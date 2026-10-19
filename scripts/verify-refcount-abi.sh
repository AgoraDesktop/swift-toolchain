#!/usr/bin/env bash
#
# Stage S5 gate of SWIFT-GNUSTEP-CLASS-ABI.md: typed selector records, so
# Objective-C dispatch - including libobjc2's own release path - reaches a
# Swift method.
#
#   swift-toolchain/scripts/verify-refcount-abi.sh
#
# With S1/S4/S4b/S4c a Swift class with Objective-C ancestry is a registered
# GNUstep class object, but its selector records were *untyped* (one record per
# name, `types = NULL`) while every Clang-compiled caller - and libobjc2's
# `objc_release_fast_np`, which sends `dealloc` - uses a *typed* selector.
# libobjc2 keys type-dependent dispatch by (name, type encoding), so the two
# land in different dtable slots: a typed `-dealloc` send found NSObject's
# implementation (inherited in the subclass's dtable) instead of the Swift one,
# and `deinit` never ran.  IRGen now emits one selector record per
# (name, encoding), with the record carrying the same encoding as the method
# entry, and mangles the symbol exactly like Clang's GNUstep ABI v2 emitter so
# the two records merge.
#
# The gate proves, through the public Objective-C API:
#
#   * `deinit` runs for a pure Swift class, a pure generic class, a fixed class
#     with an ObjC ancestor and a generic class with an ObjC ancestor;
#   * a Swift method that overrides an inherited typed selector is reached by a
#     real Clang-compiled typed send: `-dealloc` (release), `-init`, a plain
#     Swift `@objc` method (`-read`) and a class method (`+version`);
#   * retain/release from Objective-C balance, and the destructor runs exactly
#     once, at the last release;
#   * 50k allocate/init/release cycles from Objective-C neither leak (deinit
#     count is exact) nor climb in RSS;
#   * the class's `dealloc`/`init` entries answer *identically* to the typed and
#     the untyped selector - the exact property that was broken.
#
# Runs against the layout-2 compiler *and* stdlib (a generic class with an ObjC
# ancestor needs both), like the S4/S4b gates.
#
#   AGORA_PREFIX       Agora install prefix (default ../../build-prefix)
#   SWIFTC_LAYOUT2     layout-2 wrapper (computed from the build tree)
#   SKIP_BUILD=1       do not rebuild the layout-2 compiler + stdlib
#   ITERATIONS         C-side allocate/release cycles (default 50000)

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
ITERATIONS="${ITERATIONS:-50000}"

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

cat > "$work/s5.swift" <<'EOF'
import Foundation

// The counters the C side reads.  `deinit` is the thing under test.
final class Stats {
  static var deinits = 0
}

@_cdecl("s5_deinits")
public func s5Deinits() -> Int { return Stats.deinits }

// Pure Swift classes: these always ran `deinit`, so they guard the fix against
// regressions in the non-ObjC path.
class Pure {
  var v: Int
  init(_ v: Int) { self.v = v }
  deinit { Stats.deinits += 1 }
}

class PureBox<T> {
  var v: T
  init(_ v: T) { self.v = v }
  deinit { Stats.deinits += 1 }
}

// A fixed class with an Objective-C ancestor.  `override init()` gives the
// Clang-compiled `[obj init]` (a *typed* selector) something to override, and
// `-read` is the plain @objc method.
@objc(DeinitBox)
class DeinitBox: NSObject {
  var v: Int
  override init() { self.v = 7; super.init() }
  init(_ v: Int) { self.v = v; super.init() }
  @objc func read() -> Int { return v }
  @objc(version) class func version() -> Int { return 9 }
  deinit { Stats.deinits += 1 }
}

// A generic class with an Objective-C ancestor: allocated by
// `objc_allocWithZone`, released by libobjc2, and (with S5) its destructor runs.
class Doomed<T>: NSObject {
  var v: T
  init(_ v: T) { self.v = v; super.init() }
  @objc func read() -> Int { return 1 }
  deinit { Stats.deinits += 1 }
}

func pointer(to object: AnyObject) -> UnsafeMutableRawPointer {
  Unmanaged.passUnretained(object).toOpaque()
}

@_silgen_name("s5_selector_imps")
func s5SelectorImps(_ object: UnsafeMutableRawPointer) -> Int32

@_silgen_name("s5_typed_init")
func s5TypedInit() -> Int

