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

# Count the pinned main commit with full history. The rolling manager-ci Git
# tag can lag behind the release assets, so it is not a source ref for builds.
git clone --no-tags --no-checkout --single-branch --branch main \
  "$SUKISU_REPOSITORY" "$WORKSPACE/KernelSU"
git -C "$WORKSPACE/KernelSU" cat-file -e "$SUKISU_MAIN_COMMIT^{commit}"
test "$(git -C "$WORKSPACE/KernelSU" rev-parse --is-shallow-repository)" = false
COUNT="$(git -C "$WORKSPACE/KernelSU" rev-list --count "$SUKISU_MAIN_COMMIT")"
VERSION=$((SUKISU_VERSION_BASE + COUNT + SUKISU_VERSION_OFFSET))
if [[ "$VERSION" != "$SUKISU_CI_VERSION_CODE" ]]; then
  printf 'SukiSU-Nova CI version mismatch: pinned main %s yields %s, expected %s\n' \
    "$SUKISU_MAIN_COMMIT" "$VERSION" "$SUKISU_CI_VERSION_CODE" >&2
  exit 1
fi
if ! git -C "$WORKSPACE/KernelSU" cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
  git -C "$WORKSPACE/KernelSU" fetch --no-tags --depth=1 origin "$COMMIT"
fi
git -C "$WORKSPACE/KernelSU" checkout --detach "$COMMIT"
test "$(git -C "$WORKSPACE/KernelSU" rev-parse HEAD)" = "$COMMIT"
python3 "$SCRIPT_DIR/prepare_sukisu.py" "$WORKSPACE" --susfs "$SUSFS" \
  --version "$VERSION" --count "$COUNT" --ref "$SUKISU_MAIN_COMMIT" --tag "$SUKISU_CI_VERSION_NAME"

printf 'SukiSU-Nova: branch=%s commit=%s main=%s version=%s\n' "$BRANCH" "$COMMIT" "$SUKISU_MAIN_COMMIT" "$VERSION"
printf 'source=%s\nbranch=%s\ncommit=%s\nversion_source=%s\nKSUVER=%s\nci_release=%s\n' \
  "$SUKISU_REPOSITORY" "$BRANCH" "$COMMIT" "$SUKISU_MAIN_COMMIT" "$VERSION" "$SUKISU_CI_RELEASE_URL" \
  > "$WORKSPACE/sukisu-source.txt"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'KSUVER=%s\nSUKISU_COMMIT=%s\nSUKISU_BRANCH=%s\n' "$VERSION" "$COMMIT" "$BRANCH" >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'ksuver=%s\n' "$VERSION" >> "$GITHUB_OUTPUT"
fi
