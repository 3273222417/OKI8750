#!/usr/bin/env bash
# Usage: bash scripts/setup_sukisu.sh kernel_workspace true|false
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/sukisu_sources.env"

WORKSPACE="$(cd -- "${1:?kernel workspace required}" && pwd)"
SUSFS="${2:?SUSFS true or false required}"
case "$SUSFS" in
  true) BRANCH=builtin ;;
  false) BRANCH=main ;;
  *) echo "SUSFS must be true or false" >&2; exit 1 ;;
esac
test -d "$WORKSPACE/common/drivers"
test ! -e "$WORKSPACE/KernelSU" || { echo 'KernelSU already exists; use a clean workspace' >&2; exit 1; }

# Keep history for the commit-count version formula, but omit blobs until the
# selected main/builtin checkout is needed. This is materially faster on CI.
if ! git clone --filter=blob:none --no-tags --no-checkout --single-branch --branch main \
  "$SUKISU_REPOSITORY" "$WORKSPACE/KernelSU"; then
  rm -rf "$WORKSPACE/KernelSU"
  git clone --no-tags --no-checkout --single-branch --branch main \
    "$SUKISU_REPOSITORY" "$WORKSPACE/KernelSU"
fi
MAIN_COMMIT="$(git -C "$WORKSPACE/KernelSU" rev-parse refs/remotes/origin/main)"
git -C "$WORKSPACE/KernelSU" cat-file -e "$MAIN_COMMIT^{commit}"
test "$(git -C "$WORKSPACE/KernelSU" rev-parse --is-shallow-repository)" = false
COUNT="$(git -C "$WORKSPACE/KernelSU" rev-list --count "$MAIN_COMMIT")"
VERSION=$((SUKISU_VERSION_BASE + COUNT + SUKISU_VERSION_OFFSET))

release_json=''
assets=''
manager_version=''
manager_tag=''
manager_target=''
for attempt in $(seq 1 "$SUKISU_CI_MAX_ATTEMPTS"); do
  release_json="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 45 \
    -H 'Cache-Control: no-cache' "$SUKISU_CI_API/releases/tags/$SUKISU_CI_TAG")" || release_json=''
  if [[ -n "$release_json" ]]; then
    manager_tag="$(jq -r '.tag_name // empty' <<<"$release_json")"
    manager_target="$(jq -r '.target_commitish // empty' <<<"$release_json")"
    if [[ ! "$manager_target" =~ ^[0-9a-f]{40}$ ]]; then
      manager_target="$(git ls-remote "$SUKISU_REPOSITORY" \
        refs/heads/main 2>/dev/null | awk 'NR==1 {print $1}')"
    fi
    assets="$(jq -r '[.assets[]? | select(.name | test("release[.]apk$"; "i")) | select(.name | test("debug|spoofed"; "i") | not) | [.name, .browser_download_url] | @tsv] | sort_by(if (.[0] | test("arm64-v8a"; "i")) then 0 elif (.[0] | test("universal"; "i")) then 1 else 2 end) | .[]' <<<"$release_json")"
    first_name="$(head -n 1 <<<"$assets" | cut -f1)"
    if [[ "$first_name" =~ _([0-9]+)(-([a-z0-9-]+))?-release[.]apk$ ]]; then
      manager_version="${BASH_REMATCH[1]}"
    else
      manager_version=''
    fi
  fi
  if [[ "$manager_target" == "$MAIN_COMMIT" && "$manager_version" == "$VERSION" && -n "$assets" ]]; then
    break
  fi
  if [[ "$attempt" -eq "$SUKISU_CI_MAX_ATTEMPTS" ]]; then
    printf 'SukiSU-Nova manager-ci is not ready for main=%s (expected version=%s, release target=%s, APK version=%s)\n' \
      "$MAIN_COMMIT" "$VERSION" "$manager_target" "${manager_version:-unknown}" >&2
    exit 1
  fi
  echo "manager-ci is ${manager_version:-unavailable}, main is $VERSION; waiting for the matching latest CI build ($attempt/$SUKISU_CI_MAX_ATTEMPTS)"
  sleep "$SUKISU_CI_RETRY_SECONDS"
