[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$package=Join-Path $root 'tools\wsabuilds\LTS8-arm64\WSA_2407.40000.4.0_arm64'
$candidate=Join-Path $root 'tools\wsabuilds\arm64-only-candidate'
$backup=Join-Path $root 'tools\wsabuilds\backups\lts8-before-arm64-only'
$report=Get-Content -Raw (Join-Path $root 'artifacts\wsa\arm64-only-patch-result.json') | ConvertFrom-Json
$fsck=Get-Content -Raw (Join-Path $root 'artifacts\wsa\arm64-only-fsck.json') | ConvertFrom-Json
if(-not $fsck.success){throw 'Independent filesystem checks have not passed'}
$registered=Get-AppxPackage 'MicrosoftCorporationII.WindowsSubsystemForAndroid'
if(-not $registered -or $registered.InstallLocation -ne $package){throw 'Unexpected registered WSA package path'}
if(Get-Process WsaClient,vmmemWSA -ErrorAction SilentlyContinue){throw 'Stop WSA before applying images'}
if((Get-Service WsaService).Status -ne 'Stopped'){throw 'WSA service must be stopped'}
if(Test-Path -LiteralPath $backup){throw 'Backup already exists; refusing to replace it or reapply'}
foreach($name in @('system.vhdx','vendor.vhdx')) {
    $plan=@($report.images | Where-Object image -eq $name)
    $check=@($fsck.images | Where-Object image -eq $name)
    if($plan.Count -ne 1 -or $check.Count -ne 1){throw "Incomplete verification: $name"}
    if($plan[0].result.candidateSha256 -ne $check[0].sha256 -or $check[0].filesystemCheckExitCode -ne 0){throw "Candidate verification mismatch: $name"}
    if((Get-FileHash (Join-Path $package $name)).Hash -ne $plan[0].sourceSha256){throw "Original image changed: $name"}
    if((Get-FileHash (Join-Path $candidate $name)).Hash -ne $check[0].sha256){throw "Candidate image changed: $name"}
    $handle=[IO.File]::Open((Join-Path $package $name),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $handle.Dispose()
}
New-Item -ItemType Directory -Path $backup | Out-Null
foreach($name in @('system.vhdx','vendor.vhdx')) {
    Copy-Item -LiteralPath (Join-Path $package $name) -Destination (Join-Path $backup $name)
    $plan=$report.images | Where-Object image -eq $name
    if((Get-FileHash (Join-Path $backup $name)).Hash -ne $plan.sourceSha256){throw "Backup verification failed: $name"}
}
$changed=@()
try {
    foreach($name in @('system.vhdx','vendor.vhdx')) {
        $changed += $name
        Copy-Item -LiteralPath (Join-Path $candidate $name) -Destination (Join-Path $package $name) -Force
        $plan=$report.images | Where-Object image -eq $name
        if((Get-FileHash (Join-Path $package $name)).Hash -ne $plan.result.candidateSha256){throw "Installed hash mismatch: $name"}
    }
} catch {
    foreach($name in $changed){Copy-Item -LiteralPath (Join-Path $backup $name) -Destination (Join-Path $package $name) -Force}
    throw
}
[ordered]@{appliedUtc=[DateTime]::UtcNow.ToString('o');backupDirectory='tools/wsabuilds/backups/lts8-before-arm64-only';
    modifiedImages=@('system.vhdx','vendor.vhdx');userdataModified=$false;selfTestServicesModified=$false;
    runtimeBootVerified=$false;avbHashtreesRegenerated=$false;avbEnforcementChanged=$false;
    note='Experimental ARM64-only ABI/zygote configuration. Original AVB descriptors are retained; no AVB validity claim.'} |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $root 'artifacts\wsa\arm64-only-applied.json') -Encoding utf8
Write-Output 'Verified ARM64-only candidate applied; original images retained in backup.'
