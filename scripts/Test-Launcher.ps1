[CmdletBinding()]
param([switch]$SkipRuntimeProbe)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$executable = Join-Path $projectRoot 'artifacts/launcher/win-arm64/SparkDroid.exe'
if (-not (Test-Path -LiteralPath $executable)) { throw 'Build the launcher first with scripts/Build-Launcher.ps1.' }
function Invoke-Launcher([string[]]$Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new($executable)
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Launcher test timed out.' }
        $outputText = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Launcher test exit $($process.ExitCode): $errorText $outputText" }
        return $outputText | ConvertFrom-Json
    } finally { $process.Dispose() }
}
$smoke = Invoke-Launcher @('--smoke-test')
if ($smoke.architecture -ne 'Arm64' -or -not $smoke.windows -or -not $smoke.uiConstructed) {
    throw 'Launcher did not pass native ARM64 WinForms construction.'
}
$report = [ordered]@{ measuredUtc = [DateTime]::UtcNow.ToString('o'); launcherSmoke = $smoke; runtimeProbe = $null; note = 'Read-only launcher/control integration tests. No VM or Android app is started, stopped, installed or launched.' }
if (-not $SkipRuntimeProbe) {
    $probe = Invoke-Launcher @('--probe-runtime', '--project', $projectRoot)
    if ($null -eq $probe.vmRunning -or $null -eq $probe.androidBootCompleted) { throw 'Runtime status did not include readiness fields.' }
    $report.runtimeProbe = $probe
}
$path = Join-Path $projectRoot 'artifacts/launcher/host-integration-test.json'
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding utf8
Write-Output "Launcher tests passed. Evidence: $path"
$report | ConvertTo-Json -Depth 12
