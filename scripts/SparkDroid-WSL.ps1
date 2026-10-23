#requires -Version 7.2
[CmdletBinding()]
param(
    [ValidateSet('Status','Probe','Provision','Start','Stop','Apps','Install','Launch')]
    [string]$Action='Status',
    [string[]]$Apk,
    [string]$Package,
    [ValidateSet('Software','DrmExperimental')][string]$Graphics='Software',
    [switch]$WaitForAndroid
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$config=Get-Content -LiteralPath (Join-Path $root 'config/runtime-wsl.json') -Raw|ConvertFrom-Json
$serial="127.0.0.1:$($config.adbPort)"
function Full([string]$path){Join-Path $root $path}
function RequireFile([string]$path){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Required file missing: $path"}}
function InvokeProcess([string]$exe,[string[]]$arguments,[int]$timeout=30000,[switch]$AllowFailure){
    $psi=[Diagnostics.ProcessStartInfo]::new($exe)
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WorkingDirectory=$root
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    if([IO.Path]::GetFileName($exe) -ieq 'wsl.exe'){
        $psi.Environment['WSL_UTF8']='1'
        $psi.StandardOutputEncoding=[Text.Encoding]::UTF8;$psi.StandardErrorEncoding=[Text.Encoding]::UTF8
    }
    foreach($argument in $arguments){$psi.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::Start($psi)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($timeout)){
            # This ends only this command client, never all WSL distributions.
            $process.Kill()
            throw "Command timed out after $($timeout/1000)s: $([IO.Path]::GetFileName($exe)). The Linux operation may still be running; inspect Status before retrying."
        }
        $result=[pscustomobject]@{ExitCode=$process.ExitCode;Output=$stdout.GetAwaiter().GetResult().Trim();Error=$stderr.GetAwaiter().GetResult().Trim()}
        if(-not $AllowFailure -and $result.ExitCode -ne 0){throw "$([IO.Path]::GetFileName($exe)) exited $($result.ExitCode): $($result.Error) $($result.Output)"}
        return $result
    } finally {$process.Dispose()}
}
function Wsl([string[]]$arguments,[int]$timeout=30000){
    (InvokeProcess $script:wslExe (@('--distribution',[string]$config.distro,'--user','root','--exec')+$arguments) $timeout).Output
}
function RegisteredDistros([switch]$Running){
    $arguments=@('--list','--quiet');if($Running){$arguments+= '--running'}
    $result=InvokeProcess $script:wslExe $arguments 15000 -AllowFailure
    if($result.ExitCode -ne 0){throw "Cannot list WSL distributions. Install WSL 2 and import the SPARKDROID ARM64 distro first. $($result.Error) $($result.Output)"}
    @($result.Output -split "`r?`n"|ForEach-Object {$_.Trim([char]0).Trim()}|Where-Object {$_})
}
function RequireDistro {
    if([string]$config.distro -notin @(RegisteredDistros)){throw "WSL distro '$($config.distro)' is not installed. Run the project WSL setup first. The QEMU installation is separate."}
}
function BootLease {
    New-Item -ItemType Directory -Force (Full 'state/wsl')|Out-Null
    $deadline=[DateTime]::UtcNow.AddMinutes(15)
    do{
        try{return [IO.File]::Open((Full 'state/wsl/start.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
        catch [IO.IOException]{Start-Sleep -Milliseconds 250}
    }while([DateTime]::UtcNow -lt $deadline)
    throw 'Another SPARKDROID WSL operation did not release its lock within 15 minutes.'
}
function GuestAction([string]$operation,[int]$timeout=60000){
    RequireDistro
    if($operation -in @('provision','start','stop')){
        $marker=Wsl @('cat','/etc/sparkdroid-wsl') 10000
        if($marker -cne 'SPARKDROID-WSL1'){throw 'The SPARKDROID distro has no matching ownership marker. Refusing to modify or terminate a potentially unrelated distribution.'}
    }
    $guestScript=Full 'guest/wsl/provision-redroid.sh';RequireFile $guestScript
    $linuxPath=Wsl @('wslpath','-a','-u',$guestScript)
    $mode=if($Graphics -eq 'DrmExperimental'){'host'}else{'guest'}
    $arguments=@('env',"SPARKDROID_ANDROID_IMAGE=$($config.androidImage)","SPARKDROID_CONTAINER=$($config.container)",
        "SPARKDROID_ADB_PORT=$($config.adbPort)","SPARKDROID_WIDTH=$($config.display.width)","SPARKDROID_HEIGHT=$($config.display.height)",
        "SPARKDROID_DPI=$($config.display.dpi)","SPARKDROID_FPS=$($config.display.refreshHz)","SPARKDROID_GPU_MODE=$mode",
        "SPARKDROID_GPU_NODE=$($config.gpuNode)",'bash',$linuxPath,$operation)
    Wsl $arguments $timeout
}
function Adb([string[]]$arguments,[int]$timeout=30000){
    $exe=Full $config.adb;RequireFile $exe
    (InvokeProcess $exe (@('-s',$serial)+$arguments) $timeout).Output
}
function ConnectAdb {
    $exe=Full $config.adb;RequireFile $exe
    $result=(InvokeProcess $exe @('connect',$serial) 10000).Output
    if($result -match 'failed|cannot|unable'){throw "WSL Android ADB connection failed: $result. Only localhost port $($config.adbPort) is supported; no external ADB listener or global port proxy is created."}
}
function RequireAndroid {
    RequireDistro
    if([string]$config.distro -notin @(RegisteredDistros -Running)){throw 'SPARKDROID WSL is stopped. Start it first.'}
    ConnectAdb
    if((Adb @('shell','getprop','sys.boot_completed') 5000) -ne '1'){throw 'WSL Android has not completed boot.'}
}
function StartAndroid {
    $lease=BootLease
    try {
        GuestAction 'start' 540000
        ConnectAdb
        if((Adb @('shell','getprop','sys.boot_completed') 10000) -ne '1'){throw 'Android boot completed in the container but is not reachable via localhost ADB.'}
        Write-Output "SPARKDROID WSL Android is ready at $serial. Requested refresh: $($config.display.refreshHz) Hz. Hardware rendering is not validated."
    } finally {$lease.Dispose()}
}
function CheckApkAbi([string[]]$paths){
    $supported=((Adb @('shell','getprop','ro.product.cpu.abilist') 5000).Split(','))
    $nativeAbis=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($path in $paths){
        $zip=[IO.Compression.ZipFile]::OpenRead($path)
        try{foreach($entry in $zip.Entries){if($entry.FullName -match '^lib/([^/]+)/[^/]+\.so$'){$null=$nativeAbis.Add($Matches[1])}}}finally{$zip.Dispose()}
    }
    if($nativeAbis.Count -gt 0 -and -not @($supported|Where-Object {$nativeAbis.Contains($_)}).Count){
        throw "APK native-library ABI mismatch. APK: $($nativeAbis -join ', '); Android: $($supported -join ', '). Obtain an arm64-v8a APK; this runtime does not translate 32-bit or x86 libraries."
    }
}
try {
    if($config.distro -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$' -or $config.container -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$'){throw 'Invalid isolated distro/container name in WSL config.'}
    if([int]$config.adbPort -lt 1024 -or [int]$config.adbPort -gt 65535){throw 'Invalid WSL ADB port.'}
    $command=Get-Command wsl.exe -ErrorAction SilentlyContinue
    if(-not $command){throw 'wsl.exe is absent. Install WSL 2 before using this backend.'}
    $script:wslExe=$command.Source
    switch($Action){
        'Status' {
            $status=[ordered]@{backend=$config.backend;distro=$config.distro;distroRegistered=$false;distroRunning=$false;androidBootCompleted=$false;adb=$serial;requestedDisplayHz=$config.display.refreshHz;graphicsAccelerationValidated=$false}
            try {
                $status.distroRegistered=[string]$config.distro -in @(RegisteredDistros)
                if($status.distroRegistered){$status.distroRunning=[string]$config.distro -in @(RegisteredDistros -Running)}
                if($status.distroRunning){
                    $status.guest=(GuestAction 'status' 15000|ConvertFrom-Json)
                    if($status.guest.containerRunning){
                        ConnectAdb
                        $status.androidBootCompleted=(Adb @('shell','getprop','sys.boot_completed') 5000) -eq '1'
                        if($status.androidBootCompleted){
                            $sf=Adb @('shell','dumpsys','SurfaceFlinger') 7000
                            $status.actualRenderer=($sf -split "`n"|Where-Object {$_ -match '^GLES:'}|Select-Object -First 1)
                        }
                    }
                }
            }catch{$status.diagnostic=$_.Exception.Message}
            $status|ConvertTo-Json -Depth 8
        }
        'Probe' {GuestAction 'probe' 30000}
        'Provision' {
            $lease=BootLease
            try{GuestAction 'provision' 1800000}finally{$lease.Dispose()}
        }
        'Start' {StartAndroid}
        'Stop' {
            RequireDistro
            if([string]$config.distro -notin @(RegisteredDistros -Running)){Write-Output 'SPARKDROID WSL is already stopped.';break}
            $lease=BootLease
            try {
                GuestAction 'stop' 90000
                $null=InvokeProcess $script:wslExe @('--terminate',[string]$config.distro) 30000
                Write-Output 'Android container stopped and filesystems synced. Only the SPARKDROID WSL distro was terminated; its Android data remains saved.'
            }finally{$lease.Dispose()}
        }
        'Apps' {RequireAndroid;Adb @('shell','pm','list','packages','-3')}
        'Install' {
            RequireAndroid
            if(-not $Apk -or $Apk.Count -eq 0){throw 'Provide -Apk with an APK path or a base/split APK array.'}
            $paths=@($Apk|ForEach-Object {$path=(Resolve-Path -LiteralPath $_).Path;RequireFile $path;if([IO.Path]::GetExtension($path) -ine '.apk'){throw 'Only .apk files are accepted.'};$path})
            CheckApkAbi $paths
            $arguments=if($paths.Count -eq 1){@('install','-r')}else{@('install-multiple','-r')}
            Adb ($arguments+$paths) 180000
        }
        'Launch' {
            if($Package -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'){throw 'A valid Android package id is required.'}
            StartAndroid
            $scrcpy=Full $config.scrcpy;RequireFile $scrcpy
            $server=Full $config.display.server;RequireFile $server
            $width=[int]$config.display.width;$height=[int]$config.display.height;$dpi=[int]$config.display.dpi;$hz=[int]$config.display.refreshHz
            if($width -lt 240 -or $width -gt 3840 -or $height -lt 240 -or $height -gt 3840 -or $dpi -lt 120 -or $dpi -gt 640 -or $hz -lt 30 -or $hz -gt 240){throw 'Invalid display dimensions, DPI, or refresh rate.'}
            $codec=[string]$config.display.videoCodec
            if($codec -notin @('h264','h265','vp8','vp9','av1')){throw 'Invalid video codec.'}
            $name=switch($Package){'com.tencent.mm'{'微信'};'org.videolan.vlc'{'VLC'};default{$Package}}
            $arguments=@('-s',$serial,"--new-display=${width}x${height}/$dpi","--start-app=$Package","--window-title=$name (Android - SPARKDROID WSL)","--max-fps=$hz","--video-codec=$codec",'--print-fps','--video-buffer=0','--require-audio')
            if($config.display.lowComplexity -and $codec -eq 'h264'){$arguments+='--video-codec-options=complexity:int=0,priority:int=0'}
            New-Item -ItemType Directory -Force (Full 'artifacts/logs/wsl')|Out-Null
            $stamp=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
            $outLog=Full "artifacts/logs/wsl/app-$Package-$stamp.out.log"
            $errLog=Full "artifacts/logs/wsl/app-$Package-$stamp.err.log"
            # Start-Process serializes ArgumentList on Windows; quote every complete argument.
            $quoted=($arguments|ForEach-Object {'"'+($_ -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"'}) -join ' '
            $oldAdb=$env:ADB;$oldServer=$env:SCRCPY_SERVER_PATH
            try {
                $env:ADB=Full $config.adb;$env:SCRCPY_SERVER_PATH=$server
                $process=Start-Process -FilePath $scrcpy -ArgumentList $quoted -WorkingDirectory (Split-Path $scrcpy -Parent) -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
            }finally{$env:ADB=$oldAdb;$env:SCRCPY_SERVER_PATH=$oldServer}
            Start-Sleep -Milliseconds 1000
            if($process.HasExited){throw "Application window exited $($process.ExitCode). Inspect $errLog"}
            Write-Output "WSL Android app window opened: PID $($process.Id); requested $hz Hz. Actual FPS is recorded in $outLog"
        }
    }
}catch{[Console]::Error.WriteLine($_.Exception.Message);exit 1}
