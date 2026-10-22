#!/usr/bin/env bash
#
# verify-generic-release.sh — release of an instance of a *generic* pure-Swift
# class, which used to crash on this toolchain.
#
#   swift-toolchain/scripts/verify-generic-release.sh
#
# STATUS: GREEN.  The three programs below were RED until this round; they are
# the reduction of the crash the P2 spike's upstream test run found
# (UUIDTests/DateIntervalTests/IndexPathTests all reached it):
#
#   final class Box<T> { var value: T }
#   var a: [Box<Int>] = []; a.append(Box(1)); a.removeAll()   // SIGSEGV
#
# ROOT CAUSE (two defects, both in the layout-2 class ABI):
#
# 1. **A runtime-pattern class with no Objective-C ancestry was not a class
#    object.**  The standard library does not store class elements with the
#    element's own storage type: `getContiguousArrayStorageType(for:)` returns
#    `_ContiguousArrayStorage<AnyObject>` whenever the element is a class (a
#    bridging optimization since SwiftStdlib 5.7), and the array's `deinit`
#    therefore destroys its elements with `AnyObject`'s destroy, which is
#    `objc_release`.  A pattern class without an `isa` has no dispatch table to
#    inherit `-release` from, so libobjc2's slow path faulted.  The same send
#    arrives from ordinary Objective-C code: `NSMutableArray().add(Box(1))`
#    retains through libobjc2.  Every pattern class is now a GNUstep class
#    object (IRGen `isGNUstepPatternClassObject`), so "a Swift class instance"
#    has one answer at run time.
#
# 2. **A pattern class with Objective-C ancestry got Swift's value witnesses.**
#    `initializeClassMetadataFromPattern` chose the class's value-witness table
#    with "does the pattern carry a metaclass", read as
#    `pattern->MetaclassObjectOffset != 0` — which is **zero** in the GNUstep
#    layout for the normal case (the metaclass is the first object in the
#    extra-data pattern).  A `Box<Int>: NSObject` therefore got Swift's `Bo`
#    witnesses with `Flags == 0`, so retaining it ran Swift's native refcount
#    increment over the word that holds its first stored property.  The choice
#    now follows `ClassFlags::UsesSwiftRefcounting`, like every other layout.
#
# The old note that "the compiled IR contains no `objc_release`, so the destroy
# comes from the value witnesses" was half right: the destroy *did* come from a
# witness table, but from the **storage's** (`_ContiguousArrayStorage<AnyObject>`)
# rather than from the element class's own.  That is why probing the element
# class's flags, its VWT and the layout-string engine all came back negative.
#
# What this script checks (each is a separate failure mode):
#   * `[GenericBox<Int>]` released through `_ContiguousArrayStorage<AnyObject>`;
#   * the same through `[AnyHashable]` (how the FoundationEssentials suites
#     reach it);
#   * a generic class instance retained and released by `NSMutableArray`;
#   * a nested instantiation (`Box<Box<Int>>`), which retains a generic class
#     instance through its value witnesses — the second defect above.
#
#   GATE_SWIFTC   the compiler to use (default: the installed toolchain; native-env
#                 exports SWIFTC for its own builds, so it is not the override)
#   AGORA_PREFIX, AGORA_SWIFT_ROOT, ... as in native-env.sh

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/native-env.sh"

TOOLCHAIN="$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr"
COMPILER="${GATE_SWIFTC:-${SWIFTC_LAYOUT2:-$TOOLCHAIN/bin/swiftc}}"
STDLIB="$TOOLCHAIN/lib/swift/linux"
PROBE_MODULEMAP="$AGORA_ROOT/swift-interop-probe/agora-modules/module.modulemap"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/release.swift" <<'EOF'
import Foundation

