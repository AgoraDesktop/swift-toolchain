#!/usr/bin/env bash
#
# build-swift-foundation.sh — P2 spike: build swift-foundation's
# FoundationEssentials / FoundationInternationalization against Agora.
#
#   swift-toolchain/scripts/build-swift-foundation.sh --configure [--testing]
#   swift-toolchain/scripts/build-swift-foundation.sh --build [target ...]
#   swift-toolchain/scripts/build-swift-foundation.sh --apply-patches
#   swift-toolchain/scripts/build-swift-foundation.sh --logs
#
# `--apply-patches` applies `patches/0016-swift-foundation-bundle-stub-name.patch`
# (idempotent: `git apply --check` first).  It is needed before a build on a fresh
# checkout, and it is what makes `import Foundation` unambiguous: FoundationEssentials'
# stand-in bundle type is named `FoundationBundle` there, so it cannot collide with
# an Objective-C Foundation's `Bundle` — Agora's `NSBundle` imports under that name.
# See SWIFT-PORT-HANDOFF.md §2.35.
#
# This is a SPIKE build, not the shipped arrangement: the modules land in a
# private tree (AGORA_FOUNDATION_BUILD_DIR), they are not installed next to the
# target stdlib, and `import Foundation` still means Agora's overlay. What it
# measures is in SWIFT-FOUNDATION-P2-SPIKE.md.
#
# Why CMake and not SwiftPM: the installed toolchain has no swift-build /
# swift-driver, so SwiftPM cannot run. swift-foundation's CMake build is the one
# the toolchain itself uses, and it accepts local dependency paths, which keeps
# the spike offline.
#
# Inputs, all local:
#   - swift-foundation, swift-collections, swift-foundation-icu (source checkouts)
#   - SwiftSyntaxConfig.cmake from the compiler build tree (FoundationMacros)
#   - Agora's headers and libraries in $AGORA_PREFIX
#   - the CoreFoundation module map in swift-interop-probe/agora-modules/

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/native-env.sh"

TOOLCHAIN="$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr"
SWIFTC="$TOOLCHAIN/bin/swiftc"
SOURCE="$OPEN_SWIFT_SOURCE_ROOT/swift-foundation"
: "${AGORA_FOUNDATION_BUILD_DIR:=$OPEN_SWIFT_BUILD_ROOT/p2-foundation}"
BUILD="$AGORA_FOUNDATION_BUILD_DIR"
INSTALL="$BUILD/install"
MODULEMAP_DIR="$AGORA_ROOT/swift-interop-probe/agora-modules"
# The toolchain build tree has moved between layouts; take whichever exists.
for candidate in \
    "$OPEN_SWIFT_BUILD_ROOT/agora-linux-x86_64/swift-linux-x86_64/cmake/modules" \
    "$OPEN_SWIFT_SOURCE_ROOT/build/agora-linux-x86_64/swift-linux-x86_64/cmake/modules"; do
  if [[ -f "$candidate/SwiftSyntaxConfig.cmake" ]]; then
    SWIFT_SYNTAX_CMAKE="$candidate"
    break
  fi
done
: "${SWIFT_SYNTAX_CMAKE:=}"

if [[ ! -d "$SOURCE" ]]; then
  echo "error: swift-foundation sources not found at $SOURCE" >&2
  exit 1
fi
if [[ ! -x "$SWIFTC" ]]; then
  echo "error: no installed swiftc at $SWIFTC" >&2
  exit 1
fi
if [[ ! -f "$SWIFT_SYNTAX_CMAKE/SwiftSyntaxConfig.cmake" ]]; then
  echo "error: SwiftSyntaxConfig.cmake not found under $SWIFT_SYNTAX_CMAKE" >&2
  echo "       FoundationMacros needs a swift-syntax CMake build" >&2
  exit 1
fi

# The C shim and the Swift sources both include Agora's headers, and the linker
# has to find Agora's libraries; the module map's `link "agora-core"` supplies the
# autolink *name*, this supplies the search path.
export CPATH="$AGORA_PREFIX/include:${CPATH:-}"
export LIBRARY_PATH="$AGORA_PREFIX/lib:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="$AGORA_PREFIX/lib:${LD_LIBRARY_PATH:-}"

