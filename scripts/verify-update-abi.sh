#!/usr/bin/env bash
#
# Library-evolution gate: a class whose instance layout is only final at
# runtime, because a stored property's type is a non-frozen struct from another
# module ("resiliently sized members").
#
#   swift-toolchain/scripts/verify-update-abi.sh
#
# The compiler emits two different strategies for such a class:
#
#   * a *pure Swift* class keeps the cheap `Update` strategy: metadata is
#     emitted statically and the class's metadata accessor calls
#     `swift_updateClassMetadata2` before the first allocation.  That function
#     only knew how to do its job at layout 1; at layout 2 the call did not even
#     link (`undefined reference to swift_updateClassMetadata2`).  The layout-2
#     implementation recomputes the field offset vector and the instance
#     size/alignment from the runtime field layouts, slides the field-offset
#     globals the compiled accesses load, and mirrors the size into the GNUstep
#     `instance_size` word.
#   * a class with an Objective-C ancestor is allocated by libobjc2, which reads
#     `instance_size`.  libobjc2 has no `_objc_realizeClassFromSwift` update
#     hook, and a load-time registration would carry the *static* (minimum)
#     size.  Such a class is therefore built with the `Singleton` strategy at
#     layout 2: the layout is computed first and the class is registered with
#     libobjc2 only then - the ordering the resilient path already used.
#
# The gate proves the actual promise, not just that it links: it builds a
# library-evolution module v1, compiles the client against it, then swaps in a
# v2 of the module whose struct has one more field - *without recompiling the
# client* - and runs both versions at `-Onone` and `-O`:
#
#   * values of the pure-Swift and the ObjC-rooted holder are correct in both;
#   * in v2 the ObjC class's `class_getInstanceSize` reflects the grown struct
#     (8-byte header + runtime struct size + 8), and 20k allocations through the
#     Objective-C allocator do not corrupt anything;
#   * a class whose layout is only final at runtime is registered lazily: asked
#     by name *before* the first Swift metadata access, `objc_getClass` says nil;
#     after it, the class is there with the final size (the same visibility the
#     resilient path has at this layout).
#
# Runs against the layout-2 compiler *and* stdlib (the build tree, like the
# other layout-2 gates).
#
#   AGORA_PREFIX       Agora install prefix (default ../../build-prefix)
#   SWIFTC_LAYOUT2     layout-2 wrapper (computed from the build tree)
#   STDLIB_DIR         stdlib the produced programs must link (default: tree)
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

mm=(-Xcc -fmodule-map-file="$agora/swift-interop-probe/agora-modules/module.modulemap"
    -Xcc -I"$AGORA_PREFIX/include" -Xcc -Wno-incomplete-umbrella)

# The evolving library: v2 adds one field and keeps v1's initializer *symbol*,
# so a client compiled against v1 still links and runs against v2.
cat > "$work/v1.swift" <<'EOF'
public struct Payload {
  public var a: Int
  public var b: Int
  public init(a: Int = 1, b: Int = 2) { self.a = a; self.b = b }
}
EOF

cat > "$work/v2.swift" <<'EOF'
public struct Payload {
  public var a: Int
  public var b: Int
  public var c: Int = 3
  public init(a: Int = 1, b: Int = 2) { self.a = a; self.b = b; self.c = 3 }
}
EOF

cat > "$work/client.swift" <<'EOF'
import Foundation
import LibEvolving

// Update strategy: pure Swift, allocated by Swift.
class PureHolder {
  var p = Payload(a: 1, b: 2)
  var tail = 3
}

// Objective-C ancestor: at layout 2 this is a class object, so it takes the
// Singleton path (compute the layout, then register).
@objc(ObjCHolder)
class ObjCHolder: NSObject {
  var p = Payload(a: 4, b: 5)
  var tail = 6
  @objc func read() -> Int { return p.a + p.b + tail }
}

@_silgen_name("ue_class_named")
func ueClassNamed(_ name: UnsafePointer<CChar>) -> UnsafeMutableRawPointer?

@_silgen_name("ue_instance_size")
func ueInstanceSize(_ cls: UnsafeMutableRawPointer) -> Int

// Asked by name before any Swift access to ObjCHolder: the class has not been
// registered yet.
let before = ueClassNamed("ObjCHolder")
precondition(before == nil,
             "a runtime-layout class must not be registered before its metadata is built")

let pure = PureHolder()
precondition(pure.p.a == 1 && pure.p.b == 2 && pure.tail == 3,
             "pure holder fields (Update strategy)")

let objc = ObjCHolder()
precondition(objc.p.a == 4 && objc.p.b == 5 && objc.tail == 6
             && objc.read() == 15,
             "ObjC holder fields (Singleton strategy)")

