#!/usr/bin/env bash
# Switch only the named Android container's graphics transport inside its VM.
# Android data, the Linux guest and the Windows host are preserved.
set -Eeuo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run as root inside the Linux guest.'; exit 1; }
GPU_MODE="${SPARKDROID_GPU_MODE:-guest}"
GPU_NODE="${SPARKDROID_GPU_NODE:-/dev/dri/renderD128}"
CONTAINER=sparkdroid-android
case "$GPU_MODE" in guest|host) ;; *) echo 'GPU mode must be guest or host.'; exit 1 ;; esac
GPU_ARGS=("androidboot.redroid_gpu_mode=$GPU_MODE")
GPU_DEVICES=()
if [[ $GPU_MODE == host ]]; then
  [[ $GPU_NODE =~ ^/dev/dri/renderD[0-9]+$ && -c $GPU_NODE ]] || {
    echo "Requested hardware graphics device is absent: $GPU_NODE"
    exit 1
  }
  GPU_ARGS+=("androidboot.redroid_gpu_node=$GPU_NODE")
  GPU_DEVICES=(--device /dev/dri:/dev/dri)
fi
for node in /dev/binder /dev/hwbinder /dev/vndbinder /dev/ashmem; do
  [[ -c $node ]] || { echo "Required Android device absent: $node"; exit 1; }
done
IMAGE=$(docker inspect --format '{{.Config.Image}}' "$CONTAINER")
DATA_SOURCE=$(docker inspect "$CONTAINER" | jq -r '.[0].Mounts[] | select(.Destination == "/data" and .Type == "bind") | .Source')
[[ -n $DATA_SOURCE && -d $DATA_SOURCE ]] || { echo 'Refusing switch: persistent Android data bind mount not found.'; exit 1; }
mapfile -t ORIGINAL_ARGS < <(docker inspect --format '{{json .Config.Cmd}}' "$CONTAINER" | jq -r '.[] | select((startswith("androidboot.redroid_gpu_mode=") or startswith("androidboot.redroid_gpu_node=")) | not)')
mkdir -p /var/log/sparkdroid
docker inspect "$CONTAINER" > /var/log/sparkdroid/pre-graphics-switch-container.json
docker stop --time 30 "$CONTAINER"
docker rm "$CONTAINER"
docker run -d --name "$CONTAINER" --restart unless-stopped \
  --platform linux/arm64 --privileged \
  --device /dev/binder:/dev/binder \
  --device /dev/hwbinder:/dev/hwbinder \
  --device /dev/vndbinder:/dev/vndbinder \
  --device /dev/ashmem:/dev/ashmem \
  "${GPU_DEVICES[@]}" \
  --mount "type=bind,src=$DATA_SOURCE,dst=/data" \
  -p 0.0.0.0:5555:5555 "$IMAGE" "${ORIGINAL_ARGS[@]}" "${GPU_ARGS[@]}"
DEADLINE=$((SECONDS + 180))
while (( SECONDS < DEADLINE )); do
  BOOT=$(docker exec "$CONTAINER" /system/bin/getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
  if [[ $BOOT == 1 ]]; then
    docker exec "$CONTAINER" /system/bin/dumpsys SurfaceFlinger \
      > "/var/log/sparkdroid/surfaceflinger-$GPU_MODE.txt"
    echo "Android booted with requested mode=$GPU_MODE; validate renderer in surfaceflinger-$GPU_MODE.txt"
    exit 0
  fi
  sleep 3
done
echo "Android did not boot with requested graphics mode=$GPU_MODE; no software fallback was selected."
echo 'Restore explicit software mode with: sudo env SPARKDROID_GPU_MODE=guest bash /opt/sparkdroid/set-graphics.sh'
exit 1
