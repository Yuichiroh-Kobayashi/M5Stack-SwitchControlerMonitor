[CmdletBinding()]
param(
    [ValidateSet('S1','T1')][string]$Trial = 'S1',
    [switch]$OfflineSelfTest,
    [switch]$EmitUploadPlan,
    [switch]$RunPhysicalTrial,
    [switch]$AllowUpload,
    [switch]$AllowSerial,
    [switch]$AllowPeer,
    [switch]$AllowNetworkTrial,
    [string]$ReviewedManifestPath = '',
    [string]$ExpectedReviewedManifestSha256 = '',
    [string]$ExpectedPnpDeviceId = 'USB\VID_303A&PID_1001&MI_00\6&25A42EA3&0&0000'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$peerScript = Join-Path $PSScriptRoot 'usb_lan_gate_dg_c_peer.py'
$contractPath = Join-Path $repoRoot 'docs\usb-lan-gate-dg-d-contract.md'
$freezeRoot = Join-Path $repoRoot 'build-temp\usb-lan-isolation\freeze\C1-final-20260818-005403-666bf93b'
$freezeZip = "$freezeRoot.zip"
$validationRoot = Join-Path $repoRoot 'build-temp\usb-lan-isolation\implementation-validation\dg-d'
$repairBuildRoot = Join-Path $validationRoot 'repair-build-only-matrix-final'
$physicalEvidenceRoot = Join-Path $repoRoot 'build-temp\usb-lan-isolation\gate-dg-d'
$reviewRoot = Join-Path $repoRoot 'build-temp\usb-lan-isolation\review'
$fqbn = 'm5stack:esp32:m5stack_cores3'
$fixedPnpDeviceId = 'USB\VID_303A&PID_1001&MI_00\6&25A42EA3&0&0000'
$fixedArduinoCliPath = 'C:\Program Files\Arduino IDE\resources\app\lib\backend\resources\arduino-cli.exe'
$requiredArduinoCliVersion = '1.5.1'
$requiredM5StackCoreVersion = '3.3.7'
$requiredPlatformSha256 = 'E778787B6C8521AB1C5F6185AC32398F88DFBE4F943813A8CFF052FE924F152B'
$senderIp = '192.168.50.10'
$peerIp = '192.168.50.30'
$peerPort = 50001
$submissionPort = 50001

$authority = [ordered]@{
    C1Generation = 'C1-final-20260818-005403-666bf93b'
    ArchiveManifestSha256 = 'CBEF2EEB288F72DCCFD35797D994B3D15C3551D2E7CAD0FB423528182358B028'
    FreezeZipSize = [int64]4482569
    FreezeZipSha256 = '41071B6A948768E179C76627A4132C311888491A0DF0510B9533A6CBBEFC12E2'
    BootloaderSize = [int64]19984
    BootloaderSha256 = '5403BA8CDF81CBB47F2DEBE13C0F5FF5903540075CCAF3FAC65F0EE68213CB7D'
    PartitionsSize = [int64]3072
    PartitionsSha256 = 'ACE02503447D0F470692E65FA76002F2D77A92DC81CD3813D8AA66718D716DA9'
    BootApp0Size = [int64]8192
    BootApp0Sha256 = 'F94C5D786A7A8FAB06AC5D10E33BF37711A6697636DC037559EA19CC410A17F0'
    S1ApplicationSize = [int64]565376
    S1ApplicationSha256 = '6CDD986F9B1285D70F0A12E9034D58F51B7216C56A7639DBE2E54791AA33CAC5'
    S1ElfSize = [int64]16096096
    S1ElfSha256 = 'DE500E963EFB58BED380B25267BECF16E9F75A02500D286B8D67ED4089E768D9'
    S1MergedSize = [int64]16777216
    S1MergedSha256 = '4F2340288C517FBBA3AE2F68BA54149DC2C9F3F36D1CEB222A2425134FCA8643'
    T1ApplicationSize = [int64]565376
    T1ApplicationSha256 = '22F26D154EBD62799DCE5BF794D4669A2B53B468BF6A7CA01532A9C4E8789FBF'
    T1ElfSize = [int64]16096096
    T1ElfSha256 = '3422A305D9404850198F9D3E999F55EBAAA8870705EF81134217A4BBF8DFADE0'
    T1MergedSize = [int64]16777216
    T1MergedSha256 = '897722C7AAE88F924E8D334D08AA612EE956EBB871DDEC86B0DB444D904ECBBF'
}

$donors = @(
    [pscustomobject]@{ Role='dg_c_reviewed_manifest'; Relative='build-temp\usb-lan-isolation\review\DG-C-implementation-review-20260823-022104-e096cb3a\authority\DG-C-reviewed-source-manifest.csv'; Size=659; Sha256='AD58C3A8CF6A2562B9EB5AE2C9B3472D73026F26D5239DB905194B5FC0181E24' },
    [pscustomobject]@{ Role='dg_c_peer'; Relative='tools\usb_lan_gate_dg_c_peer.py'; Size=34102; Sha256='0D770B8C02ECCBC382A3F5A484F401A3DF9EF9318701ED0C3A2395EEB66E830A' },
    [pscustomobject]@{ Role='dg_c_runner'; Relative='build-temp\usb-lan-isolation\review\DG-C-implementation-review-20260823-022104-e096cb3a\source\usb_lan_gate_dg_c_runner.ps1'; Size=120080; Sha256='596CCCD96DB83F918013F3EA59C9056CC56B8FBEDB2879530B7B2804294F2D93' },
    [pscustomobject]@{ Role='dg_c_contract'; Relative='build-temp\usb-lan-isolation\review\DG-C-implementation-review-20260823-022104-e096cb3a\contract\usb-lan-gate-dg-c-contract.md'; Size=15249; Sha256='95B4BC00EF362832FB7F43EC38A42D889B797819EB43133D810D48C1436A3E93' }
)
$frozenDgDPeer = [pscustomobject]@{ Size=[int64]34102; Sha256='0D770B8C02ECCBC382A3F5A484F401A3DF9EF9318701ED0C3A2395EEB66E830A' }

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-BytesSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','') }
    finally { $sha.Dispose() }
}

function Assert-FileIdentity(
    [string]$Path,
    [int64]$ExpectedSize,
    [string]$ExpectedSha256,
    [string]$FailureToken
) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$FailureToken missing=$Path" }
    $item = Get-Item -LiteralPath $Path
    $actualHash = Get-Sha256 $Path
    if ($item.Length -ne $ExpectedSize -or $actualHash -cne $ExpectedSha256.ToUpperInvariant()) {
        throw "$FailureToken path=$Path expected_size=$ExpectedSize actual_size=$($item.Length) expected_sha=$ExpectedSha256 actual_sha=$actualHash"
    }
    [pscustomobject]@{ Path=$item.FullName; Size=$item.Length; Sha256=$actualHash }
}

function Get-StageAuthority([ValidateSet('S1','T1')][string]$Stage) {
    $trialId = "DG-D-$Stage-BUILD-ONLY"
    $caseName = "DG-D-$Stage"
    $build = Join-Path $repairBuildRoot "$caseName\build"
    $base = 'M5Stack-PS5CoREUsbLanIsolationDiagnosticDG_D.ino'
    $bootAppPath = Join-Path $env:LOCALAPPDATA 'Arduino15\packages\m5stack\hardware\esp32\3.3.7\tools\partitions\boot_app0.bin'
    [pscustomobject]@{
        Stage = $Stage
        TrialId = $trialId
        DurationSeconds = if ($Stage -eq 'S1') { 10 } else { 60 }
        Application = Join-Path $build "$base.bin"
        ApplicationSize = $authority["${Stage}ApplicationSize"]
        ApplicationSha256 = $authority["${Stage}ApplicationSha256"]
        Elf = Join-Path $build "$base.elf"
        ElfSize = $authority["${Stage}ElfSize"]
        ElfSha256 = $authority["${Stage}ElfSha256"]
        Bootloader = Join-Path $build "$base.bootloader.bin"
        BootloaderSize = $authority.BootloaderSize
        BootloaderSha256 = $authority.BootloaderSha256
        Partitions = Join-Path $build "$base.partitions.bin"
        PartitionsSize = $authority.PartitionsSize
        PartitionsSha256 = $authority.PartitionsSha256
        BootApp0 = $bootAppPath
        BootApp0Size = $authority.BootApp0Size
        BootApp0Sha256 = $authority.BootApp0Sha256
        Merged = Join-Path $build "$base.merged.bin"
        MergedSize = $authority["${Stage}MergedSize"]
        MergedSha256 = $authority["${Stage}MergedSha256"]
    }
}

function Assert-C1FreezeAuthority {
    $manifest = Join-Path $freezeRoot 'archive-manifest.csv'
    Assert-FileIdentity $manifest (Get-Item -LiteralPath $manifest).Length $authority.ArchiveManifestSha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH' | Out-Null
    Assert-FileIdentity $freezeZip $authority.FreezeZipSize $authority.FreezeZipSha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH' | Out-Null
}

function Assert-DonorAuthority {
    $verified = foreach ($donor in $donors) {
        $path = Join-Path $repoRoot $donor.Relative
        $item = Assert-FileIdentity $path $donor.Size $donor.Sha256 'BLOCKED_DG_D_DONOR_AUTHORITY_IDENTITY_UNRESOLVED'
        [pscustomobject]@{ Role=$donor.Role; Path=$item.Path; Size=$item.Size; Sha256=$item.Sha256; Result='PASS' }
    }
    @($verified)
}

function Assert-DgDPeerUnchanged {
    Assert-FileIdentity $peerScript $frozenDgDPeer.Size $frozenDgDPeer.Sha256 'BLOCKED_DG_D_UNEXPECTED_PEER_CHANGE_REQUIRED'
}

