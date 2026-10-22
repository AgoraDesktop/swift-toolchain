#!/usr/bin/env bash
#
# Stage S4 gate of SWIFT-GNUSTEP-CLASS-ABI.md: generic classes under the GNUstep
# class layout.
#
#   swift-toolchain/scripts/verify-generic-abi.sh
#
# A generic class's metadata is *built at runtime* from a pattern, so unlike the
# fixed class of the S1 gate it cannot be validated with a frontend-only
# compiler
# alone: the runtime that fills in `Flags`, `InstanceSize`, the field-offset
# vector and the generic arguments must agree with the compiler's header layout.
# This gate therefore runs against the layout-2 *stdlib* built by
# build-layout2-stdlib.sh, and checks that the binary really linked it.
#
# What is covered:
#   * a generic class instantiated with Int, String and a tuple (instance size
#     is what exposed the mixed-ABI bug: 8-byte elements "worked", 16-byte ones
#     corrupted the heap);
#   * several parameters, a class-typed stored property, a generic subclass with
#     a vtable override;
#   * Array/Set/Dictionary of a generic class, String operations, existentials,
#     `AnyObject` boxing, dynamic casts between specializations, Mirror;
#   * `deinit` of a generic instance (refcounting goes through the Swift path
#     only when the runtime recognizes the metadata as Swift's, i.e. through
#     ABIVersion in this layout).
#
# Exits non-zero if any check fails.
#
#   AGORA_PREFIX       Agora install prefix (default ../../build-prefix)
#   SWIFTC_LAYOUT2     layout-2 wrapper (computed from the build tree)
#   SKIP_BUILD=1       do not rebuild the layout-2 compiler + stdlib

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
agora="$here"
source "$agora/swift-toolchain/scripts/native-env.sh"

AGORA_PREFIX="${AGORA_PREFIX:-$agora/build-prefix}"
SWIFT_BUILD_SUBDIR="${SWIFT_BUILD_SUBDIR:-agora-${AGORA_TARGET_TRIPLE}}"
BUILD_DIR="$OPEN_SWIFT_SOURCE_ROOT/build/$SWIFT_BUILD_SUBDIR/swift-$AGORA_TARGET_TRIPLE"
SWIFTC_LAYOUT2="${SWIFTC_LAYOUT2:-$BUILD_DIR/bin/swiftc-layout2-stdlib}"
# Override when running a gate against the *installed* toolchain, e.g.
#   STDLIB_DIR=~/.agora-swift/toolchain/usr/lib/swift
STDLIB_DIR="${STDLIB_DIR:-$BUILD_DIR/lib/swift}"

if [[ "${SKIP_BUILD:-0}" != "1" || ! -x "$SWIFTC_LAYOUT2" ]]; then
  echo "== layout-2 compiler + stdlib =="
  "$agora/swift-toolchain/scripts/build-layout2-stdlib.sh"
  echo
fi

if [[ ! -x "$SWIFTC_LAYOUT2" ]]; then
  echo "error: no layout-2 swiftc at $SWIFTC_LAYOUT2" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
check() {
  local name="$1"; shift
  if "$@" >"$work/out" 2>&1; then
    printf '  [ok]   %s\n' "$name"
  else
    printf '  [FAIL] %s\n' "$name"
    sed 's/^/         /' "$work/out" | head -25
    failures=$((failures + 1))
  fi
}

# Programs find Agora's libraries through the RUNPATH the driver records; the
# Swift stdlib on that RUNPATH must be the build tree's, not the installed one.
export LD_LIBRARY_PATH="$AGORA_PREFIX/lib"

cat > "$work/generics.swift" <<'EOF'
// One class hierarchy that forces every interesting generic-metadata path.
protocol Named {
  func describe() -> String
}

class Box<T>: Named {
  var value: T
  var tag: Int
  init(_ value: T, tag: Int = 7) {
    self.value = value
    self.tag = tag
  }
  func describe() -> String { "Box(\(value), \(tag))" }
  deinit { BoxDeinitCount.count += 1 }
}