final class GenericBox<T>: Hashable {
  var value: T
  init(_ value: T) { self.value = value }
  static func == (l: GenericBox, r: GenericBox) -> Bool { return l === r }
  func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

final class PlainBox {
  var value = 1
}

var problems: [String] = []
func expect(_ condition: Bool, _ what: String) {
  if !condition { problems.append(what) }
}

// The control: a non-generic pure-Swift class releases correctly.
var plain: [PlainBox] = []
for _ in 0..<8 { plain.append(PlainBox()) }
plain.removeAll()

// A generic pure-Swift class, released through the array's value witnesses.
var generic: [GenericBox<Int>] = []
for n in 0..<8 { generic.append(GenericBox(n)) }
expect(generic.count == 8, "generic array built")
generic.removeAll()

// The same through an existential, which is how the FoundationEssentials
// tests reach it (AnyHashable boxes of value types).
var erased: [AnyHashable] = []
for n in 0..<8 { erased.append(AnyHashable(GenericBox(n))) }
erased.removeAll()

// Objective-C retains what it is given: `-[NSMutableArray addObject:]` is
// objc_retain, and `-removeAllObjects` is objc_release.
do {
  let array = NSMutableArray()
  for n in 0..<8 { array.add(GenericBox(n)) }
  expect(array.count == 8, "NSMutableArray count through objc retain")
  let first = array.object(at: 0) as? GenericBox<Int>
  expect(first?.value == 0, "element comes back through the ObjC path")
  array.removeAllObjects()
}

// A nested instantiation: `Box<Box<Int>>` stores a generic class instance in a
// stored property, which retains it through the *element's* value witnesses.
// With Swift's witnesses on an Objective-C-refcounted class, that retain lands
// in the word holding `value` (the second defect above).
final class Nest<T> {
  var value: T
  var marker: Int = 7
  init(_ value: T) { self.value = value }
}
let inner = Nest(42)
let outer = Nest(inner)
expect(inner.value == 42, "the inner value survives the retain")
expect(outer.value.value == 42, "nested generic value reads back")
expect(outer.marker == 7, "fields after a nested retain are intact")

// Same shape with an Objective-C ancestor, allocated through objc_allocWithZone.
final class ObjBox<T>: NSObject {
  var value: T
  init(_ value: T) { self.value = value; super.init() }
}
let objInner = ObjBox(7)
let objOuter = ObjBox(objInner)
expect(objOuter.value.value == 7, "nested ObjC-ancestry generic value reads back")

precondition(problems.isEmpty,
             "generic-release: \(problems.count) failure(s): \(problems)")
print("generic-release: ok")
EOF

run_case() {
  local name="$1"; local bin="$2"; shift 2
  if ! "$COMPILER" "$@" -o "$work/$bin" "$work/release.swift" \
      -Xcc -fmodule-map-file="$PROBE_MODULEMAP" \
      -Xcc -I"$AGORA_PREFIX/include" -Xcc -Wno-incomplete-umbrella \
      -L"$AGORA_PREFIX/lib" -lagora-base -lagora-core -lagora-dispatch \
      -lobjc -lBlocksRuntime \
      -Xlinker -rpath -Xlinker "$AGORA_PREFIX/lib" \
      >"$work/build.log" 2>&1; then
    echo "  [FAIL] $name: build failed:" >&2
    tail -5 "$work/build.log" >&2
    return 1
  fi
  if LD_LIBRARY_PATH="$STDLIB:$AGORA_PREFIX/lib" "$work/$bin" \
      >"$work/run.log" 2>&1; then
    printf '  [ok]   %s: %s\n' "$name" "$(tail -1 "$work/run.log")"
  else
    echo "  [FAIL] $name" >&2
    sed 's/^/         /' "$work/run.log" | tail -5 >&2
    echo "         see SWIFT-PORT-HANDOFF.md §2.30" >&2
    return 1
  fi
}

echo "== generic-release gate: releasing generic class instances =="
failures=0
run_case "-Onone" release-onone -Onone || failures=$((failures + 1))
run_case "-O" release-opt -O || failures=$((failures + 1))

if [[ "$failures" -ne 0 ]]; then
  echo "generic-release gate: $failures check(s) failed" >&2
  exit 1
fi
echo
echo "generic-release gate: ok (array destroy, NSMutableArray retain/release,"
echo "                           nested instantiation)"
