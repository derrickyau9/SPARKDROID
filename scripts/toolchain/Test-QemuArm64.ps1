#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [switch]$WithVirgl
)
$ErrorActionPreference = 'Stop'
$qemu = Join-Path $ProjectRoot 'tools/qemu-arm64/clangarm64/bin/qemu-system-aarch64.exe'
$evidence = Join-Path $ProjectRoot 'artifacts/toolchain'
New-Item -ItemType Directory -Force $evidence | Out-Null
$file = [IO.File]::OpenRead($qemu)
try {
    $reader = [IO.BinaryReader]::new($file)
    $file.Position = 0x3c
    $peOffset = $reader.ReadInt32()
    $file.Position = $peOffset
    if ($reader.ReadUInt32() -ne 0x00004550) { throw 'Not a PE executable.' }
    $machine = $reader.ReadUInt16()
} finally { $file.Dispose() }
if ($machine -ne 0xAA64) { throw ('QEMU is not native Windows ARM64: PE Machine 0x{0:X4}' -f $machine) }
$checks = [ordered]@{
    timestampUtc = [DateTime]::UtcNow.ToString('o')
    binary = $qemu
    sha256 = (Get-FileHash -LiteralPath $qemu -Algorithm SHA256).Hash.ToLowerInvariant()
    peMachine = ('0x{0:X4}' -f $machine)
    nativeWindowsArm64 = $true
    virglRequested = [bool]$WithVirgl
    commands = @()
}
foreach ($item in @(
    @{name='version';arguments=@('--version')},
    @{name='accelerators';arguments=@('-accel','help')},
    @{name='displays';arguments=@('-display','help')},
    @{name='audiodevs';arguments=@('-audio','driver=help')},
    @{name='devices';arguments=@('-device','help')}
)) {
    $output = & $qemu @($item.arguments) 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    $output | Set-Content -LiteralPath (Join-Path $evidence "qemu-$($item.name).txt") -Encoding utf8
    $checks.commands += [ordered]@{name=$item.name;arguments=$item.arguments;exitCode=$exitCode;output=$output.Trim()}
}
# A real machine must initialize before the QMP greeting; listed accelerators alone prove only compilation.
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $qemu
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$portReservation = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$portReservation.Start()
$qmpPort = $portReservation.LocalEndpoint.Port
$portReservation.Stop()
$display = if ($WithVirgl) { 'egl-headless' } else { 'none' }
$arguments = @('-M','virt','-accel','whpx','-cpu','host','-m','512','-smp','1','-nodefaults','-display',$display,'-serial','none','-qmp',"tcp:127.0.0.1:$qmpPort,server=on,wait=off",'-S')
if ($WithVirgl) { $arguments += @('-device','virtio-gpu-gl-pci') }
foreach ($argument in $arguments) { $startInfo.ArgumentList.Add($argument) }
$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$timer = [Diagnostics.Stopwatch]::StartNew()
$transcript = [Collections.Generic.List[string]]::new()
$ready = $false
$status = $null
try {
    [void]$process.Start()
    $stderr = $process.StandardError.ReadToEndAsync()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $client = $null
    for ($attempt = 0; $attempt -lt 30 -and -not $process.HasExited; $attempt++) {
        try { $client = [Net.Sockets.TcpClient]::new('127.0.0.1', $qmpPort); break }
        catch { Start-Sleep -Milliseconds 100 }
    }
    if ($client) {
        try {
            $networkStream = $client.GetStream()
            $qmpReader = [IO.StreamReader]::new($networkStream, [Text.UTF8Encoding]::new($false))
            $qmpWriter = [IO.StreamWriter]::new($networkStream, [Text.UTF8Encoding]::new($false))
            $qmpWriter.NewLine = "`n"
            $qmpWriter.AutoFlush = $true
            $greeting = $qmpReader.ReadLineAsync()
            if (-not $greeting.Wait(5000)) { throw 'QMP greeting timed out.' }
            $transcript.Add($greeting.Result)
            foreach ($command in @('qmp_capabilities','query-status','query-cpus-fast','quit')) {
                $qmpWriter.WriteLine((@{execute=$command;id=$command} | ConvertTo-Json -Compress))
                do {
                    $line = $qmpReader.ReadLineAsync()
                    if (-not $line.Wait(5000)) { throw "QMP $command timed out." }
                    if ($null -eq $line.Result) { break }
                    $transcript.Add($line.Result)
                    $response = $line.Result | ConvertFrom-Json
                } while ($response.id -ne $command)
                if ($response.id -eq 'query-status' -and $response.return) {
                    $status = $response.return.status
                    $ready = ($status -eq 'prelaunch' -or $status -eq 'paused')
                }
            }
        } finally { $client.Dispose() }
    }
    if (-not $process.WaitForExit(15000)) { $process.Kill($true); $process.WaitForExit(); $transcript.Add('TIMEOUT: process terminated after 15 seconds.') }
    $output = $stdout.GetAwaiter().GetResult()
    $errors = $stderr.GetAwaiter().GetResult()
    $transcript.Add($output)
    $transcript.Add($errors)
    $checks.whpx = [ordered]@{arguments=$arguments;exitCode=$process.ExitCode;initialized=$ready;status=$status;elapsedMs=$timer.ElapsedMilliseconds;qmp=@($transcript);stdout=$output;stderr=$errors}
} finally {
    if ($process.Id -and -not $process.HasExited) { $process.Kill($true) }
    $process.Dispose()
}
$prefix = if ($WithVirgl) { 'qemu-virgl' } else { 'qemu' }
$transcript | Set-Content -LiteralPath (Join-Path $evidence "$prefix-whpx-qmp.txt") -Encoding utf8
$checks | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $evidence "$prefix-validation.json") -Encoding utf8
[pscustomobject]@{Binary=$qemu;NativeArm64=$true;VirglRequested=[bool]$WithVirgl;WhpxInitialized=$ready;WhpxStatus=$status;Evidence=(Join-Path $evidence "$prefix-validation.json")}
