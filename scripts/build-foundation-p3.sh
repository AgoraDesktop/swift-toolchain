#!/usr/bin/env bash
#
# build-foundation-p3.sh — build the P3 `Foundation` module and run its probe.
#
#   swift-toolchain/scripts/build-foundation-p3.sh            # build + probe
#   swift-toolchain/scripts/build-foundation-p3.sh --build    # build only
#
# What P3 changes: `import Foundation` stops being the hand-written overlay and
# becomes Darwin's arrangement — one Swift module that re-exports
# `FoundationEssentials` and `FoundationInternationalization` and adds the value
# bridges to Agora's Objective-C classes (`NSData`, `NSDate`, `NSURL`, ...).
# The old overlay's value types (`foundation-overlay/FoundationValueTypes.swift`)
# are retired; what remains of the overlay is the standard-library bridges, which
# no one else supplies (`foundation-p3/FoundationShim.swift`).
#
# The module is built *into a staging tree*, not installed, so the shipped
# toolchain keeps working while the bridges are written.  Layout:
#
#   $BUILD/lib/swift/linux/Foundation.swiftmodule/<target>.swiftmodule
#   $BUILD/lib/swift/linux/libFoundation.so
#   $BUILD/bin/foundation-p3-probe
#
# FoundationEssentials/FoundationInternationalization come from the spike build
# that `build-swift-foundation.sh --testing` produced (the `-enable-testing` in it
# does not matter to a client); `AGORA_FOUNDATION_SPIKE_DIR` points at it.
#
# Inputs: an installed toolchain (build-swift-toolchain.sh) and the Foundation
# spike build.  Environment as in native-env.sh, plus
#   AGORA_FOUNDATION_SPIKE_DIR      default $OPEN_SWIFT_BUILD_ROOT/p2-foundation-testing
#   AGORA_FOUNDATION_P3_BUILD_DIR   default $OPEN_SWIFT_BUILD_ROOT/p3-foundation

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/native-env.sh"

T="$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr"
SWIFTC="$T/bin/swiftc"
STDLIB="$T/lib/swift/linux"
SRCDIR="$AGORA_ROOT/swift-toolchain/foundation-p3"
SP="${AGORA_FOUNDATION_SPIKE_DIR:-$OPEN_SWIFT_BUILD_ROOT/p2-foundation-testing}"
BUILD="${AGORA_FOUNDATION_P3_BUILD_DIR:-$OPEN_SWIFT_BUILD_ROOT/p3-foundation}"
ICU="$OPEN_SWIFT_SOURCE_ROOT/swift-foundation-icu/icuSources/include"
SHIMS="$OPEN_SWIFT_SOURCE_ROOT/swift-foundation/Sources/_FoundationCShims/include"
MODULEMAP="$AGORA_ROOT/swift-interop-probe/agora-modules/module.modulemap"
HOST_TARGET="${HOST_TARGET:-$(uname -m)-unknown-linux-gnu}"
OUT="$BUILD/lib/swift/linux"

for f in "$SWIFTC" "$MODULEMAP"; do
  if [[ ! -e "$f" ]]; then
    echo "error: missing $f (build the toolchain first: build-swift-toolchain.sh)" >&2
    exit 1
  fi
done
if [[ ! -d "$SP/swift" ]]; then
  echo "error: no FoundationEssentials build at $SP" >&2
  echo "       run build-swift-foundation.sh --testing --configure and --build" >&2
  exit 1
fi

# FoundationEssentials' modules need their own Clang modules (the C shims and the
# ICU headers) wherever they are imported, this build included.
FE_FLAGS=(
  -I "$SP/reexport/swift" -I "$SP/swift"
  -L "$SP/reexport/lib" -L "$SP/lib"
  -lFoundationEssentials -lFoundationInternationalization
  -l_FoundationCollections -l_FoundationCShims -l_FoundationICU
  -Xcc "-fmodule-map-file=$SHIMS/module.modulemap"
  -Xcc "-fmodule-map-file=$ICU/_foundation_unicode/module.modulemap"
  -Xcc -I"$ICU" -Xcc -I"$SHIMS"
  -Xlinker -rpath -Xlinker "$SP/lib"
)

# Agora's Objective-C Foundation, as the *underlying* module of the same name.
AGORA_FLAGS=(
  -Xcc "-fmodule-map-file=$MODULEMAP"
  -Xcc -I"$AGORA_PREFIX/include"
  -Xcc -Wno-incomplete-umbrella
  -L"$AGORA_PREFIX/lib" -lagora-base -lagora-core -lagora-dispatch
  -lobjc -lBlocksRuntime
  -Xlinker -rpath -Xlinker "$AGORA_PREFIX/lib"
)

mkdir -p "$OUT/Foundation.swiftmodule" "$SP/lib" "$BUILD/bin"

echo "== building the P3 Foundation module =="
echo "   sources: $SRCDIR"
echo "   FE/FI  : $SP"
"$SWIFTC" -module-name Foundation -import-underlying-module \
  -emit-module -emit-module-path "$OUT/Foundation.swiftmodule/$HOST_TARGET.swiftmodule" \
  -emit-library -module-link-name Foundation \
  -o "$OUT/libFoundation.so" \
  "$SRCDIR/Foundation.swift" \
  "$SRCDIR/FoundationShim.swift" \
  "$SRCDIR/FoundationValueBridges.swift" \
  "${FE_FLAGS[@]}" "${AGORA_FLAGS[@]}" \
  >"$BUILD/build.log" 2>&1 || {
    echo "  [FAIL] the module did not build:" >&2
    grep -E "error:" "$BUILD/build.log" | head -15 | sed 's/^/         /' >&2
    exit 1
  }
echo "  [ok] $(ls -l "$OUT/libFoundation.so" | awk '{print $5}') bytes, module at $OUT"

if [[ "${1:-}" == "--build" ]]; then
  echo "== done (module only) =="
  exit 0
fi

echo "== building the probe =="
probe="$BUILD/bin/foundation-p3-probe"
"$SWIFTC" -o "$probe" "$SRCDIR/Probe.swift" \
  -I "$OUT" "$OUT/libFoundation.so" "${FE_FLAGS[@]}" "${AGORA_FLAGS[@]}" \
  -Xlinker -rpath -Xlinker "$OUT" \
  >"$BUILD/probe.log" 2>&1 || {
    echo "  [FAIL] the probe did not build:" >&2
    grep -E "error:" "$BUILD/probe.log" | head -15 | sed 's/^/         /' >&2
    exit 1
  }

echo "== running the probe =="
if LD_LIBRARY_PATH="$OUT:$SP/lib:$STDLIB:$AGORA_PREFIX/lib" "$probe" >"$BUILD/probe-run.log" 2>&1; then
  sed 's/^/  /' "$BUILD/probe-run.log"
  echo
  echo "foundation-p3: ok (module built, every bridge in the probe round-trips)"
else
  echo "  [FAIL] the probe failed:" >&2
  sed 's/^/         /' "$BUILD/probe-run.log" | tail -20 >&2
  exit 1
fi