function Get-MergedSliceSha256([string]$MergedPath) {
    $stream = [IO.File]::Open($MergedPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        [void]$stream.Seek(0xE000,[IO.SeekOrigin]::Begin)
        $bytes = [byte[]]::new(8192)
        $read = $stream.Read($bytes,0,$bytes.Length)
        if ($read -ne 8192) { throw 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH merged_slice_short' }
        Get-BytesSha256 $bytes
    } finally { $stream.Dispose() }
}

function Assert-StageAuthority([ValidateSet('S1','T1')][string]$Stage) {
    Assert-C1FreezeAuthority
    $a = Get-StageAuthority $Stage
    $verified = @(
        Assert-FileIdentity $a.Application $a.ApplicationSize $a.ApplicationSha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH'
        Assert-FileIdentity $a.Elf $a.ElfSize $a.ElfSha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH'
        Assert-FileIdentity $a.Bootloader $a.BootloaderSize $a.BootloaderSha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH'
        Assert-FileIdentity $a.Partitions $a.PartitionsSize $a.PartitionsSha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH'
        Assert-FileIdentity $a.BootApp0 $a.BootApp0Size $a.BootApp0Sha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH'
        Assert-FileIdentity $a.Merged $a.MergedSize $a.MergedSha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH'
    )
    $sliceHash = Get-MergedSliceSha256 $a.Merged
    if ($sliceHash -cne $a.BootApp0Sha256) {
        throw "BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH boot_app0_merged_slice expected=$($a.BootApp0Sha256) actual=$sliceHash"
    }
    [pscustomobject]@{ Authority=$a; Files=$verified; MergedBootApp0SliceSha256=$sliceHash }
}

function Assert-ChildPath([string]$Parent,[string]$Child) {
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $childFull = [IO.Path]::GetFullPath($Child)
    if (!$childFull.StartsWith($parentFull,[StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe child path: $childFull is outside $parentFull"
    }
}

function Get-RelativePathCompat([string]$BasePath,[string]$TargetPath) {
    $baseFull=[IO.Path]::GetFullPath($BasePath).TrimEnd('\')+'\'
    $targetFull=[IO.Path]::GetFullPath($TargetPath)
    $baseUri=[Uri]::new($baseFull)
    $targetUri=[Uri]::new($targetFull)
    [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($targetUri).ToString()).Replace('/','\')
}

function New-DgDArtifactStaging([ValidateSet('S1','T1')][string]$Stage,[string]$Root,[switch]$UseRootAsStaging) {
    $verified = Assert-StageAuthority $Stage
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $stagePath = if($UseRootAsStaging){[IO.Path]::GetFullPath($Root)}else{Join-Path $Root ("DG-D-{0}-{1}-{2}" -f $Stage,(Get-Date -Format 'yyyyMMdd-HHmmss'),([guid]::NewGuid().ToString('N').Substring(0,8)))}
    if(!$UseRootAsStaging){Assert-ChildPath $Root $stagePath;New-Item -ItemType Directory -Path $stagePath | Out-Null}
    $a = $verified.Authority
    $targets = [ordered]@{
        Application = Join-Path $stagePath ([IO.Path]::GetFileName($a.Application))
        Bootloader = Join-Path $stagePath ([IO.Path]::GetFileName($a.Bootloader))
        Partitions = Join-Path $stagePath ([IO.Path]::GetFileName($a.Partitions))
        BootApp0 = Join-Path $stagePath 'boot_app0.bin'
        Merged = Join-Path $stagePath ([IO.Path]::GetFileName($a.Merged))
    }
    Copy-Item -LiteralPath $a.Application -Destination $targets.Application
    Copy-Item -LiteralPath $a.Bootloader -Destination $targets.Bootloader
    Copy-Item -LiteralPath $a.Partitions -Destination $targets.Partitions
    Copy-Item -LiteralPath $a.BootApp0 -Destination $targets.BootApp0
    Copy-Item -LiteralPath $a.Merged -Destination $targets.Merged
    Assert-FileIdentity $targets.Application $a.ApplicationSize $a.ApplicationSha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH' | Out-Null
    Assert-FileIdentity $targets.Bootloader $a.BootloaderSize $a.BootloaderSha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH' | Out-Null
    Assert-FileIdentity $targets.Partitions $a.PartitionsSize $a.PartitionsSha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH' | Out-Null
    Assert-FileIdentity $targets.BootApp0 $a.BootApp0Size $a.BootApp0Sha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH' | Out-Null
    Assert-FileIdentity $targets.Merged $a.MergedSize $a.MergedSha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH' | Out-Null
    if ((Get-MergedSliceSha256 $targets.Merged) -cne (Get-Sha256 $targets.BootApp0)) {
        throw 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH staged_boot_app0_merged_slice'
    }
    [pscustomobject]@{ Stage=$Stage; Path=$stagePath; Authority=$a; Files=[pscustomobject]$targets }
}

function Assert-StagedArtifactIdentity([pscustomobject]$Staging) {
    $a=$Staging.Authority
    Assert-FileIdentity $Staging.Files.Application $a.ApplicationSize $a.ApplicationSha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH'|Out-Null
    Assert-FileIdentity $Staging.Files.Bootloader $a.BootloaderSize $a.BootloaderSha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH'|Out-Null
    Assert-FileIdentity $Staging.Files.Partitions $a.PartitionsSize $a.PartitionsSha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH'|Out-Null
    Assert-FileIdentity $Staging.Files.BootApp0 $a.BootApp0Size $a.BootApp0Sha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH'|Out-Null
    Assert-FileIdentity $Staging.Files.Merged $a.MergedSize $a.MergedSha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH'|Out-Null
    Assert-FileIdentity $a.BootApp0 $a.BootApp0Size $a.BootApp0Sha256 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH'|Out-Null
    if((Get-MergedSliceSha256 $Staging.Files.Merged) -cne $a.BootApp0Sha256){throw 'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH staged_boot_app0_merged_slice'}
    $true
}

function Get-DgDToolchainAuthority([string]$CliPath=$fixedArduinoCliPath,[string]$CliVersionOverride='',[string]$CoreVersionOverride='') {
    $coreVersion=if($CoreVersionOverride){$CoreVersionOverride}else{$requiredM5StackCoreVersion}
    $corePath=Join-Path $env:LOCALAPPDATA "Arduino15\packages\m5stack\hardware\esp32\$coreVersion"
    $platformPath=Join-Path $corePath 'platform.txt'
    $bootApp0Path=Join-Path $corePath 'tools\partitions\boot_app0.bin'
    if(!(Test-Path -LiteralPath $CliPath -PathType Leaf)){throw 'BLOCKED_DG_D_UPLOAD_TOOLCHAIN_IDENTITY_MISMATCH cli_missing'}
    if(!(Test-Path -LiteralPath $platformPath -PathType Leaf)){throw 'BLOCKED_DG_D_UPLOAD_TOOLCHAIN_IDENTITY_MISMATCH platform_missing'}
    if(!(Test-Path -LiteralPath $bootApp0Path -PathType Leaf)){throw 'BLOCKED_DG_D_UPLOAD_TOOLCHAIN_IDENTITY_MISMATCH boot_app0_missing'}
    $cliVersion=$CliVersionOverride
    if(!$cliVersion){
        $versionOutput=& $CliPath version 2>&1 | Out-String
        if($LASTEXITCODE -ne 0 -or $versionOutput -notmatch 'Version:\s*([0-9]+(?:\.[0-9]+){2})'){throw 'BLOCKED_DG_D_UPLOAD_TOOLCHAIN_IDENTITY_MISMATCH cli_version_unresolved'}
        $cliVersion=$matches[1]
    }
    $record=[pscustomobject]@{
        ARDUINO_CLI_PATH=[IO.Path]::GetFullPath($CliPath)
        ARDUINO_CLI_VERSION=$cliVersion
        M5STACK_CORE_PATH=[IO.Path]::GetFullPath($corePath)
        M5STACK_CORE_VERSION=$coreVersion
        PLATFORM_TXT_PATH=[IO.Path]::GetFullPath($platformPath)
        PLATFORM_TXT_SHA256=Get-Sha256 $platformPath
        BOOT_APP0_ACTUAL_PATH=[IO.Path]::GetFullPath($bootApp0Path)
        BOOT_APP0_ACTUAL_SHA256=Get-Sha256 $bootApp0Path
    }
    if($record.ARDUINO_CLI_PATH -cne $fixedArduinoCliPath -or $record.ARDUINO_CLI_VERSION -cne $requiredArduinoCliVersion -or
       $record.M5STACK_CORE_VERSION -cne $requiredM5StackCoreVersion -or $record.PLATFORM_TXT_SHA256 -cne $requiredPlatformSha256 -or
       $record.BOOT_APP0_ACTUAL_SHA256 -cne $authority.BootApp0Sha256){throw 'BLOCKED_DG_D_UPLOAD_TOOLCHAIN_IDENTITY_MISMATCH'}
    $record
}

function Get-DgDArtifactIdentityRows([pscustomobject]$Staging,[pscustomobject]$Toolchain,[ValidateSet('PRE_UPLOAD','POST_UPLOAD')][string]$Phase) {
    $a=$Staging.Authority
    @(
        [pscustomobject]@{ARTIFACT_IDENTITY_PHASE=$Phase;Role='application';Offset='0x10000';Path=$Staging.Files.Application;Size=(Get-Item $Staging.Files.Application).Length;Sha256=Get-Sha256 $Staging.Files.Application}
        [pscustomobject]@{ARTIFACT_IDENTITY_PHASE=$Phase;Role='bootloader';Offset='0x0000';Path=$Staging.Files.Bootloader;Size=(Get-Item $Staging.Files.Bootloader).Length;Sha256=Get-Sha256 $Staging.Files.Bootloader}
        [pscustomobject]@{ARTIFACT_IDENTITY_PHASE=$Phase;Role='partitions';Offset='0x8000';Path=$Staging.Files.Partitions;Size=(Get-Item $Staging.Files.Partitions).Length;Sha256=Get-Sha256 $Staging.Files.Partitions}
        [pscustomobject]@{ARTIFACT_IDENTITY_PHASE=$Phase;Role='boot_app0_staged_evidence';Offset='0xE000';Path=$Staging.Files.BootApp0;Size=(Get-Item $Staging.Files.BootApp0).Length;Sha256=Get-Sha256 $Staging.Files.BootApp0}
        [pscustomobject]@{ARTIFACT_IDENTITY_PHASE=$Phase;Role='boot_app0_actual_upload_input';Offset='0xE000';Path=$Toolchain.BOOT_APP0_ACTUAL_PATH;Size=(Get-Item $Toolchain.BOOT_APP0_ACTUAL_PATH).Length;Sha256=Get-Sha256 $Toolchain.BOOT_APP0_ACTUAL_PATH}
        [pscustomobject]@{ARTIFACT_IDENTITY_PHASE=$Phase;Role='merged_authority_not_uploaded';Offset='NOT_UPLOADED';Path=$Staging.Files.Merged;Size=(Get-Item $Staging.Files.Merged).Length;Sha256=Get-Sha256 $Staging.Files.Merged}
        [pscustomobject]@{ARTIFACT_IDENTITY_PHASE=$Phase;Role='merged_0xE000_slice';Offset='0xE000';Path="$($Staging.Files.Merged)#offset=0xE000,length=8192";Size=[int64]8192;Sha256=Get-MergedSliceSha256 $Staging.Files.Merged}
    )
}

function Assert-DgDArtifactIdentityRows([object[]]$Rows,[pscustomobject]$Staging) {
    $expected=[ordered]@{
        application=@($Staging.Authority.ApplicationSize,$Staging.Authority.ApplicationSha256)
        bootloader=@($Staging.Authority.BootloaderSize,$Staging.Authority.BootloaderSha256)
        partitions=@($Staging.Authority.PartitionsSize,$Staging.Authority.PartitionsSha256)
        boot_app0_staged_evidence=@($Staging.Authority.BootApp0Size,$Staging.Authority.BootApp0Sha256)
        boot_app0_actual_upload_input=@($Staging.Authority.BootApp0Size,$Staging.Authority.BootApp0Sha256)
        merged_authority_not_uploaded=@($Staging.Authority.MergedSize,$Staging.Authority.MergedSha256)
        merged_0xE000_slice=@([int64]8192,$Staging.Authority.BootApp0Sha256)
    }
    if(@($Rows).Count -ne $expected.Count){throw 'BLOCKED_DG_D_UPLOAD_ARTIFACT_IDENTITY_DRIFT row_count'}
    foreach($role in $expected.Keys){
        $row=@($Rows|Where-Object Role -ceq $role)
        if($row.Count -ne 1 -or [int64]$row[0].Size -ne [int64]$expected[$role][0] -or $row[0].Sha256 -cne $expected[$role][1]){throw "BLOCKED_DG_D_UPLOAD_ARTIFACT_IDENTITY_DRIFT role=$role"}
    }
    $true
}

function Compare-DgDArtifactIdentityRows([object[]]$Pre,[object[]]$Post) {
    foreach($preRow in $Pre){
        $postRow=@($Post|Where-Object Role -ceq $preRow.Role)
        if($postRow.Count -ne 1 -or $postRow[0].Path -cne $preRow.Path -or [int64]$postRow[0].Size -ne [int64]$preRow.Size -or $postRow[0].Sha256 -cne $preRow.Sha256){throw "BLOCKED_DG_D_UPLOAD_ARTIFACT_IDENTITY_DRIFT role=$($preRow.Role)"}
    }
    $true
}

function Get-DgDUploadPlan([pscustomobject]$Staging) {
    $command = "`"$fixedArduinoCliPath`" upload --fqbn $fqbn --port COM4 --input-dir `"$($Staging.Path)`""
    [pscustomobject]@{
        Stage=$Staging.Stage
        StagingPath=$Staging.Path
        Command=$command
        Build='NOT_RUN'
        Compile='NOT_RUN'
        WholeFlashMergedUpload='PROHIBITED'
        Segments=@(
            [pscustomobject]@{ Offset='0x0000'; Role='bootloader'; Path=$Staging.Files.Bootloader; StagedEvidencePath=$Staging.Files.Bootloader; Sha256=$Staging.Authority.BootloaderSha256 }
            [pscustomobject]@{ Offset='0x8000'; Role='partitions'; Path=$Staging.Files.Partitions; StagedEvidencePath=$Staging.Files.Partitions; Sha256=$Staging.Authority.PartitionsSha256 }
            [pscustomobject]@{ Offset='0xE000'; Role='boot_app0'; Path=$Staging.Authority.BootApp0; StagedEvidencePath=$Staging.Files.BootApp0; Sha256=$Staging.Authority.BootApp0Sha256 }
            [pscustomobject]@{ Offset='0x10000'; Role='application'; Path=$Staging.Files.Application; StagedEvidencePath=$Staging.Files.Application; Sha256=$Staging.Authority.ApplicationSha256 }
        )
    }
}

function Test-DgDUploadEvidence([string]$StdoutPath,[pscustomobject]$StageAuthority) {
    if(!(Test-Path -LiteralPath $StdoutPath -PathType Leaf)){return $false}
    $text=Get-Content -LiteralPath $StdoutPath -Raw
    $expected=@(
        @{Size=$StageAuthority.BootloaderSize;Offset='00000000'},
        @{Size=$StageAuthority.PartitionsSize;Offset='00008000'},
        @{Size=$StageAuthority.BootApp0Size;Offset='0000e000'},
        @{Size=$StageAuthority.ApplicationSize;Offset='00010000'}
    )
    foreach($segment in $expected){
        if($text -notmatch "Wrote\s+$($segment.Size)\s+bytes\s+\([^\r\n]+\)\s+at\s+0x$($segment.Offset)\b"){return $false}
    }
    if(([regex]::Matches($text,'(?m)^Hash of data verified\.\s*$')).Count -ne 4){return $false}
    if($text -notmatch '(?m)^Hard resetting via RTS pin\.\.\.\s*$'){return $false}
    $true
}

function Get-Com4IdentityRecords {
    @(
        Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
        Where-Object { $_.Name -match '\(COM4\)' } |
        ForEach-Object {[pscustomobject]@{Name=[string]$_.Name;PNPDeviceID=[string]$_.PNPDeviceID}}
    )
}

function Test-ExactCom4Identity([object[]]$Records,[string]$ExpectedPnp=$fixedPnpDeviceId) {
    if($ExpectedPnp -cne $fixedPnpDeviceId){return $false}
    $matches=@($Records|Where-Object{$_.Name -match '\(COM4\)' -and $_.PNPDeviceID -ceq $fixedPnpDeviceId})
    @($Records).Count -eq 1 -and $matches.Count -eq 1
}

function Wait-ExactCom4Reenumeration([string]$ExpectedPnp,[int]$TimeoutSeconds=15) {
    if($ExpectedPnp -cne $fixedPnpDeviceId){throw 'BLOCKED_DG_D_COM4_PNP_IDENTITY'}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds){
        try{$records=Get-Com4IdentityRecords;if(Test-ExactCom4Identity $records $ExpectedPnp){return $records[0]}}catch{}
        Start-Sleep -Milliseconds 100
    }
    throw 'BLOCKED_DG_D_COM4_REENUMERATION'
}

function Test-DgDPeerTopologyRecords([object[]]$IpRecords,[object[]]$AdapterRecords,[object[]]$RouteRecords,[object[]]$GatewayRecords) {
    $matched=@($IpRecords|Where-Object{$_.IPAddress -ceq $peerIp -and [int]$_.PrefixLength -eq 24})
    if($matched.Count -ne 1){return $false}
    $ifIndex=[int]$matched[0].InterfaceIndex
    $adapters=@($AdapterRecords|Where-Object{[int]$_.InterfaceIndex -eq $ifIndex -and $_.Status -ceq 'Up'})
    if($adapters.Count -ne 1){return $false}
    if(@($GatewayRecords|Where-Object{[int]$_.InterfaceIndex -eq $ifIndex -and $_.NextHop -notin @('','0.0.0.0')}).Count -ne 0){return $false}
    $direct=@($RouteRecords|Where-Object{[int]$_.InterfaceIndex -eq $ifIndex -and $_.DestinationPrefix -ceq '192.168.50.0/24' -and $_.NextHop -ceq '0.0.0.0'})
    $direct.Count -eq 1
}

function Assert-DgDPeerTopology {
    $ips=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop)
    $adapters=@(Get-NetAdapter -ErrorAction Stop)
    $routes=@(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop)
    $gateways=@(Get-NetIPConfiguration -ErrorAction Stop|ForEach-Object{foreach($g in @($_.IPv4DefaultGateway)){if($null-ne $g){[pscustomobject]@{InterfaceIndex=$_.InterfaceIndex;NextHop=[string]$g.NextHop}}}})
    if(!(Test-DgDPeerTopologyRecords $ips $adapters $routes $gateways)){throw 'BLOCKED_DG_D_PEER_TOPOLOGY'}
}

function Test-DgDControlPlaneTrace([string[]]$Events) {
    $serialReady=[Array]::IndexOf($Events,'SERIAL_CAPTURE_READY')
    $arm=[Array]::IndexOf($Events,'ARM_REQUESTED')
    $serialFailed=[Array]::IndexOf($Events,'SERIAL_CAPTURE_OPEN_FAILED')
    if($arm -ge 0 -and ($serialReady -lt 0 -or $serialReady -gt $arm)){return $false}
    if($serialFailed -ge 0 -and $arm -ge 0){return $false}
    $true
}

function Test-DgDTerminalMarkerChunks([string[]]$Chunks) {
    $builder=[Text.StringBuilder]::new()
    foreach($chunk in $Chunks){[void]$builder.Append($chunk);if($builder.ToString().Contains('SCOPE_MARKER trial=DG-D event=TRIAL_COMPLETE')){return $true}}
    $false
}

function Write-ExactUtf8Text([string]$Path,[string]$Text) {
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}

function Convert-KeyValueLine([string]$Line) {
    $fields = [ordered]@{}
    $duplicate = $false
    foreach ($match in [regex]::Matches($Line,'(?:^|\s)([A-Z0-9_]+)=([^\s]+)')) {
        $key = $match.Groups[1].Value
        if ($fields.Contains($key)) { $duplicate = $true } else { $fields[$key] = $match.Groups[2].Value }
    }
    [pscustomobject]@{ Fields=$fields; Duplicate=$duplicate }
}

function Test-Decimal([object]$Map,[string]$Key) {
    if (!$Map.Contains($Key) -or $Map[$Key] -notmatch '^\d+$') { return $null }
    $value = [uint64]0
    if (![uint64]::TryParse($Map[$Key],[ref]$value)) { return $null }
    $value
}

function Test-HexByte([object]$Map,[string]$Key) {
    if (!$Map.Contains($Key) -or $Map[$Key] -notmatch '^[0-9A-Fa-f]{2}$') { return $null }
    [Convert]::ToUInt32($Map[$Key],16)
}

function Get-DgDRawProvisionalPrimary([string]$SerialText) {
    if ($SerialText -match 'USB_DETACH') { return 'DG_D_USB_HID_FAIL' }
    if ($SerialText -match '(?m)REASON=USB_DETACH_OR_UNSUPPORTED(?:\s|$)') { return 'DG_D_USB_HID_FAIL' }
    if ($SerialText -match '(?m)REASON=HID_STALL(?:\s|$)') { return 'DG_D_USB_HID_FAIL' }
    'NONE'
}

function Test-DgDSerialLog([string]$Text) {
    try {
        $provisional = Get-DgDRawProvisionalPrimary $Text
        $lines = @($Text -split '\r?\n')
        $c1Indexes=@();$rxIndexes=@();$drainIndexes=@();$terminalIndexes=@();$scopeIndexes=@();$setupIndexes=@()
        for ($i=0;$i -lt $lines.Count;$i++) {
            if ($lines[$i] -match '^C1_FINAL\s') { $c1Indexes += $i }
            if ($lines[$i] -match '^DG_D_FINAL\s+RX_PARSE_CALL_STARTED_TOTAL=') { $rxIndexes += $i }
            if ($lines[$i] -match '^DG_D_FINAL\s+DRAIN_TARGET_TX_TOTAL=') { $drainIndexes += $i }
            if ($lines[$i] -match '(?:^|\s)TEST_COMPLETE=(?:PASS|FAIL)(?:\s|$)') { $terminalIndexes += $i }
            if ($lines[$i] -match '^SCOPE_MARKER trial=DG-D event=TRIAL_COMPLETE result=(?:PASS|FAIL)$') { $scopeIndexes += $i }
            if ($lines[$i] -match '^C1_SETUP_FAIL=1\s') { $setupIndexes += $i }
        }
        $noEvidence = $c1Indexes.Count -eq 0 -and $rxIndexes.Count -eq 0 -and $terminalIndexes.Count -eq 0 -and $setupIndexes.Count -eq 0 -and $provisional -eq 'NONE'
        $setupReasons = @('W5100_INIT','CHIP_ID','VERSIONR','BUFFER_MAP_INIT','PHY_PROFILE','PHY_PROFILE_READBACK','BUFFER_MAP_FIXED10','NETWORK_CONFIG','PHY_AFTER_NETWORK_CONFIG','BUFFER_MAP_NETWORK_CONFIG','LINK_PROFILE_CHANGED','LINK_TIMEOUT','UDP_BEGIN','UDP_SOCKET','PHY_AFTER_UDP_BEGIN','BUFFER_MAP_UDP_BEGIN','VERSION_AFTER_UDP_BEGIN','BUFFER_MAP_USB_INIT','USB_INIT','PHY_DURING_USB_STABILITY','HORI_READY')
        if ($setupIndexes.Count -gt 0) {
            $valid = $setupIndexes.Count -eq 1 -and $c1Indexes.Count -eq 0 -and $rxIndexes.Count -eq 0 -and $terminalIndexes.Count -eq 1 -and $scopeIndexes.Count -eq 1
            $setup = Convert-KeyValueLine $lines[$setupIndexes[0]]
            $terminal = Convert-KeyValueLine $lines[$terminalIndexes[0]]
            $scopePass = $lines[$scopeIndexes[0]] -ceq 'SCOPE_MARKER trial=DG-D event=TRIAL_COMPLETE result=FAIL'
            $reason = if ($setup.Fields.Contains('REASON')) { $setup.Fields.REASON } else { '' }
            $valid = $valid -and !$setup.Duplicate -and !$terminal.Duplicate -and $scopePass -and $setupReasons -contains $reason
            $valid = $valid -and $terminal.Fields.TEST_COMPLETE -ceq 'FAIL' -and $terminal.Fields.TEST_MODE -ceq '18' -and $terminal.Fields.TEST_MODE_NAME -ceq 'USB_FIXED10_UDP_POSITIVE_PARSE_IMMEDIATE_NULL_DISCARD' -and $terminal.Fields.REASON -ceq $reason
            return [pscustomobject]@{ EvidenceContractValid=$valid; LogicalPass=$false; Schema='SETUP_FAILURE'; Fields=$terminal.Fields; Reason=$reason; Completion='FAIL'; ProvisionalPrimary=$provisional; NoEvidence=$noEvidence; Reasons=@() }
        }
        $valid = $c1Indexes.Count -eq 1 -and $rxIndexes.Count -eq 1 -and $drainIndexes.Count -eq 1 -and $terminalIndexes.Count -eq 1 -and $scopeIndexes.Count -eq 1
        if (!$valid) { return [pscustomobject]@{ EvidenceContractValid=$false; LogicalPass=$false; Schema='INVALID'; Fields=[ordered]@{}; Reason=''; Completion=''; ProvisionalPrimary=$provisional; NoEvidence=$noEvidence; Reasons=@('line_count_or_schema') } }
        $valid = $c1Indexes[0] -lt $rxIndexes[0] -and $rxIndexes[0] -lt $drainIndexes[0] -and $drainIndexes[0] -lt $terminalIndexes[0] -and $terminalIndexes[0] -lt $scopeIndexes[0]
        $final = Convert-KeyValueLine $lines[$c1Indexes[0]]
        $rx = Convert-KeyValueLine $lines[$rxIndexes[0]]
        $drain = Convert-KeyValueLine $lines[$drainIndexes[0]]
        $terminal = Convert-KeyValueLine $lines[$terminalIndexes[0]]
        $valid = $valid -and !$final.Duplicate -and !$rx.Duplicate -and !$drain.Duplicate -and !$terminal.Duplicate
        $finalRequired = @('UDP_TX_TOTAL','UDP_TX_FAIL','UDP_BEGIN_COUNT','UDP_BEGIN_FAIL','UDP_BEGIN_MAX_US','UDP_BEGIN_PACKET_MAX_US','UDP_WRITE_MAX_US','UDP_END_PACKET_MAX_US','UDP_MAX_GAP_US','SCHEDULER_MISSED_DEADLINE','SCHEDULER_MAX_LATENESS_US','LOOP_MAX_US','HID_STALL_COUNT','HID_MAX_NO_REPORT_MS')
        $rxRequired=@('RX_PARSE_CALL_STARTED_TOTAL','RX_PARSE_CALL_COMPLETED_TOTAL','RX_PARSE_ZERO_TOTAL','RX_PARSE_POSITIVE_TOTAL','RX_PARSE_NEGATIVE_TOTAL','RX_POSITIVE_SIZE_32_TOTAL','RX_POSITIVE_OTHER_SIZE_TOTAL','RX_PRE_PARSE_REMAINING_NONZERO','RX_NULL_DISCARD_CALL_TOTAL','RX_NULL_DISCARD_RETURN_TOTAL','RX_NULL_DISCARD_REQUEST_BYTES_TOTAL','RX_NULL_DISCARD_BYTES_TOTAL','RX_NULL_DISCARD_FAIL_TOTAL','RX_POST_DISCARD_REMAINING_NONZERO','RX_PARSE_MAX_US','RX_NULL_DISCARD_MAX_US','RX_TREATMENT_MAX_US')
        $drainRequired=@('DRAIN_TARGET_TX_TOTAL','DRAIN_ENTER_MS','DRAIN_COMPLETE_MS','DRAIN_TIMEOUT_MS','DRAIN_QUIET_REQUIRED_MS','DRAIN_QUIET_OBSERVED_MS','DRAIN_PARSE_POSITIVE_START_TOTAL','DRAIN_PARSE_POSITIVE_END_TOTAL','DRAIN_ZERO_CONFIRMATION_TOTAL')
        $terminalDecimal = @('DURATION_MS','TRIAL_RUNTIME_MS','FINAL_HID_READY','HID_READY_DROP','HID_STALL_COUNT','HID_MAX_NO_REPORT_MS','HID_REPORT_TOTAL','FINAL_PHY_OK','FINAL_VERSION_OK','FINAL_BUFFER_MAP_OK','MAX_REGISTER_TRIPLE_READ_MISMATCH','SPI_CORRUPTION_SUSPECTED')
        $values = [ordered]@{}
        foreach ($key in $finalRequired) { $value=Test-Decimal $final.Fields $key; if ($null -eq $value) {$valid=$false} else {$values[$key]=$value} }
        foreach ($key in $rxRequired) { $value=Test-Decimal $rx.Fields $key; if ($null -eq $value) {$valid=$false} else {$values[$key]=$value} }
        foreach ($key in $drainRequired) { $value=Test-Decimal $drain.Fields $key; if ($null -eq $value) {$valid=$false} else {$values[$key]=$value} }
        foreach ($key in $terminalDecimal) { $value=Test-Decimal $terminal.Fields $key; if ($null -eq $value) {$valid=$false} else {$values["TERMINAL_$key"]=$value} }
        $usbState=Test-HexByte $terminal.Fields 'FINAL_USB_STATE'; $version=Test-HexByte $terminal.Fields 'VERSIONR'
        if ($null -eq $usbState -or $null -eq $version) {$valid=$false} else {$values.FINAL_USB_STATE=$usbState;$values.VERSIONR=$version}
        foreach ($key in @('TEST_COMPLETE','TEST_MODE','TEST_MODE_NAME','REASON','VID','PID','SCOPE_RESULT')) { if (!$terminal.Fields.Contains($key)) {$valid=$false} }
        foreach($key in @('RX_POSITIVE_OTHER_SIZE_FIRST','RX_POSITIVE_OTHER_SIZE_LAST','RX_NULL_DISCARD_LAST_RETURN')){if(!$rx.Fields.Contains($key)-or$rx.Fields[$key]-notmatch '^-?\d+$'){$valid=$false}else{$values[$key]=[int64]$rx.Fields[$key]}}
        foreach($key in @('DG_D_PHASE')){if(!$rx.Fields.Contains($key)){$valid=$false}}
        foreach($key in @('DRAIN_RESULT','DRAIN_BLOCK_REASON')){if(!$drain.Fields.Contains($key)){$valid=$false}}
        $reason = if ($terminal.Fields.Contains('REASON')) {$terminal.Fields.REASON} else {''}
        $completion = if ($terminal.Fields.Contains('TEST_COMPLETE')) {$terminal.Fields.TEST_COMPLETE} else {''}
        $scopeExpected = "SCOPE_MARKER trial=DG-D event=TRIAL_COMPLETE result=$completion"
        $valid = $valid -and $lines[$scopeIndexes[0]] -ceq $scopeExpected
        $valid = $valid -and $terminal.Fields.TEST_MODE -ceq '18' -and $terminal.Fields.TEST_MODE_NAME -ceq 'USB_FIXED10_UDP_POSITIVE_PARSE_IMMEDIATE_NULL_DISCARD'
        # updateUsbIdentity() clears identity when HID is no longer ready. A zero
        # terminal identity is evidence of a target loss only with pretrial proof.
        $targetIdentity = $terminal.Fields.VID -ceq '0F0D' -and $terminal.Fields.PID -ceq '0202'
        $lostTargetIdentity = $false
        if ($terminal.Fields.VID -ceq '0000' -and $terminal.Fields.PID -ceq '0000' -and
            $completion -ceq 'FAIL' -and $reason -ceq 'USB_DETACH_OR_UNSUPPORTED' -and
            $values.TERMINAL_FINAL_HID_READY -eq 0 -and $values.TERMINAL_HID_READY_DROP -gt 0 -and
            $values.TERMINAL_HID_REPORT_TOTAL -gt 0) {
            $readyIndexes=@(); $startIndexes=@()
            for ($i=0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^C1_READY=') { $readyIndexes += $i }
                if ($lines[$i] -ceq 'DIAGNOSTIC_START') { $startIndexes += $i }
            }
            if ($readyIndexes.Count -eq 1 -and $startIndexes.Count -eq 1 -and
                $readyIndexes[0] -lt $startIndexes[0] -and $startIndexes[0] -lt $c1Indexes[0]) {
                $ready=Convert-KeyValueLine $lines[$readyIndexes[0]]
                $usbStable=Test-Decimal $ready.Fields 'USB_STABLE_MS'
                $linkStable=Test-Decimal $ready.Fields 'LINK_STABLE_MS'
                $lostTargetIdentity = !$ready.Duplicate -and $ready.Fields.C1_READY -ceq '1' -and
                    $ready.Fields.USB_STATE -ceq '90' -and $ready.Fields.HID_READY -ceq '1' -and
                    $ready.Fields.VID -ceq '0F0D' -and $ready.Fields.PID -ceq '0202' -and
                    $null -ne $usbStable -and $usbStable -ge 1000 -and $null -ne $linkStable -and $linkStable -ge 500
            }
        }
        $valid = $valid -and ($targetIdentity -or $lostTargetIdentity) -and $terminal.Fields.SCOPE_RESULT -ceq 'NOT_CAPTURED'
        if($Text -match '(?m)(?:^|\s)RESET_REASON=(?:PANIC|WDT|BROWNOUT)(?:\s|$)'){$valid=$false}
        foreach($overlap in @('HID_STALL_COUNT','HID_MAX_NO_REPORT_MS')){
            $terminalKey="TERMINAL_$overlap"
            if(!$values.Contains($overlap) -or !$values.Contains($terminalKey) -or $values[$overlap] -ne $values[$terminalKey]){$valid=$false}
        }
        $logical = $valid -and $completion -ceq 'PASS' -and $reason -ceq 'DRAIN_COMPLETE' -and $rx.Fields.DG_D_PHASE -ceq 'COMPLETE' -and $drain.Fields.DRAIN_RESULT -ceq 'PASS' -and $drain.Fields.DRAIN_BLOCK_REASON -ceq 'NONE' -and
            $values.UDP_TX_TOTAL -gt 0 -and $values.UDP_TX_FAIL -eq 0 -and $values.UDP_BEGIN_COUNT -eq 1 -and $values.UDP_BEGIN_FAIL -eq 0 -and
            $values.SCHEDULER_MISSED_DEADLINE -eq 0 -and $values.TERMINAL_DURATION_MS -gt 0 -and $values.TERMINAL_TRIAL_RUNTIME_MS -gt 0 -and $values.TERMINAL_HID_REPORT_TOTAL -gt 0 -and
            $values.HID_STALL_COUNT -eq 0 -and $values.FINAL_USB_STATE -eq 0x90 -and $values.TERMINAL_FINAL_HID_READY -eq 1 -and
            $values.TERMINAL_HID_READY_DROP -eq 0 -and $values.TERMINAL_FINAL_PHY_OK -eq 1 -and $values.TERMINAL_FINAL_VERSION_OK -eq 1 -and
            $values.TERMINAL_FINAL_BUFFER_MAP_OK -eq 1 -and $values.VERSIONR -eq 0x04 -and
            $values.TERMINAL_MAX_REGISTER_TRIPLE_READ_MISMATCH -eq 0 -and $values.TERMINAL_SPI_CORRUPTION_SUSPECTED -eq 0 -and
            $values.RX_PARSE_CALL_STARTED_TOTAL -eq $values.RX_PARSE_CALL_COMPLETED_TOTAL -and
            $values.RX_PARSE_CALL_COMPLETED_TOTAL -eq ($values.RX_PARSE_ZERO_TOTAL+$values.RX_PARSE_POSITIVE_TOTAL+$values.RX_PARSE_NEGATIVE_TOTAL) -and
            $values.RX_PARSE_NEGATIVE_TOTAL -eq 0 -and $values.RX_PARSE_POSITIVE_TOTAL -gt 0 -and
            $values.RX_POSITIVE_SIZE_32_TOTAL -eq $values.RX_PARSE_POSITIVE_TOTAL -and $values.RX_POSITIVE_OTHER_SIZE_TOTAL -eq 0 -and
            $values.RX_PRE_PARSE_REMAINING_NONZERO -eq 0 -and $values.RX_NULL_DISCARD_CALL_TOTAL -eq $values.RX_PARSE_POSITIVE_TOTAL -and
            $values.RX_NULL_DISCARD_RETURN_TOTAL -eq $values.RX_PARSE_POSITIVE_TOTAL -and $values.RX_NULL_DISCARD_REQUEST_BYTES_TOTAL -eq (32*$values.RX_PARSE_POSITIVE_TOTAL) -and
            $values.RX_NULL_DISCARD_BYTES_TOTAL -eq (32*$values.RX_PARSE_POSITIVE_TOTAL) -and $values.RX_NULL_DISCARD_FAIL_TOTAL -eq 0 -and $values.RX_NULL_DISCARD_LAST_RETURN -eq 32 -and
            $values.RX_POST_DISCARD_REMAINING_NONZERO -eq 0 -and $values.DRAIN_TARGET_TX_TOTAL -eq $values.UDP_TX_TOTAL -and
            $values.DRAIN_PARSE_POSITIVE_END_TOTAL -eq $values.RX_PARSE_POSITIVE_TOTAL -and $values.DRAIN_TIMEOUT_MS -eq 1000 -and
            $values.DRAIN_QUIET_REQUIRED_MS -eq 100 -and $values.DRAIN_QUIET_OBSERVED_MS -ge 100
        [pscustomobject]@{ EvidenceContractValid=$valid; LogicalPass=$logical; Schema='RUNTIME'; Fields=$values; Reason=$reason; Completion=$completion; ProvisionalPrimary=$provisional; NoEvidence=$noEvidence; Reasons=@() }
    } catch {
        [pscustomobject]@{ EvidenceContractValid=$false; LogicalPass=$false; Schema='INVALID'; Fields=[ordered]@{}; Reason=''; Completion=''; ProvisionalPrimary=(Get-DgDRawProvisionalPrimary $Text); NoEvidence=$false; Reasons=@("parser_exception:$($_.Exception.Message)") }
    }
}

function Convert-SummaryMap([string]$Text) {
    $map = [ordered]@{}; $duplicate=$false
    foreach ($line in @($Text -split '\r?\n')) {
        if ($line -match '^([A-Z0-9_]+)=(.*)$') {
            if ($map.Contains($matches[1])) {$duplicate=$true} else {$map[$matches[1]]=$matches[2]}
        }
    }
    [pscustomobject]@{ Map=$map; Duplicate=$duplicate }
}

function Test-UInt32OrNone([object]$Map,[string]$Key,[switch]$AllowNa) {
    if(!$Map.Contains($Key)){return $null}
    $raw=[string]$Map[$Key]
    if($raw -ceq 'NONE' -or ($AllowNa -and $raw -ceq 'NA')){return [pscustomobject]@{Valid=$true;IsNumber=$false;Value=$null;Raw=$raw}}
    if($raw -notmatch '^\d+$'){return [pscustomobject]@{Valid=$false;IsNumber=$false;Value=$null;Raw=$raw}}
    $value=[uint64]0
    if(![uint64]::TryParse($raw,[ref]$value) -or $value -gt [uint64]4294967295){return [pscustomobject]@{Valid=$false;IsNumber=$false;Value=$null;Raw=$raw}}
    [pscustomobject]@{Valid=$true;IsNumber=$true;Value=$value;Raw=$raw}
}

function Test-FiniteNonnegative([object]$Map,[string]$Key) {
    if(!$Map.Contains($Key)){return $null}
    $value=[double]0
    $ok=[double]::TryParse([string]$Map[$Key],[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$value)
    if(!$ok -or [double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0){return $null}
    $value
}

function Test-DgDPeerSummary([string]$Text,[int]$ExitCode=0) {
    try {
        $parsed=Convert-SummaryMap $Text; $m=$parsed.Map; $valid=!$parsed.Duplicate; $consistent=$true
        $requiredStrings=@('PEER_COMPLETE','PEER_ARMED','ADMISSION_SEQUENCE_ZERO_OK','BLOCKED_ADMISSION_SEQUENCE_MISS','FIRST_SEQUENCE','LAST_SEQUENCE','INGRESS_FIRST_SEQUENCE','INGRESS_LAST_SEQUENCE','PEER_BOUND_IP','PEER_BOUND_PORT','INGRESS_SOURCE_IP','INGRESS_SOURCE_PORT','INGRESS_DEST_IP','INGRESS_DEST_PORT','PEER_SOCKET_ERROR_PHASE','PEER_SOCKET_ERROR_SEQUENCE','PEER_SOCKET_ERROR_ERRNO','PEER_SOCKET_ERROR_WINERROR','PEER_SOCKET_ERROR_MESSAGE','TIMING_EVIDENCE_VALID','INGRESS_RX_TO_SEND_MAX_US','INGRESS_RX_TO_SEND_P99_US','INGRESS_SEND_CALL_MAX_US','PEER_APPLICATION_SUBMISSION_TO_PROVEN_OPEN_PORT','W5500_PACKET_ARRIVAL','W5500_SOCKET_MATCH_ACCEPTANCE','W5500_RX_STORAGE','W5500_RX_BUFFER_SATURATION','W5500_MATCHED_PORT_INTERNAL_SEMANTICS','PEER_FATAL_REASON','PEER_RESULT')
        $numeric=@('VALID_DEVICE_TX_RX_TOTAL','CRC_ERROR','LENGTH_ERROR','FORMAT_ERROR','PAYLOAD_ERROR','FLAGS_ERROR','UNEXPECTED_SOURCE','SOURCE_PORT_ERROR','SEQ_GAP','DUPLICATE','OUT_OF_ORDER','INGRESS_TX_ATTEMPT_TOTAL','INGRESS_TX_SUCCESS_TOTAL','INGRESS_TX_FAIL_TOTAL','PEER_SOCKET_ERROR_TOTAL')
        foreach($key in $requiredStrings){if(!$m.Contains($key)){$valid=$false}}
        $v=[ordered]@{}
        foreach($key in $numeric){$n=Test-Decimal $m $key;if($null -eq $n){$valid=$false}else{$v[$key]=$n}}
        foreach($key in @('PEER_COMPLETE','PEER_ARMED','ADMISSION_SEQUENCE_ZERO_OK','BLOCKED_ADMISSION_SEQUENCE_MISS','TIMING_EVIDENCE_VALID')){if(!$m.Contains($key) -or $m[$key] -notin @('0','1')){$valid=$false}}
        $seq=[ordered]@{}
        foreach($key in @('FIRST_SEQUENCE','LAST_SEQUENCE','INGRESS_FIRST_SEQUENCE','INGRESS_LAST_SEQUENCE')){$item=Test-UInt32OrNone $m $key;if($null-eq $item -or !$item.Valid){$valid=$false}else{$seq[$key]=$item}}
        if($m.Contains('PEER_RESULT') -and $m.PEER_RESULT -notin @('PASS','FAIL','BLOCKED')){$valid=$false}
        if($m.Contains('PEER_APPLICATION_SUBMISSION_TO_PROVEN_OPEN_PORT') -and $m.PEER_APPLICATION_SUBMISSION_TO_PROVEN_OPEN_PORT -notin @('0','1')){$valid=$false}
        foreach($key in @('W5500_PACKET_ARRIVAL','W5500_SOCKET_MATCH_ACCEPTANCE','W5500_RX_STORAGE','W5500_RX_BUFFER_SATURATION','W5500_MATCHED_PORT_INTERNAL_SEMANTICS')){if($m.Contains($key) -and $m[$key] -cne 'UNKNOWN'){$valid=$false}}
        $fatalVocabulary=@('NONE','BLOCKED_DG_C_PEER_UDP_ASYNC_ERROR','BLOCKED_DG_C_ADMISSION_SEQUENCE_MISS','BLOCKED_DG_C_EVIDENCE_CONTRACT_INVALID','DG_C_PEER_INGRESS_SEND_FAIL','BLOCKED_DG_D_PEER_UDP_ASYNC_ERROR','BLOCKED_DG_D_ADMISSION_SEQUENCE_MISS','BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID','DG_D_PEER_INGRESS_SEND_FAIL')
        if($m.Contains('PEER_FATAL_REASON') -and $m.PEER_FATAL_REASON -notin $fatalVocabulary){$valid=$false}
        $phaseVocabulary=@('NONE','BIND','GETSOCKNAME','RECVFROM','SENDTO')
        if($m.Contains('PEER_SOCKET_ERROR_PHASE') -and $m.PEER_SOCKET_ERROR_PHASE -notin $phaseVocabulary){$valid=$false}
        $timing=[ordered]@{}
        foreach($key in @('INGRESS_RX_TO_SEND_MAX_US','INGRESS_RX_TO_SEND_P99_US','INGRESS_SEND_CALL_MAX_US')){$number=Test-FiniteNonnegative $m $key;if($null-eq $number){$valid=$false}else{$timing[$key]=$number}}
        if($valid -and $timing.INGRESS_RX_TO_SEND_MAX_US -lt $timing.INGRESS_RX_TO_SEND_P99_US){$valid=$false}
        try{if($m.Contains('PEER_SOCKET_ERROR_MESSAGE')){$message=$m.PEER_SOCKET_ERROR_MESSAGE|ConvertFrom-Json -ErrorAction Stop;if($message -isnot [string]){$valid=$false}}}catch{$valid=$false}
        if($valid){
            $valid=$m.PEER_BOUND_IP -ceq $peerIp -and $m.PEER_BOUND_PORT -ceq '50001' -and $m.INGRESS_SOURCE_IP -ceq $peerIp -and $m.INGRESS_SOURCE_PORT -ceq '50001' -and $m.INGRESS_DEST_IP -ceq $senderIp -and $m.INGRESS_DEST_PORT -ceq '50001'
            $expectedTreatment=if($v.INGRESS_TX_SUCCESS_TOTAL -gt 0){'1'}else{'0'}
            $valid=$valid -and $m.PEER_APPLICATION_SUBMISSION_TO_PROVEN_OPEN_PORT -ceq $expectedTreatment
        }
        if($valid){
            if($v.PEER_SOCKET_ERROR_TOTAL -eq 0){
                if($m.PEER_SOCKET_ERROR_PHASE -cne 'NONE' -or $m.PEER_SOCKET_ERROR_SEQUENCE -cne 'NA' -or $m.PEER_SOCKET_ERROR_ERRNO -cne 'NA' -or $m.PEER_SOCKET_ERROR_WINERROR -cne 'NA'){$valid=$false}
                if($m.PEER_RESULT -ceq 'PASS' -and $m.PEER_FATAL_REASON -cne 'NONE'){$valid=$false}
            }else{
                if($m.PEER_SOCKET_ERROR_PHASE -ceq 'NONE' -or $m.PEER_FATAL_REASON -cnotin @('BLOCKED_DG_C_PEER_UDP_ASYNC_ERROR','BLOCKED_DG_D_PEER_UDP_ASYNC_ERROR') -or $m.PEER_RESULT -cne 'BLOCKED'){$valid=$false}
                $errorSeq=Test-UInt32OrNone $m 'PEER_SOCKET_ERROR_SEQUENCE' -AllowNa
                if($null-eq $errorSeq -or !$errorSeq.Valid){$valid=$false}
                foreach($key in @('PEER_SOCKET_ERROR_ERRNO','PEER_SOCKET_ERROR_WINERROR')){if($m[$key] -cne 'NA' -and $m[$key] -notmatch '^-?\d+$'){$valid=$false}}
                if($m.PEER_SOCKET_ERROR_PHASE -ceq 'SENDTO' -and (!$errorSeq.IsNumber)){$valid=$false}
            }
            if($m.PEER_FATAL_REASON -cin @('BLOCKED_DG_C_PEER_UDP_ASYNC_ERROR','BLOCKED_DG_D_PEER_UDP_ASYNC_ERROR') -and $v.PEER_SOCKET_ERROR_TOTAL -eq 0){$valid=$false}
            if($m.PEER_FATAL_REASON -cin @('DG_C_PEER_INGRESS_SEND_FAIL','DG_D_PEER_INGRESS_SEND_FAIL') -and ($m.PEER_RESULT -cne 'FAIL' -or $v.INGRESS_TX_FAIL_TOTAL -eq 0)){$valid=$false}
            if($m.PEER_FATAL_REASON -cin @('BLOCKED_DG_C_ADMISSION_SEQUENCE_MISS','BLOCKED_DG_D_ADMISSION_SEQUENCE_MISS') -and ($m.PEER_RESULT -cne 'BLOCKED' -or $m.BLOCKED_ADMISSION_SEQUENCE_MISS -cne '1')){$valid=$false}
            if($m.PEER_FATAL_REASON -cin @('BLOCKED_DG_C_EVIDENCE_CONTRACT_INVALID','BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID') -and $m.PEER_RESULT -cne 'BLOCKED'){$valid=$false}
        }
        $errorsZero=$valid
        foreach($key in @('CRC_ERROR','LENGTH_ERROR','FORMAT_ERROR','PAYLOAD_ERROR','FLAGS_ERROR','UNEXPECTED_SOURCE','SOURCE_PORT_ERROR','SEQ_GAP','DUPLICATE','OUT_OF_ORDER')){if($valid -and $v[$key] -ne 0){$errorsZero=$false}}
        if($valid -and $m.PEER_COMPLETE -ceq '1' -and $m.PEER_RESULT -ceq 'PASS'){
            $count=$v.VALID_DEVICE_TX_RX_TOTAL
            if($count -eq 0 -or $count -gt [uint64]4294967296 -or !$seq.FIRST_SEQUENCE.IsNumber -or !$seq.INGRESS_FIRST_SEQUENCE.IsNumber -or !$seq.LAST_SEQUENCE.IsNumber -or !$seq.INGRESS_LAST_SEQUENCE.IsNumber){$consistent=$false}
            elseif($seq.FIRST_SEQUENCE.Value -ne 0 -or $seq.INGRESS_FIRST_SEQUENCE.Value -ne 0 -or $seq.LAST_SEQUENCE.Value -ne ($count-1) -or $seq.INGRESS_LAST_SEQUENCE.Value -ne ($count-1)){$consistent=$false}
        }
        $logical=$valid -and $consistent -and $ExitCode -eq 0 -and $m.PEER_COMPLETE -ceq '1' -and $m.PEER_ARMED -ceq '1' -and $m.ADMISSION_SEQUENCE_ZERO_OK -ceq '1' -and $m.BLOCKED_ADMISSION_SEQUENCE_MISS -ceq '0' -and $v.VALID_DEVICE_TX_RX_TOTAL -gt 0 -and $errorsZero -and $v.INGRESS_TX_ATTEMPT_TOTAL -gt 0 -and $v.INGRESS_TX_SUCCESS_TOTAL -gt 0 -and $v.INGRESS_TX_ATTEMPT_TOTAL -eq $v.INGRESS_TX_SUCCESS_TOTAL -and $v.INGRESS_TX_FAIL_TOTAL -eq 0 -and $v.PEER_SOCKET_ERROR_TOTAL -eq 0 -and $m.TIMING_EVIDENCE_VALID -ceq '1' -and $m.PEER_FATAL_REASON -ceq 'NONE' -and $m.PEER_RESULT -ceq 'PASS'
        [pscustomobject]@{ EvidenceContractValid=$valid; StreamConsistent=$consistent; LogicalPass=$logical; Fields=$v; Strings=$m; Sequences=$seq; Timing=$timing; AsyncError=($valid -and $v.PEER_SOCKET_ERROR_TOTAL -gt 0); SendFail=($valid -and $v.INGRESS_TX_FAIL_TOTAL -gt 0); AdmissionBlocked=($valid -and $m.BLOCKED_ADMISSION_SEQUENCE_MISS -ceq '1'); SubmissionToOpenPort=if($valid -and $m.PEER_COMPLETE -ceq '1'){$m.PEER_APPLICATION_SUBMISSION_TO_PROVEN_OPEN_PORT}else{'UNKNOWN'} }
    } catch {
        [pscustomobject]@{ EvidenceContractValid=$false; StreamConsistent=$false; LogicalPass=$false; Fields=[ordered]@{}; Strings=[ordered]@{}; Sequences=[ordered]@{}; Timing=[ordered]@{}; AsyncError=$false; SendFail=$false; AdmissionBlocked=$false; SubmissionToOpenPort='UNKNOWN' }
    }
}

function Test-DgDReconciliation([pscustomobject]$Serial,[pscustomobject]$Peer) {
    if(!$Serial.EvidenceContractValid -or !$Peer.EvidenceContractValid -or !$Serial.Fields.Contains('UDP_TX_TOTAL')){return [pscustomobject]@{EvidenceValid=$false;Pass=$false}}
    foreach($key in @('RX_PARSE_POSITIVE_TOTAL','RX_POSITIVE_SIZE_32_TOTAL','RX_NULL_DISCARD_CALL_TOTAL','RX_NULL_DISCARD_RETURN_TOTAL','DRAIN_TARGET_TX_TOTAL')){if(!$Serial.Fields.Contains($key)){return [pscustomobject]@{EvidenceValid=$false;Pass=$false}}}
    $d=[uint64]$Serial.Fields.UDP_TX_TOTAL;$p=[uint64]$Peer.Fields.VALID_DEVICE_TX_RX_TOTAL;$a=[uint64]$Peer.Fields.INGRESS_TX_ATTEMPT_TOTAL;$s=[uint64]$Peer.Fields.INGRESS_TX_SUCCESS_TOTAL
    $rx=[uint64]$Serial.Fields.RX_PARSE_POSITIVE_TOTAL;$size32=[uint64]$Serial.Fields.RX_POSITIVE_SIZE_32_TOTAL;$calls=[uint64]$Serial.Fields.RX_NULL_DISCARD_CALL_TOTAL;$returns=[uint64]$Serial.Fields.RX_NULL_DISCARD_RETURN_TOTAL;$target=[uint64]$Serial.Fields.DRAIN_TARGET_TX_TOTAL
    [pscustomobject]@{EvidenceValid=$true;Pass=($d -eq $p -and $p -eq $a -and $a -eq $s -and $s -eq $rx -and $rx -eq $size32 -and $size32 -eq $calls -and $calls -eq $returns -and $returns -eq $target);Device=$d;Peer=$p;Attempt=$a;Success=$s;Positive=$rx;DiscardReturns=$returns;DrainTarget=$target}
}

function Get-DgDStimulusEstablished([pscustomobject]$Serial,[pscustomobject]$Peer) {
    if($null-eq $Serial -or $null-eq $Peer -or !$Serial.EvidenceContractValid -or !$Peer.EvidenceContractValid -or !$Peer.Fields.Contains('INGRESS_TX_SUCCESS_TOTAL')){return 'UNKNOWN'}
    $f=$Serial.Fields
    foreach($key in @('RX_PARSE_CALL_STARTED_TOTAL','RX_PARSE_CALL_COMPLETED_TOTAL','RX_PARSE_POSITIVE_TOTAL','RX_PARSE_NEGATIVE_TOTAL','RX_POSITIVE_SIZE_32_TOTAL','RX_POSITIVE_OTHER_SIZE_TOTAL','RX_PRE_PARSE_REMAINING_NONZERO','RX_NULL_DISCARD_CALL_TOTAL','RX_NULL_DISCARD_RETURN_TOTAL','RX_NULL_DISCARD_REQUEST_BYTES_TOTAL','RX_NULL_DISCARD_BYTES_TOTAL','RX_NULL_DISCARD_FAIL_TOTAL','RX_POST_DISCARD_REMAINING_NONZERO')){if(!$f.Contains($key)){return 'UNKNOWN'}}
    $positive=[uint64]$f.RX_PARSE_POSITIVE_TOTAL
    if([uint64]$Peer.Fields.INGRESS_TX_SUCCESS_TOTAL -gt 0 -and $positive -gt 0 -and
       [uint64]$f.RX_POSITIVE_SIZE_32_TOTAL -eq $positive -and [uint64]$f.RX_POSITIVE_OTHER_SIZE_TOTAL -eq 0 -and
       [uint64]$f.RX_NULL_DISCARD_CALL_TOTAL -eq $positive -and [uint64]$f.RX_NULL_DISCARD_RETURN_TOTAL -eq $positive -and
       [uint64]$f.RX_NULL_DISCARD_REQUEST_BYTES_TOTAL -eq (32*$positive) -and [uint64]$f.RX_NULL_DISCARD_BYTES_TOTAL -eq (32*$positive) -and
       [uint64]$f.RX_NULL_DISCARD_FAIL_TOTAL -eq 0 -and [uint64]$f.RX_PRE_PARSE_REMAINING_NONZERO -eq 0 -and
       [uint64]$f.RX_POST_DISCARD_REMAINING_NONZERO -eq 0 -and [uint64]$f.RX_PARSE_CALL_STARTED_TOTAL -eq [uint64]$f.RX_PARSE_CALL_COMPLETED_TOTAL -and
       [uint64]$f.RX_PARSE_NEGATIVE_TOTAL -eq 0){return '1'}
    '0'
}

function Get-DgDDeviceBlockedToken([pscustomobject]$Serial,[pscustomobject]$Reconciliation) {
    if($null-eq $Serial -or !$Serial.EvidenceContractValid){return ''}
    if($Serial.ProvisionalPrimary -ceq 'DG_D_USB_HID_FAIL'){return ''}
    if($Serial.Schema -ceq 'SETUP_FAILURE'){
        if($Serial.Reason -match '^(?:W5100_INIT|CHIP_ID|VERSIONR|BUFFER_MAP|PHY_|NETWORK_CONFIG|LINK_)'){return 'BLOCKED_DG_D_PHY_HEALTH_FAIL'}
        if($Serial.Reason -match '^(?:USB_INIT|HORI_READY)$'){return 'DG_D_DEVICE_LOGICAL_FAIL'}
        return 'DG_D_DEVICE_LOGICAL_FAIL'
    }
    if($Serial.Schema -cne 'RUNTIME'){return ''}
    $f=$Serial.Fields
    if([uint64]$f.RX_PRE_PARSE_REMAINING_NONZERO -gt 0){return 'BLOCKED_DG_D_PRE_PARSE_REMAINING_NONZERO'}
    if([uint64]$f.RX_PARSE_NEGATIVE_TOTAL -gt 0){return 'BLOCKED_DG_D_PARSE_API_NEGATIVE'}
    if([uint64]$f.RX_PARSE_CALL_STARTED_TOTAL -ne [uint64]$f.RX_PARSE_CALL_COMPLETED_TOTAL){return 'BLOCKED_DG_D_PARSE_CALL_INCOMPLETE'}
    if([uint64]$f.RX_POSITIVE_OTHER_SIZE_TOTAL -gt 0 -or [uint64]$f.RX_POSITIVE_SIZE_32_TOTAL -ne [uint64]$f.RX_PARSE_POSITIVE_TOTAL){return 'BLOCKED_DG_D_POSITIVE_SIZE_NOT_32'}
    $positive=[uint64]$f.RX_PARSE_POSITIVE_TOTAL
    if([uint64]$f.RX_NULL_DISCARD_CALL_TOTAL -ne $positive -or
       [uint64]$f.RX_NULL_DISCARD_RETURN_TOTAL -ne $positive -or
       [uint64]$f.RX_NULL_DISCARD_REQUEST_BYTES_TOTAL -ne (32*$positive) -or
       [uint64]$f.RX_NULL_DISCARD_BYTES_TOTAL -ne (32*$positive) -or
       [uint64]$f.RX_NULL_DISCARD_FAIL_TOTAL -ne 0 -or
       ($positive -gt 0 -and [int64]$f.RX_NULL_DISCARD_LAST_RETURN -ne 32)){
        return 'BLOCKED_DG_D_NULL_DISCARD_RETURN_MISMATCH'
    }
    if([uint64]$f.RX_POST_DISCARD_REMAINING_NONZERO -gt 0){return 'BLOCKED_DG_D_POST_DISCARD_REMAINING_NONZERO'}
    if([uint64]$f.SCHEDULER_MISSED_DEADLINE -gt 0){return 'BLOCKED_DG_D_TIMING_FAIL'}
    if([uint64]$f.TERMINAL_FINAL_PHY_OK -ne 1 -or [uint64]$f.TERMINAL_FINAL_VERSION_OK -ne 1 -or
       [uint64]$f.TERMINAL_FINAL_BUFFER_MAP_OK -ne 1 -or [uint64]$f.VERSIONR -ne 0x04){return 'BLOCKED_DG_D_PHY_HEALTH_FAIL'}
    if([uint64]$f.TERMINAL_MAX_REGISTER_TRIPLE_READ_MISMATCH -gt 0 -or [uint64]$f.TERMINAL_SPI_CORRUPTION_SUSPECTED -gt 0){return 'BLOCKED_DG_D_MAX_SPI_CANARY_FAIL'}
    if($Serial.Reason -ceq 'BLOCKED_DG_D_DRAIN_TIMEOUT'){return 'BLOCKED_DG_D_DRAIN_TIMEOUT'}
    if($Serial.Reason -cin @('BLOCKED_DG_D_PRE_PARSE_REMAINING_NONZERO','BLOCKED_DG_D_PARSE_API_NEGATIVE','BLOCKED_DG_D_PARSE_CALL_INCOMPLETE','BLOCKED_DG_D_POSITIVE_SIZE_NOT_32','BLOCKED_DG_D_NULL_DISCARD_RETURN_MISMATCH','BLOCKED_DG_D_POST_DISCARD_REMAINING_NONZERO','BLOCKED_DG_D_DRAIN_TIMEOUT','BLOCKED_DG_D_TIMING_FAIL','BLOCKED_DG_D_PHY_HEALTH_FAIL','BLOCKED_DG_D_MAX_SPI_CANARY_FAIL','BLOCKED_DG_D_RECONCILIATION_MISMATCH')){return $Serial.Reason}
    if($null-ne $Reconciliation -and (!$Reconciliation.EvidenceValid -or !$Reconciliation.Pass)){return 'BLOCKED_DG_D_RECONCILIATION_MISMATCH'}
    if(!$Serial.LogicalPass){return 'DG_D_DEVICE_LOGICAL_FAIL'}
    ''
}

function Convert-DgDControlPlaneObservations([string[]]$RawObservations=@()) {
    $raw=[Collections.Generic.List[string]]::new()
    $unexpected=[Collections.Generic.List[string]]::new()
    foreach($item in @($RawObservations)){
        if([string]::IsNullOrWhiteSpace($item)){continue}
        $raw.Add([string]$item)
        if($item -cnotin @('SERIAL_CAPTURE_TIMEOUT','PEER_GRACEFUL_EXIT_TIMEOUT')){$unexpected.Add([string]$item)}
    }
    $canonical=if($unexpected.Count -gt 0){'BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID'}elseif($raw.Count -gt 0){'BLOCKED_DG_D_ORCHESTRATION'}else{'NONE'}
    [pscustomobject]@{Raw=[string[]]$raw.ToArray();Canonical=$canonical;Unexpected=[string[]]$unexpected.ToArray()}
}

function Get-DgDClassification([pscustomobject]$Serial,[pscustomobject]$Peer,[pscustomobject]$Reconciliation,[string[]]$RawControlPlaneObservations=@(),[bool]$TemporalPretrialProven=$false) {
    $stimulus=Get-DgDStimulusEstablished $Serial $Peer
    $submission=if($null-ne $Peer -and $Peer.EvidenceContractValid){$Peer.SubmissionToOpenPort}else{'UNKNOWN'}
    $controlMapping=Convert-DgDControlPlaneObservations $RawControlPlaneObservations
    $controlCondition=if($controlMapping.Canonical -ceq 'NONE'){''}else{$controlMapping.Canonical}
    $usbFailure=$false
    $logicalFailure=$false
    if($null-ne $Serial){
        $usbFailure=$Serial.ProvisionalPrimary -ceq 'DG_D_USB_HID_FAIL'
        if(!$usbFailure -and $Serial.EvidenceContractValid -and $Serial.Schema -ceq 'RUNTIME'){
            $usbFailure=($Serial.Fields.FINAL_USB_STATE -ne 0x90 -or $Serial.Fields.TERMINAL_FINAL_HID_READY -ne 1 -or $Serial.Fields.TERMINAL_HID_READY_DROP -ne 0 -or $Serial.Fields.HID_STALL_COUNT -ne 0)
        }
        $logicalFailure=$Serial.EvidenceContractValid -and !$usbFailure -and !$Serial.LogicalPass
    }

    $peerCondition=''
    if($null-eq $Peer){$peerCondition='BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID'}
    elseif(!$Peer.EvidenceContractValid){$peerCondition='BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID'}
    elseif($Peer.AsyncError){$peerCondition='BLOCKED_DG_D_PEER_UDP_ASYNC_ERROR'}
    elseif($Peer.AdmissionBlocked){$peerCondition='BLOCKED_DG_D_ADMISSION_SEQUENCE_MISS'}
    elseif($Peer.SendFail){$peerCondition='DG_D_PEER_INGRESS_SEND_FAIL'}
    elseif(!$Peer.LogicalPass){$peerCondition='BLOCKED_DG_D_CONTROL_PLANE'}
    $deviceBlockedToken=Get-DgDDeviceBlockedToken $Serial $Reconciliation

    $primary=''
    if($usbFailure){$primary='DG_D_USB_HID_FAIL'}
    elseif($deviceBlockedToken){$primary=$deviceBlockedToken}
    elseif(($null-eq $Serial -or $Serial.NoEvidence) -and $null-eq $Peer){$primary='BLOCKED_DG_D_ORCHESTRATION'}
    elseif($peerCondition){$primary=$peerCondition}
    elseif($controlCondition){$primary=$controlCondition}
    elseif(!$Serial.EvidenceContractValid){$primary='BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID'}
    elseif($null-eq $Reconciliation -or !$Reconciliation.EvidenceValid -or !$Reconciliation.Pass){$primary='BLOCKED_DG_D_RECONCILIATION_MISMATCH'}
    elseif($Serial.LogicalPass -and $Peer.LogicalPass -and $stimulus -ceq '1'){$primary='DG_D_PASS'}
    else{$primary='BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID'}

    $secondaryToken='NONE'
    if($usbFailure -and $controlCondition){$secondaryToken=$controlCondition}
    elseif(($usbFailure -or $logicalFailure -or $deviceBlockedToken) -and $peerCondition){$secondaryToken=$peerCondition}
    elseif(($usbFailure -or $logicalFailure -or $deviceBlockedToken) -and $controlCondition){$secondaryToken=$controlCondition}
    elseif($peerCondition -and $controlCondition -and $peerCondition -cne $controlCondition){$secondaryToken=$controlCondition}

    $trialResult='BLOCKED'
    $blockReason='NONE'
    if($primary -ceq 'DG_D_USB_HID_FAIL'){
        if($TemporalPretrialProven){$blockReason='BLOCKED_DG_D_PROVEN_PRETRIAL_CAUSE'}
        elseif($controlCondition){$blockReason=$controlCondition}
        elseif($stimulus -ceq '1'){$trialResult='FAIL'}
        else{$blockReason='BLOCKED_DG_D_STIMULUS_NOT_ESTABLISHED'}
    }elseif($primary -ceq 'DG_D_PASS'){
        $trialResult='PASS'
    }elseif($deviceBlockedToken){
        $blockReason=$primary
    }elseif($peerCondition){
        $blockReason=$peerCondition
    }elseif($controlCondition){
        $blockReason=$controlCondition
    }else{
        $blockReason=$primary
    }

    $pretrialProven=$TemporalPretrialProven
    if(!$pretrialProven -and $logicalFailure -and $Serial.Schema -ceq 'SETUP_FAILURE' -and $stimulus -ceq '0'){$pretrialProven=$true}
    $devicePretrialReason=if($pretrialProven -and ($usbFailure -or $logicalFailure)){$Serial.Reason}else{'NONE'}
    $c2Reproduction=if($primary -ceq 'DG_D_USB_HID_FAIL' -and $stimulus -ceq '1' -and $trialResult -ceq 'FAIL'){'ESTABLISHED'}else{'NOT_ESTABLISHED'}

    [pscustomobject]@{
        Primary=$primary
        Secondary=$secondaryToken
        StimulusEstablished=$stimulus
        TrialResult=$trialResult
        TrialBlockReason=$blockReason
        DevicePretrialReason=$devicePretrialReason
        C2TypeUsbHidReproduction=$c2Reproduction
        SubmissionToOpenPort=$submission
        RawControlPlaneObservations=$controlMapping.Raw
    }
}

function Get-DgDFailureToken([string]$Message) {
    $match=[regex]::Match($Message,'(?:BLOCKED_[A-Z0-9_]+|DG_D_[A-Z0-9_]+)')
    if($match.Success){$match.Value}else{'BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID'}
}

function Get-DgDCanonicalPrimaryTokens {
    @(
        'DG_D_PASS','DG_D_USB_HID_FAIL','DG_D_DEVICE_LOGICAL_FAIL','DG_D_PEER_INGRESS_SEND_FAIL',
        'BLOCKED_DG_D_ARTIFACT_IDENTITY','BLOCKED_DG_D_ADMISSION_SEQUENCE_MISS',
        'BLOCKED_DG_D_STIMULUS_NOT_ESTABLISHED','BLOCKED_DG_D_PROVEN_PRETRIAL_CAUSE','BLOCKED_DG_D_PEER_UDP_ASYNC_ERROR',
        'BLOCKED_DG_D_CONTROL_PLANE','BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID','BLOCKED_DG_D_ORCHESTRATION',
        'BLOCKED_DG_D_AUTHORITY_IDENTITY_UNRESOLVED','BLOCKED_DG_D_MODE_IDENTITY_COLLISION',
        'BLOCKED_DG_D_PRE_PARSE_REMAINING_NONZERO','BLOCKED_DG_D_PARSE_API_NEGATIVE',
        'BLOCKED_DG_D_PARSE_CALL_INCOMPLETE','BLOCKED_DG_D_POSITIVE_SIZE_NOT_32',
        'BLOCKED_DG_D_NULL_DISCARD_RETURN_MISMATCH','BLOCKED_DG_D_POST_DISCARD_REMAINING_NONZERO',
        'BLOCKED_DG_D_PEER_FAIL','BLOCKED_DG_D_RECONCILIATION_MISMATCH',
        'BLOCKED_DG_D_DRAIN_TIMEOUT','BLOCKED_DG_D_TIMING_FAIL',
        'BLOCKED_DG_D_PHY_HEALTH_FAIL','BLOCKED_DG_D_MAX_SPI_CANARY_FAIL',
        'BLOCKED_DG_D_C1_ARTIFACT_IDENTITY_MISMATCH','BLOCKED_DG_D_COM4_PNP_IDENTITY',
        'BLOCKED_DG_D_COM4_REENUMERATION','BLOCKED_DG_D_DONOR_AUTHORITY_IDENTITY_UNRESOLVED',
        'BLOCKED_DG_D_EXACT_C1_ARTIFACT_UPLOAD_PATH_UNRESOLVED',
        'BLOCKED_DG_D_IMPLEMENTATION_AUTHORITY_IDENTITY_MISMATCH',
        'BLOCKED_DG_D_IMPLEMENTATION_AUTHORITY_REQUIRED','BLOCKED_DG_D_PEER_TOPOLOGY',
        'BLOCKED_DG_D_UNEXPECTED_PEER_CHANGE_REQUIRED','BLOCKED_DG_D_UPLOAD_ARTIFACT_IDENTITY_DRIFT',
        'BLOCKED_DG_D_UPLOAD_TOOLCHAIN_IDENTITY_MISMATCH'
    )
}

function Get-DgDPropertyString([pscustomobject]$Object,[string]$Name,[string]$Default='') {
    $property=$Object.PSObject.Properties[$Name]
    if($null-eq $property){return $Default}
    [string]$property.Value
}

function Convert-DgDClosedWorldAdjudication([pscustomobject]$Adjudication) {
    $primary=Get-DgDPropertyString $Adjudication 'Primary'
    $secondary=Get-DgDPropertyString $Adjudication 'Secondary' 'NONE'
    $stimulus=Get-DgDPropertyString $Adjudication 'StimulusEstablished' 'UNKNOWN'
    $trialResult=Get-DgDPropertyString $Adjudication 'TrialResult' 'BLOCKED'
    $blockReason=Get-DgDPropertyString $Adjudication 'TrialBlockReason' 'NONE'
    $pretrial=Get-DgDPropertyString $Adjudication 'DevicePretrialReason' 'NONE'
    $c2=Get-DgDPropertyString $Adjudication 'C2TypeUsbHidReproduction' 'NOT_ESTABLISHED'
    $submission=Get-DgDPropertyString $Adjudication 'SubmissionToOpenPort' 'UNKNOWN'
    $primaryTokens=@(Get-DgDCanonicalPrimaryTokens)
    $secondaryTokens=@('NONE')+@($primaryTokens|Where-Object{$_ -cne 'DG_D_PASS'})
    $blockTokens=@('NONE')+@($primaryTokens|Where-Object{$_ -cne 'DG_D_PASS'})
    $violations=[Collections.Generic.List[string]]::new()
    if($primary -cnotin $primaryTokens){$violations.Add("Primary=$primary")}
    if($secondary -cnotin $secondaryTokens){$violations.Add("Secondary=$secondary")}
    if($blockReason -cnotin $blockTokens){$violations.Add("TrialBlockReason=$blockReason")}
    if($stimulus -cnotin @('1','0','UNKNOWN')){$violations.Add("StimulusEstablished=$stimulus")}
    if($trialResult -cnotin @('PASS','FAIL','BLOCKED')){$violations.Add("TrialResult=$trialResult")}
    if($c2 -cnotin @('ESTABLISHED','NOT_ESTABLISHED')){$violations.Add("C2TypeUsbHidReproduction=$c2")}
    if($submission -cnotin @('1','0','UNKNOWN')){$violations.Add("SubmissionToOpenPort=$submission")}
    if($trialResult -ceq 'FAIL' -and ($primary -cne 'DG_D_USB_HID_FAIL' -or $stimulus -cne '1' -or $c2 -cne 'ESTABLISHED')){$violations.Add('Only established-stimulus DG_D_USB_HID_FAIL may be FAIL')}
    if($c2 -ceq 'ESTABLISHED' -and ($primary -cne 'DG_D_USB_HID_FAIL' -or $stimulus -cne '1' -or $trialResult -cne 'FAIL')){$violations.Add('C2 reproduction requires DG_D_USB_HID_FAIL/1/FAIL')}
    if($primary -ceq 'DG_D_DEVICE_LOGICAL_FAIL' -and $trialResult -cne 'BLOCKED'){$violations.Add('DG_D_DEVICE_LOGICAL_FAIL must remain BLOCKED')}
    $rawProperty=$Adjudication.PSObject.Properties['RawControlPlaneObservations']
    $raw=if($null-ne $rawProperty){@($rawProperty.Value|Where-Object{![string]::IsNullOrWhiteSpace($_)}|ForEach-Object{[string]$_})}else{@()}
    if($violations.Count -gt 0){
        return [pscustomobject]@{
            Adjudication=[pscustomobject]@{Primary='BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID';Secondary='NONE';StimulusEstablished='UNKNOWN';TrialResult='BLOCKED';TrialBlockReason='BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID';DevicePretrialReason='NONE';C2TypeUsbHidReproduction='NOT_ESTABLISHED';SubmissionToOpenPort='UNKNOWN'}
            RawControlPlaneObservations=$raw
            ValidationViolation=($violations -join ';')
        }
    }
    [pscustomobject]@{
        Adjudication=[pscustomobject]@{Primary=$primary;Secondary=$secondary;StimulusEstablished=$stimulus;TrialResult=$trialResult;TrialBlockReason=$blockReason;DevicePretrialReason=$pretrial;C2TypeUsbHidReproduction=$c2;SubmissionToOpenPort=$submission}
        RawControlPlaneObservations=$raw
        ValidationViolation='NONE'
    }
}

function Get-DgDCanonicalAdjudicationLines([pscustomobject]$Adjudication) {
    @(
        "DG_D_CLASSIFICATION_PRIMARY=$($Adjudication.Primary)"
        "DG_D_CLASSIFICATION_SECONDARY=$($Adjudication.Secondary)"
        "DG_D_STIMULUS_ESTABLISHED=$($Adjudication.StimulusEstablished)"
        "DG_D_TRIAL_RESULT=$($Adjudication.TrialResult)"
        "DG_D_TRIAL_BLOCK_REASON=$($Adjudication.TrialBlockReason)"
        "DG_D_DEVICE_PRETRIAL_REASON=$($Adjudication.DevicePretrialReason)"
        "C2_TYPE_USB_HID_REPRODUCTION=$($Adjudication.C2TypeUsbHidReproduction)"
        "PEER_APPLICATION_SUBMISSION_TO_PROVEN_OPEN_PORT=$($Adjudication.SubmissionToOpenPort)"
    )
}

function Get-DgDAdjudicationLines([pscustomobject]$Adjudication) {
    $closed=Convert-DgDClosedWorldAdjudication $Adjudication
    @(Get-DgDCanonicalAdjudicationLines $closed.Adjudication)
}

function Write-DgDAdjudicationFile([string]$TrialRoot,[string[]]$Lines) {
    if(!(Test-Path -LiteralPath $TrialRoot -PathType Container)){throw 'BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID trial_root_missing_for_adjudication'}
    $path=Join-Path $TrialRoot 'runner-adjudication.txt'
    $text=if($Lines.Count){($Lines -join "`n")+"`n"}else{''}
    [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false))
    $path
}

function Write-DgDControlPlaneObservationFile([string]$TrialRoot,[string[]]$Observations,[string]$ValidationViolation='NONE') {
    if(!(Test-Path -LiteralPath $TrialRoot -PathType Container)){throw 'BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID trial_root_missing_for_control_observation'}
    $lines=[Collections.Generic.List[string]]::new()
    foreach($item in @($Observations)){
        if([string]::IsNullOrWhiteSpace($item)){continue}
        if($item -cin @('SERIAL_CAPTURE_TIMEOUT','PEER_GRACEFUL_EXIT_TIMEOUT')){$lines.Add("CONTROL_PLANE_OBSERVATION=$item")}
        else{$lines.Add("CONTROL_PLANE_OBSERVATION_JSON=$($item|ConvertTo-Json -Compress)")}
    }
    if($ValidationViolation -cne 'NONE'){$lines.Add("CANONICAL_VALIDATION_REJECTED_JSON=$($ValidationViolation|ConvertTo-Json -Compress)")}
    if($lines.Count -eq 0){return $null}
    $path=Join-Path $TrialRoot 'runner-control-plane-observation.txt'
    $lf=[string][char]10
    [IO.File]::WriteAllText($path,(($lines.ToArray() -join $lf)+$lf),[Text.UTF8Encoding]::new($false))
    $path
}

function Write-DgDAdjudicationOutput([pscustomobject]$Adjudication,[string]$TrialRoot='') {
    $closed=Convert-DgDClosedWorldAdjudication $Adjudication
    $lines=@(Get-DgDCanonicalAdjudicationLines $closed.Adjudication)
    if(![string]::IsNullOrWhiteSpace($TrialRoot)){
        [void](Write-DgDControlPlaneObservationFile $TrialRoot $closed.RawControlPlaneObservations $closed.ValidationViolation)
        [void](Write-DgDAdjudicationFile $TrialRoot $lines)
    }
    $lines|Write-Output
}

function New-PeerFixture([uint64]$Count=499,[string]$Result='PASS',[uint64]$SocketErrors=0,[uint64]$SendFail=0,[uint64]$AdmissionBlocked=0,[object]$SuccessOverride=$null) {
    $success=if($null-ne $SuccessOverride){[uint64]$SuccessOverride}elseif($SendFail -gt 0){$Count-1}else{$Count}
    $fatal=if($SocketErrors -gt 0){'BLOCKED_DG_D_PEER_UDP_ASYNC_ERROR'}elseif($AdmissionBlocked -gt 0){'BLOCKED_DG_D_ADMISSION_SEQUENCE_MISS'}elseif($SendFail -gt 0){'DG_D_PEER_INGRESS_SEND_FAIL'}else{'NONE'}
    @"
PEER_COMPLETE=1
PEER_ARMED=1
ADMISSION_SEQUENCE_ZERO_OK=1
BLOCKED_ADMISSION_SEQUENCE_MISS=$AdmissionBlocked
VALID_DEVICE_TX_RX_TOTAL=$Count
FIRST_SEQUENCE=0
LAST_SEQUENCE=$($Count-1)
CRC_ERROR=0
LENGTH_ERROR=0
FORMAT_ERROR=0
PAYLOAD_ERROR=0
FLAGS_ERROR=0
UNEXPECTED_SOURCE=0
SOURCE_PORT_ERROR=0
SEQ_GAP=0
DUPLICATE=0
OUT_OF_ORDER=0
INGRESS_TX_ATTEMPT_TOTAL=$Count
INGRESS_TX_SUCCESS_TOTAL=$success
INGRESS_TX_FAIL_TOTAL=$SendFail
INGRESS_FIRST_SEQUENCE=0
INGRESS_LAST_SEQUENCE=$($Count-1)
PEER_BOUND_IP=192.168.50.30
PEER_BOUND_PORT=50001
INGRESS_SOURCE_IP=192.168.50.30
INGRESS_SOURCE_PORT=50001
INGRESS_DEST_IP=192.168.50.10
INGRESS_DEST_PORT=50001
PEER_SOCKET_ERROR_TOTAL=$SocketErrors
PEER_SOCKET_ERROR_PHASE=$(if($SocketErrors){'RECVFROM'}else{'NONE'})
PEER_SOCKET_ERROR_SEQUENCE=NA
PEER_SOCKET_ERROR_ERRNO=$(if($SocketErrors){'10054'}else{'NA'})
PEER_SOCKET_ERROR_WINERROR=$(if($SocketErrors){'10054'}else{'NA'})
PEER_SOCKET_ERROR_MESSAGE=$(if($SocketErrors){'"fixture"'}else{'""'})
TIMING_EVIDENCE_VALID=1
INGRESS_RX_TO_SEND_MAX_US=10.000
INGRESS_RX_TO_SEND_P99_US=9.000
INGRESS_SEND_CALL_MAX_US=5.000
PEER_APPLICATION_SUBMISSION_TO_PROVEN_OPEN_PORT=$(if($success -gt 0){'1'}else{'0'})
W5500_PACKET_ARRIVAL=UNKNOWN
W5500_SOCKET_MATCH_ACCEPTANCE=UNKNOWN
W5500_RX_STORAGE=UNKNOWN
W5500_RX_BUFFER_SATURATION=UNKNOWN
W5500_MATCHED_PORT_INTERNAL_SEMANTICS=UNKNOWN
PEER_FATAL_REASON=$fatal
PEER_RESULT=$Result
"@
}

function New-SetupFailureFixture([string]$Reason) {
@"
C1_SETUP_FAIL=1 REASON=$Reason
TEST_COMPLETE=FAIL TEST_MODE=18 TEST_MODE_NAME=USB_FIXED10_UDP_POSITIVE_PARSE_IMMEDIATE_NULL_DISCARD REASON=$Reason
SCOPE_MARKER trial=DG-D event=TRIAL_COMPLETE result=FAIL
"@
}

function Set-FirstByte([string]$Path) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{$value=$stream.ReadByte();[void]$stream.Seek(0,[IO.SeekOrigin]::Begin);$stream.WriteByte(($value -bxor 1))}finally{$stream.Dispose()}
}

function New-DgDSerialFixture([uint64]$Count=499,[string]$Completion='PASS',[string]$Reason='DRAIN_COMPLETE') {
    $phase=if($Completion -ceq 'PASS'){'COMPLETE'}else{'BLOCKED'}
    $drainResult=if($Completion -ceq 'PASS'){'PASS'}else{'BLOCKED'}
    $blockReason=if($Completion -ceq 'PASS'){'NONE'}else{$Reason}
    $identity='FINAL_USB_STATE=90 FINAL_HID_READY=1 HID_READY_DROP=0'
    $ids='VID=0F0D PID=0202'
    if($Completion -ceq 'FAIL' -and $Reason -ceq 'USB_DETACH_OR_UNSUPPORTED') {
        $identity='FINAL_USB_STATE=12 FINAL_HID_READY=0 HID_READY_DROP=1'
        $ids='VID=0000 PID=0000'
    }
@"
C1_READY=1 USB_STATE=90 HID_READY=1 VID=0F0D PID=0202 USB_STABLE_MS=1000 LINK_STABLE_MS=500
DIAGNOSTIC_START
C1_FINAL UDP_TX_TOTAL=$Count UDP_TX_FAIL=0 UDP_BEGIN_COUNT=1 UDP_BEGIN_FAIL=0 UDP_BEGIN_MAX_US=1 UDP_BEGIN_PACKET_MAX_US=1 UDP_WRITE_MAX_US=1 UDP_END_PACKET_MAX_US=1 UDP_MAX_GAP_US=20000 SCHEDULER_MISSED_DEADLINE=0 SCHEDULER_MAX_LATENESS_US=1 LOOP_MAX_US=10 HID_STALL_COUNT=0 HID_MAX_NO_REPORT_MS=10
DG_D_FINAL RX_PARSE_CALL_STARTED_TOTAL=$($Count+100) RX_PARSE_CALL_COMPLETED_TOTAL=$($Count+100) RX_PARSE_ZERO_TOTAL=100 RX_PARSE_POSITIVE_TOTAL=$Count RX_PARSE_NEGATIVE_TOTAL=0 RX_POSITIVE_SIZE_32_TOTAL=$Count RX_POSITIVE_OTHER_SIZE_TOTAL=0 RX_POSITIVE_OTHER_SIZE_FIRST=0 RX_POSITIVE_OTHER_SIZE_LAST=0 RX_PRE_PARSE_REMAINING_NONZERO=0 RX_NULL_DISCARD_CALL_TOTAL=$Count RX_NULL_DISCARD_RETURN_TOTAL=$Count RX_NULL_DISCARD_REQUEST_BYTES_TOTAL=$(32*$Count) RX_NULL_DISCARD_BYTES_TOTAL=$(32*$Count) RX_NULL_DISCARD_FAIL_TOTAL=0 RX_NULL_DISCARD_LAST_RETURN=32 RX_POST_DISCARD_REMAINING_NONZERO=0 RX_PARSE_MAX_US=10 RX_NULL_DISCARD_MAX_US=10 RX_TREATMENT_MAX_US=30 DG_D_PHASE=$phase
DG_D_FINAL DRAIN_TARGET_TX_TOTAL=$Count DRAIN_ENTER_MS=10000 DRAIN_COMPLETE_MS=10100 DRAIN_TIMEOUT_MS=1000 DRAIN_QUIET_REQUIRED_MS=100 DRAIN_QUIET_OBSERVED_MS=100 DRAIN_PARSE_POSITIVE_START_TOTAL=$Count DRAIN_PARSE_POSITIVE_END_TOTAL=$Count DRAIN_ZERO_CONFIRMATION_TOTAL=10 DRAIN_RESULT=$drainResult DRAIN_BLOCK_REASON=$blockReason
TEST_COMPLETE=$Completion TEST_MODE=18 TEST_MODE_NAME=USB_FIXED10_UDP_POSITIVE_PARSE_IMMEDIATE_NULL_DISCARD DURATION_MS=10100 TRIAL_RUNTIME_MS=10100 REASON=$Reason $identity HID_STALL_COUNT=0 HID_MAX_NO_REPORT_MS=10 $ids HID_REPORT_TOTAL=1000 FINAL_PHY_OK=1 FINAL_VERSION_OK=1 FINAL_BUFFER_MAP_OK=1 VERSIONR=04 MAX_REGISTER_TRIPLE_READ_MISMATCH=0 SPI_CORRUPTION_SUSPECTED=0 SCOPE_RESULT=NOT_CAPTURED
SCOPE_MARKER trial=DG-D event=TRIAL_COMPLETE result=$Completion
"@
}

function New-DgDActiveUsbFailureFixture([uint64]$PositiveCount=7) {
    $parseStarted=$PositiveCount+20
    $discardBytes=32*$PositiveCount
@"
C1_READY=1 USB_STATE=90 HID_READY=1 VID=0F0D PID=0202 USB_STABLE_MS=1000 LINK_STABLE_MS=500
DIAGNOSTIC_START
C1_FINAL UDP_TX_TOTAL=12 UDP_TX_FAIL=0 UDP_BEGIN_COUNT=1 UDP_BEGIN_FAIL=0 UDP_BEGIN_MAX_US=1 UDP_BEGIN_PACKET_MAX_US=1 UDP_WRITE_MAX_US=1 UDP_END_PACKET_MAX_US=1 UDP_MAX_GAP_US=20000 SCHEDULER_MISSED_DEADLINE=0 SCHEDULER_MAX_LATENESS_US=1 LOOP_MAX_US=10 HID_STALL_COUNT=0 HID_MAX_NO_REPORT_MS=10
DG_D_FINAL RX_PARSE_CALL_STARTED_TOTAL=$parseStarted RX_PARSE_CALL_COMPLETED_TOTAL=$parseStarted RX_PARSE_ZERO_TOTAL=20 RX_PARSE_POSITIVE_TOTAL=$PositiveCount RX_PARSE_NEGATIVE_TOTAL=0 RX_POSITIVE_SIZE_32_TOTAL=$PositiveCount RX_POSITIVE_OTHER_SIZE_TOTAL=0 RX_POSITIVE_OTHER_SIZE_FIRST=0 RX_POSITIVE_OTHER_SIZE_LAST=0 RX_PRE_PARSE_REMAINING_NONZERO=0 RX_NULL_DISCARD_CALL_TOTAL=$PositiveCount RX_NULL_DISCARD_RETURN_TOTAL=$PositiveCount RX_NULL_DISCARD_REQUEST_BYTES_TOTAL=$discardBytes RX_NULL_DISCARD_BYTES_TOTAL=$discardBytes RX_NULL_DISCARD_FAIL_TOTAL=0 RX_NULL_DISCARD_LAST_RETURN=32 RX_POST_DISCARD_REMAINING_NONZERO=0 RX_PARSE_MAX_US=10 RX_NULL_DISCARD_MAX_US=10 RX_TREATMENT_MAX_US=30 DG_D_PHASE=BLOCKED
DG_D_FINAL DRAIN_TARGET_TX_TOTAL=0 DRAIN_ENTER_MS=0 DRAIN_COMPLETE_MS=0 DRAIN_TIMEOUT_MS=1000 DRAIN_QUIET_REQUIRED_MS=100 DRAIN_QUIET_OBSERVED_MS=0 DRAIN_PARSE_POSITIVE_START_TOTAL=0 DRAIN_PARSE_POSITIVE_END_TOTAL=0 DRAIN_ZERO_CONFIRMATION_TOTAL=0 DRAIN_RESULT=BLOCKED DRAIN_BLOCK_REASON=USB_DETACH_OR_UNSUPPORTED
TEST_COMPLETE=FAIL TEST_MODE=18 TEST_MODE_NAME=USB_FIXED10_UDP_POSITIVE_PARSE_IMMEDIATE_NULL_DISCARD DURATION_MS=10000 TRIAL_RUNTIME_MS=4321 REASON=USB_DETACH_OR_UNSUPPORTED FINAL_USB_STATE=12 FINAL_HID_READY=0 HID_READY_DROP=1 HID_STALL_COUNT=0 HID_MAX_NO_REPORT_MS=10 VID=0000 PID=0000 HID_REPORT_TOTAL=321 FINAL_PHY_OK=1 FINAL_VERSION_OK=1 FINAL_BUFFER_MAP_OK=1 VERSIONR=04 MAX_REGISTER_TRIPLE_READ_MISMATCH=0 SPI_CORRUPTION_SUSPECTED=0 SCOPE_RESULT=NOT_CAPTURED
SCOPE_MARKER trial=DG-D event=TRIAL_COMPLETE result=FAIL
"@
}

function Remove-DgDOfflineTempDirectory([string]$Path) {
    $resolved=(Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $tempParent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    $parent=[IO.Path]::GetDirectoryName($resolved).TrimEnd('\','/')
    $leaf=[IO.Path]::GetFileName($resolved)
    if (!$parent.Equals($tempParent,[StringComparison]::OrdinalIgnoreCase) -or
        $leaf -notmatch '^dg-d-(?:b37|serializer)-[0-9a-f]{32}$' -or
        ((Get-Item -LiteralPath $resolved).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Unsafe offline temporary directory cleanup target'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Invoke-DgDOfflineSelfTests {
    $results=[Collections.Generic.List[object]]::new()
    $b37Evidence=[Collections.Generic.List[string]]::new()
    function Record([string]$Name,[bool]$Pass){$results.Add([pscustomobject]@{Name=$Name;Pass=$Pass})}
    Record 'authority_donors_match' ((@(Assert-DonorAuthority)).Count -eq 4)
    $peerIdentity=Assert-DgDPeerUnchanged
    Record 'exact_dg_c_peer_reused' ([bool]($peerIdentity.Sha256 -ceq '0D770B8C02ECCBC382A3F5A484F401A3DF9EF9318701ED0C3A2395EEB66E830A'))
    $base=New-DgDSerialFixture 497;$serial=Test-DgDSerialLog $base;$peer=Test-DgDPeerSummary (New-PeerFixture 497) 0
    Record 'one_correct_32_byte_treatment' ($serial.EvidenceContractValid -and $serial.LogicalPass)
    Record 'valid_one_for_one_peer' ($peer.EvidenceContractValid -and $peer.LogicalPass)
    Record 'actual_count_497_reconciles' ((Test-DgDReconciliation $serial $peer).Pass)
    foreach($count in @(499,2999,3000)){$s=Test-DgDSerialLog (New-DgDSerialFixture $count);$p=Test-DgDPeerSummary (New-PeerFixture $count) 0;Record "actual_count_${count}_reconciles" ((Test-DgDReconciliation $s $p).Pass)}
    $mutations=[ordered]@{
        all_zero_parse=@('RX_PARSE_POSITIVE_TOTAL=497','RX_PARSE_POSITIVE_TOTAL=0');pre_parse_remaining_nonzero=@('RX_PRE_PARSE_REMAINING_NONZERO=0','RX_PRE_PARSE_REMAINING_NONZERO=1');negative_parse=@('RX_PARSE_NEGATIVE_TOTAL=0','RX_PARSE_NEGATIVE_TOTAL=1');parse_started_not_completed=@('RX_PARSE_CALL_COMPLETED_TOTAL=597','RX_PARSE_CALL_COMPLETED_TOTAL=596');positive_size_31=@('RX_POSITIVE_OTHER_SIZE_TOTAL=0','RX_POSITIVE_OTHER_SIZE_TOTAL=1');positive_size_33=@('RX_POSITIVE_OTHER_SIZE_TOTAL=0 RX_POSITIVE_OTHER_SIZE_FIRST=0 RX_POSITIVE_OTHER_SIZE_LAST=0','RX_POSITIVE_OTHER_SIZE_TOTAL=1 RX_POSITIVE_OTHER_SIZE_FIRST=33 RX_POSITIVE_OTHER_SIZE_LAST=33');null_discard_negative=@('RX_NULL_DISCARD_LAST_RETURN=32','RX_NULL_DISCARD_LAST_RETURN=-1');partial_null_discard=@('RX_NULL_DISCARD_BYTES_TOTAL=15904','RX_NULL_DISCARD_BYTES_TOTAL=15873');post_discard_nonzero=@('RX_POST_DISCARD_REMAINING_NONZERO=0','RX_POST_DISCARD_REMAINING_NONZERO=1');counter_arithmetic_mismatch=@('RX_PARSE_ZERO_TOTAL=100','RX_PARSE_ZERO_TOTAL=99')
    }
    foreach($name in $mutations.Keys){$pair=$mutations[$name];$bad=Test-DgDSerialLog ($base.Replace($pair[0],$pair[1]));Record $name (!$bad.LogicalPass)}
    $drainMutations=[ordered]@{drain_count_exceeds=@('DRAIN_TARGET_TX_TOTAL=497','DRAIN_TARGET_TX_TOTAL=496');drain_target_never_reached=@('DRAIN_PARSE_POSITIVE_END_TOTAL=497','DRAIN_PARSE_POSITIVE_END_TOTAL=496');drain_quiet_short=@('DRAIN_QUIET_OBSERVED_MS=100','DRAIN_QUIET_OBSERVED_MS=99');drain_timeout=@('DRAIN_RESULT=PASS DRAIN_BLOCK_REASON=NONE','DRAIN_RESULT=BLOCKED DRAIN_BLOCK_REASON=BLOCKED_DG_D_DRAIN_TIMEOUT')}
    foreach($name in $drainMutations.Keys){$pair=$drainMutations[$name];$bad=Test-DgDSerialLog ($base.Replace($pair[0],$pair[1]));Record $name (!$bad.LogicalPass)}
    $sendFail=Test-DgDPeerSummary (New-PeerFixture 497 'FAIL' 0 1) 1;Record 'peer_send_failure' ([bool]$sendFail.SendFail)
    foreach($field in @('SEQ_GAP','DUPLICATE','OUT_OF_ORDER')){$bad=Test-DgDPeerSummary ((New-PeerFixture 497).Replace("$field=0","$field=1")) 0;Record "peer_$($field.ToLower())" (!$bad.LogicalPass)}
    Record 'peer_summary_missing' (!(Test-DgDPeerSummary '' 1).EvidenceContractValid)
    Record 'peer_summary_duplicate' (!(Test-DgDPeerSummary ((New-PeerFixture 497)+"`nPEER_RESULT=PASS") 0).EvidenceContractValid)
    Record 'peer_summary_malformed' (!(Test-DgDPeerSummary 'malformed' 1).EvidenceContractValid)
    $recon=Test-DgDReconciliation $serial $peer;$classification=Get-DgDClassification $serial $peer $recon
    Record 'healthy_complete_pass' ($classification.Primary -ceq 'DG_D_PASS' -and $classification.TrialResult -ceq 'PASS')
    $usb=Test-DgDSerialLog (New-DgDSerialFixture 497 'FAIL' 'USB_DETACH_OR_UNSUPPORTED');$usbEstablished=Get-DgDClassification $usb $peer (Test-DgDReconciliation $usb $peer)
    Record 'usb_fail_stimulus_1' ($usbEstablished.Primary -ceq 'DG_D_USB_HID_FAIL' -and $usbEstablished.TrialResult -ceq 'FAIL')
    $usbUnknown=Get-DgDClassification $usb $null $null;Record 'usb_fail_stimulus_unknown_raw_primary' ($usbUnknown.Primary -ceq 'DG_D_USB_HID_FAIL' -and $usbUnknown.TrialResult -ceq 'BLOCKED')
    $activeUsb=Test-DgDSerialLog (New-DgDActiveUsbFailureFixture 7)
    $activePeer=Test-DgDPeerSummary (New-PeerFixture 7) 0
    $activeText=New-DgDActiveUsbFailureFixture 7
    $readyLine='C1_READY=1 USB_STATE=90 HID_READY=1 VID=0F0D PID=0202 USB_STABLE_MS=1000 LINK_STABLE_MS=500'
    $identityMutations=[ordered]@{
        missing_ready=$activeText.Replace($readyLine,'')
        wrong_ready=$activeText.Replace('VID=0F0D PID=0202','VID=054C PID=0CE6')
        duplicate_ready=($readyLine+"`n"+$activeText)
        late_ready=($activeText.Replace($readyLine,'')+"`n"+$readyLine)
        duplicate_ready_field=$activeText.Replace('C1_READY=1 USB_STATE=90','C1_READY=1 C1_READY=1 USB_STATE=90')
        unstable_ready=$activeText.Replace('USB_STABLE_MS=1000','USB_STABLE_MS=999')
        unstable_link=$activeText.Replace('LINK_STABLE_MS=500','LINK_STABLE_MS=499')
        missing_start=$activeText.Replace('DIAGNOSTIC_START','')
        zero_without_drop=$activeText.Replace('HID_READY_DROP=1','HID_READY_DROP=0')
        zero_without_reports=$activeText.Replace('HID_REPORT_TOTAL=321','HID_REPORT_TOTAL=0')
        zero_still_ready=$activeText.Replace('FINAL_HID_READY=0','FINAL_HID_READY=1')
        mixed_identity=$activeText.Replace('VID=0000 PID=0000','VID=0F0D PID=0000')
        unsupported_terminal=$activeText.Replace('VID=0000 PID=0000','VID=054C PID=0CE6')
        zero_other_reason=$activeText.Replace('USB_DETACH_OR_UNSUPPORTED','HID_REPORT_STALL')
        zero_pass=$base.Replace('VID=0F0D PID=0202','VID=0000 PID=0000')
    }
    foreach($name in $identityMutations.Keys) {
        $bad=Test-DgDSerialLog $identityMutations[$name]
        $badClass=Get-DgDClassification $bad $activePeer (Test-DgDReconciliation $bad $activePeer)
        Record "detach_identity_${name}_blocked" (!$bad.EvidenceContractValid -and $badClass.TrialResult -ceq 'BLOCKED')
    }
    $retained=Test-DgDSerialLog ($activeText.Replace('VID=0000 PID=0000','VID=0F0D PID=0202'))
    Record 'detach_retained_target_identity_compatible' ($retained.EvidenceContractValid -and !$retained.LogicalPass)
    $activeRecon=Test-DgDReconciliation $activeUsb $activePeer
    $activeEstablished=Get-DgDClassification $activeUsb $activePeer $activeRecon
    Record 'active_usb_failure_fixture_contract_valid' ($activeUsb.EvidenceContractValid -and !$activeUsb.LogicalPass -and !$activeRecon.Pass)
    Record 'active_usb_failure_valid_prefix_stimulus_1' ($activeEstablished.Primary -ceq 'DG_D_USB_HID_FAIL' -and $activeEstablished.StimulusEstablished -ceq '1' -and $activeEstablished.TrialResult -ceq 'FAIL' -and $activeEstablished.C2TypeUsbHidReproduction -ceq 'ESTABLISHED')
    Record 'b37_a_usb_stimulus_1_clean_fail_established' ($activeEstablished.Primary -ceq 'DG_D_USB_HID_FAIL' -and $activeEstablished.Secondary -ceq 'NONE' -and $activeEstablished.TrialResult -ceq 'FAIL' -and $activeEstablished.C2TypeUsbHidReproduction -ceq 'ESTABLISHED')
    $b37Evidence.Add("B37_EVIDENCE name=B37-A PRIMARY=$($activeEstablished.Primary) SECONDARY=$($activeEstablished.Secondary) STIMULUS=$($activeEstablished.StimulusEstablished) TRIAL_RESULT=$($activeEstablished.TrialResult) BLOCK_REASON=$($activeEstablished.TrialBlockReason) C2=$($activeEstablished.C2TypeUsbHidReproduction)")
    $b37SerialTimeout=Get-DgDClassification $activeUsb $activePeer $activeRecon @('SERIAL_CAPTURE_TIMEOUT')
    Record 'b37_b_usb_stimulus_1_serial_capture_timeout_blocked' ($b37SerialTimeout.Primary -ceq 'DG_D_USB_HID_FAIL' -and $b37SerialTimeout.Secondary -ceq 'BLOCKED_DG_D_ORCHESTRATION' -and $b37SerialTimeout.StimulusEstablished -ceq '1' -and $b37SerialTimeout.TrialResult -ceq 'BLOCKED' -and $b37SerialTimeout.TrialBlockReason -ceq 'BLOCKED_DG_D_ORCHESTRATION' -and $b37SerialTimeout.C2TypeUsbHidReproduction -ceq 'NOT_ESTABLISHED')
    $b37Evidence.Add("B37_EVIDENCE name=B37-B RAW_CONTROL=SERIAL_CAPTURE_TIMEOUT PRIMARY=$($b37SerialTimeout.Primary) SECONDARY=$($b37SerialTimeout.Secondary) STIMULUS=$($b37SerialTimeout.StimulusEstablished) TRIAL_RESULT=$($b37SerialTimeout.TrialResult) BLOCK_REASON=$($b37SerialTimeout.TrialBlockReason) C2=$($b37SerialTimeout.C2TypeUsbHidReproduction)")
    $b37PeerTimeout=Get-DgDClassification $activeUsb $activePeer $activeRecon @('PEER_GRACEFUL_EXIT_TIMEOUT')
    Record 'b37_c_usb_stimulus_1_peer_graceful_timeout_blocked' ($b37PeerTimeout.Primary -ceq 'DG_D_USB_HID_FAIL' -and $b37PeerTimeout.Secondary -ceq 'BLOCKED_DG_D_ORCHESTRATION' -and $b37PeerTimeout.StimulusEstablished -ceq '1' -and $b37PeerTimeout.TrialResult -ceq 'BLOCKED' -and $b37PeerTimeout.TrialBlockReason -ceq 'BLOCKED_DG_D_ORCHESTRATION' -and $b37PeerTimeout.C2TypeUsbHidReproduction -ceq 'NOT_ESTABLISHED')
    $b37Evidence.Add("B37_EVIDENCE name=B37-C RAW_CONTROL=PEER_GRACEFUL_EXIT_TIMEOUT PRIMARY=$($b37PeerTimeout.Primary) SECONDARY=$($b37PeerTimeout.Secondary) STIMULUS=$($b37PeerTimeout.StimulusEstablished) TRIAL_RESULT=$($b37PeerTimeout.TrialResult) BLOCK_REASON=$($b37PeerTimeout.TrialBlockReason) C2=$($b37PeerTimeout.C2TypeUsbHidReproduction)")
    $activeZeroPeer=Test-DgDPeerSummary (New-PeerFixture 7 'BLOCKED' 0 0 0 0) 0
    $activeZero=Get-DgDClassification $activeUsb $activeZeroPeer (Test-DgDReconciliation $activeUsb $activeZeroPeer)
    Record 'active_usb_failure_stimulus_0_blocked' ($activeZero.Primary -ceq 'DG_D_USB_HID_FAIL' -and $activeZero.StimulusEstablished -ceq '0' -and $activeZero.TrialResult -ceq 'BLOCKED' -and $activeZero.C2TypeUsbHidReproduction -ceq 'NOT_ESTABLISHED')
    Record 'b37_d_usb_stimulus_0_normal_blocked' ($activeZero.Primary -ceq 'DG_D_USB_HID_FAIL' -and $activeZero.TrialResult -ceq 'BLOCKED' -and $activeZero.C2TypeUsbHidReproduction -ceq 'NOT_ESTABLISHED')
    $b37Evidence.Add("B37_EVIDENCE name=B37-D PRIMARY=$($activeZero.Primary) SECONDARY=$($activeZero.Secondary) STIMULUS=$($activeZero.StimulusEstablished) TRIAL_RESULT=$($activeZero.TrialResult) BLOCK_REASON=$($activeZero.TrialBlockReason) C2=$($activeZero.C2TypeUsbHidReproduction)")
    $activeUnknown=Get-DgDClassification $activeUsb $null $null
    Record 'active_usb_failure_stimulus_unknown_blocked' ($activeUnknown.Primary -ceq 'DG_D_USB_HID_FAIL' -and $activeUnknown.StimulusEstablished -ceq 'UNKNOWN' -and $activeUnknown.TrialResult -ceq 'BLOCKED' -and $activeUnknown.C2TypeUsbHidReproduction -ceq 'NOT_ESTABLISHED')
    Record 'b37_e_usb_stimulus_unknown_normal_blocked' ($activeUnknown.Primary -ceq 'DG_D_USB_HID_FAIL' -and $activeUnknown.TrialResult -ceq 'BLOCKED' -and $activeUnknown.C2TypeUsbHidReproduction -ceq 'NOT_ESTABLISHED')
    $b37Evidence.Add("B37_EVIDENCE name=B37-E PRIMARY=$($activeUnknown.Primary) SECONDARY=$($activeUnknown.Secondary) STIMULUS=$($activeUnknown.StimulusEstablished) TRIAL_RESULT=$($activeUnknown.TrialResult) BLOCK_REASON=$($activeUnknown.TrialBlockReason) C2=$($activeUnknown.C2TypeUsbHidReproduction)")
    $b37Root=Join-Path ([IO.Path]::GetTempPath()) ("dg-d-b37-"+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $b37Root|Out-Null
    try{
        $null=@(Write-DgDAdjudicationOutput $b37SerialTimeout $b37Root)
        $rawB37=[IO.File]::ReadAllText((Join-Path $b37Root 'runner-control-plane-observation.txt'),[Text.UTF8Encoding]::new($false))
        $canonicalB37=[IO.File]::ReadAllText((Join-Path $b37Root 'runner-adjudication.txt'),[Text.UTF8Encoding]::new($false))
        Record 'b37_f_raw_orchestration_preserved_not_invented_primary' ($rawB37.Contains('CONTROL_PLANE_OBSERVATION=SERIAL_CAPTURE_TIMEOUT') -and $canonicalB37.Contains('DG_D_CLASSIFICATION_PRIMARY=DG_D_USB_HID_FAIL') -and !$canonicalB37.Contains('SERIAL_CAPTURE_TIMEOUT'))
        $b37Evidence.Add("B37_EVIDENCE name=B37-F RAW_CONTROL_PRESERVED=$($rawB37.Contains('CONTROL_PLANE_OBSERVATION=SERIAL_CAPTURE_TIMEOUT')) CANONICAL_PRIMARY_USB=$($canonicalB37.Contains('DG_D_CLASSIFICATION_PRIMARY=DG_D_USB_HID_FAIL')) RAW_TOKEN_NOT_CANONICAL_PRIMARY=$(!$canonicalB37.Contains('SERIAL_CAPTURE_TIMEOUT'))")
        $unexpectedB37=Get-DgDClassification $activeUsb $activePeer $activeRecon @('UNEXPECTED_B37_CONTROL_TOKEN')
        $unexpectedRoot=Join-Path $b37Root 'unexpected';New-Item -ItemType Directory -Path $unexpectedRoot|Out-Null;$null=@(Write-DgDAdjudicationOutput $unexpectedB37 $unexpectedRoot)
        $unexpectedCanonical=[IO.File]::ReadAllText((Join-Path $unexpectedRoot 'runner-adjudication.txt'),[Text.UTF8Encoding]::new($false))
        $unexpectedRaw=[IO.File]::ReadAllText((Join-Path $unexpectedRoot 'runner-control-plane-observation.txt'),[Text.UTF8Encoding]::new($false))
        Record 'b37_g_unexpected_control_token_fail_closed_no_causal_fail' ($unexpectedB37.Primary -ceq 'DG_D_USB_HID_FAIL' -and $unexpectedB37.Secondary -ceq 'BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID' -and $unexpectedB37.TrialResult -ceq 'BLOCKED' -and $unexpectedB37.C2TypeUsbHidReproduction -ceq 'NOT_ESTABLISHED' -and $unexpectedRaw.Contains('UNEXPECTED_B37_CONTROL_TOKEN') -and !$unexpectedCanonical.Contains('UNEXPECTED_B37_CONTROL_TOKEN'))
        $b37Evidence.Add("B37_EVIDENCE name=B37-G RAW_CONTROL=UNEXPECTED_B37_CONTROL_TOKEN PRIMARY=$($unexpectedB37.Primary) SECONDARY=$($unexpectedB37.Secondary) STIMULUS=$($unexpectedB37.StimulusEstablished) TRIAL_RESULT=$($unexpectedB37.TrialResult) BLOCK_REASON=$($unexpectedB37.TrialBlockReason) C2=$($unexpectedB37.C2TypeUsbHidReproduction) RAW_CONTROL_PRESERVED=$($unexpectedRaw.Contains('UNEXPECTED_B37_CONTROL_TOKEN')) RAW_TOKEN_NOT_CANONICAL=$(!$unexpectedCanonical.Contains('UNEXPECTED_B37_CONTROL_TOKEN'))")
    }finally{Remove-DgDOfflineTempDirectory $b37Root}
    $nonUsbCases=[ordered]@{
        scheduler_timing=@(($base -replace 'SCHEDULER_MISSED_DEADLINE=0','SCHEDULER_MISSED_DEADLINE=1'),'BLOCKED_DG_D_TIMING_FAIL')
        phy_link=@(($base -replace 'FINAL_PHY_OK=1','FINAL_PHY_OK=0'),'BLOCKED_DG_D_PHY_HEALTH_FAIL')
        versionr=@(($base -replace 'VERSIONR=04','VERSIONR=03'),'BLOCKED_DG_D_PHY_HEALTH_FAIL')
        buffer_map=@(($base -replace 'FINAL_BUFFER_MAP_OK=1','FINAL_BUFFER_MAP_OK=0'),'BLOCKED_DG_D_PHY_HEALTH_FAIL')
        max_spi=@(($base -replace 'MAX_REGISTER_TRIPLE_READ_MISMATCH=0','MAX_REGISTER_TRIPLE_READ_MISMATCH=1'),'BLOCKED_DG_D_MAX_SPI_CANARY_FAIL')
        drain_timeout=@((New-DgDSerialFixture 497 'FAIL' 'BLOCKED_DG_D_DRAIN_TIMEOUT'),'BLOCKED_DG_D_DRAIN_TIMEOUT')
        pre_parse_after_valid=@(($base -replace 'RX_PRE_PARSE_REMAINING_NONZERO=0','RX_PRE_PARSE_REMAINING_NONZERO=1'),'BLOCKED_DG_D_PRE_PARSE_REMAINING_NONZERO')
        negative_parse_after_valid=@(($base -replace 'RX_PARSE_NEGATIVE_TOTAL=0','RX_PARSE_NEGATIVE_TOTAL=1'),'BLOCKED_DG_D_PARSE_API_NEGATIVE')
        size_after_valid=@(($base -replace 'RX_POSITIVE_OTHER_SIZE_TOTAL=0','RX_POSITIVE_OTHER_SIZE_TOTAL=1'),'BLOCKED_DG_D_POSITIVE_SIZE_NOT_32')
        discard_after_valid=@(($base -replace 'RX_NULL_DISCARD_BYTES_TOTAL=15904','RX_NULL_DISCARD_BYTES_TOTAL=15873'),'BLOCKED_DG_D_NULL_DISCARD_RETURN_MISMATCH')
        post_discard_after_valid=@(($base -replace 'RX_POST_DISCARD_REMAINING_NONZERO=0','RX_POST_DISCARD_REMAINING_NONZERO=1'),'BLOCKED_DG_D_POST_DISCARD_REMAINING_NONZERO')
    }
    foreach($name in $nonUsbCases.Keys){$fixture=$nonUsbCases[$name];$parsed=Test-DgDSerialLog $fixture[0];$result=Get-DgDClassification $parsed $peer (Test-DgDReconciliation $parsed $peer);Record "non_usb_${name}_blocked_never_fail" ($result.Primary -ceq $fixture[1] -and $result.TrialResult -ceq 'BLOCKED' -and $result.C2TypeUsbHidReproduction -ceq 'NOT_ESTABLISHED')}
    $mismatchPeer=Test-DgDPeerSummary (New-PeerFixture 496) 0
    $mismatch=Get-DgDClassification $serial $mismatchPeer (Test-DgDReconciliation $serial $mismatchPeer)
    Record 'non_usb_reconciliation_mismatch_blocked_never_fail' ($mismatch.Primary -ceq 'BLOCKED_DG_D_RECONCILIATION_MISMATCH' -and $mismatch.StimulusEstablished -ceq '1' -and $mismatch.TrialResult -ceq 'BLOCKED')
    $illegalLogicalFail=Convert-DgDClosedWorldAdjudication ([pscustomobject]@{Primary='DG_D_DEVICE_LOGICAL_FAIL';Secondary='NONE';StimulusEstablished='1';TrialResult='FAIL';TrialBlockReason='NONE';DevicePretrialReason='NONE';C2TypeUsbHidReproduction='NOT_ESTABLISHED';SubmissionToOpenPort='1'})
    Record 'device_logical_fail_cannot_serialize_as_fail' ($illegalLogicalFail.Adjudication.Primary -ceq 'BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID' -and $illegalLogicalFail.Adjudication.TrialResult -ceq 'BLOCKED')
    $unknown=Convert-DgDClosedWorldAdjudication ([pscustomobject]@{Primary='UNKNOWN_TOKEN';Secondary='NONE';StimulusEstablished='1';TrialResult='PASS';TrialBlockReason='NONE';DevicePretrialReason='NONE';C2TypeUsbHidReproduction='NOT_ESTABLISHED';SubmissionToOpenPort='1'});Record 'unknown_token_invalidates_contract' ($unknown.Adjudication.Primary -ceq 'BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID')
    $temp=Join-Path ([IO.Path]::GetTempPath()) ("dg-d-serializer-"+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $temp|Out-Null
    try{$lines=@(Get-DgDAdjudicationLines $classification);[void](Write-DgDAdjudicationFile $temp $lines);$bytes=[IO.File]::ReadAllBytes((Join-Path $temp 'runner-adjudication.txt'));$expected=[Text.UTF8Encoding]::new($false).GetBytes(($lines -join "`n")+"`n");Record 'serializer_stdout_file_bytes_equal' ([Linq.Enumerable]::SequenceEqual([byte[]]$bytes,[byte[]]$expected));Record 'serializer_utf8_no_bom' ([bool](!($bytes.Length-ge 3 -and $bytes[0]-eq 0xEF -and $bytes[1]-eq 0xBB -and $bytes[2]-eq 0xBF)));Record 'serializer_exactly_one_block' ((@($lines|Where-Object{$_ -like 'DG_D_CLASSIFICATION_PRIMARY=*'}).Count)-eq 1)}finally{Remove-DgDOfflineTempDirectory $temp}
    $pass=@($results|Where-Object Pass).Count;$fail=$results.Count-$pass;$lines=@($results|ForEach-Object{"OFFLINE_TEST name=$($_.Name) result=$(if($_.Pass){'PASS'}else{'FAIL'})"})+@($b37Evidence)+@("OFFLINE_TEST_RESULT=$(if($fail-eq 0){'PASS'}else{'FAIL'}) PASS=$pass FAIL=$fail TOTAL=$($results.Count)");[pscustomobject]@{Pass=$fail-eq 0;Lines=$lines;Results=$results}
}

function Invoke-Captured([string]$File,[string[]]$Arguments,[string]$Stdout,[string]$Stderr,[switch]$AllowNonZero) {
    $p=Start-Process -FilePath $File -ArgumentList $Arguments -NoNewWindow -PassThru -Wait -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
    if(!$AllowNonZero -and $p.ExitCode -ne 0){throw "process failed file=$File exit=$($p.ExitCode)"}
    $p.ExitCode
}

function Write-Utf8([string]$Path,[string[]]$Lines) {[IO.File]::WriteAllLines($Path,$Lines,[Text.UTF8Encoding]::new($false))}

function Assert-ReviewedImplementationAuthority([string]$Manifest,[string]$ExpectedHash) {
    if([string]::IsNullOrWhiteSpace($Manifest)-or[string]::IsNullOrWhiteSpace($ExpectedHash)){throw 'BLOCKED_DG_D_IMPLEMENTATION_AUTHORITY_REQUIRED'}
    Assert-FileIdentity $Manifest (Get-Item -LiteralPath $Manifest).Length $ExpectedHash 'BLOCKED_DG_D_IMPLEMENTATION_AUTHORITY_IDENTITY_MISMATCH'|Out-Null
    foreach($row in Import-Csv -LiteralPath $Manifest){Assert-FileIdentity $row.path ([int64]$row.size) $row.sha256 'BLOCKED_DG_D_IMPLEMENTATION_AUTHORITY_IDENTITY_MISMATCH'|Out-Null}
}

function Start-DgDSerialCaptureJob([string]$TrialRoot,[int]$DurationSeconds,[string]$PnpDeviceId) {
    $serialPath=Join-Path $TrialRoot 'serial.log';$metadataPath=Join-Path $TrialRoot 'serial-capture-metadata.txt';$readyPath=Join-Path $TrialRoot 'serial.capture.ready';$errorPath=Join-Path $TrialRoot 'serial-capture-error.txt'
    $job=Start-Job -ArgumentList @($serialPath,$metadataPath,$readyPath,$errorPath,$DurationSeconds,$PnpDeviceId) -ScriptBlock {
        param($SerialPath,$MetadataPath,$ReadyPath,$ErrorPath,$Duration,$Pnp)
        $encoding=[Text.UTF8Encoding]::new($false);$start=[DateTime]::UtcNow;$builder=[Text.StringBuilder]::new();$terminal=$false;$timedOut=$false;$captureError='NONE';$port=$null
        try{
            $port=[IO.Ports.SerialPort]::new('COM4',115200,'None',8,'One');$port.DtrEnable=$false;$port.RtsEnable=$false;$port.Open()
            [IO.File]::WriteAllText($ReadyPath,"SERIAL_CAPTURE_READY=1`n",$encoding)
            $deadline=[DateTime]::UtcNow.AddSeconds($Duration+30)
            while([DateTime]::UtcNow -lt $deadline){
                $chunk=$port.ReadExisting()
                if($chunk){[void]$builder.Append($chunk);if($builder.ToString().Contains('SCOPE_MARKER trial=DG-D event=TRIAL_COMPLETE')){$terminal=$true;break}}
                Start-Sleep -Milliseconds 10
            }
            if(!$terminal){$timedOut=$true}
        }catch{$captureError=$_.Exception.Message;[IO.File]::WriteAllText($ErrorPath,$captureError,$encoding)}finally{
            if($null-ne $port){try{if($port.IsOpen){$port.Close()}}catch{};try{$port.Dispose()}catch{}}
            $text=$builder.ToString();[IO.File]::WriteAllText($SerialPath,$text,$encoding)
            $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($encoding.GetBytes($text)))).Replace('-','')}finally{$sha.Dispose()}
            $end=[DateTime]::UtcNow
            $metadata=@("COM_PORT=COM4","COM_PNP_DEVICE_ID=$Pnp","CAPTURE_START_UTC=$($start.ToString('o'))","CAPTURE_END_UTC=$($end.ToString('o'))","TERMINAL_DETECTED=$(if($terminal){1}else{0})","CAPTURE_TIMEOUT=$(if($timedOut){1}else{0})","CAPTURED_CHARACTER_LENGTH=$($text.Length)","CAPTURE_UTF8_SHA256=$hash","CAPTURE_ERROR=$captureError")
            [IO.File]::WriteAllLines($MetadataPath,$metadata,$encoding)
        }
        if($captureError -ne 'NONE'){throw 'BLOCKED_DG_D_CONTROL_PLANE'}
    }
    [pscustomobject]@{Job=$job;SerialPath=$serialPath;MetadataPath=$metadataPath;ReadyPath=$readyPath;ErrorPath=$errorPath}
}

function Invoke-DgDPhysicalTrial {
    if(!($RunPhysicalTrial -and $AllowUpload -and $AllowSerial -and $AllowPeer -and $AllowNetworkTrial)){throw 'Physical trial requires all explicit permission switches.'}
    try{Assert-ReviewedImplementationAuthority $ReviewedManifestPath $ExpectedReviewedManifestSha256}catch{
        $token=Get-DgDFailureToken $_.Exception.Message
        Write-DgDAdjudicationOutput ([pscustomobject]@{Primary=$token;Secondary='NONE';StimulusEstablished='UNKNOWN';TrialResult='BLOCKED';TrialBlockReason=$token;DevicePretrialReason='NONE';C2TypeUsbHidReproduction='NOT_ESTABLISHED';SubmissionToOpenPort='UNKNOWN'})
        throw
    }
    $trialRoot=Join-Path $physicalEvidenceRoot ("DG-D-$Trial-{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'),([guid]::NewGuid().ToString('N').Substring(0,8)));New-Item -ItemType Directory -Force -Path $trialRoot|Out-Null
    $adjudicationEmitted=$false
    try {
    if($ExpectedPnpDeviceId -cne $fixedPnpDeviceId){throw 'BLOCKED_DG_D_COM4_PNP_IDENTITY'}
    $staging=New-DgDArtifactStaging $Trial (Join-Path $trialRoot 'artifact-staging') -UseRootAsStaging
    $plan=Get-DgDUploadPlan $staging
    $toolchain=Get-DgDToolchainAuthority
    $toolchain.PSObject.Properties|ForEach-Object{"$($_.Name)=$($_.Value)"}|Set-Content -LiteralPath (Join-Path $trialRoot 'toolchain-identity.txt') -Encoding utf8
    $pre=Get-DgDArtifactIdentityRows $staging $toolchain PRE_UPLOAD;Assert-DgDArtifactIdentityRows $pre $staging|Out-Null
    $pre|Export-Csv -LiteralPath (Join-Path $trialRoot 'artifact-authority-pre-upload.csv') -NoTypeInformation -Encoding utf8
    $planLines=@("FUTURE_UPLOAD_COMMAND=$($plan.Command)")+@($plan.Segments|ForEach-Object{"UPLOAD_SEGMENT OFFSET=$($_.Offset) ROLE=$($_.Role) ACTUAL_INPUT_PATH=$($_.Path) STAGED_EVIDENCE_PATH=$($_.StagedEvidencePath) SHA256=$($_.Sha256)"})
    Write-Utf8 (Join-Path $trialRoot 'upload-plan.txt') $planLines
    $com=Get-Com4IdentityRecords;if(!(Test-ExactCom4Identity $com $ExpectedPnpDeviceId)){throw 'BLOCKED_DG_D_COM4_PNP_IDENTITY'}
    Assert-DgDPeerTopology
    $arm=Join-Path $trialRoot 'peer.arm';$armed=Join-Path $trialRoot 'peer.armed';$ready=Join-Path $trialRoot 'peer.ready';$stop=Join-Path $trialRoot 'peer.stop';$csv=Join-Path $trialRoot 'peer.csv';$peerOut=Join-Path $trialRoot 'peer.stdout.log';$peerErr=Join-Path $trialRoot 'peer.stderr.log'
    $peer=Start-Process -FilePath 'python.exe' -ArgumentList @($peerScript,'--live','--bind-ip',$peerIp,'--port','50001','--arm-file',$arm,'--armed-file',$armed,'--ready-file',$ready,'--stop-file',$stop,'--csv',$csv) -PassThru -WindowStyle Hidden -RedirectStandardOutput $peerOut -RedirectStandardError $peerErr
    $controlPlaneObservations=[Collections.Generic.List[string]]::new();$armRequested=$false;$serialCapture=$null
    try{
        $watch=[Diagnostics.Stopwatch]::StartNew();while(!(Test-Path -LiteralPath $ready)){if($peer.HasExited){throw 'BLOCKED_DG_D_CONTROL_PLANE'};if($watch.Elapsed.TotalSeconds -gt 10){throw 'BLOCKED_DG_D_ORCHESTRATION'};Start-Sleep -Milliseconds 50}
        [void](Assert-StagedArtifactIdentity $staging)
        $uploadOut=Join-Path $trialRoot 'upload.stdout.log';$uploadErr=Join-Path $trialRoot 'upload.stderr.log';$upload=Start-Process -FilePath $toolchain.ARDUINO_CLI_PATH -ArgumentList @('upload','--fqbn',$fqbn,'--port','COM4','--input-dir',$staging.Path) -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $uploadOut -RedirectStandardError $uploadErr
        if($upload.ExitCode -ne 0){throw 'BLOCKED_DG_D_EXACT_C1_ARTIFACT_UPLOAD_PATH_UNRESOLVED'}
        if(!(Test-DgDUploadEvidence $uploadOut $staging.Authority)){throw 'BLOCKED_DG_D_EXACT_C1_ARTIFACT_UPLOAD_PATH_UNRESOLVED upload_evidence_invalid'}
        $post=Get-DgDArtifactIdentityRows $staging $toolchain POST_UPLOAD;Assert-DgDArtifactIdentityRows $post $staging|Out-Null;Compare-DgDArtifactIdentityRows $pre $post|Out-Null
        $post|Export-Csv -LiteralPath (Join-Path $trialRoot 'artifact-authority-post-upload.csv') -NoTypeInformation -Encoding utf8
        [void](Wait-ExactCom4Reenumeration $ExpectedPnpDeviceId 15)
        $serialCapture=Start-DgDSerialCaptureJob $trialRoot $staging.Authority.DurationSeconds $ExpectedPnpDeviceId
        $watch.Restart();while(!(Test-Path -LiteralPath $serialCapture.ReadyPath)){if($serialCapture.Job.State -in @('Completed','Failed','Stopped')){Receive-Job $serialCapture.Job -ErrorAction SilentlyContinue|Out-File -LiteralPath (Join-Path $trialRoot 'serial-capture-job.log') -Encoding utf8;throw 'BLOCKED_DG_D_CONTROL_PLANE'};if($watch.Elapsed.TotalSeconds -gt 5){throw 'BLOCKED_DG_D_CONTROL_PLANE'};Start-Sleep -Milliseconds 25}
        Write-Utf8 $arm @('SERIAL_CAPTURE_READY=1','UPLOAD_PASS=1','ARM=1');$armRequested=$true
        $watch.Restart();while(!(Test-Path -LiteralPath $armed)){if($peer.HasExited){throw 'BLOCKED_DG_D_CONTROL_PLANE'};if($watch.Elapsed.TotalSeconds -gt 10){throw 'BLOCKED_DG_D_ORCHESTRATION'};Start-Sleep -Milliseconds 50}
        if(!(Wait-Job $serialCapture.Job -Timeout ($staging.Authority.DurationSeconds+40))){$controlPlaneObservations.Add('SERIAL_CAPTURE_TIMEOUT');Stop-Job $serialCapture.Job -ErrorAction SilentlyContinue}
        Receive-Job $serialCapture.Job -ErrorAction SilentlyContinue|Out-File -LiteralPath (Join-Path $trialRoot 'serial-capture-job.log') -Encoding utf8
        if(!(Test-Path -LiteralPath $serialCapture.SerialPath)){throw 'BLOCKED_DG_D_CONTROL_PLANE'}
        $serialText=[IO.File]::ReadAllText($serialCapture.SerialPath,[Text.UTF8Encoding]::new($false));$provisional=Get-DgDRawProvisionalPrimary $serialText
        Write-Utf8 $stop @('PEER_STOP=1')
        if(!$peer.WaitForExit(10000)){$controlPlaneObservations.Add('PEER_GRACEFUL_EXIT_TIMEOUT')}
        $peerText=if(Test-Path $peerOut){Get-Content -LiteralPath $peerOut -Raw}else{''}
        $serialResult=Test-DgDSerialLog $serialText;$peerResult=Test-DgDPeerSummary $peerText $(if($peer.HasExited){$peer.ExitCode}else{-1});$recon=Test-DgDReconciliation $serialResult $peerResult;$classification=Get-DgDClassification $serialResult $peerResult $recon $controlPlaneObservations.ToArray()
        Write-DgDAdjudicationOutput $classification $trialRoot;$adjudicationEmitted=$true
        if($classification.TrialResult -ne 'PASS'){throw "DG-D trial non-pass: primary=$($classification.Primary) trial_result=$($classification.TrialResult)"}
    } catch {
        Write-Utf8 (Join-Path $trialRoot 'runner-terminal-error.txt') @("ARM_REQUESTED=$(if($armRequested){1}else{0})","ERROR=$($_.Exception.Message)")
        throw
    } finally {
        if($null-ne $serialCapture -and $serialCapture.Job.State -notin @('Completed','Failed','Stopped')){Stop-Job $serialCapture.Job -ErrorAction SilentlyContinue;Receive-Job $serialCapture.Job -ErrorAction SilentlyContinue|Out-Null}
        if(!$peer.HasExited){Write-Utf8 $stop @('PEER_STOP=1');if(!$peer.WaitForExit(5000)){Stop-Process -Id $peer.Id -Force -ErrorAction SilentlyContinue}}
    }
    } catch {
        if(!$adjudicationEmitted){
            $token=Get-DgDFailureToken $_.Exception.Message
            $catchStimulus='UNKNOWN';$catchSecondary='';$catchRawObservations=@()
            $controlObservationVariable=Get-Variable -Name controlPlaneObservations -ErrorAction SilentlyContinue
            if($null-ne $controlObservationVariable){$catchRawObservations=@($controlObservationVariable.Value.ToArray())}
            try{
                $peerOutVariable=Get-Variable -Name peerOut -ErrorAction SilentlyContinue
                if($null-ne $peerOutVariable -and (Test-Path -LiteralPath $peerOutVariable.Value -PathType Leaf)){
                    $catchPeerText=Get-Content -LiteralPath $peerOutVariable.Value -Raw
                    $peerVariable=Get-Variable -Name peer -ErrorAction SilentlyContinue
                    $catchExit=if($null-ne $peerVariable -and $peerVariable.Value.HasExited){$peerVariable.Value.ExitCode}else{-1}
                    $catchPeer=Test-DgDPeerSummary $catchPeerText $catchExit
                    $catchStimulus=Get-DgDStimulusEstablished $null $catchPeer
                    if(!$catchPeer.EvidenceContractValid){$catchSecondary='BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID'}elseif($catchPeer.AsyncError){$catchSecondary='BLOCKED_DG_D_PEER_UDP_ASYNC_ERROR'}elseif($catchPeer.AdmissionBlocked){$catchSecondary='BLOCKED_DG_D_ADMISSION_SEQUENCE_MISS'}elseif($catchPeer.SendFail){$catchSecondary='DG_D_PEER_INGRESS_SEND_FAIL'}
                }
            }catch{$catchStimulus='UNKNOWN';$catchSecondary='BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID'}
            Write-DgDAdjudicationOutput ([pscustomobject]@{Primary=$token;Secondary=if($catchSecondary){$catchSecondary}else{'NONE'};StimulusEstablished=$catchStimulus;TrialResult='BLOCKED';TrialBlockReason=$token;DevicePretrialReason='NONE';C2TypeUsbHidReproduction='NOT_ESTABLISHED';SubmissionToOpenPort=if($catchStimulus -ceq 'UNKNOWN'){'UNKNOWN'}elseif($catchStimulus -ceq '1'){'1'}else{'0'};RawControlPlaneObservations=$catchRawObservations}) $trialRoot
            $adjudicationEmitted=$true
        }
        if(!(Test-Path -LiteralPath (Join-Path $trialRoot 'runner-terminal-error.txt'))){Write-Utf8 (Join-Path $trialRoot 'runner-terminal-error.txt') @('ARM_REQUESTED=0',"ERROR=$($_.Exception.Message)")}
        throw
    }
}

if($OfflineSelfTest){$r=Invoke-DgDOfflineSelfTests;$r.Lines|ForEach-Object{Write-Output $_};if(!$r.Pass){exit 1};exit 0}
if($EmitUploadPlan){$stage=New-DgDArtifactStaging $Trial (Join-Path $validationRoot 'plan-staging');$plan=Get-DgDUploadPlan $stage;Write-Output "FUTURE_UPLOAD_COMMAND=$($plan.Command)";foreach($segment in $plan.Segments){Write-Output "UPLOAD_SEGMENT OFFSET=$($segment.Offset) ROLE=$($segment.Role) ACTUAL_INPUT_PATH=$($segment.Path) STAGED_EVIDENCE_PATH=$($segment.StagedEvidencePath) SHA256=$($segment.Sha256)"};Write-Output 'BUILD=NOT_RUN';Write-Output 'COMPILE=NOT_RUN';Write-Output 'UPLOAD=NOT_RUN';exit 0}
if($RunPhysicalTrial){Invoke-DgDPhysicalTrial;exit 0}
Write-Output 'DG-D runner safe default: no action.'
Write-Output 'Allowed offline modes: -OfflineSelfTest, -EmitUploadPlan.'
Write-Output 'Physical mode is implemented but requires -RunPhysicalTrial and all explicit permission switches.'
