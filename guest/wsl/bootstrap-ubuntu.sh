#!/usr/bin/env bash
# Only for the separately imported, project-owned ARM64 WSL distribution.
set -Eeuo pipefail
[[ $(id -u) == 0 && $(uname -m) == aarch64 ]] || { echo 'Root in ARM64 WSL is required.' >&2; exit 1; }
grep -qi microsoft /proc/sys/kernel/osrelease || { echo 'WSL is required.' >&2; exit 1; }
[[ $(cat /etc/sparkdroid-wsl 2>/dev/null) == SPARKDROID-WSL1 ]] || { echo 'Missing SPARKDROID ownership marker.' >&2; exit 1; }
case "${1:-configure}" in
  configure)
    python3 - <<'PY'
from pathlib import Path
import configparser
path = Path('/etc/wsl.conf')
config = configparser.ConfigParser(interpolation=None)
if path.exists():
    config.read(path)
changed = config.get('boot', 'systemd', fallback='false').lower() != 'true'
if changed:
    if not config.has_section('boot'):
        config.add_section('boot')
    config.set('boot', 'systemd', 'true')
    if path.exists() and not Path('/etc/wsl.conf.before-sparkdroid').exists():
        Path('/etc/wsl.conf.before-sparkdroid').write_bytes(path.read_bytes())
    with path.open('w') as output:
        config.write(output)
print(f'SYSTEMD_CONFIG_CHANGED={int(changed)}')
PY
    ;;
  dependencies)
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o Acquire::Retries=3 update
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
      ca-certificates python3 kmod libegl1 libegl-mesa0 libgles2 libgl1-mesa-dri libx11-6 \
      mesa-utils vulkan-tools
    ;;
  *) echo 'Expected configure or dependencies.' >&2; exit 1 ;;
esac
