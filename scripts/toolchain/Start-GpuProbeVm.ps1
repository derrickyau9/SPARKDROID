#requires -Version 7.0
[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $ProjectRoot
$seedDirectory = Join-Path $ProjectRoot 'state/gpu-probe-seed'
New-Item -ItemType Directory -Force $seedDirectory | Out-Null
$publicKey = (Get-Content -LiteralPath state/ssh_key.pub -Raw).Trim()
$cloud = @"
#cloud-config
hostname: sparkdroid-gpu-probe
manage_etc_hosts: true
ssh_pwauth: false
disable_root: true
users:
  - name: spark
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - $publicKey
package_update: true
packages:
  - mesa-utils
  - libegl1
  - libgles2
  - libgl1-mesa-dri
runcmd:
  - [sh, -c, 'modprobe virtio_gpu; ls -l /dev/dri > /var/log/sparkdroid-gpu-devices.log 2>&1; EGL_PLATFORM=surfaceless eglinfo -B > /var/log/sparkdroid-eglinfo.log 2>&1; touch /var/lib/sparkdroid-gpu-probe-complete']
final_message: 'SPARKDROID GPU diagnostic cloud-init complete after `$UPTIME seconds.'
"@
[IO.File]::WriteAllText((Join-Path $seedDirectory 'user-data'),($cloud -replace "`r`n","`n"),[Text.UTF8Encoding]::new($false))
$metadata = Join-Path $seedDirectory 'meta-data'
if (-not (Test-Path -LiteralPath $metadata)) {
    [IO.File]::WriteAllText($metadata,"instance-id: gpu-probe-$([Guid]::NewGuid().ToString('N'))`nlocal-hostname: sparkdroid-gpu-probe`n",[Text.UTF8Encoding]::new($false))
}
$python = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
& $python scripts/toolchain/make-probe-seed.py
if ($LASTEXITCODE) { throw 'Probe seed creation failed.' }
$prefix = Join-Path $ProjectRoot 'tools/qemu-arm64/clangarm64'
$disk = Join-Path $ProjectRoot 'state/gpu-probe.qcow2'
if (-not (Test-Path -LiteralPath $disk)) {
    & (Join-Path $prefix 'bin/qemu-img.exe') create -f qcow2 -F qcow2 -b (Join-Path $ProjectRoot 'tools/images/ubuntu-noble-arm64.img') $disk
    if ($LASTEXITCODE) { throw 'Probe overlay creation failed.' }
    & (Join-Path $prefix 'bin/qemu-img.exe') resize $disk 12G
    if ($LASTEXITCODE) { throw 'Probe overlay resize failed.' }
}
foreach ($port in @(22223,14445)) {
    $reservation = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port)
    try { $reservation.Start() } finally { $reservation.Stop() }
}
$arguments = @('-name','SPARKDROID GPU diagnostic','-machine','virt,gic-version=3','-accel','whpx','-cpu','host','-smp','2','-m','2048','-bios',(Join-Path $prefix 'share/qemu/edk2-aarch64-code.fd'),'-display','egl-headless','-device','virtio-gpu-gl-pci',
    '-drive',"file=$disk,if=virtio,format=qcow2,discard=unmap",'-drive',"file=$(Join-Path $ProjectRoot 'state/gpu-probe-seed.iso'),if=none,id=seed,format=raw,media=cdrom,readonly=on",'-device','virtio-scsi-pci','-device','scsi-cd,drive=seed',
    '-netdev','user,id=net0,hostfwd=tcp:127.0.0.1:22223-:22','-device','virtio-net-pci,netdev=net0','-device','virtio-rng-pci','-qmp','tcp:127.0.0.1:14445,server=on,wait=off','-serial',"file:$(Join-Path $ProjectRoot 'artifacts/toolchain/gpu-probe-serial.log')",'-monitor','none')
$quoted = ($arguments | ForEach-Object { '"' + ($_ -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1') + '"' }) -join ' '
$process = Start-Process -FilePath (Join-Path $prefix 'bin/qemu-system-aarch64.exe') -ArgumentList $quoted -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $ProjectRoot 'artifacts/toolchain/gpu-probe-stdout.txt') -RedirectStandardError (Join-Path $ProjectRoot 'artifacts/toolchain/gpu-probe-stderr.txt')
Start-Sleep -Milliseconds 1200
if ($process.HasExited) { throw "GPU diagnostic VM exited $($process.ExitCode). See artifacts/toolchain/gpu-probe-stderr.txt." }
$state = [ordered]@{pid=$process.Id;startTicks=$process.StartTime.ToUniversalTime().Ticks;arguments=$arguments;sshPort=22223;qmpPort=14445;disk=$disk}
$state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath state/gpu-probe-vm.json -Encoding utf8
Write-Output "GPU diagnostic VM PID $($process.Id); SSH22223 / QMP14445. No root runtime files were changed."
