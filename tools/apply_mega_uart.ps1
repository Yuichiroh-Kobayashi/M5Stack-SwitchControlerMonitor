[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$CandidateRoot,
  [Parameter(Mandatory=$true)][string]$Target,
  [Parameter(Mandatory=$true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedHexSha256
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$candidate=[IO.Path]::GetFullPath($CandidateRoot)
$targetRoot=[IO.Path]::GetFullPath($Target).TrimEnd('\')
$workspaceTemp=(Join-Path $repo 'build-temp').TrimEnd('\')+'\'
if(!$candidate.StartsWith($workspaceTemp,[StringComparison]::OrdinalIgnoreCase)){throw 'Candidate must be workspace-local evidence'}
$manifest=Get-Content -LiteralPath (Join-Path $candidate 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if($manifest.schema -ne 'core-mega-uart-candidate-v1' -or [IO.Path]::GetFullPath($manifest.source).TrimEnd('\') -ine $targetRoot){throw 'Candidate does not belong to this target'}
$hex=Join-Path $candidate 'build-verified/CoRE2_sample.ino.hex'
if((Get-FileHash -LiteralPath $hex).Hash -ine $ExpectedHexSha256){throw 'Built firmware identity mismatch'}
$sketch=Join-Path $candidate 'CoRE2_sample'
function ChildPath([string]$Parent,[string]$Relative) {
  $full=[IO.Path]::GetFullPath((Join-Path $Parent $Relative))
  if(!$full.StartsWith($Parent.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Manifest path escapes its root'}
  $full
}
# Verify every original and candidate before any target write. Reject new,
# unexplained entries as well as edits to the known baseline.
$originalNames=@($manifest.before.PSObject.Properties.Name)
$actual=@(Get-ChildItem -LiteralPath $targetRoot -Force)
if($actual.Count -ne $originalNames.Count){throw 'Target file set changed'}
foreach($file in $actual){
  if($file.PSIsContainer -or $file.Name -cnotin $originalNames -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Unexpected target entry'}
  if((Get-FileHash -LiteralPath $file.FullName).Hash -ine $manifest.before.($file.Name)){throw 'Target changed since preparation'}
}
foreach($entry in $manifest.after.PSObject.Properties){
  if((Get-FileHash -LiteralPath (ChildPath $sketch $entry.Name)).Hash -ine $entry.Value){throw 'Candidate source changed after preparation'}
  [void](ChildPath $targetRoot $entry.Name)
}
$backup=Join-Path $candidate 'original-backup'
if(Test-Path -LiteralPath $backup){throw 'Apply was already attempted; inspect saved evidence'}
New-Item -ItemType Directory -Path $backup | Out-Null
foreach($file in $actual){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $backup $file.Name)}
foreach($name in $manifest.changed){
  $destination=ChildPath $targetRoot $name
  New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
  Copy-Item -LiteralPath (ChildPath $sketch $name) -Destination $destination
}
foreach($entry in $manifest.after.PSObject.Properties){
  if((Get-FileHash -LiteralPath (ChildPath $targetRoot $entry.Name)).Hash -ine $entry.Value){throw 'Applied source failed readback verification'}
}
@{schema='core-mega-apply-v1';target=$targetRoot;candidate=$candidate;hex_sha256=$ExpectedHexSha256;backup=$backup;changed=$manifest.changed;result='APPLIED_SOURCE_HASHES_MATCH';upload='NOT_RUN'} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $candidate 'applied.json') -Encoding UTF8
Write-Output 'MEGA_SOURCE_APPLY_PASS=1 UPLOAD=NOT_RUN'
