#!/usr/bin/env bash
#
# build-foundation-macros.sh — build swift-foundation's macro plugin
# (`Predicate`, `Expression`, `Bundle`) for the FoundationEssentials spike.
#
#   swift-toolchain/scripts/build-foundation-macros.sh --configure
#   swift-toolchain/scripts/build-foundation-macros.sh --build
#   swift-toolchain/scripts/build-foundation-macros.sh            # both + self-check
#
# Why this exists: swift-foundation's predicate tests (`PredicateTests`, and the
# `#Predicate`/`#Expression` declarations in FoundationEssentials themselves) need
# the plugin; without it the compiler cannot expand the macro and the test file
# does not build.  It was the last build failure in the P2 harness.
#
# Why *library* mode: a macro plugin runs inside the compiler process, and the
# compiler is a host tool (it runs on the bootstrap runtime, handoff §2.4).  The
# plugin is therefore built by the **bootstrap** compiler against the **host**
# SwiftSyntax that the toolchain build tree exports
# (`lib/swift/host/libSwiftSyntax*.so`), and loaded with
# `-load-plugin-library libFoundationMacros.so`.  swift-foundation's own CMake
# supports exactly this shape (`-DFoundationMacros_BuildLocalExecutable=NO`,
# `FOUNDATION_MACROS_LIBRARY`), which is how swift-testing's `TestingMacros` is
# built here too.
#
# The executable shape would need `SwiftSyntax::SwiftCompilerPlugin`, which the
# toolchain's `SwiftSyntaxConfig.cmake` does not export (the target is
# EXCLUDE_FROM_ALL upstream), so it is not an option in this tree.
#
#   AGORA_FOUNDATION_MACROS_BUILD_DIR   build directory (default
#                                       $OPEN_SWIFT_BUILD_ROOT/p2-foundation-macros)
#   AGORA_PREFIX, AGORA_SWIFT_ROOT, ... as in native-env.sh

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/native-env.sh"

SOURCE="$OPEN_SWIFT_SOURCE_ROOT/swift-foundation/Sources/FoundationMacros"
BUILD="${AGORA_FOUNDATION_MACROS_BUILD_DIR:-$OPEN_SWIFT_BUILD_ROOT/p2-foundation-macros}"
BOOTSTRAP_SWIFTC="$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/bin/swiftc"

# The host SwiftSyntax the compiler was built against.  Take whichever the tree
# has; the exported config points at lib/swift/host/, which is what a host plugin
# must link.
SWIFT_SYNTAX_CMAKE=""
for candidate in \
    "$OPEN_SWIFT_SOURCE_ROOT/build/agora-linux-x86_64/swift-linux-x86_64/cmake/modules" \
    "$OPEN_SWIFT_BUILD_ROOT/agora-linux-x86_64/swift-linux-x86_64/cmake/modules"; do
  if [[ -f "$candidate/SwiftSyntaxConfig.cmake" ]]; then
    SWIFT_SYNTAX_CMAKE="$candidate"
    break
  fi
done

if [[ ! -d "$SOURCE" ]]; then
  echo "error: swift-foundation macros not found at $SOURCE" >&2
  exit 1
fi
if [[ ! -x "$BOOTSTRAP_SWIFTC" ]]; then
  echo "error: bootstrap swiftc not found at $BOOTSTRAP_SWIFTC" >&2
  exit 1
fi

