[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange(15,90)][int]$Seconds = 35
)
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This bounded ETW diagnostic capture requires elevation.'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$suffix = [Guid]::NewGuid().ToString('N').Substring(0,8)
$providers = @(
    @{Name="SPARKDROID-WSA-Kernel-$suffix"; File='kernel'; Guid='{B99CDB5A-039C-5046-E672-1A0DE0A40211}'},
    @{Name="SPARKDROID-WSA-Dmesg-$suffix"; File='dmesg'; Guid='{A322581F-BFF3-5BF6-6BFC-6A067DB5F8D8}'},
    @{Name="SPARKDROID-WSA-Client-$suffix"; File='client'; Guid='{30CB12F5-B71B-5A66-0484-11B8118099DA}'}
)
$started = @()
$receipt = [ordered]@{startedUtc=[DateTime]::UtcNow.ToString('o');seconds=$Seconds;success=$false;phases=@();errors=@()}
try {
    foreach ($provider in $providers) {
        $etl = Join-Path $OutputDirectory ($provider.File + '.etl')
        & logman.exe create trace $provider.Name -o $etl -p $provider.Guid 0xffffffffffffffff 5 -ets 2>&1 |
            Out-File (Join-Path $OutputDirectory ($provider.File + '-start.txt'))
        $receipt.phases += @{provider=$provider.File;phase='start';exitCode=$LASTEXITCODE}
        if ($LASTEXITCODE -ne 0) { throw "ETW start failed: $($provider.File)" }
        $started += $provider
    }
    [DateTime]::UtcNow.ToString('o') | Set-Content (Join-Path $OutputDirectory 'ready.txt')
    Start-Sleep -Seconds $Seconds
} catch {
    $receipt.errors += $_.Exception.Message
    $_.Exception.Message | Set-Content (Join-Path $OutputDirectory 'error.txt')
} finally {
    foreach ($provider in $started) {
        & logman.exe stop $provider.Name -ets 2>&1 |
            Out-File (Join-Path $OutputDirectory ($provider.File + '-stop.txt'))
        $receipt.phases += @{provider=$provider.File;phase='stop';exitCode=$LASTEXITCODE}
        if ($LASTEXITCODE -ne 0) { $receipt.errors += "ETW stop failed: $($provider.File)" }
    }
}
foreach ($provider in $started) {
    $etl = Join-Path $OutputDirectory ($provider.File + '.etl')
    $xml = Join-Path $OutputDirectory ($provider.File + '.xml')
    & tracerpt.exe $etl -o $xml -of XML -y 2>&1 |
        Out-File (Join-Path $OutputDirectory ($provider.File + '-decode.txt'))
    $receipt.phases += @{provider=$provider.File;phase='decode';exitCode=$LASTEXITCODE}
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $xml)) {
        $receipt.errors += "ETW decode failed: $($provider.File)"
    }
}
$receipt.success = $receipt.errors.Count -eq 0 -and $started.Count -eq $providers.Count
$receipt.completedUtc = [DateTime]::UtcNow.ToString('o')
$receipt | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutputDirectory 'receipt.json')
# This marker means the worker finished, not that Android booted or tracing succeeded.
[DateTime]::UtcNow.ToString('o') | Set-Content (Join-Path $OutputDirectory 'complete.txt')
if (-not $receipt.success) { exit 1 }
