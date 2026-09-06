# Offline file application only, entirely within workspace/build-temp.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$runner=Join-Path $repo 'tools/apply_mega_uart.ps1'
$root=Join-Path $repo ('build-temp/offline-mega-apply-'+[guid]::NewGuid().ToString('N'))
$target=Join-Path $root 'target';$candidate=Join-Path $root 'candidate';$sketch=Join-Path $candidate 'CoRE2_sample'
New-Item -ItemType Directory -Path $target,$sketch,(Join-Path $candidate 'build-verified'),(Join-Path $sketch 'src') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $target 'controller.ino'),'OFFLINE ORIGINAL')
[IO.File]::WriteAllText((Join-Path $target 'keep.txt'),'OFFLINE PRESERVE')
[IO.File]::WriteAllText((Join-Path $sketch 'controller.ino'),'OFFLINE CHANGED')
Copy-Item -LiteralPath (Join-Path $target 'keep.txt') -Destination $sketch
[IO.File]::WriteAllText((Join-Path $sketch 'src/added.h'),'OFFLINE NEW')
$hex=Join-Path $candidate 'build-verified/CoRE2_sample.ino.hex'
[IO.File]::WriteAllText($hex,'OFFLINE NOT FIRMWARE')
$before=@{};foreach($name in @('controller.ino','keep.txt')){$before[$name]=(Get-FileHash (Join-Path $target $name)).Hash}
$after=@{};foreach($name in @('controller.ino','keep.txt','src/added.h')){$after[$name]=(Get-FileHash (Join-Path $sketch $name)).Hash}
@{schema='core-mega-uart-candidate-v1';source=$target;before=$before;after=$after;changed=@('controller.ino','src/added.h')} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $candidate 'manifest.json') -Encoding UTF8
$sha=(Get-FileHash $hex).Hash
$checks=0
$refused=$false;try{& $runner -CandidateRoot $candidate -Target $target -ExpectedHexSha256 ('0'*64)}catch{$refused=$true}
if(!$refused -or (Test-Path (Join-Path $candidate 'original-backup'))){throw 'Wrong artifact was not refused before write'};$checks++
[IO.File]::AppendAllText((Join-Path $target 'keep.txt'),'EDIT')
$refused=$false;try{& $runner -CandidateRoot $candidate -Target $target -ExpectedHexSha256 $sha}catch{$refused=$true}
if(!$refused -or (Test-Path (Join-Path $candidate 'original-backup'))){throw 'Concurrent target edit was not refused'};$checks++
[IO.File]::WriteAllText((Join-Path $target 'keep.txt'),'OFFLINE PRESERVE')
& $runner -CandidateRoot $candidate -Target $target -ExpectedHexSha256 $sha
foreach($name in $after.Keys){if((Get-FileHash (Join-Path $target $name)).Hash -ne $after[$name]){throw 'Readback differs'};$checks++}
foreach($name in $before.Keys){if((Get-FileHash (Join-Path $candidate ('original-backup/'+$name))).Hash -ne $before[$name]){throw 'Backup differs'};$checks++}
$refused=$false;try{& $runner -CandidateRoot $candidate -Target $target -ExpectedHexSha256 $sha}catch{$refused=$true}
if(!$refused){throw 'Second apply must fail'};$checks++
Write-Output "MEGA_APPLY_OFFLINE_TEST_PASS checks=$checks"
