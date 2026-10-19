#!/usr/bin/env bash
#
# Build and install Agora's Swift `ObjectiveC` module.
#
#   swift-toolchain/scripts/build-objectivec-overlay.sh
#
# The Clang importer looks three things up *by name* in a module called
# `ObjectiveC`:
#
#   BOOL      -> ObjectiveC.ObjCBool   (otherwise every `BOOL` imports as UInt8)
#   SEL       -> ObjectiveC.Selector   (otherwise `#selector` is unavailable)
#   NSZone *  -> ObjectiveC.NSZone
#
# On Darwin that module is an overlay over the `ObjectiveC` Clang module.
# Agora's libobjc2 headers are not a Clang module, so the Swift module declares
# the two C entry points it needs with `@_silgen_name` and needs no Clang
# module at all. It is installed next to the target stdlib:
#
#   usr/lib/swift/linux/ObjectiveC.swiftmodule
#   usr/lib/swift/linux/libObjectiveC.so
#
# The Foundation overlay re-exports it (`@_exported import ObjectiveC`), so
# `import Foundation` brings `ObjCBool`/`Selector`/`NSZone` into scope the way
# Darwin does.
#
# Runs against the *installed* toolchain, before build-foundation-overlay.sh.
#
#   AGORA_PREFIX, AGORA_SWIFT_ROOT, ... as in native-env.sh

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/native-env.sh"

TOOLCHAIN="$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr"
SWIFTC="$TOOLCHAIN/bin/swiftc"
STDLIB_DIR="$TOOLCHAIN/lib/swift/linux"
SRC="$AGORA_ROOT/swift-toolchain/objectivec-overlay/ObjectiveC.swift"

if [[ ! -x "$SWIFTC" ]]; then
  echo "error: no installed swiftc at $SWIFTC" >&2
  exit 1
fi
if [[ ! -f "$SRC" ]]; then
  echo "error: ObjectiveC overlay source not found: $SRC" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

HOST_TARGET="${HOST_TARGET:-$(uname -m)-unknown-linux-gnu}"

echo "== building the ObjectiveC module =="
"$SWIFTC" -module-name ObjectiveC \
  -emit-module -emit-module-path "$work/ObjectiveC.swiftmodule" \
  -emit-library -module-link-name ObjectiveC \
  -o "$work/libObjectiveC.so" \
  "$SRC"

install -d "$STDLIB_DIR/ObjectiveC.swiftmodule"
install -m 644 "$work/ObjectiveC.swiftmodule" \
  "$STDLIB_DIR/ObjectiveC.swiftmodule/$HOST_TARGET.swiftmodule"
install -m 755 "$work/libObjectiveC.so" "$STDLIB_DIR/libObjectiveC.so"

echo "== checking that 'import ObjectiveC' and 'BOOL' work =="
cat > "$work/objc-check.swift" <<'EOF'
import ObjectiveC
import Foundation

precondition(ObjCBool(true).boolValue)
precondition(_convertObjCBoolToBool(_convertBoolToObjCBool(true)))
let sel: Selector = #selector(NSObject.copy)
precondition(sel == Selector("copy"))
precondition(sel.name == "copy")
let registered = Selector(stringLiteral: "length")
precondition(registered.name == "length")
print("objectivec module: ok")
EOF
if env -i PATH=/usr/bin:/bin HOME="${HOME:-/tmp}" \
     LD_LIBRARY_PATH="$AGORA_PREFIX/lib" \
     "$SWIFTC" -o "$work/objc-check" "$work/objc-check.swift" \
     -Xcc -fmodule-map-file="$AGORA_ROOT/swift-interop-probe/agora-modules/module.modulemap" \
     -Xcc -I"$AGORA_PREFIX/include" -Xcc -Wno-incomplete-umbrella \
     -L"$AGORA_PREFIX/lib" -lagora-base -lobjc \
     -Xlinker -rpath -Xlinker "$AGORA_PREFIX/lib" \
     >"$work/out" 2>&1 \
   && LD_LIBRARY_PATH="$AGORA_PREFIX/lib" "$work/objc-check" >>"$work/out" 2>&1; then
  echo "  [ok] $(tail -1 "$work/out")"
else
  echo "  [warn] the ObjectiveC self-check failed:" >&2
  sed 's/^/         /' "$work/out" | tail -15 >&2
fi

echo "== done: ObjectiveC installed under $STDLIB_DIR =="
