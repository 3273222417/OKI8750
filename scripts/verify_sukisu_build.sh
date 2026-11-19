#!/usr/bin/env bash
# Run inside common after make Image, before optional KPatch-Next rewriting.
set -euo pipefail
SUSFS="${1:?SUSFS true or false required}"
case "$SUSFS" in true|false) ;; *) exit 1 ;; esac
grep -qx 'CONFIG_KSU=y' out/.config
grep -qx 'CONFIG_HEADERS_INSTALL=y' out/.config
if [[ "$SUSFS" == true ]]; then
  grep -qx 'CONFIG_KSU_SUSFS=y' out/.config
else
  if grep -qx 'CONFIG_KSU_SUSFS=y' out/.config; then
    echo 'SUSFS unexpectedly enabled' >&2; exit 1
  fi
fi
if grep -qx 'CONFIG_KPM=y' out/.config; then
  echo 'Nova builtin KPM must remain disabled when using KPatch-Next' >&2; exit 1
fi
test -s out/usr/include/linux/unistd.h
test -s out/drivers/kernelsu/preinit/runner.elf
test -s out/arch/arm64/boot/Image
grep -q -- '-DKSU_VERSION=' out/drivers/kernelsu/.*.cmd
echo 'SukiSU-Nova build checks passed (config, UAPI headers, preinit runner, Image).'
