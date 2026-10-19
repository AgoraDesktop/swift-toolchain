#!/usr/bin/env bash
#
# Fetch the official Swift toolchain used only to bootstrap the Agora build.
#
# Native, no container: downloads the swift.org tarball and unpacks it under
# $AGORA_SWIFT_ROOT/bootstrap. It never touches the system. The bootstrap Swift
# is a build tool — the toolchain that targets Agora is the fork built by
# build-swift-toolchain.sh.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/native-env.sh"

VER="$AGORA_BOOTSTRAP_VERSION"
UBUNTU="ubuntu24.04"
BASENAME="swift-${VER}-RELEASE-${UBUNTU}"
URL="https://download.swift.org/swift-${VER}-release/ubuntu2404/swift-${VER}-RELEASE/${BASENAME}.tar.gz"

mkdir -p "$AGORA_SWIFT_ROOT/downloads" "$AGORA_SWIFT_ROOT/bootstrap"

if [[ -x "$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/bin/swift" ]]; then
  echo "bootstrap Swift already present:"
  "$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/bin/swift" --version | head -2
  exit 0
fi

TARBALL="$AGORA_SWIFT_ROOT/downloads/${BASENAME}.tar.gz"
if [[ ! -s "$TARBALL" ]]; then
  echo "downloading $URL"
  curl -sSL -o "$TARBALL" "$URL"
fi
echo "unpacking $(du -h "$TARBALL" | cut -f1) into $AGORA_SWIFT_ROOT/bootstrap"
tar -xzf "$TARBALL" -C "$AGORA_SWIFT_ROOT/bootstrap" --strip-components=1

echo "== bootstrap Swift =="
"$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/bin/swift" --version | head -2
