#!/usr/bin/env bash
#
# build-swift-testing.sh — P2 spike: build swift-testing (`Testing`) for the
# Agora-targeting toolchain.
#
#   swift-toolchain/scripts/build-swift-testing.sh --syntax      # target swift-syntax
#   swift-toolchain/scripts/build-swift-testing.sh --configure
#   swift-toolchain/scripts/build-swift-testing.sh --build
#
# swift-foundation's test suites are `import Testing` (85 of 86 files), and the
# installed toolchain ships no XCTest or Testing, so P2 needs this built for the
# target before it can run the upstream suite.
#
# The macro plugin is built as a *library* (SwiftSyntax was found), which is the
# branch that does not need SwiftSyntax::SwiftCompilerPlugin — the target the
# toolchain's SwiftSyntaxConfig.cmake does not export (see
# SWIFT-FOUNDATION-P2-SPIKE.md). Clients then load it with
# `-load-plugin-library <build>/lib/libTestingMacros.so`.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/native-env.sh"

TOOLCHAIN="$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr"
SWIFTC="$TOOLCHAIN/bin/swiftc"
SOURCE="$OPEN_SWIFT_SOURCE_ROOT/swift-testing"
: "${AGORA_SWIFT_TESTING_BUILD_DIR:=$OPEN_SWIFT_BUILD_ROOT/p2-swift-testing}"
BUILD="$AGORA_SWIFT_TESTING_BUILD_DIR"
INSTALL="$BUILD/install"

# A TARGET build of swift-syntax, if one exists, wins over the compiler's host
# build: the macros are compiled for this stdlib, and the host swift-syntax was
# built by the bootstrap toolchain with a non-interop ABI — linking the two makes
# the SIL verifier reject the inlined `Array`/`String` code (measured).
for candidate in \
    "$OPEN_SWIFT_SOURCE_ROOT/build/agora-linux-x86_64/swift-linux-x86_64/cmake/modules" \
    "$OPEN_SWIFT_BUILD_ROOT/agora-linux-x86_64/swift-linux-x86_64/cmake/modules" \
    "$BUILD/swift-syntax/cmake/modules"; do
  if [[ -f "$candidate/SwiftSyntaxConfig.cmake" ]]; then
    SWIFT_SYNTAX_CMAKE="$candidate"
    break
  fi
done
: "${SWIFT_SYNTAX_CMAKE:=}"

if [[ ! -d "$SOURCE" ]]; then
  echo "error: swift-testing sources not found at $SOURCE" >&2
  exit 1
fi
if [[ -z "$SWIFT_SYNTAX_CMAKE" ]]; then
  echo "error: SwiftSyntaxConfig.cmake not found (the macro plugin needs swift-syntax)" >&2
  exit 1
fi

# Build swift-syntax for the *target*. Pure Swift, and safe to build with the
# toolchain the macros will be compiled by; this is also the P3 prerequisite
# (the shipped toolchain currently has only the host copy).
syntax() {
  local source="$OPEN_SWIFT_SOURCE_ROOT/swift-syntax"
  local build="$BUILD/swift-syntax"
  mkdir -p "$build"
  cmake -S "$source" -B "$build" -G Ninja \
    -DCMAKE_BUILD_TYPE="${AGORA_SWIFT_TESTING_BUILD_TYPE:-Debug}" \
    -DCMAKE_Swift_COMPILER="$SWIFTC" \
    -DCMAKE_C_COMPILER="${AGORA_HOST_CC:-clang}" \
    -DCMAKE_CXX_COMPILER="${AGORA_HOST_CXX:-clang++}" \
    -DBUILD_SHARED_LIBS=ON \
    2>&1 | tee "$BUILD/configure-syntax.log"
  cmake --build "$build" --target \
    SwiftSyntax SwiftSyntaxMacros SwiftDiagnostics SwiftParser SwiftOperators \
    SwiftSyntaxBuilder SwiftSyntaxMacroExpansion SwiftCompilerPlugin \
    SwiftCompilerPluginMessageHandling \
    2>&1 | tee "$BUILD/build-syntax.log"
}

# The C shims include Agora's headers, the link needs Agora's libraries, and the
# macro plugin is loaded by the in-process plugin server — a separate process — so
# it needs them on the *loader* path too.
export CPATH="$AGORA_PREFIX/include${CPATH:+:$CPATH}"
export LIBRARY_PATH="$AGORA_PREFIX/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$AGORA_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

