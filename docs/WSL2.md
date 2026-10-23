# WSL2 ARM64 backend

## Current status — 2026-10-23

This is an experimental backend under construction. **Android has not booted on WSL, and WSL/Android hardware rendering has not yet passed a runtime test.**

- WSL 3.0.3 and WSLg 1.0.79 are installed on this Windows ARM64 host. Installation explicitly requires a Windows restart; the current boot cannot start WSL2.
- The official Ubuntu 24.04.5 ARM64 WSL archive has been downloaded and SHA-256 verified. Its URL and checksum are pinned in `upstream/ubuntu-wsl-arm64.lock.json`.
- Separate distro import, GPU diagnostics and Android management scripts are implemented. Offline script/ABI/argument checks passed; these are not runtime acceptance.
- The installed Microsoft ARM64 kernel 6.18.54.1 has **no Android Binder support** in its embedded configuration. This must be resolved before Android can boot. This pinned Redroid image also needs ashmem for its software gralloc. An old Ubuntu 6.8 module cannot be reused in this kernel.
- No SPARKDROID WSL distro has been successfully imported yet. The existing QEMU app data is separate and remains usable through its existing launcher.

## Continue after restarting Windows

Double-click `Setup-SPARKDROID-WSL.cmd`, or use the portable PowerShell commands below. Import creates an isolated distro named `SPARKDROID` and configures systemd only inside it. Probe installs Linux graphics diagnostics and performs a real shader draw/readback test. It does not provision Android.

```powershell
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\Setup-WSL.ps1 -Action Import
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\Setup-WSL.ps1 -Action Probe
```

For a fresh checkout, `Setup-WSL.ps1 -Action Prepare` downloads and verifies the pinned archive. WSL itself must first be installed using Microsoft's `wsl --install --no-distribution`, with elevation/restart when Windows requests it. Local installation files remain in ignored `tools/wsl/` and `state/wsl/`.

`state/wsl/host-setup.json` records the boot at which this host's WSL installation requested a restart. Setup refuses Import/Probe until a new boot is observed. It never restarts Windows automatically. A same-named distro without the project ownership marker is preserved and rejected.

Reports are saved under `artifacts/wsl/`. `gpu-probe.json` reports success only for ARM64 Linux, usable `/dev/dxg`, ARM64 WSL D3D12/DXCore libraries, an NVIDIA D3D12 renderer, and correct shader output pixels. Missing `/dev/dri` does not by itself fail this GPU route. The report always separates Android acceleration from Linux rendering.

## Android management contract

These commands become usable **after the Binder/ashmem kernel dependency is resolved**. Provision currently fails clearly when required devices are absent instead of reporting a successful Android installation. All runtime operations target the separate distro/container and use ADB localhost port **15565**. The QEMU backend uses 15555.

```powershell
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\SparkDroid-WSL.ps1 -Action Status
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\SparkDroid-WSL.ps1 -Action Probe
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\SparkDroid-WSL.ps1 -Action Provision
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\SparkDroid-WSL.ps1 -Action Start
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\SparkDroid-WSL.ps1 -Action Install -Apk C:\path\app-arm64.apk
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\SparkDroid-WSL.ps1 -Action Launch -Package org.videolan.vlc
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\SparkDroid-WSL.ps1 -Action Stop
```

Stop requests container shutdown, syncs filesystems and terminates only `SPARKDROID`. Android `/data` is persisted inside that distro. The scripts do not edit global `.wslconfig`, replace the shared WSL kernel, shut down all WSL distributions or install a global port proxy. Kernel integration is outstanding, not an omitted successful step.

Defaults are explicit software rendering and Smooth 60 Hz (540×960). The existing WinForms control panel still manages QEMU; WSL has a separate CLI during development. APK preflight rejects packages whose native libraries do not match `arm64-v8a`, including the user's old 32-bit-only CPU-Z APK. Moving to WSL does not add a missing Android ABI.

## Graphics direction

The selected first experiment is `Android Mesa virpipe → WSL virglrenderer → Mesa D3D12 → /dev/dxg → NVIDIA`. Android's Bionic libraries and Microsoft's glibc Linux driver cannot simply be copied into one another. A renderer process in WSL and a socket transport can cross that boundary, but the Android EGL/gralloc/SurfaceFlinger integration still needs implementation and pixel validation.

After Linux GPU qualification, validate the Linux transport, then Android colored buffers, then SurfaceFlinger frames. Separately prototype a Wayland/WSLg presentation route to reduce the current Android video-encoding overhead. WSL2 itself is hardware virtualization, and does not automatically guarantee lower power use or 120 FPS. Read [graphics research and primary sources](WSL-GRAPHICS-RESEARCH.md) for WSA history, route tradeoffs and test gates.

## Offline validation

```powershell
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\Test-WslBackend.ps1
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\Test-WslSetup.ps1
& .\tools\python\python.exe -m py_compile .\guest\wsl\gpu-probe.py
```

`gpu-probe-windows-negative.json` deliberately records running the Linux probe on Windows; its expected failure proves no hardware-success claim is fabricated on the wrong host. It is not a WSL GPU failure measurement.
