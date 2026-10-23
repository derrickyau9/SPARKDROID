#!/usr/bin/env bash
# Build a custom Android16 ARM64 Redroid image on a provisioned x86-64 Linux
# build workstation. This was NOT used to create the downloaded prebuilt image.
set -Eeuo pipefail
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || {
  echo 'AOSP upstream host tools require an x86-64 Linux build workstation.'
  exit 1
}
PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD_DIR="${SPARKDROID_AOSP_DIR:?Set SPARKDROID_AOSP_DIR to an empty build directory with 400 GB free.}"
JOBS="${SPARKDROID_BUILD_JOBS:-8}"
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid build job count.'; exit 1; }
for tool in repo git git-lfs python3; do
  command -v "$tool" > /dev/null || { echo "Install required build tool: $tool"; exit 1; }
done
mkdir -p "$BUILD_DIR"
BUILD_DIR=$(cd "$BUILD_DIR" && pwd)
FREE_KB=$(df -Pk "$BUILD_DIR" | awk 'NR==2 {print $4}')
RAM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
(( FREE_KB >= 400 * 1024 * 1024 )) || { echo 'AOSP checkout/build requires at least 400 GiB free.'; exit 1; }
(( RAM_KB >= 60 * 1024 * 1024 )) || { echo 'Use a workstation with at least 64 GB installed RAM.'; exit 1; }
mkdir -p "$BUILD_DIR/sparkdroid-build-logs"
exec > >(tee -a "$BUILD_DIR/sparkdroid-build-logs/build.log") 2>&1
cd "$BUILD_DIR"
repo init -u https://android.googlesource.com/platform/manifest \
  -b android-16.0.0_r2 --depth=1 --git-lfs
[[ $(git -C .repo/manifests rev-parse HEAD) == 6650f1e0458a5450156c0348fe0dc96acb958eb8 ]]
mkdir -p .repo/local_manifests
cp "$PROJECT_DIR/upstream/aosp/sparkdroid-redroid16.xml" .repo/local_manifests/sparkdroid.xml
repo sync -c --fail-fast -j "$JOBS"
PATCH_DIR="$PROJECT_DIR/upstream/redroid-patches/android-16.0.0_r2"
test -d "$PATCH_DIR"
STAMP="$BUILD_DIR/.sparkdroid-redroid-patches-applied"
PATCH_REV=a5c70c0dd89c12b5027c902ab4182f31d38f3bb7
if [[ ! -f $STAMP ]]; then
  while IFS= read -r -d '' patch; do
    relative=${patch#"$PATCH_DIR/"}
    project=${relative%/*}
    git -C "$BUILD_DIR/$project" am "$patch"
  done < <(find "$PATCH_DIR" -type f -name '*.patch' -print0 | sort -z)
  printf '%s\n' "$PATCH_REV" > "$STAMP"
fi
[[ $(cat "$STAMP") == "$PATCH_REV" ]]
repo manifest -r -o "$BUILD_DIR/sparkdroid-build-logs/resolved-manifest.xml"
# envsetup.sh is an upstream shell library which does not support nounset.
set +u
source build/envsetup.sh
lunch redroid_arm64_only-bp2a-userdebug
m -j "$JOBS"
set -u
PRODUCT_OUT="$BUILD_DIR/out/target/product/redroid_arm64_only"
test -f "$PRODUCT_OUT/system.img"
test -f "$PRODUCT_OUT/vendor.img"
sha256sum "$PRODUCT_OUT/system.img" "$PRODUCT_OUT/vendor.img" \
  > "$BUILD_DIR/sparkdroid-build-logs/images.sha256"
printf 'Custom Android build completed: %s\n' "$PRODUCT_OUT"
echo 'Import system/vendor images into a Linux container using the upstream Redroid build instructions.'
