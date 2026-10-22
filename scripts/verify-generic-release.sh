#!/usr/bin/env bash
#
# verify-generic-release.sh — release of an instance of a *generic* pure-Swift
# class, which is currently broken on this toolchain.
#
#   swift-toolchain/scripts/verify-generic-release.sh
#
# STATUS: RED, deliberately. This gate pins a crash found by the P2 spike's
# upstream test run (UUIDTests/DateIntervalTests/IndexPathTests all reach it):
#
#   final class Box<T> { var value: T }
#   var a: [Box<Int>] = []; a.append(Box(1)); a.removeAll()   // SIGSEGV
#
# Diagnosed: `swift_arrayDestroy` uses the element metadata's value witnesses, and
# a generically-instantiated pure-Swift class (runtime pattern class) is emitted
# with the Objective-C class witnesses, whose `destroy` is `objc_release` — while
# SWIFT-GNUSTEP-CLASS-ABI.md §2.21 deliberately makes such a pattern class *not* a
# class object (null isa). The release therefore messages a class with no dispatch
# table and dies in libobjc2's slow path.
#
# Narrowed further: a generic class WITH Objective-C ancestry (`Box<T>: NSObject`)
# releases correctly, because it *is* a class object; the pure-Swift one is not.
# The compiled IR contains no `objc_release` at all, so the Objective-C destroy is
# coming from the element type's *value witnesses* — i.e. the witness table emitted
# for a generic pure-Swift pattern class. The fix is therefore in the compiler's
# class value-witness/metadata-kind decision (Swift witnesses for a Swift class, or
# make the pattern a class object), and this script is its acceptance test: it must
# pass before the value-type test suites can run.
#
#   AGORA_PREFIX, AGORA_SWIFT_ROOT, ... as in native-env.sh

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/native-env.sh"

TOOLCHAIN="$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr"
SWIFTC="$TOOLCHAIN/bin/swiftc"
STDLIB="$TOOLCHAIN/lib/swift/linux"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/release.swift" <<'EOF'
final class GenericBox<T>: Hashable {
  var value: T
  init(_ value: T) { self.value = value }
  static func == (l: GenericBox, r: GenericBox) -> Bool { return l === r }
  func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

final class PlainBox {
  var value = 1
}

// The control: a non-generic pure-Swift class releases correctly.
var plain: [PlainBox] = []
for _ in 0..<8 { plain.append(PlainBox()) }
plain.removeAll()

// The regression: a generic pure-Swift class, released through the array's
// value witnesses.
var generic: [GenericBox<Int>] = []
for n in 0..<8 { generic.append(GenericBox(n)) }
generic.removeAll()

// And the same through an existential, which is how the FoundationEssentials
// tests reach it (AnyHashable boxes of value types).
var erased: [AnyHashable] = []
for n in 0..<8 { erased.append(AnyHashable(GenericBox(n))) }
erased.removeAll()

print("generic-release: ok")
EOF

"$SWIFTC" -O -o "$work/release" "$work/release.swift" \
  -L"$AGORA_PREFIX/lib" -lagora-base -lagora-core -lagora-dispatch -lobjc \
  -lBlocksRuntime -Xlinker -rpath -Xlinker "$AGORA_PREFIX/lib" \
  >"$work/build.log" 2>&1 || { echo "  [FAIL] build:"; tail -5 "$work/build.log"; exit 1; }

if LD_LIBRARY_PATH="$STDLIB:$AGORA_PREFIX/lib" "$work/release" >"$work/run.log" 2>&1; then
  echo "  [ok] $(tail -1 "$work/run.log")"
else
  echo "  [FAIL] releasing a generic pure-Swift class crashed:" >&2
  sed 's/^/         /' "$work/run.log" | tail -5 >&2
  echo "         see SWIFT-GNUSTEP-CLASS-ABI.md §2.21 and SWIFT-FOUNDATION-P2-SPIKE.md §8" >&2
  exit 1
fi
