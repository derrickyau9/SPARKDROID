[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=Join-Path $root 'tools/scrcpy-source'
$expected='a60891aea193d92e7e5c3942700eca63f9d19a5f'
if((& git -C $source rev-parse HEAD).Trim() -ne $expected){throw 'Unexpected scrcpy source revision'}
$build=Join-Path $root 'tools/scrcpy-refresh-build'
$java=Join-Path $root 'tools/jdk/bin'
$platform=Join-Path $root 'tools/android-sdk/android-36'
$bt=Join-Path $root 'tools/android-sdk/android-16'
foreach($dir in @('src','gen','classes','dex')){New-Item -ItemType Directory -Force (Join-Path $build $dir)|Out-Null}
Copy-Item "$source/server/src/main/java/*" "$build/src" -Recurse -Force
function ReplaceExact([string]$path,[string]$old,[string]$new){
    $text=[IO.File]::ReadAllText($path)
    if(-not $text.Contains($old)){throw "Patch context absent: $path"}
    [IO.File]::WriteAllText($path,$text.Replace($old,$new),[Text.UTF8Encoding]::new($false))
}
$capture=Join-Path $build 'src/com/genymobile/scrcpy/video/NewDisplayCapture.java'
ReplaceExact $capture 'private final NewDisplay newDisplay;' "private final NewDisplay newDisplay;`n    private final float requestedRefreshRate;"
ReplaceExact $capture 'this.newDisplay = options.getNewDisplay();' "this.newDisplay = options.getNewDisplay();`n        this.requestedRefreshRate = options.getMaxFps();"
ReplaceExact $capture '.createNewVirtualDisplay("scrcpy", displaySize.getWidth(), displaySize.getHeight(), dpi, surface, flags);' '.createNewVirtualDisplay("scrcpy", displaySize.getWidth(), displaySize.getHeight(), dpi, surface, flags, requestedRefreshRate);'
ReplaceExact $capture 'setCurrentVirtualDisplay(vd); // used for client resize' 'Ln.i("SPARKDROID requested virtual refresh: " + requestedRefreshRate + " Hz"); setCurrentVirtualDisplay(vd); // used for client resize'
$manager=Join-Path $build 'src/com/genymobile/scrcpy/wrappers/DisplayManager.java'
ReplaceExact $manager 'import android.hardware.display.VirtualDisplay;' "import android.hardware.display.VirtualDisplay;`nimport android.hardware.display.VirtualDisplayConfig;`nimport android.os.Build;"
ReplaceExact $manager 'int dpi, Surface surface, int flags) throws Exception {' 'int dpi, Surface surface, int flags, float refreshRate) throws Exception {'
ReplaceExact $manager 'return dm.createVirtualDisplay(name, width, height, dpi, surface, flags);' @'
if (Build.VERSION.SDK_INT >= 34) {
            VirtualDisplayConfig config = new VirtualDisplayConfig.Builder(name, width, height, dpi)
                    .setFlags(flags).setSurface(surface).setRequestedRefreshRate(refreshRate).build();
            return dm.createVirtualDisplay(config);
        }
        if (refreshRate > 60) {
            throw new UnsupportedOperationException("SPARKDROID high-refresh displays require Android 14+");
        }
        return dm.createVirtualDisplay(name, width, height, dpi, surface, flags);
'@
[IO.File]::WriteAllText((Join-Path $build 'src/com/genymobile/scrcpy/BuildConfig.java'),'package com.genymobile.scrcpy; public final class BuildConfig { public static final boolean DEBUG=false; public static final String VERSION_NAME="5.0.1"; }',[Text.UTF8Encoding]::new($false))
Push-Location "$source/server/src/main/aidl"
try{
    $aidlRoot=[IO.Path]::GetFullPath("$source/server/src/main/aidl")
    $gen=[IO.Path]::GetFullPath("$build/gen")
    & "$bt/aidl.exe" "-o$gen" "-I$aidlRoot" (Join-Path $aidlRoot 'android\content\IOnPrimaryClipChangedListener.aidl')
    if($LASTEXITCODE){throw 'Clipboard AIDL generation failed'}
    & "$bt/aidl.exe" "-o$gen" "-I$aidlRoot" '-p' "$platform/framework.aidl" (Join-Path $aidlRoot 'android\view\IDisplayWindowListener.aidl')
    if($LASTEXITCODE){throw 'Display AIDL generation failed'}
}finally{Pop-Location}
$sources=@(Get-ChildItem "$build/src","$build/gen" -Recurse -Filter '*.java'|ForEach-Object {'"'+($_.FullName -replace '\\','/')+'"'})
[IO.File]::WriteAllLines("$build/sources.txt",$sources,[Text.UTF8Encoding]::new($false))
& "$java/javac.exe" -encoding UTF-8 -bootclasspath "$platform/android.jar" -cp "$bt/core-lambda-stubs.jar;$build/gen" -source 1.8 -target 1.8 -d "$build/classes" "@$build/sources.txt"
if($LASTEXITCODE){throw 'scrcpy Java compilation failed'}
& "$java/jar.exe" --create --file "$build/classes.jar" -C "$build/classes" .
if($LASTEXITCODE){throw 'scrcpy class archive failed'}
& "$java/java.exe" -cp "$bt/lib/d8.jar" com.android.tools.r8.D8 --min-api 21 --lib "$platform/android.jar" --output "$build/dex" "$build/classes.jar"
if($LASTEXITCODE){throw 'scrcpy DEX compilation failed'}
& "$java/jar.exe" --create --file "$build/scrcpy-server-sparkdroid" -C "$build/dex" classes.dex
if($LASTEXITCODE){throw 'scrcpy server archive failed'}
Copy-Item "$build/scrcpy-server-sparkdroid" "$root/tools/scrcpy/scrcpy-server-sparkdroid" -Force
New-Item -ItemType Directory -Force "$root/artifacts/refresh"|Out-Null
$diff=& git diff --no-index -- "$source/server/src/main/java" "$build/src"
[IO.File]::WriteAllLines("$root/upstream/scrcpy-refresh/server-refresh.patch",[string[]]$diff,[Text.UTF8Encoding]::new($false))
@{sourceUrl='https://github.com/Genymobile/scrcpy';revision=$expected;version='5.0.1';modification='Request Android virtual display refresh rate from max_fps on Android 14+';sha256=(Get-FileHash "$build/scrcpy-server-sparkdroid").Hash;builtUtc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json|Tee-Object -FilePath "$root/upstream/scrcpy-refresh-server.lock.json"