done

manager_name="$(head -n 1 <<<"$assets" | cut -f1)"
if [[ "$manager_name" =~ _v?([0-9]+[.][0-9]+[.][0-9]+)_${manager_version}- ]]; then
  manager_name="${BASH_REMATCH[1]}"
else
  manager_name="$manager_tag"
fi

if ! git -C "$WORKSPACE/KernelSU" cat-file -e "refs/remotes/origin/$BRANCH^{commit}" 2>/dev/null; then
  if ! git -C "$WORKSPACE/KernelSU" fetch --filter=blob:none --no-tags origin \
    "refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"; then
    git -C "$WORKSPACE/KernelSU" fetch --no-tags origin \
      "refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
  fi
fi
COMMIT="$(git -C "$WORKSPACE/KernelSU" rev-parse "refs/remotes/origin/$BRANCH")"
git -C "$WORKSPACE/KernelSU" checkout --detach "$COMMIT"
test "$(git -C "$WORKSPACE/KernelSU" rev-parse HEAD)" = "$COMMIT"
BUILTIN_COMMIT=""
if git -C "$WORKSPACE/KernelSU" cat-file -e refs/remotes/origin/builtin^{commit} 2>/dev/null; then
  BUILTIN_COMMIT="$(git -C "$WORKSPACE/KernelSU" rev-parse refs/remotes/origin/builtin)"
fi
python3 "$SCRIPT_DIR/prepare_sukisu.py" "$WORKSPACE" --susfs "$SUSFS" \
  --version "$VERSION" --count "$COUNT" --ref "$MAIN_COMMIT" --tag "$manager_name"

mkdir -p "$WORKSPACE/manager-artifacts"
manager_asset_line="$(head -n 1 <<< "$assets")"
IFS=$'\t' read -r manager_asset_name manager_asset_url <<< "$manager_asset_line"
test -n "$manager_asset_name" && test -n "$manager_asset_url"
curl -fsSL --retry 3 --max-time 300 \
  -o "$WORKSPACE/manager-artifacts/$manager_asset_name" "$manager_asset_url"
test -n "$(find "$WORKSPACE/manager-artifacts" -type f -name '*release.apk' -print -quit)"

printf 'SukiSU-Nova: branch=%s commit=%s main=%s version=%s manager=%s\n' "$BRANCH" "$COMMIT" "$MAIN_COMMIT" "$VERSION" "$manager_name"
printf 'source=%s\nbranch=%s\ncommit=%s\nversion_source=%s\nKSUVER=%s\nci_release=%s\nci_target=%s\nmanager_version=%s\nmanager_name=%s\n' \
  "$SUKISU_REPOSITORY" "$BRANCH" "$COMMIT" "$MAIN_COMMIT" "$VERSION" "$SUKISU_CI_RELEASE_URL" "$manager_target" "$manager_version" "$manager_name" \
  > "$WORKSPACE/sukisu-source.txt"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'KSUVER=%s\nSUKISU_CI_VERSION_CODE=%s\nSUKISU_MAIN_COMMIT=%s\nSUKISU_BUILTIN_COMMIT=%s\nSUKISU_COMMIT=%s\nSUKISU_BRANCH=%s\n' \
    "$VERSION" "$VERSION" "$MAIN_COMMIT" "$BUILTIN_COMMIT" "$COMMIT" "$BRANCH" >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'ksuver=%s\nmanager_version=%s\nmain_commit=%s\nbuiltin_commit=%s\n' \
    "$VERSION" "$manager_version" "$MAIN_COMMIT" "$BUILTIN_COMMIT" >> "$GITHUB_OUTPUT"
fi
