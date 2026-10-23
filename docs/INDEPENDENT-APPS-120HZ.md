# Individual Android apps on Windows, 120 Hz target

Updated 2026-10-23 on the NVIDIA N1X Windows ARM64 laptop.

## Open apps

The installed kit is `dist/SPARKDROID-0.1.0-win-arm64`. Desktop and Start menu entries for WeChat and VLC point at its self-contained ARM64 `SparkDroid.exe`:

```powershell
SparkDroid.exe --project "<absolute-kit-folder>" --package com.tencent.mm
SparkDroid.exe --project "<absolute-kit-folder>" --package org.videolan.vlc
```

Each opens its own Windows window and Android virtual display. The full control panel is unnecessary. Android starts automatically if stopped; simultaneous starts share a file lock to avoid starting two VMs on the same disk. Closing an app window leaves the shared Android VM running. Use the control panel's Stop command to shut it down cleanly.

Use the launcher's **Desktop shortcut** action for additional installed apps; it creates a Start menu entry too. `SparkDroid.exe --project "<kit>" --export-shortcuts` exports all installed user apps while Android is running. Shortcuts must be recreated after moving the kit.

## Refresh configuration

The current default is **Smooth 60 Hz**: Performance (8 vCPUs, 8192 MiB), 540×960 at 180 DPI, H.264 with low encoder complexity, and zero extra video buffering. This preserves the logical UI size while reducing pixels and render frequency. It does not change Windows' own 120 Hz screen setting.

**120 Hz (experimental)** selects 720×1280 at 240 DPI with `display.matchWindows=true`, reading the primary Windows screen rate at launch. Moving a running window between monitors does not automatically reconfigure it. Both modes are available in the launcher:

```powershell
.\scripts\SparkDroid.ps1 -Action SetDisplay -DisplayMode Smooth
.\scripts\SparkDroid.ps1 -Action SetDisplay -DisplayMode HighRefresh
```

The Windows primary screen reports 120 Hz through GDI `VREFRESH`. The Android container receives `androidboot.redroid_fps=120`; persistent Android `peak_refresh_rate` and `min_refresh_rate` are both 120. The minimum matters: leaving it at the default allowed the main compositor to run at 60 Hz even while an app's virtual display reported 120 Hz and its draw callbacks ran at 120/s.

Upstream scrcpy 5.0.1 creates its virtual display through the legacy API without requesting a refresh rate. Our server uses Android 14+ `VirtualDisplayConfig.Builder.setRequestedRefreshRate()`, derived from `--max-fps`. Both the virtual display mode and the main compositor rate were inspected; changing the capture cap alone was insufficient. Source revision, patch and binary checksum are in `upstream/scrcpy-refresh-server.lock.json` and `upstream/scrcpy-refresh/server-refresh.patch`.

`SparkDroid.ps1 -Action SetDisplay` applies the selected container refresh and Android settings. A changed container boot parameter requires an Android restart. The existing `/data` mount is retained, and the previous stopped container metadata is retained for recovery. This action is explicit because it closes running app streams when the container must restart.

## Actual FPS and limits

The diagnostic app in `src/SparkDroid.FrameProbe` continuously animates. Its draw callback rate is separate from the Windows client's `--print-fps` output. Measurements discard the first two one-second samples; raw samples and logs are under `artifacts/refresh/`. Results are observations of a synthetic app, not guarantees for WeChat, VLC, games, or every UI operation.

| 8-vCPU test | Audio | Windows client mean FPS | One-second sample range |
|---|---|---:|---:|
| 720×1280 H.264, main compositor still at 60 Hz | off | 59.92 | 59–60 |
| 720×1280 VP8, main compositor fixed to 120 Hz, short test | off | 119.08 | 104–131 |
| 720×1280 H.264, low complexity | off | 115.88 | 100–121 |
| 720×1280 VP8, 30-second test | on | 82.48 | 3–120 |
| 540×960 VP8, 20-second test | on | 96.12 | 84–113 |
| 720×1280 H.264, low complexity, 30-second test | on | 81.56 | 58–116 |
| 720×1280 VP8 with WeChat and VLC windows open | on | 75.65 | 59–88 |
| 720×1280 H.264, low complexity, WeChat and VLC windows open | on | 40.24 | 0–75 |
| Current Smooth mode: 540×960 H.264, low complexity, 60 Hz, 30-second test | on | 59.33 | 55–61 |

Values above 120 in an individual one-second reporting bucket are timing/queue variations, not a display refresh above 120 Hz. Short tests do not establish sustained performance. The audio-enabled and resolution trials differ in timing and workload and do not isolate audio as the cause of slowdown.

The result is **working independent app windows with a verified 120 Hz display mode, but sustained 120 FPS acceptance remains unmet**. Android uses SwiftShader and software video encoders. Windows H.264 decoding uses D3D11VA; that does not make Android rendering or encoding GPU accelerated. Earlier Android VirGL tests produced black frames and remain rejected. A working Android GPU/composition path or a faster presentation bridge is needed before promising stable 120 FPS under concurrent workloads. Apps and source videos can also intentionally produce fewer frames.

## Reproduce

The portable kit already includes the custom server. Building it requires only local, pinned tools, without modifying global Java or Android SDK installations:

```powershell
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\Setup-RefreshBuildTools.ps1
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\Build-RefreshServer.ps1
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\Build-FrameProbe.ps1
# Install the generated artifacts/refresh/FrameProbe.apk into the active kit.
& .\tools\powershell\pwsh.exe -NoProfile -File .\scripts\Measure-AppFps.ps1 -Codec h264 -LowComplexity -WithAudio -Seconds 30
```

Measurement defaults to the active kit, not the separate source-tree VM. Do not run both VMs on their shared forwarded ports. The diagnostic APK is removed from the normal installed application list after testing.
