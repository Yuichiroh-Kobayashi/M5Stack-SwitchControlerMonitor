[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('UsbScreen','UsbMapping','LanScreen')][string]$Mode,
    [Parameter(Mandatory=$true)][string]$BuildRoot,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedBinarySha256,
    [Parameter(Mandatory=$true)][ValidatePattern('^COM[0-9]+$')][string]$Port,
    [Parameter(Mandatory=$true)][string]$ExpectedPnpDeviceId,
    [Parameter(Mandatory=$true)][string]$PhysicalAttestationFile,
    [string]$ConfigFile='',
    [string]$OutputRoot='',
    [string]$MappingStep='',
    [string]$MappingReview='',
    [string]$TimingLimits='',
    [string]$RunningFirmwareEvidenceFile='',
    [ValidateRange(16,600)][int]$DurationSeconds=75,
    [switch]$Upload,
    [switch]$PreflightOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'product_validation/Preflight.ps1')
$BuildRoot=Resolve-ProductWorkspacePath $BuildRoot $repoRoot
$cli=Join-Path $PSScriptRoot 'product_trial.py'
$python=(Get-Command python -ErrorAction Stop).Source
if($Mode -eq 'UsbMapping'){
    $plan=(& $python $cli mapping-plan | ConvertFrom-Json)
    if($LASTEXITCODE -ne 0 -or $MappingStep -notin (@($plan.required_steps)+@($plan.exploratory_step))){throw 'Select a mapping step from product_trial.py mapping-plan'}
    $DurationSeconds=16
}elseif($DurationSeconds -lt 65){throw 'Screening needs at least65s;75s is recommended'}
$caseName=if($Mode -eq 'LanScreen'){'sender'}else{'sender-usb-only'}
$cases=@(Get-Content -LiteralPath (Join-Path $BuildRoot 'results.json') -Raw -Encoding UTF8 | ConvertFrom-Json)
$selected=@($cases | Where-Object {$_.Case -eq $caseName})
if($selected.Count -ne 1 -or $selected[0].Result -ne 'TARGET_BUILD_PASS'){throw 'Missing exact build case'}
$candidate=$selected[0]
if($candidate.NumericUi -ne 1){throw 'Mapping/screening requires numeric UI enabled'}
if($candidate.BinarySha256 -ine $ExpectedBinarySha256){throw 'Requested binary does not match build record'}
if($Mode -eq 'LanScreen'){
    if($candidate.PcPeerTest -ne 1 -or $candidate.UsbOnly -ne 0 -or $candidate.UsbIntake -ne 0){throw 'LAN screen requires the identified PC-peer test build'}
}elseif($candidate.UsbOnly -ne 1 -or $candidate.UsbIntake -ne 1 -or $candidate.PcPeerTest -ne 0){throw 'USB observation requires the USB-only intake build'}
$caseRoot=Join-Path $BuildRoot $caseName
$build=Join-Path $caseRoot 'build'
$manifest=Import-Csv -LiteralPath (Join-Path $caseRoot 'binary-hashes.csv')
foreach($entry in $manifest){
    if([IO.Path]::GetFileName($entry.File) -cne $entry.File -or (Get-FileHash -LiteralPath (Join-Path $build $entry.File)).Hash -ine $entry.Sha256){throw 'Binary artifact hash mismatch'}
}
if((Get-FileHash -LiteralPath (Join-Path $build 'M5Stack-PS5CoRELANSender.ino.bin')).Hash -ine $ExpectedBinarySha256){throw 'Application hash mismatch'}
$sources=Import-Csv -LiteralPath (Join-Path $caseRoot 'source-hashes.csv')
$profile=@($sources | Where-Object {($_.Path -replace '\\','/') -eq 'src/controller_profile/ControllerProfile.h'})
if($profile.Count -ne 1){throw 'Missing controller profile source identity'}
$profileSha=$profile[0].Sha256
$sourceManifestSha=(Get-FileHash -LiteralPath (Join-Path $caseRoot 'source-hashes.csv')).Hash
if($Mode -eq 'LanScreen'){
    & $python $cli validate-gate --review $MappingReview --profile-sha256 $profileSha --pnp-id $ExpectedPnpDeviceId --source-manifest-sha256 $sourceManifestSha --limits $TimingLimits
    if($LASTEXITCODE -ne 0){throw 'Manual mapping/timing prerequisites incomplete'}
}
if(!(Test-Path -LiteralPath $PhysicalAttestationFile -PathType Leaf) -or (Get-Item -LiteralPath $PhysicalAttestationFile).Length -eq 0){throw 'Current operator physical attestation is required'}
if(!$Upload -and !$PreflightOnly){
    if(!$RunningFirmwareEvidenceFile){throw 'Without upload, provide the prior successful upload trial metadata.json'}
    $installed=Get-Content -LiteralPath $RunningFirmwareEvidenceFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $installedRoot=Split-Path -Parent ([IO.Path]::GetFullPath($RunningFirmwareEvidenceFile))
    & $python $cli verify --root $installedRoot
    if($LASTEXITCODE -ne 0){throw 'Prior upload evidence failed integrity verification'}
    $installedResult=Get-Content -LiteralPath (Join-Path $installedRoot 'runner-result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if(!$installed.upload -or $installed.preflight_only -or !$installedResult.passed -or $installed.binary_sha256 -ine $ExpectedBinarySha256 -or $installed.expected_pnp_id -cne $ExpectedPnpDeviceId){throw 'Prior upload evidence does not identify this firmware/device'}
}
if(!$OutputRoot){$OutputRoot=Join-Path $repoRoot ('build-temp/product-trials/'+(Get-Date -Format yyyyMMdd-HHmmss)+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))}
$OutputRoot=Resolve-ProductWorkspacePath $OutputRoot $repoRoot
$trialPrefix=(Join-Path $repoRoot 'build-temp').TrimEnd('\')+'\'
if(!$OutputRoot.StartsWith($trialPrefix,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $OutputRoot)){throw 'Use a fresh child of build-temp for trial evidence'}
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
$serial=$null;$raw=$null;$jsonLines=$null;$peerProcess=$null;$failure=$null;$passed=$false
try{
    $snapshot=Get-ProductSnapshot
    $snapshot | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $OutputRoot 'preflight.json') -Encoding UTF8
    Assert-ProductIdentity $snapshot.Devices $Port $ExpectedPnpDeviceId
    Assert-ProductNetwork $snapshot
    Copy-Item -LiteralPath $PhysicalAttestationFile -Destination (Join-Path $OutputRoot 'physical-attestation.txt')
    if($RunningFirmwareEvidenceFile){Copy-Item -LiteralPath $RunningFirmwareEvidenceFile -Destination (Join-Path $OutputRoot 'prior-upload-metadata.json')}
    Copy-Item -LiteralPath (Join-Path $caseRoot 'source-hashes.csv'),(Join-Path $caseRoot 'binary-hashes.csv'),(Join-Path $caseRoot 'arguments.json'),(Join-Path $BuildRoot 'library-hashes.csv') -Destination $OutputRoot
    $metadata=[ordered]@{schema='core-product-trial-v1';mode=$Mode;trial_kind=$(if($Mode -eq 'UsbMapping'){'physical_usb_mapping'}else{'physical_screen'});mapping_step=$MappingStep;expected_pnp_id=$ExpectedPnpDeviceId;port=$Port;controller_profile_sha256=$profileSha;source_manifest_sha256=$sourceManifestSha;binary_sha256=$ExpectedBinarySha256.ToUpperInvariant();period_ms=$candidate.PeriodMs;duration_seconds=$DurationSeconds;upload=[bool]$Upload;preflight_only=[bool]$PreflightOnly;host_clock='Stopwatch monotonic; timestamp at completed serial line; not USB event time';build=$candidate}
    $metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputRoot 'metadata.json') -Encoding UTF8
    if($PreflightOnly){$passed=$true;Write-Output 'PREFLIGHT_ONLY_PASS=1';return}
    if($Upload){
        $ConfigFile=Resolve-ProductWorkspacePath $ConfigFile $repoRoot
        $config=Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach($kind in @('data','downloads','user')){[void](Resolve-ProductWorkspacePath $config.directories.$kind $repoRoot)}
        $boot=Join-Path $config.directories.data 'packages/m5stack/hardware/esp32/3.3.7/tools/partitions/boot_app0.bin'
        if((Get-FileHash -LiteralPath $boot).Hash -ine $candidate.BootAppSha256){throw 'Boot app does not match build authority'}
        # Re-read exact identity immediately before the destructive upload step.
        Assert-ProductIdentity (Get-ProductDevices) $Port $ExpectedPnpDeviceId
        & arduino-cli --config-file $ConfigFile upload --fqbn m5stack:esp32:m5stack_cores3 --port $Port --input-dir $build *> (Join-Path $OutputRoot 'upload.log')
        if($LASTEXITCODE -ne 0){throw 'Firmware upload failed'}
    }
    Assert-ProductIdentity (Get-ProductDevices) $Port $ExpectedPnpDeviceId
    if($Mode -eq 'LanScreen'){
        Copy-Item -LiteralPath $MappingReview -Destination (Join-Path $OutputRoot 'mapping-review.json')
        Copy-Item -LiteralPath $TimingLimits -Destination (Join-Path $OutputRoot 'timing-limits.json')
        $request=@{operation='lan_screen';period_ms=$candidate.PeriodMs;duration_seconds=$DurationSeconds+3;bind='192.168.50.30';device='192.168.50.10';port=50001;output_root=$OutputRoot;mapping_review=[IO.Path]::GetFullPath($MappingReview);limits=[IO.Path]::GetFullPath($TimingLimits);controller_profile_sha256=$profileSha;source_manifest_sha256=$sourceManifestSha;expected_pnp_id=$ExpectedPnpDeviceId}
        $requestPath=Join-Path $OutputRoot 'peer-request.json'
        $request|ConvertTo-Json|Set-Content -LiteralPath $requestPath -Encoding UTF8
        $peerProcess=Start-Process -FilePath $python -ArgumentList @('-u',('"'+$cli+'"'),'peer','--request',('"'+$requestPath+'"')) -WorkingDirectory $repoRoot -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $OutputRoot 'peer.stdout.log') -RedirectStandardError (Join-Path $OutputRoot 'peer.stderr.log')
        $readyWatch=[Diagnostics.Stopwatch]::StartNew()
        while(!(Test-Path -LiteralPath (Join-Path $OutputRoot 'peer.ready'))){
            if($peerProcess.HasExited -or $readyWatch.Elapsed.TotalSeconds -gt 10){throw 'PC peer startup failed'}
            Start-Sleep -Milliseconds 20
        }
    }
    $serial=[IO.Ports.SerialPort]::new($Port,115200,'None',8,'One')
    $serial.DtrEnable=$false;$serial.RtsEnable=$false;$serial.ReadTimeout=100
    $raw=[IO.StreamWriter]::new((Join-Path $OutputRoot 'serial.raw.log'),$false,[Text.UTF8Encoding]::new($false))
    $jsonLines=[IO.StreamWriter]::new((Join-Path $OutputRoot 'serial.jsonl'),$false,[Text.UTF8Encoding]::new($false))
    $serial.Open();$watch=[Diagnostics.Stopwatch]::StartNew();$pending='';$phase='NEUTRAL'
    if($Mode -eq 'UsbMapping'){Write-Output "MAPPING_STEP=$MappingStep PHASE=NEUTRAL"}
    while($watch.Elapsed.TotalSeconds -lt $DurationSeconds){
        if($peerProcess -and $peerProcess.HasExited){throw 'PC peer exited during capture'}
        if($Mode -eq 'UsbMapping'){
            if($phase -eq 'NEUTRAL' -and $watch.Elapsed.TotalSeconds -ge 4){$phase='HOLD';Write-Output "MAPPING_STEP=$MappingStep PHASE=HOLD"}
            if($phase -eq 'HOLD' -and $watch.Elapsed.TotalSeconds -ge 10){$phase='RELEASE';Write-Output "MAPPING_STEP=$MappingStep PHASE=RELEASE"}
        }
        $chunk=$serial.ReadExisting()
        if($chunk.Length){
            $raw.Write($chunk);$raw.Flush();$pending+=$chunk
            if($pending.Length -gt 16384){throw 'Serial line exceeded evidence bound'}
            while(($lf=$pending.IndexOf("`n")) -ge 0){
                $line=$pending.Substring(0,$lf).TrimEnd("`r");$pending=$pending.Substring($lf+1)
                @{elapsed_ns=[long]($watch.Elapsed.TotalMilliseconds*1000000);line=$line;utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Compress | ForEach-Object {$jsonLines.WriteLine($_)}
            }
            $jsonLines.Flush()
        }
        Start-Sleep -Milliseconds 5
    }
    $serial.Dispose();$serial=$null;$raw.Dispose();$raw=$null;$jsonLines.Dispose();$jsonLines=$null
    if($peerProcess){
        [IO.File]::WriteAllText((Join-Path $OutputRoot 'peer.stop'),'stop')
        if(!$peerProcess.WaitForExit(10000)){throw 'PC peer did not finish'}
        $peerProcess.Refresh();if($peerProcess.ExitCode -ne 0){throw 'PC peer failed'}
    }
    if($Mode -eq 'UsbMapping'){
        & $python $cli --output (Join-Path $OutputRoot 'mapping-step.json') mapping-step --serial (Join-Path $OutputRoot 'serial.jsonl') --metadata (Join-Path $OutputRoot 'metadata.json') --step $MappingStep
    }elseif($Mode -eq 'LanScreen'){
        & $python $cli --output (Join-Path $OutputRoot 'analysis.json') analyze --serial (Join-Path $OutputRoot 'serial.jsonl') --peer (Join-Path $OutputRoot 'peer.csv') --period-ms $candidate.PeriodMs --limits $TimingLimits
    }else{
        & $python $cli --output (Join-Path $OutputRoot 'analysis.json') passive --serial (Join-Path $OutputRoot 'serial.jsonl')
    }
    if($LASTEXITCODE -ne 0){throw 'Data adjudication failed/incomplete; retain all evidence'}
    $passed=$true
}catch{
    $failure=$_.Exception.Message
    [IO.File]::WriteAllText((Join-Path $OutputRoot 'failure.txt'),$failure)
}finally{
    if($serial){$serial.Dispose()};if($raw){$raw.Dispose()};if($jsonLines){$jsonLines.Dispose()}
    if($peerProcess -and !$peerProcess.HasExited){
        [IO.File]::WriteAllText((Join-Path $OutputRoot 'peer.stop'),'stop')
        if(!$peerProcess.WaitForExit(10000)){
            # Only this runner's child process; preserve log files on failure.
            $peerProcess.Kill();$peerProcess.WaitForExit();$passed=$false
            [IO.File]::WriteAllText((Join-Path $OutputRoot 'peer-forced-stop.txt'),'Owned peer process failed to exit; trial invalid')
        }
    }
    @{passed=$passed;preflight_only=[bool]$PreflightOnly;physical_qualification=$false;failure=$failure}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $OutputRoot 'runner-result.json') -Encoding UTF8
    & $python $cli finalize --root $OutputRoot
    if($LASTEXITCODE -ne 0){throw 'Evidence finalization failed'}
}
if(!$passed){throw "Trial failed/incomplete: $failure; evidence=$OutputRoot"}
Write-Output "TRIAL_DATA_COMPLETE=$OutputRoot"