final class BoxDeinitCount {
  static var count = 0
}

class Pair<A, B> {
  var first: A
  var second: B
  init(_ first: A, _ second: B) {
    self.first = first
    self.second = second
  }
}

// Class-typed stored property: the field's layout depends on the generic
// argument's metadata, not on a static size.
class Holder<T> {
  var box: Box<T>
  var callback: (T) -> T
  init(_ value: T) {
    self.box = Box(value)
    self.callback = { $0 }
  }
}

// Generic inheritance plus a vtable override: the subclass's vtable entries are
// installed when its metadata is completed.
class Tagged<T>: Box<T> {
  override func describe() -> String { "Tagged(" + super.describe() + ")" }
}

// Monomorphized through a protocol existential.
func describeAll(_ items: [any Named]) -> [String] { items.map { $0.describe() } }

// Exercises Array's own generic classes (_ContiguousArrayStorage<...>), the
// runtime's prespecialized generic metadata, hashing and string interning.
var failures: [String] = []
func expect(_ condition: Bool, _ what: String) {
  if !condition { failures.append(what) }
}

let intBox = Box(42)
let stringBox = Box("héllo 🌍")
let tupleBox = Box((1, 2, 3))
let pair = Pair("x", 3.5)
let holder = Holder("nested")
let tagged = Tagged(1, tag: 9)

expect(intBox.value == 42, "Int payload")
expect(stringBox.value == "héllo 🌍", "String payload")
expect(tupleBox.value == (1, 2, 3), "tuple payload")
expect(pair.first == "x" && pair.second == 3.5, "two parameters")
expect(holder.box.value == "nested", "class-typed stored property")
expect(holder.callback("x") == "x", "closure property")
expect(tagged.describe() == "Tagged(Box(1, 9))", "generic subclass override")
expect(tagged is Box<Int>, "isKind on a generic subclass")
expect(intBox.describe() == "Box(42, 7)", "method on a generic instance")

// Deinit of a generic instance runs in a scope.
do {
  _ = Box(0)
  _ = Box("scoped")
}
expect(BoxDeinitCount.count == 2, "deinit of generic instances (\(BoxDeinitCount.count))")

// Collections of a generic class, plus String/Set/Dictionary.
let boxes = [intBox, Box(1), Box(2)]
expect(boxes.map { $0.value } == [42, 1, 2], "Array of a generic class")
expect(Set(["a", "b", "a"]).count == 2, "Set")
var dict: [String: Box<Int>] = ["k": Box(9)]
dict["k2"] = Box(10)
expect(dict.values.map { $0.value }.sorted() == [9, 10], "Dictionary of a generic class")
expect(String(repeating: "ab", count: 3) == "ababab", "String")

// Existentials and dynamic casts between specializations.
expect(describeAll([intBox, stringBox]) == ["Box(42, 7)", "Box(héllo 🌍, 7)"],
       "existential array")
let anyBox: Any = intBox
expect((anyBox as? Box<Int>)?.value == 42, "cast to the same specialization")
expect((anyBox as? Box<String>) == nil, "cast to another specialization")

// AnyObject boxing of a generic instance (the box must retain/release through
// the Swift refcounting path, not objc_release).
let boxed: AnyObject = intBox
expect(boxed === intBox, "AnyObject box")

// Reflection reads the generic arguments from the metadata.
let mirror = Mirror(reflecting: intBox)
expect(mirror.children.contains { $0.label == "value" }, "Mirror children")
expect(String(describing: type(of: intBox)) == "Box<Int>", "type name")

// A pile of instantiations, to catch metadata-cache/locking mistakes.
var total = 0
for i in 0..<200 {
  total += Box(i).value
  _ = Box("s\(i)")
  _ = Pair(i, Double(i))
}
expect(total == 19900, "many instantiations")

