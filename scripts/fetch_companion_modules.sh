#!/usr/bin/env bash
# Fetch the current companion modules for the same rolling Nova build.
# Usage: bash scripts/fetch_companion_modules.sh output_dir true|false
set -euo pipefail

OUT="$(mkdir -p -- "${1:?output directory required}" && cd -- "$1" && pwd)"
NOMOUNT="${2:?true or false required}"
case "$NOMOUNT" in true|false) ;; *) exit 1 ;; esac
mkdir -p "$OUT"

AUTH_ARGS=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  AUTH_ARGS=(-H "Authorization: Bearer $GITHUB_TOKEN")
elif [[ -n "${GH_TOKEN:-}" ]]; then
  AUTH_ARGS=(-H "Authorization: Bearer $GH_TOKEN")
fi

get_release_asset() {
  local repo="$1" pattern="$2" output="$3" label="$4"
  local json tag url
  json="$(curl -fsSL --retry 4 --retry-delay 3 --retry-all-errors \
    "${AUTH_ARGS[@]}" "https://api.github.com/repos/$repo/releases/latest")"
  tag="$(jq -r '.tag_name // empty' <<<"$json")"
  url="$(jq -r --arg pattern "$pattern" '[.assets[]? | select(.name | test($pattern; "i")) | .browser_download_url][0] // empty' <<<"$json")"
  [[ -n "$url" && "$url" != null ]] || { echo "No $label asset in $repo release $tag" >&2; return 1; }
  local file="$OUT/$output"
  curl -fsSL --retry 4 --retry-delay 3 --retry-all-errors -o "$file" "$url"
  unzip -t "$file" >/dev/null
  printf '%s=%s\n' "${label^^}_RELEASE" "$tag" >> "$OUT/companion-source.txt"
  printf '%s=%s\n' "${label^^}_FILE" "$(basename "$file")" >> "$OUT/companion-source.txt"
  printf '%s=%s\n' "${label^^}__SOURCE_ASSET" "$(basename "$url")" >> "$OUT/companion-source.txt"
}

get_release_asset 'sidex15/susfs4ksu-module' 'ksu_module_susfs.*[.]zip$' susfs-latest.zip susfs
if [[ "$NOMOUNT" == true ]]; then
  get_release_asset 'maxsteeel/nomount' '[.]zip$' nomount-latest.zip nomount
fi
