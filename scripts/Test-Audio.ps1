[CmdletBinding()]
param(
    [string]$Serial,
    [switch]$PrepareOnly,
    [switch]$RebuildProbe
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$config = Get-Content -LiteralPath (Join-Path $projectRoot 'config/runtime.json') -Raw | ConvertFrom-Json
if (-not $Serial) { $Serial = "127.0.0.1:$($config.adbPort)" }
$artifactDir = Join-Path $projectRoot 'artifacts/acceptance'
$sourceDir = Join-Path $projectRoot 'src/SparkDroid.AudioProbe'
$dotnet = Join-Path $projectRoot 'tools/dotnet/dotnet.exe'
$python = Join-Path $projectRoot 'tools/python/python.exe'
$adb = Join-Path $projectRoot $config.adb
$scrcpy = Join-Path $projectRoot $config.scrcpy
$probe = Join-Path $sourceDir 'publish/SparkDroid.AudioProbe.exe'
$tone = Join-Path $artifactDir 'audio-test-tone.wav'
$recording = Join-Path $artifactDir 'audio-windows-output-loopback.wav'
$captureReport = Join-Path $artifactDir 'audio-loopback-analysis.json'
$readyFile = Join-Path $artifactDir 'audio-capture-ready.txt'
$finalReport = Join-Path $artifactDir 'audio-acceptance.json'
New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null

if($RebuildProbe -or -not(Test-Path -LiteralPath $probe)) {
    if(-not(Test-Path -LiteralPath $dotnet)){throw 'Rebuilding the audio helper requires the local .NET SDK. Run Setup-Tools.ps1 -IncludeBuildSdk.'}
    & $dotnet publish (Join-Path $sourceDir 'SparkDroid.AudioProbe.csproj') -c Release -r win-arm64 --self-contained true -o (Join-Path $sourceDir 'publish') 2>&1 |
        Tee-Object -FilePath (Join-Path $artifactDir 'audio-build.log')
    if ($LASTEXITCODE -ne 0) { throw 'Audio probe compilation failed.' }
}
& $python (Join-Path $sourceDir 'generate-tone.py') $tone
if ($LASTEXITCODE -ne 0) { throw 'Known audio test signal generation failed.' }
if ($PrepareOnly) {
    Write-Output 'Audio helper compiled and signal prepared. No recording, guest change or playback occurred.'
    return
}

function Invoke-TestAdb {
    param([string[]]$AdbArguments, [switch]$AllowFailure)
    $text = & $adb -s $Serial @AdbArguments 2>&1 | Out-String
    $code = $LASTEXITCODE
    Add-Content -LiteralPath (Join-Path $artifactDir 'audio-adb.log') -Value ($AdbArguments -join ' ')
    Add-Content -LiteralPath (Join-Path $artifactDir 'audio-adb.log') -Value $text
    if ($code -ne 0 -and -not $AllowFailure) { throw "ADB audio test command failed: $text" }
    return $text.Trim()
}
function Start-TestProcess {
    param([string]$Executable, [string[]]$ProcessArguments)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.WorkingDirectory = $projectRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $ProcessArguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    if (-not $process.Start()) { throw "Could not start $Executable" }
    return [pscustomobject]@{
        Process = $process
        Stdout = $process.StandardOutput.ReadToEndAsync()
        Stderr = $process.StandardError.ReadToEndAsync()
    }
}
function Save-TestProcessLogs {
    param($Started, [string]$Prefix)
    if ($null -eq $Started -or -not $Started.Process.HasExited) { return }
    $Started.Stdout.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $artifactDir "$Prefix.stdout.log") -Encoding utf8NoBOM
    $Started.Stderr.GetAwaiter().GetResult() | Set-Content -LiteralPath (Join-Path $artifactDir "$Prefix.stderr.log") -Encoding utf8NoBOM
}