@_silgen_name("s5_typed_dispatch")
func s5TypedDispatch(_ object: UnsafeMutableRawPointer) -> Int

@_silgen_name("s5_typed_class_method")
func s5TypedClassMethod() -> Int

@_silgen_name("s5_retain_release")
func s5RetainRelease() -> Int

@_silgen_name("s5_alloc_release_loop")
func s5AllocReleaseLoop(_ iterations: Int32) -> Int

@_silgen_name("s5_rss_kb")
func s5RssKB() -> Int

// Objects whose lifetime ends at the end of this function, so the count can be
// read afterwards (-O may shorten a lifetime, never lengthen it past return).
func makeAndDrop() {
  let pure = Pure(1)
  let pureBox = PureBox(2)
  let fixed = DeinitBox(3)
  let generic = Doomed(4)
  _ = pure.v + pureBox.v + fixed.read() + generic.read()
}
let deinitsBefore = s5Deinits()
makeAndDrop()
let swiftDeinits = s5Deinits() - deinitsBefore

var problems: [String] = []
func expect(_ condition: Bool, _ what: String) {
  if !condition { problems.append(what) }
}
expect(swiftDeinits == 4, "Swift-side deinits = \(swiftDeinits), expected 4")

// The class object's entries must answer the typed selector and the untyped
// selector with the same IMP.  Before S5 the typed `dealloc` found NSObject's
// implementation and the untyped one found Swift's.
let fixed = DeinitBox(10)
expect(s5SelectorImps(pointer(to: fixed)) == 0,
       "typed/untyped IMP mismatch for -dealloc or -init")
expect(s5TypedDispatch(pointer(to: fixed)) == 10,
       "typed Objective-C send reached the Swift method")
expect(s5TypedClassMethod() == 9,
       "typed Objective-C class send reached the Swift class method")

// A real Clang-compiled `[[DeinitBox alloc] init]`: the typed `init` send has to
// reach Swift's override, which sets v = 7.
expect(s5TypedInit() == 7, "typed Objective-C -init reached Swift's override")

// retain/release from Objective-C balance; the destructor runs at the last one.
// The object is allocated by the C side so its only owner is that reference.
expect(s5RetainRelease() == 0,
       "retain/release did not balance, or deinit did not run exactly once")

// 50k cycles of alloc/init/release through the Objective-C runtime.
let rssBefore = s5RssKB()
let beforeLoop = s5Deinits()
let survived = s5AllocReleaseLoop(Int32(__ITERATIONS__))
let afterLoop = s5Deinits()
let rssAfter = s5RssKB()
expect(survived == Int32(__ITERATIONS__), "C allocation loop lost objects")
expect(afterLoop - beforeLoop == __ITERATIONS__,
       "deinits in the C loop = \(afterLoop - beforeLoop), expected \(__ITERATIONS__)")
expect(rssAfter - rssBefore < 8192,
       "RSS grew by \(rssAfter - rssBefore) KB over \(__ITERATIONS__) cycles")

precondition(problems.isEmpty,
             "S5: \(problems.count) failure(s): \(problems)")
print("s5: ok")
EOF
sed -i "s/__ITERATIONS__/$ITERATIONS/g" "$work/s5.swift"

cat > "$work/c_gate.m" <<'EOF'
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int s5_deinits(void);

/* The class is a Swift class: these three selectors are the ones that used to
   miss.  `dealloc` and `init` are inherited from NSObject, whose typed records
   are already in the subclass's dispatch table - a Swift method whose record is
   untyped lands in a different slot and is never reached by a typed send. */
long s5_selector_imps(void *obj) {
  Class cls = object_getClass((id)obj);
  SEL untypedDealloc = sel_registerName("dealloc");
  SEL typedDealloc = sel_registerTypedName_np("dealloc", "v16@0:8");
  SEL untypedInit = sel_registerName("init");
  SEL typedInit = sel_registerTypedName_np("init", "@16@0:8");
  if (!class_respondsToSelector(cls, typedDealloc)) return 1;
  if (!class_respondsToSelector(cls, typedInit)) return 2;
  if (class_getMethodImplementation(cls, untypedDealloc) !=
      class_getMethodImplementation(cls, typedDealloc)) return 3;
  if (class_getMethodImplementation(cls, untypedInit) !=
      class_getMethodImplementation(cls, typedInit)) return 4;
  return 0;
}

