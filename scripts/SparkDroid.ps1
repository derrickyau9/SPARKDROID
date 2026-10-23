[CmdletBinding()]
param(
    [ValidateSet('Status','Start','Stop','Suspend','Resume','Install','InstallSplit','Apps','Launch','Uninstall','AdbShell','Benchmark','GuestShell','SetGraphics','SetDisplay','ReclaimMemory','PushShared','PullShared','EmergencyStop')][string]$Action='Status',
    [string[]]$Apk,
    [string]$Package,
    [ValidateSet('Performance','Balanced','UltraEfficient')][string]$Profile,
    [ValidateSet('Software','Virgl')][string]$Graphics,
    [ValidateSet('Smooth','HighRefresh')][string]$DisplayMode,
    [ValidateRange(2048,32768)][int]$MemoryMiB=3072,
    [int]$Seconds=30,
    [switch]$WaitForAndroid
)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$configPath=Join-Path $root 'config/runtime.json'
$config=Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json
$stateFile=Join-Path $root 'state/runtime.json'
function Full([string]$path){Join-Path $root $path}
function RequireFile([string]$path){if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Required file missing: $path"}}
function Run([string]$exe,[string[]]$arguments){
    $psi=[Diagnostics.ProcessStartInfo]::new($exe)
    $psi.UseShellExecute=$false
    $psi.WorkingDirectory=$root
    foreach($arg in $arguments){$psi.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::Start($psi)
    $p.WaitForExit()
    if($p.ExitCode -ne 0){throw "$([IO.Path]::GetFileName($exe)) exited $($p.ExitCode)"}
}
function Capture([string]$exe,[string[]]$arguments,[int]$timeout=30000){
    $psi=[Diagnostics.ProcessStartInfo]::new($exe)
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.WorkingDirectory=$root
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach($arg in $arguments){$psi.ArgumentList.Add($arg)}
    $p=[Diagnostics.Process]::Start($psi)
    $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
    if(-not $p.WaitForExit($timeout)){$p.Kill($true);throw "Command timed out: $exe"}
    $out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult()
    if($p.ExitCode -ne 0){throw "$([IO.Path]::GetFileName($exe)) exit $($p.ExitCode): $err $out"}
    return $out.Trim()
}
function VmProcess {
    if(-not(Test-Path -LiteralPath $stateFile)){return $null}
    $saved=Get-Content -LiteralPath $stateFile -Raw|ConvertFrom-Json
    $p=Get-Process -Id $saved.pid -ErrorAction SilentlyContinue
    if(-not $p){return $null}
    if($p.Path -ne (Full $config.qemu) -or $p.StartTime.ToUniversalTime().Ticks -ne $saved.startTicks){throw 'Runtime PID identity mismatch. Refusing to control an unrelated process.'}
    return $p
}
function Qmp([string]$command,[hashtable]$arguments=@{}){
    $vm=VmProcess
    if(-not $vm){throw 'SPARKDROID VM is not running'}
    $client=[Net.Sockets.TcpClient]::new()
    try {
        if(-not $client.ConnectAsync('127.0.0.1',[int]$config.qmpPort).Wait(3000)){throw 'QMP connection timed out'}
        $stream=$client.GetStream();$stream.ReadTimeout=5000;$stream.WriteTimeout=5000
        $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$false,1024,$true)
        $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false),1024,$true);$writer.AutoFlush=$true
        $greeting=$reader.ReadLine()|ConvertFrom-Json
        if(-not $greeting.QMP){throw 'Invalid QMP greeting'}
        foreach($request in @(@{execute='qmp_capabilities';id='cap'},@{execute=$command;arguments=$arguments;id='request'})){
            $writer.WriteLine(($request|ConvertTo-Json -Depth 8 -Compress))
            do {$line=$reader.ReadLine();if($null -eq $line){throw 'QMP closed connection'};$reply=$line|ConvertFrom-Json}while($reply.id -ne $request.id)
            if($reply.error){throw ($reply.error|ConvertTo-Json -Compress)}
        }
        return $reply.return
    } finally {$client.Dispose()}
}
function Adb([string[]]$arguments,[int]$timeout=30000){
    $exe=Full $config.adb;RequireFile $exe
    return Capture $exe (@('-s',"127.0.0.1:$($config.adbPort)")+$arguments) $timeout
}
function RequireAndroid {
    if(-not(VmProcess)){throw 'Start the runtime first'}
    $null=Capture (Full $config.adb) @('connect',"127.0.0.1:$($config.adbPort)") 5000
    if((Adb @('shell','getprop','sys.boot_completed') 5000) -ne '1'){throw 'Android has not completed boot. Inspect artifacts/logs and guest provisioning log.'}
}
function KnownHostsOption {
    'UserKnownHostsFile="'+((Full 'state/known_hosts') -replace '\\','/')+'"'
}
function SshArgs {
    @('-p',"$($config.sshPort)",'-i',(Full 'state/ssh_key'),'-o','BatchMode=yes','-o','ConnectTimeout=5','-o','StrictHostKeyChecking=accept-new','-o',(KnownHostsOption),'spark@127.0.0.1')
}
function ValidPackage {
    if($Package -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'){throw 'A valid Android package id is required'}
}
function EnsureAndroid {
    if(-not(VmProcess)){
        & $PSCommandPath -Action Start -WaitForAndroid
        if(-not $?){throw 'Android runtime startup failed'}
    }
    if((Qmp 'query-status').status -eq 'paused'){$null=Qmp 'cont'}
    $wait=[Diagnostics.Stopwatch]::StartNew()
    while($wait.Elapsed.TotalSeconds -lt 900){
        if(-not(VmProcess)){throw 'Android VM exited during startup'}
        try{RequireAndroid;return}catch{Start-Sleep -Seconds 2}
    }
    throw 'Android readiness timeout; see runtime logs'
}
function DisplayRefresh {
    $target=if($config.display){[int]$config.display.refreshHz}else{[int]$config.profiles.($config.profile).fps}
    if($config.display.matchWindows){
        if(-not('SparkDroidDesktopRate' -as [type])){
            Add-Type 'using System; using System.Runtime.InteropServices; public static class SparkDroidDesktopRate { [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr w); [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr w,IntPtr dc); [DllImport("gdi32.dll")] static extern int GetDeviceCaps(IntPtr dc,int index); public static int Hz(){IntPtr dc=GetDC(IntPtr.Zero);try{return GetDeviceCaps(dc,116);}finally{ReleaseDC(IntPtr.Zero,dc);}} }'
        }
        $hostHz=[SparkDroidDesktopRate]::Hz()
        if($hostHz -ge 30 -and $hostHz -le 240){$target=$hostHz}
    }
    if($target -lt 30 -or $target -gt 240){throw 'Display refresh must be 30..240 Hz'}
    return $target
}
function BootLease {
    New-Item -ItemType Directory -Force (Full 'state')|Out-Null
    $until=[DateTime]::UtcNow.AddMinutes(15)
    do {
        try{return [IO.File]::Open((Full 'state/start.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
        catch [IO.IOException] {Start-Sleep -Milliseconds 250}
    }while([DateTime]::UtcNow -lt $until)
    throw 'Another Android startup did not release its startup lock within 15 minutes'
}
try {
    switch($Action){
        'Status' {
            $p=VmProcess
            $status=[ordered]@{backend=$config.backend;vmRunning=[bool]$p;profile=$config.profile;graphics=$config.graphics;graphicsAccelerationValidated=$false;androidBootCompleted=$false;adb="127.0.0.1:$($config.adbPort)";logDirectory=(Full 'artifacts/logs')}
            $status.requestedDisplayHz=DisplayRefresh
            if($p){$status.pid=$p.Id;$status.qmp=Qmp 'query-status';if($status.qmp.status -eq 'paused'){$status.androidBootCompleted=$null;$status.androidStatus='Guest paused; Android readiness is not queried.'}else{try{
                $status.androidBootCompleted=((Adb @('shell','getprop','sys.boot_completed') 3000) -eq '1')
                if($status.androidBootCompleted){
                    $sf=Adb @('shell','dumpsys','SurfaceFlinger') 5000
                    $renderer=($sf -split "`n"|Where-Object {$_ -match '^GLES:'}|Select-Object -First 1).Trim()
                    $status.actualRenderer=$renderer
                    $status.hardwareRendererReported=($renderer -match 'virgl.*NVIDIA' -and $renderer -notmatch 'SwiftShader|llvmpipe|softpipe')
                    # A renderer string alone is insufficient: the current VirGL
                    # experiment reports NVIDIA while producing black frames.
                    $evidencePath=Full 'artifacts/acceptance/graphics.json'
                    if(Test-Path $evidencePath){$evidence=Get-Content $evidencePath -Raw|ConvertFrom-Json;$status.graphicsAccelerationValidated=($status.hardwareRendererReported -and $evidence.androidHardwareFramesValidated -eq $true -and $evidence.renderer -eq $renderer)}
                }
            }catch{$status.androidStatus=$_.Exception.Message}}}
            $status|ConvertTo-Json -Depth 8
        }
        'Start' {
            $lease=BootLease
            try {
            if(VmProcess){Write-Output 'SPARKDROID VM is already running';break}
            foreach($path in @($config.qemu,$config.qemuImg,$config.firmware)){RequireFile (Full $path)}
            if(-not(Test-Path (Full $config.seed)) -or -not(Test-Path (Full 'state/ssh_key'))){& (Join-Path $PSScriptRoot 'Prepare-Guest.ps1');if(-not $?){throw 'Guest seed preparation failed'}}
            RequireFile (Full $config.seed)
            if(-not(Test-Path (Full $config.disk))){RequireFile (Full $config.baseImage)}
            if(-not $Profile){$Profile=$config.profile}
            if(-not $Graphics){$Graphics=if($config.graphics -eq 'virgl-experimental'){'Virgl'}else{'Software'}}
            $policy=$config.profiles.$Profile
            New-Item -ItemType Directory -Force (Full 'state'),(Full 'artifacts/logs'),(Full 'artifacts/benchmarks'),(Full 'shared')|Out-Null
            if(-not(Test-Path (Full $config.disk))){
                Run (Full $config.qemuImg) @('create','-f','qcow2','-F','qcow2','-b',(Full $config.baseImage),(Full $config.disk))
                Run (Full $config.qemuImg) @('resize',(Full $config.disk),'48G')
            }
            foreach($port in @($config.qmpPort,$config.sshPort,$config.adbPort)){
                $test=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,[int]$port)
                try{$test.Start()}finally{$test.Stop()}
            }
            $stamp=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
            $args=@('-name','SPARKDROID','-machine','virt,gic-version=3','-accel','whpx','-cpu','host','-smp',"$($policy.cpus)",'-m',"$($policy.memoryMiB)",'-bios',(Full $config.firmware),'-display','none',
                '-drive',"file=$(Full $config.disk),if=virtio,format=qcow2,discard=unmap",
                '-drive',"file=$(Full $config.seed),if=none,id=seed,format=raw,media=cdrom,readonly=on",'-device','virtio-scsi-pci','-device','scsi-cd,drive=seed',
                '-netdev',"user,id=net0,hostfwd=tcp:127.0.0.1:$($config.sshPort)-:22,hostfwd=tcp:127.0.0.1:$($config.adbPort)-:5555",'-device','virtio-net-pci,netdev=net0',
                '-device','virtio-rng-pci',
                '-qmp',"tcp:127.0.0.1:$($config.qmpPort),server=on,wait=off",'-serial',"file:$(Full "artifacts/logs/serial-$stamp.log")",'-monitor','none')
            if($Graphics -eq 'Virgl'){
                $args[$args.IndexOf('-display')+1]='egl-headless'
                $args+=@('-device','virtio-gpu-gl-pci')
            }
            # Start-Process serializes ArgumentList; quote each complete argument for Windows.
            $quoted=($args|ForEach-Object {'"'+($_ -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"'}) -join ' '
            $bootTimer=[Diagnostics.Stopwatch]::StartNew()
            $p=Start-Process -FilePath (Full $config.qemu) -ArgumentList $quoted -WorkingDirectory $root -WindowStyle Hidden -PassThru -RedirectStandardOutput (Full "artifacts/logs/qemu-$stamp.out.log") -RedirectStandardError (Full "artifacts/logs/qemu-$stamp.err.log")
            Start-Sleep -Milliseconds 1200
            if($p.HasExited){throw "QEMU exited $($p.ExitCode). See artifacts/logs/qemu-$stamp.err.log. No CPU emulator fallback was selected."}
            @{pid=$p.Id;startTicks=$p.StartTime.ToUniversalTime().Ticks;startedUtc=[DateTime]::UtcNow.ToString('o');profile=$Profile;serial="artifacts/logs/serial-$stamp.log";arguments=$args}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $stateFile
            $config.profile=$Profile;$config.graphics=if($Graphics -eq 'Virgl'){'virgl-experimental'}else{'software-explicit'};$config|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $configPath
            Write-Output "VM started with native ARM64 WHPX, $($policy.cpus) vCPUs, $($policy.memoryMiB) MiB. VM graphics: $Graphics. Android renderer is checked separately with Status; first boot provisioning may take several minutes."
            Qmp 'query-status'|ConvertTo-Json
            if($WaitForAndroid){
                $watch=[Diagnostics.Stopwatch]::StartNew();$ready=$false
                while($watch.Elapsed.TotalSeconds -lt 900){if(-not(VmProcess)){throw 'VM exited while waiting for Android; inspect QEMU logs'};try{RequireAndroid;$ready=$true;break}catch{Start-Sleep -Seconds 3}}
                if(-not $ready){throw 'Android did not become ready within 900 seconds; inspect guest logs'}
                @{bootWaitSeconds=$watch.Elapsed.TotalSeconds;vmStartToAndroidReadySeconds=$bootTimer.Elapsed.TotalSeconds;pollIntervalSeconds=3;measuredUtc=[DateTime]::UtcNow.ToString('o');note='Readiness includes provisioning when first boot. Poll quantization is up to 3 seconds plus ADB command time.'}|ConvertTo-Json|Set-Content (Full "artifacts/benchmarks/boot-$stamp.json")
                Write-Output 'Android boot completed.'
            }
            }finally{$lease.Dispose()}
        }
        'Stop' {
            $p=VmProcess
            if(-not $p){Write-Output 'Runtime is already stopped';break}
            if((Qmp 'query-status').status -eq 'paused'){$null=Qmp 'cont'}
            $shutdown=Capture (Get-Command ssh.exe).Source ((SshArgs)+@('sudo systemctl poweroff')) 15000
            if(-not $p.WaitForExit(60000)){throw 'Guest has not shut down within 60 seconds. VM remains running; no forced termination was performed.'}
            Remove-Item -LiteralPath $stateFile -ErrorAction SilentlyContinue
            Write-Output 'Guest shut down cleanly and VM exited.'
        }
        'Suspend' {Qmp 'stop'|ConvertTo-Json;Write-Output 'Guest execution paused in memory. Background services and notifications pause too; this is not a low-memory saved state.'}
        'Resume' {Qmp 'cont'|ConvertTo-Json;Write-Output 'Guest execution resumed.'}
        'ReclaimMemory' {
            throw 'Dynamic memory reclamation is disabled: the Windows WHPX balloon experiment made the guest unresponsive. Select a fixed startup profile instead. See artifacts/acceptance/memory-balloon.json.'
        }
        'EmergencyStop' {
            $p=VmProcess
            if(-not $p){Write-Output 'Runtime is already stopped';break}
            Write-Warning 'Emergency VM termination requested. Android/Linux cannot flush their filesystems; this is an unclean guest shutdown.'
            $stamp=[DateTime]::UtcNow.ToString('o')
            Qmp 'quit'|ConvertTo-Json
            if(-not $p.WaitForExit(15000)){throw 'QMP quit did not terminate the identified VM. No unrelated process was stopped.'}
            @{timeUtc=$stamp;cleanGuestShutdown=$false;reason='Explicit EmergencyStop requested';pid=$p.Id}|ConvertTo-Json|Set-Content (Full 'artifacts/acceptance/last-emergency-stop.json')
            Remove-Item -LiteralPath $stateFile -ErrorAction SilentlyContinue
        }
        'SetGraphics' {
            if(-not $Graphics){throw 'Provide -Graphics Software or Virgl'}
            if($Graphics -eq 'Virgl' -and $config.graphics -ne 'virgl-experimental'){throw 'Restart VM with Start -Graphics Virgl before selecting Android hardware rendering'}
            $mode=if($Graphics -eq 'Virgl'){'host'}else{'guest'}
            Run (Get-Command scp.exe).Source @('-P',"$($config.sshPort)",'-i',(Full 'state/ssh_key'),'-o','BatchMode=yes','-o','StrictHostKeyChecking=accept-new','-o',(KnownHostsOption),(Full 'guest/set-graphics.sh'),'spark@127.0.0.1:/home/spark/set-graphics.sh')
            Capture (Get-Command ssh.exe).Source ((SshArgs)+@("sudo env SPARKDROID_GPU_MODE=$mode bash /home/spark/set-graphics.sh")) 210000
        }
        'SetDisplay' {
            if($DisplayMode){
                $high=$DisplayMode -eq 'HighRefresh'
                $config.display.refreshHz=if($high){120}else{60}
                $config.display.matchWindows=$high
                $config.display.width=if($high){720}else{540}
                $config.display.height=if($high){1280}else{960}
                $config.display.dpi=if($high){240}else{180}
                $config|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $configPath
            }
            EnsureAndroid
            $hz=DisplayRefresh
            Run (Get-Command scp.exe).Source @('-P',"$($config.sshPort)",'-i',(Full 'state/ssh_key'),'-o','BatchMode=yes','-o','StrictHostKeyChecking=accept-new','-o',(KnownHostsOption),(Full 'guest/set-display.sh'),'spark@127.0.0.1:/home/spark/set-display.sh')
            Capture (Get-Command ssh.exe).Source ((SshArgs)+@("sudo bash /home/spark/set-display.sh $hz")) 240000
        }
        'Install' {
            RequireAndroid
            if(-not $Apk -or $Apk.Count -eq 0){throw 'Provide -Apk with one APK or an array of base and split APK paths'}
            $paths=@($Apk|ForEach-Object {$path=(Resolve-Path -LiteralPath $_).Path;if([IO.Path]::GetExtension($path) -ne '.apk'){throw 'Only .apk files are supported; extract split archives first'};$path})
            $cmd=if($paths.Count -eq 1){@('install','-r')}else{@('install-multiple','-r')}
            Adb ($cmd+$paths) 180000
        }
        'InstallSplit' {
            if($Apk.Count -ne 1){throw 'Provide -Apk with one JSON manifest containing an array of APK paths'}
            $paths=@(Get-Content -LiteralPath $Apk[0] -Raw|ConvertFrom-Json)
            if($paths.Count -lt 2){throw 'A split installation requires a base APK and at least one split'}
            & $PSCommandPath -Action Install -Apk $paths
            if(-not $?){throw 'Split APK installation failed'}
        }
        'PushShared' {
            RequireAndroid
            New-Item -ItemType Directory -Force (Full 'shared')|Out-Null
            $null=Adb @('shell','mkdir','-p','/sdcard/Download/SPARKDROID')
            Adb @('push',((Full 'shared')+[IO.Path]::DirectorySeparatorChar+'.'),'/sdcard/Download/SPARKDROID/') 180000
            Write-Output 'Host shared files copied to Android Download/SPARKDROID. Transfers are explicit; this is not a live filesystem mount.'
        }
        'PullShared' {
            RequireAndroid
            $destination=Full 'shared/from-android'
            New-Item -ItemType Directory -Force $destination|Out-Null
            Adb @('pull','/sdcard/Download/SPARKDROID/.',$destination) 180000
            Write-Output "Android shared files copied to $destination"
        }
        'Apps' {RequireAndroid;Adb @('shell','pm','list','packages','-3')}
        'Uninstall' {ValidPackage;RequireAndroid;Adb @('uninstall',$Package)}
        'Launch' {
            ValidPackage;EnsureAndroid;RequireFile (Full $config.scrcpy)
            $env:ADB=Full $config.adb
            $fps=DisplayRefresh
            $codec=if($config.display.videoCodec){[string]$config.display.videoCodec}else{'h264'}
            if($codec -notin @('h264','h265','vp8','vp9','av1')){throw 'Invalid video codec'}
            if($config.display.server){$server=Full $config.display.server;RequireFile $server;$env:SCRCPY_SERVER_PATH=$server}
            New-Item -ItemType Directory -Force (Full 'artifacts/logs')|Out-Null
            Write-Output "Opening $Package in its own window at requested $fps Hz. Actual FPS depends on application workload."
            $width=if($config.display.width){[int]$config.display.width}else{720}
            $height=if($config.display.height){[int]$config.display.height}else{1280}
            $dpi=if($config.display.dpi){[int]$config.display.dpi}else{240}
            if($width -lt 240 -or $width -gt 3840 -or $height -lt 240 -or $height -gt 3840 -or $dpi -lt 120 -or $dpi -gt 640){throw 'Invalid application window dimensions or DPI'}
            $name=switch($Package){'com.tencent.mm'{'微信'};'org.videolan.vlc'{'VLC'};default{$Package}}
            $args=@('-s',"127.0.0.1:$($config.adbPort)","--new-display=${width}x${height}/$dpi","--start-app=$Package","--window-title=$name (Android - SPARKDROID)","--max-fps=$fps","--video-codec=$codec",'--print-fps','--video-buffer=0','--require-audio')
            if($config.display.lowComplexity -and $codec -eq 'h264'){$args+='--video-codec-options=complexity:int=0,priority:int=0'}
            $quoted=($args|ForEach-Object {'"'+($_ -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"'}) -join ' '
            $stamp=[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
            $p=Start-Process -FilePath (Full $config.scrcpy) -ArgumentList $quoted -WorkingDirectory (Full 'tools/scrcpy') -WindowStyle Hidden -PassThru -RedirectStandardOutput (Full "artifacts/logs/app-$Package-$stamp.out.log") -RedirectStandardError (Full "artifacts/logs/app-$Package-$stamp.err.log")
            Start-Sleep -Milliseconds 750
            if($p.HasExited){throw "Application window exited $($p.ExitCode). See artifacts/logs/app-$Package-$stamp.err.log"}
            Write-Output "Application window process: $($p.Id)"
        }
        'AdbShell' {RequireAndroid;Run (Full $config.adb) @('-s',"127.0.0.1:$($config.adbPort)",'shell')}
        'GuestShell' {Run (Get-Command ssh.exe).Source (SshArgs)}
        'Benchmark' {& (Join-Path $PSScriptRoot 'Measure-Runtime.ps1') -Seconds $Seconds -Package $Package;if(-not $?){throw 'Benchmark failed'}}
    }
}catch{[Console]::Error.WriteLine($_.Exception.Message);exit 1}
