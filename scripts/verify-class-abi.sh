#!/usr/bin/env bash
#
# Stage S1 gate of SWIFT-GNUSTEP-CLASS-ABI.md: a Swift class emitted as a real
# GNUstep class object.
#
#   swift-toolchain/scripts/verify-class-abi.sh
#
# Uses the layout-2 compiler: since the 2026-10-17 flip that is the installed
# `swiftc`, and the default here is the build tree's wrapper (rebuilt by
# swift-toolchain/scripts/build-layout2-frontend.sh unless SKIP_BUILD=1) so the
# gate can be run against an uninstalled compiler change.  Override
# SWIFTC_LAYOUT2 to point at the installed one.  The checks are made from C,
# because the point is that Agora sees the Swift class:
#
#   * `objc_getClass("Counter")` resolves it from a constructor, i.e. before
#     `main`;
#   * the class name, `-greet` and `+classAnswer` are visible to
#     `respondsToSelector` (after the first send installs libobjc2's dispatch
#     tables);
#   * an Objective-C category on the Swift class is attached and its `+load` is
#     delivered, without crashing;
#   * `class_createInstance` allocates, and both instance and class methods
#     dispatch to the Swift IMPs;
#   * the emitted `objc_ivar_list` is usable from C: `class_getInstanceVariable`
#     reports the field and its offset, a value C writes is read back by Swift,
#     and a value Swift writes is read back by C (stage S3).
#
# Exits non-zero if any check fails.
#
#   AGORA_PREFIX       Agora install prefix (default ../../build-prefix)
#   SWIFTC_LAYOUT2     layout-2 `swiftc` wrapper (computed from the build tree)
#   BOOTSTRAP_CLANG    clang for the C/ObjC side (default bootstrap toolchain)

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
agora="$here"
source "$agora/swift-toolchain/scripts/native-env.sh"

AGORA_PREFIX="${AGORA_PREFIX:-$agora/build-prefix}"
BOOTSTRAP_CLANG="${BOOTSTRAP_CLANG:-$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/bin/clang}"
SWIFT_BUILD_SUBDIR="${SWIFT_BUILD_SUBDIR:-agora-${AGORA_TARGET_TRIPLE}}"
SWIFTC_LAYOUT2="${SWIFTC_LAYOUT2:-$OPEN_SWIFT_SOURCE_ROOT/build/$SWIFT_BUILD_SUBDIR/swift-$AGORA_TARGET_TRIPLE/bin/swiftc-layout2}"

if [[ "${SKIP_BUILD:-0}" != "1" || ! -x "$SWIFTC_LAYOUT2" ]]; then
  echo "== layout-2 compiler =="
  "$agora/swift-toolchain/scripts/build-layout2-frontend.sh"
  echo
fi

if [[ ! -x "$SWIFTC_LAYOUT2" ]]; then
  echo "error: no layout-2 swiftc at $SWIFTC_LAYOUT2" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Programs find their stdlib through the RUNPATH the driver records: the
# installed toolchain's (layout 2) when the default wrapper is used, the build
# tree's when SWIFTC_LAYOUT2 points there.
export LD_LIBRARY_PATH="$AGORA_PREFIX/lib"

cat > "$work/counter_lib.swift" <<'EOF'
import Foundation

@objc(Counter)
class Counter: NSObject {
  var start: Int = 0
  @objc func greet() -> Int { return 42 }
  @objc(classAnswer) class func classAnswer() -> Int { return 7 }
  // Used by the S3 half of the gate: C reads and writes the ivar through the
  // emitted objc_ivar_list and Swift sees the value.
  @objc func readStart() -> Int { return start }
  @objc func writeStart(_ value: Int) { start = value }
}
EOF

# An Objective-C category on the Swift class.  Its +load is what proves the
# class is a normal ObjC class: libobjc2 must attach the category and deliver
# +load to a class that Swift emitted.
cat > "$work/category.m" <<'EOF'
#import <Foundation/Foundation.h>

@interface Counter : NSObject
@end
@interface Counter (LoadProbe)
+ (void)load;
@end

int counter_category_loaded = 0;

@implementation Counter (LoadProbe)
+ (void)load { counter_category_loaded = 1; }
@end
EOF

cat > "$work/c_gate.c" <<'EOF'
#include <objc/runtime.h>
#include <stdio.h>
#include <string.h>

extern int counter_category_loaded;

static int registered_before_main = 0;
static int responds_before_main = 0;

__attribute__((constructor))
static void pre_main_check(void) {
  Class c = objc_getClass("Counter");
  registered_before_main = (c != NULL);
  if (!c) return;
  /* The first send installs libobjc2's dispatch tables; class_respondsToSelector
     only consults them, it does not trigger initialization. */
  objc_msg_lookup((id)c, sel_registerName("class"));
  responds_before_main =
      class_respondsToSelector(c, sel_registerName("greet"));
}

