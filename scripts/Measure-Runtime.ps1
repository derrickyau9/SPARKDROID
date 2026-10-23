[CmdletBinding()]
param(
    [ValidateRange(5, 86400)][int]$Seconds = 30,
    [ValidateRange(1, 60)][int]$IntervalSeconds = 2,
    [ValidateRange(0, 300)][int]$WarmupSeconds = 3,
    [ValidateSet('Runtime', 'Baseline')][string]$Mode = 'Runtime',
    [string]$Label = 'unspecified-observation',
    [string]$Package
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$config = Get-Content -LiteralPath (Join-Path $projectRoot 'config/runtime.json') -Raw | ConvertFrom-Json
$statePath = Join-Path $projectRoot 'state/runtime.json'
$qemuPath = [IO.Path]::GetFullPath((Join-Path $projectRoot $config.qemu))
$adbPath = Join-Path $projectRoot $config.adb
$adbSerial = "127.0.0.1:$($config.adbPort)"
if ($Package -and $Package -notmatch '\A[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+\z') {
    throw 'Provide a valid Android package identifier for the optional cold-start trials.'
}
if ($Mode -eq 'Baseline' -and $Package) { throw 'Baseline does not launch Android applications; omit -Package.' }

function Find-ManagedVm {
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $process = Get-Process -Id $saved.pid -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    if ($process.Path -ne $qemuPath -or $process.StartTime.ToUniversalTime().Ticks -ne $saved.startTicks) {
        throw 'Runtime PID identity does not match its saved executable and creation time. No unrelated process will be measured as the VM.'
    }
    return $process
}
$vm = Find-ManagedVm
if ($Mode -eq 'Runtime' -and -not $vm) { throw 'Runtime mode requires the managed VM to be running. Use -Mode Baseline only when it is stopped.' }
if ($Mode -eq 'Baseline') {
    $sameBinary = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($qemuPath)) -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $qemuPath })
    if ($vm -or $sameBinary.Count -gt 0) { throw 'Refusing to label a measurement Baseline while the configured QEMU executable is running. Stop the runtime first.' }
}
$vmId = if ($vm) { $vm.Id } else { $null }
$vmStartTicks = if ($vm) { $vm.StartTime.ToUniversalTime().Ticks } else { $null }
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
$outputDirectory = Join-Path $projectRoot "artifacts/benchmarks/$stamp-$($Mode.ToLowerInvariant())-$([Guid]::NewGuid().ToString('N').Substring(0,6))"
$null = New-Item -ItemType Directory -Path $outputDirectory -Force
$diagnosticDirectory = Join-Path $outputDirectory 'raw'
$null = New-Item -ItemType Directory -Path $diagnosticDirectory -Force
$diagnosticCommands = [Collections.Generic.List[object]]::new()
$notes = [Collections.Generic.List[string]]::new()

function Invoke-Captured([string]$Executable, [string[]]$Arguments, [int]$TimeoutMilliseconds = 10000) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = [Diagnostics.ProcessStartInfo]::new($Executable)
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.WorkingDirectory = $projectRoot
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $process.StartInfo.ArgumentList.Add($argument) }
    try {
        if (-not $process.Start()) { throw "Could not start $Executable" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutMilliseconds)
        if ($timedOut) { try { $process.Kill() } catch { }; $null = $process.WaitForExit(2000) }
        $null = $stdoutTask.Wait(2000)
        $null = $stderrTask.Wait(2000)
        return [pscustomobject]@{
            exitCode = if ($process.HasExited) { $process.ExitCode } else { $null }
            timedOut = $timedOut
            stdout = if ($stdoutTask.IsCompletedSuccessfully) { $stdoutTask.Result } else { '[stdout capture did not close]' }
            stderr = if ($stderrTask.IsCompletedSuccessfully) { $stderrTask.Result } else { '[stderr capture did not close]' }
            elapsedMilliseconds = [math]::Round($watch.Elapsed.TotalMilliseconds, 3)
        }
    } catch {
        return [pscustomobject]@{ exitCode = $null; timedOut = $false; stdout = ''; stderr = $_.Exception.Message; elapsedMilliseconds = [math]::Round($watch.Elapsed.TotalMilliseconds, 3) }
    } finally { $process.Dispose() }
}