configure() {
  if [[ -z "$SWIFT_SYNTAX_CMAKE" ]]; then
    echo "error: SwiftSyntaxConfig.cmake not found (the macros need swift-syntax)" >&2
    echo "       build the toolchain once (build-swift-toolchain.sh) first" >&2
    exit 1
  fi
  # SWIFT_SYNTAX_CMAKE is the `cmake/modules` directory next to the toolchain
  # build tree; the host libraries the plugin links are its sibling.
  local host_dir
  host_dir="$(cd "$(dirname "$SWIFT_SYNTAX_CMAKE")/../lib/swift/host" && pwd)"
  mkdir -p "$BUILD"
  echo "== configure $BUILD =="
  echo "   compiler : $BOOTSTRAP_SWIFTC (host)"
  echo "   syntax   : $SWIFT_SYNTAX_CMAKE"
  "$AGORA_CMAKE" -S "$SOURCE" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_Swift_COMPILER="$BOOTSTRAP_SWIFTC" \
    -DSwiftSyntax_DIR="$SWIFT_SYNTAX_CMAKE" \
    -DFoundationMacros_BuildLocalExecutable=NO \
    -DCMAKE_SHARED_LINKER_FLAGS="-Xlinker -rpath -Xlinker $host_dir" \
    >"$BUILD/configure.log" 2>&1 || { tail -20 "$BUILD/configure.log" >&2; exit 1; }
}

build() {
  if [[ ! -f "$BUILD/build.ninja" ]]; then
    echo "error: no configured build tree at $BUILD (run --configure)" >&2
    exit 1
  fi
  echo "== build FoundationMacros (library plugin) =="
  "$AGORA_NINJA" -C "$BUILD" FoundationMacros
}

# A plugin that cannot expand `#Predicate` is worse than none: type-check a
# two-line program against the spike's FoundationEssentials when it is there.
self_check() {
  local plugin="$BUILD/lib/libFoundationMacros.so"
  local spike="${AGORA_FOUNDATION_SPIKE_DIR:-$OPEN_SWIFT_BUILD_ROOT/p2-foundation-testing}"
  if [[ ! -f "$plugin" ]]; then
    echo "error: $plugin was not produced" >&2
    exit 1
  fi
  if [[ ! -d "$spike/swift" ]]; then
    echo "   [skip] self-check (no FoundationEssentials build at $spike;"
    echo "          run build-swift-foundation.sh --testing --configure/--build)"

    return 0
  fi
  local work shims icu mm
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' RETURN
  shims="$OPEN_SWIFT_SOURCE_ROOT/swift-foundation/Sources/_FoundationCShims/include"
  icu="$OPEN_SWIFT_SOURCE_ROOT/swift-foundation-icu/icuSources/include"
  mm=(-Xcc "-fmodule-map-file=$AGORA_ROOT/swift-interop-probe/agora-modules/module.modulemap"
      -Xcc -I"$AGORA_PREFIX/include" -Xcc -Wno-incomplete-umbrella)
  cat > "$work/predicate.swift" <<'EOF'
import FoundationEssentials
let p = #Predicate<Int> { $0 > 5 }
let e = #Expression<Int, Bool> { $0 == 7 }
EOF
  if "$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr/bin/swiftc" -typecheck \
      -I "$spike/reexport/swift" -I "$spike/swift" \
      -L "$spike/reexport/lib" -L "$spike/lib" \
      -Xcc "-fmodule-map-file=$shims/module.modulemap" \
      -Xcc "-fmodule-map-file=$icu/_foundation_unicode/module.modulemap" \
      -Xcc -I"$icu" -Xcc -I"$shims" "${mm[@]}" \
      -load-plugin-library "$plugin" "$work/predicate.swift" >"$work/check.log" 2>&1; then
    echo "   [ok] #Predicate and #Expression expand through the plugin"
  else
    echo "   [FAIL] the plugin does not expand #Predicate:" >&2
    grep -E "error:" "$work/check.log" | head -5 | sed 's/^/         /' >&2
    exit 1
  fi
}

case "${1:-}" in
  --configure) configure ;;
  --build)     build ;;
  "")
    configure
    build
    echo "== self-check =="
    self_check
    echo "== done =="
    echo "  plugin: $BUILD/lib/libFoundationMacros.so"
    echo "  load:   swiftc -load-plugin-library $BUILD/lib/libFoundationMacros.so ..."
    ;;
  *)
    echo "usage: $0 [--configure | --build]" >&2
    exit 2
    ;;
esac
