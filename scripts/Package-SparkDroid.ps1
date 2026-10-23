#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?$')][string]$Version = '0.1.0',
    [string]$OutputDirectory,
    [switch]$IncludeBaseImage,
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$configPath = Join-Path $root 'config/runtime.json'
$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
$dist = Join-Path $root 'dist'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $dist "SPARKDROID-$Version-win-arm64" }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$boundary = [IO.Path]::GetFullPath($dist).TrimEnd('\') + '\'
if (-not $OutputDirectory.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)) { throw 'Package output must be a child of this workspace dist directory.' }

function Full([string]$path) {
    if ([IO.Path]::IsPathRooted($path)) { throw "Runtime configuration must use relative paths: $path" }
    $absolute = [IO.Path]::GetFullPath((Join-Path $root $path))
    if (-not $absolute.StartsWith(($root.TrimEnd('\') + '\'),[StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes project: $path" }
    $absolute
}
function RequireFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required package input missing: $path" }
}
function RequireDirectory([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Required package directory missing: $path" }
}
function AssertVmStopped {
    $stateFile = Join-Path $root 'state/runtime.json'
    $qemu = Full $config.qemu
    if (Test-Path -LiteralPath $stateFile) {
        $saved = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        $savedProcess = Get-Process -Id $saved.pid -ErrorAction SilentlyContinue
        if ($savedProcess) {
            if ($savedProcess.Path -ne $qemu -or $savedProcess.StartTime.ToUniversalTime().Ticks -ne $saved.startTicks) {
                throw 'Runtime PID identity mismatch. Packaging cannot safely establish that the source VM is stopped.'
            }
            throw 'SPARKDROID is running. Shut it down cleanly using the launcher or SparkDroid.ps1 -Action Stop before packaging.'
        }
    }
    $localPrefix = [IO.Path]::GetFullPath((Join-Path $root 'tools/qemu-arm64')).TrimEnd('\') + '\'
    $active = Get-Process -Name 'qemu-system-aarch64','qemu-system-aarch64w' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($localPrefix,[StringComparison]::OrdinalIgnoreCase) }
    if ($active) { throw 'A SPARKDROID QEMU VM or diagnostic VM remains active. Packaging requires all local QEMU VMs to be stopped.' }
    # An exclusive, read-only open also catches a source disk held by another process.
    $stream = [IO.File]::Open((Full $config.disk),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    $stream.Dispose()
}

$launcher = Join-Path $root 'artifacts/launcher/win-arm64'
$copyPlans = @(
    @{source=$launcher;relative=''},
    @{source=(Join-Path $root 'scripts');relative='scripts'},
    @{source=(Join-Path $root 'config');relative='config'},
    @{source=(Join-Path $root 'guest');relative='guest'},
    @{source=(Join-Path $root 'docs');relative='docs'},
    @{source=(Join-Path $root 'src');relative='src'},
    @{source=(Join-Path $root 'upstream');relative='upstream'},
    @{source=(Join-Path $root 'tools/qemu-arm64');relative='tools/qemu-arm64'},
    @{source=(Join-Path $root 'tools/android');relative='tools/android'},
    @{source=(Join-Path $root 'tools/scrcpy');relative='tools/scrcpy'},
    @{source=(Join-Path $root 'tools/powershell');relative='tools/powershell'},
    @{source=(Join-Path $root 'tools/python');relative='tools/python'},
    @{source=(Join-Path $root 'tools/python-libs');relative='tools/python-libs'},
    @{source=(Join-Path $root 'artifacts/toolchain/sources');relative='artifacts/toolchain/sources'}
)
foreach ($plan in $copyPlans) { RequireDirectory $plan.source }
foreach ($file in @('SparkDroid.exe','SparkDroid.runtimeconfig.json')) { RequireFile (Join-Path $launcher $file) }
foreach ($path in @($config.qemu,$config.qemuImg,$config.firmware,$config.adb,$config.scrcpy,$config.disk,'tools/powershell/pwsh.exe','tools/python/python.exe','scripts/Prepare-Guest.ps1','scripts/make-seed.py','guest/provision-redroid.sh','upstream/qemu-arm64.lock.json')) { RequireFile (Full $path) }
if($config.display.server){RequireFile (Full $config.display.server)}
RequireFile (Full 'tools/qemu-arm64/clangarm64/share/licenses/qemu/COPYING')
RequireFile (Full 'tools/qemu-arm64/clangarm64/share/licenses/virglrenderer/COPYING')
RequireFile (Full 'tools/dotnet/LICENSE.txt')
RequireFile (Full 'tools/dotnet/ThirdPartyNotices.txt')
if ($IncludeBaseImage) { RequireFile (Full $config.baseImage) }
$python = Full 'tools/python/python.exe'
& $python -c "import sys; sys.path.insert(0, sys.argv[1]); import pycdlib; print('Portable Python and pycdlib import succeeded')" (Full 'tools/python-libs')
if ($LASTEXITCODE) { throw 'Bundled Python/pycdlib verification failed.' }
$preflight = [ordered]@{
    projectRoot=$root;destination=$OutputDirectory;version=$Version
    sourceDisk=(Full $config.disk);sourceDiskBytes=(Get-Item -LiteralPath (Full $config.disk)).Length
    launcher=(Join-Path $launcher 'SparkDroid.exe');copyDirectories=$copyPlans.Count
    includeBaseImage=[bool]$IncludeBaseImage;localTestGuestDataRetained=$true
    privateHostStateCopied=$false;validateOnly=[bool]$ValidateOnly
}
if ($ValidateOnly) { $preflight | ConvertTo-Json -Depth 4; return }
if (Test-Path -LiteralPath $OutputDirectory) { throw "Refusing to overwrite an existing package: $OutputDirectory" }
AssertVmStopped
New-Item -ItemType Directory -Force $dist | Out-Null
if ((Get-Item -LiteralPath $dist -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The package dist directory must be a physical directory inside this workspace.' }
$stage = Join-Path $dist ('.' + (Split-Path -Leaf $OutputDirectory) + '-assembling-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
$logDirectory = Join-Path $root 'artifacts/packaging'
New-Item -ItemType Directory -Force $logDirectory | Out-Null
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$copyLog = Join-Path $logDirectory "copy-$stamp.log"
try {
    $excludedDirectories = @('.git','obj','__pycache__',(Join-Path $root 'upstream/redroid-doc')) + @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Recurse -Directory -Filter bin | ForEach-Object { $_.FullName })
    foreach ($plan in $copyPlans) {
        $target = if ($plan.relative) { Join-Path $stage $plan.relative } else { $stage }
        $options = @($plan.source,$target,'/E','/COPY:DAT','/DCOPY:DAT','/XJ','/R:1','/W:1','/NFL','/NDL','/NP',"/LOG+:$copyLog",'/XD') + $excludedDirectories + @('/XF','*.pyc','*.base64')
        & robocopy.exe @options | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Copy failed: $($plan.relative), robocopy exit $LASTEXITCODE; see $copyLog" }
    }
    foreach ($file in @('README.md','LICENSE','LICENSE.txt','NOTICE','NOTICE.md')) {
        $source = Join-Path $root $file
        if (Test-Path -LiteralPath $source -PathType Leaf) { Copy-Item -LiteralPath $source -Destination (Join-Path $stage $file) }
    }
    $dotnetNotices = Join-Path $stage 'licenses/dotnet'
    New-Item -ItemType Directory -Force $dotnetNotices | Out-Null
    foreach ($file in @('LICENSE.txt','ThirdPartyNotices.txt')) {
        Copy-Item -LiteralPath (Full "tools/dotnet/$file") -Destination (Join-Path $dotnetNotices $file)
    }
    # Evidence is small and reviewable; exclude binary caches, host logs, and test APKs.
    foreach ($directory in @('acceptance','benchmarks','host','compatibility')) {
        $source = Join-Path $root "artifacts/$directory"
        if (-not (Test-Path -LiteralPath $source)) { continue }
        $target = Join-Path $stage "artifacts/$directory"
        & robocopy.exe $source $target /E /COPY:DAT /XJ /R:1 /W:1 /NFL /NDL /NP "/LOG+:$copyLog" | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Evidence copy failed: $directory" }
    }
    $toolEvidence = Join-Path $stage 'artifacts/toolchain'
    New-Item -ItemType Directory -Force $toolEvidence | Out-Null
    foreach ($pattern in @('qemu*-validation.json','angle-renderer*.json','linux-virgl*.json','linux-virgl-validation.txt','graphics-path.md','android-virgl-diagnosis.md','balloon-win32-*.json','balloon-win32-diagnosis.md','redroid-graphics-libraries.txt','source-excerpt-hashes.json')) {
        Get-ChildItem -LiteralPath (Join-Path $root 'artifacts/toolchain') -Filter $pattern -File | Copy-Item -Destination $toolEvidence
    }
    New-Item -ItemType Directory -Force (Join-Path $stage 'state'),(Join-Path $stage 'shared'),(Join-Path $stage 'artifacts/logs'),(Join-Path $stage 'artifacts/benchmarks') | Out-Null
    if ($IncludeBaseImage) {
        $baseDestination = Join-Path $stage $config.baseImage
        New-Item -ItemType Directory -Force (Split-Path -Parent $baseDestination) | Out-Null
        Copy-Item -LiteralPath (Full $config.baseImage) -Destination $baseDestination
    }
    $packagedDisk = Join-Path $stage $config.disk
    New-Item -ItemType Directory -Force (Split-Path -Parent $packagedDisk) | Out-Null
    AssertVmStopped
    $sourceBefore = Get-Item -LiteralPath (Full $config.disk) | Select-Object Length,LastWriteTimeUtc
    # qemu-img opens its input read-only and writes a NEW self-contained image.
    & (Full $config.qemuImg) convert -p -O qcow2 (Full $config.disk) $packagedDisk *> (Join-Path $logDirectory "flatten-$stamp.log")
    if ($LASTEXITCODE) { throw "Guest flattening failed: $LASTEXITCODE" }
    $sourceAfter = Get-Item -LiteralPath (Full $config.disk) | Select-Object Length,LastWriteTimeUtc
    if ($sourceBefore.Length -ne $sourceAfter.Length -or $sourceBefore.LastWriteTimeUtc -ne $sourceAfter.LastWriteTimeUtc) { throw 'Source guest disk changed during packaging. Package is not accepted.' }
    $imageInfoText = & (Full $config.qemuImg) info --output=json $packagedDisk
    if ($LASTEXITCODE) { throw 'Packaged guest image inspection failed.' }
    $imageInfo = $imageInfoText | ConvertFrom-Json
    if ($imageInfo.'backing-filename' -or $imageInfo.'full-backing-filename') { throw 'Packaged image still depends on an external backing image.' }
    $imageInfoText | Set-Content -LiteralPath (Join-Path $stage 'guest-image-info.json') -Encoding utf8
    # Never copy host state/seed/keys. Prepare-Guest creates fresh ones on first Start.
    foreach ($forbidden in @('state/ssh_key','state/ssh_key.pub','state/known_hosts','state/runtime.json','state/seed.iso','state/seed/user-data','state/gpu-probe-vm.json')) {
        if (Test-Path -LiteralPath (Join-Path $stage $forbidden)) { throw "Forbidden host state in package: $forbidden" }
    }
    @'
@echo off
"%~dp0SparkDroid.exe" --project "%~dp0." %*
'@ | Set-Content -LiteralPath (Join-Path $stage 'Start-SPARKDROID.cmd') -Encoding ascii
    @'
SPARKDROID 0.1.0 local engineering kit for Windows ARM64

Open SparkDroid.exe, then choose Start. The runtime creates a new local SSH
management key and NoCloud seed before boot. Keep every packaged folder together.
Windows OpenSSH Client (ssh.exe and ssh-keygen.exe) is required.

This is an UNSANITIZED LOCAL TEST GUEST, not a public distribution image.
The guest disk retains installed test apps, Android app data, existing guest SSH
host keys and prior authorized public keys. The workspace host private management
key and its seed ISO are omitted. No user accounts or credentials are sanitized.
Do not publish this guest image without a separate sanitation and licensing review.

Read docs/PACKAGING.md and the measured acceptance reports before use.
The .NET ARM64 runtime, PowerShell, Python, QEMU, ADB and scrcpy are bundled.
The .NET SDK is not bundled; launcher source is included under src/.
manifest.sha256 and package-manifest.json describe the untouched packaged files.
'@ | Set-Content -LiteralPath (Join-Path $stage 'PACKAGE-README.txt') -Encoding utf8
    $notice = @"
SPARKDROID local test kit $Version

Native launcher source: src/SparkDroid.Launcher. Rebuild: scripts/Build-Launcher.ps1
with an ARM64-capable .NET SDK10. The bundled launcher is self-contained.
.NET library terms and third-party notices: licenses/dotnet.
QEMU and dependency licenses: tools/qemu-arm64/clangarm64/share/licenses.
QEMU original source/digests: upstream/qemu-source.lock.json.
QEMU binary and dependency package digests: upstream/qemu-arm64.lock.json.
Additional runtime versions, source URLs and licenses: upstream/*lock.json and
each tool distribution's license/notice files. Python pycdlib includes its
dist-info license metadata under tools/python-libs.
Android/Redroid source manifests and patches: upstream/aosp and upstream/redroid-patches.
Guest packages and containers retain their upstream license obligations.
This assembly does not grant additional redistribution rights for those components.
"@
    $notice | Set-Content -LiteralPath (Join-Path $stage 'THIRD-PARTY-NOTICES.txt') -Encoding utf8
    $preflight.createdUtc = [DateTime]::UtcNow.ToString('o')
    $preflight.guestImageFlattened = $true
    $preflight.guestImageInfo = $imageInfo
    $preflight.packageKind = 'local-unsanitized-engineering-test-kit'
    $preflight | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $stage 'package-info.json') -Encoding utf8
    $files = @(Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
        [ordered]@{path=[IO.Path]::GetRelativePath($stage,$_.FullName).Replace('\','/');bytes=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    [ordered]@{schemaVersion=1;version=$Version;createdUtc=[DateTime]::UtcNow.ToString('o');algorithm='SHA256';excludes=@('package-manifest.json','manifest.sha256');files=$files} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $stage 'package-manifest.json') -Encoding utf8
    $files | ForEach-Object { "$($_.sha256) *$($_.path)" } | Set-Content -LiteralPath (Join-Path $stage 'manifest.sha256') -Encoding utf8
    if (Test-Path -LiteralPath $OutputDirectory) { throw 'The output directory appeared during assembly; refusing to merge into it.' }
    $outputParent = Split-Path -Parent $OutputDirectory
    New-Item -ItemType Directory -Force $outputParent | Out-Null
    $resolvedStage = (Resolve-Path -LiteralPath $stage).ProviderPath
    $resolvedParent = (Resolve-Path -LiteralPath $outputParent).ProviderPath
    if (-not $resolvedStage.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or ($resolvedParent -ne $dist -and -not $resolvedParent.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase))) { throw 'Resolved package move paths escaped the intended dist directory.' }
    Move-Item -LiteralPath $resolvedStage -Destination $OutputDirectory
    [pscustomobject]@{Package=$OutputDirectory;Files=$files.Count;TotalBytes=($files | ForEach-Object { $_.bytes } | Measure-Object -Sum).Sum;FlattenedGuest=$true;HostPrivateKeysIncluded=$false} | ConvertTo-Json
} catch {
    throw "Packaging failed. Source files were not removed. Partial assembly retained at $stage. $($_.Exception.Message)"
}
