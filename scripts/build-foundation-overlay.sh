#!/usr/bin/env bash
#
# Build and install Agora's Swift Foundation overlay.
#
#   swift-toolchain/scripts/build-foundation-overlay.sh
#
# The standard library deliberately leaves the value bridges (`String` <->
# `NSString`, `Array` <-> `NSArray`, `Error` <-> `NSError`, ...) to the
# Foundation overlay.  Darwin gets them from its Foundation; this toolchain has
# Agora's Objective-C Foundation as a Clang module, so the overlay is a Swift
# module *of the same name*, built with `-import-underlying-module` exactly the
# way Darwin's is, and installed next to the target stdlib:
#
#   usr/lib/swift/linux/Foundation.swiftmodule
#   usr/lib/swift/linux/libFoundation.so
#
# `import Foundation` then picks it up with no extra flags; the module's link
# name (`-module-link-name Foundation`) autolinks the shared library.
#
# Runs against the *installed* toolchain, after build-swift-toolchain.sh has
# installed the compiler and stdlib.
#
#   AGORA_PREFIX, AGORA_SWIFT_ROOT, ... as in native-env.sh

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/native-env.sh"

TOOLCHAIN="$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr"
SWIFTC="$TOOLCHAIN/bin/swiftc"
STDLIB_DIR="$TOOLCHAIN/lib/swift/linux"
SRCDIR="$AGORA_ROOT/swift-toolchain/foundation-overlay"
MODULEMAP="$AGORA_ROOT/swift-interop-probe/agora-modules/module.modulemap"

if [[ ! -x "$SWIFTC" ]]; then
  echo "error: no installed swiftc at $SWIFTC" >&2
  exit 1
fi
if [[ ! -d "$SRCDIR" ]]; then
  echo "error: overlay sources not found: $SRCDIR" >&2
  exit 1
fi
if [[ ! -f "$MODULEMAP" ]]; then
  echo "error: Agora module map not found: $MODULEMAP" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The module search looks for `<name>.swiftmodule/<target>.swiftmodule` in the
# resource dir, the same layout the stdlib's own modules use; a bare
# `Foundation.swiftmodule` file is only found through an explicit -I.
HOST_TARGET="${HOST_TARGET:-$(uname -m)-unknown-linux-gnu}"

echo "== building the Foundation overlay =="
"$SWIFTC" -module-name Foundation -import-underlying-module \
  -emit-module -emit-module-path "$work/Foundation.swiftmodule" \
  -emit-library -module-link-name Foundation \
  -o "$work/libFoundation.so" \
  "$SRCDIR"/*.swift \
  -Xcc -fmodule-map-file="$MODULEMAP" \
  -Xcc -I"$AGORA_PREFIX/include" \
  -Xcc -Wno-incomplete-umbrella \
  -L"$AGORA_PREFIX/lib" -lagora-base -lagora-core -lagora-dispatch \
  -lobjc -lBlocksRuntime \
  -Xlinker -rpath -Xlinker "$AGORA_PREFIX/lib"

install -d "$STDLIB_DIR/Foundation.swiftmodule"
install -m 644 "$work/Foundation.swiftmodule" \
  "$STDLIB_DIR/Foundation.swiftmodule/$HOST_TARGET.swiftmodule"
install -m 755 "$work/libFoundation.so" "$STDLIB_DIR/libFoundation.so"

echo "== checking that 'import Foundation' picks the overlay up =="
cat > "$work/bridge-check.swift" <<'EOF'
import Foundation

// The bridges are exercised the way Swift spells them: `as`/`as?` conversions.
// (A *variable* of type String does not implicitly coerce to NSString in Swift,
// on any platform; a literal does on Darwin only because its overlay redeclares
// the API surface in Swift, which this overlay does not.)
let s: NSString = "héllo 🌍" as NSString
precondition(s.length == 8, "String -> NSString")
precondition((s as String) == "héllo 🌍", "NSString -> String")

let a = ["a", "b"] as NSArray
precondition(a.count == 2 && (a as? [String]) == ["a", "b"], "Array <-> NSArray")

let d = ["k": 1] as NSDictionary
precondition((d as? [String: Int]) == ["k": 1], "Dictionary <-> NSDictionary")

let set = Set([1, 2, 3]) as NSSet
precondition((set as? Set<Int>) == [1, 2, 3], "Set <-> NSSet")

let n = 42 as NSNumber
precondition((n as? Int) == 42, "Int <-> NSNumber")

struct E: Error { var code: Int }
do { throw E(code: 7) } catch let e as NSError {
  precondition(e.code == 1, "Error -> NSError")
}

// CustomNSError is the overlay protocol the runtime consults for domain/code.
struct CE: CustomNSError {
  static var errorDomain: String { return "ce" }
  var errorCode: Int { return 9 }
  var errorUserInfo: [String: Any] { return ["k": "v"] }
}
do { throw CE() } catch let e as NSError {
  precondition((e.domain as String) == "ce" && e.code == 9,
               "CustomNSError -> NSError domain/code")
}
print("foundation overlay: ok")
EOF
if env -i PATH=/usr/bin:/bin HOME="${HOME:-/tmp}" \
     LD_LIBRARY_PATH="$AGORA_PREFIX/lib" \
     "$SWIFTC" -o "$work/bridge-check" "$work/bridge-check.swift" \
     -Xcc -fmodule-map-file="$MODULEMAP" \
     -Xcc -I"$AGORA_PREFIX/include" -Xcc -Wno-incomplete-umbrella \
     -L"$AGORA_PREFIX/lib" -Xlinker -rpath -Xlinker "$AGORA_PREFIX/lib" \
     >"$work/out" 2>&1 \
   && LD_LIBRARY_PATH="$AGORA_PREFIX/lib" "$work/bridge-check" >>"$work/out" 2>&1; then
  echo "  [ok] $(tail -1 "$work/out")"
else
  echo "  [warn] the overlay self-check failed:" >&2
  sed 's/^/         /' "$work/out" | tail -15 >&2
fi

echo "== done: overlay installed under $STDLIB_DIR =="
