#!/usr/bin/env bash
# Run inside common after make Image, before optional KPatch-Next rewriting.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/sukisu_sources.env"
SUSFS="${1:?SUSFS true or false required}"
case "$SUSFS" in true|false) ;; *) exit 1 ;; esac
grep -qx 'CONFIG_KSU=y' out/.config
grep -qx 'CONFIG_HEADERS_INSTALL=y' out/.config
if [[ "$SUSFS" == true ]]; then
  grep -qx 'CONFIG_KSU_SUSFS=y' out/.config
  nova_cmd=out/drivers/kernelsu/.ksu_main.o.cmd
else
  if grep -qx 'CONFIG_KSU_SUSFS=y' out/.config; then
    echo 'SUSFS unexpectedly enabled' >&2; exit 1
  fi
  nova_cmd=out/drivers/kernelsu/core/.init.o.cmd
fi
if grep -qx 'CONFIG_KPM=y' out/.config; then
  echo 'Nova builtin KPM must remain disabled when using KPatch-Next' >&2; exit 1
fi
test -s out/usr/include/linux/unistd.h
test -s out/drivers/kernelsu/preinit/runner.elf
test -s out/arch/arm64/boot/Image
if ! grep -Eq -- "(^|[[:space:]])-DKSU_VERSION=$SUKISU_CI_VERSION_CODE([[:space:]]|$)" "$nova_cmd"; then
  echo "SukiSU-Nova compile flags do not match CI $SUKISU_CI_VERSION_CODE: $nova_cmd" >&2
  exit 1
fi
echo "SukiSU-Nova CI $SUKISU_CI_VERSION_CODE build checks passed (config, UAPI headers, preinit runner, Image)."
