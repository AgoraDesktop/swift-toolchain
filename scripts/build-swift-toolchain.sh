#!/usr/bin/env bash
#
# Build the Swift toolchain that targets Agora — natively.
#
# Derived from OpenSwiftProject/toolchain-docker's scripts/build-swift-toolchain.sh.
#
# AGORA CHANGES relative to upstream — all build flags are upstream's and are
# kept verbatim so the fork stays rebasable:
#
#   1. CPATH / LIBRARY_PATH point at $AGORA_PREFIX (Agora's Foundation,
#      CoreFoundation, objc headers and libraries) and at
#      $OPEN_SWIFT_RUNTIME_PREFIX (this build's Swift-capable libdispatch).
#      This is the change that makes the stdlib's
#      `#import <Foundation/Foundation.h>` resolve to Agora.
#   2. Host tools come from the bootstrap toolchain ($AGORA_HOST_CC/CXX and
#      $AGORA_NINJA), so no system clang is required.
#   3. Target defaults to linux-x86_64; no $GNUSTEP_PREFIX anywhere.
#
# The Objective-C runtime is Agora's libobjc2 (upstream v2.3). The fork's
# -objc-runtime-vendor=gnustep selects libobjc2's GNUstep ABI v2, which Agora
# already emits via -fobjc-runtime=gnustep-2.0.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/native-env.sh"

BUILD_JOBS="${BUILD_JOBS:-$(nproc 2>/dev/null || echo 3)}"

SWIFT_ROOT="$OPEN_SWIFT_SOURCE_ROOT/swift"
SWIFT_BUILD_SUBDIR="${SWIFT_BUILD_SUBDIR:-agora-${AGORA_TARGET_TRIPLE}}"
SWIFT_CMAKE_OPTIONS=(
  -USWIFT_DARWIN_SUPPORTED_ARCHS
  -DSWIFT_STDLIB_ENABLE_OBJC_INTEROP:BOOL=TRUE
  # Select the class-metadata layout explicitly. Empty means "use
  # Runtime/Config.h's platform default"; 2 builds the GNUstep
  # `struct objc_class` layout (SWIFT-GNUSTEP-CLASS-ABI.md). Always pass it so
  # a stale value in CMakeCache.txt cannot silently change the ABI.
  "-DSWIFT_OBJC_CLASS_LAYOUT:STRING=${AGORA_SWIFT_CLASS_LAYOUT:-}"
  # Objective-C interop is incompatible with embedded Swift, and we build the
  # embedded stdlib only as a matter of course. Turn it off.
  -DSWIFT_SHOULD_BUILD_EMBEDDED_STDLIB:BOOL=FALSE
  # swift-reflection-test is a test binary that links the stdlib; interop makes
  # it need the ObjC/blocks runtimes explicitly, and it is not needed here.
  -DSWIFT_INCLUDE_TEST_BINARIES:BOOL=FALSE
  # The stdlib's TBD-vs-IR validation does not know about the Objective-C class
  # symbols that interop now emits; the compiler itself suggests disabling it.
  #
  # The vendor flag is NOT repeated here: SwiftSource.cmake already passes
  # `-objc-runtime-vendor=gnustep` for a non-Apple interop build, and the
  # frontend defaults the vendor to GNUstep for a non-Darwin ELF target
  # (CompilerInvocation.cpp). Repeating it was an S6 removal.
  #
  # `-sil-disable-pass=code-sinking` predates the class-layout work and has no
  # recorded rationale in the handoff; it is kept because the stdlib build has
  # not been retested without it, and it is the one flag here that affects
  # optimization rather than diagnostics.
  "-DSWIFT_EXPERIMENTAL_EXTRA_FLAGS:STRING=-Xfrontend;-validate-tbd-against-ir=none;-Xllvm;-sil-disable-pass=code-sinking"
)
COMMON_CMAKE_OPTIONS=(
  "-DFETCHCONTENT_SOURCE_DIR_SWIFTSYNTAX:PATH=$OPEN_SWIFT_SOURCE_ROOT/swift-syntax"
  -DLLVM_USE_LINKER=lld
  # Full bootstrapping needs LLVMTestingSupport. Force test support on and clear
  # the LLVM build dir so the target is generated.
  "-DLLVM_BUILD_TESTS:BOOL=ON"
  "-DLLVM_INCLUDE_TESTS:BOOL=ON"
  "-DCLANG_INCLUDE_TESTS:BOOL=ON"
)

