[CmdletBinding()]
param(
    [string]$Configuration = 'Release',
    [string]$OutputDirectory,
    [switch]$SkipSmokeTest
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $projectRoot 'src/SparkDroid.Launcher/SparkDroid.Launcher.csproj'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot 'artifacts/launcher/win-arm64' }
$bundledDotnet = Join-Path $projectRoot 'tools/dotnet/dotnet.exe'
if (Test-Path -LiteralPath $bundledDotnet) {
    $dotnet = $bundledDotnet
} else {
    $dotnet = (Get-Command dotnet -ErrorAction Stop).Source
}
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
& $dotnet publish $project --configuration $Configuration --runtime win-arm64 --self-contained true --output $OutputDirectory -p:PublishSingleFile=false -p:PublishTrimmed=false
if ($LASTEXITCODE -ne 0) { throw "Launcher publish failed with exit code $LASTEXITCODE" }
$executable = Join-Path $OutputDirectory 'SparkDroid.exe'
if (-not (Test-Path -LiteralPath $executable)) { throw 'Launcher executable was not generated.' }
if (-not $SkipSmokeTest) {
    if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64) {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new($executable)
        $startInfo.ArgumentList.Add('--smoke-test')
        $startInfo.ArgumentList.Add('--screenshot')
        $startInfo.ArgumentList.Add((Join-Path $OutputDirectory 'launcher-preview.png'))
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.CreateNoWindow = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
        $process.Dispose()
        if ($exitCode -ne 0) { throw "Launcher smoke test failed ($exitCode): $stderr" }
        if ([string]::IsNullOrWhiteSpace($stdout)) { throw 'Launcher smoke test returned no report.' }
        $report = $stdout | ConvertFrom-Json
        if ($report.architecture -ne 'Arm64') { throw 'Launcher did not execute natively as ARM64.' }
        $stdout | Set-Content -LiteralPath (Join-Path $OutputDirectory 'smoke-test.json') -Encoding utf8
        Write-Output $stdout.Trim()
    } else {
        Write-Warning 'ARM64 launcher compiled; native process smoke test requires Windows ARM64.'
    }
}
Get-FileHash -LiteralPath $executable -Algorithm SHA256 | Format-List
Write-Output "Launcher published to: $OutputDirectory"
