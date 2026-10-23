[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$out=Join-Path $root 'artifacts/host'
New-Item -ItemType Directory -Force $out|Out-Null
if(-not('SparkDroidWhpProbe' -as [type])){
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SparkDroidWhpProbe {
 [DllImport("WinHvPlatform.dll", ExactSpelling=true)] public static extern int WHvGetCapability(uint c, IntPtr b, uint s, out uint n);
 [DllImport("WinHvPlatform.dll", ExactSpelling=true)] public static extern int WHvCreatePartition(out IntPtr p);
 [DllImport("WinHvPlatform.dll", ExactSpelling=true)] public static extern int WHvDeletePartition(IntPtr p);
}
'@
}
$buffer=[Runtime.InteropServices.Marshal]::AllocHGlobal(8)
try {
    [Runtime.InteropServices.Marshal]::WriteInt64($buffer,0);[uint32]$written=0
    $hr=[SparkDroidWhpProbe]::WHvGetCapability(0,$buffer,8,[ref]$written)
    $partition=[IntPtr]::Zero;$phr=[SparkDroidWhpProbe]::WHvCreatePartition([ref]$partition)
    if($partition -ne [IntPtr]::Zero){$null=[SparkDroidWhpProbe]::WHvDeletePartition($partition)}
    $report=[ordered]@{
        capturedUtc=[DateTime]::UtcNow.ToString('o');processArchitecture=[Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        os=Get-CimInstance Win32_OperatingSystem|Select-Object Caption,Version,BuildNumber,OSArchitecture,TotalVisibleMemorySize
        computer=Get-CimInstance Win32_ComputerSystem|Select-Object Manufacturer,Model,SystemType,TotalPhysicalMemory,HypervisorPresent
        cpu=Get-CimInstance Win32_Processor|Select-Object Name,Architecture,NumberOfCores,NumberOfLogicalProcessors,VirtualizationFirmwareEnabled,SecondLevelAddressTranslationExtensions
        gpu=Get-CimInstance Win32_VideoController|Select-Object Name,DriverVersion,DriverDate,AdapterRAM,PNPDeviceID
        optionalFeatureInventory=Get-CimInstance Win32_OptionalFeature|Where-Object {$_.Name -match 'Hyper-V|HypervisorPlatform|VirtualMachinePlatform|Subsystem-Linux'}|Select-Object Name,InstallState
        whp=@{capabilityHResult=('0x{0:X8}' -f $hr);hypervisorPresent=[Runtime.InteropServices.Marshal]::ReadInt32($buffer);createPartitionHResult=('0x{0:X8}' -f $phr)}
        gpuSensor=(& nvidia-smi --query-gpu=name,driver_version,memory.total,power.draw,power.limit --format=csv,noheader 2>&1|Out-String).Trim()
        memoryCaution='Win32 host RAM, legacy AdapterRAM and nvidia-smi device memory disagree on this host. They are reported separately; unified/shared memory is not inferred.'
    }
    $report|ConvertTo-Json -Depth 8|Tee-Object -FilePath (Join-Path $out 'inventory.json')
}finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)}
