[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$package=Join-Path $root 'tools/wsabuilds/LTS8-arm64/WSA_2407.40000.4.0_arm64'
$source=Join-Path $root 'tools/wsabuilds/vendor-audio-candidate/vendor.vhdx'
$target=Join-Path $package 'vendor.vhdx'
$backup=Join-Path $root 'tools/wsabuilds/backups/abi-before-audio'
$report=Get-Content -Raw (Join-Path $root 'artifacts/wsa/vendor-audio-candidate-result.json')|ConvertFrom-Json
$sourceHash='7300d4e7c6fe204210e99c0ea6d10da9103041ff112381d29e3e248badc0155a'
$candidateHash='dd3593f3a182a983aed1ca15a75de7c913eb010781865177ed07eb2ba82a382e'
$systemHash='6a39a8636e364e45eca3fcb35b9d223c3e4fa3d0ca332ebafd5e85a954888b4b'
if(-not $report.success -or -not $report.filesystemBuild.success -or -not $report.sourceHashesUnchanged){throw 'Candidate build has not passed'}
if($report.sourceSha256 -ne $sourceHash -or $report.candidateSha256 -ne $candidateHash){throw 'Unexpected candidate receipt'}
if(@($report.filesystemBuild.changedFiles).Count -ne 1 -or $report.filesystemBuild.changedFiles[0] -ne 'bin/hw/android.hardware.audio.service'){throw 'Unexpected modified files'}
$check=@($report.filesystemBuild.commands|Where-Object stage -eq 'candidate-fsck')
if($check.Count -ne 1 -or $check[0].exitCode -ne 0 -or -not $report.filesystemBuild.targetMetadataPreserved){throw 'Filesystem verification failed'}
$registered=Get-AppxPackage 'MicrosoftCorporationII.WindowsSubsystemForAndroid'
if(-not $registered -or $registered.InstallLocation -ne $package){throw 'Unexpected registered WSA path'}
if(Get-Process WsaClient,vmmemWSA -ErrorAction SilentlyContinue){throw 'Stop WSA before applying'}
if((Get-Service WsaService).Status -ne 'Stopped'){throw 'WSA service must be stopped'}
if(Test-Path -LiteralPath $backup){throw 'Backup exists; refusing overwrite or repeated apply'}
if((Get-FileHash -LiteralPath $target).Hash -ine $sourceHash){throw 'Installed vendor changed'}
if((Get-FileHash -LiteralPath $source).Hash -ine $candidateHash){throw 'Candidate changed'}
if((Get-FileHash -LiteralPath (Join-Path $package 'system.vhdx')).Hash -ine $systemHash){throw 'Installed system changed'}
$handle=[IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$handle.Dispose()
New-Item -ItemType Directory -Path $backup|Out-Null
$saved=Join-Path $backup 'vendor.vhdx'
Copy-Item -LiteralPath $target -Destination $saved
if((Get-FileHash -LiteralPath $saved).Hash -ine $sourceHash){throw 'Backup verification failed'}
try {
    Copy-Item -LiteralPath $source -Destination $target -Force
    if((Get-FileHash -LiteralPath $target).Hash -ine $candidateHash){throw 'Installed hash mismatch'}
} catch {
    Copy-Item -LiteralPath $saved -Destination $target -Force
    if((Get-FileHash -LiteralPath $target).Hash -ine $sourceHash){throw 'Rollback failed; retained backup must be restored before boot'}
    throw
}
[ordered]@{appliedUtc=[DateTime]::UtcNow.ToString('o');backupDirectory='tools/wsabuilds/backups/abi-before-audio';
    modifiedImages=@('vendor.vhdx');sourceSha256=$sourceHash;installedSha256=$candidateHash;
    changedGuestFiles=@('/vendor/bin/hw/android.hardware.audio.service');userdataModified=$false;
    runtimeBootVerified=$false;inactiveAvbExperiment=$true;avbValid=$false;avbEnforcementChanged=$false;
    note='Experimental ELF64 audio replacement. Expanded filesystem has no valid AVB trailer. Original images and prior ABI candidate retained for rollback.'}|
    ConvertTo-Json -Depth 4|Set-Content (Join-Path $root 'artifacts/wsa/vendor-audio-applied.json') -Encoding utf8
Write-Output 'Audio candidate applied and hash verified; prior vendor retained in backup.'
