#!/usr/bin/env bash
# Runs as root only inside the isolated SPARKDROID WSL 2 ARM64 distribution.
# Never changes .wslconfig, the global WSL kernel, or another distribution.
set -Eeuo pipefail
ACTION=${1:-probe}
STATE_DIR=/var/lib/sparkdroid-wsl
LOG_DIR=/var/log/sparkdroid-wsl
CONTAINER_NAME=${SPARKDROID_CONTAINER:-sparkdroid-android-wsl}
ANDROID_IMAGE=${SPARKDROID_ANDROID_IMAGE:-docker.io/redroid/redroid@sha256:e194edc99aa364358d1f8c214acb18b6d006c74fa0561f39259a20173ec30b66}
ADB_PORT=${SPARKDROID_ADB_PORT:-15565}
WIDTH=${SPARKDROID_WIDTH:-540}
HEIGHT=${SPARKDROID_HEIGHT:-960}
FPS=${SPARKDROID_FPS:-60}
DPI=${SPARKDROID_DPI:-180}
GPU_MODE=${SPARKDROID_GPU_MODE:-guest}
GPU_NODE=${SPARKDROID_GPU_NODE:-/dev/dri/renderD128}
BOOT_TIMEOUT=${SPARKDROID_BOOT_TIMEOUT:-480}
fail(){ printf '%s\n' "$*" >&2; exit 1; }
[[ $(id -u) == 0 ]] || fail 'Run as root in the isolated SPARKDROID WSL distribution.'
[[ $(uname -m) == aarch64 ]] || fail 'This backend requires ARM64 Linux.'
grep -qi microsoft /proc/sys/kernel/osrelease || fail 'This entry point is restricted to WSL; use the QEMU guest entry point elsewhere.'
[[ $CONTAINER_NAME =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]] || fail 'Invalid container name.'
for value in "$ADB_PORT" "$WIDTH" "$HEIGHT" "$FPS" "$DPI" "$BOOT_TIMEOUT"; do
  [[ $value =~ ^[1-9][0-9]*$ ]] || fail 'Invalid numeric runtime option.'
done
(( ADB_PORT >= 1024 && ADB_PORT <= 65535 && WIDTH >= 240 && WIDTH <= 3840 && HEIGHT >= 240 && HEIGHT <= 3840 && FPS >= 30 && FPS <= 240 && DPI >= 120 && DPI <= 640 && BOOT_TIMEOUT <= 900 )) || fail 'Runtime option outside supported range.'
[[ $GPU_MODE == guest || $GPU_MODE == host ]] || fail 'GPU mode must be guest or host.'
[[ $ANDROID_IMAGE =~ ^docker\.io/redroid/redroid@sha256:[a-f0-9]{64}$ ]] || fail 'Use a digest-pinned official redroid/redroid image.'
case "$ACTION" in
  start|provision|stop)
    [[ -f /etc/sparkdroid-wsl && $(cat /etc/sparkdroid-wsl) == SPARKDROID-WSL1 ]] || fail 'Missing SPARKDROID ownership marker; refusing to modify this WSL distribution.'
    ;;
esac

