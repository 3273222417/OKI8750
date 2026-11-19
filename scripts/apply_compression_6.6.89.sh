#!/usr/bin/env bash
# Apply the SM8750 6.6.89 compression patches without silently dropping hunks.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="$(cd -- "${1:?kernel source directory required}" && pwd)"
cd "$COMMON"

# An archive may be nested inside the Actions checkout. git apply run from
# a repository subdirectory skips paths outside that subdirectory.
if [[ ! -e .git ]]; then
  git init -q
fi
lz4="$ROOT/zram_patch/001-lz4.patch"
zstd="$ROOT/zram_patch/002-zstd.patch"
zstd_stream() {
  # 6.6.89 already carries the GCC >= 11 BMI2 check. Keep the vendor
  # condition, while updating the rest of the ZSTD portability header.
  if grep -Fq '&& (__GNUC__ >= 11)))' lib/zstd/common/portability_macros.h; then
    sed -e 's/\r$//' -e 's/(__GNUC__ >= 5 || (__GNUC__ == 4 \&\& __GNUC_MINOR__ >= 8))))/(__GNUC__ >= 11)))/' "$zstd"
  else
    sed 's/\r$//' "$zstd"
  fi
}

sed 's/\r$//' "$lz4" | git -c core.autocrlf=false apply --check -p1 -
zstd_stream | patch --batch --forward --dry-run -p1 -F 3
sed 's/\r$//' "$lz4" | git -c core.autocrlf=false apply -p1 -
zstd_stream | patch --batch --forward -p1 -F 3
for entry in 'MAJOR 1' 'MINOR 10' 'RELEASE 0'; do
  grep -Eq "^#define LZ4_VERSION_${entry% *}[[:space:]]+${entry#* }\b" lib/lz4/lz4.h
done
for entry in 'MAJOR 1' 'MINOR 5' 'RELEASE 7'; do
  grep -Eq "^#define ZSTD_VERSION_${entry% *}[[:space:]]+${entry#* }\b" include/linux/zstd_lib.h
done
echo 'Verified LZ4 1.10.0 and ZSTD 1.5.7 sources.'
