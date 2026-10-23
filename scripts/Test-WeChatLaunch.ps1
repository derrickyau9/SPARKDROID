[CmdletBinding()]
param([switch]$SkipInstall, [ValidateRange(1, 60)][int]$WaitSeconds = 5)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$config = Get-Content -LiteralPath (Join-Path $projectRoot 'config/runtime.json') -Raw | ConvertFrom-Json
$lock = Get-Content -LiteralPath (Join-Path $projectRoot 'artifacts/apks/wechat.lock.json') -Raw | ConvertFrom-Json
$apk = Join-Path $projectRoot 'artifacts/apks/WeChat-arm64.apk'
$adb = Join-Path $projectRoot $config.adb
$serial = "127.0.0.1:$($config.adbPort)"
$package = 'com.tencent.mm'
if ($lock.package -ne $package) { throw 'The pinned artifact is not the expected WeChat package.' }
if ((Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant() -ne $lock.sha256) { throw 'The WeChat APK does not match the pinned official-source SHA256.' }
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$directory = Join-Path $projectRoot "artifacts/compatibility/wechat-$stamp"
$null = New-Item -ItemType Directory -Force -Path $directory
$commands = [Collections.Generic.List[object]]::new()
function Adb-Command([string]$Name, [string[]]$Arguments, [int]$TimeoutMilliseconds = 15000) {
    $start = [Diagnostics.ProcessStartInfo]::new($adb)
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    foreach ($argument in (@('-s', $serial) + $Arguments)) { $start.ArgumentList.Add($argument) }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutMilliseconds)
        if ($timedOut) { $process.Kill(); $null = $process.WaitForExit(2000) }
        $null = $stdout.Wait(2000); $null = $stderr.Wait(2000)
        $result = [pscustomobject]@{ name = $Name; arguments = $Arguments; exitCode = if ($process.HasExited) { $process.ExitCode } else { $null }; timedOut = $timedOut; elapsedMilliseconds = [math]::Round($watch.Elapsed.TotalMilliseconds, 3); stdout = if ($stdout.IsCompletedSuccessfully) { $stdout.Result } else { '[capture incomplete]' }; stderr = if ($stderr.IsCompletedSuccessfully) { $stderr.Result } else { '[capture incomplete]' } }
        $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $directory "$Name.json") -Encoding utf8
        $commands.Add($result)
        return $result
    } finally { $process.Dispose() }
}
$boot = Adb-Command 'android-boot-completed' @('shell', 'getprop', 'sys.boot_completed') 5000
if ($boot.exitCode -ne 0 -or $boot.stdout.Trim() -ne '1') { throw "Android is not ready. No installation attempted. See $directory" }
$install = if (-not $SkipInstall) { Adb-Command 'install' @('install', '-r', $apk) 180000 } else { $null }
if ($install -and ($install.exitCode -ne 0 -or $install.stdout -notmatch '(?m)^Success\s*$')) { throw "WeChat installation failed. See $directory" }
$null = Adb-Command 'package-details' @('shell', 'dumpsys', 'package', $package)
$resolve = Adb-Command 'resolve-activity' @('shell', 'cmd', 'package', 'resolve-activity', '--brief', $package)
$component = @($resolve.stdout -split '\r?\n' | Where-Object { $_ -match ('\A' + [regex]::Escape($package) + '/[A-Za-z0-9_.]+\z') }) | Select-Object -Last 1
if ($resolve.exitCode -ne 0 -or -not $component) { throw "No validated WeChat launcher activity resolved. See $directory" }
$null = Adb-Command 'force-stop-before' @('shell', 'am', 'force-stop', $package)
$launch = Adb-Command 'start-activity' @('shell', 'am', 'start', '-W', '-n', $component) 45000
Start-Sleep -Seconds $WaitSeconds
$pidResult = Adb-Command 'process-id' @('shell', 'pidof', $package)
$null = Adb-Command 'activity-state' @('shell', 'dumpsys', 'activity', 'activities')
$null = Adb-Command 'window-state' @('shell', 'dumpsys', 'window', 'windows')
$null = Adb-Command 'recent-logcat' @('logcat', '-d', '-t', '600')
$guestPrefix = "/sdcard/sparkdroid-wechat-$stamp"
$screenshot = Adb-Command 'screenshot-capture' @('shell', 'screencap', '-p', "$guestPrefix.png")
if ($screenshot.exitCode -eq 0) { $null = Adb-Command 'screenshot-pull' @('pull', "$guestPrefix.png", (Join-Path $directory 'screen.png')) }
$ui = Adb-Command 'ui-dump' @('shell', 'uiautomator', 'dump', "$guestPrefix.xml") 30000
if ($ui.exitCode -eq 0) { $null = Adb-Command 'ui-pull' @('pull', "$guestPrefix.xml", (Join-Path $directory 'ui.xml')) }
$null = Adb-Command 'remove-own-guest-captures' @('shell', 'rm', '-f', "$guestPrefix.png", "$guestPrefix.xml")
$launchValues = @{}
foreach ($line in ($launch.stdout -split '\r?\n')) { if ($line -match '^(Status|LaunchState|TotalTime|WaitTime):\s*(.*)$') { $launchValues[$Matches[1]] = $Matches[2].Trim() } }
$report = [ordered]@{
    schemaVersion = 1; measuredUtc = [DateTime]::UtcNow.ToString('o'); package = $package; versionName = $lock.versionName; versionCode = $lock.versionCode; apkSha256 = $lock.sha256
    backend = $config.backend; configuredGraphics = $config.graphics; installationPerformed = -not $SkipInstall; installationAcceptedByPackageManager = if ($install) { $install.exitCode -eq 0 -and $install.stdout -match '(?m)^Success\s*$' } else { $null }
    component = $component; launchExitCode = $launch.exitCode; launchStatus = $launchValues.Status; launchState = $launchValues.LaunchState; totalTimeMillisecondsRaw = $launchValues.TotalTime; waitTimeMillisecondsRaw = $launchValues.WaitTime; adbWallMilliseconds = $launch.elapsedMilliseconds
    mainProcessAliveAfterWait = $pidResult.exitCode -eq 0 -and $pidResult.stdout.Trim() -match '\A[0-9 ]+\z'; processIdsRaw = $pidResult.stdout.Trim(); uiReview = 'Pending manual review of screen.png and ui.xml; process survival alone is not welcome-screen or functional compatibility evidence.'
    noInputEventsSent = $true; accountLoginAttempted = $false; accountRegistrationAttempted = $false; legalTermsAcceptedByTest = $false; permissionsGrantedByTest = $false
    limitations = 'Initial launch only. No account features, messages, payments, calls, push delivery, camera, microphone, location, integrity or vendor framework compatibility tested. A successful install is not independent signer-identity pinning.'
    commands = @($commands | Select-Object name, arguments, exitCode, timedOut, elapsedMilliseconds)
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $directory 'result.json') -Encoding utf8
Write-Output "WeChat launch observation written to: $directory"
$report | ConvertTo-Json -Depth 8