/* A plain typed send to a Swift @objc method. */
long s5_typed_dispatch(void *obj) {
  SEL read = sel_registerTypedName_np("read", "q16@0:8");
  IMP imp = objc_msg_lookup((id)obj, read);
  return imp ? ((long (*)(id, SEL))imp)((id)obj, read) : -1;
}

/* The class-side list goes through the same emitter: a typed class send must
   land on the Swift implementation too. */
long s5_typed_class_method(void) {
  id cls = objc_getClass("DeinitBox");
  SEL version = sel_registerTypedName_np("version", "q16@0:8");
  IMP imp = objc_msg_lookup(cls, version);
  return imp ? ((long (*)(id, SEL))imp)(cls, version) : -1;
}

/* Allocate and initialize through the Objective-C runtime.  `[obj init]` is
   typed by Clang from the NSObject protocol's `- (id)init`. */
long s5_typed_init(void) {
  Class cls = objc_getClass("DeinitBox");
  id obj = [(id)cls alloc];
  obj = [obj init];
  SEL read = sel_registerTypedName_np("read", "q16@0:8");
  IMP imp = objc_msg_lookup(obj, read);
  long value = imp ? ((long (*)(id, SEL))imp)(obj, read) : -1;
  [obj release];
  return value;
}

/* One retain, one release: the object must survive, so the deinit count must
   not move; the next release is the one that destroys it and must run the
   destructor exactly once.  Allocated here so this reference is the only one. */
long s5_retain_release(void) {
  Class cls = objc_getClass("DeinitBox");
  id obj = [(id)cls alloc];
  obj = [obj init];
  long before = s5_deinits();
  [obj retain];
  [obj release];
  long balanced = s5_deinits();
  [obj release];
  long final = s5_deinits();
  if (balanced != before) return -1;
  if (final != before + 1) return -2;
  return 0;
}

long s5_alloc_release_loop(int iterations) {
  Class cls = objc_getClass("DeinitBox");
  long survived = 0;
  for (int i = 0; i < iterations; i++) {
    id obj = [(id)cls alloc];
    obj = [obj init];
    if (obj) survived++;
    [obj release];
  }
  return survived;
}

long s5_rss_kb(void) {
  FILE *f = fopen("/proc/self/status", "r");
  char line[256];
  long kb = -1;
  if (!f) return -1;
  while (fgets(line, sizeof(line), f)) {
    if (strncmp(line, "VmRSS:", 6) == 0) {
      kb = strtol(line + 6, NULL, 10);
      break;
    }
  }
  fclose(f);
  return kb;
}
EOF

echo "== S5 gate: typed selector records (deinit, retain/release) =="

"$BOOTSTRAP_CLANG" -fobjc-runtime=gnustep-2.0 -fblocks \
  -I"$AGORA_PREFIX/include" -c "$work/c_gate.m" -o "$work/c_gate.o" \
  || { echo "error: Objective-C helper failed to compile" >&2; exit 1; }

build_and_run() {
  local name="$1"; shift
  "$SWIFTC_LAYOUT2" -L"$AGORA_PREFIX/lib" \
    -Xcc -fmodule-map-file="$agora/swift-interop-probe/agora-modules/module.modulemap" \
    -Xcc -I"$AGORA_PREFIX/include" \
    -Xcc -Wno-incomplete-umbrella \
    -lagora-base -lagora-core -lagora-dispatch -lobjc -lBlocksRuntime \
    -Xlinker -rpath -Xlinker "$AGORA_PREFIX/lib" \
    -o "$work/$name" "$work/s5.swift" "$work/c_gate.o" "$@" || return 1

  local resolved
  resolved="$(ldd "$work/$name" | awk '/libswiftCore\.so/ { print $3 }')"
  if [[ "$resolved" != "$STDLIB_DIR/linux/libswiftCore.so" ]]; then
    echo "linked against '$resolved', expected '$STDLIB_DIR/linux/libswiftCore.so'"
    return 1
  fi
  "$work/$name"
}

check "typed selectors / deinit (-Onone)" build_and_run s5-onone
check "typed selectors / deinit (-O)" build_and_run s5-opt -O

echo
if (( failures == 0 )); then
  echo "S5 gate: ok (typed selectors: deinit of ObjC-ancestry classes, typed"
  echo "                init/method dispatch, retain/release balance, no leak)"
  exit 0
fi
echo "S5 gate: $failures check(s) failed"
exit 1