function Save-Diagnostic([string]$Name, [string]$Executable, [string[]]$Arguments, [int]$TimeoutMilliseconds = 10000) {
    $result = Invoke-Captured $Executable $Arguments $TimeoutMilliseconds
    $text = "COMMAND: $Executable`nARGUMENTS: $($Arguments | ConvertTo-Json -Compress)`nEXIT: $($result.exitCode)`nTIMED OUT: $($result.timedOut)`nELAPSED MS: $($result.elapsedMilliseconds)`n`nSTDOUT`n$($result.stdout)`nSTDERR`n$($result.stderr)"
    $text | Set-Content -LiteralPath (Join-Path $diagnosticDirectory "$Name.txt") -Encoding utf8
    $diagnosticCommands.Add([pscustomobject]@{ name = $Name; executable = $Executable; arguments = $Arguments; exitCode = $result.exitCode; timedOut = $result.timedOut; elapsedMilliseconds = $result.elapsedMilliseconds; rawFile = "raw/$Name.txt" })
    return $result
}

function Adb-Diagnostic([string]$Name, [string[]]$Arguments, [int]$TimeoutMilliseconds = 10000) {
    return Save-Diagnostic $Name $adbPath (@('-s', $adbSerial) + $Arguments) $TimeoutMilliseconds
}