let after = ueClassNamed("ObjCHolder")
precondition(after != nil, "the class is registered after its Swift metadata access")
let size = ueInstanceSize(after!)
// ObjC header (8) + the *runtime* Payload size + tail (8).
let expected = 8 + MemoryLayout<Payload>.size + 8
precondition(size == expected,
             "instance size = \(size), expected \(expected) for runtime Payload \(MemoryLayout<Payload>.size)")

// 20k allocations through libobjc2: a stale or undersized `instance_size`
// would corrupt the heap, not fail politely.
var sum = 0
for i in 0..<20000 {
  let o = ObjCHolder()
  o.p = Payload(a: i, b: i + 1)
  o.tail = i + 2
  let q = PureHolder()
  q.p = Payload(a: i * 2, b: i * 2 + 1)
  q.tail = i * 2 + 2
  sum += o.p.a + o.tail + q.p.b + q.tail
  precondition(o.p.b == i + 1 && q.p.a == i * 2, "loop fields")
}
precondition(sum != 0)

print("update: ok (Payload \(MemoryLayout<Payload>.size) bytes, instance size \(size))")
EOF

cat > "$work/helpers.c" <<'EOF'
#include <objc/runtime.h>
void *ue_class_named(const char *name) { return (void *)objc_getClass(name); }
long ue_instance_size(void *cls) { return (long)class_getInstanceSize((Class)cls); }
EOF

build_library() {
  local src="$1" out="$2"
  "$SWIFTC_LAYOUT2" "${mm[@]}" -emit-module -emit-library \
    -enable-library-evolution -Xfrontend -validate-tbd-against-ir=none \
    -module-name LibEvolving -o "$out/libLibEvolving.so" "$src" \
    -L"$AGORA_PREFIX/lib" -Xlinker -rpath -Xlinker "$AGORA_PREFIX/lib"
}

build_client() {
  local opt="$1" out="$2"
  local -a optflag=()
  [[ -n "$opt" ]] && optflag=("$opt")
  "$SWIFTC_LAYOUT2" "${mm[@]}" "${optflag[@]}" \
    -I "$work/v1" -L "$work/v1" -lLibEvolving \
    -Xlinker -rpath -Xlinker "$work/v1" \
    -o "$out" "$work/client.swift" "$work/helpers.o" \
    -L"$AGORA_PREFIX/lib" -Xlinker -rpath -Xlinker "$AGORA_PREFIX/lib"
}

run_with() {
  local libdir="$1" bin="$2"
  LD_LIBRARY_PATH="$AGORA_PREFIX/lib:$libdir" "$bin"
}

# The client must exercise *both* strategies: the pure Swift holder is Update
# (`swift_updateClassMetadata2`), the ObjC-rooted one is Singleton at layout 2
# (`swift_initClassMetadata2`).
check_strategies() {
  "$SWIFTC_LAYOUT2" "${mm[@]}" -I "$work/v1" -L "$work/v1" -lLibEvolving \
    -emit-ir "$work/client.swift" > "$work/client.ll" || return 1
  grep -q 'swift_updateClassMetadata2' "$work/client.ll" || {
    echo "the pure Swift holder did not use the Update strategy"
    return 1
  }
  grep -q 'swift_initClassMetadata2' "$work/client.ll" || {
    echo "the ObjC-rooted holder did not use the Singleton strategy"
    return 1
  }
}

check_stdlib() {
  local bin="$1" resolved
  resolved="$(ldd "$bin" | awk '/libswiftCore\.so/ { print $3 }')"
  if [[ "$resolved" != "$STDLIB_DIR/linux/libswiftCore.so" ]]; then
    echo "linked against '$resolved', expected '$STDLIB_DIR/linux/libswiftCore.so'"
    return 1
  fi
}

echo "== library-evolution gate: resiliently sized members =="

"$BOOTSTRAP_CLANG" -I"$AGORA_PREFIX/include" -c "$work/helpers.c" \
  -o "$work/helpers.o" || { echo "error: C helper failed to compile" >&2; exit 1; }

build_library "$work/v1.swift" "$work/v1" || { echo "error: v1 library build failed" >&2; exit 1; }
build_library "$work/v2.swift" "$work/v2" || { echo "error: v2 library build failed" >&2; exit 1; }

check "both strategies are exercised" check_strategies

for opt in "" -O; do
  name="${opt:--Onone}"
  bin="$work/client${opt}"
  build_client "$opt" "$bin" || { echo "error: client build failed ($name)" >&2; exit 1; }
  check "client links the layout-2 stdlib ($name)" check_stdlib "$bin"
  check "same-layout library ($name)" run_with "$work/v1" "$bin"
  check "evolved library, client not recompiled ($name)" run_with "$work/v2" "$bin"
done

echo
if (( failures == 0 )); then
  echo "library-evolution gate: ok (Update + Singleton, evolved runtime layout,"
  echo "                           lazy registration, 20k ObjC allocations)"
  exit 0
fi
echo "library-evolution gate: $failures check(s) failed"
exit 1
