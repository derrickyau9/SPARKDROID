[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
New-Item -ItemType Directory -Force "$root/tools/downloads"|Out-Null
function Archive([string]$lockName,[string]$file){
    $lock=Get-Content "$root/upstream/$lockName" -Raw|ConvertFrom-Json
    $path=Join-Path $root "tools/downloads/$file"
    if(-not(Test-Path -LiteralPath $path)){
        & curl.exe --fail --location --silent --show-error --retry 3 --output $path $lock.Url
        if($LASTEXITCODE){throw "Download failed: $file"}
    }
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $lock.Sha256){throw "Checksum mismatch: $file"}
    return $path
}
if(-not(Test-Path "$root/tools/jdk/bin/javac.exe")){
    $zip=Archive 'jdk-build.lock.json' 'jdk21-arm64.zip'
    New-Item -ItemType Directory -Force "$root/tools/jdk"|Out-Null
    & tar.exe -xf $zip -C "$root/tools/jdk" --strip-components 1
    if($LASTEXITCODE){throw 'JDK extraction failed'}
}
foreach($item in @(
    @{lock='platform36.zip.lock.json';file='platform36.zip';check='android-36/android.jar'},
    @{lock='buildtools36.zip.lock.json';file='buildtools36.zip';check='android-16/lib/d8.jar'})){
    if(-not(Test-Path "$root/tools/android-sdk/$($item.check)")){
        $zip=Archive $item.lock $item.file
        Expand-Archive -LiteralPath $zip -DestinationPath "$root/tools/android-sdk" -Force
    }
}
$source=Join-Path $root 'tools/scrcpy-source'
if(-not(Test-Path "$source/.git")){
    & git clone --depth 1 --branch v5.0.1 https://github.com/Genymobile/scrcpy.git $source
    if($LASTEXITCODE){throw 'scrcpy source acquisition failed'}
}
if((& git -C $source rev-parse HEAD).Trim() -ne 'a60891aea193d92e7e5c3942700eca63f9d19a5f'){throw 'Unexpected scrcpy source revision'}
Write-Output 'Local refresh bridge build dependencies are ready.'
