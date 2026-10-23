#requires -Version 7.2
# Offline safety contracts only: no WSL invocation, installation, import or restart.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$errors=$null;$tokens=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Setup-WSL.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
foreach($name in @('AssertRebootCompleted','AssertOwned','DistroExists')){
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if(-not $definition){throw "Missing setup function: $name"}
    . ([scriptblock]::Create($definition.Extent.Text))
}
$state=Join-Path $root 'state/wsl/offline-setup-test-fixtures'
New-Item -ItemType Directory -Force $state|Out-Null
$receiptPath=Join-Path $state 'host-setup.json'
$fakeBoot=[datetime]::Parse('2026-10-23T11:27:35.909911Z').ToUniversalTime()
function Get-CimInstance([string]$ClassName){
    if($ClassName -ne 'Win32_OperatingSystem'){throw 'Unexpected host query.'}
    [pscustomobject]@{LastBootUpTime=$fakeBoot}
}
$receipt=@{rebootRequired=$true;bootTimeUtc=$fakeBoot.ToString('o')}
$receipt|ConvertTo-Json|Set-Content -LiteralPath $receiptPath -Encoding utf8
$blocked=$false
try{AssertRebootCompleted}catch{if($_.Exception.Message -notmatch 'has not restarted'){throw};$blocked=$true}
if(-not $blocked){throw 'Pending reboot on the same Windows boot must block setup.'}
$fakeBoot=$fakeBoot.AddMinutes(10)
AssertRebootCompleted
$receipt.rebootRequired=$false;$receipt.bootTimeUtc=$fakeBoot.ToString('o')
$receipt|ConvertTo-Json|Set-Content -LiteralPath $receiptPath -Encoding utf8
AssertRebootCompleted

$distro='SPARKDROID';$marker='SPARKDROID-WSL1'
$guestReply=[pscustomobject]@{ExitCode=0;Output=$marker;Error=''}
function Guest([string[]]$arguments,[int]$timeout,[switch]$AllowFailure){
    if(($arguments -join '|') -cne 'cat|/etc/sparkdroid-wsl'){throw 'Ownership check issued an unexpected guest command.'}
    return $guestReply
}
AssertOwned
foreach($reply in @(
    [pscustomobject]@{ExitCode=0;Output='UNRELATED';Error=''},
    [pscustomobject]@{ExitCode=1;Output='';Error='missing marker'}
)){
    $guestReply=$reply;$blocked=$false
    try{AssertOwned}catch{if($_.Exception.Message -notmatch 'not marked as owned'){throw};$blocked=$true}
    if(-not $blocked){throw 'An unrelated or unmarked distribution must be rejected.'}
}
$listedReply=[pscustomobject]@{ExitCode=0;Output="Ubuntu`r`nSPARKDROID`r`n";Error=''}
function Run([string]$exe,[string[]]$arguments,[int]$timeout,[switch]$AllowFailure){
    if(($arguments -join '|') -cne '--list|--quiet'){throw 'Distro existence check issued an unexpected host command.'}
    return $listedReply
}
if(-not(DistroExists)){throw 'Exact distro name was not found.'}
$listedReply.Output='OTHER-SPARKDROID'
if(DistroExists){throw 'Distro existence matched only a substring.'}

# Ensure guard calls remain before any Import/Probe host or guest action.
$dispatch=$ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -eq '$Action -eq ''Prepare'''},$true)
if(-not $dispatch){throw 'Cannot identify setup action dispatch.'}
$import=@($dispatch.Clauses|Where-Object {$_.Item1.Extent.Text -eq '$Action -eq ''Import'''})
if($import.Count -ne 1 -or $import[0].Item2.Statements[0].Extent.Text -ne 'AssertRebootCompleted' -or $dispatch.ElseClause.Statements[0].Extent.Text -ne 'AssertRebootCompleted'){
    throw 'Import and Probe must check the reboot receipt before any other action.'
}
[pscustomobject]@{
    PowerShellSyntax='passed';SameBootPendingReboot='blocked';ChangedBoot='accepted';NoRestartRequired='accepted'
    ExistingOwnedDistro='accepted';UnrelatedDistro='rejected';MissingOwnershipMarker='rejected';ExactDistroMatch='passed'
    ImportAndProbeRebootGuardOrdering='passed';HostMutations='none';RuntimeAndGpu='not tested'
}|ConvertTo-Json
