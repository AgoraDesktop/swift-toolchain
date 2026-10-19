#!/usr/bin/env bash
#
# Stage S4b gate of SWIFT-GNUSTEP-CLASS-ABI.md: a *generic* class that inherits
# an imported Objective-C class is a real GNUstep class object.
#
#   swift-toolchain/scripts/verify-generic-objc-abi.sh
#
# S4 proved generic classes that stay Swift-only (their metadata is not a class
# object).  A generic class cannot have `@objc` members, but it *can* inherit an
# imported Objective-C class, and then Swift allocates instances through
# `objc_allocWithZone` and sends `-init` through the Objective-C runtime.  That
# needs three things the other gates do not exercise:
#
#   * a GNUstep metaclass in the generic metadata pattern, and the class
#     registered with libobjc2 when its instance layout is complete;
#   * a unique Objective-C name per instantiation (`Box<Int>` and `Box<String>`
#     are two different classes, and libobjc2 keys its class table by name);
#   * the class's method list, because the stored-property initializers run
#     behind `objc_msgSend(obj, init)` and a `-dealloc` has to exist for release.
#
# Runs against the layout-2 compiler *and* stdlib built by
# build-layout2-stdlib.sh, like the S4 gate.
#
#   AGORA_PREFIX       Agora install prefix (default ../../build-prefix)
#   SWIFTC_LAYOUT2     layout-2 wrapper (computed from the build tree)
#   SKIP_BUILD=1       do not rebuild the layout-2 compiler + stdlib

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
agora="$here"
source "$agora/swift-toolchain/scripts/native-env.sh"

AGORA_PREFIX="${AGORA_PREFIX:-$agora/build-prefix}"
BOOTSTRAP_CLANG="${BOOTSTRAP_CLANG:-$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/bin/clang}"
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

export LD_LIBRARY_PATH="$AGORA_PREFIX/lib"

cat > "$work/s4b.swift" <<'EOF'
import Foundation

// A generic class with an imported Objective-C ancestor: allocated by
// objc_allocWithZone, initialized by -init (a Swift thunk in the class's method
// list), released by the Objective-C runtime.
class Box<T>: NSObject {
  var value: T
  var tag: Int = 7
  init(_ value: T) {
    self.value = value
    super.init()
  }
}

// A generic subclass of a generic Objective-C class: both are class objects and
// the metaclass chain has to line up.
class Sub<T>: Box<T> {
  var extra: T
  init(_ value: T, _ extra: T) {
    self.extra = extra
    super.init(value)
  }
}

// The initializer of this one is reached only if the class's method list is in
// the registered class object: `Box<Int>()` is `objc_allocWithZone` followed by
// `objc_msgSend(obj, init)`.
class Defaults<T>: NSObject {
  var x: Int = 42
  var y: String = "dflt"
  var t: T?
  override init() { super.init() }
}

// -dealloc must exist on the class object, and (S5, verify-refcount-abi.sh)
// actually run the destructor when libobjc2 release sends its typed selector.
final class Counters { static var deinits = 0 }

class WithDeinit<T>: NSObject {
  var v: T
  init(_ v: T) { self.v = v; super.init() }
  deinit { Counters.deinits += 1 }
}

