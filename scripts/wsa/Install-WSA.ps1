#requires -Version 5.1
#requires -RunAsAdministrator
# Minimal registration of the inspected ARM64 package. No global execution-policy
# change, removal of existing WSA installations, automatic reboot or app login.
[CmdletBinding()]
param([switch]$EnableDevelopmentRegistration)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$reportPath=Join-Path $root 'artifacts/wsa/installation.json'
$null=New-Item -ItemType Directory -Force -Path (Split-Path $reportPath -Parent)
try {
    $packageDir=Join-Path $root 'tools/wsabuilds/LTS8-arm64/WSA_2407.40000.4.0_arm64'
    $manifestPath=Join-Path $packageDir 'AppxManifest.xml'
    [xml]$manifest=Get-Content -LiteralPath $manifestPath
    if($manifest.Package.Identity.ProcessorArchitecture -ne 'arm64'){throw 'Expected ARM64 WSA package.'}
    $name=$manifest.Package.Identity.Name
    if($name -ne 'MicrosoftCorporationII.WindowsSubsystemForAndroid'){throw 'Unexpected package identity.'}
    $existing=Get-AppxPackage -Name $name
    if($existing -and $existing.InstallLocation -ne $packageDir){throw 'A different WSA installation exists. Preserving it; explicit migration is required.'}
    foreach($dependency in $manifest.Package.Dependencies.PackageDependency){
        $installed=Get-AppxPackage -Name $dependency.Name|Where-Object {$_.Architecture -eq 'Arm64' -and [version]$_.Version -ge [version]$dependency.MinVersion}
        if(-not $installed){
            $path=Join-Path $packageDir "$($dependency.Name)_arm64.appx"
            if(-not(Test-Path -LiteralPath $path)){throw "Missing dependency package: $path"}
            Add-AppxPackage -Path $path -ErrorAction Stop
        }
    }
    $policyKey='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'
    $policyName='AllowDevelopmentWithoutDevLicense'
    $previous=Get-ItemProperty -LiteralPath $policyKey -Name $policyName -ErrorAction SilentlyContinue
    $hadValue=$null -ne $previous
    $oldValue=if($hadValue){$previous.$policyName}else{$null}
    $changed=$EnableDevelopmentRegistration -and $oldValue -ne 1
    try {
        if($changed){
            [ordered]@{key=$policyKey;name=$policyName;hadValue=$hadValue;oldValue=$oldValue;temporary=$true}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $root 'artifacts/wsa/development-registration-policy.json') -Encoding utf8
            $null=New-Item -Path $policyKey -Force
            $null=New-ItemProperty -LiteralPath $policyKey -Name $policyName -Value 1 -PropertyType DWord -Force
        }
        Add-AppxPackage -Register $manifestPath -ErrorAction Stop
    }finally{
        if($changed){
            if($hadValue){$null=Set-ItemProperty -LiteralPath $policyKey -Name $policyName -Value $oldValue}
            else{Remove-ItemProperty -LiteralPath $policyKey -Name $policyName}
        }
    }
    $installed=Get-AppxPackage -Name $name
    if(-not $installed){throw 'WSA registration did not return an installed package.'}
    [ordered]@{success=$true;timestampUtc=[datetime]::UtcNow.ToString('o');name=$installed.Name;version=[string]$installed.Version;architecture=[string]$installed.Architecture;installLocation=$installed.InstallLocation;packageFamilyName=$installed.PackageFamilyName;runtimeBootVerified=$false}|ConvertTo-Json|Set-Content -LiteralPath $reportPath -Encoding utf8
}catch{
    [ordered]@{success=$false;timestampUtc=[datetime]::UtcNow.ToString('o');error=$_.Exception.Message;details=($_|Out-String)}|ConvertTo-Json|Set-Content -LiteralPath $reportPath -Encoding utf8
    exit 1
}
