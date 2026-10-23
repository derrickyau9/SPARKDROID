#!/usr/bin/env bash
# Run as root inside the disposable Ubuntu ARM64 SPARKDROID virtual machine.
# This script never runs against the Windows host.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

STATE_DIR=/var/lib/sparkdroid
LOG_DIR=/var/log/sparkdroid
CONTAINER_NAME=sparkdroid-android
# Official redroid/redroid:16.0.0_64only-latest ARM64 manifest, resolved 2026-10-22.
ANDROID_IMAGE="${SPARKDROID_ANDROID_IMAGE:-docker.io/redroid/redroid@sha256:e194edc99aa364358d1f8c214acb18b6d006c74fa0561f39259a20173ec30b66}"
WIDTH="${SPARKDROID_WIDTH:-720}"
HEIGHT="${SPARKDROID_HEIGHT:-1280}"
FPS="${SPARKDROID_FPS:-60}"
DPI="${SPARKDROID_DPI:-240}"
BOOT_TIMEOUT="${SPARKDROID_BOOT_TIMEOUT:-480}"
GPU_MODE="${SPARKDROID_GPU_MODE:-guest}"
GPU_NODE="${SPARKDROID_GPU_NODE:-/dev/dri/renderD128}"
PHASE=initializing

if [[ $(id -u) != 0 ]]; then
  echo 'Run this provisioning script as root inside the Linux guest.' >&2
  exit 1
fi
mkdir -p "$STATE_DIR" "$LOG_DIR"
exec > >(tee -a "$LOG_DIR/provision.log") 2>&1
write_status() {
  local result=$1
  printf '{"status":"%s","phase":"%s","kernel":"%s","updated_utc":"%s"}\n' \
    "$result" "$PHASE" "$(uname -r)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    > "$STATE_DIR/provision-status.json"
}
trap 'result=$?; if (( result != 0 )); then write_status failed; fi' EXIT
write_status running
[[ $(uname -m) == aarch64 ]] || { echo 'ARM64 Linux guest required.'; exit 1; }
for value in "$WIDTH" "$HEIGHT" "$FPS" "$DPI" "$BOOT_TIMEOUT"; do
  [[ $value =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid numeric runtime setting.'; exit 1; }
done
case "$GPU_MODE" in
  guest|host) ;;
  *) echo 'SPARKDROID_GPU_MODE must be guest or host.'; exit 1 ;;
esac
GPU_ARGS=("androidboot.redroid_gpu_mode=$GPU_MODE")
GPU_DEVICES=()
if [[ $GPU_MODE == host ]]; then
  [[ $GPU_NODE =~ ^/dev/dri/renderD[0-9]+$ && -c $GPU_NODE ]] || {
    echo "Explicit host GPU requested but DRM render device is absent: $GPU_NODE"
    exit 1
  }
  GPU_ARGS+=("androidboot.redroid_gpu_node=$GPU_NODE")
  GPU_DEVICES=(--device /dev/dri:/dev/dri)
fi

PHASE=installing-packages
write_status running
apt-get -o Acquire::Retries=3 update
apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
  ca-certificates curl docker.io jq kmod
if ! modinfo binder_linux > /dev/null 2>&1; then
  # Ubuntu's virtual kernel can omit the binder module from its base modules.
  # Install only the extra modules matching the running kernel; no kernel upgrade.
  apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
    "linux-modules-extra-$(uname -r)"
fi

PHASE=configuring-binder
write_status running
printf '%s\n' 'options binder_linux devices=binder,hwbinder,vndbinder' \
  > /etc/modprobe.d/sparkdroid-binder.conf
