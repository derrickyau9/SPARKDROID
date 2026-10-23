[CmdletBinding()]
param(
    [ValidateSet('Preview', 'Apply', 'Status', 'Accept', 'Rollback', 'Watchdog')]
    [string]$Action = 'Preview',
    [string]$RunDirectory
)

# Controlled session-only refresh-rate experiment. The default action is read-only.
# Apply starts an independent rollback process before changing DISPLAY1. Accept
# must be called explicitly within 60 seconds to retain the session setting.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$trialRoot = Join-Path $projectRoot 'artifacts/wsa/display120-trials'
$targetDisplay = '\\.\DISPLAY1'
$otherDisplay = '\\.\DISPLAY2'
$rollbackSeconds = 60

if (-not ('SparkDroid.DisplayModeReadWrite' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SparkDroid {
 public sealed class DisplayModeSnapshot {
  public string Device, Description, MonitorId;
  public int State, Width, Height, Frequency, PositionX, PositionY, Orientation;
  public byte[] Raw;
 }
 public static class DisplayModeReadWrite {
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool EnumDisplayDevices(string device, uint index, IntPtr data, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern bool EnumDisplaySettingsEx(string device, int mode, IntPtr data, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern int ChangeDisplaySettingsEx(string device, IntPtr mode, IntPtr hwnd, uint flags, IntPtr parameter);
  static string ReadString(IntPtr data, int offset, int chars) {
   return Marshal.PtrToStringUni(IntPtr.Add(data, offset), chars).TrimEnd('\0');
  }
  static IntPtr ZeroBuffer(int length) {
   IntPtr ptr=Marshal.AllocHGlobal(length);
   Marshal.Copy(new byte[length],0,ptr,length);
   return ptr;
  }
  public static DisplayModeSnapshot Read(string device) {
   var result=new DisplayModeSnapshot { Device=device };
   IntPtr dd=ZeroBuffer(840);
   try {
    bool found=false;
    for(uint i=0;i<32;i++) {
     Marshal.Copy(new byte[840],0,dd,840); Marshal.WriteInt32(dd,840);
     if(!EnumDisplayDevices(null,i,dd,0)) break;
     if(ReadString(dd,4,32)!=device) continue;
     result.Description=ReadString(dd,68,128); result.State=Marshal.ReadInt32(dd,324);
     found=true; break;
    }
    if(!found || (result.State&1)==0) throw new InvalidOperationException("Requested display is not active: "+device);
    Marshal.Copy(new byte[840],0,dd,840); Marshal.WriteInt32(dd,840);
    if(!EnumDisplayDevices(device,0,dd,0)) throw new InvalidOperationException("Monitor identity unavailable: "+device);
    result.MonitorId=ReadString(dd,328,128);
    if(String.IsNullOrWhiteSpace(result.MonitorId)) throw new InvalidOperationException("Empty monitor identity");
   } finally { Marshal.FreeHGlobal(dd); }
   // Reserve the complete public DEVMODEW plus the maximum WORD-sized driver
   // payload. Preserve whatever size and driver-extra length the API returns.
   IntPtr dm=ZeroBuffer(220+65535);
   try {
    Marshal.WriteInt16(dm,68,220);
    if(!EnumDisplaySettingsEx(device,-1,dm,0)) throw new InvalidOperationException("Current mode unavailable: "+device);
    int publicSize=(ushort)Marshal.ReadInt16(dm,68);
    int extraSize=(ushort)Marshal.ReadInt16(dm,70);
    if(publicSize<188 || publicSize>220) throw new InvalidOperationException("Unexpected DEVMODEW size");
    result.Raw=new byte[publicSize+extraSize]; Marshal.Copy(dm,result.Raw,0,result.Raw.Length);
    result.PositionX=Marshal.ReadInt32(dm,76); result.PositionY=Marshal.ReadInt32(dm,80);
    result.Orientation=Marshal.ReadInt32(dm,84); result.Width=Marshal.ReadInt32(dm,172);
    result.Height=Marshal.ReadInt32(dm,176); result.Frequency=Marshal.ReadInt32(dm,184);
   } finally { Marshal.FreeHGlobal(dm); }
   return result;
  }
  public static byte[] With120Hz(byte[] original) {
   byte[] changed=(byte[])original.Clone();
   Buffer.BlockCopy(BitConverter.GetBytes(BitConverter.ToUInt32(changed,72)|0x00400000u),0,changed,72,4);
   Buffer.BlockCopy(BitConverter.GetBytes(120u),0,changed,184,4);
   for(int i=0;i<original.Length;i++)
    if(original[i]!=changed[i] && !(i>=72&&i<76) && !(i>=184&&i<188))
     throw new InvalidOperationException("Unexpected DEVMODE mutation");
   return changed;
  }
  public static int Test(string device, byte[] raw) { return Set(device,raw,2); } // CDS_TEST
  public static int ApplySession(string device, byte[] raw) { return Set(device,raw,0); }
  static int Set(string device, byte[] raw, uint flags) {
   if(device!="\\\\.\\DISPLAY1") throw new InvalidOperationException("Only DISPLAY1 may be changed");
   IntPtr p=Marshal.AllocHGlobal(raw.Length);
   try { Marshal.Copy(raw,0,p,raw.Length); return ChangeDisplaySettingsEx(device,p,IntPtr.Zero,flags,IntPtr.Zero); }
   finally { Marshal.FreeHGlobal(p); }
  }
 }
}
'@
}

function Get-Hash([byte[]]$Bytes) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}
function Save-Json([string]$Name, $Value) {
    $destination = Join-Path $script:run $Name
    $temporary = $destination + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $destination, $true)
}
function Mode-Record($Mode) {
    [ordered]@{
        device=$Mode.Device; description=$Mode.Description; monitorId=$Mode.MonitorId; state=$Mode.State
        width=$Mode.Width; height=$Mode.Height; frequency=$Mode.Frequency
        x=$Mode.PositionX; y=$Mode.PositionY; orientation=$Mode.Orientation
        devModeBase64=[Convert]::ToBase64String($Mode.Raw); devModeSha256=(Get-Hash $Mode.Raw)
    }
}
function Assert-SameMonitor($Current, $Saved) {
    if ($Current.Device -ne $Saved.device -or $Current.MonitorId -ne $Saved.monitorId -or
        $Current.Description -ne $Saved.description -or $Current.State -ne $Saved.state) {
        throw 'Monitor identity, active/primary state or adapter changed; refusing to target a different display.'
    }
}
function Assert-SameGeometry($Current, $Saved) {
    Assert-SameMonitor $Current $Saved
    if ($Current.Width -ne $Saved.width -or $Current.Height -ne $Saved.height -or
        $Current.PositionX -ne $Saved.x -or $Current.PositionY -ne $Saved.y -or
        $Current.Orientation -ne $Saved.orientation) { throw 'Display geometry or arrangement changed.' }
}
function Read-Snapshot {
    $s = Get-Content -LiteralPath (Join-Path $script:run 'snapshot.json') -Raw | ConvertFrom-Json
    if ($s.target.device -ne $targetDisplay -or $s.other.device -ne $otherDisplay -or
        $s.target.width -ne 2880 -or $s.target.height -ne 1800 -or $s.target.frequency -ne 60) {
        throw 'This trial is only valid for the previously observed DISPLAY1 2880x1800 at 60 Hz.'
    }
    $raw = [Convert]::FromBase64String($s.target.devModeBase64)
    if ((Get-Hash $raw) -ne $s.target.devModeSha256) { throw 'Saved DEVMODE checksum mismatch.' }
    return $s
}
function Restore-Original([string]$Reason) {
    $s = Read-Snapshot
    $current = [SparkDroid.DisplayModeReadWrite]::Read($targetDisplay)
    Assert-SameMonitor $current $s.target
    $code = [SparkDroid.DisplayModeReadWrite]::ApplySession($targetDisplay, [Convert]::FromBase64String($s.target.devModeBase64))
    $after = [SparkDroid.DisplayModeReadWrite]::Read($targetDisplay)
    $other = [SparkDroid.DisplayModeReadWrite]::Read($otherDisplay)
    Assert-SameGeometry $after $s.target
    Assert-SameGeometry $other $s.other
    $success = $code -eq 0 -and $after.Frequency -eq $s.target.frequency -and $other.Frequency -eq $s.other.frequency
    Save-Json 'rollback.json' ([ordered]@{utc=[DateTime]::UtcNow.ToString('o');reason=$Reason;resultCode=$code;success=$success;target=(Mode-Record $after);other=(Mode-Record $other)})
    if (-not $success) { throw 'Rollback did not verify; inspect rollback.json immediately.' }
}
function Assert-TrialMode {
    $s = Read-Snapshot
    $current = [SparkDroid.DisplayModeReadWrite]::Read($targetDisplay)
    $other = [SparkDroid.DisplayModeReadWrite]::Read($otherDisplay)
    Assert-SameGeometry $current $s.target
    Assert-SameGeometry $other $s.other
    if ($current.Frequency -ne 120 -or (Get-Hash $other.Raw) -ne $s.other.devModeSha256) {
        throw '120 Hz target or unchanged DISPLAY2 could not be verified.'
    }
    return $current
}

if ($Action -eq 'Preview') {
    [ordered]@{action='Preview';displayChangePerformed=$false;target=(Mode-Record ([SparkDroid.DisplayModeReadWrite]::Read($targetDisplay)));other=(Mode-Record ([SparkDroid.DisplayModeReadWrite]::Read($otherDisplay)));targetHz=120;rollbackSeconds=$rollbackSeconds;registryUpdate=$false} | ConvertTo-Json -Depth 8
    exit 0
}
if (-not $RunDirectory) {
    if ($Action -ne 'Apply') { throw '-RunDirectory from the Apply result is required.' }
    $RunDirectory = Join-Path $trialRoot ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
}
$script:run = [IO.Path]::GetFullPath($RunDirectory)
$allowedPrefix = [IO.Path]::GetFullPath($trialRoot).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
if (-not $script:run.StartsWith($allowedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Trial directory must be beneath $trialRoot"
}

if ($Action -eq 'Apply') {
    if (Test-Path -LiteralPath $script:run) { throw 'A new trial directory is required.' }
    $current = [SparkDroid.DisplayModeReadWrite]::Read($targetDisplay)
    $other = [SparkDroid.DisplayModeReadWrite]::Read($otherDisplay)
    if ($current.Width -ne 2880 -or $current.Height -ne 1800 -or $current.Frequency -ne 60) {
        throw 'Expected DISPLAY1 current mode 2880x1800 at 60 Hz. No changes made.'
    }
    $newMode = [SparkDroid.DisplayModeReadWrite]::With120Hz($current.Raw)
    $testResult = [SparkDroid.DisplayModeReadWrite]::Test($targetDisplay, $newMode)
    if ($testResult -ne 0) { throw "CDS_TEST rejected 120 Hz (result $testResult). No changes made." }
    [IO.Directory]::CreateDirectory($script:run) | Out-Null
    Save-Json 'snapshot.json' ([ordered]@{schemaVersion=1;utc=[DateTime]::UtcNow.ToString('o');target=(Mode-Record $current);other=(Mode-Record $other);requestedHz=120;rollbackSeconds=$rollbackSeconds;cdsTestResult=$testResult;registryUpdate=$false})
    $shellPath = (Get-Process -Id $PID).Path
    $watchdogArgs = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),'-Action','Watchdog','-RunDirectory',('"{0}"' -f $script:run))
    $watchdog = Start-Process -FilePath $shellPath -ArgumentList $watchdogArgs -WindowStyle Hidden -PassThru
    $readyDeadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath (Join-Path $script:run 'watchdog-ready.json'))) {
        $watchdog.Refresh()
        if ($watchdog.HasExited -or [DateTime]::UtcNow -ge $readyDeadline) { throw 'Rollback watchdog did not become ready. No changes made.' }
        Start-Sleep -Milliseconds 100
    }
    # Detect intervening changes before the single session-only native call.
    if ((Get-Hash ([SparkDroid.DisplayModeReadWrite]::Read($targetDisplay)).Raw) -ne (Get-Hash $current.Raw) -or
        (Get-Hash ([SparkDroid.DisplayModeReadWrite]::Read($otherDisplay)).Raw) -ne (Get-Hash $other.Raw)) {
        Save-Json 'cancelled.json' @{reason='A display mode changed before apply';utc=[DateTime]::UtcNow.ToString('o')}
        throw 'Display mode changed during preflight. No changes made.'
    }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($rollbackSeconds)
    Save-Json 'apply-started.json' @{utc=[DateTime]::UtcNow.ToString('o');rollbackDeadlineUtc=$deadline.ToString('o');rollbackDeadlineUnixMs=$deadline.ToUnixTimeMilliseconds()}
    try {
        $code = [SparkDroid.DisplayModeReadWrite]::ApplySession($targetDisplay, $newMode)
        if ($code -ne 0) { throw "ChangeDisplaySettingsEx returned $code" }
        $verified = Assert-TrialMode
        Save-Json 'applied.json' @{utc=[DateTime]::UtcNow.ToString('o');resultCode=$code;target=(Mode-Record $verified)}
        [ordered]@{action='Apply';runDirectory=$script:run;target=$targetDisplay;currentHz=$verified.Frequency;rollbackDeadlineUtc=$deadline.ToString('o');watchdogPid=$watchdog.Id;registryUpdate=$false;next='Verify stability and WSA modes, then call -Action Accept with this RunDirectory before the deadline; otherwise automatic rollback restores the complete saved mode.'} | ConvertTo-Json
    } catch {
        $failure = $_.Exception.Message
        Restore-Original ('Apply verification failed: ' + $failure)
        throw $failure
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $script:run -PathType Container)) { throw 'Trial directory does not exist.' }
if ($Action -eq 'Status') {
    Read-Snapshot | Out-Null
    [ordered]@{runDirectory=$script:run;markers=@(Get-ChildItem -LiteralPath $script:run -Filter '*.json' | Select-Object -ExpandProperty Name);target=(Mode-Record ([SparkDroid.DisplayModeReadWrite]::Read($targetDisplay)));other=(Mode-Record ([SparkDroid.DisplayModeReadWrite]::Read($otherDisplay)))} | ConvertTo-Json -Depth 8
    exit 0
}
if ($Action -eq 'Rollback') { Restore-Original 'Explicit rollback'; Get-Content -LiteralPath (Join-Path $script:run 'rollback.json'); exit 0 }
if ($Action -eq 'Accept') {
    if (Test-Path -LiteralPath (Join-Path $script:run 'rollback.json')) { throw 'Trial has already rolled back.' }
    $started = Get-Content -LiteralPath (Join-Path $script:run 'apply-started.json') -Raw | ConvertFrom-Json
    if ([DateTime]::UtcNow -ge [DateTimeOffset]::FromUnixTimeMilliseconds([long]$started.rollbackDeadlineUnixMs).UtcDateTime) { throw 'Acceptance deadline expired.' }
    Assert-TrialMode | Out-Null
    Save-Json 'accept-requested.json' @{utc=[DateTime]::UtcNow.ToString('o')}
    $ackDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not (Test-Path -LiteralPath (Join-Path $script:run 'accepted.json'))) {
        if ((Test-Path -LiteralPath (Join-Path $script:run 'rollback.json')) -or [DateTime]::UtcNow -ge $ackDeadline) {
            throw 'Watchdog has not acknowledged acceptance. Automatic rollback remains possible; inspect Status.'
        }
        Start-Sleep -Milliseconds 100
    }
    Get-Content -LiteralPath (Join-Path $script:run 'accepted.json')
    exit 0
}
if ($Action -eq 'Watchdog') {
    try {
        Read-Snapshot | Out-Null
        Save-Json 'watchdog-ready.json' @{utc=[DateTime]::UtcNow.ToString('o');pid=$PID}
        $startDeadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not (Test-Path -LiteralPath (Join-Path $script:run 'apply-started.json'))) {
            if ((Test-Path -LiteralPath (Join-Path $script:run 'cancelled.json')) -or [DateTime]::UtcNow -ge $startDeadline) { exit 0 }
            Start-Sleep -Milliseconds 100
        }
        $started = Get-Content -LiteralPath (Join-Path $script:run 'apply-started.json') -Raw | ConvertFrom-Json
        $deadline = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$started.rollbackDeadlineUnixMs).UtcDateTime
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-Path -LiteralPath (Join-Path $script:run 'rollback.json')) { exit 0 }
            if (Test-Path -LiteralPath (Join-Path $script:run 'accept-requested.json')) {
                $verified = Assert-TrialMode
                Save-Json 'accepted.json' @{utc=[DateTime]::UtcNow.ToString('o');currentHz=$verified.Frequency;registryUpdate=$false;rollbackAvailable=$true;note='Session-only 120 Hz retained after explicit acceptance; original full DEVMODE remains saved.'}
                exit 0
            }
            Start-Sleep -Milliseconds 100
        }
        Restore-Original '60-second trial expired without acceptance'
    } catch {
        $failure = $_.Exception.Message
        Save-Json 'watchdog-error.json' @{utc=[DateTime]::UtcNow.ToString('o');error=$failure}
        if ((Test-Path -LiteralPath (Join-Path $script:run 'apply-started.json')) -and -not (Test-Path -LiteralPath (Join-Path $script:run 'rollback.json'))) {
            try { Restore-Original ('Watchdog error: ' + $failure) } catch {
                Save-Json 'rollback-error.json' @{utc=[DateTime]::UtcNow.ToString('o');error=$_.Exception.Message}
            }
        }
        exit 1
    }
}
