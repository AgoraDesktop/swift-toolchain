#!/usr/bin/env bash
#
# Shared native layout for the Agora Swift toolchain. Source it; do not run it.
#
#   . "$(dirname "${BASH_SOURCE[0]}")/native-env.sh"
#
# There is no container anywhere in this build. Everything the toolchain needs
# lives under $AGORA_SWIFT_ROOT, and Agora's own build-prefix is consumed in
# place. Nothing is written outside those two directories, and nothing needs
# root.

# --- locate the Agora release repository from this script -------------------
_agora_scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGORA_ROOT="$(cd "$_agora_scripts_dir/../.." && pwd)"

# --- Agora's built stack (headers + libs), consumed as-is -------------------
: "${AGORA_PREFIX:=$AGORA_ROOT/build-prefix}"

# --- where all toolchain sources, builds and installs live ------------------
: "${AGORA_SWIFT_ROOT:=$HOME/.agora-swift}"

# --- target ----------------------------------------------------------------
# Upstream's published image is aarch64; the fork supports x86_64 too.
: "${AGORA_TARGET_TRIPLE:=linux-x86_64}"

# --- derived layout ---------------------------------------------------------
: "${OPEN_SWIFT_SOURCE_ROOT:=$AGORA_SWIFT_ROOT/src}"
: "${OPEN_SWIFT_BUILD_ROOT:=$AGORA_SWIFT_ROOT/build}"
: "${OPEN_SWIFT_RUNTIME_PREFIX:=$AGORA_SWIFT_ROOT/runtime}"
: "${OPEN_SWIFT_TOOLCHAIN_DESTDIR:=$AGORA_SWIFT_ROOT/toolchain}"
: "${OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN:=$AGORA_SWIFT_ROOT/bootstrap/usr}"
: "${AGORA_SWIFT_TOOLS:=$AGORA_SWIFT_ROOT/bin}"

# The bootstrap Swift release to fetch from swift.org (verified to run on
# Debian 13, which is this host, as well as Ubuntu 24.04).
: "${AGORA_BOOTSTRAP_VERSION:=6.3.3}"

export AGORA_ROOT AGORA_PREFIX AGORA_SWIFT_ROOT AGORA_TARGET_TRIPLE
export OPEN_SWIFT_SOURCE_ROOT OPEN_SWIFT_BUILD_ROOT OPEN_SWIFT_RUNTIME_PREFIX
export OPEN_SWIFT_TOOLCHAIN_DESTDIR OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN
export AGORA_SWIFT_TOOLS AGORA_BOOTSTRAP_VERSION

# `ninja` is fetched here (no root); the bootstrap toolchain supplies
# swiftc/clang/lld. Both go on PATH ahead of the system.
export PATH="$AGORA_SWIFT_TOOLS:$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/bin:$PATH"

# Host C/C++ compilers: the bootstrap toolchain's own clang, so the build does
# not depend on a system clang existing.
: "${AGORA_HOST_CC:=$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/bin/clang}"
: "${AGORA_HOST_CXX:=$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/bin/clang++}"
: "${AGORA_CMAKE:=/usr/bin/cmake}"
: "${AGORA_NINJA:=$AGORA_SWIFT_TOOLS/ninja}"
export AGORA_HOST_CC AGORA_HOST_CXX AGORA_CMAKE AGORA_NINJA

# The bootstrap Swift must keep using its own bundled libraries, so Agora is
# deliberately NOT put on this LD_LIBRARY_PATH: the compiler that builds Agora
# is not linked against Agora. build-swift-toolchain.sh adds Agora's
# CPATH/LIBRARY_PATH only for the stdlib being built.
export LD_LIBRARY_PATH="$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/lib/swift/linux:$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export SWIFTC="$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/bin/swiftc"

# Class-metadata layout: 2 is the GNUstep `struct objc_class` ABI
# (SWIFT-GNUSTEP-CLASS-ABI.md) and the default since the 2026-10-17 flip, which
# matches Runtime/Config.h.  Pass 0 for the compact layout the toolchain used
# before the flip.  The build script always passes the value explicitly, so a
# stale CMakeCache.txt cannot silently change the ABI.
: "${AGORA_SWIFT_CLASS_LAYOUT:=2}"
export AGORA_SWIFT_CLASS_LAYOUT