int main(void) {
  Class c = objc_getClass("Counter");
  if (!c) { printf("FAIL: Counter not registered\n"); return 1; }
  printf("registered before main: %d\n", registered_before_main);
  if (!registered_before_main) return 2;
  if (strcmp(class_getName(c), "Counter") != 0) return 3;

  objc_msg_lookup((id)c, sel_registerName("class"));
  SEL greet = sel_registerName("greet");
  if (!class_respondsToSelector(c, greet)) {
    printf("FAIL: -greet missing\n"); return 4;
  }
  if (!responds_before_main) {
    printf("FAIL: -greet missing before main\n"); return 5;
  }
  SEL classAnswer = sel_registerName("classAnswer");
  if (!class_respondsToSelector(object_getClass((id)c), classAnswer)) {
    printf("FAIL: +classAnswer missing\n"); return 6;
  }
  SEL load = sel_registerName("load");
  if (!class_respondsToSelector(object_getClass((id)c), load)) {
    printf("FAIL: category +load not attached\n"); return 7;
  }
  if (!counter_category_loaded) {
    printf("FAIL: +load not delivered\n"); return 8;
  }

  id obj = class_createInstance(c, 0);
  IMP greetImp = objc_msg_lookup(obj, greet);
  int v = ((int(*)(id, SEL))greetImp)(obj, greet);
  if (v != 42) { printf("FAIL: greet = %d\n", v); return 9; }

  IMP answerImp = objc_msg_lookup((id)c, classAnswer);
  int cv = ((int(*)(id, SEL))answerImp)((id)c, classAnswer);
  if (cv != 7) { printf("FAIL: classAnswer = %d\n", cv); return 10; }

  /* S3: the emitted objc_ivar_list is what libobjc2 uses for
     class_getInstanceVariable and the ivar offsets. A Swift Int is 8 bytes on
     this target, so `long` is the matching C type. */
  Ivar start = class_getInstanceVariable(c, "start");
  if (!start) { printf("FAIL: ivar 'start' missing\n"); return 11; }
  ptrdiff_t startOffset = ivar_getOffset(start);
  if (startOffset < (ptrdiff_t)sizeof(void *)) {
    printf("FAIL: ivar offset %td looks wrong\n", startOffset);
    return 12;
  }

  /* C -> Swift: write through the offset, read through a Swift accessor. */
  *(long *)((char *)obj + startOffset) = 5;
  SEL readStart = sel_registerName("readStart");
  long fromC = ((long(*)(id, SEL))objc_msg_lookup(obj, readStart))(obj, readStart);
  if (fromC != 5) { printf("FAIL: C write not seen by Swift (%ld)\n", fromC); return 13; }

  /* Swift -> C: write through Swift, read the same offset. */
  SEL writeStart = sel_registerName("writeStart:");
  ((void(*)(id, SEL, long))objc_msg_lookup(obj, writeStart))(obj, writeStart, 9);
  long fromSwift = *(long *)((char *)obj + startOffset);
  if (fromSwift != 9) { printf("FAIL: Swift write not seen by C (%ld)\n", fromSwift); return 14; }

  printf("S1 gate: ok (registered, name/methods visible, +load delivered, "
         "dispatch = %d/%d, ivar offset = %td and readable both ways)\n",
         v, cv, startOffset);
  return 0;
}
EOF

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== compile the Swift class (layout 2) =="
"$SWIFTC_LAYOUT2" -c -parse-as-library \
  "$work/counter_lib.swift" -o "$work/counter_lib.o" \
  -Xcc -fmodule-map-file="$agora/swift-interop-probe/agora-modules/module.modulemap" \
  -Xcc -I"$AGORA_PREFIX/include" \
  -Xcc -Wno-incomplete-umbrella || fail "swift compile"

echo "== compile the C/ObjC side =="
"$BOOTSTRAP_CLANG" -fobjc-runtime=gnustep-2.0 -fblocks \
  -I"$AGORA_PREFIX/include" -c "$work/category.m" -o "$work/category.o" \
  || fail "category"
"$BOOTSTRAP_CLANG" -fblocks -I"$AGORA_PREFIX/include" \
  -c "$work/c_gate.c" -o "$work/c_gate.o" || fail "c gate"

echo "== link =="
"$SWIFTC_LAYOUT2" "$work/counter_lib.o" "$work/category.o" "$work/c_gate.o" \
  -o "$work/c_gate" \
  -L"$AGORA_PREFIX/lib" \
  -lagora-base -lagora-core -lagora-dispatch -lobjc -lBlocksRuntime \
  -Xlinker -rpath -Xlinker "$AGORA_PREFIX/lib" || fail "link"

echo "== run =="
"$work/c_gate" || fail "gate"
