[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=Join-Path $root 'src/SparkDroid.FrameProbe'
$out=Join-Path $root 'tools/frame-probe-build'
$java=Join-Path $root 'tools/jdk/bin'
$bt=Join-Path $root 'tools/android-sdk/android-16'
$platform=Join-Path $root 'tools/android-sdk/android-36/android.jar'
New-Item -ItemType Directory -Force "$out/classes","$out/dex","$root/artifacts/refresh"|Out-Null
& "$java/javac.exe" -encoding UTF-8 -source 1.8 -target 1.8 -bootclasspath $platform -d "$out/classes" "$source/FrameActivity.java"
if($LASTEXITCODE){throw 'Frame probe Java build failed'}
& "$java/jar.exe" --create --file "$out/classes.jar" -C "$out/classes" .
& "$java/java.exe" -cp "$bt/lib/d8.jar" com.android.tools.r8.D8 --min-api 34 --lib $platform --output "$out/dex" "$out/classes.jar"
if($LASTEXITCODE){throw 'Frame probe DEX build failed'}
& "$bt/aapt2.exe" link -I $platform --manifest "$source/AndroidManifest.xml" -o "$out/unsigned.apk"
if($LASTEXITCODE){throw 'Frame probe APK resource build failed'}
& "$java/jar.exe" --update --file "$out/unsigned.apk" -C "$out/dex" classes.dex
if(-not(Test-Path "$out/debug.keystore")){
    & "$java/keytool.exe" -genkeypair -keystore "$out/debug.keystore" -storepass android -keypass android -alias androiddebugkey -dname 'CN=SPARKDROID Test' -keyalg RSA -validity 3650 -noprompt
}
& "$java/java.exe" -jar "$bt/lib/apksigner.jar" sign --ks "$out/debug.keystore" --ks-pass pass:android --key-pass pass:android --out "$root/artifacts/refresh/FrameProbe.apk" "$out/unsigned.apk"
if($LASTEXITCODE){throw 'Frame probe APK signing failed'}
Write-Output "$root/artifacts/refresh/FrameProbe.apk"