# --- AGORA CHANGE 1: the include/library search order -----------------------
# Agora's headers come first, so <Foundation/…>, <CoreFoundation/…>, <objc/…>
# and <dispatch/…> resolve to Agora and to this build's libdispatch. Nothing
# GNUstep is on these paths.
export CPATH="$AGORA_PREFIX/include:$OPEN_SWIFT_RUNTIME_PREFIX/include${CPATH:+:$CPATH}"
export LIBRARY_PATH="$AGORA_PREFIX/lib:$OPEN_SWIFT_RUNTIME_PREFIX/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/lib/swift/linux:$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/lib:$AGORA_PREFIX/lib:$OPEN_SWIFT_RUNTIME_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if [[ ! -x "$SWIFTC" ]]; then
  echo "error: bootstrap Swift compiler not found at $SWIFTC" >&2
  echo "       run install-bootstrap-swift.sh first" >&2
  exit 1
fi
if [[ ! -x "$AGORA_NINJA" ]]; then
  echo "error: ninja not found at $AGORA_NINJA" >&2
  echo "       run install-ninja.sh first" >&2
  exit 1
fi

mkdir -p "$OPEN_SWIFT_BUILD_ROOT/$SWIFT_BUILD_SUBDIR" "$OPEN_SWIFT_TOOLCHAIN_DESTDIR"

echo "== Bootstrap host compiler =="
"$SWIFTC" --version | head -2

echo "== Build Swift toolchain targeting $AGORA_TARGET_TRIPLE against Agora =="
echo "   CPATH        = $CPATH"
echo "   LIBRARY_PATH = $LIBRARY_PATH"

# AGORA: --bootstrapping=bootstrapping is kept for the day the class-metadata
# layout question is settled (SWIFT-PORT-HANDOFF.md §4), but on Linux it is a
# no-op: swift/CMakeLists.txt force-sets BOOTSTRAPPING_MODE=HOSTTOOLS when
# swift-syntax is enabled (which it always is), because only HOSTTOOLS is
# supported there. So the compiler's own Swift modules are always compiled by
# the bootstrap compiler — and because they are compiled WITHOUT interop while
# this stdlib is built WITH it, the two have incompatible class metadata
# layouts (interop adds three words to every class metadata header). That is the
# current hard blocker; see SWIFT-PORT-HANDOFF.md §3.
"$SWIFT_ROOT/utils/build-script" \
  --workspace "$OPEN_SWIFT_SOURCE_ROOT" \
  --build-subdir "$SWIFT_BUILD_SUBDIR" \
  --install-prefix /usr \
  --install-destdir "$OPEN_SWIFT_TOOLCHAIN_DESTDIR" \
  --host-target "$AGORA_TARGET_TRIPLE" \
  --stdlib-deployment-targets="$AGORA_TARGET_TRIPLE" \
  --native-clang-tools-path "$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/bin" \
  --bootstrapping=bootstrapping \
  --host-cc "$AGORA_HOST_CC" \
  --host-cxx "$AGORA_HOST_CXX" \
  --cmake "$AGORA_CMAKE" \
  --ninja-bin "$AGORA_NINJA" \
  --release \
  --llvm-build-type Release \
  --swift-build-type Release \
  --swift-stdlib-build-type Release \
  --libdispatch-build-type Release \
  --swift-enable-assertions true \
  --swift-stdlib-enable-assertions false \
  --swift-stdlib-enable-strict-availability false \
  --jobs "$BUILD_JOBS" \
  --lit-jobs "$BUILD_JOBS" \
  --build-swift-examples false \
  --swift-enable-backtracing true \
  --swift-include-tests false \
  --llvm-include-tests true \
  --build-swift-libexec false \
  --build-swift-clang-overlays true \
  --swift-source-dirname swift \
  --skip-build-benchmarks \
  --libdispatch \
  --skip-build-lldb \
  --skip-build-libcxx \
  --skip-build-static-foundation \
  --skip-build-static-libdispatch \
  --skip-build-libxml2 \
  --skip-build-zlib \
  --skip-build-curl \
  --build-swift-dynamic-stdlib \
  --build-swift-dynamic-sdk-overlay \
  --skip-build-android \
  --skip-build-clang-tools-extra \
  --skip-test-swift \
  --skip-test-lldb \
  --skip-test-llbuild \
  --skip-test-xctest \
  --skip-test-foundation \
  --skip-test-libdispatch \
  --skip-test-benchmarks \
  --skip-early-swift-driver \
  --extra-swift-cmake-options="${SWIFT_CMAKE_OPTIONS[*]}" \
  --extra-cmake-options="${COMMON_CMAKE_OPTIONS[*]}" \
  --swift-objc-interop=1 \
  --install-llvm \
  --install-swift \
  --install-libdispatch \
  --reconfigure \
  --llvm-lit-args=-sv \
  --llvm-install-components="IndexStore" \
  --skip-build-lld

