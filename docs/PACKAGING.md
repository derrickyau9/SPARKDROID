# SPARKDROID portable engineering kit

`scripts/Package-SparkDroid.ps1` assembles `dist/SPARKDROID-0.1.0-win-arm64` as a folder. It includes the self-contained Windows ARM64 launcher, its source, portable QEMU, PowerShell, Python, pycdlib, ADB and scrcpy, guest provisioning scripts, relative runtime configuration, source manifests and package locks, licenses, and measured validation evidence. The .NET SDK and download caches are excluded.

This package contains the **local engineering test guest**, including its existing applications and guest data. It is not a sanitized appliance for public redistribution. The host management private SSH key, its public-key file, the existing seed ISO, host SSH known-hosts file, and runtime PID state are excluded. Existing public authorized keys and SSH host keys inside the guest image remain. No guest account, application token, or app data is scrubbed.

## Prepare and build

Finish guest testing, then shut SPARKDROID down cleanly through its launcher or runtime control script. Stop diagnostic VMs as well. Packaging refuses an active local QEMU process and checks saved PID identity before accessing the disk. It never stops a VM itself.

Run from the project root with PowerShell 7:

```powershell
.\tools\powershell\pwsh.exe -NoProfile -File .\scripts\Package-SparkDroid.ps1 -ValidateOnly
.\tools\powershell\pwsh.exe -NoProfile -File .\scripts\Package-SparkDroid.ps1
```

`-ValidateOnly` checks input paths and the bundled Python/pycdlib import without copying data or requiring a stopped VM. A normal build refuses to overwrite an existing output directory. Failed builds retain their partial assembly under `dist/.SPARKDROID-...-assembling-*` for diagnosis. Copy and image-conversion logs are saved under `artifacts/packaging`.

The script uses `qemu-img convert -O qcow2` to read the existing overlay and write a new flattened image into the package. It verifies that the result has no backing filename and that the original disk's size and modification time stayed unchanged. The active project image and its backing image are not modified. A stopped guest is required for filesystem consistency.

The flattened guest does not need `tools/images/ubuntu-noble-arm64.img`. `-IncludeBaseImage` additionally includes it for workflows that deliberately recreate the VM disk. The runtime must only require the base image when creating a missing disk, and it must prepare a fresh seed and management key before its first Start.

## First launch

Keep all packaged folders together and open `SparkDroid.exe` or `Start-SPARKDROID.cmd`. The launcher finds `scripts/SparkDroid.ps1` beside it and uses the bundled PowerShell. Its first Start generates a new management key and NoCloud seed with a new instance ID. Cloud-init updates guest access for that key and reruns the supplied provisioning logic. Existing Android data is retained by the provisioning configuration.

The kit requires Windows ARM64, working WHPX/Hyper-V support, and the Windows OpenSSH Client commands `ssh.exe` and `ssh-keygen.exe`. The packaged .NET runtime is self-contained. No global Python, PowerShell, .NET runtime, or QEMU installation is needed. The initial provisioning pass can need internet access for guest packages or missing images.

Example command-line controls:

```powershell
.\tools\powershell\pwsh.exe -NoProfile -File .\scripts\SparkDroid.ps1 -Action Status
.\tools\powershell\pwsh.exe -NoProfile -File .\scripts\SparkDroid.ps1 -Action Start
.\tools\powershell\pwsh.exe -NoProfile -File .\scripts\SparkDroid.ps1 -Action Stop
```

The included GPU and application acceptance reports describe what was measured for the source build. They do not establish identical performance on another host. GPU behavior, unsupported APIs, software rendering, and initialization failures must remain explicit in the runtime status and documentation.

## Integrity and licensing

`package-manifest.json` records each packaged file's relative path, byte count, and SHA256. `manifest.sha256` provides the same digests in a simple text format. These manifests exclude themselves. Verify them before first use: running the guest, generating keys, changing a profile, or collecting new logs intentionally changes package files.

QEMU and its MSYS2 dependencies retain their license files under `tools/qemu-arm64/clangarm64/share/licenses`. The .NET library terms and third-party notices are copied separately under `licenses/dotnet`; the SDK binaries remain excluded. The kit includes source URLs and exact package digests under `upstream`, source manifests and patches for Android/Redroid, and third-party notices. The package assembly script does not certify compliance for public redistribution or remove license obligations from bundled guest packages, applications, or runtimes. Preserve all upstream notices when moving this local test kit.

Rebuild the native launcher from `src/SparkDroid.Launcher` with `scripts/Build-Launcher.ps1` and an appropriate .NET SDK. The launcher build is a local compilation. QEMU, ADB, scrcpy, PowerShell, and Python are pinned upstream binary distributions; they were not all rebuilt from source in this workspace.
