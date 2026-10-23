#!/usr/bin/env bash
#
# verify-foundation-parity.sh — the Foundation-surface gate.
#
# Extracts two symbol graphs and diffs them:
#
#   reference  the Linux Foundation the bootstrap toolchain ships (the same
#              swift-foundation API Darwin has) — the API baseline;
#   ours       Agora's Foundation: the Objective-C classes imported through the
#              probe module map, plus swift-toolchain/foundation-overlay/.
#
#   --report            human diff (default)
#   --check             gate: fails on an unallowlisted or grown gap, and on a
#                       stale allowlist count
#   --update-allowlist  rewrite the counts in place (review the diff)
#   --keep              keep the extracted graphs (AGORA_PARITY_DIR, below)
#
# The plan and the staging vocabulary are in
# ../SWIFT-FOUNDATION-PARITY-PLAN.md.
#
# Note on the toolchain: `swift-symbolgraph-extract` is swift-frontend, and a
# plain install resolves the *target* stdlib through RUNPATH, which is built
# against Agora. Put the toolchain's host runtime first on the loader path so
# the tool runs on the compiler's own stdlib, like `swiftc` does.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_ROOT="$(cd "$HERE/.." && pwd)"
AGORA_ROOT="${AGORA_ROOT:-$(cd "$TOOLCHAIN_ROOT/.." && pwd)}"

: "${AGORA_PREFIX:=$AGORA_ROOT/build-prefix}"
: "${AGORA_SWIFT_ROOT:=$HOME/.agora-swift}"
: "${OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN:=$AGORA_SWIFT_ROOT/bootstrap/usr}"
: "${OPEN_SWIFT_TOOLCHAIN_DESTDIR:=$AGORA_SWIFT_ROOT/toolchain}"
: "${AGORA_PARITY_DIR:=${TMPDIR:-/tmp}/agora-foundation-parity}"

BOOTSTRAP_SWIFTLIB="$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/lib/swift/linux"
OUR_SWIFTLIB="$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr/lib/swift/linux"
OUR_HOST_RUNTIME="$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr/lib/swift/host/runtime"
MODULE_MAP="$AGORA_ROOT/swift-interop-probe/agora-modules/module.modulemap"
ALLOWLIST="$TOOLCHAIN_ROOT/parity/foundation-allowlist.txt"
TARGET="x86_64-unknown-linux-gnu"

MODE=--report
KEEP=0
for arg in "$@"; do
  case "$arg" in
    --report) MODE=--report ;;
    --check) MODE=--check ;;
    --update-allowlist) MODE=--update-allowlist ;;
    --keep) KEEP=1 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

for path in \
  "$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/bin/swift-symbolgraph-extract" \
  "$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr/bin/swift-symbolgraph-extract" \
  "$MODULE_MAP" \
  "$AGORA_PREFIX/include/Foundation/Foundation.h"; do
  if [[ ! -e "$path" ]]; then
    echo "error: missing $path" >&2
    exit 1
  fi
done

if [[ "$MODE" == --check || "$MODE" == --update-allowlist ]]; then
  if [[ ! -e "$ALLOWLIST" ]]; then
    echo "error: missing allowlist $ALLOWLIST" >&2
    exit 1
  fi
fi

if [[ "${KEEP:-0}" != "1" ]]; then rm -rf "$AGORA_PARITY_DIR"; fi
mkdir -p "$AGORA_PARITY_DIR/reference" "$AGORA_PARITY_DIR/ours" \
         "$AGORA_PARITY_DIR/module-cache-reference" \
         "$AGORA_PARITY_DIR/module-cache-ours"

# `import Foundation` on Darwin is one surface over three modules; extract all
# three so the value types, coders and formatters are measured, not just the
# Objective-C classes Foundation itself declares.
REFERENCE_MODULES=(Foundation FoundationEssentials FoundationInternationalization)
for module in "${REFERENCE_MODULES[@]}"; do
  echo "== reference: $module ($BOOTSTRAP_SWIFTLIB) =="
  mkdir -p "$AGORA_PARITY_DIR/reference/$module"
  LD_LIBRARY_PATH="$BOOTSTRAP_SWIFTLIB" \
  "$OPEN_SWIFT_BOOTSTRAP_TOOLCHAIN/bin/swift-symbolgraph-extract" \
    -module-name "$module" \
    -target "$TARGET" \
    -I "$BOOTSTRAP_SWIFTLIB" \
    -module-cache-path "$AGORA_PARITY_DIR/module-cache-reference" \
    -output-dir "$AGORA_PARITY_DIR/reference/$module"
done

echo "== ours: $OUR_SWIFTLIB =="
LD_LIBRARY_PATH="$OUR_HOST_RUNTIME:$AGORA_PREFIX/lib" \
"$OPEN_SWIFT_TOOLCHAIN_DESTDIR/usr/bin/swift-symbolgraph-extract" \
  -module-name Foundation \
  -target "$TARGET" \
  -I "$OUR_SWIFTLIB" \
  -Xcc -fmodule-map-file="$MODULE_MAP" \
  -Xcc -I"$AGORA_PREFIX/include" \
  -Xcc -Wno-incomplete-umbrella \
  -Xcc -I"$OUR_SWIFTLIB/foundation-c-modules/FoundationCShims" \
  -Xcc -I"$OUR_SWIFTLIB/foundation-c-modules/FoundationICU" \
  -module-cache-path "$AGORA_PARITY_DIR/module-cache-ours" \
  -output-dir "$AGORA_PARITY_DIR/ours"

REFERENCE_ARGS=()
for module in "${REFERENCE_MODULES[@]}"; do
  REFERENCE_ARGS+=(--reference "$AGORA_PARITY_DIR/reference/$module")
done

case "$MODE" in
  --report)
    exec python3 "$HERE/foundation-parity-diff.py" \
      "${REFERENCE_ARGS[@]}" \
      --ours "$AGORA_PARITY_DIR/ours" \
      --allowlist "$ALLOWLIST" --report
    ;;
  --check)
    python3 "$HERE/foundation-parity-diff.py" \
      "${REFERENCE_ARGS[@]}" \
      --ours "$AGORA_PARITY_DIR/ours" \
      --allowlist "$ALLOWLIST" --check
    status=$?
    ;;
  --update-allowlist)
    python3 "$HERE/foundation-parity-diff.py" \
      "${REFERENCE_ARGS[@]}" \
      --ours "$AGORA_PARITY_DIR/ours" \
      --allowlist "$ALLOWLIST" --update-allowlist "$ALLOWLIST"
    status=$?
    ;;
esac

if [[ "$KEEP" -eq 0 ]]; then
  rm -rf "$AGORA_PARITY_DIR/module-cache-reference" \
         "$AGORA_PARITY_DIR/module-cache-ours"
fi

exit "${status:-0}"
