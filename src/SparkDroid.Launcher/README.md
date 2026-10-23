# SPARKDROID native launcher

`SparkDroid.exe` is a self-contained Windows ARM64 .NET 10 WinForms application. Build from the project root with:

```powershell
pwsh -NoProfile -File scripts/Build-Launcher.ps1
```

Output: `artifacts/launcher/win-arm64/SparkDroid.exe` and its adjacent runtime files. Keep all published files together. The executable finds `scripts/SparkDroid.ps1` by walking parent directories, or accepts `--project <absolute project path>`.

The launcher uses PowerShell 7 from `tools/powershell/pwsh.exe`, Program Files or PATH. It invokes the runtime control script using argument arrays, without shell interpolation. It does not install host features, start Android automatically or poll in the background. Start applies the selected Performance, Balanced or UltraEfficient runtime profile; select a profile before starting. Runtime scripts determine what a profile can implement.

Features:

- Start, stop, suspend, resume, status and measured benchmark commands.
- APK picker, multi-file drag and drop, positional APK command-line paths and `--apk <path>`. A separate **Install splits** picker installs a base APK and all splits for one application in a single runtime installation session.
- Installed package list and filter, per-app launch (`--package com.example.app`), uninstall with data-loss confirmation, and desktop shortcut creation.
- Interactive ADB console, shared/project folder shortcuts, explicit **Send shared files** and **Fetch shared files** ADB transfers between host `shared/` and Android `/sdcard/Download/SPARKDROID`, raw runtime diagnostics/activity logs and export. These are manual copies; the folder is not mounted or continuously synchronized. Session logs persist in `artifacts/launcher/logs` when writable.
- User-invoked registration in Windows APK **Open with** choices. Choose SPARKDROID and **Always** in Windows to enable double-click APK handling. The application does not silently replace Windows' default association.

```powershell
& artifacts/launcher/win-arm64/SparkDroid.exe --apk 'C:\Downloads\application.apk'
& artifacts/launcher/win-arm64/SparkDroid.exe --project 'C:\Projects\SPARKDROID' --package com.example.app
```

Selecting multiple APK files in the ordinary picker or by drag and drop installs each file independently. **Install splits** writes a temporary JSON file containing the selected absolute paths and passes it to `-Action InstallSplit -Apk <manifest>`, then deletes the manifest. The launcher sends `Launch` to the runtime; separate resizable Android windows, audio, clipboard, touch and other integration depend on the configured Android/scrcpy transport. It does not claim those capabilities from a successful launcher build. Runtime errors and missing dependencies are displayed verbatim. Boot, GPU acceleration, APK compatibility and power behavior require independent runtime measurements.

`--smoke-test` creates and disposes the Windows form handle without displaying it, checks package validation/parsing, returns a JSON report and exits without starting Android. This validates ARM64 process execution and WinForms construction; it is not an Android boot test. Optional `--screenshot <file.png>` draws the initial form to a bitmap without starting the runtime. The build script runs this on Windows ARM64 and saves `smoke-test.json` and `launcher-preview.png` beside the executable.

`--probe-runtime` executes the same read-only Status path used by the UI and returns the runtime script's output/exit status without displaying a window. Run `scripts/Test-Launcher.ps1` after building to check both native UI construction and launcher-to-PowerShell runtime status integration; evidence is saved to `artifacts/launcher/host-integration-test.json`.