$androidBootCompleted = $false
$androidProperties = [ordered]@{}
$rendererEvidence = @()
$coldStartTrials = [Collections.Generic.List[object]]::new()
if ($Mode -eq 'Runtime') {
    Write-Output "Collecting bounded Android diagnostics. Artifact directory: $outputDirectory"
    $null = Save-Diagnostic 'adb-connect' $adbPath @('connect', $adbSerial) 5000
    $boot = Adb-Diagnostic 'android-boot-completed' @('shell', 'getprop', 'sys.boot_completed') 5000
    $androidBootCompleted = $boot.exitCode -eq 0 -and $boot.stdout.Trim() -eq '1'
    if ($androidBootCompleted) {
        $properties = Adb-Diagnostic 'android-getprop' @('shell', 'getprop')
        foreach ($line in ($properties.stdout -split '\r?\n')) {
            if ($line -match '^\[([^\]]+)\]: \[(.*)\]$') { $androidProperties[$Matches[1]] = $Matches[2] }
        }
        $null = Adb-Diagnostic 'android-uname' @('shell', 'uname', '-a')
        $null = Adb-Diagnostic 'android-meminfo' @('shell', 'dumpsys', 'meminfo') 15000
        $null = Adb-Diagnostic 'android-cpuinfo' @('shell', 'dumpsys', 'cpuinfo') 15000
        $surface = Adb-Diagnostic 'android-surfaceflinger' @('shell', 'dumpsys', 'SurfaceFlinger') 15000
        $rendererEvidence = @($surface.stdout -split '\r?\n' | Where-Object { $_ -match 'GLES:|EGL implementation|RenderEngine|SwiftShader|llvmpipe|Vulkan' })
        if ($Package) { $null = Adb-Diagnostic 'app-gfxinfo-before' @('shell', 'dumpsys', 'gfxinfo', $Package, 'framestats') 15000 }
    } else {
        $notes.Add('Android did not report sys.boot_completed=1 before the observation. This is a VM measurement, not an Android idle or application performance result.')
    }
    $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    $key = Join-Path $projectRoot 'state/ssh_key'
    if ($ssh -and (Test-Path -LiteralPath $key)) {
        $knownHostsOption = 'UserKnownHostsFile="'+((Join-Path $projectRoot 'state/known_hosts') -replace '\\','/')+'"'
        $sshArguments = @('-p', "$($config.sshPort)", '-i', $key, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-o', 'StrictHostKeyChecking=accept-new', '-o', $knownHostsOption, 'spark@127.0.0.1', 'uname -a; cat /proc/meminfo; cat /proc/loadavg')
        $null = Save-Diagnostic 'linux-host-snapshot' $ssh.Source $sshArguments 10000
    }
}

if (-not ('SparkDroidMeasurement.NativeCounters' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace SparkDroidMeasurement {
    public sealed class HostSnapshot {
        public ulong Idle, Kernel, User, TotalPhysicalBytes, AvailablePhysicalBytes;
    }
    public static class NativeCounters {
        [StructLayout(LayoutKind.Sequential)]
        private struct MemoryStatus {
            public uint Length, MemoryLoad;
            public ulong TotalPhys, AvailPhys, TotalPageFile, AvailPageFile, TotalVirtual, AvailVirtual, AvailExtendedVirtual;
        }
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GetSystemTimes(out ulong idle, out ulong kernel, out ulong user);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
        public static HostSnapshot Read() {
            var snapshot = new HostSnapshot();
            if (!GetSystemTimes(out snapshot.Idle, out snapshot.Kernel, out snapshot.User)) throw new Win32Exception(Marshal.GetLastWin32Error());
            var memory = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
            if (!GlobalMemoryStatusEx(ref memory)) throw new Win32Exception(Marshal.GetLastWin32Error());
            snapshot.TotalPhysicalBytes = memory.TotalPhys; snapshot.AvailablePhysicalBytes = memory.AvailPhys;
            return snapshot;
        }
    }
}
'@
}

$computer = Get-CimInstance -ClassName Win32_ComputerSystem
$logicalProcessors = [int]$computer.NumberOfLogicalProcessors
$nvidiaCommand = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
$nvidiaPath = if ($nvidiaCommand) { $nvidiaCommand.Source } else { $null }
if (-not $nvidiaPath) { $notes.Add('nvidia-smi.exe was not found; GPU sensor fields are unavailable.') }

function Read-VmSnapshot {
    if ($null -eq $vmId) { return $null }
    $process = Get-Process -Id $vmId -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    if ($process.Path -ne $qemuPath -or $process.StartTime.ToUniversalTime().Ticks -ne $vmStartTicks) {
        throw 'VM process identity changed during sampling; refusing to substitute another process.'
    }
    return [pscustomobject]@{ cpuSeconds = $process.TotalProcessorTime.TotalSeconds; workingSetBytes = $process.WorkingSet64; privateBytes = $process.PrivateMemorySize64 }
}

function Number-OrNull([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $parsed = 0.0
    if ([double]::TryParse($Value.Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { return $parsed }
    return $null
}

function Statistics($Values) {
    $items = @($Values | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) { return $null }
    $measure = $items | Measure-Object -Average -Minimum -Maximum
    return [ordered]@{ count = $items.Count; mean = [math]::Round($measure.Average, 4); minimum = $measure.Minimum; maximum = $measure.Maximum }
}

$samples = [Collections.Generic.List[object]]::new()
$gpuSamples = [Collections.Generic.List[object]]::new()
$batterySamples = [Collections.Generic.List[object]]::new()
if ($WarmupSeconds -gt 0) { Write-Output "Settling for $WarmupSeconds seconds before sampling."; Start-Sleep -Seconds $WarmupSeconds }
$startUtc = [DateTime]::UtcNow
$watch = [Diagnostics.Stopwatch]::StartNew()
$previousHost = [SparkDroidMeasurement.NativeCounters]::Read()
$previousVm = Read-VmSnapshot
$previousTime = $watch.Elapsed.TotalSeconds
$startVmCpuSeconds = if ($previousVm) { $previousVm.cpuSeconds } else { $null }
$firstTime = $previousTime
$baselineRemainedWithoutVm = $Mode -eq 'Baseline'
$nextSampleAt = [double][math]::Min($IntervalSeconds, $Seconds)
Write-Output "Sampling $Mode ($Label) for $Seconds seconds at nominal $IntervalSeconds-second intervals. No idle workload is assumed."
while ($previousTime -lt $Seconds) {
    $remaining = $nextSampleAt - $watch.Elapsed.TotalSeconds
    if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int][math]::Ceiling($remaining * 1000)) }
    $hostSnapshot = [SparkDroidMeasurement.NativeCounters]::Read()
    $vmSnapshot = Read-VmSnapshot
    if ($Mode -eq 'Baseline') {
        $duringBaselineVm = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($qemuPath)) -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $qemuPath })
        if ($duringBaselineVm.Count -gt 0) { $baselineRemainedWithoutVm = $false }
    }
    $sampleTime = $watch.Elapsed.TotalSeconds
    $elapsed = $sampleTime - $previousTime
    $totalCpuTicks = [double]($hostSnapshot.Kernel - $previousHost.Kernel) + [double]($hostSnapshot.User - $previousHost.User)
    $idleTicks = [double]($hostSnapshot.Idle - $previousHost.Idle)
    $hostCpuPercent = if ($totalCpuTicks -gt 0) { [math]::Round(100 * ($totalCpuTicks - $idleTicks) / $totalCpuTicks, 4) } else { $null }
    $vmCpu = if ($vmSnapshot -and $previousVm -and $elapsed -gt 0) { 100 * ($vmSnapshot.cpuSeconds - $previousVm.cpuSeconds) / $elapsed } else { $null }
    $sampleUtc = [DateTime]::UtcNow.ToString('o')
    $gpuCount = 0
    if ($nvidiaPath) {
        $gpu = Invoke-Captured $nvidiaPath @('--query-gpu=index,name,power.draw,utilization.gpu,memory.used', '--format=csv,noheader,nounits') 5000
        $gpu.stdout | Set-Content -LiteralPath (Join-Path $diagnosticDirectory "gpu-sample-$($samples.Count).txt") -Encoding utf8
        if ($gpu.exitCode -eq 0 -and -not $gpu.timedOut) {
            foreach ($device in @($gpu.stdout | ConvertFrom-Csv -Header 'index', 'name', 'power', 'utilization', 'memory')) {
                if ([string]::IsNullOrWhiteSpace($device.index)) { continue }
                $gpuSamples.Add([pscustomobject]@{ utc = $sampleUtc; elapsedSeconds = [math]::Round($sampleTime, 4); index = $device.index.Trim(); name = $device.name.Trim(); devicePowerWatts = Number-OrNull $device.power; utilizationPercent = Number-OrNull $device.utilization; memoryUsedMiB = Number-OrNull $device.memory; queryElapsedMilliseconds = $gpu.elapsedMilliseconds })
                $gpuCount++
            }
        } else { $notes.Add("GPU sample $($samples.Count) unavailable: $($gpu.stderr.Trim())") }
    }
    try {
        foreach ($battery in @(Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus -ErrorAction Stop)) {
            $activeDischarge = -not $battery.PowerOnline -and $battery.Discharging
            $rate = if ($activeDischarge -and $battery.DischargeRate -gt 0 -and $battery.DischargeRate -lt [uint32]::MaxValue) { [long]$battery.DischargeRate } else { $null }
            $batterySamples.Add([pscustomobject]@{ utc = $sampleUtc; elapsedSeconds = [math]::Round($sampleTime, 4); instanceName = $battery.InstanceName; powerOnline = [bool]$battery.PowerOnline; charging = [bool]$battery.Charging; discharging = [bool]$battery.Discharging; dischargeRateRaw = $rate; remainingCapacityRaw = $battery.RemainingCapacity; voltageRaw = $battery.Voltage; systemPowerWatts = $null })
        }
    } catch { if ($samples.Count -eq 0) { $notes.Add("BatteryStatus unavailable: $($_.Exception.Message)") } }
    $samples.Add([pscustomobject]@{
        utc = $sampleUtc; elapsedSeconds = [math]::Round($sampleTime, 4); intervalSeconds = [math]::Round($elapsed, 4)
        hostCpuPercent = $hostCpuPercent; hostAvailablePhysicalBytes = $hostSnapshot.AvailablePhysicalBytes; hostTotalPhysicalBytes = $hostSnapshot.TotalPhysicalBytes
        vmPid = if ($vmSnapshot) { $vmId } else { $null }
        vmCpuPercentOneCore = if ($null -ne $vmCpu) { [math]::Round($vmCpu, 4) } else { $null }
        vmCpuPercentWholeMachine = if ($null -ne $vmCpu) { [math]::Round($vmCpu / $logicalProcessors, 4) } else { $null }
        vmCpuSecondsTotal = if ($vmSnapshot) { $vmSnapshot.cpuSeconds } else { $null }
        vmWorkingSetBytes = if ($vmSnapshot) { $vmSnapshot.workingSetBytes } else { $null }
        vmPrivateBytes = if ($vmSnapshot) { $vmSnapshot.privateBytes } else { $null }
        gpuSensorCount = $gpuCount; systemPowerWatts = $null
    })
    $previousHost = $hostSnapshot; $previousVm = $vmSnapshot; $previousTime = $sampleTime
    $nextSampleAt = [math]::Min($Seconds, $nextSampleAt + $IntervalSeconds)
}
$observationSeconds = $previousTime - $firstTime
$observationEndUtc = [DateTime]::UtcNow
$samples | Export-Csv -LiteralPath (Join-Path $outputDirectory 'host-samples.csv') -NoTypeInformation -Encoding utf8
if ($gpuSamples.Count -gt 0) { $gpuSamples | Export-Csv -LiteralPath (Join-Path $outputDirectory 'gpu-samples.csv') -NoTypeInformation -Encoding utf8 }
if ($batterySamples.Count -gt 0) { $batterySamples | Export-Csv -LiteralPath (Join-Path $outputDirectory 'battery-samples.csv') -NoTypeInformation -Encoding utf8 }

