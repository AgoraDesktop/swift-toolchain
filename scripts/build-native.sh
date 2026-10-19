#!/usr/bin/env bash
#
# Build a Swift toolchain that targets Agora — natively, no container.
#
#   swift-toolchain/scripts/build-native.sh
#
# Everything is installed under $AGORA_SWIFT_ROOT (default ~/.agora-swift) and
# consumes Agora's build-prefix in place. Nothing else on the system is touched.
#
# This is a long build: it compiles LLVM, the Swift compiler, the Swift stdlib
# and SwiftPM's dependencies from source. Expect hours and tens of GB. Run it
# under `nohup`/`tmux` if your session may drop.
#
# Steps:
#   1. bootstrap Swift (swift.org tarball)   — install-bootstrap-swift.sh
#   2. ninja                                  — install-ninja.sh
#   3. source checkout                        — clone-sources.sh
#   4. Swift-capable libdispatch              — build-agora-baseline.sh
#   5. the toolchain, against Agora           — build-swift-toolchain.sh
#
# Skip steps with AGORA_SKIP="clone,baseline" etc.

set -euo pipefail
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPTS/native-env.sh"

skip_contains() { [[ ",${AGORA_SKIP:-}," == *",$1,"* ]]; }

echo "=============================================================="
echo " Agora Swift toolchain — native build"
echo "   Agora prefix   : $AGORA_PREFIX"
echo "   work root      : $AGORA_SWIFT_ROOT"
echo "   target triple  : $AGORA_TARGET_TRIPLE"
echo "   bootstrap Swift: $AGORA_BOOTSTRAP_VERSION"
echo "   host cc        : $AGORA_HOST_CC"
echo "=============================================================="

# --- 0. Agora itself must be built ------------------------------------------
if [[ ! -e "$AGORA_PREFIX/lib/libobjc.so" && ! -e "$AGORA_PREFIX/lib/libobjc.so.4.6" ]]; then
  echo "error: Agora's libobjc2 not found under $AGORA_PREFIX/lib." >&2
  echo "       Build libagora-objc (and the rest of the stack), or set AGORA_PREFIX." >&2
  exit 1
fi
if [[ ! -f "$AGORA_PREFIX/include/Foundation/Foundation.h" ]]; then
  echo "error: Agora's Foundation headers not found under $AGORA_PREFIX/include." >&2
  exit 1
fi

# --- optional host dependency check -----------------------------------------
MISSING_DEPS=()
for h in curl/curl.h editline/readline.h; do
  # Debian/Ubuntu install these under the multiarch include dir, so a plain
  # /usr/include/$h test is a false negative. Check the glob too.
  if [[ ! -e "/usr/include/$h" ]] && ! compgen -G "/usr/include/*/$h" >/dev/null; then
    MISSING_DEPS+=("$h")
  fi
done
if (( ${#MISSING_DEPS[@]} )); then
  echo
  echo "WARNING: some development headers are missing: ${MISSING_DEPS[*]}"
  echo "  curl/curl.h          <- libcurl4-openssl-dev (swift-corelibs-foundation)"
  echo "  editline/readline.h  <- libedit-dev            (the Swift driver/REPL)"
  echo "  Install them, e.g.:"
  echo "    sudo apt-get install -y libcurl4-openssl-dev libedit-dev"
  if [[ "${AGORA_INSTALL_DEPS:-0}" == "1" ]]; then
    echo "  AGORA_INSTALL_DEPS=1 set — installing..."
    sudo apt-get update && sudo apt-get install -y libcurl4-openssl-dev libedit-dev
  else
    echo "  (set AGORA_INSTALL_DEPS=1 to have this script run that for you)"
  fi
  echo
fi

# --- 1 & 2. tools -----------------------------------------------------------
skip_contains bootstrap || "$SCRIPTS/install-bootstrap-swift.sh"
skip_contains tools     || "$SCRIPTS/install-ninja.sh"

# --- 3. sources -------------------------------------------------------------
skip_contains clone || "$SCRIPTS/clone-sources.sh"

# --- 4. Swift-capable libdispatch -------------------------------------------
skip_contains baseline || "$SCRIPTS/build-agora-baseline.sh"

# --- 5. the toolchain -------------------------------------------------------
skip_contains toolchain || "$SCRIPTS/build-swift-toolchain.sh"

echo
echo "=============================================================="
echo " done."
echo "   toolchain : $OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr"
echo "   run       : PATH=\"$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr/bin:\$PATH\" swiftc --version"
echo "   probe     : cd swift-interop-probe && \\"
echo "               AGORA_PREFIX=$AGORA_PREFIX \\"
echo "               PATH=\"$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr/bin:\$PATH\" swift run objc-to-swift-probe"
echo "=============================================================="
