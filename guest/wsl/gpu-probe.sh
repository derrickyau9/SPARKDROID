#!/usr/bin/env bash
# Run from inside the SPARKDROID WSL distro; installs nothing and changes no config.
# Usage: bash guest/wsl/gpu-probe.sh /path/to/output-directory
set -u
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
output_dir="${1:-./gpu-probe-results}"
mkdir -p -- "$output_dir" || exit 1
export MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA
export GALLIUM_DRIVER=d3d12

collect() {
    local name="$1"
    shift
    if command -v "$1" >/dev/null 2>&1; then
        timeout 30s "$@" >"$output_dir/$name.txt" 2>&1
        printf '%s\n' "$?" >"$output_dir/$name.exit-code.txt"
    else
        printf 'Command unavailable: %s\n' "$1" >"$output_dir/$name.txt"
        printf '127\n' >"$output_dir/$name.exit-code.txt"
    fi
}

collect uname uname -a
collect glxinfo glxinfo -B
collect eglinfo eglinfo -B
collect vulkaninfo vulkaninfo --summary
python3 "$script_dir/gpu-probe.py" --output "$output_dir/gpu-probe.json" \
    >"$output_dir/gpu-probe.stdout.txt" 2>"$output_dir/gpu-probe.stderr.txt"
probe_status="$?"
printf '%s\n' "$probe_status" >"$output_dir/gpu-probe.exit-code.txt"
cat -- "$output_dir/gpu-probe.stdout.txt"
exit "$probe_status"