printf '%s\n' binder_linux > /etc/modules-load.d/sparkdroid-binder.conf
# Ubuntu 6.8's modular BinderFS creates devices in a mounted binderfs rather
# than as legacy misc devices. Recreate the mount and aliases before Docker
# starts after every guest boot.
cat > /usr/local/sbin/sparkdroid-binder-setup <<'BINDER_SETUP'
#!/bin/sh
set -eu
modprobe binder_linux devices=binder,hwbinder,vndbinder
if [ ! -c /dev/binder ]; then
  mkdir -p /dev/binderfs
  if ! mountpoint -q /dev/binderfs; then
    mount -t binder binder /dev/binderfs
  fi
  for node in binder hwbinder vndbinder; do
    test -c "/dev/binderfs/$node"
    if [ ! -e "/dev/$node" ]; then
      ln -s "/dev/binderfs/$node" "/dev/$node"
    fi
  done
fi
BINDER_SETUP
chmod 0755 /usr/local/sbin/sparkdroid-binder-setup
cat > /etc/systemd/system/sparkdroid-binder.service <<'BINDER_SERVICE'
[Unit]
Description=SPARKDROID Android Binder devices
After=systemd-modules-load.service
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sparkdroid-binder-setup
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
BINDER_SERVICE
systemctl daemon-reload
systemctl enable --now sparkdroid-binder.service
for node in binder hwbinder vndbinder; do
  if [[ ! -c /dev/$node ]]; then
    echo "Missing /dev/$node after loading binder_linux. Check module device parameters."
    exit 1
  fi
done
# Android's Java shared memory uses memfd, but this Redroid image's software
# gralloc still opens /dev/ashmem. Without it SurfaceFlinger aborts while
# priming shaders. Build the small upstream ashmem module for this exact
# guest kernel, including the upstream-proposed modern-kernel fixes (PR 23).
PHASE=configuring-ashmem
write_status running
if ! modinfo ashmem_linux > /dev/null 2>&1; then
  ASHMEM_REV=f55e1e7515a6dd5f8e0f9569ea79148c08f60816
  ASHMEM_SHA256=3bcc9c4084ddb8422e0865f648541f398569411c95f6de99b251f02e73b1776b
  ASHMEM_ARCHIVE="$STATE_DIR/redroid-modules-$ASHMEM_REV.tar.gz"
  ASHMEM_SOURCE="$STATE_DIR/redroid-modules-$ASHMEM_REV"
  apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
    make gcc "linux-headers-$(uname -r)"
  curl --fail --location --retry 3 \
    "https://codeload.github.com/remote-android/redroid-modules/tar.gz/$ASHMEM_REV" \
    --output "$ASHMEM_ARCHIVE"
  printf '%s  %s\n' "$ASHMEM_SHA256" "$ASHMEM_ARCHIVE" | sha256sum --check -
  mkdir -p "$ASHMEM_SOURCE"
  tar -xzf "$ASHMEM_ARCHIVE" --strip-components=1 -C "$ASHMEM_SOURCE"
  (cd "$ASHMEM_SOURCE/ashmem" && make -j "$(nproc)")
  install -D -m 0644 "$ASHMEM_SOURCE/ashmem/ashmem_linux.ko" \
    "/lib/modules/$(uname -r)/updates/sparkdroid/ashmem_linux.ko"
  depmod -a
fi
modprobe ashmem_linux
test -c /dev/ashmem
printf '%s\n' ashmem_linux > /etc/modules-load.d/sparkdroid-ashmem.conf

PHASE=acquiring-android
write_status running
systemctl enable --now docker
docker pull --platform linux/arm64 "$ANDROID_IMAGE"
[[ $(docker image inspect --format '{{.Architecture}}' "$ANDROID_IMAGE") == arm64 ]]
docker image inspect "$ANDROID_IMAGE" > "$STATE_DIR/android-image-inspect.json"
mkdir -p "$STATE_DIR/android-data"

