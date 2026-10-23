# SPARKDROID measured result

This is a working experimental ARM64 Android runtime with a native Windows launcher. Full project acceptance remains incomplete. Android graphics acceleration, automatic power management, production security, broad app compatibility and several Windows device bridges remain open work.

## Actual execution

The detected host is an HP OmniBook X 14-ks000 running Windows 11 Pro ARM64 build 28000.2605. It reports NVIDIA RTX Spark N1X, 20 CPU cores, approximately 30.4 GiB usable Windows RAM and NVIDIA driver 32.0.16.1721 / 617.21. Inventory and sensor memory counters disagree; shared GPU memory is not inferred.

QEMU 11.1.2 is a native Windows ARM64 PE executable. It successfully instantiated WHPX, booted Ubuntu 24.04 ARM64 and ran a digest-pinned Android 16 ARM64 Redroid container. BinderFS integration was repaired and a matching ashmem module was actually compiled and installed in the guest. No Windows bootloader, partition, optional-feature, driver or global power-plan modification was needed.

The Windows WinForms launcher was compiled as self-contained win-arm64 and executed with an actual native window handle. It provides runtime start/stop, pause/resume, three startup profiles, APK/split workflows, app listing/launch/uninstall, per-app shortcuts, manual file transfers, ADB shell and diagnostics. Per-app windows use ARM64 scrcpy. File association registration is an explicit launcher action.

## Acceptance evidence

| Check | Observed result | Evidence |
|---|---|---|
| Android boot | sys.boot_completed=1, Android 16, arm64-v8a | artifacts/acceptance/runtime-checks.json |
| Repeat boot | VM start to Android ready 38.510 s, 3 s polling resolution | artifacts/benchmarks/boot-20261023T071509Z.json or latest boot JSON |
| ARM64 native APK | Official VLC 3.7.1, four AArch64 ELF libraries, installed and launched | upstream/test-apk.lock.json; VLC benchmark raw trials |
| Chinese APK | Official Tencent WeChat 8.0.79 installed as arm64-v8a and opened to welcome screen | artifacts/compatibility/wechat-20261023T070739171Z/ |
| App windows | VLC launched on a separate scrcpy virtual display; native Windows D3D11 presentation/decode | artifacts/logs/app-org.videolan.vlc-*.out.log |
| Network | Android DNS resolution and ICMP reply from www.example.com | artifacts/acceptance/android-network.txt |
| Audio route | Generated alternating 440/880 Hz reached Windows output loopback; physical output is muted | artifacts/acceptance/audio-acceptance.json |
| Input | Android HOME key injection left Settings; physical Windows input devices remain untested | artifacts/acceptance/runtime-checks.json |
| Files | Host → Android → host file SHA256 matched | artifacts/acceptance/file-bridge.json |
| Persistence | VLC and WeChat remain installed after VM shutdown/restart; Android /data retained | package paths and repeated runtime checks |
| Shutdown | Multiple normal SSH/systemctl shutdowns exited QEMU cleanly, including recovery after balloon testing | QEMU serial shutdown logs |
| Pause/resume | 5.014 s pause used 0.03125 process CPU seconds, then Android checks passed | artifacts/acceptance/pause-resume.json |
| Android GPU | Failed acceptance: hardware renderer reported NVIDIA, but screenshot black | artifacts/acceptance/graphics.json |

VLC's three process-cold `am start -W` trials reported COLD and TotalTime 399, 472 and 464 ms. These preserve ART/filesystem caches. WeChat's one observed COLD launch reported TotalTime 430 ms, then survived the five-second observation and displayed Log In / Sign Up. No WeChat terms, account login, registration, permission flow, messages or payments were performed.

The audio test used one bounded 9.98-second Windows output-loopback recording, with both frequencies and nine alternations detected. It did not open a microphone. The host output endpoint was muted with scalar volume zero and was not changed. This establishes digital playback routing, with physical audibility and latency unverified.

## Graphics and memory limits

Native Windows ANGLE rendered and read a known pixel on NVIDIA D3D11. An isolated Linux ARM64 guest also rendered/read the pixel using VirtIO → VirGL → ANGLE → NVIDIA. The guest exposes GLES 2.0 / GL 2.1 in this path. Android booted with its VirGL renderer string but produced black frames; QEMU recorded incomplete framebuffer 0x8d56, GL error 1286 and a failed CLEAR. The failing attachment/sample combination needs further tracing. Renderer-name strings and Windows video decoding are not accepted as successful Android GPU rendering.

The usable default explicitly selects Android ANGLE/SwiftShader software rendering. No automatic fallback hides a graphics failure. `artifacts/toolchain/graphics-path.md` and the Android failure report retain exact evidence and reproduction flags. The Vulkan-backed host ANGLE experiment also failed initialization; CUDA, passthrough and zero-copy sharing are not implemented.

The balloon experiment was rejected: the Win32 build reports unsupported RAM discard, and guest SSH/ADB became unresponsive after requesting reclamation. The later normal shutdown succeeded; emergency termination was unnecessary. The supported configuration removes virtio-balloon and rejects ReclaimMemory. Profiles use fixed RAM/vCPU allocation at boot. Exact guest-hang causation remains unestablished; the nonfatal WILLNEED hint warning alone is not causal proof.

## Resource observations

Final 20-second software-build observation, Android Home with no scrcpy window and other host development work present:

| Metric | Observed value |
|---|---:|
| QEMU CPU | 3.5141% of one CPU core |
| QEMU CPU normalized over 20 host CPUs | 0.1757% |
| QEMU working set, mean | 3,284,296,499 bytes, about 3.06 GiB |
| QEMU private bytes, mean | 6,813,867,622 bytes, about 6.35 GiB |
| GPU device sensor power, mean | 1.145 W |
| Whole-system power / battery drain | Unavailable |

Source: artifacts/benchmarks/20261023T071743742Z-runtime-465682/measurement.json. Initial provisioning and connected-display observations have different working sets and CPU costs; the reports retain their workload labels. The stopped-runtime baseline was ten seconds amid development activity. These runs are not controlled enough to derive a CPU speedup or subtract small GPU-power differences as Android energy overhead. Sensors were sampled every two seconds and can perturb power/wakeups. The host was AC-powered, so battery-discharge and system-power results remain null.

## Remaining implementation

The chosen prebuilt image reports security patch 2025-06-05, userdebug, disabled SELinux and WebView 133.0.6943.137. A full updated AOSP system build has not been executed. Pinned source manifests, patches and the guarded build script are included for a suitable x86-64 Linux builder; this host is outside the supported full AOSP build environment.

Unfinished or unvalidated: working Android hardware graphics, calibrated frame/FPS/latency benchmarks, current production hardening, Windows microphone/camera/GPS bridges, Windows notification toasts, automatic battery/idle/vCPU management, live shared mounts, actual split-package compatibility, physical touch/keyboard/mouse tests, clipboard/deep-link tests, Chinese IME interaction, sustained background reliability, device attestation/DRM and the remaining requested Chinese applications. See docs/compatibility.md for per-app scope.
