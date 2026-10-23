#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$Repository = 'https://mirror.msys2.org/mingw/clangarm64'
)
$ErrorActionPreference = 'Stop'
$evidence = Join-Path $ProjectRoot 'artifacts/toolchain'
$database = Join-Path $evidence 'clangarm64.db'
New-Item -ItemType Directory -Force $evidence | Out-Null
& curl.exe --silent --show-error --fail --location --retry 3 --output $database "$Repository/clangarm64.db"
if ($LASTEXITCODE) { throw "Database download failed: $LASTEXITCODE" }
$databaseDigest = (Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash.ToLowerInvariant()
$expanded = Join-Path (Join-Path $evidence 'msys2-db') $databaseDigest.Substring(0,12)
New-Item -ItemType Directory -Force $expanded | Out-Null
& tar.exe -xf $database -C $expanded
if ($LASTEXITCODE) { throw "Database extraction failed: $LASTEXITCODE" }
$packages = @{}
$providers = @{}
foreach ($description in Get-ChildItem -LiteralPath $expanded -Recurse -Filter desc) {
    $record = @{}
    $section = $null
    foreach ($line in [IO.File]::ReadAllLines($description.FullName)) {
        if ($line -match '^%(\w+)%$') {
            $section = $Matches[1]
            $record[$section] = [Collections.Generic.List[string]]::new()
        } elseif ($section -and $line) {
            $record[$section].Add($line)
        }
    }
    $packages[$record.NAME[0]] = $record
    foreach ($provided in $record.PROVIDES) {
        $providers[($provided -replace '[<>=].*$', '')] = $record.NAME[0]
    }
}
$pending = [Collections.Generic.Queue[string]]::new()
$pending.Enqueue('mingw-w64-clang-aarch64-qemu')
$resolved = @{}
while ($pending.Count) {
    $name = $pending.Dequeue() -replace '[<>=].*$', ''
    if (-not $packages.ContainsKey($name) -and $providers.ContainsKey($name)) { $name = $providers[$name] }
    if ($resolved.ContainsKey($name)) { continue }
    if (-not $packages.ContainsKey($name)) { throw "Unresolved dependency: $name" }
    $resolved[$name] = $packages[$name]
    foreach ($dependency in $packages[$name].DEPENDS) { $pending.Enqueue($dependency) }
}
$lock = [ordered]@{
    schemaVersion = 1
    repository = $Repository
    databaseSha256 = $databaseDigest
    architecture = 'Windows ARM64 (PE machine 0xAA64)'
    verification = 'SHA256 package digests pinned from official HTTPS repository database. Detached package PGP signatures have not been verified.'
    packages = @($resolved.Keys | Sort-Object | ForEach-Object {
        $package = $resolved[$_]
        [ordered]@{
            name = $_
            version = $package.VERSION[0]
            file = $package.FILENAME[0]
            sha256 = $package.SHA256SUM[0]
            size = [long]$package.CSIZE[0]
            dependencies = @($package.DEPENDS | Where-Object { $_ })
            license = @($package.LICENSE)
        }
    })
}
New-Item -ItemType Directory -Force (Join-Path $ProjectRoot 'upstream') | Out-Null
$destination = Join-Path $ProjectRoot 'upstream/qemu-arm64.lock.json'
$lock | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $destination -Encoding utf8
[pscustomobject]@{Lock=$destination;Packages=$resolved.Count;DownloadMiB=[math]::Round(($lock.packages | ForEach-Object { $_.size } | Measure-Object -Sum).Sum / 1MB,1)}
