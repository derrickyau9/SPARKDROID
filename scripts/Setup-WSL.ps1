#requires -Version 7.2
[CmdletBinding()]
param([ValidateSet('Prepare','Import','Probe')][string]$Action='Prepare')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$config=Get-Content -LiteralPath (Join-Path $root 'config/runtime-wsl.json') -Raw|ConvertFrom-Json
$pin=Get-Content -LiteralPath (Join-Path $root 'upstream/ubuntu-wsl-arm64.lock.json') -Raw|ConvertFrom-Json
$state=Join-Path $root 'state/wsl'
$evidence=Join-Path $root 'artifacts/wsl'
$image=Join-Path $root $pin.localPath
$distro=[string]$config.distro
$marker='SPARKDROID-WSL1'
function Run([string]$exe,[string[]]$arguments,[int]$timeout=30000,[switch]$AllowFailure){
    $psi=[Diagnostics.ProcessStartInfo]::new($exe)
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WorkingDirectory=$root
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $psi.StandardOutputEncoding=[Text.Encoding]::UTF8;$psi.StandardErrorEncoding=[Text.Encoding]::UTF8
    $psi.Environment['WSL_UTF8']='1'
    foreach($argument in $arguments){$psi.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::Start($psi)
    try {
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit($timeout)){
            $process.Kill()
            throw 'Command client timed out. A Linux operation may still be running; inspect the SPARKDROID distro before retrying.'
        }
        $result=[pscustomobject]@{ExitCode=$process.ExitCode;Output=$stdout.GetAwaiter().GetResult().Trim();Error=$stderr.GetAwaiter().GetResult().Trim()}
        if(-not $AllowFailure -and $result.ExitCode -ne 0){throw "$([IO.Path]::GetFileName($exe)) exited $($result.ExitCode): $($result.Output) $($result.Error)"}
        $result
    }finally{$process.Dispose()}
}
function Guest([string[]]$arguments,[int]$timeout=30000,[switch]$AllowFailure){
    Run $script:wslExe (@('--distribution',$distro,'--user','root','--exec')+$arguments) $timeout -AllowFailure:$AllowFailure
}
function SaveJson([string]$name,$value){$value|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $evidence $name) -Encoding utf8}
function PrepareImage {
    if($pin.architecture -ne 'arm64' -or $pin.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $pin.url -notmatch '^https://cdimages\.ubuntu\.com/'){throw 'Invalid official Ubuntu ARM64 image pin.'}
    if(-not(Test-Path -LiteralPath $image)){
        New-Item -ItemType Directory -Force (Split-Path $image -Parent)|Out-Null
        $partial="$image.partial"
        Write-Host 'Downloading the pinned official Ubuntu ARM64 WSL image...'
        $null=Run 'curl.exe' @('--fail','--location','--retry','3','--output',$partial,[string]$pin.url) 1800000
        if((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ine $pin.sha256){throw "Root filesystem checksum mismatch. Preserved for inspection: $partial"}
        Move-Item -LiteralPath $partial -Destination $image
    }
    if((Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash -ine $pin.sha256){throw "Root filesystem checksum mismatch: $image"}
    Write-Host 'Ubuntu ARM64 WSL image checksum verified.'
}
function AssertRebootCompleted {
    $receiptPath=Join-Path $state 'host-setup.json'
    if(Test-Path -LiteralPath $receiptPath){
        $receipt=Get-Content -LiteralPath $receiptPath -Raw|ConvertFrom-Json
        if($receipt.rebootRequired -and -not $receipt.bootTimeUtc){throw 'WSL host setup receipt is missing its boot time. Inspect state/wsl/host-setup.json before proceeding.'}
        $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
        if($receipt.rebootRequired -and $receipt.bootTimeUtc -and [Math]::Abs(($boot-[datetime]$receipt.bootTimeUtc).TotalSeconds) -lt 2){
            throw 'Windows has not restarted since WSL/Virtual Machine Platform installation. Restart Windows, then run this command again. No distro or Android startup was attempted.'
        }
    }
}
function DistroExists {
    $listed=Run $script:wslExe @('--list','--quiet') 30000 -AllowFailure
    if($listed.ExitCode -ne 0){throw "Cannot enumerate WSL distributions: $($listed.Output) $($listed.Error)"}
    $distro -in @($listed.Output -split "`r?`n"|ForEach-Object {$_.Trim()})
}
function AssertOwned {
    $found=Guest @('cat','/etc/sparkdroid-wsl') 30000 -AllowFailure
    if($found.ExitCode -ne 0 -or $found.Output -ne $marker){throw "Distro '$distro' is not marked as owned by SPARKDROID. Preserving it without modification. Choose a separate distro name in config/runtime-wsl.json."}
}
function BootstrapPath { (Guest @('wslpath','-a','-u',(Join-Path $root 'guest/wsl/bootstrap-ubuntu.sh'))).Output }
try {
    if($distro -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$'){throw 'Invalid isolated distribution name.'}
    New-Item -ItemType Directory -Force $state,$evidence|Out-Null
    $script:wslExe=(Get-Command wsl.exe -ErrorAction Stop).Source
    # Shared with Start/Stop/Provision so a configure restart cannot race an app launch.
    $lease=[IO.File]::Open((Join-Path $state 'start.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        if($Action -eq 'Prepare'){
            PrepareImage
            $version=Run $script:wslExe @('--version') 30000 -AllowFailure
            $status=Run $script:wslExe @('--status') 30000 -AllowFailure
            $version.Output|Set-Content -LiteralPath (Join-Path $evidence 'wsl-version.txt') -Encoding utf8
            SaveJson 'host-status.json' ([ordered]@{recordedUtc=[datetime]::UtcNow.ToString('o');imageVerified=$true;distro=$distro;wslVersion=$version.Output;wslStatus=$status.Output;wslStatusExitCode=$status.ExitCode;androidHardwareRenderingVerified=$false})
            Write-Host 'Preparation complete. Import and GPU probing are separate stages; neither Android nor GPU acceleration is established by this step.'
            AssertRebootCompleted
        }elseif($Action -eq 'Import'){
            AssertRebootCompleted
            if(-not(DistroExists)){
                PrepareImage
                $installPath=Join-Path $state $distro
                if((Test-Path -LiteralPath $installPath) -and @(Get-ChildItem -LiteralPath $installPath -Force).Count -gt 0){throw "Distro installation directory is not empty: $installPath. Preserving its contents; inspect the prior import."}
                New-Item -ItemType Directory -Force $installPath|Out-Null
                Write-Host "Importing a separate $distro distro (existing QEMU app data is not migrated)..."
                $null=Run $script:wslExe @('--import',$distro,$installPath,$image,'--version','2') 900000
                # Only a successfully completed import made by this invocation is claimed.
                $null=Guest @('sh','-c','test ! -e /etc/sparkdroid-wsl && printf "%s\n" SPARKDROID-WSL1 > /etc/sparkdroid-wsl')
                [ordered]@{distro=$distro;installPath=$installPath;imageSha256=$pin.sha256;createdUtc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $state "$distro.json") -Encoding utf8
            }
            AssertOwned
            $configured=Guest @('bash',(BootstrapPath),'configure')
            Write-Host $configured.Output
            if($configured.Output -match 'SYSTEMD_CONFIG_CHANGED=1'){
                $null=Run $script:wslExe @('--terminate',$distro) 30000
            }
            Write-Host 'Distro imported. Next: Setup-WSL.ps1 -Action Probe.'
        }else{
            AssertRebootCompleted
            if(-not(DistroExists)){throw 'SPARKDROID is not imported. Run Setup-WSL.ps1 -Action Import first.'}
            AssertOwned
            Write-Host 'Installing Linux graphics diagnostic dependencies in SPARKDROID...'
            $deps=Guest @('bash',(BootstrapPath),'dependencies') 1800000
            $deps.Output|Set-Content -LiteralPath (Join-Path $evidence 'ubuntu-dependencies.log') -Encoding utf8
            $probePath=(Guest @('wslpath','-a','-u',(Join-Path $root 'guest/wsl/gpu-probe.sh'))).Output
            $outputPath=(Guest @('wslpath','-a','-u',$evidence)).Output
            $probe=Guest @('bash',$probePath,$outputPath) 240000 -AllowFailure
            Write-Output $probe.Output
            if($probe.Error){Write-Host $probe.Error}
            if($probe.ExitCode -ne 0){throw "WSL NVIDIA D3D12 pixel test did not pass. Inspect artifacts/wsl/gpu-probe.json; Android GPU rendering remains unverified."}
            Write-Host 'WSL Linux D3D12 pixel test passed. This result does not establish Android GPU acceleration; Android EGL/gralloc and SurfaceFlinger tests are still required.'
        }
    }finally{$lease.Dispose()}
}catch{
    SaveJson 'setup-last-result.json' ([ordered]@{action=$Action;recordedUtc=[datetime]::UtcNow.ToString('o');completed=$false;diagnostic=$_.Exception.Message})
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
SaveJson 'setup-last-result.json' ([ordered]@{action=$Action;recordedUtc=[datetime]::UtcNow.ToString('o');completed=$true})
