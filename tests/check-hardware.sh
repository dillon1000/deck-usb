#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
source ./scripts/hardware.sh
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
mkdir -p "$root/pci" "$root/drm" "$root/drivers/amdgpu"
! find_drd_controller "$root/pci" 2>/dev/null
mkdir "$root/pci/arbitrary-address"
printf '0x1022' > "$root/pci/arbitrary-address/vendor"
printf '0x163a' > "$root/pci/arbitrary-address/device"
[[ $(find_drd_controller "$root/pci") == "$root/pci/arbitrary-address" ]]
cp -R "$root/pci/arbitrary-address" "$root/pci/second"
! find_drd_controller "$root/pci" 2>/dev/null
! find_render_node "$root/drm" 2>/dev/null
mkdir -p "$root/drm/renderD999/device"
ln -s "$root/drivers/amdgpu" "$root/drm/renderD999/device/driver"
[[ $(find_render_node "$root/drm") == /dev/dri/renderD999 ]]
mkdir -p "$root/drm/renderD888/device"
ln -s "$root/drivers/amdgpu" "$root/drm/renderD888/device/driver"
! find_render_node "$root/drm" 2>/dev/null
printf 'Hardware discovery: PASS\n'
