#requires -Version 7.2
<#
Build an isolated vendor candidate containing one reviewed ARM64 audio service.
Default is a reviewable plan. -Build -AllowInactiveAvbExperiment creates copies
only; no WSA registration, source replacement, Android boot, or ELF execution.
#>
[CmdletBinding()]
param(
    [switch]$Build,
    [switch]$AllowInactiveAvbExperiment,
    [string]$OutputDirectory,
    [string]$ReportPath
)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source=Join-Path $root 'tools/wsabuilds/arm64-only-candidate/vendor.vhdx'
$replacement=Join-Path $root 'tools/wsabuilds/snickler-inspection/candidates/android.hardware.audio.service'
$qemu=Join-Path $root 'tools/qemu-arm64/clangarm64/bin/qemu-img.exe'
$builder=Join-Path $PSScriptRoot 'Build-WsaAudioFilesystem.py'
$wsl=(Get-Command wsl.exe -ErrorAction Stop).Source
$distro='SPARKDROID-Tools'
$sourceHash='7300d4e7c6fe204210e99c0ea6d10da9103041ff112381d29e3e248badc0155a'
$replacementHash='c7a830d4f62c5643c3a7303d442892dcf4d1899741261fa775eeabeb86805e22'
if(-not $OutputDirectory){$OutputDirectory=Join-Path $root 'tools/wsabuilds/vendor-audio-candidate'}
if(-not $ReportPath){$ReportPath=Join-Path $root $(if($Build){'artifacts/wsa/vendor-audio-candidate-result.json'}else{'artifacts/wsa/vendor-audio-candidate-plan.json'})}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$ReportPath=[IO.Path]::GetFullPath($ReportPath)
$allowedParent=[IO.Path]::GetFullPath((Join-Path $root 'tools/wsabuilds'))
if([IO.Path]::GetDirectoryName($OutputDirectory) -ne $allowedParent){throw 'Candidate output must be a new immediate child of tools/wsabuilds.'}
if(Test-Path -LiteralPath $OutputDirectory){throw 'Candidate directory already exists; refusing reuse or overwrite.'}
if(Test-Path -LiteralPath $ReportPath){throw 'Report already exists; choose a new report path.'}
if($ReportPath.StartsWith([IO.Path]::GetDirectoryName($source)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Report cannot be written into the source directory.'}
foreach($file in @($source,$replacement,$qemu,$builder)){if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Missing prerequisite: $file"}}
if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ine $sourceHash){throw 'Source vendor SHA256 differs from the validated ARM64-only candidate.'}
if((Get-FileHash -LiteralPath $replacement -Algorithm SHA256).Hash -ine $replacementHash -or (Get-Item -LiteralPath $replacement).Length -ne 19472){throw 'Replacement hash/length precondition failed.'}

function Run([string]$exe,[string[]]$arguments){
    $psi=[Diagnostics.ProcessStartInfo]::new($exe)
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.WorkingDirectory=$root
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $psi.StandardOutputEncoding=[Text.Encoding]::UTF8;$psi.StandardErrorEncoding=[Text.Encoding]::UTF8
    $psi.Environment['WSL_UTF8']='1'
    foreach($argument in $arguments){$psi.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::Start($psi)
    try{
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $result=[pscustomobject]@{exitCode=$process.ExitCode;output=$stdout.GetAwaiter().GetResult().Trim();error=$stderr.GetAwaiter().GetResult().Trim()}
        if($result.exitCode -ne 0){throw "$([IO.Path]::GetFileName($exe)) exited $($result.exitCode): $($result.output) $($result.error)"}
        $result
    }finally{$process.Dispose()}
}
function Guest([string[]]$arguments){Run $wsl (@('--distribution',$distro,'--user','root','--exec')+$arguments)}
function LinuxPath([string]$path){(Guest @('/usr/bin/wslpath','-a','-u',$path)).output}

$report=[ordered]@{
    schemaVersion=1;mode=$(if($Build){'candidate'}else{'plan'});success=$false
    source='arm64-only-candidate/vendor.vhdx';sourceSha256=$sourceHash
    replacement='snickler-inspection/candidates/android.hardware.audio.service';replacementSha256=$replacementHash
    replacementBytes=19472;target='/vendor/bin/hw/android.hardware.audio.service'
    sourceProvenance='artifacts/wsa/snickler-audio-comparison.json'
    workflow=@('Convert source VHDX to a new raw copy.','Validate raw ext4; mount read-only, noexec, nodev, nosuid for full-tree content and metadata snapshot.',
        'Grow the raw copy to 256MiB; resize2fs; e2fsck -E unshare_blocks; confirm shared-blocks flag cleared and filesystem clean.',
        'Mount only the copy with noexec, nodev, nosuid; replace audio bytes via r+b preserving inode, uid, gid, mode and every xattr.',
        'Compare all filesystem paths, contents and metadata, allowing only the approved audio content/size change; unmount and fsck.',
        'Convert the candidate raw to new VHDX, convert it back to raw and require byte-identical roundtrip; preserve source SHA256.')
    inactiveAvbExperiment=$true
    avbNotice='Filesystem growth can overwrite the former AVB/hash-tree trailer. Candidate does not retain valid AVB data. No runtime verification setting is changed; source VHDX stays intact.'
    replacementExecuted=$false;runtimeInstalledOrStarted=$false
}
try{
    if($Build){
        if(-not $AllowInactiveAvbExperiment){throw 'This candidate requires -AllowInactiveAvbExperiment because growing ext4 invalidates the inactive AVB trailer.'}
        $registrations=@(Get-ChildItem -LiteralPath 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Lxss'|ForEach-Object {Get-ItemProperty -LiteralPath $_.PSPath}|Where-Object DistributionName -eq $distro)
        $expectedBase=[IO.Path]::GetFullPath((Join-Path $root 'state/wsa-tools'))
        if($registrations.Count -ne 1 -or [IO.Path]::GetFullPath([string]$registrations[0].BasePath) -ine $expectedBase){throw 'Tools distro is not registered at this workspace state/wsa-tools; refusing mutation.'}
        $report.distroOwnershipVerifiedByRegistry=$true
        $null=New-Item -ItemType Directory -Path $OutputDirectory
        $raw=Join-Path $OutputDirectory 'vendor.raw'
        $candidate=Join-Path $OutputDirectory 'vendor.vhdx'
        Write-Host 'Converting the preserved vendor image into a new raw candidate...'
        $converted=Run $qemu @('convert','-f','vhdx','-O','raw',$source,$raw)
        $token=[Guid]::NewGuid().ToString('N')
        [ordered]@{token=$token;rawSha256=(Get-FileHash -LiteralPath $raw -Algorithm SHA256).Hash.ToLowerInvariant();allowInactiveAvbExperiment=$true;distroOwnershipVerifiedByRegistry=$true;toolsDistro=$distro}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $OutputDirectory 'build-request.json') -Encoding utf8NoBOM
        Write-Host 'Preparing and auditing the isolated ext4 candidate in SPARKDROID-Tools...'
        $built=Guest @('/usr/bin/python3',(LinuxPath $builder),'--directory',(LinuxPath $OutputDirectory),'--replacement',(LinuxPath $replacement),'--token',$token)
        $built.output|Write-Host
        $fs=Get-Content -LiteralPath (Join-Path $OutputDirectory 'filesystem-build.json') -Raw|ConvertFrom-Json
        if(-not $fs.success){throw 'Filesystem builder did not report success.'}
        if((Get-FileHash -LiteralPath $raw -Algorithm SHA256).Hash -ine $fs.rawSha256){throw 'Candidate raw changed after filesystem validation.'}
        Write-Host 'Converting verified raw to VHDX and checking a byte-identical roundtrip...'
        $null=Run $qemu @('convert','-f','raw','-O','vhdx','-o','subformat=dynamic',$raw,$candidate)
        $roundtrip=Join-Path $OutputDirectory 'roundtrip.raw'
        $null=Run $qemu @('convert','-f','vhdx','-O','raw',$candidate,$roundtrip)
        if((Get-FileHash -LiteralPath $roundtrip -Algorithm SHA256).Hash -ine $fs.rawSha256){throw 'VHDX roundtrip differs from validated raw.'}
        $report.filesystemBuild=$fs
        $report.candidateSha256=(Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
        $report.candidateBytes=(Get-Item -LiteralPath $candidate).Length
        $report.rawRoundtripSha256=$fs.rawSha256
        $report.qemuInfo=(Run $qemu @('info','--output=json',$candidate)).output|ConvertFrom-Json
    }
    if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ine $sourceHash){throw 'Preserved source hash changed.'}
    if((Get-FileHash -LiteralPath $replacement -Algorithm SHA256).Hash -ine $replacementHash){throw 'Replacement source changed.'}
    $report.sourceHashesUnchanged=$true
    $report.success=$true
}catch{
    $report.error=$_.Exception.Message
    throw
}finally{
    $null=New-Item -ItemType Directory -Force -Path (Split-Path $ReportPath -Parent)
    $report|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $ReportPath -Encoding utf8NoBOM
}
Write-Host "Ready: $ReportPath"