// C-side views of an object's class, so the checks below do not depend on how
// Swift imports the Objective-C runtime's types.
@_silgen_name("s4b_class_of")
func s4bClassOf(_ object: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer

@_silgen_name("s4b_class_name")
func s4bClassName(_ object: UnsafeMutableRawPointer) -> UnsafePointer<CChar>

@_silgen_name("s4b_superclass")
func s4bSuperclass(_ cls: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?

@_silgen_name("s4b_instance_size")
func s4bInstanceSize(_ cls: UnsafeMutableRawPointer) -> Int

@_silgen_name("s4b_nsobject_class")
func s4bNSObjectClass() -> UnsafeMutableRawPointer

@_silgen_name("s4b_check_class")
func s4bCheckClass(_ cls: UnsafeMutableRawPointer,
                   _ super: UnsafeMutableRawPointer,
                   _ prefix: UnsafePointer<CChar>?,
                   _ sendInit: Int32) -> Int32

func pointer(to object: AnyObject) -> UnsafeMutableRawPointer {
  Unmanaged.passUnretained(object).toOpaque()
}

func className(_ object: AnyObject) -> String {
  String(cString: s4bClassName(pointer(to: object)))
}

var problems: [String] = []
func expect(_ condition: Bool, _ what: String) {
  if !condition { problems.append(what) }
}

let i = Box(42)
let s = Box("héllo")
let t = Box((1, 2))
let sub = Sub(1, 2)
let defaults = Defaults<Int>()
let deinitBox = WithDeinit("x")

// Values through the normal Swift path.
expect(i.value == 42 && i.tag == 7, "Int payload")
expect(s.value == "héllo", "String payload")
expect(t.value == (1, 2), "tuple payload")
expect(sub.value == 1 && sub.extra == 2, "generic subclass payload")
expect(defaults.x == 42 && defaults.y == "dflt" && defaults.t == nil,
       "stored-property initializers ran through -init")

// Each instantiation is its own class object, with its own name.
expect(className(i) != className(s), "Box<Int> and Box<String> have distinct names")
expect(className(i) != className(t), "Box<Int> and Box<(Int, Int)> have distinct names")
expect(className(i).contains("Box"), "the mangled name mentions the class")

// libobjc2 knows the classes by those names, and the hierarchy is wired up.
let intClass = s4bClassOf(pointer(to: i))
let objcClass = s4bNSObjectClass()
expect(s4bSuperclass(intClass) == objcClass, "Box<Int> inherits NSObject")
expect(s4bSuperclass(s4bClassOf(pointer(to: sub))) == intClass,
       "Sub<Int> inherits Box<Int>")
expect(i.isKind(of: NSObject.self), "isKind(of: NSObject)")
expect(sub.isKind(of: Box<Int>.self), "isKind(of: Box<Int>)")

// The class objects have the shape libobjc2 requires, and -init/-dealloc are in
// their method lists (the C helper also round-trips the name through
// objc_getClass and allocates/inits through the Objective-C runtime).
expect(s4bCheckClass(s4bClassOf(pointer(to: i)), objcClass,
                     className(i), 0) == 0, "C-side class object shape (Box<Int>)")
expect(s4bCheckClass(s4bClassOf(pointer(to: s)), objcClass,
                     className(s), 0) == 0, "C-side class object shape (Box<String>)")
expect(s4bCheckClass(s4bClassOf(pointer(to: deinitBox)), objcClass,
                     className(deinitBox), 0) == 0, "C-side class object shape (WithDeinit)")
expect(s4bCheckClass(s4bClassOf(pointer(to: defaults)), objcClass,
                     className(defaults), 1) == 0,
       "C-side alloc+init through the ObjC runtime (Defaults)")

// Instance sizes: NSObject is 8 bytes, then the Swift fields.
expect(s4bInstanceSize(intClass) == 24, "Box<Int> instance size is 24")

// The destructor runs when the last reference dies (S5: typed `dealloc`).
// Scoped to a function so the release happens before the count is read.
func dropOneDeinitBox() {
  let box = WithDeinit<Int>(0)
  _ = box.v
}
let deinitsBefore = Counters.deinits
dropOneDeinitBox()
expect(Counters.deinits == deinitsBefore + 1,
       "deinit of a generic ObjC-ancestry class did not run")

// Same instantiation, same class object.
let i2 = Box(7)
expect(s4bClassOf(pointer(to: i2)) == intClass, "one class object per instantiation")
expect(i2.value == 7, "second instance is independent")

// Owning containers go through the ObjC retain/release path.
let array = NSMutableArray()
array.add(i)
array.add(sub)
expect(array.count == 2, "NSMutableArray count")
expect(s4bClassOf(pointer(to: array.object(at: 0) as AnyObject)) == intClass,
       "container identity")

// Class-typed generic argument (nested instantiation).
let nested = Box(i)
expect(nested.value.value == 42, "nested generic instance")
expect(className(nested) != className(i), "nested instantiation has its own name")

precondition(problems.isEmpty,
             "S4b: \(problems.count) failure(s): \(problems)")
print("s4b: ok")
EOF

cat > "$work/c_check.c" <<'EOF'
#include <objc/runtime.h>
#include <stddef.h>
#include <string.h>

/* Returns 0 when the class object looks like a registered GNUstep class whose
   method list reaches the Swift initializer. */
void *s4b_class_of(void *object) {
  return object_getClass((id)object);
}

const char *s4b_class_name(void *object) {
  Class cls = object_getClass((id)object);
  const char *name = cls ? class_getName(cls) : NULL;
  return name ? name : "";
}

void *s4b_superclass(void *clsRaw) {
  return class_getSuperclass((Class)clsRaw);
}

long s4b_instance_size(void *clsRaw) {
  return (long)class_getInstanceSize((Class)clsRaw);
}

void *s4b_nsobject_class(void) {
  return objc_getClass("NSObject");
}

int s4b_check_class(void *clsRaw, void *superRaw, const char *prefix,
                    int sendInit) {
  Class cls = (Class)clsRaw;
  Class super = (Class)superRaw;
  if (!cls || !super) return 1;

  const char *name = class_getName(cls);
  if (!name) return 2;
  if (prefix && strncmp(name, prefix, strlen(prefix)) != 0) return 3;
  if ((Class)objc_getClass(name) != cls) return 4;
  if (class_getSuperclass(cls) != super) return 5;

  SEL init = sel_registerName("init");
  SEL dealloc = sel_registerName("dealloc");
  if (!class_respondsToSelector(cls, init)) return 6;
  if (!class_respondsToSelector(cls, dealloc)) return 7;
  if (class_getInstanceSize(cls) < sizeof(void *)) return 8;

  /* The class is not a meta class, but its isa is. */
  if (class_isMetaClass(cls)) return 9;
  if (!class_isMetaClass(object_getClass((id)cls))) return 10;

  if (!sendInit)
    return 0;

  /* Allocate and initialize through the Objective-C runtime.  Only for a class
     that actually implements -init (a class with a designated init(_:) gets
     Swift's trapping unimplemented-init stub in its method list instead). */
  id object = class_createInstance(cls, 0);
  if (!object) return 11;
  if ((Class)object_getClass(object) != cls) return 12;
  IMP initImp = objc_msg_lookup(object, init);
  if (!initImp) return 13;
  id initialized = ((id(*)(id, SEL))initImp)(object, init);
  if (!initialized) return 14;
  if ((Class)object_getClass(initialized) != cls) return 15;

  return 0;
}
EOF

echo "== S4b gate: generic classes with an Objective-C ancestor =="

build_and_run() {
  local name="$1"; shift
  "$SWIFTC_LAYOUT2" -L"$AGORA_PREFIX/lib" \
    -Xcc -fmodule-map-file="$agora/swift-interop-probe/agora-modules/module.modulemap" \
    -Xcc -I"$AGORA_PREFIX/include" \
    -Xcc -Wno-incomplete-umbrella \
    -lagora-base -lagora-core -lagora-dispatch -lobjc -lBlocksRuntime \
    -Xlinker -rpath -Xlinker "$AGORA_PREFIX/lib" \
    -o "$work/$name" "$work/s4b.swift" "$work/c_check.o" "$@" || return 1

  local resolved
  resolved="$(ldd "$work/$name" | awk '/libswiftCore\.so/ { print $3 }')"
  if [[ "$resolved" != "$STDLIB_DIR/linux/libswiftCore.so" ]]; then
    echo "linked against '$resolved', expected '$STDLIB_DIR/linux/libswiftCore.so'"
    return 1
  fi
  "$work/$name"
}

"$BOOTSTRAP_CLANG" -I"$AGORA_PREFIX/include" -c "$work/c_check.c" \
  -o "$work/c_check.o" || { echo "error: C helper failed to compile" >&2; exit 1; }

check "generic ObjC class object (-Onone)" build_and_run s4b-onone
check "generic ObjC class object (-O)" build_and_run s4b-opt -O

# ---------------------------------------------------------------------------
# S4c: a *resilient* class (library evolution) with an imported ObjC ancestor.
#
# Its metadata is not emitted by the compiler at all: `_swift_relocateClassMetadata`
# builds it at runtime from a pattern.  The class is not generic, so it needs the
# static-side machinery of S1 (a metaclass, the class-side fields) while being
# registered like the dynamic class of S4b.  A pure Swift resilient class (no
# ObjC ancestor) must keep working without any class object, and a class whose
# superclass is itself resilient exercises the chain.
# ---------------------------------------------------------------------------

cat > "$work/ResilientLib.swift" <<'EOF'
import Foundation

// Fixed layout in this module, but opaque to clients: a client subclass gets
// the Resilient strategy (its metadata is relocated at runtime).
open class Base: NSObject {
  public var b: Int = 1
  public override init() { super.init() }
}

// The same without Objective-C ancestry: the client subclass is relocated too,
// but must stay a plain Swift metadata object.
open class PureBase {
  public var p: Int = 10
  public init() {}
}
EOF

cat > "$work/resilient.swift" <<'EOF'
import Foundation
import ResilientLib

final class Counters { static var deinits = 0 }

class Sub: Base {
  var v: Int = 2
  deinit { Counters.deinits += 1 }
}

class GrandSub: Sub {
  var w: Int = 3
}

class Pure: PureBase {
  var q: Int = 20
}

@_silgen_name("s4c_dump")
func s4cDump(_ object: UnsafeMutableRawPointer)

@_silgen_name("s4b_class_of")
func s4bClassOf(_ object: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer

@_silgen_name("s4b_class_name")
func s4bClassName(_ object: UnsafeMutableRawPointer) -> UnsafePointer<CChar>

@_silgen_name("s4b_superclass")
func s4bSuperclass(_ cls: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?

@_silgen_name("s4b_instance_size")
func s4bInstanceSize(_ cls: UnsafeMutableRawPointer) -> Int

@_silgen_name("s4b_nsobject_class")
func s4bNSObjectClass() -> UnsafeMutableRawPointer

@_silgen_name("s4b_check_class")
func s4bCheckClass(_ cls: UnsafeMutableRawPointer,
                   _ super: UnsafeMutableRawPointer,
                   _ prefix: UnsafePointer<CChar>?,
                   _ sendInit: Int32) -> Int32

func pointer(to object: AnyObject) -> UnsafeMutableRawPointer {
  Unmanaged.passUnretained(object).toOpaque()
}

var problems: [String] = []
func expect(_ condition: Bool, _ what: String) {
  if !condition { problems.append(what) }
}

let sub = Sub()
let grand = GrandSub()
let pure = Pure()
let base = Base()

// Field offsets in a resilient class are relocated at runtime; the initializer
// must land them where the accessors read.
expect(sub.b == 1 && sub.v == 2, "resilient ObjC class fields")
expect(grand.b == 1 && grand.v == 2 && grand.w == 3, "resilient class chain")
expect(pure.p == 10 && pure.q == 20, "resilient pure-Swift class fields")
expect(sub.isKind(of: Base.self), "isKind(of: Base)")
expect(grand.isKind(of: Sub.self), "isKind(of: Sub)")

// The relocated ObjC class is registered, so libobjc2 knows its name and shape.
let subClass = s4bClassOf(pointer(to: sub))
let objcClass = s4bNSObjectClass()
expect(String(cString: s4bClassName(pointer(to: sub))) !=
       String(cString: s4bClassName(pointer(to: grand))),
       "distinct names for the resilient chain")
expect(s4bSuperclass(subClass) != nil, "Sub has a superclass")
expect(s4bInstanceSize(subClass) == 24, "Sub instance size is 24")
expect(s4bInstanceSize(s4bClassOf(pointer(to: grand))) == 32,
       "GrandSub instance size is 32")
expect(s4bCheckClass(subClass, s4bClassOf(pointer(to: base)),
                     s4bClassName(pointer(to: sub)), 0) == 0,
       "C-side resilient class object shape (Sub)")
expect(s4bCheckClass(s4bClassOf(pointer(to: grand)), subClass,
                     s4bClassName(pointer(to: grand)), 0) == 0,
       "C-side resilient class object shape (GrandSub)")

s4cDump(pointer(to: sub))
s4cDump(pointer(to: grand))

// S5: a relocated class's method list is installed on the runtime-built
// metadata, and its typed `dealloc` record is what libobjc2's release sends.
// Scope the allocation to a function so the release runs before the count.
func dropOneSub() {
  let s = Sub()
  _ = s.v
}
let deinitsBefore = Counters.deinits
dropOneSub()
expect(Counters.deinits == deinitsBefore + 1,
       "deinit of a resilient ObjC-ancestry class did not run")

precondition(problems.isEmpty,
             "S4c: \(problems.count) failure(s): \(problems)")
print("s4c: ok")
EOF

cat > "$work/c_check2.c" <<'EOF'
#include <objc/runtime.h>
#include <stdio.h>
#include <string.h>

void s4c_dump(void *o) {
  Class cls = object_getClass((id)o);
  Class sup = class_getSuperclass(cls);
  printf("  %s size=%zu super=%s meta=%d", class_getName(cls),
         (size_t)class_getInstanceSize(cls), sup ? class_getName(sup) : "nil",
         class_isMetaClass(object_getClass((id)cls)));
  const char *names[] = {"w", "v", "b", "q"};
  for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
    Ivar iv = class_getInstanceVariable(cls, names[i]);
    if (iv) printf(" %s@%ld", names[i], (long)ivar_getOffset(iv));
  }
  printf("\n");
}
EOF

"$BOOTSTRAP_CLANG" -I"$AGORA_PREFIX/include" -c "$work/c_check2.c" \
  -o "$work/c_check2.o" || { echo "error: C helper failed to compile" >&2; exit 1; }

build_resilient() {
  local opt="$1"; shift
  "$SWIFTC_LAYOUT2" -emit-module -emit-library -enable-library-evolution \
    -Xfrontend -validate-tbd-against-ir=none \
    -module-name ResilientLib -o "$work/libResilientLib.so" \
    "$work/ResilientLib.swift" \
    -Xcc -fmodule-map-file="$agora/swift-interop-probe/agora-modules/module.modulemap" \
    -Xcc -I"$AGORA_PREFIX/include" -Xcc -Wno-incomplete-umbrella \
    -L"$AGORA_PREFIX/lib" -lagora-base -lagora-core -lagora-dispatch \
    -lobjc -lBlocksRuntime \
    -Xlinker -rpath -Xlinker "$AGORA_PREFIX/lib" || return 1

  local -a optflag=()
  [[ -n "$opt" ]] && optflag=("$opt")
  "$SWIFTC_LAYOUT2" "${optflag[@]}" -I"$work" -L"$work" -lResilientLib \
    -Xlinker -rpath -Xlinker "$work" \
    -Xcc -fmodule-map-file="$agora/swift-interop-probe/agora-modules/module.modulemap" \
    -Xcc -I"$AGORA_PREFIX/include" -Xcc -Wno-incomplete-umbrella \
    -L"$AGORA_PREFIX/lib" -lagora-base -lagora-core -lagora-dispatch \
    -lobjc -lBlocksRuntime \
    -Xlinker -rpath -Xlinker "$AGORA_PREFIX/lib" \
    -o "$work/resilient" "$work/resilient.swift" "$work/c_check.o" \
    "$work/c_check2.o" || return 1

  local resolved
  resolved="$(LD_LIBRARY_PATH="$work" ldd "$work/resilient" |
              awk '/libswiftCore\.so/ { print $3 }')"
  if [[ "$resolved" != "$STDLIB_DIR/linux/libswiftCore.so" ]]; then
    echo "linked against '$resolved', expected '$STDLIB_DIR/linux/libswiftCore.so'"
    return 1
  fi
  LD_LIBRARY_PATH="$AGORA_PREFIX/lib:$work" "$work/resilient"
}

check "resilient ObjC class object (-Onone)" build_resilient ""
check "resilient ObjC class object (-O)" build_resilient -O

echo
if (( failures == 0 )); then
  echo "S4b/S4c gate: ok (class objects, unique names, -init/-dealloc, hierarchy,"
  echo "                     resilient relocation)"
  exit 0
fi
echo "S4b/S4c gate: $failures check(s) failed"
exit 1
