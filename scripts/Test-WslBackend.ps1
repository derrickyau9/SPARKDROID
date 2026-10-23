#requires -Version 7.2
# Offline contract checks. Does not start WSL, Android, or any installed app.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$errors=$null;$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'SparkDroid-WSL.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($name in @('InvokeProcess','CheckApkAbi','GuestAction')){
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if(-not $definition){throw "Missing backend function: $name"}
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Adb([string[]]$arguments,[int]$timeout){'arm64-v8a'}
function RequireDistro {}
function Wsl([string[]]$arguments,[int]$timeout){
    if($arguments.Count -eq 2 -and $arguments[0] -ceq 'cat' -and $arguments[1] -ceq '/etc/sparkdroid-wsl'){return 'UNRELATED-DISTRO'}
    throw 'Ownership check should reject before any other guest command.'
}
foreach($operation in @('provision','start','stop')){
    $refused=$false
    try{GuestAction $operation}catch{if($_.Exception.Message -notmatch 'ownership marker'){throw};$refused=$true}
    if(-not $refused){throw "Unowned-distro $operation operation should have been refused."}
}
$fixtures=Join-Path $root 'state/wsl/offline-test-fixtures'
New-Item -ItemType Directory -Force $fixtures|Out-Null
function MakeApk([string]$name,[string[]]$entries){
    $path=Join-Path $fixtures $name
    $stream=[IO.File]::Open($path,[IO.FileMode]::Create,[IO.FileAccess]::Write)
    try{
        $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
        try{foreach($entry in $entries){$null=$zip.CreateEntry($entry)}}finally{$zip.Dispose()}
    }finally{$stream.Dispose()}
    return $path
}
$legacy=MakeApk "old CPU-Z's package.apk" @('lib/armeabi/libcpuz.so','lib/mips/libcpuz.so','lib/x86/libcpuz.so')
$native=MakeApk 'ARM64 package.apk' @('lib/arm64-v8a/libapp.so')
$java=MakeApk 'Java package.apk' @('classes.dex')
$rejected=$false
try{CheckApkAbi @($legacy)}catch{
    if($_.Exception.Message -notmatch 'ABI mismatch'){throw}
    $rejected=$true
}
if(-not $rejected){throw '32-bit-only APK should be rejected before ADB install.'}
CheckApkAbi @($native)
CheckApkAbi @($java)
CheckApkAbi @($java,$native)
$python=Join-Path $root 'tools/python/python.exe'
if(-not(Test-Path -LiteralPath $python)){throw 'Portable Python is required to check native argument roundtrips.'}
$helper=Join-Path $fixtures 'argument roundtrip.py'
[IO.File]::WriteAllText($helper,"import json, sys`nprint(json.dumps(sys.argv[1:]))`n",[Text.UTF8Encoding]::new($false))
$expected=@('spaces inside',"single'quote",'double"quote','C:\path with spaces\','$(Get-Process)','中文路径')
$actual=@(((InvokeProcess $python (@($helper)+$expected)).Output|ConvertFrom-Json))
if($actual.Count -ne $expected.Count){throw 'Argument count changed across the native process boundary.'}
for($i=0;$i -lt $expected.Count;$i++){if($expected[$i] -cne $actual[$i]){throw "Argument $i changed across the native process boundary."}}
[pscustomobject]@{
    PowerShellSyntax='passed';UnownedDistroRefusal='passed';LegacyAbiRejection='passed';Arm64Apk='passed';JavaOnlyApk='passed';SplitArm64Apk='passed';NativeArgumentRoundtrip='passed'
    RuntimeBoot='not tested by this offline test';HardwareRendering='not tested by this offline test'
}|ConvertTo-Json