configure() {
  mkdir -p "$BUILD" "$INSTALL"
  # `Testing` imports Foundation for file I/O, and on this target Foundation is
  # Agora's Clang module + overlay: the module maps are build inputs, the same way
  # they are for any client program.
  # ONLY the Foundation map. Passing the CoreFoundation map as well is a trap:
  # Foundation's umbrella includes CoreFoundation's headers, and if CoreFoundation
  # is a module of its own it is built in C mode, where CFBridgingTypes.h's
  # `#if defined(__OBJC__)` block is skipped. Foundation then sees the same
  # header through that module and NSInteger/NSRange never exist. (That is a
  # module-ownership trap, not a compiler bug; measured in the spike.)
  local swift_flags=(
    "-Xcc" "-fmodule-map-file=$AGORA_ROOT/swift-interop-probe/agora-modules/module.modulemap"
    "-Xcc" "-I$AGORA_PREFIX/include"
    "-Xcc" "-Wno-incomplete-umbrella"
    # `Backtrace` probes `_CFErrorSetCallStackCaptureEnabled` through `dlsym`
    # whenever `_runtime(_ObjC)` is true, which it is on this target. That is a
    # Foundation SPI Agora does not have; swift-testing's own switch for platforms
    # without dynamic linking turns the probe off, and the rest of `Testing` never
    # looks at the symbol.
    "-D" "SWT_NO_DYNAMIC_LINKING"
    # The compiler's interface emitter writes `@_optimize(none)` onto a stored
    # property (`failureBreakpointValue`), which its own verifier then rejects
    # ("cannot be applied to stored properties"). That is a toolchain bug recorded
    # in SWIFT-FOUNDATION-P2-SPIKE.md; the interface is still emitted, the
    # round-trip check is skipped.
    "-no-verify-emitted-module-interface"
  )
  # P3 step 1: when the re-export `Foundation` (FoundationEssentials +
  # FoundationInternationalization) has been built, it goes FIRST on the search
  # path, so `import Foundation` in Testing means that module and not the
  # hand-written overlay. See swift-toolchain/spike/foundation-reexport/.
  if [[ -n "${AGORA_FOUNDATION_SPIKE_DIR:-}" ]]; then
    local spike="$AGORA_FOUNDATION_SPIKE_DIR"
    local icu="$OPEN_SWIFT_SOURCE_ROOT/swift-foundation-icu/icuSources/include"
    local shims="$OPEN_SWIFT_SOURCE_ROOT/swift-foundation/Sources/_FoundationCShims/include"
    swift_flags=(
      "-I" "$spike/reexport/swift" "-I" "$spike/swift"
      "-L" "$spike/reexport/lib" "-L" "$spike/lib"
      "-Xcc" "-fmodule-map-file=$shims/module.modulemap"
      "-Xcc" "-fmodule-map-file=$icu/_foundation_unicode/module.modulemap"
      "-Xcc" "-I$icu" "-Xcc" "-I$shims"
      "${swift_flags[@]}"
    )
  fi
  cmake -S "$SOURCE" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE="${AGORA_SWIFT_TESTING_BUILD_TYPE:-Debug}" \
    -DCMAKE_Swift_COMPILER="$SWIFTC" \
    -DCMAKE_C_COMPILER="${AGORA_HOST_CC:-clang}" \
    -DCMAKE_CXX_COMPILER="${AGORA_HOST_CXX:-clang++}" \
    -DCMAKE_PREFIX_PATH="$AGORA_PREFIX" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DSwiftSyntax_DIR="$SWIFT_SYNTAX_CMAKE" \
    -DSwiftTesting_MACRO_Swift_COMPILER="${OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN}/bin/swiftc" \
    "-DCMAKE_Swift_FLAGS=${swift_flags[*]}" \
    -DCMAKE_SHARED_LINKER_FLAGS="-L$AGORA_PREFIX/lib" \
    -DCMAKE_EXE_LINKER_FLAGS="-L$AGORA_PREFIX/lib" \
    -DBUILD_TESTING=OFF \
    2>&1 | tee "$BUILD/configure.log"
}

build() {
  local target
  for target in Testing TestingMacros; do
    cmake --build "$BUILD" --target "$target" 2>&1 | tee "$BUILD/build-$target.log"
  done
}

case "${1:-}" in
  --syntax)    syntax ;;
  --configure) configure ;;
  --build)     build ;;
  *)
    echo "usage: $0 --syntax | --configure | --build" >&2
    exit 2
    ;;
esac
