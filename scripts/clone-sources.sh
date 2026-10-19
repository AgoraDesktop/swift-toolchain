#!/usr/bin/env bash
#
# Fetch the sources a Swift toolchain that targets Agora needs.
#
# Derived from OpenSwiftProject/toolchain-docker's scripts/clone-sources.sh.
#
# AGORA CHANGES: the GNUstep clones are gone. Upstream also clones libobjc2,
# tools-make, libs-base and libs-corebase into a gnustep-src/ tree. Agora ships
# its own libobjc2 (libagora-objc) and needs no GNUstep Foundation, so none of
# those are fetched. The Swift fork, LLVM and swift-corelibs-libdispatch are
# unchanged from upstream.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/native-env.sh"

OPEN_SWIFT_GIT_BASE="${OPEN_SWIFT_GIT_BASE:-https://github.com/OpenSwiftProject}"

SWIFT_BRANCH="${SWIFT_BRANCH:-feature/gnu_objc_6.3}"
SWIFT_REVISION="${SWIFT_REVISION:-}"
if [[ -n "$SWIFT_REVISION" && ! "$SWIFT_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
  echo "error: SWIFT_REVISION must be a full lowercase commit SHA" >&2
  exit 1
fi
LLVM_BRANCH="${LLVM_BRANCH:-swift/release/6.3}"
LIBDISPATCH_BRANCH="${LIBDISPATCH_BRANCH:-release/6.3}"

clone_or_update() {
  local repo="$1" dest="$2" ref="$3"
  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" fetch --filter=blob:none --depth 1 origin "$ref"
    git -C "$dest" checkout --detach FETCH_HEAD
  else
    git clone --filter=blob:none --depth 1 --branch "$ref" "$OPEN_SWIFT_GIT_BASE/$repo.git" "$dest"
  fi
}

mkdir -p "$OPEN_SWIFT_SOURCE_ROOT"

clone_or_update swift "$OPEN_SWIFT_SOURCE_ROOT/swift" "$SWIFT_BRANCH"
git -C "$OPEN_SWIFT_SOURCE_ROOT/swift" fetch --filter=blob:none --depth 1 origin release/6.3:refs/remotes/origin/release/6.3
git -C "$OPEN_SWIFT_SOURCE_ROOT/swift" branch --force release/6.3 origin/release/6.3

# Let Swift's release scheme clone the rest of the workspace, then restore the
# Swift fork branch because update-checkout may align it back to release/6.3.
"$OPEN_SWIFT_SOURCE_ROOT/swift/utils/update-checkout" \
  --scheme release/6.3 \
  --source-root "$OPEN_SWIFT_SOURCE_ROOT" \
  --skip-repository swift \
  --skip-history \
  --skip-tags \
  --partial-clone \
  --clone
git -C "$OPEN_SWIFT_SOURCE_ROOT/swift" fetch --filter=blob:none --depth 1 "$OPEN_SWIFT_GIT_BASE/swift.git" "${SWIFT_REVISION:-$SWIFT_BRANCH}"
git -C "$OPEN_SWIFT_SOURCE_ROOT/swift" checkout --detach FETCH_HEAD
if [[ -n "$SWIFT_REVISION" ]]; then
  test "$(git -C "$OPEN_SWIFT_SOURCE_ROOT/swift" rev-parse HEAD)" = "$SWIFT_REVISION"
fi

if [[ -d "$OPEN_SWIFT_SOURCE_ROOT/llvm-project/.git" ]]; then
  git -C "$OPEN_SWIFT_SOURCE_ROOT/llvm-project" remote add osp "$OPEN_SWIFT_GIT_BASE/llvm-project.git" 2>/dev/null || true
  git -C "$OPEN_SWIFT_SOURCE_ROOT/llvm-project" fetch --filter=blob:none --depth 1 osp "$LLVM_BRANCH"
  git -C "$OPEN_SWIFT_SOURCE_ROOT/llvm-project" checkout FETCH_HEAD
fi

if [[ -d "$OPEN_SWIFT_SOURCE_ROOT/swift-corelibs-libdispatch/.git" ]]; then
  git -C "$OPEN_SWIFT_SOURCE_ROOT/swift-corelibs-libdispatch" remote add osp "$OPEN_SWIFT_GIT_BASE/swift-corelibs-libdispatch.git" 2>/dev/null || true
  git -C "$OPEN_SWIFT_SOURCE_ROOT/swift-corelibs-libdispatch" fetch --filter=blob:none --depth 1 osp "$LIBDISPATCH_BRANCH"
  git -C "$OPEN_SWIFT_SOURCE_ROOT/swift-corelibs-libdispatch" checkout FETCH_HEAD
fi

# No GNUstep clones: libobjc2 is Agora's libagora-objc, and libs-base /
# libs-corebase / tools-make are not used.