// A *non-generic* class with a generic Swift superclass.  Its metadata is
// completed at run time like a generic class's, but the class is not itself
// generic, so its metadata object - and its metaclass - are emitted statically.
// It is registered with libobjc2 like any other class object; the superclass it
// names is one too, since every pattern class is (see below), which is what
// makes the registration resolvable.
class FixedBase<T> {
  var field: T
  init(_ field: T) { self.field = field }
}
class FixedSub: FixedBase<Int> {
  init() { super.init(41) }
}
class FixedGrandSub: FixedSub {
  init(marker: Int) { self.marker = marker; super.init() }
  var marker: Int = 0
}
let fixedSub = FixedSub()
let fixedGrand = FixedGrandSub(marker: 3)
expect(fixedSub.field == 41, "fixed class with a generic superclass")
expect(fixedGrand.field == 41 && fixedGrand.marker == 3,
       "fixed class chain with generic ancestry")
expect(String(describing: type(of: fixedSub)) == "FixedSub",
       "fixed generic-ancestry class name")

// Every runtime-instantiated class is a GNUstep class object, whatever its
// ancestry: the metadata's first word is `isa` (a metaclass), not the
// `MetadataKind::Class` placeholder (0).  This is the invariant that lets
// Objective-C code - including the stdlib's own `_ContiguousArrayStorage<AnyObject>`
// element destroy - retain and release a Swift class instance with
// `objc_retain`/`objc_release`.  verify-generic-release.sh is the behavioural
// gate; this is the shape check.
func metadataFirstWord(of type: Any.Type) -> UInt {
  return unsafeBitCast(type, to: UnsafePointer<UInt>.self)[0]
}
expect(metadataFirstWord(of: Box<Int>.self) != 0,
       "a pure Swift generic class is a class object")
expect(metadataFirstWord(of: Box<String>.self) != 0,
       "every instantiation is a class object")
expect(metadataFirstWord(of: FixedSub.self) != 0,
       "a generic-ancestry fixed class is a class object")

precondition(failures.isEmpty,
             "generic ABI: \(failures.count) failure(s): \(failures)")
print("generics: ok")
EOF

build_and_run() {
  local bin="$1"; shift
  "$SWIFTC_LAYOUT2" -L"$AGORA_PREFIX/lib" -o "$bin" "$work/generics.swift" "$@" || return 1
  # The linked stdlib must be the layout-2 one from the build tree.
  local resolved
  resolved="$(ldd "$bin" | awk '/libswiftCore\.so/ { print $3 }')"
  if [[ "$resolved" != "$STDLIB_DIR/linux/libswiftCore.so" ]]; then
    echo "linked against '$resolved', expected '$STDLIB_DIR/linux/libswiftCore.so'"
    return 1
  fi
  "$bin"
}

echo "== S4 gate: generic classes at the GNUstep class layout =="
check "generic metadata layout (-Onone)" build_and_run "$work/generics-onone"
check "generic metadata layout (-O)" build_and_run "$work/generics-opt" -O

# The layout-2 stdlib is what makes the gate meaningful; say so loudly if the
# compiler under test is silently using a non-layout-2 one.
# NB: no `grep -q` here - under `set -o pipefail` grep's early exit makes `nm`
# die of SIGPIPE and turns the pipeline into a failure.
if ! nm "$STDLIB_DIR/linux/libswiftCore.so" 2>/dev/null | grep '_OBJC_METACLASS__TtCs12_SwiftObject' >/dev/null; then
  echo "  [FAIL] $STDLIB_DIR is not a layout-2 build"
  failures=$((failures + 1))
else
  echo "  [ok]   the stdlib carries the GNUstep root metaclass"
fi

echo
if (( failures == 0 )); then
  echo "S4 gate: ok (generic classes, collections, casts, deinit)"
  exit 0
fi
echo "S4 gate: $failures check(s) failed"
exit 1
