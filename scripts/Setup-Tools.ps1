# Runs on stock Windows PowerShell 5.1 or PowerShell 7; all files stay local.
[CmdletBinding()]
param([switch]$IncludeBuildSdk)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Set-Location -LiteralPath $root
New-Item -ItemType Directory -Force tools/downloads,upstream | Out-Null
function GetLocked([string]$name,[string]$archive,[string]$destination){
    $lock=Get-Content -LiteralPath "upstream/$name.lock.json" -Raw|ConvertFrom-Json
    $download=Join-Path $root "tools/downloads/$archive"
    if(-not(Test-Path -LiteralPath $download)){
        & curl.exe --fail --location --silent --show-error --retry 3 --output $download $lock.Url
        if($LASTEXITCODE -ne 0){throw "$name download failed"}
    }
    if((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $lock.Sha256){throw "$name SHA256 mismatch; download was not extracted"}
    if($destination){Expand-Archive -LiteralPath $download -DestinationPath (Join-Path $root $destination) -Force}
    return $download
}
if(-not(Test-Path tools/powershell/pwsh.exe)){$null=GetLocked powershell powershell-arm64.zip tools/powershell}
$pwsh=Join-Path $root 'tools/powershell/pwsh.exe'
if(-not(Test-Path tools/python/python.exe)){$null=GetLocked python python-arm64.zip tools/python}
if(-not(Test-Path tools/android/platform-tools/adb.exe)){$null=GetLocked adb platform-tools.zip tools/android}
if(-not(Test-Path tools/scrcpy/scrcpy.exe)){
    $zip=GetLocked scrcpy scrcpy-arm64.zip ''
    New-Item -ItemType Directory -Force tools/scrcpy|Out-Null
    & tar.exe -xf $zip -C tools/scrcpy --strip-components 1
    if($LASTEXITCODE -ne 0){throw 'scrcpy extraction failed'}
}
& $pwsh -NoProfile -File scripts/toolchain/Get-QemuArm64.ps1
if($LASTEXITCODE -ne 0){throw 'QEMU provisioning failed'}
$imageLock=Get-Content upstream/ubuntu-image.lock.json -Raw|ConvertFrom-Json
if(-not(Test-Path tools/images/ubuntu-noble-arm64.img)){
    New-Item -ItemType Directory -Force tools/images|Out-Null
    & curl.exe --fail --location --silent --show-error --retry 3 --output tools/images/ubuntu-noble-arm64.img $imageLock.Url
    if($LASTEXITCODE -ne 0){throw 'Ubuntu acquisition failed'}
}
if((Get-FileHash tools/images/ubuntu-noble-arm64.img -Algorithm SHA256).Hash -ne $imageLock.Sha256){throw 'Ubuntu checksum mismatch'}
# pycdlib is a pure-Python, pinned wheel. The embedded interpreter needs no pip.
if(-not(Test-Path tools/python-libs/pycdlib)){
    $lock=Get-Content upstream/pycdlib.lock.json -Raw|ConvertFrom-Json
    $wheel=Join-Path $root 'tools/downloads/pycdlib.whl.zip'
    & curl.exe --fail --location --silent --show-error --output $wheel $lock.Url
    if($LASTEXITCODE -ne 0){throw 'pycdlib download failed'}
    if((Get-FileHash $wheel -Algorithm SHA256).Hash -ne $lock.Sha256){throw 'pycdlib checksum mismatch'}
    Expand-Archive -LiteralPath $wheel -DestinationPath tools/python-libs -Force
}
if($IncludeBuildSdk -and -not(Test-Path tools/dotnet/dotnet.exe)){
    $null=GetLocked dotnet dotnet-arm64.zip tools/dotnet
}
if(-not(Test-Path tools/scrcpy/scrcpy-server-sparkdroid)){
    & $pwsh -NoProfile -File scripts/Setup-RefreshBuildTools.ps1
    if($LASTEXITCODE -ne 0){throw 'Refresh bridge dependencies failed'}
    & $pwsh -NoProfile -File scripts/Build-RefreshServer.ps1
    if($LASTEXITCODE -ne 0){throw 'Refresh bridge build failed'}
}
& $pwsh -NoProfile -File scripts/Prepare-Guest.ps1
if($LASTEXITCODE -ne 0){throw 'Guest seed preparation failed'}
Write-Output 'Portable tools and guest seed ready. Run Start-SPARKDROID.cmd.'
