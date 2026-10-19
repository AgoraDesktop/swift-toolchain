#!/usr/bin/env bash
#
# Fetch a `ninja` binary into $AGORA_SWIFT_ROOT/bin.
#
# The Swift build requires ninja; the bootstrap toolchain does not ship one and
# this avoids an apt install, so no root is needed. Extraction uses python3
# (always present) rather than unzip.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/native-env.sh"

NINJA_VERSION="${NINJA_VERSION:-1.12.1}"
DEST="$AGORA_SWIFT_TOOLS/ninja"

if [[ -x "$DEST" ]]; then
  echo "ninja already present: $DEST ($("$DEST" --version))"
  exit 0
fi

mkdir -p "$AGORA_SWIFT_TOOLS"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

URL="https://github.com/ninja-build/ninja/releases/download/v${NINJA_VERSION}/ninja-linux.zip"
echo "downloading $URL"
curl -sSL -o "$TMP/ninja.zip" "$URL"
python3 - "$TMP/ninja.zip" "$TMP" <<'PY'
import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])
PY
install -m 0755 "$TMP/ninja" "$DEST"
echo "ninja $("$DEST" --version) -> $DEST"
