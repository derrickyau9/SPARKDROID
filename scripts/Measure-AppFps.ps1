[CmdletBinding()]
param(
    [string]$RuntimeRoot=(Join-Path (Split-Path $PSScriptRoot -Parent) 'dist/SPARKDROID-0.1.0-win-arm64'),
    [ValidateRange(10,120)][int]$Seconds=16,
    [ValidateSet('h264','vp8')][string]$Codec='h264',
    [ValidateRange(240,1920)][int]$Width=720,
    [ValidateRange(240,2560)][int]$Height=1280,
    [ValidateRange(30,240)][int]$TargetHz=120,
    [switch]$LowComplexity,
    [switch]$WithAudio
)
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$out=Join-Path $project ('artifacts/refresh/'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')+"-$Codec-${Width}x${Height}")
New-Item -ItemType Directory -Force $out|Out-Null
$config=Get-Content "$RuntimeRoot/config/runtime.json" -Raw|ConvertFrom-Json
$psi=[Diagnostics.ProcessStartInfo]::new((Join-Path $RuntimeRoot $config.scrcpy))
$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
$psi.Environment['ADB']=Join-Path $RuntimeRoot $config.adb
$psi.Environment['SCRCPY_SERVER_PATH']=Join-Path $RuntimeRoot $config.display.server
$args=@('-s',"127.0.0.1:$($config.adbPort)","--new-display=${Width}x${Height}/240",'--start-app=+dev.sparkdroid.frameprobe',"--max-fps=$TargetHz",'--print-fps','--video-buffer=0','--no-audio',"--video-codec=$Codec","--time-limit=$Seconds",'--window-title=SPARKDROID FPS measurement')
if($LowComplexity){$args+='--video-codec-options=complexity:int=0,priority:int=0'}
if($WithAudio){$args=@($args|Where-Object {$_ -ne '--no-audio'});$args+='--require-audio'}
foreach($arg in $args){$psi.ArgumentList.Add($arg)}
$p=[Diagnostics.Process]::Start($psi);$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
if(-not $p.WaitForExit(($Seconds+30)*1000)){$p.Kill();throw 'Frame test timed out'}
$a=$stdout.GetAwaiter().GetResult();$b=$stderr.GetAwaiter().GetResult()
$a|Set-Content "$out/client-stdout.log";$b|Set-Content "$out/client-stderr.log"
if($p.ExitCode -ne 0){throw "Frame test failed $($p.ExitCode); see $out"}
$matches=[regex]::Matches($a+"`n"+$b,'(?m)INFO:\s+(\d+) fps(?: \(\+(\d+) frames skipped\))?')
$all=@($matches|ForEach-Object {[int]$_.Groups[1].Value})
$steady=@($all|Select-Object -Skip 2)
if($steady.Count -lt 5){throw 'Too few real FPS samples'}
$measure=$steady|Measure-Object -Average -Minimum -Maximum
$r=[ordered]@{capturedUtc=[DateTime]::UtcNow.ToString('o');requestedHz=$TargetHz;codec=$Codec;width=$Width;height=$Height;lowComplexity=[bool]$LowComplexity;audioEnabled=[bool]$WithAudio;warmupSamplesDiscarded=2;samples=$all;steadyMeanFps=[math]::Round($measure.Average,2);steadyMinimumFps=$measure.Minimum;steadyMaximumFps=$measure.Maximum;arguments=$args;note='scrcpy Windows client FPS on a continuously animated test app. Android draw callback rate and display mode are separate metrics.'}
$r|ConvertTo-Json -Depth 6|Tee-Object -FilePath "$out/measurement.json"
& (Join-Path $RuntimeRoot $config.adb) -s "127.0.0.1:$($config.adbPort)" shell dumpsys display > "$out/android-display.txt"
& (Join-Path $RuntimeRoot $config.adb) -s "127.0.0.1:$($config.adbPort)" shell logcat -d -s SPARKDROID_FRAME_TEST:I '*:S' | Select-Object -Last 20 > "$out/android-callbacks.txt"
