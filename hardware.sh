#!/usr/bin/env bash
# Print one supported controller path. Refuse absent or ambiguous hardware.
# The optional sysfs root permits tests without changing hardware state.
find_drd_controller() {
    local root=${1:-/sys/bus/pci/devices} candidate
    local candidates=()
    for candidate in "$root"/*; do
        [[ -f $candidate/vendor && -f $candidate/device ]] || continue
        [[ $(cat "$candidate/vendor") == 0x1022 && $(cat "$candidate/device") == 0x163a ]] || continue
        candidates+=("$candidate")
    done
    [[ ${#candidates[@]} == 1 ]] || { echo 'Expected one supported AMD DRD controller. Check firmware USB dual-role mode.' >&2; return 1; }
    printf '%s\n' "${candidates[0]}"
}
# Print the AMD render device name, requiring an unambiguous selection.
find_render_node() {
    local root=${1:-/sys/class/drm} node
    local nodes=()
    for node in "$root"/renderD*; do
        [[ -e $node/device/driver ]] || continue
        [[ $(basename "$(readlink -f "$node/device/driver")") == amdgpu ]] || continue
        nodes+=("${node##*/}")
    done
    [[ ${#nodes[@]} == 1 ]] || { echo 'Set VAAPI_DEVICE to the intended render node.' >&2; return 1; }
    printf '/dev/dri/%s\n' "${nodes[0]}"
}
