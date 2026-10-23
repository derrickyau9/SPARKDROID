# WSA Android 13 on RTX Spark

The local ARM64 WSA experiment now boots Android 13 / API 33, reports
`sys.boot_completed=1`, and opens Android apps as individual Windows windows.
Files and the SPARKDROID frame test have rendered; VLC 3.7.1 has reached its
welcome screen. This is an experimental compatibility build, not a completed
Android 16 port or a production-ready Android distribution.

## Open and close

Open `Start-SPARKDROID-WSA.cmd` or the desktop shortcut
**SPARKDROID - WSA Control Panel**. In the WSA panel, **System > Files** starts
Android and **System > Turn off** shuts down all WSA apps and releases its VM.
Installed Android apps also appear in the Windows Start menu.
The desktop shortcut **VLC (WSA Android 13)** opens this installation's VLC.

The older `Start-SPARKDROID.cmd` and the existing SPARKDROID WeChat/VLC desktop
shortcuts control the separate QEMU runtime. They do not control WSA.

For this local WSA installation, ADB connects to `127.0.0.1:58526` after Android
starts. The device-side debugging prompt must be accepted by the user.

## Why the original package could not boot

N1X uses Cortex-X925 and Cortex-A725 CPU cores, which support AArch64 execution
without native AArch32 execution. The original ARM64 WSA package still contains
ARM32 services. Its 32-bit BoringSSL startup self-test failed with
`Exec format error` and triggered a guest reboot. Both the WSA and WSL kernels
already have `CONFIG_COMPAT=y`; a kernel option cannot restore a missing CPU
execution state.

The first patch selects the ARM64-only ABI and `zygote64`; all 64-bit BoringSSL
self-tests pass. The next boot exposed a second blocker: the ARM32 audio HAL
failed repeatedly and its restart action killed `audioserver`. Android's system
server waited for the audio-policy service and eventually hit its watchdog.

The second patch replaces only `/vendor/bin/hw/android.hardware.audio.service`
with an inspected ARM64 service from snickler/WSA-Patched 0.0.2. Its original
audio libraries and service definition remain unchanged. Static examination
is consistent with the AOSP Android 13 service, but it is not a reproducible
source build or a publisher-signature verification. The rest of that community
image, including its extra apps and certificates, was not installed.

All 556 vendor filesystem paths were compared. Only the audio executable's
bytes and size changed; its inode, mode, owner and SELinux attributes were
preserved. Filesystem checks and the raw/VHDX roundtrip passed. The filesystem
was expanded and shared blocks were removed in an isolated copy. This changes
the old AVB trailer: **the candidate is not AVB-valid**. No runtime verification
setting was changed; the existing WSA boot path mounts these ext4 images
without enforcing those descriptors.

## Verified behavior and limits

- Android 13 / SDK 33, `arm64-v8a`, `zygote64`, completed boot and authorized ADB.
- `audioserver` remains running; the prior audio-triggered kill loop is gone.
- SurfaceFlinger reports Microsoft Subsystem OpenGL ES Translator, OpenGL ES 3.0;
  the frame-test app uses Skia OpenGL. Windows presentation FPS is a separate metric.
- Initial guest display modes were 60 Hz on both screens, matching the Windows
  modes at that time. Short foreground animation samples were approximately
  59–60 draw callbacks/s; later samples with window changes were lower.
- The Windows internal 2880x1800 display supports 120 Hz. The external 3440x1440
  display currently exposes only 60 Hz at that resolution. This does not establish
  a permanent WSA refresh-rate limit.
- A session-only switch of the internal Windows display to 120 Hz succeeded,
  while the running WSA and frame test on guest display 2 remained at 60 Hz.
  Both Windows screens were restored to their exact previous mode afterward.
  Starting WSA from cold while Windows is already at 120 Hz remains untested.
- The original ARM32 media, DRM, CAS and OMX services still fail to execute.
  Full video playback, codecs, DRM and application compatibility are unverified.
- Apps containing only ARM32 native libraries cannot execute natively on this CPU.

## Evidence and rollback copies

Sanitized publication copies are under `artifacts/wsa/published/`: `guest-boot-failure.json`,
`arm64-boot-audio-blocker.json`, `vendor-audio-candidate-result.json`,
`android13-runtime-verification.json`, `host-display-modes-readonly.json` and
`n1x-aarch32-evidence.json`. Raw ETW/logcat captures remain local under ignored
`artifacts/logs/wsa/`.

The scripts are research procedures for the recorded installation. They require
separately obtained and extracted packages, offline filesystem tools, and locally
generated receipts under `artifacts/wsa/`. Some audio build/apply checks pin the
exact candidate hashes from the recorded validation run. The ABI patch generates new VHDX GUIDs,
so rebuilding it changes the container hash even when the guest file changes are
identical. A fresh clone therefore does not reproduce the entire installation
by running these scripts in sequence; hash/receipt generalization and automated
input preparation remain future work. Published reports document observations;
the apply scripts require locally generated build receipts.

Original WSA system/vendor images are preserved at
`tools/wsabuilds/backups/lts8-before-arm64-only/`; the ABI-only vendor is also
preserved at `tools/wsabuilds/backups/abi-before-audio/`. Stop WSA before restoring
images. The patch/build/apply scripts under `scripts/wsa/` pin hashes and refuse
to overwrite existing backups. User data was not reset to perform these fixes.

The temporary `SPARKDROID-Tools` WSL distro was used only for offline ext4 tooling
and was terminated after image checks. The Android runtime itself is WSA.

Sources: [NVIDIA CPU configuration](https://docs.nvidia.com/rtx-spark/rtx-spark-porting-guide/latest/portingandemulation/cpuspecific.html),
[Arm Cortex-A725](https://www.arm.com/products/silicon-ip-cpu/cortex-a/cortex-a725),
[Arm Cortex-X925 firmware source](https://github.com/ARM-software/arm-trusted-firmware/blob/master/lib/cpus/aarch64/cortex_x925.S),
[WSABuilds ARM64 LTS8 baseline](https://github.com/MustardChef/WSABuilds/releases/tag/Windows_11_2407.40000.4.0_LTS_8_arm64),
[WSA-Patched 0.0.2](https://github.com/snickler/WSA-Patched/releases/tag/0.0.2).
