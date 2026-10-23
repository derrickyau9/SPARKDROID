#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [int]$DownloadConcurrency = 6
)
$ErrorActionPreference = 'Stop'
$lockPath = Join-Path $ProjectRoot 'upstream/qemu-arm64.lock.json'
if (-not (Test-Path -LiteralPath $lockPath)) { throw "Missing pinned package lock: $lockPath. Run Resolve-QemuPackages.ps1 explicitly to refresh it." }
$lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
$cache = Join-Path $ProjectRoot 'artifacts/toolchain/packages'
$destination = Join-Path $ProjectRoot 'tools/qemu-arm64'
$runtimeBoundary = [IO.Path]::GetFullPath($destination).TrimEnd('\') + '\'
$running = Get-Process -Name 'qemu-system-aarch64','qemu-system-aarch64w' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($runtimeBoundary,[StringComparison]::OrdinalIgnoreCase) }
if ($running) { throw 'Stop SPARKDROID and its diagnostic VMs before reprovisioning the local QEMU runtime.' }
New-Item -ItemType Directory -Force $cache, $destination | Out-Null
$repository = $lock.repository
$downloadResults = $lock.packages | ForEach-Object -ThrottleLimit $DownloadConcurrency -Parallel {
    $ErrorActionPreference = 'Stop'
    $package = $_
    $path = Join-Path $using:cache $package.file
    $valid = (Test-Path -LiteralPath $path) -and ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ieq $package.sha256)
    if (-not $valid) {
        & curl.exe --silent --show-error --fail --location --retry 3 --output $path "$using:repository/$($package.file)"
        if ($LASTEXITCODE) { throw "Package download failed: $($package.name): $LASTEXITCODE" }
    }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $package.sha256) { throw "SHA256 mismatch: $($package.name)" }
    [pscustomobject]@{name=$package.name;file=$package.file;sha256=$actual;bytes=(Get-Item -LiteralPath $path).Length}
}
if (@($downloadResults).Count -ne @($lock.packages).Count) { throw 'Not all package downloads succeeded.' }
$downloadResults | Sort-Object name | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ProjectRoot 'artifacts/toolchain/downloads.json') -Encoding utf8
foreach ($package in $lock.packages) {
    Write-Host "Extracting $($package.name) $($package.version)"
    $archive = Join-Path $cache $package.file
    # Native Windows tar cannot create POSIX symlinks without special host privileges.
    # Exclude them and materialize existing file targets inside this local runtime instead.
    $links = @(& tar.exe -tvf $archive | ForEach-Object {
        if ($_ -match '^l.*\s(?<path>clangarm64/.*?) -> (?<target>.*)$') {
            [pscustomobject]@{path=$Matches.path;target=$Matches.target}
        }
    })
    if ($LASTEXITCODE) { throw "Package listing failed: $($package.name): $LASTEXITCODE" }
    $excludesPath = Join-Path $cache "$($package.file).excluded-links.txt"
    [IO.File]::WriteAllLines($excludesPath, [string[]]@($links | ForEach-Object { $_.path }), [Text.UTF8Encoding]::new($false))
    if ($package.name -eq 'mingw-w64-clang-aarch64-qemu') {
        # Keep the native ARM64 system emulator and its runtime modules, not other guest ISA executables.
        & tar.exe -xf $archive -C $destination -X $excludesPath --include 'clangarm64/bin/qemu-system-aarch64.exe' --include 'clangarm64/bin/qemu-system-aarch64w.exe' --include 'clangarm64/lib/qemu/*' --include 'clangarm64/share/qemu/*'
    } else {
        # Runtime data and DLLs remain intact. Static development artifacts and reference manuals are unnecessary.
        & tar.exe -xf $archive -C $destination -X $excludesPath --exclude 'clangarm64/include' --exclude 'clangarm64/share/doc' --exclude 'clangarm64/share/man' --exclude 'clangarm64/share/gtk-doc' --exclude '*.a'
    }
    if ($LASTEXITCODE) { throw "Package extraction failed: $($package.name): $LASTEXITCODE" }
    foreach ($link in $links) {
        $alias = [IO.Path]::GetFullPath((Join-Path $destination $link.path))
        if ($link.target.StartsWith('/')) { $target = Join-Path $destination $link.target.TrimStart('/') }
        else { $target = Join-Path (Split-Path -Parent $alias) $link.target }
        $target = [IO.Path]::GetFullPath($target)
        $runtimeBoundary = [IO.Path]::GetFullPath($destination).TrimEnd('\') + '\'
        if (-not $alias.StartsWith($runtimeBoundary, [StringComparison]::OrdinalIgnoreCase) -or -not $target.StartsWith($runtimeBoundary, [StringComparison]::OrdinalIgnoreCase)) { throw "Archive link escapes runtime: $($link.path)" }
        if ((Test-Path -LiteralPath (Split-Path -Parent $alias)) -and (Test-Path -LiteralPath $target -PathType Leaf) -and -not (Test-Path -LiteralPath $alias)) {
            Copy-Item -LiteralPath $target -Destination $alias
        }
    }
}
$binary = Join-Path $destination 'clangarm64/bin/qemu-system-aarch64.exe'
if (-not (Test-Path -LiteralPath $binary)) { throw "QEMU binary missing: $binary" }
Write-Output $binary
