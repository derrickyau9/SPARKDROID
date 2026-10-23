[CmdletBinding()]
param([string]$Python, [switch]$RebuildSeed)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Set-Location -LiteralPath $root
New-Item -ItemType Directory -Force state,shared,state/seed | Out-Null
if (-not $Python) {
    $portable=Join-Path $root 'tools/python/python.exe'
    $candidate=Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
    if(Test-Path $portable){$Python=$portable}elseif(Test-Path $candidate){$Python=$candidate}else{$Python=(Get-Command python -ErrorAction Stop).Source}
}
if(-not (Test-Path state/ssh_key)) {
    & ssh-keygen -q -t ed25519 -N '' -C sparkdroid-local -f state/ssh_key
    if($LASTEXITCODE){throw 'SSH key generation failed'}
}
$publicKey=(Get-Content state/ssh_key.pub -Raw).Trim()
$provision=Get-Content guest/provision-redroid.sh -Raw
$b64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($provision -replace "`r`n","`n")))
$cloud=@"
#cloud-config
hostname: sparkdroid
manage_etc_hosts: true
ssh_pwauth: false
disable_root: true
users:
  - name: spark
    gecos: SPARKDROID local management
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - $publicKey
write_files:
  - path: /opt/sparkdroid/provision.sh
    permissions: '0755'
    encoding: b64
    content: $b64
runcmd:
  - [bash, /opt/sparkdroid/provision.sh]
final_message: 'SPARKDROID cloud-init complete after `$UPTIME seconds; inspect /var/log/sparkdroid/provision.log.'
"@
[IO.File]::WriteAllText((Join-Path $root 'state/seed/user-data'),($cloud -replace "`r`n","`n"),[Text.UTF8Encoding]::new($false))
if(-not (Test-Path state/seed/meta-data)){
    [IO.File]::WriteAllText((Join-Path $root 'state/seed/meta-data'),"instance-id: sparkdroid-$([guid]::NewGuid().ToString('N'))`nlocal-hostname: sparkdroid`n",[Text.UTF8Encoding]::new($false))
}
& $Python scripts/make-seed.py
if($LASTEXITCODE){throw 'Seed ISO generation failed. Install pycdlib==1.16.0 into tools/python-libs.'}
Write-Output 'Cloud-init seed ready. Private key stays in state/ssh_key and must not be packaged.'
