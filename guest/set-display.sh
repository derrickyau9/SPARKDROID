#!/usr/bin/env bash
# Recreate only Android container metadata; retain the existing /data bind mount.
set -Eeuo pipefail
[[ $(id -u) == 0 ]] || { echo 'Run inside the guest as root.'; exit 1; }
FPS=${1:-120}
[[ $FPS =~ ^[0-9]+$ && $FPS -ge 30 && $FPS -le 240 ]] || { echo 'Refresh must be 30..240 Hz.'; exit 1; }
CONTAINER=sparkdroid-android
mkdir -p /var/log/sparkdroid /var/lib/sparkdroid
SNAPSHOT=/var/log/sparkdroid/display-container-before.json
docker inspect "$CONTAINER" > "$SNAPSHOT"
CURRENT=$(jq -r '.[0].Config.Cmd[] | select(startswith("androidboot.redroid_fps=")) | split("=")[1]' "$SNAPSHOT")
if [[ $CURRENT == "$FPS" ]]; then
  docker exec "$CONTAINER" /system/bin/settings put system peak_refresh_rate "$FPS"
  docker exec "$CONTAINER" /system/bin/settings put system min_refresh_rate "$FPS"
  echo "Android container is already configured for $FPS Hz."
  exit 0
fi
IMAGE=$(jq -r '.[0].Config.Image' "$SNAPSHOT")
DATA=$(jq -r '.[0].Mounts[] | select(.Destination=="/data" and .Type=="bind") | .Source' "$SNAPSHOT")
[[ -d $DATA && $DATA == /var/lib/sparkdroid/android-data ]] || { echo 'Unexpected data mount; refusing configuration change.'; exit 1; }
mapfile -t ARGS < <(jq -r '.[0].Config.Cmd[] | select(startswith("androidboot.redroid_fps=") | not)' "$SNAPSHOT")
DEVICES=()
while IFS=$'\t' read -r src dst; do
  [[ -e $src ]] || { echo "Required device absent: $src"; exit 1; }
  DEVICES+=(--device "$src:$dst")
done < <(jq -r '.[0].HostConfig.Devices[] | [.PathOnHost,.PathInContainer] | @tsv' "$SNAPSHOT")
BACKUP="sparkdroid-display-backup-$(date +%s)"
docker stop --timeout 30 "$CONTAINER"
docker rename "$CONTAINER" "$BACKUP"
if ! docker run -d --name "$CONTAINER" --restart unless-stopped --platform linux/arm64 --privileged \
    "${DEVICES[@]}" --mount "type=bind,src=$DATA,dst=/data" -p 0.0.0.0:5555:5555 \
    "$IMAGE" "${ARGS[@]}" "androidboot.redroid_fps=$FPS"; then
  docker rename "$BACKUP" "$CONTAINER"
  docker start "$CONTAINER"
  echo 'Display change failed; original container restored.'
  exit 1
fi
printf '%s\n' "$BACKUP" > /var/lib/sparkdroid/display-backup-container
DEADLINE=$((SECONDS+180))
while ((SECONDS<DEADLINE)); do
  BOOT=$(docker exec "$CONTAINER" /system/bin/getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)
  if [[ $BOOT == 1 ]]; then
    docker exec "$CONTAINER" /system/bin/settings put system peak_refresh_rate "$FPS"
    docker exec "$CONTAINER" /system/bin/settings put system min_refresh_rate "$FPS"
    docker exec "$CONTAINER" /system/bin/dumpsys display > /var/log/sparkdroid/display-after.txt
    echo "Android boot completed; requested main display $FPS Hz. Previous stopped container retained as $BACKUP."
    exit 0
  fi
  sleep 3
done
echo 'Android readiness timeout. Container metadata backup and app data are retained.'
exit 1