$capture = $null
$mirror = $null
$startedUtc = [DateTime]::UtcNow.ToString('o')
$passed = $false
$errorMessage = $null
try {
    if ((Invoke-TestAdb -AdbArguments @('shell', 'getprop', 'sys.boot_completed')) -ne '1') { throw 'Android framework is not booted.' }
    Invoke-TestAdb -AdbArguments @('push', $tone, '/sdcard/Download/sparkdroid-audio-test.wav') | Write-Output
    Invoke-TestAdb -AdbArguments @('shell', 'pm', 'grant', 'org.videolan.vlc', 'android.permission.READ_MEDIA_AUDIO') -AllowFailure | Write-Verbose
    # Complete VLC's optional introductory tour before the bounded recording.
    # Only an actual SKIP node belonging to VLC is tapped; coordinates are read
    # from this guest's current UI hierarchy rather than assumed screen sizes.
    Invoke-TestAdb -AdbArguments @('shell', 'am', 'start', '-W', '-n', 'org.videolan.vlc/org.videolan.vlc.StartActivity') | Write-Verbose
    Invoke-TestAdb -AdbArguments @('shell', 'uiautomator', 'dump', '/data/local/tmp/sparkdroid-audio-ui.xml') -AllowFailure | Write-Verbose
    $uiText = Invoke-TestAdb -AdbArguments @('shell', 'cat', '/data/local/tmp/sparkdroid-audio-ui.xml') -AllowFailure
    if ($uiText.StartsWith('<?xml')) {
        $ui = [xml]$uiText
        foreach ($node in $ui.SelectNodes('//node')) {
            if ($node.GetAttribute('package') -eq 'org.videolan.vlc' -and $node.GetAttribute('text') -match '^(?i:skip)$') {
                if ($node.GetAttribute('bounds') -match '^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$') {
                    $tapX = [int]( ([int]$Matches[1] + [int]$Matches[3]) / 2 )
                    $tapY = [int]( ([int]$Matches[2] + [int]$Matches[4]) / 2 )
                    Invoke-TestAdb -AdbArguments @('shell', 'input', 'tap', "$tapX", "$tapY") | Write-Verbose
                }
                break
            }
        }
    }
    Invoke-TestAdb -AdbArguments @('shell', 'am', 'force-stop', 'org.videolan.vlc') | Write-Verbose
    $mirror = Start-TestProcess -Executable $scrcpy -ProcessArguments @('--serial', $Serial, '--no-video', '--no-control', '--no-window', '--audio-source=output', '--audio-codec=raw', '--require-audio', '--time-limit=14')
    Start-Sleep -Milliseconds 1000
    if ($mirror.Process.HasExited) { throw 'Scrcpy audio output transport exited before the signal test.' }
    if (Test-Path -LiteralPath $readyFile) { Remove-Item -LiteralPath $readyFile }
    $capture = Start-TestProcess -Executable $probe -ProcessArguments @('capture', '--output', $recording, '--report', $captureReport, '--ready-file', $readyFile, '--seconds', '10')
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath $readyFile)) {
        if ($capture.Process.HasExited -or [DateTime]::UtcNow -gt $readyDeadline) { throw 'Windows playback loopback did not become ready.' }
        Start-Sleep -Milliseconds 100
    }
    Invoke-TestAdb -AdbArguments @('shell', 'am', 'start', '-W', '-a', 'android.intent.action.VIEW', '-d', 'file:///sdcard/Download/sparkdroid-audio-test.wav', '-t', 'audio/wav', '-p', 'org.videolan.vlc', '--grant-read-uri-permission') | Write-Output
    if (-not $capture.Process.WaitForExit(15000)) { throw 'Bounded Windows output capture failed to finish.' }
    Save-TestProcessLogs $capture 'audio-probe'
    $analysis = Get-Content -LiteralPath $captureReport -Raw | ConvertFrom-Json
    $passed = $capture.Process.ExitCode -eq 0 -and $analysis.Passed
    if (-not $passed) { $errorMessage = 'Known alternating 440/880 Hz Android signal was not established at the Windows playback endpoint.' }
}
catch {
    $errorMessage = $_.Exception.Message
}
finally {
    Invoke-TestAdb -AdbArguments @('shell', 'am', 'force-stop', 'org.videolan.vlc') -AllowFailure | Write-Verbose
    foreach ($started in @($capture, $mirror)) {
        if ($null -ne $started -and -not $started.Process.HasExited) {
            if (-not $started.Process.WaitForExit(4000)) { $started.Process.Kill() ; $started.Process.WaitForExit() }
        }
    }
    Save-TestProcessLogs $capture 'audio-probe'
    Save-TestProcessLogs $mirror 'audio-scrcpy'
    $report = [ordered]@{
        schemaVersion = 1
        passed = [bool]$passed
        startedUtc = $startedUtc
        completedUtc = [DateTime]::UtcNow.ToString('o')
        serial = $Serial
        source = 'Generated 18-second 440/880 Hz alternating PCM WAV played by Android VLC'
        route = 'VLC -> Android remote_submix -> scrcpy raw audio -> Windows default playback endpoint -> WASAPI output loopback'
        microphoneOpened = $false
        captureDurationSeconds = 10
        physicalAudibilityTested = $false
        analysis = 'artifacts/acceptance/audio-loopback-analysis.json'
        recording = 'artifacts/acceptance/audio-windows-output-loopback.wav'
        error = $errorMessage
    }
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $finalReport -Encoding utf8NoBOM
}
Get-Content -LiteralPath $finalReport -Raw | Write-Output
if (-not $passed) { throw $errorMessage }