SWIFT_FLAGS=(
  "-Xcc" "-fmodule-map-file=$MODULEMAP_DIR/CoreFoundation.modulemap"
  "-Xcc" "-I$AGORA_PREFIX/include"
  "-Xcc" "-Wno-incomplete-umbrella"
)

configure() {
  mkdir -p "$BUILD" "$INSTALL" "$BUILD/empty-plugin-dir"
  # FoundationMacros cannot be built here: it links SwiftSyntax::SwiftCompilerPlugin,
  # and the toolchain's swift-syntax is configured with that target EXCLUDE_FROM_ALL,
  # so it is absent from the exported SwiftSyntaxConfig.cmake. No FoundationEssentials
  # source uses a Foundation macro, so the plugin path points at an empty directory:
  # the compiler only reads it when a macro is expanded. P3 must build the plugin for
  # real (see SWIFT-FOUNDATION-P2-SPIKE.md).
  local macro_workaround="$BUILD/empty-plugin-dir"
  local enable_testing=""
  if (( testing_build )); then enable_testing=" -enable-testing"; fi
  cmake -S "$SOURCE" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_Swift_COMPILER="$SWIFTC" \
    -DCMAKE_C_COMPILER="${AGORA_HOST_CC:-clang}" \
    -DCMAKE_CXX_COMPILER="${AGORA_HOST_CXX:-clang++}" \
    -DCMAKE_PREFIX_PATH="$AGORA_PREFIX" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL" \
    -DBUILD_SHARED_LIBS=ON \
    -DSwiftFoundation_SOURCE_DIR="$SOURCE" \
    -D_SwiftCollections_SourceDIR="$OPEN_SWIFT_SOURCE_ROOT/swift-collections" \
    -D_SwiftFoundationICU_SourceDIR="$OPEN_SWIFT_SOURCE_ROOT/swift-foundation-icu" \
    -DSwiftSyntax_DIR="$SWIFT_SYNTAX_CMAKE" \
    -DSwiftFoundation_MACRO="$macro_workaround" \
    "-DCMAKE_Swift_FLAGS=${SWIFT_FLAGS[*]}$enable_testing" \
    -DCMAKE_SHARED_LINKER_FLAGS="-L$AGORA_PREFIX/lib" \
    -DCMAKE_EXE_LINKER_FLAGS="-L$AGORA_PREFIX/lib" \
    2>&1 | tee "$BUILD/configure.log"
}

build() {
  local target
  for target in "$@"; do
    cmake --build "$BUILD" --target "$target" 2>&1 | tee "$BUILD/build-$target.log"
  done
}

# The test targets are `@testable import FoundationEssentials`, so the suite needs a
# module built with -enable-testing. That is a separate build tree: the spike's
# shipped-shape build stays free of testable symbols.
action=""
targets=()
testing_build=0
for arg in "$@"; do
  case "$arg" in
    --testing)               testing_build=1 ;;
    --apply-patches|--configure|--build|--logs) action="$arg" ;;
    -*)                      echo "unknown option: $arg" >&2; exit 2 ;;
    *)                       targets+=("$arg") ;;
  esac
done
if (( testing_build )); then
  BUILD="$AGORA_FOUNDATION_BUILD_DIR-testing"
  INSTALL="$BUILD/install"
fi

apply_patches() {
  local patch
  for patch in "$AGORA_ROOT"/swift-toolchain/patches/0016-swift-foundation-*.patch; do
    [[ -f "$patch" ]] || continue
    echo "== $(basename "$patch") =="
    if git -C "$SOURCE" apply --check "$patch" 2>/dev/null; then
      git -C "$SOURCE" apply "$patch"
      echo "  [ok] applied"
    elif git -C "$SOURCE" apply --reverse --check "$patch" 2>/dev/null; then
      echo "  [ok] already applied"
    else
      echo "  [FAIL] neither applies nor is applied; the checkout has moved" >&2
      exit 1
    fi
  done
}

case "$action" in
  --apply-patches) apply_patches ;;
  --configure) configure ;;
  --build)     build "${targets[@]:-FoundationEssentials}" ;;
  --logs)      grep -nE 'error:|undefined reference|fatal error' "$BUILD"/*.log | head -60 ;;
  *)
    echo "usage: $0 [--testing] --configure | --build [target ...] | --logs" >&2
    exit 2
    ;;
esac
