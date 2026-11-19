#!/usr/bin/env bash
# Usage: bash scripts/setup_sukisu.sh kernel_workspace true|false
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/sukisu_sources.env"

WORKSPACE="$(cd -- "${1:?kernel workspace required}" && pwd)"
SUSFS="${2:?SUSFS true or false required}"
case "$SUSFS" in
  true) BRANCH=builtin; COMMIT="$SUKISU_BUILTIN_COMMIT" ;;
  false) BRANCH=main; COMMIT="$SUKISU_MAIN_COMMIT" ;;
  *) echo "SUSFS must be true or false" >&2; exit 1 ;;
esac
test -d "$WORKSPACE/common/drivers"
test ! -e "$WORKSPACE/KernelSU" || { echo 'KernelSU already exists; use a clean workspace' >&2; exit 1; }

# Do not execute an unpinned remote setup.sh (it clones a different Gitea host).
# Full main history is needed for the manager-compatible version count; blobs
# outside the selected checkout are omitted to keep this fetch small.
git clone --filter=blob:none --no-checkout --single-branch --branch main \
  "$SUKISU_REPOSITORY" "$WORKSPACE/KernelSU"
git -C "$WORKSPACE/KernelSU" cat-file -e "$SUKISU_MAIN_COMMIT^{commit}"
test "$(git -C "$WORKSPACE/KernelSU" rev-parse --is-shallow-repository)" = false
COUNT="$(git -C "$WORKSPACE/KernelSU" rev-list --count "$SUKISU_MAIN_COMMIT")"
VERSION=$((SUKISU_VERSION_BASE + COUNT + SUKISU_VERSION_OFFSET))
TAG="$(git -C "$WORKSPACE/KernelSU" describe --tags --abbrev=0 --match 'v[0-9]*' "$SUKISU_MAIN_COMMIT" 2>/dev/null || printf 'v3.0.0')"
if ! git -C "$WORKSPACE/KernelSU" cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
  git -C "$WORKSPACE/KernelSU" fetch --depth=1 origin "$COMMIT"
fi
git -C "$WORKSPACE/KernelSU" checkout --detach "$COMMIT"
test "$(git -C "$WORKSPACE/KernelSU" rev-parse HEAD)" = "$COMMIT"
python3 "$SCRIPT_DIR/prepare_sukisu.py" "$WORKSPACE" --susfs "$SUSFS" \
  --version "$VERSION" --count "$COUNT" --ref "$SUKISU_MAIN_COMMIT" --tag "${TAG#v}"

printf 'SukiSU-Nova: branch=%s commit=%s main=%s version=%s\n' "$BRANCH" "$COMMIT" "$SUKISU_MAIN_COMMIT" "$VERSION"
printf 'source=%s\nbranch=%s\ncommit=%s\nversion_source=%s\nKSUVER=%s\n' \
  "$SUKISU_REPOSITORY" "$BRANCH" "$COMMIT" "$SUKISU_MAIN_COMMIT" "$VERSION" > "$WORKSPACE/sukisu-source.txt"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'KSUVER=%s\nSUKISU_COMMIT=%s\nSUKISU_BRANCH=%s\n' "$VERSION" "$COMMIT" "$BRANCH" >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'ksuver=%s\n' "$VERSION" >> "$GITHUB_OUTPUT"
fi
