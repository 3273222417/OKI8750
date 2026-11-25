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

# The project moved from the Forgejo mirror to GitHub. Keep the mirror as a
# commit-level fallback because an already-published manager-ci build can point
# to a commit that has not been copied into the renamed GitHub repository yet.
clone_source() {
  local url="$1"
  rm -rf "$WORKSPACE/KernelSU"
  if git clone --filter=blob:none --no-tags --no-checkout --single-branch --branch main \
    "$url" "$WORKSPACE/KernelSU"; then
    return 0
  fi
  rm -rf "$WORKSPACE/KernelSU"
  git clone --no-tags --no-checkout --single-branch --branch main \
    "$url" "$WORKSPACE/KernelSU"
}

if clone_source "$SUKISU_REPOSITORY"; then
  SOURCE_REMOTE=origin
else
  echo "Official SukiSU-Nova repository unavailable; using the historical CI mirror" >&2
  clone_source "$SUKISU_REPOSITORY_FALLBACK"
  SOURCE_REMOTE=origin
fi

if [[ -n "${SUKISU_REPOSITORY_FALLBACK:-}" && "$SOURCE_REMOTE" != ci-source ]]; then
  git -C "$WORKSPACE/KernelSU" remote add ci-source "$SUKISU_REPOSITORY_FALLBACK"
fi

fetch_source_branch() {
  local remote="$1" branch="$2"
  if ! git -C "$WORKSPACE/KernelSU" fetch --filter=blob:none --no-tags "$remote" \
    "+refs/heads/$branch:refs/remotes/$remote/$branch"; then
    git -C "$WORKSPACE/KernelSU" fetch --no-tags "$remote" \
      "+refs/heads/$branch:refs/remotes/$remote/$branch"
  fi
}

fetch_source_branch "$SOURCE_REMOTE" main
CURRENT_MAIN_COMMIT="$(git -C "$WORKSPACE/KernelSU" rev-parse "refs/remotes/$SOURCE_REMOTE/main")"
git -C "$WORKSPACE/KernelSU" cat-file -e "$CURRENT_MAIN_COMMIT^{commit}"
test "$(git -C "$WORKSPACE/KernelSU" rev-parse --is-shallow-repository)" = false

# Select the remote that contains the commit named by the current manager-ci
# manifest. This prevents a new APK from being paired with an unrelated source
# history after a repository migration.
select_target_source() {
  local target="$1" remote
  local remotes=("$SOURCE_REMOTE")
  if git -C "$WORKSPACE/KernelSU" remote get-url ci-source >/dev/null 2>&1 &&
      [[ "$SOURCE_REMOTE" != ci-source ]]; then
    remotes+=(ci-source)
  fi
  for remote in "${remotes[@]}"; do
    if ! fetch_source_branch "$remote" main; then
      continue
    fi
    if git -C "$WORKSPACE/KernelSU" cat-file -e "$target^{commit}" 2>/dev/null &&
        git -C "$WORKSPACE/KernelSU" merge-base --is-ancestor "$target" \
          "refs/remotes/$remote/main"; then
      SOURCE_REMOTE="$remote"
      CURRENT_MAIN_COMMIT="$(git -C "$WORKSPACE/KernelSU" rev-parse "refs/remotes/$remote/main")"
      return 0
    fi
  done
  return 1
}

refresh_main() {
  fetch_source_branch "$SOURCE_REMOTE" main || return 1
  CURRENT_MAIN_COMMIT="$(git -C "$WORKSPACE/KernelSU" rev-parse "refs/remotes/$SOURCE_REMOTE/main")" || return 1
  git -C "$WORKSPACE/KernelSU" cat-file -e "$CURRENT_MAIN_COMMIT^{commit}" || return 1
}

extract_manifest_target() {
  jq -r '.body // empty' | sed -nE 's/.*Commit:[[:space:]]*`([0-9a-f]{40})`.*/\1/p' | head -n 1
}