PHASE=starting-android
write_status running
if docker container inspect "$CONTAINER_NAME" > /dev/null 2>&1; then
  EXISTING_IMAGE=$(docker container inspect --format '{{.Config.Image}}' "$CONTAINER_NAME")
  if [[ $EXISTING_IMAGE != "$ANDROID_IMAGE" ]]; then
    echo 'An existing SPARKDROID container uses a different image; preserving it and its data.'
    exit 1
  fi
  CURRENT_GPU_ARGS=$(docker inspect --format '{{json .Config.Cmd}}' "$CONTAINER_NAME" | jq -r '.[] | select(startswith("androidboot.redroid_gpu_"))' | sort)
  REQUESTED_GPU_ARGS=$(printf '%s\n' "${GPU_ARGS[@]}" | sort)
  if [[ $CURRENT_GPU_ARGS != "$REQUESTED_GPU_ARGS" ]]; then
    # Container metadata is replaceable; the bind-mounted Android /data remains.
    docker stop --time 30 "$CONTAINER_NAME"
    docker rm "$CONTAINER_NAME"
  fi
fi
if docker container inspect "$CONTAINER_NAME" > /dev/null 2>&1; then
  docker start "$CONTAINER_NAME"
else
  # Guest listens on its virtual NIC so QEMU's loopback-only hostfwd can reach it.
  # The Windows QEMU command MUST use hostfwd=tcp:127.0.0.1:5555-:5555.
  # /data is persistent. This privileged container is confined to this Linux VM.
  docker run -d --name "$CONTAINER_NAME" --restart unless-stopped \
    --platform linux/arm64 --privileged \
    --device /dev/binder:/dev/binder \
    --device /dev/hwbinder:/dev/hwbinder \
    --device /dev/vndbinder:/dev/vndbinder \
    --device /dev/ashmem:/dev/ashmem \
    "${GPU_DEVICES[@]}" \
    --mount "type=bind,src=$STATE_DIR/android-data,dst=/data" \
    -p 0.0.0.0:5555:5555 \
    "$ANDROID_IMAGE" \
    androidboot.use_memfd=1 \
    "${GPU_ARGS[@]}" \
    "androidboot.redroid_width=$WIDTH" \
    "androidboot.redroid_height=$HEIGHT" \
    "androidboot.redroid_dpi=$DPI" \
    "androidboot.redroid_fps=$FPS" \
    androidboot.redroid_net_ndns=2 \
    androidboot.redroid_net_dns1=1.1.1.1 \
    androidboot.redroid_net_dns2=8.8.8.8
fi

PHASE=waiting-for-android-framework
write_status running
DEADLINE=$((SECONDS + BOOT_TIMEOUT))
while (( SECONDS < DEADLINE )); do
  BOOT_COMPLETED=$(docker exec "$CONTAINER_NAME" /system/bin/getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
  if [[ $BOOT_COMPLETED == 1 ]]; then
    break
  fi
  if [[ $(docker container inspect --format '{{.State.Running}}' "$CONTAINER_NAME") != true ]]; then
    docker logs --tail 200 "$CONTAINER_NAME"
    echo 'Android container stopped before framework boot completed.'
    exit 1
  fi
  sleep 5
done
docker inspect "$CONTAINER_NAME" > "$STATE_DIR/android-container-inspect.json"
docker logs --tail 500 "$CONTAINER_NAME" > "$LOG_DIR/android-container.log" 2>&1 || true
docker exec "$CONTAINER_NAME" /system/bin/getprop > "$STATE_DIR/android-properties.txt" || true
if [[ $BOOT_COMPLETED != 1 ]]; then
  echo "Android framework did not finish booting within ${BOOT_TIMEOUT}s."
  exit 1
fi
ABI=$(docker exec "$CONTAINER_NAME" /system/bin/getprop ro.product.cpu.abi | tr -d '\r')
[[ $ABI == arm64-v8a ]] || { echo "Unexpected Android ABI: $ABI"; exit 1; }
docker exec "$CONTAINER_NAME" /system/bin/settings put system peak_refresh_rate "$FPS"
docker exec "$CONTAINER_NAME" /system/bin/settings put system min_refresh_rate "$FPS"
PHASE=android-framework-booted
write_status complete
echo "SPARKDROID_ANDROID_BOOTED ABI=arm64-v8a gpu-mode=$GPU_MODE renderer-validation-required"
echo 'Host validation: adb connect 127.0.0.1:5555; adb -s 127.0.0.1:5555 shell getprop sys.boot_completed'
