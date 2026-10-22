#!/usr/bin/env bash
#
# build-foundation-p3.sh — build the P3 `Foundation` module and run its probe.
#
#   swift-toolchain/scripts/build-foundation-p3.sh            # build + probe
#   swift-toolchain/scripts/build-foundation-p3.sh --build    # build only
#   swift-toolchain/scripts/build-foundation-p3.sh --install  # build, probe, install
#   swift-toolchain/scripts/build-foundation-p3.sh --uninstall
#
# `--install` is the step that changes what `import Foundation` means for the
# toolchain: FoundationEssentials, FoundationInternationalization and this module
# are copied next to the target stdlib, and the old overlay's module is moved to
# `Foundation.overlay-backup/` so `--uninstall` (or `build-foundation-overlay.sh`)
# puts it back.  Two C modules the ported Foundation needs (`_FoundationCShims`,
# `_FoundationICU`) are shipped the same way, and the `swiftc-p3` wrapper the
# script writes adds their module maps, which is the piece an SDK would supply: a
# client still passes Agora's own module map for `NSObject` and friends, exactly
# as it does today, but nothing extra for Foundation.
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
"$SWIFTC" -module-name Foundation -import-underlying-module -enable-testing \
  -emit-module -emit-module-path "$OUT/Foundation.swiftmodule/$HOST_TARGET.swiftmodule" \
  -emit-library -module-link-name Foundation \
  -o "$OUT/libFoundation.so" \
  "$SRCDIR/Foundation.swift" \
  "$SRCDIR/FoundationShim.swift" \
  "$SRCDIR/FoundationValueBridges.swift" \
  "$SRCDIR/FoundationKeptTypes.swift" \
  "$SRCDIR/FoundationCompat.swift" \
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

install_module() {
  local backup="$STDLIB/Foundation.overlay-backup"
  echo "== installing the P3 Foundation beside the target stdlib =="
  if [[ ! -d "$backup" ]]; then
    mkdir -p "$backup"
    [[ -e "$STDLIB/Foundation.swiftmodule" ]] && mv "$STDLIB/Foundation.swiftmodule" "$backup/"
    [[ -e "$STDLIB/libFoundation.so" ]] && mv "$STDLIB/libFoundation.so" "$backup/"
  fi
  # FoundationEssentials / FoundationInternationalization and the two libraries
  # they are built on, then the P3 module itself.
  local mod lib
  # The CMake build writes one `<Module>.swiftmodule` *file*; the toolchain's
  # module layout is `<Module>.swiftmodule/<target>.swiftmodule`, the shape the
  # stdlib's own modules use and the one the importer searches.  Both are handled
  # so a build that switches shape does not silently install nothing.
  for mod in FoundationEssentials FoundationInternationalization _FoundationCollections; do
    local src="$SP/swift/$mod.swiftmodule"
    if [[ -d "$src" ]]; then
      rm -rf "$STDLIB/$mod.swiftmodule"
      cp -a "$src" "$STDLIB/"
    elif [[ -f "$src" ]]; then
      rm -rf "$STDLIB/$mod.swiftmodule"
      install -d "$STDLIB/$mod.swiftmodule"
      install -m 644 "$src" "$STDLIB/$mod.swiftmodule/$HOST_TARGET.swiftmodule"
    fi
  done
  for lib in libFoundationEssentials.so libFoundationInternationalization.so \
             lib_FoundationCollections.so lib_FoundationCShims.so lib_FoundationICU.so; do
    [[ -e "$SP/lib/$lib" ]] && cp -a "$SP/lib/$lib" "$STDLIB/"
  done
  install -d "$STDLIB/Foundation.swiftmodule"
  install -m 644 "$OUT/Foundation.swiftmodule/$HOST_TARGET.swiftmodule" \
    "$STDLIB/Foundation.swiftmodule/$HOST_TARGET.swiftmodule"
  install -m 755 "$OUT/libFoundation.so" "$STDLIB/libFoundation.so"

  # The C modules the ported Foundation imports.  An SDK installs these; the
  # wrapper below points Clang at them so a client needs no extra flags for them.
  local cdir="$STDLIB/foundation-c-modules"
  install -d "$cdir"
  if [[ -d "$SHIMS" ]]; then
    rm -rf "$cdir/FoundationCShims"
    cp -a "$SHIMS" "$cdir/FoundationCShims"
  fi
  local icu_inc
  icu_inc="$(dirname "$ICU")"
  if [[ -d "$ICU" ]]; then
    rm -rf "$cdir/FoundationICU"
    install -d "$cdir/FoundationICU"
    cp -a "$ICU/." "$cdir/FoundationICU/"
  fi

  # A `swiftc` front that adds those two include directories: the toolchain's own
  # wrapper stays untouched, so `--uninstall` is just the two moves above.
  cat > "$BUILD/bin/swiftc-p3" <<'WRAP'
#!/usr/bin/env bash
# Generated by build-foundation-p3.sh --install: the toolchain's swiftc plus the
# include directories the ported Foundation's C modules live in (the piece an SDK
# would otherwise supply).  Everything else is the toolchain's own driver.
TOOLCHAIN_SWIFTC=@SWIFTC@
CMODULES=@CMODULES@
exec "$TOOLCHAIN_SWIFTC" \
  -Xcc -I"$CMODULES/FoundationCShims" \
  -Xcc -I"$CMODULES/FoundationICU" \
  "$@"
WRAP
  sed -i "s|@SWIFTC@|$SWIFTC|; s|@CMODULES@|$cdir|" "$BUILD/bin/swiftc-p3"
  chmod +x "$BUILD/bin/swiftc-p3"
  echo "  [ok] Foundation.swiftmodule + libFoundation.so installed in $STDLIB"
  echo "  [ok] FE/FI and their libraries installed; client front: $BUILD/bin/swiftc-p3"
}

uninstall_module() {
  local backup="$STDLIB/Foundation.overlay-backup"
  echo "== restoring the overlay =="
  rm -rf "$STDLIB/Foundation.swiftmodule" "$STDLIB/libFoundation.so"
  if [[ -d "$backup" ]]; then
    [[ -e "$backup/Foundation.swiftmodule" ]] && mv "$backup/Foundation.swiftmodule" "$STDLIB/"
    [[ -e "$backup/libFoundation.so" ]] && mv "$backup/libFoundation.so" "$STDLIB/"
    rmdir "$backup" 2>/dev/null || true
    echo "  [ok] the overlay is back"
  else
    echo "  [warn] no backup found; run build-foundation-overlay.sh to rebuild it"
  fi
  # Everything else the install added goes too, so a stale module cannot shadow a
  # later one and the toolchain is exactly as build-swift-toolchain.sh left it.
  local mod lib
  for mod in FoundationEssentials FoundationInternationalization _FoundationCollections; do
    rm -rf "$STDLIB/$mod.swiftmodule"
  done
  for lib in libFoundationEssentials.so libFoundationInternationalization.so \
             lib_FoundationCollections.so lib_FoundationCShims.so lib_FoundationICU.so; do
    rm -f "$STDLIB/$lib"
  done
  rm -rf "$STDLIB/foundation-c-modules"
  rm -f "$BUILD/bin/swiftc-p3"
  echo "  [ok] FoundationEssentials/FoundationInternationalization removed"
}

if [[ "${1:-}" == "--uninstall" ]]; then
  uninstall_module
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

if [[ "${1:-}" == "--install" ]]; then
  install_module
fi