if ($Mode -eq 'Runtime' -and $androidBootCompleted -and $Package) {
    Write-Output "Running three force-stop / am start -W trials for $Package after the observation window."
    $resolved = Adb-Diagnostic 'app-resolve-activity' @('shell', 'cmd', 'package', 'resolve-activity', '--brief', $Package) 10000
    $component = @($resolved.stdout -split '\r?\n' | Where-Object { $_ -match '\A[A-Za-z][A-Za-z0-9_.]*/[A-Za-z0-9_.$]+\z' }) | Select-Object -Last 1
    if ($resolved.exitCode -eq 0 -and $component) {
        for ($trial = 1; $trial -le 3; $trial++) {
            $stop = Adb-Diagnostic "app-trial-$trial-force-stop" @('shell', 'am', 'force-stop', $Package) 10000
            $launch = if ($stop.exitCode -eq 0) { Adb-Diagnostic "app-trial-$trial-start" @('shell', 'am', 'start', '-W', '-n', $component) 30000 } else { $null }
            $values = @{}
            if ($launch) {
                foreach ($line in ($launch.stdout -split '\r?\n')) { if ($line -match '^(Status|LaunchState|Activity|ThisTime|TotalTime|WaitTime):\s*(.*)$') { $values[$Matches[1]] = $Matches[2].Trim() } }
            }
            $coldStartTrials.Add([pscustomobject]@{ trial = $trial; component = $component; forceStopExitCode = $stop.exitCode; startExitCode = if ($launch) { $launch.exitCode } else { $null }; status = $values.Status; launchState = $values.LaunchState; adbWallMilliseconds = if ($launch) { $launch.elapsedMilliseconds } else { $null }; thisTimeMilliseconds = if ($values.ContainsKey('ThisTime')) { Number-OrNull $values.ThisTime } else { $null }; totalTimeMilliseconds = if ($values.ContainsKey('TotalTime')) { Number-OrNull $values.TotalTime } else { $null }; waitTimeMilliseconds = if ($values.ContainsKey('WaitTime')) { Number-OrNull $values.WaitTime } else { $null }; success = $null -ne $launch -and $launch.exitCode -eq 0 -and $values.Status -eq 'ok' })
        }
        $null = Adb-Diagnostic 'app-gfxinfo-after' @('shell', 'dumpsys', 'gfxinfo', $Package, 'framestats') 15000
    } else { $notes.Add('The package had no validated launchable activity; cold-start trials were not run.') }
} elseif ($Package) { $notes.Add('Cold-start trials were not run because Android had not completed boot.') }