# --- the host Swift runtime, staged into the toolchain ----------------------
# The compiler is a *host tool*: it was built by the bootstrap toolchain, and its
# own Swift libraries (lib/swift/host/compiler) are ABI-locked to *that*
# toolchain's non-interop, compact-layout stdlib.  The stdlib installed for Agora
# is the opposite: Objective-C interop at the GNUstep class layout.  The two are
# not interchangeable (`_runtime(_ObjC)` changes Array's storage type and the
# class header, which is why a raw `swift-frontend` cannot load the target
# stdlib), so the toolchain now *ships* the matching host runtime and the
# `swiftc` wrapper puts it first on the loader path.  Before this, the wrapper
# pointed at ~/.agora-swift/bootstrap, i.e. the install only worked on the
# machine that built it.
HOST_RUNTIME_LIBS=(
  libswiftCore.so
  libswift_Concurrency.so
  libswiftGlibc.so
  libswift_Builtin_float.so
  libBlocksRuntime.so
  libdispatch.so
)
HOST_RUNTIME_DIR="$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr/lib/swift/host/runtime"
mkdir -p "$HOST_RUNTIME_DIR"
for lib in "${HOST_RUNTIME_LIBS[@]}"; do
  src="$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/lib/swift/linux/$lib"
  if [[ ! -e "$src" ]]; then
    echo "error: host runtime library not found: $src" >&2
    exit 1
  fi
  cp -f "$src" "$HOST_RUNTIME_DIR/$lib"
done
cat > "$HOST_RUNTIME_DIR/README" <<'EOF_README'
Host Swift runtime for the compiler process
===========================================

These shared libraries are the standard library the *compiler* runs on.  The
compiler is a host tool built by the bootstrap Swift toolchain, and its Swift
libraries in ../../host/compiler are ABI-locked to that toolchain's non-interop,
compact-class-layout stdlib.  The stdlib installed for Agora (../../linux) is
Objective-C-interop at the GNUstep class layout; the two cannot be mixed.

The files are copied from the bootstrap Swift release the toolchain was built
with (Apache 2.0 with Runtime Library Exception; see swift-toolchain/README.md).
`usr/bin/swiftc` puts this directory first on LD_LIBRARY_PATH; programs the
compiler produces are unaffected - they link ../../linux through their RUNPATH.
EOF_README

# --- clang, staged for linking ----------------------------------------------
# The (legacy) Swift driver shells out to `clang` to link, and it looks for it
# next to the frontend.  A symlink into the bootstrap tree would keep the
# install machine-bound, so the host clang is copied in (it is a single
# statically linked binary) together with its resource directory.
HOST_CLANG="$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr/bin/clang"
if [[ -e "$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/bin/clang-21" ]]; then
  rm -f "$HOST_CLANG"
  cp -f "$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/bin/clang-21" "$HOST_CLANG"
elif [[ -e "$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/bin/clang" ]]; then
  rm -f "$HOST_CLANG"
  cp -f "$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/bin/clang" "$HOST_CLANG"
fi
chmod +x "$HOST_CLANG" 2>/dev/null || true
ln -sfn clang "$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr/bin/clang++"
if [[ -d "$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/lib/clang" ]]; then
  rm -rf "$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr/lib/clang"
  cp -a "$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/lib/clang" \
        "$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr/lib/clang"
fi

