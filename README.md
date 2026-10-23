# SPARKDROID for NVIDIA RTX Spark

Experimental Android integration and ARM64 compatibility tools for Windows on
NVIDIA RTX Spark (N1X). This independent project contains launcher code,
compatibility patches, diagnostics, source/version records and measured results.

| Backend | Android version | Verified status |
|---|---|---|
| WSA ARM64 | 13 / API 33 | Boots after ARM64-only startup and audio-service fixes; Files, the frame test and VLC welcome screen open in independent Windows windows. Host GPU activity is observed; Android currently exposes 60 Hz. |
| QEMU / WHPX + Redroid | 16 | Runs with hardware-virtualized ARM64 CPU execution; the usable Android graphics path uses software rendering. |
| WSL2 + Redroid | Planned | WSL setup and offline tools work; the Android backend and its GPU path remain unfinished. |

For the current WSA installation, open `Start-SPARKDROID-WSA.cmd`; use
**System > Files** to start Android and **System > Turn off** to shut it down.
See [WSA Android 13 setup notes and limits](docs/WSA-ANDROID13.md).
WSA 120 Hz, remaining media services and a WSA Android 16 port are unfinished.
The WSA scripts record a tested local experiment and require prepared inputs;
they are not a fresh-clone, one-click installer.

The WSA backend uses Microsoft's existing runtime, a pinned
[MustardChef/WSABuilds ARM64 package](upstream/wsabuilds-arm64.lock.json), and one
inspected ARM64 audio-service component from
[snickler/WSA-Patched](upstream/wsa-audio-arm64.lock.json).
See [component attribution](THIRD_PARTY_NOTICES.md). Third-party system images,
APKs and runtime binaries are acquired separately and are not redistributed here.

## QEMU / Redroid backend

SPARKDROID is a working experimental Android 16 runtime on this Windows ARM64 laptop. It uses a native ARM64 QEMU 11.1.2 process and Windows Hypervisor Platform to boot Ubuntu ARM64, which runs a pinned ARM64 Redroid container. The Windows launcher is compiled as a self-contained ARM64 .NET application. Android CPU instructions execute through hardware virtualization; no TCG CPU fallback is selected.

The verified usable graphics mode is **software rendering through Android ANGLE/SwiftShader**. Native NVIDIA D3D11 rendering and Linux guest VirGL rendering passed pixel readback tests. Android's VirGL experiment booted and reported NVIDIA but produced black frames with an incomplete multisample framebuffer error. It therefore fails Android graphics acceptance. Evidence is retained in `artifacts/acceptance/graphics.json` and `artifacts/toolchain/`.

This is a functional prototype with incomplete acceptance. A custom AOSP system image has not been compiled. Windows microphone/camera/location integration, native Windows notification delivery, broad Chinese app compatibility and whole-system energy efficiency remain unfinished or unmeasured. The prebuilt guest reports security patch **2025-06-05**, a userdebug build and disabled SELinux; it needs substantial security work before production or sensitive accounts.

## Run the existing build

An experimental **WSL2 ARM64 backend** was prepared separately. The host has since restarted and WSL works; a dedicated tools distro was used for offline WSA filesystem checks. The WSL Android runtime, Binder/ashmem integration and GPU validation remain unfinished. See [WSL2 setup and current status](docs/WSL2.md). The control panel below continues to operate the existing QEMU backend.

Open `Start-SPARKDROID.cmd`, then choose **Start**. Select **Refresh status** when Android has booted, and **Refresh apps** to list installed applications. Choose an app and **Launch app window**. The launcher uses explicit refresh and has no resident polling loop.

The compiled executable is `artifacts/launcher/win-arm64/SparkDroid.exe`. Its startup root is discovered from the project or supplied with `--project`. For a ready local kit see `dist/SPARKDROID-0.1.0-win-arm64/` after packaging; the packaging script creates this directory from the stopped guest.

```powershell
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\SparkDroid.ps1 -Action Start -WaitForAndroid
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\SparkDroid.ps1 -Action Status
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\SparkDroid.ps1 -Action Stop
```

Use **Stop** for a clean Linux/Android shutdown. **Suspend** pauses guest execution in memory, including background services and notifications; **Resume** continues it. It is not a saved-state suspend and does not free VM RAM.

## APKs and applications

Choose **Install APK**, drag APK files into the launcher, or pass an APK path to `SparkDroid.exe`. Multiple ordinary APKs are installed separately. For one application's base APK plus splits, use **Install splits** so Android installs them in a single session. `.apks`, `.xapk` and encrypted archives must be extracted first; proprietary application packages are not modified.

```powershell
.\scripts\SparkDroid.ps1 -Action Install -Apk C:\path\app.apk
.\scripts\SparkDroid.ps1 -Action Install -Apk @('C:\path\base.apk','C:\path\split_config.arm64_v8a.apk')
.\scripts\SparkDroid.ps1 -Action Apps
.\scripts\SparkDroid.ps1 -Action Launch -Package org.videolan.vlc
.\scripts\SparkDroid.ps1 -Action Uninstall -Package org.example.app
```

