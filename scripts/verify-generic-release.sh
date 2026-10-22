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
# TESTED HYPOTHESES, both negative:
#   1. the runtime picks the class value-witness table by the generic pattern's
#      `ClassFlags::UsesSwiftRefcounting`; a guard was added so a pattern without a
#      metaclass (i.e. not a class object) keeps Swift's witnesses unconditionally.
#      The gate stayed red, so that is not the path this program takes — the guard is
#      kept as a correctness measure, not as the fix (patches/0003).
#   2. the compiled IR contains no `objc_release`, so the destroy comes from a
#      witness table or layout string selected at run time.
# MEASURED (gdb, the minimal program):
#   - the generic pattern's `ClassFlags` are 2, i.e. `UsesSwiftRefcounting` IS set, so
#     the runtime picks Swift's class witnesses — hypothesis 1 was wrong on the facts,
#     not only on the path;
#   - the layout-string destroy symbols (`objcStrongDestroy`,
#     `nativeSwiftObjcStrongDestroy`) are never reached, so the layout-string engine is
#     not the destroy either;
#   - the crashing call is `swift_arrayDestroy` with a small `count` whose `self`
#     metadata sits next to `Any`/`AnyObject` metadata, i.e. the array being destroyed
#     is an *existential* one (`[Any]`/`[AnyObject]`), whose element destroy is
#     `objc_release` by design — and the element is an instance of a Swift class that
#     is not a class object.
# ABI FACT that the last probes established: `asFullMetadata()` reaches the value
# witness table at **one word before** the metadata pointer, and in the GNUstep layout
# the class object's first word is `isa` — so a class's VWT lives in the word the
# allocator has to reserve *before* the class object.  A statically emitted class gets
# that word from IRGen; a runtime-instantiated generic class gets it from
# `swift_allocateGenericClassMetadata`, and that allocation is where the two halves can
# disagree.
#
# METHOD NOTE: the gdb readings above were taken against the installed libswiftCore,
# which is `-O` with no debug info; breakpoints land after the prologue, so argument
# registers are no longer trustworthy.  Instead the runtime now carries an env-gated
# diagnostic (`SWIFT_LAYOUT2_DIAG=1`): `initializeClassMetadataFromPattern` prints the
# pattern's flags, bounds and the VWT word before the class, and `swift_arrayDestroy`
# prints its `self`, `self->getKind()`, the witness table, the `destroy` symbol and its
# caller.  What it showed:
#
#   [pattern] meta=0x... flags=2 neg=3 pos=25, vwt after header init = Bo
#   [arrayDestroy] caller=_ContiguousArrayStorage.deinit, count=4,
#                  self=0x... kind=771 (= 0x303, a witness-table flags word)
#
# i.e. the class's own witnesses are right, and the `self` the array storage passes to
# `swift_arrayDestroy` is **not the element class's metadata** — it reads like a value
# witness table.  Printing its words settles that: `{0x303, 0x80000000, <fnptr>, ...}`
# is a witness-table header (flags, size/stride, destroy...), and it lives in the
# stdlib's static data, ~1.2 MB away from the pattern class metadata (0x...33d8 vs
# 0x...8018).  So `Element.self` inside `_ContiguousArrayStorage.deinit` is reading the
# element's **value witness table**, not its metadata: the generic-argument slot of a
# layout-2 class is off by one word on the read (or the write) side, and the word it
# lands on is the VWT that precedes a metadata object.
#
# That is the bug: **generic-argument access for a runtime-instantiated class at layout
# 2**, not the class pattern, the VWT choice, the layout string, or array storage.
# Next: print the descriptor's `getGenericArgumentOffset()` in `installGenericArguments`
# (the write side) next to the offset IRGen uses when a class method reads `Element.self`
# (the read side); whichever differs by one word is the fix, in `Metadata.h`'s
# `getNonResilientImmediateMembersOffset()` or in IRGen's class layout.
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