# The wrapper: put the staged host runtime on the loader path.  Everything is
# resolved relative to the wrapper, so the toolchain can be moved.
# AGORA_SWIFT_HOST_RUNTIME still overrides it (the build-tree wrappers use it).
# NB: `swiftc` is a symlink to `swift-frontend` in a plain install, so it has to
# be removed before the wrapper is written, or it would overwrite the compiler
# binary itself.
rm -f "$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr/bin/swiftc"
cat > "$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr/bin/swiftc" <<'WRAPPER_EOF'
#!/usr/bin/env bash
# Generated by swift-toolchain/scripts/build-swift-toolchain.sh.
# The compiler process runs on the toolchain's own host runtime; the programs it
# produces link the target stdlib (lib/swift/linux) through their RUNPATH.
# AGORA_SWIFT_HOST_RUNTIME overrides the runtime the compiler itself runs on.
bindir="$(dirname "$(readlink -f "$0")")"
HOST_RUNTIME="${AGORA_SWIFT_HOST_RUNTIME:-$bindir/../lib/swift/host/runtime}"
export LD_LIBRARY_PATH="$HOST_RUNTIME${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# P3: when the ported Foundation is installed (build-foundation-p3.sh --install),
# the two C modules it imports live beside it.  An SDK would supply this include
# search; here the driver does, and the test is on the directory so an install
# that has not happened (or has been rolled back) changes nothing.
stdbindir="$bindir/../lib/swift/linux"
extra=()
if [[ -d "$stdbindir/foundation-c-modules/FoundationCShims" ]]; then
  extra+=(-Xcc -I"$stdbindir/foundation-c-modules/FoundationCShims"
          -Xcc -I"$stdbindir/foundation-c-modules/FoundationICU")
fi
exec -a swiftc "$bindir/swift-frontend" "${extra[@]}" "$@"
WRAPPER_EOF
chmod +x "$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr/bin/swiftc"

# Agora owns the `Foundation` module name. If swift-corelibs-foundation was
# installed anyway, its Swift module would shadow Agora's clang module and break
# `@objc` ("type cannot be represented in Objective-C"). Move it aside.
for f in "$OPEN_SWIFT_TOOLCHAIN_DESTDIR"/usr/lib/swift/linux/Foundation.swiftmodule \
         "$OPEN_SWIFT_TOOLCHAIN_DESTDIR"/usr/lib/swift/linux/x86_64/Foundation.swiftmodule; do
  if [[ -e "$f" ]]; then
    if [[ -e "$f.swift-corelibs" ]]; then
      # A previous install already moved the corelibs module aside; drop the
      # freshly installed one instead of nesting it inside the backup.
      rm -rf "$f"
      echo "  removed swift-corelibs Foundation (already hidden): $f"
    else
      mv "$f" "$f.swift-corelibs"
      echo "  hid swift-corelibs Foundation: $f"
    fi
  fi
done

# --- the Swift Foundation overlay -------------------------------------------
# The value bridges (String <-> NSString, Array <-> NSArray, Error <-> NSError,
# ...) live in the Foundation overlay, not the stdlib.  Build it against the
# toolchain that was just installed and install it next to the target stdlib.
# The ObjectiveC module first: the Foundation overlay re-exports it, and the
# Clang importer looks BOOL/SEL/NSZone up in it.
"$AGORA_ROOT/swift-toolchain/scripts/build-objectivec-overlay.sh"
"$AGORA_ROOT/swift-toolchain/scripts/build-foundation-overlay.sh"

# --- self-check: the install must not need the bootstrap at run time --------
echo "== self-check: compile and link with only the toolchain =="
smoke="$(mktemp -d)"
cat > "$smoke/hello.swift" <<'EOF_SMOKE'
print("toolchain self-check ok")
EOF_SMOKE
# The stdlib autolinks Agora's Foundation, so a program needs Agora's lib dir
# even when it does not use it; that is a product dependency, not the bootstrap.
if env -i PATH=/usr/bin:/bin HOME="${HOME:-/tmp}" \
     LD_LIBRARY_PATH="$HOST_RUNTIME_DIR:$AGORA_PREFIX/lib" \
     "$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr/bin/swiftc" -o "$smoke/hello" \
     "$smoke/hello.swift" -L"$AGORA_PREFIX/lib" \
     -Xlinker -rpath -Xlinker "$AGORA_PREFIX/lib" >"$smoke/out" 2>&1 \
   && LD_LIBRARY_PATH="$AGORA_PREFIX/lib" "$smoke/hello" >>"$smoke/out" 2>&1; then
  echo "  [ok] $(cat "$smoke/out" | tail -1)"
else
  echo "  [warn] the installed swiftc failed a clean-environment self-check:" >&2
  sed 's/^/         /' "$smoke/out" | tail -10 >&2
fi
rm -rf "$smoke"

echo "== done: toolchain installed under $OPEN_SWIFT_TOOLCHAIN_DESTDIR =="