$notes.Add('Workload labels are supplied by the caller. No idle state, FPS, frame latency, guest wakeup frequency, CPU speedup, or compatibility is inferred from host counters.')
$notes.Add('vmCpuPercentOneCore = delta QEMU process CPU seconds / elapsed wall seconds * 100; it can exceed 100. vmCpuPercentWholeMachine divides that result by detected logical processor count.')
$notes.Add('nvidia-smi reports individual device sensor power only. GPU/NPU Watts are not whole-system or Android-only power. Invoking sensor tools and WMI can affect power and wakeups.')
$notes.Add('systemPowerWatts is unavailable without a calibrated system power source. Battery dischargeRateRaw is null on AC, while charging, or if unavailable; raw battery units are not converted to Watts because relative-capacity reporting has not been independently excluded.')
$notes.Add('Application trials force-stop the package and relaunch its resolved activity, preserving its data. Filesystem/ART caches are not cleared; report LaunchState and am timings rather than asserting storage-cold starts.')
$notes.Add('Diagnostics and optional launch trials occur outside the host observation window. Concurrent host work and guest provisioning are not suppressed.')
if ($Mode -eq 'Baseline' -and -not $baselineRemainedWithoutVm) { $notes.Add('INVALID BASELINE: the configured QEMU executable appeared during observation. Do not compare this run as a stopped-runtime baseline.') }
if ($Mode -eq 'Runtime' -and @($samples | Where-Object { $null -eq $_.vmPid }).Count -gt 0) { $notes.Add('The VM process was absent for part of this observation. Full-window VM CPU averages are unavailable.') }
$gpuSummary = @($gpuSamples | Group-Object index | ForEach-Object { [pscustomobject]@{ index = $_.Name; name = $_.Group[0].name; devicePowerWatts = Statistics $_.Group.devicePowerWatts; utilizationPercent = Statistics $_.Group.utilizationPercent } })
$windowVmCpu = if ($null -ne $startVmCpuSeconds -and $previousVm -and $observationSeconds -gt 0) { 100 * ($previousVm.cpuSeconds - $startVmCpuSeconds) / $observationSeconds } else { $null }
$report = [ordered]@{
    schemaVersion = 1; mode = $Mode; workloadLabel = $Label; startedUtc = $startUtc.ToString('o'); observationEndedUtc = $observationEndUtc.ToString('o'); requestedSeconds = $Seconds; actualObservationSeconds = [math]::Round($observationSeconds, 4); nominalIntervalSeconds = $IntervalSeconds; validStoppedRuntimeBaseline = if ($Mode -eq 'Baseline') { $baselineRemainedWithoutVm } else { $null }
    host = [ordered]@{ logicalProcessors = $logicalProcessors; physicalMemoryBytes = [long]$computer.TotalPhysicalMemory; osArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString(); processArchitecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() }
    runtime = [ordered]@{ backend = $config.backend; profile = $config.profile; configuredGraphics = $config.graphics; vmPid = $vmId; vmExecutable = if ($vm) { $qemuPath } else { $null }; androidBootCompletedBeforeObservation = $androidBootCompleted; androidProperties = $androidProperties; rendererEvidence = $rendererEvidence; hardwareGraphicsAccelerationValidated = $false }
    summary = [ordered]@{ hostCpuPercent = Statistics $samples.hostCpuPercent; vmCpuPercentOneCore = Statistics $samples.vmCpuPercentOneCore; vmCpuPercentWholeMachine = Statistics $samples.vmCpuPercentWholeMachine; windowAverageVmCpuPercentOneCore = if ($null -ne $windowVmCpu) { [math]::Round($windowVmCpu, 4) } else { $null }; windowAverageVmCpuPercentWholeMachine = if ($null -ne $windowVmCpu) { [math]::Round($windowVmCpu / $logicalProcessors, 4) } else { $null }; vmWorkingSetBytes = Statistics $samples.vmWorkingSetBytes; vmPrivateBytes = Statistics $samples.vmPrivateBytes; gpuDevices = $gpuSummary; systemPowerWatts = $null }
    samples = $samples; gpuSamples = $gpuSamples; batterySamples = $batterySamples; coldStartPackage = $Package; coldStartTrials = $coldStartTrials; diagnosticCommands = $diagnosticCommands; notes = $notes
    references = @('https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemtimes', 'https://docs.nvidia.com/deploy/nvidia-smi/', 'https://learn.microsoft.com/en-us/windows/win32/power/battery-status-str', 'https://learn.microsoft.com/en-us/windows/win32/api/batclass/ns-batclass-battery_wmi_status')
}
$reportPath = Join-Path $outputDirectory 'measurement.json'
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $reportPath -Encoding utf8
Write-Output "Measurement written: $reportPath"
$report.summary | ConvertTo-Json -Depth 6
