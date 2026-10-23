# Real integration checks against the configured, already-booted SPARKDROID VM.
[CmdletBinding()]
param([switch]$CheckInput)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Set-Location -LiteralPath $root
$config=Get-Content config/runtime.json -Raw|ConvertFrom-Json
$adb=Join-Path $root $config.adb
$serial="127.0.0.1:$($config.adbPort)"
$out=Join-Path $root 'artifacts/acceptance'
New-Item -ItemType Directory -Force $out|Out-Null
function Android([string[]]$arguments){
    $response=& $adb -s $serial @arguments 2>&1
    if($LASTEXITCODE -ne 0){throw "ADB check failed: $response"}
    ($response|Out-String).Trim()
}
$null=& $adb connect $serial
$boot=Android @('shell','getprop','sys.boot_completed')
if($boot -ne '1'){throw 'Android framework is not booted'}
$abi=Android @('shell','getprop','ro.product.cpu.abi')
if($abi -ne 'arm64-v8a'){throw "Unexpected Android ABI: $abi"}
$sf=Android @('shell','dumpsys','SurfaceFlinger')
$sf|Set-Content (Join-Path $out 'surfaceflinger-current.txt')
$props=Android @('shell','getprop')
$props|Set-Content (Join-Path $out 'android-properties-current.txt')
$network=Android @('shell','ping','-c','1','-W','3','www.example.com')
$network|Set-Content (Join-Path $out 'android-network.txt')
$vlc=Android @('shell','dumpsys','package','org.videolan.vlc')
$vlc|Set-Content (Join-Path $out 'vlc-package.txt')
if($vlc -notmatch 'primaryCpuAbi=arm64-v8a'){throw 'Installed VLC package does not report ARM64 ABI'}
$inputResult='not run'
if($CheckInput){
    $launch=Android @('shell','am','start','-W','-a','android.settings.SETTINGS')
    $launch|Set-Content (Join-Path $out 'settings-input-before.txt')
    $null=Android @('shell','input','keyevent','KEYCODE_HOME')
    Start-Sleep -Milliseconds 500
    $activities=Android @('shell','dumpsys','activity','activities')
    $activities|Set-Content (Join-Path $out 'settings-input-after.txt')
    $resumed=@($activities -split "`n"|Where-Object {$_ -match 'topResumedActivity|mResumedActivity'}) -join "`n"
    if(-not $resumed){throw 'Activity output did not establish the current resumed activity; input outcome is undetermined'}
    if($resumed -match 'com.android.settings'){throw 'HOME input did not leave Settings'}
    $inputResult='ADB HOME key injection left Settings. Physical Windows touch, mouse and keyboard were not exercised by this check.'
}
$report=[ordered]@{
    measuredUtc=[DateTime]::UtcNow.ToString('o')
    androidBootCompleted=$true;androidVersion=(Android @('shell','getprop','ro.build.version.release'))
    androidAbi=$abi;nativeVlcPackageInstalled=$true
    androidDnsAndIcmpConnectivity=$true
    renderer=(@($sf -split "`n"|Where-Object {$_ -match '^GLES:'}) -join '')
    input=$inputResult
    graphicsAcceptance='artifacts/acceptance/graphics.json'
    notes='No physical audio, FPS, energy, attestation or broad application compatibility is inferred from these checks.'
}
$report|ConvertTo-Json -Depth 5|Tee-Object -FilePath (Join-Path $out 'runtime-checks.json')