The launcher creates per-app desktop and Start menu shortcuts. Opening one starts Android automatically when necessary and leaves the individual app window after a small startup indicator closes. `SparkDroid.exe --project <kit-folder> --package com.tencent.mm` opens WeChat directly. `--export-shortcuts` creates shortcuts for installed user apps while Android is running. Its **APK Open with…** action offers per-user Windows association registration; setup does not silently replace an existing default application. App windows use native ARM64 scrcpy virtual displays with keyboard/mouse controls, clipboard facilities and required audio capture. Physical touchscreen behavior and clipboard transfer still require device-level validation.

The current default is **Smooth 60 Hz**, 540×960, following observed stutter at the experimental 120 Hz setting. **120 Hz (experimental)** matches the primary Windows screen (120 Hz here), requests a real 120 Hz virtual display and changes Android's main display policy. Changing display modes may restart the container while preserving app data. High refresh does **not** guarantee sustained 120 FPS. Short animation tests reached about 119 FPS average, while longer tests with audio and concurrent windows slowed substantially. Android still renders and encodes in software. See [independent apps and refresh measurements](docs/INDEPENDENT-APPS-120HZ.md).

ADB is forwarded only on `127.0.0.1:15555`; the guest's management SSH is forwarded on `127.0.0.1:22222`, and QMP on `127.0.0.1:14444`. `AdbShell` and `GuestShell` actions open the corresponding shells. Private management keys, guest disks and host PID records stay in ignored `state/`.

## Files and operating profiles

**Shared folder** opens the Windows `shared/` directory. **Send shared files** copies its contents to Android `Download/SPARKDROID`; **Fetch shared files** copies Android files into Windows `shared/from-android/`. Transfers are manual ADB copies. This is not a live filesystem mount. A checksum round trip is recorded in `artifacts/acceptance/file-bridge.json`.

| Profile | vCPUs at boot | Guest RAM |
|---|---:|---:|
| Performance (current default) | 8 | 8192 MiB |
| Balanced | 4 | 6144 MiB |
| UltraEfficient | 2 | 3072 MiB |

Profiles take effect when starting a stopped VM. Refresh is configured separately under `display` in `config/runtime.json`; its selected refresh target overrides the legacy profile `fps` values. These are configuration policies, not measured promises of energy savings. Essential Android services are retained. There is no automatic vCPU hotplug, battery policy or notification-aware idle suspension. Dynamic reclamation is disabled: the WHPX balloon experiment made the guest unresponsive. See `artifacts/acceptance/memory-balloon.json`. Use **Stop** for a clean shutdown. The CLI's `EmergencyStop` explicitly terminates an unresponsive VM with an unclean guest shutdown and is reserved for recovery.

## Build and reproduce

```powershell
# Fresh workspace: all downloads remain local and use pinned hashes.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Setup-Tools.ps1 -IncludeBuildSdk
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\Build-Launcher.ps1
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\Inspect-Host.ps1
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\Test-Runtime.ps1 -CheckInput
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\Measure-Runtime.ps1 -Seconds 30 -Package org.videolan.vlc -Label 'explicitly describe current workload'
```

`Setup-Tools.ps1` acquires portable QEMU, PowerShell, Python, pycdlib, ADB, scrcpy and the verified Ubuntu base image. It creates a NoCloud seed and a new local SSH key. First boot downloads the pinned Android image, installs matching Binder modules, compiles the pinned ashmem source for the guest kernel and records provisioning logs. `/data` persists on the guest disk.

The guest modules were actually compiled and loaded, and the Windows launcher was actually compiled and executed. The prebuilt Android image is pinned by OCI digest. `guest/build-android.sh` and the source locks describe a full AOSP/Redroid source build on a suitable x86-64 Linux builder. That full build was not executed on this 32 GB Windows ARM64 host; see `docs/upstream-feasibility.md` for the supported build requirements and acquired sources.

The original QEMU setup did not change the host bootloader, Windows partitions, optional features, global development tools or power plan. The subsequent WSL2 experiment installs Microsoft's WSL package and enables Virtual Machine Platform; Windows requires a restart to complete that setup. It does not change the power plan or global WSL kernel configuration.

## Evidence and remaining work

- `docs/upstream-feasibility.md`: architecture matrix, official sources and image/source locks.
- `docs/compatibility.md`: application-specific observed results and untested functions.
- `docs/MEASUREMENT.md`: reproducible sampling, workload labels and metric limitations.
- `docs/PACKAGING.md`: relocatable local kit, flattened guest disk and fresh management keys.
- `artifacts/acceptance/`: renderer failure, network, file, platform and runtime checks.
- `artifacts/benchmarks/`: raw measurements and process-cold application launch trials.
- `artifacts/host/`: actual hardware inventory and native WHP probes.
- `artifacts/logs/`: QEMU serial/output/error logs; guest provisioning log is `/var/log/sparkdroid/provision.log`.

The host reports about 30.4 GiB usable Windows RAM, while the NVIDIA sensor reports 98304 MiB device memory and the legacy video WMI field reports approximately 4 GiB. These conflicting counters do not establish shared memory or GPU memory capacity. No zero-copy, CUDA, passthrough or near-native speedup claim is made.

Whole-system idle/active Watts, battery drain, calibrated audio latency and controlled energy savings are unavailable from the current AC-powered measurements. NVIDIA sensor Watts are GPU device readings only. Keep this distinction when comparing benchmark reports.
