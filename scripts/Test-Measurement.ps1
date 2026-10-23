[CmdletBinding()]
param([Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference = 'Stop'
$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
$directory = Split-Path -Parent ([IO.Path]::GetFullPath($ReportPath))
if ($report.schemaVersion -ne 1 -or $report.actualObservationSeconds -le 0) { throw 'Invalid report schema or observation duration.' }
$samples = @($report.samples)
if ($samples.Count -eq 0) { throw 'No real observation samples were recorded.' }
$csv = @(Import-Csv -LiteralPath (Join-Path $directory 'host-samples.csv'))
if ($samples.Count -ne $csv.Count) { throw 'CSV/JSON host sample counts differ.' }
if ($null -ne $report.summary.systemPowerWatts) { throw 'An uncalibrated whole-system power value was reported.' }
$elapsedSum = ($samples | Measure-Object intervalSeconds -Sum).Sum
if ([math]::Abs($elapsedSum - $report.actualObservationSeconds) -gt 0.01) { throw 'Per-sample intervals do not reproduce the observation duration.' }
foreach ($sample in $samples) {
    if ($sample.hostCpuPercent -lt 0 -or $sample.hostCpuPercent -gt 100) { throw 'Host CPU percentage is outside its valid range.' }
    if ($null -ne $sample.systemPowerWatts) { throw 'Host sample incorrectly contains whole-system power.' }
    if ($null -ne $sample.vmCpuPercentOneCore) {
        $expected = $sample.vmCpuPercentOneCore / $report.host.logicalProcessors
        if ([math]::Abs($expected - $sample.vmCpuPercentWholeMachine) -gt 0.0002) { throw 'VM CPU normalization is inconsistent.' }
    }
}
foreach ($battery in @($report.batterySamples)) {
    if (($battery.powerOnline -or -not $battery.discharging) -and $null -ne $battery.dischargeRateRaw) { throw 'Battery discharge rate must be null outside active battery discharge.' }
    if ($null -ne $battery.systemPowerWatts) { throw 'Unverified battery units were converted to whole-system Watts.' }
}
foreach ($command in @($report.diagnosticCommands)) {
    if (-not (Test-Path -LiteralPath (Join-Path $directory $command.rawFile))) { throw "Missing raw diagnostic evidence: $($command.rawFile)" }
}
if ($report.mode -eq 'Baseline' -and -not $report.validStoppedRuntimeBaseline) { throw 'The report is not a verified stopped-runtime baseline.' }
if ($report.coldStartPackage -and $report.runtime.androidBootCompletedBeforeObservation -and @($report.coldStartTrials).Count -gt 0) {
    if (@($report.coldStartTrials).Count -ne 3) { throw 'An attempted launch series does not contain three trials.' }
    foreach ($trial in $report.coldStartTrials) {
        if ($trial.success -and ($trial.startExitCode -ne 0 -or $trial.status -ne 'ok')) { throw 'A failed Android launch was marked successful.' }
    }
}
Write-Output "Measurement evidence checks passed: $ReportPath ($($samples.Count) real samples)."