extract_manager_version() {
  local name="$1"
  if [[ "$name" =~ _([0-9]+)(-([a-z0-9-]+))?-release\.apk$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

release_json=''
assets=''
manager_version=''
manager_tag=''
manager_target=''
manager_release_url="$SUKISU_CI_RELEASE_URL"
target_count=''
target_is_ancestor=false

for attempt in $(seq 1 "$SUKISU_CI_MAX_ATTEMPTS"); do
  release_json=''
  manifest_json=''
  assets=''
  manager_version=''
  manager_tag=''
  manager_target=''
  manager_release_url="$SUKISU_CI_RELEASE_URL"
  target_count=''
  target_is_ancestor=false

  if ! refresh_main; then
    if [[ "$attempt" -eq "$SUKISU_CI_MAX_ATTEMPTS" ]]; then
      echo "Unable to refresh SukiSU-Nova main after $attempt attempts" >&2
      exit 1
    fi
    echo "Unable to refresh SukiSU-Nova main; retrying ($attempt/$SUKISU_CI_MAX_ATTEMPTS)" >&2
    sleep "$SUKISU_CI_RETRY_SECONDS"
    continue
  fi

  # CNB publishes a manifest containing the manager target commit and direct
  # /-/git/raw APK URLs. The Forgejo response is retained for older CI builds.
  manifest_json="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 45 \
    -H 'Cache-Control: no-cache' "$SUKISU_CI_MANIFEST_URL")" || manifest_json=''
  release_json=''

  manager_tag="$(jq -r '.tag_name // empty' <<<"$manifest_json" 2>/dev/null || true)"
  manager_target="$(extract_manifest_target <<<"$manifest_json")"
  manager_version="$(jq -r '.name // empty' <<<"$manifest_json" 2>/dev/null | sed -nE 's/.*\(([0-9]+)\).*/\1/p' | head -n 1)"
  assets="$(jq -r '[.assets[]? | select(.name | test("release[.]apk$"; "i")) | select(.name | test("arm64-v8a|universal"; "i")) | select(.name | test("debug|spoofed"; "i") | not) | [.name, .browser_download_url] | @tsv] | .[]' <<<"$manifest_json" 2>/dev/null | sort -t $'\t' -k1,1 || true)"

  if [[ -z "$manager_target" || -z "$assets" ]]; then
    release_json="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 45 \
      -H 'Cache-Control: no-cache' "$SUKISU_CI_API/releases/tags/$SUKISU_CI_TAG")" || release_json=''
  fi
  if [[ -z "$manager_target" && -n "$release_json" ]]; then
    manager_tag="$(jq -r '.tag_name // empty' <<<"$release_json")"
    manager_target="$(jq -r '.target_commitish // empty' <<<"$release_json")"
    manager_version="$(jq -r '.name // empty' <<<"$release_json" 2>/dev/null | sed -nE 's/.*\(([0-9]+)\).*/\1/p' | head -n 1)"
  fi
  if [[ -z "$assets" && -n "$release_json" ]]; then
    assets="$(jq -r '[.assets[]? | select(.name | test("release[.]apk$"; "i")) | select(.name | test("arm64-v8a|universal"; "i")) | select(.name | test("debug|spoofed"; "i") | not) | [.name, .browser_download_url] | @tsv] | .[]' <<<"$release_json" 2>/dev/null | sort -t $'\t' -k1,1 || true)"
  fi

  first_name="$(head -n 1 <<<"$assets" | cut -f1)"
  parsed_version="$(extract_manager_version "$first_name")"
  [[ "$parsed_version" =~ ^[0-9]+$ ]] && manager_version="$parsed_version"

  if [[ -z "$assets" ]]; then
    fallback_html="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 45 \
      -H 'Cache-Control: no-cache' "$SUKISU_CI_FALLBACK_RELEASE_URL")" || fallback_html=''
    if [[ -n "$fallback_html" ]]; then
      if [[ ! "$manager_version" =~ ^[0-9]+$ ]]; then
        manager_version="$(sed -nE 's/.*Manager CI \(([0-9]+)\).*/\1/p' <<<"$fallback_html" | head -n 1)"
      fi
      assets="$(printf '%s' "$fallback_html" | \
        python3 "$SCRIPT_DIR/extract_manager_assets.py" "$SUKISU_CI_FALLBACK_RELEASE_URL" "${manager_version:-0}")"
      manager_release_url="$SUKISU_CI_FALLBACK_RELEASE_URL"
      first_name="$(head -n 1 <<<"$assets" | cut -f1)"
      parsed_version="$(extract_manager_version "$first_name")"
      [[ "$parsed_version" =~ ^[0-9]+$ ]] && manager_version="$parsed_version"
    fi
  fi

  if [[ "$manager_target" =~ ^[0-9a-f]{40}$ ]] && select_target_source "$manager_target"; then
    target_count="$(git -C "$WORKSPACE/KernelSU" rev-list --count "$manager_target")"
    target_is_ancestor=true
  fi

  # The manager version is authoritative for the numeric code; the source SHA
  # and complete history count are still recorded for reproducible provenance.
  if [[ "$target_is_ancestor" == true && "$manager_version" =~ ^[0-9]+$ && \
      "$manager_version" -ge "$SUKISU_VERSION_BASE" && -n "$assets" ]]; then
    MAIN_COMMIT="$manager_target"
    COUNT="$target_count"
    VERSION="$manager_version"
    break
  fi
  if [[ "$attempt" -eq "$SUKISU_CI_MAX_ATTEMPTS" ]]; then
    printf 'SukiSU-Nova manager-ci is not ready for current main=%s (release target=%s, manager version=%s)\n' \
      "$CURRENT_MAIN_COMMIT" "$manager_target" "${manager_version:-unknown}" >&2
    exit 1
  fi
  echo "manager-ci is ${manager_version:-unavailable}, current main is $CURRENT_MAIN_COMMIT; waiting for the matching CI build ($attempt/$SUKISU_CI_MAX_ATTEMPTS)"
  sleep "$SUKISU_CI_RETRY_SECONDS"
done

manager_name="$(head -n 1 <<<"$assets" | cut -f1)"
if [[ "$manager_name" =~ _v?([0-9]+[.][0-9]+[.][0-9]+)(-[^_]+)?_${manager_version}- ]]; then
  manager_name="${BASH_REMATCH[1]}"
else
  manager_name="$manager_tag"
fi

fetch_source_branch "$SOURCE_REMOTE" "$BRANCH"
if [[ "$BRANCH" == main ]]; then
  COMMIT="$MAIN_COMMIT"
else
  COMMIT="$(git -C "$WORKSPACE/KernelSU" rev-parse "refs/remotes/$SOURCE_REMOTE/$BRANCH")"
fi
git -C "$WORKSPACE/KernelSU" checkout --detach "$COMMIT"
test "$(git -C "$WORKSPACE/KernelSU" rev-parse HEAD)" = "$COMMIT"
BUILTIN_COMMIT=''
if git -C "$WORKSPACE/KernelSU" cat-file -e "refs/remotes/$SOURCE_REMOTE/builtin^{commit}" 2>/dev/null; then
  BUILTIN_COMMIT="$(git -C "$WORKSPACE/KernelSU" rev-parse "refs/remotes/$SOURCE_REMOTE/builtin")"
fi

python3 "$SCRIPT_DIR/prepare_sukisu.py" "$WORKSPACE" --susfs "$SUSFS" \
  --version "$VERSION" --count "$COUNT" --ref "$MAIN_COMMIT" --tag "$manager_name"

mkdir -p "$WORKSPACE/manager-artifacts"
manager_asset_line="$(head -n 1 <<<"$assets")"
IFS=$'\t' read -r manager_asset_name manager_asset_url <<< "$manager_asset_line"
test -n "$manager_asset_name" && test -n "$manager_asset_url"
curl -fsSL --retry 3 --max-time 300 \
  -o "$WORKSPACE/manager-artifacts/$manager_asset_name" "$manager_asset_url"
test -n "$(find "$WORKSPACE/manager-artifacts" -type f -name '*release.apk' -print -quit)"

SOURCE_URL="$(git -C "$WORKSPACE/KernelSU" remote get-url "$SOURCE_REMOTE")"
printf 'SukiSU-Nova: branch=%s commit=%s main=%s version=%s manager=%s\n' "$BRANCH" "$COMMIT" "$MAIN_COMMIT" "$VERSION" "$manager_name"
printf 'source=%s\nbranch=%s\ncommit=%s\nversion_source=%s\nKSUVER=%s\nci_release=%s\nci_target=%s\nmanager_version=%s\nmanager_name=%s\nmanager_release_page=%s\nmanager_asset=%s\n' \
  "$SOURCE_URL" "$BRANCH" "$COMMIT" "$MAIN_COMMIT" "$VERSION" "$SUKISU_CI_RELEASE_URL" "$manager_target" "$manager_version" "$manager_name" "$manager_release_url" "$manager_asset_url" \
  > "$WORKSPACE/sukisu-source.txt"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'KSUVER=%s\nSUKISU_CI_VERSION_CODE=%s\nSUKISU_MAIN_COMMIT=%s\nSUKISU_BUILTIN_COMMIT=%s\nSUKISU_COMMIT=%s\nSUKISU_BRANCH=%s\n' \
    "$VERSION" "$VERSION" "$MAIN_COMMIT" "$BUILTIN_COMMIT" "$COMMIT" "$BRANCH" >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'ksuver=%s\nmanager_version=%s\nmain_commit=%s\nbuiltin_commit=%s\n' \
    "$VERSION" "$manager_version" "$MAIN_COMMIT" "$BUILTIN_COMMIT" >> "$GITHUB_OUTPUT"
fi
