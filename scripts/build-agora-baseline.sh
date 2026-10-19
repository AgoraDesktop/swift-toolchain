#!/usr/bin/env bash
#
# Agora runtime baseline — the native replacement for
# OpenSwiftProject/toolchain-docker's build-gnustep-baseline.sh.
#
# UPSTREAM builds five things into a GNUstep prefix: libobjc2, a C libdispatch,
# GNUstep tools-make, GNUstep libs-base (Foundation) and GNUstep libs-corebase.
#
# AGORA needs exactly one of those:
#
#   * libobjc2   — Agora already ships it (libagora-objc). Read from
#                  $AGORA_PREFIX; NOT rebuilt here.
#   * libdispatch — Agora's libagora-dispatch has its Swift support removed
#                  (libagora-dispatch/PROVENANCE.md), so this builds a
#                  Swift-capable swift-corelibs-libdispatch instead. C library
#                  only; the Swift `Dispatch` overlay is built later, by
#                  build-swift-toolchain.sh, once a Swift compiler exists.
#   * tools-make / libs-base / libs-corebase — NOT built. They existed for
#                  OpenSwiftProject's demo. The Swift stdlib's ObjC interop
#                  includes <Foundation/…> and <CoreFoundation/…>, which resolve
#                  to $AGORA_PREFIX (see build-swift-toolchain.sh).
#
# Result: $OPEN_SWIFT_RUNTIME_PREFIX holds only libdispatch. No GNUstep.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/native-env.sh"

BUILD_JOBS="${BUILD_JOBS:-$(nproc 2>/dev/null || echo 3)}"

if [[ ! -e "$AGORA_PREFIX/lib/libobjc.so" && ! -e "$AGORA_PREFIX/lib/libobjc.so.4.6" ]]; then
  echo "error: Agora's libobjc2 was not found under $AGORA_PREFIX/lib." >&2
  echo "       Build libagora-objc first, or set AGORA_PREFIX." >&2
  exit 1
fi

export CPATH="$OPEN_SWIFT_RUNTIME_PREFIX/include${CPATH:+:$CPATH}"
export LIBRARY_PATH="$AGORA_PREFIX/lib:$OPEN_SWIFT_RUNTIME_PREFIX/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$AGORA_PREFIX/lib:$OPEN_SWIFT_RUNTIME_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

mkdir -p "$OPEN_SWIFT_BUILD_ROOT" "$OPEN_SWIFT_RUNTIME_PREFIX"

echo "== Build swift-corelibs-libdispatch (C; Swift overlay comes later) =="
"$AGORA_CMAKE" -S "$OPEN_SWIFT_SOURCE_ROOT/swift-corelibs-libdispatch" \
  -B "$OPEN_SWIFT_BUILD_ROOT/swift-corelibs-libdispatch" \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_INSTALL_PREFIX="$OPEN_SWIFT_RUNTIME_PREFIX" \
  -DCMAKE_C_COMPILER="$AGORA_HOST_CC" \
  -DCMAKE_CXX_COMPILER="$AGORA_HOST_CXX" \
  -DCMAKE_MAKE_PROGRAM="$AGORA_NINJA" \
  -DINSTALL_PRIVATE_HEADERS=YES \
  -DINSTALL_BLOCK_HEADERS_DIR="$OPEN_SWIFT_RUNTIME_PREFIX/include" \
  -DINSTALL_DISPATCH_HEADERS_DIR="$OPEN_SWIFT_RUNTIME_PREFIX/include/dispatch" \
  -DINSTALL_OS_HEADERS_DIR="$OPEN_SWIFT_RUNTIME_PREFIX/include/os"
"$AGORA_CMAKE" --build "$OPEN_SWIFT_BUILD_ROOT/swift-corelibs-libdispatch" -- -j"$BUILD_JOBS"
"$AGORA_CMAKE" --install "$OPEN_SWIFT_BUILD_ROOT/swift-corelibs-libdispatch"

echo "== done =="
echo "   runtime prefix : $OPEN_SWIFT_RUNTIME_PREFIX   (libdispatch only)"
echo "   Agora runtime  : $AGORA_PREFIX               (libobjc2, Foundation, CoreFoundation)"