kernel_devices(){
  if command -v modprobe >/dev/null; then
    modprobe binder_linux devices=binder,hwbinder,vndbinder 2>/dev/null || true
    modprobe ashmem_linux 2>/dev/null || true
  fi
  if [[ ! -c /dev/binder && -d /sys/module/binder_linux ]]; then
    mkdir -p /dev/binderfs
    if ! mountpoint -q /dev/binderfs; then mount -t binder binder /dev/binderfs; fi
    for node in binder hwbinder vndbinder; do
      if [[ ! -e /dev/$node && -c /dev/binderfs/$node ]]; then ln -s "/dev/binderfs/$node" "/dev/$node"; fi
    done
  fi
  for node in binder hwbinder vndbinder; do
    [[ -c /dev/$node ]] || fail "Missing /dev/$node. The running WSL kernel needs Android Binder devices. No Ubuntu kernel package or global WSL kernel replacement was attempted."
  done
  [[ -c /dev/ashmem ]] || fail 'Missing /dev/ashmem. This pinned Redroid image still needs ashmem for its software gralloc despite androidboot.use_memfd=1. Supply a compatible WSL kernel/module or a separately validated image; pretending memfd fixes it would produce SurfaceFlinger failures.'
}
docker_ready(){
  command -v docker >/dev/null || fail 'Docker is not installed in SPARKDROID. Run Provision first.'
  [[ -d /run/systemd/system ]] || fail 'systemd is not running in this distro. Enable systemd in its /etc/wsl.conf, terminate only SPARKDROID, then retry.'
  systemctl start docker
  docker info >/dev/null
}
probe(){
  printf 'kernel=%s\narchitecture=%s\n' "$(uname -r)" "$(uname -m)"
  for node in /dev/dxg /dev/dri/renderD128 /dev/binder /dev/hwbinder /dev/vndbinder /dev/ashmem; do
    if [[ -c $node ]]; then printf '%s=present\n' "$node"; else printf '%s=absent\n' "$node"; fi
  done
  printf 'systemd=%s\n' "$(test -d /run/systemd/system && echo running || echo absent)"
  printf 'wslg=%s\n' "$(test -d /mnt/wslg && echo present || echo absent)"
  printf '%s\n' 'Note: /dev/dxg and Linux D3D12 support do not establish Android hardware rendering. Android renderer and nonblack frames must be verified separately.'
}
status(){
  local running=false
  if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
    running=$(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || printf false)
  fi
  [[ $running == true ]] || running=false
  printf '{"kernel":"%s","architecture":"%s","containerRunning":%s,"dxgPresent":%s,"binderPresent":%s,"ashmemPresent":%s,"graphicsAccelerationValidated":false}\n' \
    "$(uname -r)" "$(uname -m)" "$running" \
    "$(test -c /dev/dxg && echo true || echo false)" \
    "$(test -c /dev/binder && echo true || echo false)" \
    "$(test -c /dev/ashmem && echo true || echo false)"
}
wait_android(){
  local deadline=$((SECONDS + BOOT_TIMEOUT)) completed=''
  while (( SECONDS < deadline )); do
    completed=$(docker exec "$CONTAINER_NAME" /system/bin/getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
    if [[ $completed == 1 ]]; then
      [[ $(docker exec "$CONTAINER_NAME" getprop ro.product.cpu.abi | tr -d '\r') == arm64-v8a ]] || fail 'Unexpected Android ABI.'
      printf '%s\n' 'Android framework boot completed.'
      return
    fi
    if [[ $(docker inspect --format '{{.State.Running}}' "$CONTAINER_NAME") != true ]]; then
      docker logs --tail 100 "$CONTAINER_NAME" >&2
      fail 'Android stopped before boot completed.'
    fi
    sleep 3
  done
  docker logs --tail 200 "$CONTAINER_NAME" > "$LOG_DIR/android-boot-failure.log" 2>&1 || true
  fail "Android boot timed out. Inspect $LOG_DIR/android-boot-failure.log and kernel device support."
}
start_android(){
  kernel_devices
  docker_ready
  docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1 || fail 'Android container has not been provisioned. Run Provision first.'
  local image data
  image=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER_NAME")
  data=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME")
  [[ $image == "$ANDROID_IMAGE" && $data == "$STATE_DIR/android-data" ]] || fail 'Existing container identity differs; preserving it without starting or replacing it.'
  docker start "$CONTAINER_NAME" >/dev/null
  wait_android
}
provision(){
  export DEBIAN_FRONTEND=noninteractive
  # Preflight before installing tools: ordinary WSL kernels may omit Binder and
  # ashmem, and matching Ubuntu module packages cannot repair a WSL kernel.
  kernel_devices
  [[ -d /run/systemd/system ]] || fail 'Enable systemd in the SPARKDROID distro before provisioning.'
  apt-get -o Acquire::Retries=3 update
  apt-get -o Acquire::Retries=3 install -y --no-install-recommends ca-certificates docker.io jq kmod
  docker_ready
  local gpu_args=("androidboot.redroid_gpu_mode=$GPU_MODE") gpu_devices=()
  if [[ $GPU_MODE == host ]]; then
    [[ $GPU_NODE =~ ^/dev/dri/renderD[0-9]+$ && -c $GPU_NODE ]] || fail "Experimental direct DRM requested, but $GPU_NODE is absent. /dev/dxg alone is not an Android DRM render device; D3D12 needs a separate bridge."
    gpu_args+=("androidboot.redroid_gpu_node=$GPU_NODE")
    gpu_devices=(--device /dev/dri:/dev/dri)
  fi
  docker pull --platform linux/arm64 "$ANDROID_IMAGE"
  [[ $(docker image inspect --format '{{.Architecture}}' "$ANDROID_IMAGE") == arm64 ]] || fail 'Downloaded image is not ARM64.'
  if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    # Never recreate an existing container silently, even for display/GPU changes.
    local expected actual
    expected=$(printf '%s\n' "${gpu_args[@]}" "androidboot.redroid_width=$WIDTH" "androidboot.redroid_height=$HEIGHT" "androidboot.redroid_dpi=$DPI" "androidboot.redroid_fps=$FPS" | sort)
    actual=$(docker inspect --format '{{json .Config.Cmd}}' "$CONTAINER_NAME" | jq -r '.[] | select(test("^androidboot.redroid_(gpu_|width=|height=|dpi=|fps=)"))' | sort)
    [[ $actual == "$expected" ]] || fail 'Existing container display/GPU configuration differs. Preserving it and its data; explicit migration is required.'
  else
    mkdir -p "$STATE_DIR/android-data"
    docker run -d --name "$CONTAINER_NAME" --restart no --platform linux/arm64 --privileged \
      --device /dev/binder:/dev/binder --device /dev/hwbinder:/dev/hwbinder --device /dev/vndbinder:/dev/vndbinder --device /dev/ashmem:/dev/ashmem \
      "${gpu_devices[@]}" --mount "type=bind,src=$STATE_DIR/android-data,dst=/data" \
      -p "127.0.0.1:$ADB_PORT:5555" "$ANDROID_IMAGE" androidboot.use_memfd=1 \
      "${gpu_args[@]}" "androidboot.redroid_width=$WIDTH" "androidboot.redroid_height=$HEIGHT" \
      "androidboot.redroid_dpi=$DPI" "androidboot.redroid_fps=$FPS" \
      androidboot.redroid_net_ndns=2 androidboot.redroid_net_dns1=1.1.1.1 androidboot.redroid_net_dns2=8.8.8.8
  fi
  docker inspect "$CONTAINER_NAME" > "$STATE_DIR/android-container-inspect.json"
  start_android
}
case "$ACTION" in
  probe) probe ;;
  status) status ;;
  start|provision)
    mkdir -p "$STATE_DIR" "$LOG_DIR"
    exec > >(tee -a "$LOG_DIR/runtime.log") 2>&1
    if [[ $ACTION == provision ]]; then provision; else start_android; fi
    ;;
  stop)
    if command -v docker >/dev/null && docker info >/dev/null 2>&1 && docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
      docker stop --time 30 "$CONTAINER_NAME"
    fi
    sync
    ;;
  *) fail 'Supported operations: probe, status, provision, start, stop.' ;;
esac
