[CmdletBinding()]
param(
    [ValidateSet('S1','T1')][string]$Trial = 'S1',
    [switch]$OfflineSelfTest,
    [switch]$EmitUploadPlan,
    [switch]$CreateReviewPackage,
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
$peerScript = Join-Path $PSScriptRoot 'usb_lan_gate_dg_b_peer.py'
$contractPath = Join-Path $repoRoot 'docs\usb-lan-gate-dg-b-contract.md'
$freezeRoot = Join-Path $repoRoot 'build-temp\usb-lan-isolation\freeze\C1-final-20260818-005403-666bf93b'
$freezeZip = "$freezeRoot.zip"
$validationRoot = Join-Path $repoRoot 'build-temp\usb-lan-isolation\implementation-validation\dg-b'
$physicalEvidenceRoot = Join-Path $repoRoot 'build-temp\usb-lan-isolation\gate-dg-b'
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
$dropPort = 50002

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
    S1ApplicationSize = [int64]562480
    S1ApplicationSha256 = '8320BD7B6BD08D145DE47C8EBAE21497916653592CC625E5AEE55E627CFCD140'
    S1MergedSize = [int64]16777216
    S1MergedSha256 = '0F172CFC1286D369B8D8652688FE1A4071863DA5A9AC7B33352EE10ACB154F07'
    T1ApplicationSize = [int64]562480
    T1ApplicationSha256 = '0AFD5F98AC9D7EF440442416AB8F84E47DBCF4F4EDE30BEC4B89EC57DED5960B'
    T1MergedSize = [int64]16777216
    T1MergedSha256 = '70424920B0529D733704EE95493FB268EAE38D09FC5595CA9A329B1FEAADB5C0'
}

$donors = @(
    [pscustomobject]@{ Role='c1_runner_parser'; Relative='build-temp\usb-lan-isolation\freeze\C1-final-20260818-005403-666bf93b\source\reviewed-files\c1_runner\usb_lan_gate_c1_runner.ps1'; Size=50138; Sha256='5B24705265AA3B2D3830B2446F4BF75CCBACC4389C5605F475A968BA4F93E6B6' },
    [pscustomobject]@{ Role='c1_peer_parser'; Relative='build-temp\usb-lan-isolation\freeze\C1-final-20260818-005403-666bf93b\source\reviewed-files\peer\usb_lan_gate_peer.py'; Size=19422; Sha256='2D1CFD91DD68DAF9F2A25D0F80962315CBB0648A4AD517B3279AEAF491E8663A' },
    [pscustomobject]@{ Role='c2_peer_admission_send'; Relative='build-temp\usb-lan-isolation\freeze\C2-final-failure-20260819-194013-1e8535d8\authority\usb_lan_gate_c2_peer.py'; Size=40178; Sha256='B63F0C50F4B7A27964A79722DCC47E86254DA7E953CBBAC2827BFCBEDC727598' },
    [pscustomobject]@{ Role='c2_runner_control_plane'; Relative='build-temp\usb-lan-isolation\freeze\C2-final-failure-20260819-194013-1e8535d8\authority\usb_lan_gate_c2_runner.ps1'; Size=73380; Sha256='84997D656D85AA41687A33A8EF361777F5DF46B5A86536DE9499906808B5B65A' },
    [pscustomobject]@{ Role='dg_a_peer_evidence'; Relative='build-temp\usb-lan-isolation\review\DG-A-implementation-review-20260820-215826-6af1c445\source\usb_lan_gate_dg_a_peer.py'; Size=40843; Sha256='6BA4D03C7FC517DC1A958D5A3FA34D55B8DEC92B393B52AB78F6FF8BE7EE4CFF' },
    [pscustomobject]@{ Role='dg_a_runner_teardown_tier1'; Relative='build-temp\usb-lan-isolation\review\DG-A-implementation-review-20260820-215826-6af1c445\source\usb_lan_gate_dg_a_runner.ps1'; Size=122259; Sha256='58FF23B9FC8577F9D63A45E3B0F4A1C3754EB5300D7ABE181710F24793952AB7' }
)

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
    $trialId = if ($Stage -eq 'S1') { 'C1-S1-20260817-235834-96783058' } else { 'C1-T1-20260818-001549-6d8af092' }
    $caseName = if ($Stage -eq 'S1') { 'mode15-fixed10-udp-tx-only-10s' } else { 'mode15-fixed10-udp-tx-only-60s' }
    $build = Join-Path $freezeRoot "accepted\$trialId\build-matrix\$caseName\build"
    $base = 'M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino'
    $bootAppPath = Join-Path $env:LOCALAPPDATA 'Arduino15\packages\m5stack\hardware\esp32\3.3.7\tools\partitions\boot_app0.bin'
    [pscustomobject]@{
        Stage = $Stage
        TrialId = $trialId
        DurationSeconds = if ($Stage -eq 'S1') { 10 } else { 60 }
        Application = Join-Path $build "$base.bin"
        ApplicationSize = $authority["${Stage}ApplicationSize"]
        ApplicationSha256 = $authority["${Stage}ApplicationSha256"]
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
    Assert-FileIdentity $manifest (Get-Item -LiteralPath $manifest).Length $authority.ArchiveManifestSha256 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH' | Out-Null
    Assert-FileIdentity $freezeZip $authority.FreezeZipSize $authority.FreezeZipSha256 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH' | Out-Null
}

function Assert-DonorAuthority {
    $verified = foreach ($donor in $donors) {
        $path = Join-Path $repoRoot $donor.Relative
        $item = Assert-FileIdentity $path $donor.Size $donor.Sha256 'BLOCKED_DG_B_DONOR_AUTHORITY_IDENTITY_UNRESOLVED'
        [pscustomobject]@{ Role=$donor.Role; Path=$item.Path; Size=$item.Size; Sha256=$item.Sha256; Result='PASS' }
    }
    @($verified)
}

function Get-MergedSliceSha256([string]$MergedPath) {
    $stream = [IO.File]::Open($MergedPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        [void]$stream.Seek(0xE000,[IO.SeekOrigin]::Begin)
        $bytes = [byte[]]::new(8192)
        $read = $stream.Read($bytes,0,$bytes.Length)
        if ($read -ne 8192) { throw 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH merged_slice_short' }
        Get-BytesSha256 $bytes
    } finally { $stream.Dispose() }
}

function Assert-StageAuthority([ValidateSet('S1','T1')][string]$Stage) {
    Assert-C1FreezeAuthority
    $a = Get-StageAuthority $Stage
    $verified = @(
        Assert-FileIdentity $a.Application $a.ApplicationSize $a.ApplicationSha256 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH'
        Assert-FileIdentity $a.Bootloader $a.BootloaderSize $a.BootloaderSha256 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH'
        Assert-FileIdentity $a.Partitions $a.PartitionsSize $a.PartitionsSha256 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH'
        Assert-FileIdentity $a.BootApp0 $a.BootApp0Size $a.BootApp0Sha256 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH'
        Assert-FileIdentity $a.Merged $a.MergedSize $a.MergedSha256 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH'
    )
    $sliceHash = Get-MergedSliceSha256 $a.Merged
    if ($sliceHash -cne $a.BootApp0Sha256) {
        throw "BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH boot_app0_merged_slice expected=$($a.BootApp0Sha256) actual=$sliceHash"
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

function New-DgBArtifactStaging([ValidateSet('S1','T1')][string]$Stage,[string]$Root,[switch]$UseRootAsStaging) {
    $verified = Assert-StageAuthority $Stage
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $stagePath = if($UseRootAsStaging){[IO.Path]::GetFullPath($Root)}else{Join-Path $Root ("DG-B-{0}-{1}-{2}" -f $Stage,(Get-Date -Format 'yyyyMMdd-HHmmss'),([guid]::NewGuid().ToString('N').Substring(0,8)))}
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
    Assert-FileIdentity $targets.Application $a.ApplicationSize $a.ApplicationSha256 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH' | Out-Null
    Assert-FileIdentity $targets.Bootloader $a.BootloaderSize $a.BootloaderSha256 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH' | Out-Null
    Assert-FileIdentity $targets.Partitions $a.PartitionsSize $a.PartitionsSha256 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH' | Out-Null
    Assert-FileIdentity $targets.BootApp0 $a.BootApp0Size $a.BootApp0Sha256 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH' | Out-Null
    Assert-FileIdentity $targets.Merged $a.MergedSize $a.MergedSha256 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH' | Out-Null
    if ((Get-MergedSliceSha256 $targets.Merged) -cne (Get-Sha256 $targets.BootApp0)) {
        throw 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH staged_boot_app0_merged_slice'
    }
    [pscustomobject]@{ Stage=$Stage; Path=$stagePath; Authority=$a; Files=[pscustomobject]$targets }
}

function Assert-StagedArtifactIdentity([pscustomobject]$Staging) {
    $a=$Staging.Authority
    Assert-FileIdentity $Staging.Files.Application $a.ApplicationSize $a.ApplicationSha256 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH'|Out-Null
    Assert-FileIdentity $Staging.Files.Bootloader $a.BootloaderSize $a.BootloaderSha256 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH'|Out-Null
    Assert-FileIdentity $Staging.Files.Partitions $a.PartitionsSize $a.PartitionsSha256 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH'|Out-Null
    Assert-FileIdentity $Staging.Files.BootApp0 $a.BootApp0Size $a.BootApp0Sha256 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH'|Out-Null
    Assert-FileIdentity $Staging.Files.Merged $a.MergedSize $a.MergedSha256 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH'|Out-Null
    Assert-FileIdentity $a.BootApp0 $a.BootApp0Size $a.BootApp0Sha256 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH'|Out-Null
    if((Get-MergedSliceSha256 $Staging.Files.Merged) -cne $a.BootApp0Sha256){throw 'BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH staged_boot_app0_merged_slice'}
    $true
}

function Get-DgBToolchainAuthority([string]$CliPath=$fixedArduinoCliPath,[string]$CliVersionOverride='',[string]$CoreVersionOverride='') {
    $coreVersion=if($CoreVersionOverride){$CoreVersionOverride}else{$requiredM5StackCoreVersion}
    $corePath=Join-Path $env:LOCALAPPDATA "Arduino15\packages\m5stack\hardware\esp32\$coreVersion"
    $platformPath=Join-Path $corePath 'platform.txt'
    $bootApp0Path=Join-Path $corePath 'tools\partitions\boot_app0.bin'
    if(!(Test-Path -LiteralPath $CliPath -PathType Leaf)){throw 'BLOCKED_DG_B_UPLOAD_TOOLCHAIN_IDENTITY_MISMATCH cli_missing'}
    if(!(Test-Path -LiteralPath $platformPath -PathType Leaf)){throw 'BLOCKED_DG_B_UPLOAD_TOOLCHAIN_IDENTITY_MISMATCH platform_missing'}
    if(!(Test-Path -LiteralPath $bootApp0Path -PathType Leaf)){throw 'BLOCKED_DG_B_UPLOAD_TOOLCHAIN_IDENTITY_MISMATCH boot_app0_missing'}
    $cliVersion=$CliVersionOverride
    if(!$cliVersion){
        $versionOutput=& $CliPath version 2>&1 | Out-String
        if($LASTEXITCODE -ne 0 -or $versionOutput -notmatch 'Version:\s*([0-9]+(?:\.[0-9]+){2})'){throw 'BLOCKED_DG_B_UPLOAD_TOOLCHAIN_IDENTITY_MISMATCH cli_version_unresolved'}
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
       $record.BOOT_APP0_ACTUAL_SHA256 -cne $authority.BootApp0Sha256){throw 'BLOCKED_DG_B_UPLOAD_TOOLCHAIN_IDENTITY_MISMATCH'}
    $record
}

function Get-DgBArtifactIdentityRows([pscustomobject]$Staging,[pscustomobject]$Toolchain,[ValidateSet('PRE_UPLOAD','POST_UPLOAD')][string]$Phase) {
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

function Assert-DgBArtifactIdentityRows([object[]]$Rows,[pscustomobject]$Staging) {
    $expected=[ordered]@{
        application=@($Staging.Authority.ApplicationSize,$Staging.Authority.ApplicationSha256)
        bootloader=@($Staging.Authority.BootloaderSize,$Staging.Authority.BootloaderSha256)
        partitions=@($Staging.Authority.PartitionsSize,$Staging.Authority.PartitionsSha256)
        boot_app0_staged_evidence=@($Staging.Authority.BootApp0Size,$Staging.Authority.BootApp0Sha256)
        boot_app0_actual_upload_input=@($Staging.Authority.BootApp0Size,$Staging.Authority.BootApp0Sha256)
        merged_authority_not_uploaded=@($Staging.Authority.MergedSize,$Staging.Authority.MergedSha256)
        merged_0xE000_slice=@([int64]8192,$Staging.Authority.BootApp0Sha256)
    }
    if(@($Rows).Count -ne $expected.Count){throw 'BLOCKED_DG_B_UPLOAD_ARTIFACT_IDENTITY_DRIFT row_count'}
    foreach($role in $expected.Keys){
        $row=@($Rows|Where-Object Role -ceq $role)
        if($row.Count -ne 1 -or [int64]$row[0].Size -ne [int64]$expected[$role][0] -or $row[0].Sha256 -cne $expected[$role][1]){throw "BLOCKED_DG_B_UPLOAD_ARTIFACT_IDENTITY_DRIFT role=$role"}
    }
    $true
}

function Compare-DgBArtifactIdentityRows([object[]]$Pre,[object[]]$Post) {
    foreach($preRow in $Pre){
        $postRow=@($Post|Where-Object Role -ceq $preRow.Role)
        if($postRow.Count -ne 1 -or $postRow[0].Path -cne $preRow.Path -or [int64]$postRow[0].Size -ne [int64]$preRow.Size -or $postRow[0].Sha256 -cne $preRow.Sha256){throw "BLOCKED_DG_B_UPLOAD_ARTIFACT_IDENTITY_DRIFT role=$($preRow.Role)"}
    }
    $true
}

function Get-DgBUploadPlan([pscustomobject]$Staging) {
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

function Test-DgBUploadEvidence([string]$StdoutPath,[pscustomobject]$StageAuthority) {
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
    if($ExpectedPnp -cne $fixedPnpDeviceId){throw 'BLOCKED_DG_B_COM4_PNP_IDENTITY'}
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds){
        try{$records=Get-Com4IdentityRecords;if(Test-ExactCom4Identity $records $ExpectedPnp){return $records[0]}}catch{}
        Start-Sleep -Milliseconds 100
    }
    throw 'BLOCKED_DG_B_COM4_REENUMERATION'
}

function Test-DgBPeerTopologyRecords([object[]]$IpRecords,[object[]]$AdapterRecords,[object[]]$RouteRecords,[object[]]$GatewayRecords) {
    $matched=@($IpRecords|Where-Object{$_.IPAddress -ceq $peerIp -and [int]$_.PrefixLength -eq 24})
    if($matched.Count -ne 1){return $false}
    $ifIndex=[int]$matched[0].InterfaceIndex
    $adapters=@($AdapterRecords|Where-Object{[int]$_.InterfaceIndex -eq $ifIndex -and $_.Status -ceq 'Up'})
    if($adapters.Count -ne 1){return $false}
    if(@($GatewayRecords|Where-Object{[int]$_.InterfaceIndex -eq $ifIndex -and $_.NextHop -notin @('','0.0.0.0')}).Count -ne 0){return $false}
    $direct=@($RouteRecords|Where-Object{[int]$_.InterfaceIndex -eq $ifIndex -and $_.DestinationPrefix -ceq '192.168.50.0/24' -and $_.NextHop -ceq '0.0.0.0'})
    $direct.Count -eq 1
}

function Assert-DgBPeerTopology {
    $ips=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop)
    $adapters=@(Get-NetAdapter -ErrorAction Stop)
    $routes=@(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop)
    $gateways=@(Get-NetIPConfiguration -ErrorAction Stop|ForEach-Object{foreach($g in @($_.IPv4DefaultGateway)){if($null-ne $g){[pscustomobject]@{InterfaceIndex=$_.InterfaceIndex;NextHop=[string]$g.NextHop}}}})
    if(!(Test-DgBPeerTopologyRecords $ips $adapters $routes $gateways)){throw 'BLOCKED_DG_B_PEER_TOPOLOGY'}
}

function Test-DgBControlPlaneTrace([string[]]$Events) {
    $serialReady=[Array]::IndexOf($Events,'SERIAL_CAPTURE_READY')
    $arm=[Array]::IndexOf($Events,'ARM_REQUESTED')
    $serialFailed=[Array]::IndexOf($Events,'SERIAL_CAPTURE_OPEN_FAILED')
    if($arm -ge 0 -and ($serialReady -lt 0 -or $serialReady -gt $arm)){return $false}
    if($serialFailed -ge 0 -and $arm -ge 0){return $false}
    $true
}

function Test-DgBTerminalMarkerChunks([string[]]$Chunks) {
    $builder=[Text.StringBuilder]::new()
    foreach($chunk in $Chunks){[void]$builder.Append($chunk);if($builder.ToString().Contains('SCOPE_MARKER trial=C1 event=TRIAL_COMPLETE')){return $true}}
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

function Get-DgBRawProvisionalPrimary([string]$SerialText) {
    if ($SerialText -match 'USB_DETACH') { return 'DG_B_USB_HID_FAIL' }
    if ($SerialText -match '(?m)REASON=USB_DETACH_OR_UNSUPPORTED(?:\s|$)') { return 'DG_B_USB_HID_FAIL' }
    if ($SerialText -match '(?m)REASON=HID_STALL(?:\s|$)') { return 'DG_B_USB_HID_FAIL' }
    'NONE'
}

function Test-DgBSerialLog([string]$Text) {
    try {
        $provisional = Get-DgBRawProvisionalPrimary $Text
        $lines = @($Text -split '\r?\n')
        $finalIndexes = @(); $terminalIndexes = @(); $scopeIndexes = @(); $setupIndexes = @()
        for ($i=0;$i -lt $lines.Count;$i++) {
            if ($lines[$i] -match '^C1_FINAL\s') { $finalIndexes += $i }
            if ($lines[$i] -match '(?:^|\s)TEST_COMPLETE=(?:PASS|FAIL)(?:\s|$)') { $terminalIndexes += $i }
            if ($lines[$i] -match '^SCOPE_MARKER trial=C1 event=TRIAL_COMPLETE result=(?:PASS|FAIL)$') { $scopeIndexes += $i }
            if ($lines[$i] -match '^C1_SETUP_FAIL=1\s') { $setupIndexes += $i }
        }
        $noEvidence = $finalIndexes.Count -eq 0 -and $terminalIndexes.Count -eq 0 -and $setupIndexes.Count -eq 0 -and $provisional -eq 'NONE'
        $runtimeReasons = @('DURATION_COMPLETE','USB_DETACH_OR_UNSUPPORTED','HID_STALL','MAX_REGISTER_MISMATCH','LINK_OR_PHY_CHANGED')
        $setupReasons = @('W5100_INIT','CHIP_ID','VERSIONR','BUFFER_MAP_INIT','PHY_PROFILE','PHY_PROFILE_READBACK','BUFFER_MAP_FIXED10','NETWORK_CONFIG','PHY_AFTER_NETWORK_CONFIG','BUFFER_MAP_NETWORK_CONFIG','LINK_PROFILE_CHANGED','LINK_TIMEOUT','UDP_BEGIN','UDP_SOCKET','PHY_AFTER_UDP_BEGIN','BUFFER_MAP_UDP_BEGIN','VERSION_AFTER_UDP_BEGIN','BUFFER_MAP_USB_INIT','USB_INIT','PHY_DURING_USB_STABILITY','HORI_READY')
        if ($setupIndexes.Count -gt 0) {
            $valid = $setupIndexes.Count -eq 1 -and $finalIndexes.Count -eq 0 -and $terminalIndexes.Count -eq 1 -and $scopeIndexes.Count -eq 1
            $setup = Convert-KeyValueLine $lines[$setupIndexes[0]]
            $terminal = Convert-KeyValueLine $lines[$terminalIndexes[0]]
            $scopePass = $lines[$scopeIndexes[0]] -ceq 'SCOPE_MARKER trial=C1 event=TRIAL_COMPLETE result=FAIL'
            $reason = if ($setup.Fields.Contains('REASON')) { $setup.Fields.REASON } else { '' }
            $valid = $valid -and !$setup.Duplicate -and !$terminal.Duplicate -and $scopePass -and $setupReasons -contains $reason
            $valid = $valid -and $terminal.Fields.TEST_COMPLETE -ceq 'FAIL' -and $terminal.Fields.TEST_MODE -ceq '15' -and $terminal.Fields.TEST_MODE_NAME -ceq 'USB_FIXED10_UDP_TX_ONLY' -and $terminal.Fields.REASON -ceq $reason
            return [pscustomobject]@{ EvidenceContractValid=$valid; LogicalPass=$false; Schema='SETUP_FAILURE'; Fields=$terminal.Fields; Reason=$reason; Completion='FAIL'; ProvisionalPrimary=$provisional; NoEvidence=$noEvidence; Reasons=@() }
        }
        $valid = $finalIndexes.Count -eq 1 -and $terminalIndexes.Count -eq 1 -and $scopeIndexes.Count -eq 1
        if (!$valid) { return [pscustomobject]@{ EvidenceContractValid=$false; LogicalPass=$false; Schema='INVALID'; Fields=[ordered]@{}; Reason=''; Completion=''; ProvisionalPrimary=$provisional; NoEvidence=$noEvidence; Reasons=@('line_count_or_schema') } }
        $valid = $finalIndexes[0] -lt $terminalIndexes[0] -and $terminalIndexes[0] -lt $scopeIndexes[0]
        $final = Convert-KeyValueLine $lines[$finalIndexes[0]]
        $terminal = Convert-KeyValueLine $lines[$terminalIndexes[0]]
        $valid = $valid -and !$final.Duplicate -and !$terminal.Duplicate
        $finalRequired = @('UDP_TX_TOTAL','UDP_TX_FAIL','UDP_BEGIN_COUNT','UDP_BEGIN_FAIL','UDP_BEGIN_MAX_US','UDP_BEGIN_PACKET_MAX_US','UDP_WRITE_MAX_US','UDP_END_PACKET_MAX_US','UDP_MAX_GAP_US','SCHEDULER_MISSED_DEADLINE','SCHEDULER_MAX_LATENESS_US','LOOP_MAX_US','HID_STALL_COUNT','HID_MAX_NO_REPORT_MS')
        $terminalDecimal = @('DURATION_MS','TRIAL_RUNTIME_MS','FINAL_HID_READY','HID_READY_DROP','HID_STALL_COUNT','HID_MAX_NO_REPORT_MS','HID_REPORT_TOTAL','FINAL_PHY_OK','FINAL_VERSION_OK','FINAL_BUFFER_MAP_OK','MAX_REGISTER_TRIPLE_READ_MISMATCH','SPI_CORRUPTION_SUSPECTED')
        $values = [ordered]@{}
        foreach ($key in $finalRequired) { $value=Test-Decimal $final.Fields $key; if ($null -eq $value) {$valid=$false} else {$values[$key]=$value} }
        foreach ($key in $terminalDecimal) { $value=Test-Decimal $terminal.Fields $key; if ($null -eq $value) {$valid=$false} else {$values["TERMINAL_$key"]=$value} }
        $usbState=Test-HexByte $terminal.Fields 'FINAL_USB_STATE'; $version=Test-HexByte $terminal.Fields 'VERSIONR'
        if ($null -eq $usbState -or $null -eq $version) {$valid=$false} else {$values.FINAL_USB_STATE=$usbState;$values.VERSIONR=$version}
        foreach ($key in @('TEST_COMPLETE','TEST_MODE','TEST_MODE_NAME','REASON','VID','PID','SCOPE_RESULT')) { if (!$terminal.Fields.Contains($key)) {$valid=$false} }
        $reason = if ($terminal.Fields.Contains('REASON')) {$terminal.Fields.REASON} else {''}
        $completion = if ($terminal.Fields.Contains('TEST_COMPLETE')) {$terminal.Fields.TEST_COMPLETE} else {''}
        $scopeExpected = "SCOPE_MARKER trial=C1 event=TRIAL_COMPLETE result=$completion"
        $valid = $valid -and $runtimeReasons -contains $reason -and $lines[$scopeIndexes[0]] -ceq $scopeExpected
        $valid = $valid -and $terminal.Fields.TEST_MODE -ceq '15' -and $terminal.Fields.TEST_MODE_NAME -ceq 'USB_FIXED10_UDP_TX_ONLY'
        $valid = $valid -and $terminal.Fields.VID -ceq '0F0D' -and $terminal.Fields.PID -ceq '0202' -and $terminal.Fields.SCOPE_RESULT -ceq 'NOT_CAPTURED'
        if($Text -match '(?m)(?:^|\s)RESET_REASON=(?:PANIC|WDT|BROWNOUT)(?:\s|$)'){$valid=$false}
        foreach($overlap in @('HID_STALL_COUNT','HID_MAX_NO_REPORT_MS')){
            $terminalKey="TERMINAL_$overlap"
            if(!$values.Contains($overlap) -or !$values.Contains($terminalKey) -or $values[$overlap] -ne $values[$terminalKey]){$valid=$false}
        }
        $logical = $valid -and $completion -ceq 'PASS' -and $reason -ceq 'DURATION_COMPLETE' -and
            $values.UDP_TX_TOTAL -gt 0 -and $values.UDP_TX_FAIL -eq 0 -and $values.UDP_BEGIN_COUNT -eq 1 -and $values.UDP_BEGIN_FAIL -eq 0 -and
            $values.SCHEDULER_MISSED_DEADLINE -eq 0 -and $values.TERMINAL_DURATION_MS -gt 0 -and $values.TERMINAL_TRIAL_RUNTIME_MS -gt 0 -and $values.TERMINAL_HID_REPORT_TOTAL -gt 0 -and
            $values.HID_STALL_COUNT -eq 0 -and $values.FINAL_USB_STATE -eq 0x90 -and $values.TERMINAL_FINAL_HID_READY -eq 1 -and
            $values.TERMINAL_HID_READY_DROP -eq 0 -and $values.TERMINAL_FINAL_PHY_OK -eq 1 -and $values.TERMINAL_FINAL_VERSION_OK -eq 1 -and
            $values.TERMINAL_FINAL_BUFFER_MAP_OK -eq 1 -and $values.VERSIONR -eq 0x04 -and
            $values.TERMINAL_MAX_REGISTER_TRIPLE_READ_MISMATCH -eq 0 -and $values.TERMINAL_SPI_CORRUPTION_SUSPECTED -eq 0
        [pscustomobject]@{ EvidenceContractValid=$valid; LogicalPass=$logical; Schema='RUNTIME'; Fields=$values; Reason=$reason; Completion=$completion; ProvisionalPrimary=$provisional; NoEvidence=$noEvidence; Reasons=@() }
    } catch {
        [pscustomobject]@{ EvidenceContractValid=$false; LogicalPass=$false; Schema='INVALID'; Fields=[ordered]@{}; Reason=''; Completion=''; ProvisionalPrimary=(Get-DgBRawProvisionalPrimary $Text); NoEvidence=$false; Reasons=@("parser_exception:$($_.Exception.Message)") }
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

function Test-DgBPeerSummary([string]$Text,[int]$ExitCode=0) {
    try {
        $parsed=Convert-SummaryMap $Text; $m=$parsed.Map; $valid=!$parsed.Duplicate; $consistent=$true
        $requiredStrings=@('PEER_COMPLETE','PEER_ARMED','ADMISSION_SEQUENCE_ZERO_OK','BLOCKED_ADMISSION_SEQUENCE_MISS','FIRST_SEQUENCE','LAST_SEQUENCE','INGRESS_FIRST_SEQUENCE','INGRESS_LAST_SEQUENCE','PEER_BOUND_IP','PEER_BOUND_PORT','INGRESS_SOURCE_IP','INGRESS_SOURCE_PORT','INGRESS_DEST_IP','INGRESS_DEST_PORT','PEER_SOCKET_ERROR_PHASE','PEER_SOCKET_ERROR_SEQUENCE','PEER_SOCKET_ERROR_ERRNO','PEER_SOCKET_ERROR_WINERROR','PEER_SOCKET_ERROR_MESSAGE','TIMING_EVIDENCE_VALID','INGRESS_RX_TO_SEND_MAX_US','INGRESS_RX_TO_SEND_P99_US','INGRESS_SEND_CALL_MAX_US','PEER_FATAL_REASON','PEER_RESULT')
        $numeric=@('VALID_DEVICE_TX_RX_TOTAL','CRC_ERROR','LENGTH_ERROR','FORMAT_ERROR','PAYLOAD_ERROR','FLAGS_ERROR','UNEXPECTED_SOURCE','SOURCE_PORT_ERROR','SEQ_GAP','DUPLICATE','OUT_OF_ORDER','INGRESS_TX_ATTEMPT_TOTAL','INGRESS_TX_SUCCESS_TOTAL','INGRESS_TX_FAIL_TOTAL','PEER_SOCKET_ERROR_TOTAL')
        foreach($key in $requiredStrings){if(!$m.Contains($key)){$valid=$false}}
        $v=[ordered]@{}
        foreach($key in $numeric){$n=Test-Decimal $m $key;if($null -eq $n){$valid=$false}else{$v[$key]=$n}}
        foreach($key in @('PEER_COMPLETE','PEER_ARMED','ADMISSION_SEQUENCE_ZERO_OK','BLOCKED_ADMISSION_SEQUENCE_MISS','TIMING_EVIDENCE_VALID')){if(!$m.Contains($key) -or $m[$key] -notin @('0','1')){$valid=$false}}
        $seq=[ordered]@{}
        foreach($key in @('FIRST_SEQUENCE','LAST_SEQUENCE','INGRESS_FIRST_SEQUENCE','INGRESS_LAST_SEQUENCE')){$item=Test-UInt32OrNone $m $key;if($null-eq $item -or !$item.Valid){$valid=$false}else{$seq[$key]=$item}}
        if($m.Contains('PEER_RESULT') -and $m.PEER_RESULT -notin @('PASS','FAIL','BLOCKED')){$valid=$false}
        $fatalVocabulary=@('NONE','BLOCKED_DG_B_PEER_UDP_ASYNC_ERROR','BLOCKED_ADMISSION_SEQUENCE_MISS','BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID','DG_B_PEER_INGRESS_SEND_FAIL')
        if($m.Contains('PEER_FATAL_REASON') -and $m.PEER_FATAL_REASON -notin $fatalVocabulary){$valid=$false}
        $phaseVocabulary=@('NONE','BIND','GETSOCKNAME','RECVFROM','SENDTO')
        if($m.Contains('PEER_SOCKET_ERROR_PHASE') -and $m.PEER_SOCKET_ERROR_PHASE -notin $phaseVocabulary){$valid=$false}
        $timing=[ordered]@{}
        foreach($key in @('INGRESS_RX_TO_SEND_MAX_US','INGRESS_RX_TO_SEND_P99_US','INGRESS_SEND_CALL_MAX_US')){$number=Test-FiniteNonnegative $m $key;if($null-eq $number){$valid=$false}else{$timing[$key]=$number}}
        if($valid -and $timing.INGRESS_RX_TO_SEND_MAX_US -lt $timing.INGRESS_RX_TO_SEND_P99_US){$valid=$false}
        try{if($m.Contains('PEER_SOCKET_ERROR_MESSAGE')){$message=$m.PEER_SOCKET_ERROR_MESSAGE|ConvertFrom-Json -ErrorAction Stop;if($message -isnot [string]){$valid=$false}}}catch{$valid=$false}
        if($valid){
            $valid=$m.PEER_BOUND_IP -ceq $peerIp -and $m.PEER_BOUND_PORT -ceq '50001' -and $m.INGRESS_SOURCE_IP -ceq $peerIp -and $m.INGRESS_SOURCE_PORT -ceq '50001' -and $m.INGRESS_DEST_IP -ceq $senderIp -and $m.INGRESS_DEST_PORT -ceq '50002'
        }
        if($valid){
            if($v.PEER_SOCKET_ERROR_TOTAL -eq 0){
                if($m.PEER_SOCKET_ERROR_PHASE -cne 'NONE' -or $m.PEER_SOCKET_ERROR_SEQUENCE -cne 'NA' -or $m.PEER_SOCKET_ERROR_ERRNO -cne 'NA' -or $m.PEER_SOCKET_ERROR_WINERROR -cne 'NA'){$valid=$false}
                if($m.PEER_RESULT -ceq 'PASS' -and $m.PEER_FATAL_REASON -cne 'NONE'){$valid=$false}
            }else{
                if($m.PEER_SOCKET_ERROR_PHASE -ceq 'NONE' -or $m.PEER_FATAL_REASON -cne 'BLOCKED_DG_B_PEER_UDP_ASYNC_ERROR' -or $m.PEER_RESULT -cne 'BLOCKED'){$valid=$false}
                $errorSeq=Test-UInt32OrNone $m 'PEER_SOCKET_ERROR_SEQUENCE' -AllowNa
                if($null-eq $errorSeq -or !$errorSeq.Valid){$valid=$false}
                foreach($key in @('PEER_SOCKET_ERROR_ERRNO','PEER_SOCKET_ERROR_WINERROR')){if($m[$key] -cne 'NA' -and $m[$key] -notmatch '^-?\d+$'){$valid=$false}}
                if($m.PEER_SOCKET_ERROR_PHASE -ceq 'SENDTO' -and (!$errorSeq.IsNumber)){$valid=$false}
            }
            if($m.PEER_FATAL_REASON -ceq 'BLOCKED_DG_B_PEER_UDP_ASYNC_ERROR' -and $v.PEER_SOCKET_ERROR_TOTAL -eq 0){$valid=$false}
            if($m.PEER_FATAL_REASON -ceq 'DG_B_PEER_INGRESS_SEND_FAIL' -and ($m.PEER_RESULT -cne 'FAIL' -or $v.INGRESS_TX_FAIL_TOTAL -eq 0)){$valid=$false}
            if($m.PEER_FATAL_REASON -ceq 'BLOCKED_ADMISSION_SEQUENCE_MISS' -and ($m.PEER_RESULT -cne 'BLOCKED' -or $m.BLOCKED_ADMISSION_SEQUENCE_MISS -cne '1')){$valid=$false}
            if($m.PEER_FATAL_REASON -ceq 'BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID' -and $m.PEER_RESULT -cne 'BLOCKED'){$valid=$false}
        }
        $errorsZero=$valid
        foreach($key in @('CRC_ERROR','LENGTH_ERROR','FORMAT_ERROR','PAYLOAD_ERROR','FLAGS_ERROR','UNEXPECTED_SOURCE','SOURCE_PORT_ERROR','SEQ_GAP','DUPLICATE','OUT_OF_ORDER')){if($valid -and $v[$key] -ne 0){$errorsZero=$false}}
        if($valid -and $m.PEER_COMPLETE -ceq '1' -and $m.PEER_RESULT -ceq 'PASS'){
            $count=$v.VALID_DEVICE_TX_RX_TOTAL
            if($count -eq 0 -or $count -gt [uint64]4294967296 -or !$seq.FIRST_SEQUENCE.IsNumber -or !$seq.INGRESS_FIRST_SEQUENCE.IsNumber -or !$seq.LAST_SEQUENCE.IsNumber -or !$seq.INGRESS_LAST_SEQUENCE.IsNumber){$consistent=$false}
            elseif($seq.FIRST_SEQUENCE.Value -ne 0 -or $seq.INGRESS_FIRST_SEQUENCE.Value -ne 0 -or $seq.LAST_SEQUENCE.Value -ne ($count-1) -or $seq.INGRESS_LAST_SEQUENCE.Value -ne ($count-1)){$consistent=$false}
        }
        $logical=$valid -and $consistent -and $ExitCode -eq 0 -and $m.PEER_COMPLETE -ceq '1' -and $m.PEER_ARMED -ceq '1' -and $m.ADMISSION_SEQUENCE_ZERO_OK -ceq '1' -and $m.BLOCKED_ADMISSION_SEQUENCE_MISS -ceq '0' -and $v.VALID_DEVICE_TX_RX_TOTAL -gt 0 -and $errorsZero -and $v.INGRESS_TX_ATTEMPT_TOTAL -gt 0 -and $v.INGRESS_TX_SUCCESS_TOTAL -gt 0 -and $v.INGRESS_TX_ATTEMPT_TOTAL -eq $v.INGRESS_TX_SUCCESS_TOTAL -and $v.INGRESS_TX_FAIL_TOTAL -eq 0 -and $v.PEER_SOCKET_ERROR_TOTAL -eq 0 -and $m.TIMING_EVIDENCE_VALID -ceq '1' -and $m.PEER_FATAL_REASON -ceq 'NONE' -and $m.PEER_RESULT -ceq 'PASS'
        [pscustomobject]@{ EvidenceContractValid=$valid; StreamConsistent=$consistent; LogicalPass=$logical; Fields=$v; Strings=$m; Sequences=$seq; Timing=$timing; AsyncError=($valid -and $v.PEER_SOCKET_ERROR_TOTAL -gt 0); SendFail=($valid -and $v.INGRESS_TX_FAIL_TOTAL -gt 0); AdmissionBlocked=($valid -and $m.BLOCKED_ADMISSION_SEQUENCE_MISS -ceq '1') }
    } catch {
        [pscustomobject]@{ EvidenceContractValid=$false; StreamConsistent=$false; LogicalPass=$false; Fields=[ordered]@{}; Strings=[ordered]@{}; Sequences=[ordered]@{}; Timing=[ordered]@{}; AsyncError=$false; SendFail=$false; AdmissionBlocked=$false }
    }
}

function Test-DgBReconciliation([pscustomobject]$Serial,[pscustomobject]$Peer) {
    if(!$Serial.EvidenceContractValid -or !$Peer.EvidenceContractValid -or !$Serial.Fields.Contains('UDP_TX_TOTAL')){return [pscustomobject]@{EvidenceValid=$false;Pass=$false}}
    $d=[uint64]$Serial.Fields.UDP_TX_TOTAL; $p=[uint64]$Peer.Fields.VALID_DEVICE_TX_RX_TOTAL; $a=[uint64]$Peer.Fields.INGRESS_TX_ATTEMPT_TOTAL; $s=[uint64]$Peer.Fields.INGRESS_TX_SUCCESS_TOTAL
    [pscustomobject]@{EvidenceValid=$true;Pass=($d -eq $p -and $p -eq $a -and $a -eq $s);Device=$d;Peer=$p;Attempt=$a;Success=$s}
}

function Get-DgBStimulusEstablished([pscustomobject]$Serial,[pscustomobject]$Peer) {
    if($null-ne $Serial -and $Serial.EvidenceContractValid -and $Serial.Schema -ceq 'SETUP_FAILURE'){return '0'}
    if($null-eq $Peer -or !$Peer.EvidenceContractValid -or !$Peer.Fields.Contains('INGRESS_TX_SUCCESS_TOTAL')){return 'UNKNOWN'}
    if([uint64]$Peer.Fields.INGRESS_TX_SUCCESS_TOTAL -gt 0){return '1'}
    '0'
}

function Get-DgBClassification([pscustomobject]$Serial,[pscustomobject]$Peer,[pscustomobject]$Reconciliation,[string]$Secondary='') {
    $primary=$null
    if($null -ne $Serial -and $Serial.ProvisionalPrimary -ceq 'DG_B_USB_HID_FAIL'){$primary='DG_B_USB_HID_FAIL'}
    elseif($null -ne $Serial -and $Serial.EvidenceContractValid -and $Serial.Schema -ceq 'SETUP_FAILURE'){
        $primary='BLOCKED_DG_B_DEVICE_PRETRIAL_FAILURE'
    } elseif($null -ne $Serial -and $Serial.EvidenceContractValid -and $Serial.Reason -eq 'LINK_OR_PHY_CHANGED'){$primary='DG_B_PHY_HEALTH_FAIL'}
    elseif($null -ne $Serial -and $Serial.EvidenceContractValid -and $Serial.Reason -eq 'MAX_REGISTER_MISMATCH'){$primary='DG_B_MAX_SPI_CANARY_FAIL'}
    elseif($null -ne $Serial -and $Serial.EvidenceContractValid -and $Serial.Fields.SCHEDULER_MISSED_DEADLINE -gt 0){$primary='DG_B_TIMING_FAIL'}
    elseif($null -ne $Serial -and $Serial.EvidenceContractValid -and ($Serial.Fields.TERMINAL_FINAL_PHY_OK -ne 1 -or $Serial.Fields.TERMINAL_FINAL_VERSION_OK -ne 1 -or $Serial.Fields.TERMINAL_FINAL_BUFFER_MAP_OK -ne 1 -or $Serial.Fields.VERSIONR -ne 4)){$primary='DG_B_PHY_HEALTH_FAIL'}
    elseif($null -ne $Serial -and $Serial.EvidenceContractValid -and ($Serial.Fields.TERMINAL_MAX_REGISTER_TRIPLE_READ_MISMATCH -gt 0 -or $Serial.Fields.TERMINAL_SPI_CORRUPTION_SUSPECTED -ne 0)){$primary='DG_B_MAX_SPI_CANARY_FAIL'}
    elseif($null -ne $Serial -and $Serial.EvidenceContractValid -and ($Serial.Fields.FINAL_USB_STATE -ne 0x90 -or $Serial.Fields.TERMINAL_FINAL_HID_READY -ne 1 -or $Serial.Fields.TERMINAL_HID_READY_DROP -ne 0 -or $Serial.Fields.HID_STALL_COUNT -ne 0)){$primary='DG_B_USB_HID_FAIL'}
    elseif($null -ne $Serial -and $Serial.EvidenceContractValid -and ($Serial.Fields.UDP_TX_TOTAL -eq 0 -or $Serial.Fields.UDP_TX_FAIL -ne 0)){$primary='DG_B_DEVICE_TX_FAIL'}
    elseif($null -ne $Peer -and $Peer.AsyncError){$primary='BLOCKED_DG_B_PEER_UDP_ASYNC_ERROR'}
    elseif($null -ne $Peer -and $Peer.AdmissionBlocked){$primary='BLOCKED_ADMISSION_SEQUENCE_MISS'}
    elseif($null -ne $Peer -and $Peer.SendFail){$primary='DG_B_PEER_INGRESS_SEND_FAIL'}
    elseif($null -eq $Serial -or $Serial.NoEvidence){$primary='ORCHESTRATION_STALL/TIMEOUT'}
    elseif(!$Serial.EvidenceContractValid){$primary='BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID'}
    elseif($null -eq $Peer){$primary='BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID'}
    elseif(!$Peer.EvidenceContractValid){$primary='BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID'}
    elseif(!$Peer.LogicalPass){$primary='BLOCKED_DG_B_STIMULUS_NOT_ESTABLISHED'}
    elseif($null -eq $Reconciliation -or !$Reconciliation.EvidenceValid -or !$Reconciliation.Pass){$primary='BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID'}
    elseif($Serial.LogicalPass -and $Peer.LogicalPass){$primary='DG_B_PASS'}
    else{$primary='BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID'}

    $stimulus=Get-DgBStimulusEstablished $Serial $Peer
    $devicePretrialReason=if($null-ne $Serial -and $Serial.EvidenceContractValid -and $Serial.Schema -ceq 'SETUP_FAILURE'){$Serial.Reason}else{''}
    $secondaryConditions=[Collections.Generic.List[string]]::new()
    if($null-ne $Peer){
        $peerSecondary=if(!$Peer.EvidenceContractValid){'BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID'}elseif($Peer.AsyncError){'BLOCKED_DG_B_PEER_UDP_ASYNC_ERROR'}elseif($Peer.AdmissionBlocked){'BLOCKED_ADMISSION_SEQUENCE_MISS'}elseif($Peer.SendFail){'DG_B_PEER_INGRESS_SEND_FAIL'}else{''}
        if($peerSecondary -and $peerSecondary -cne $primary){$secondaryConditions.Add($peerSecondary)}
    }elseif($primary -in @('DG_B_USB_HID_FAIL','DG_B_DEVICE_TX_FAIL','DG_B_TIMING_FAIL','DG_B_PHY_HEALTH_FAIL','DG_B_MAX_SPI_CANARY_FAIL')){
        $secondaryConditions.Add('BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID')
    }
    if($Secondary -and !$secondaryConditions.Contains($Secondary)){$secondaryConditions.Add($Secondary)}

    $trialResult='BLOCKED';$trialBlockReason=''
    $treatmentEffectFailures=@('DG_B_USB_HID_FAIL','DG_B_DEVICE_TX_FAIL','DG_B_TIMING_FAIL','DG_B_PHY_HEALTH_FAIL','DG_B_MAX_SPI_CANARY_FAIL')
    if($primary -ceq 'BLOCKED_DG_B_DEVICE_PRETRIAL_FAILURE'){
        $trialBlockReason='BLOCKED_DG_B_DEVICE_PRETRIAL_FAILURE'
    }elseif($primary -ceq 'DG_B_PASS'){
        if($stimulus -ceq '1'){$trialResult='PASS'}else{$trialBlockReason=if($stimulus -ceq '0'){'BLOCKED_DG_B_STIMULUS_NOT_ESTABLISHED'}else{'BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID'}}
    }elseif($primary -in $treatmentEffectFailures){
        if($stimulus -ceq '1'){$trialResult='FAIL'}else{$trialBlockReason=if($stimulus -ceq '0'){'BLOCKED_DG_B_STIMULUS_NOT_ESTABLISHED'}else{'BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID'}}
    }else{
        $trialBlockReason=if($primary){$primary}elseif($stimulus -ceq '0'){'BLOCKED_DG_B_STIMULUS_NOT_ESTABLISHED'}else{'BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID'}
    }
    [pscustomobject]@{
        Primary=$primary
        Secondary=if($secondaryConditions.Count){$secondaryConditions[0]}else{''}
        SecondaryConditions=@($secondaryConditions)
        StimulusEstablished=$stimulus
        TrialResult=$trialResult
        TrialBlockReason=$trialBlockReason
        DevicePretrialReason=$devicePretrialReason
    }
}

function Get-DgBFailureToken([string]$Message) {
    $match=[regex]::Match($Message,'(?:BLOCKED_[A-Z0-9_]+|DG_B_[A-Z0-9_]+|ORCHESTRATION_STALL/TIMEOUT)')
    if($match.Success){$match.Value}else{'BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID'}
}

function Get-DgBAdjudicationLines([pscustomobject]$Adjudication) {
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add("DG_B_CLASSIFICATION_PRIMARY=$($Adjudication.Primary)")
    if($Adjudication.Secondary){$lines.Add("DG_B_CLASSIFICATION_SECONDARY=$($Adjudication.Secondary)")}
    $lines.Add("DG_B_STIMULUS_ESTABLISHED=$($Adjudication.StimulusEstablished)")
    $lines.Add("DG_B_TRIAL_RESULT=$($Adjudication.TrialResult)")
    if($Adjudication.TrialResult -ceq 'BLOCKED'){$lines.Add("DG_B_TRIAL_BLOCK_REASON=$($Adjudication.TrialBlockReason)")}
    if($Adjudication.DevicePretrialReason){$lines.Add("DG_B_DEVICE_PRETRIAL_REASON=$($Adjudication.DevicePretrialReason)")}
    [string[]]$lines.ToArray()
}

function Write-DgBAdjudicationFile([string]$TrialRoot,[string[]]$Lines) {
    if(!(Test-Path -LiteralPath $TrialRoot -PathType Container)){throw 'BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID trial_root_missing_for_adjudication'}
    $path=Join-Path $TrialRoot 'runner-adjudication.txt'
    $text=if($Lines.Count){($Lines -join "`n")+"`n"}else{''}
    [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false))
    $path
}

function Write-DgBAdjudicationOutput([pscustomobject]$Adjudication,[string]$TrialRoot='') {
    $lines=@(Get-DgBAdjudicationLines $Adjudication)
    if(![string]::IsNullOrWhiteSpace($TrialRoot)){[void](Write-DgBAdjudicationFile $TrialRoot $lines)}
    $lines|Write-Output
}

function New-PeerFixture([uint64]$Count=499,[string]$Result='PASS',[uint64]$SocketErrors=0,[uint64]$SendFail=0,[uint64]$AdmissionBlocked=0,[object]$SuccessOverride=$null) {
    $success=if($null-ne $SuccessOverride){[uint64]$SuccessOverride}elseif($SendFail -gt 0){$Count-1}else{$Count}
    $fatal=if($SocketErrors -gt 0){'BLOCKED_DG_B_PEER_UDP_ASYNC_ERROR'}elseif($AdmissionBlocked -gt 0){'BLOCKED_ADMISSION_SEQUENCE_MISS'}elseif($SendFail -gt 0){'DG_B_PEER_INGRESS_SEND_FAIL'}else{'NONE'}
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
INGRESS_DEST_PORT=50002
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
PEER_FATAL_REASON=$fatal
PEER_RESULT=$Result
"@
}

function New-SetupFailureFixture([string]$Reason) {
    @"
C1_SETUP_FAIL=1 REASON=$Reason
TEST_COMPLETE=FAIL TEST_MODE=15 TEST_MODE_NAME=USB_FIXED10_UDP_TX_ONLY REASON=$Reason
SCOPE_MARKER trial=C1 event=TRIAL_COMPLETE result=FAIL
"@
}

function Set-FirstByte([string]$Path) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{$value=$stream.ReadByte();[void]$stream.Seek(0,[IO.SeekOrigin]::Begin);$stream.WriteByte(($value -bxor 1))}finally{$stream.Dispose()}
}

function Invoke-RunnerOfflineSelfTests {
    $records=[Collections.Generic.List[object]]::new()
    function Record([string]$Name,[bool]$Pass,[string]$Detail=''){$records.Add([pscustomobject]@{Name=$Name;Pass=$Pass;Detail=$Detail})}
    function Expect-Throw([scriptblock]$Body,[string]$Pattern){try{&$Body|Out-Null;return $false}catch{return $_.Exception.Message -like "*$Pattern*"}}
    $testRoot=Join-Path $validationRoot ("offline-{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'),([guid]::NewGuid().ToString('N').Substring(0,8)))
    New-Item -ItemType Directory -Force -Path $testRoot|Out-Null
    try{Assert-DonorAuthority|Out-Null;Record 'donor_authority_exact' $true}catch{Record 'donor_authority_exact' $false $_.Exception.Message}
    try{Assert-StageAuthority S1|Out-Null;Record 'exact_s1_artifact_identity' $true}catch{Record 'exact_s1_artifact_identity' $false $_.Exception.Message}
    try{Assert-StageAuthority T1|Out-Null;Record 'exact_t1_artifact_identity' $true}catch{Record 'exact_t1_artifact_identity' $false $_.Exception.Message}
    $s1=Get-StageAuthority S1;$t1=Get-StageAuthority T1
    Record 's1_t1_swap_blocked' (Expect-Throw {Assert-FileIdentity $t1.Application $s1.ApplicationSize $s1.ApplicationSha256 'BLOCKED' } 'BLOCKED')
    foreach($case in @(
        @{Name='wrong_application_hash_blocked';Source=$s1.Application;Size=$s1.ApplicationSize;Hash=$s1.ApplicationSha256},
        @{Name='wrong_bootloader_blocked';Source=$s1.Bootloader;Size=$s1.BootloaderSize;Hash=$s1.BootloaderSha256},
        @{Name='wrong_partitions_blocked';Source=$s1.Partitions;Size=$s1.PartitionsSize;Hash=$s1.PartitionsSha256},
        @{Name='wrong_boot_app0_blocked';Source=$s1.BootApp0;Size=$s1.BootApp0Size;Hash=$s1.BootApp0Sha256}
    )){$copy=Join-Path $testRoot ([IO.Path]::GetFileName($case.Source)+[guid]::NewGuid().ToString('N'));Copy-Item -LiteralPath $case.Source -Destination $copy;Set-FirstByte $copy;Record $case.Name (Expect-Throw {Assert-FileIdentity $copy $case.Size $case.Hash 'BLOCKED'} 'BLOCKED')}
    $mergedCopy=Join-Path $testRoot 'bad-merged.bin';Copy-Item -LiteralPath $s1.Merged -Destination $mergedCopy
    $stream=[IO.File]::Open($mergedCopy,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);try{[void]$stream.Seek(0xE000,[IO.SeekOrigin]::Begin);$v=$stream.ReadByte();[void]$stream.Seek(0xE000,[IO.SeekOrigin]::Begin);$stream.WriteByte(($v -bxor 1))}finally{$stream.Dispose()}
    Record 'boot_app0_merged_slice_mismatch_blocked' ((Get-MergedSliceSha256 $mergedCopy) -cne $s1.BootApp0Sha256)
    $staged=New-DgBArtifactStaging S1 $testRoot
    Record 'staging_source_copy_exact_pass' ((Get-Sha256 $staged.Files.Application) -ceq $s1.ApplicationSha256)
    Set-FirstByte $staged.Files.Application
    Record 'staging_corruption_blocked' (Expect-Throw {Assert-FileIdentity $staged.Files.Application $s1.ApplicationSize $s1.ApplicationSha256 'BLOCKED'} 'BLOCKED')
    $planStage=New-DgBArtifactStaging S1 $testRoot;$plan=Get-DgBUploadPlan $planStage
    Record 'upload_plan_no_compile' ($plan.Command -notmatch '(?i)arduino-cli(?:\.exe)?\s+compile\b')
    Record 'upload_plan_no_build' ($plan.Command -notmatch '(?i)arduino-cli(?:\.exe)?\s+build\b')
    Record 'upload_plan_four_offsets' ((@($plan.Segments.Offset) -join ',') -ceq '0x0000,0x8000,0xE000,0x10000')
    $bootPlan=@($plan.Segments|Where-Object Role -eq 'boot_app0')[0]
    Record 'upload_plan_boot_app0_actual_platform_input' ($bootPlan.Path -ceq $s1.BootApp0)
    Record 'upload_plan_boot_app0_staged_evidence_distinct' ($bootPlan.StagedEvidencePath -ceq $planStage.Files.BootApp0)
    try{$toolchain=Get-DgBToolchainAuthority;Record 'toolchain_exact_identity' $true}catch{Record 'toolchain_exact_identity' $false $_.Exception.Message;$toolchain=$null}
    Record 'wrong_cli_version_blocked' (Expect-Throw {Get-DgBToolchainAuthority -CliVersionOverride '0.0.0'|Out-Null} 'BLOCKED_DG_B_UPLOAD_TOOLCHAIN_IDENTITY_MISMATCH')
    Record 'wrong_core_version_blocked' (Expect-Throw {Get-DgBToolchainAuthority -CoreVersionOverride '0.0.0'|Out-Null} 'BLOCKED_DG_B_UPLOAD_TOOLCHAIN_IDENTITY_MISMATCH')
    $pre=@();$post=@()
    if($null-ne $toolchain){
        $pre=Get-DgBArtifactIdentityRows $planStage $toolchain PRE_UPLOAD
        Record 'pre_upload_artifact_manifest_valid' (&{try{Assert-DgBArtifactIdentityRows $pre $planStage|Out-Null;$true}catch{$false}})
        $post=Get-DgBArtifactIdentityRows $planStage $toolchain POST_UPLOAD
        Record 'post_upload_same_identity_pass' (&{try{Assert-DgBArtifactIdentityRows $post $planStage|Out-Null;Compare-DgBArtifactIdentityRows $pre $post|Out-Null;$true}catch{$false}})
        $appDrift=@($post|ForEach-Object{$_|Select-Object *});@($appDrift|Where-Object Role -ceq 'application')[0].Sha256='00'
        Record 'post_upload_application_drift_blocked' (Expect-Throw {Compare-DgBArtifactIdentityRows $pre $appDrift|Out-Null} 'BLOCKED_DG_B_UPLOAD_ARTIFACT_IDENTITY_DRIFT')
        $bootDrift=@($post|ForEach-Object{$_|Select-Object *});@($bootDrift|Where-Object Role -ceq 'boot_app0_actual_upload_input')[0].Sha256='00'
        Record 'post_upload_platform_boot_app0_drift_blocked' (Expect-Throw {Compare-DgBArtifactIdentityRows $pre $bootDrift|Out-Null} 'BLOCKED_DG_B_UPLOAD_ARTIFACT_IDENTITY_DRIFT')
    }else{foreach($name in @('pre_upload_artifact_manifest_valid','post_upload_same_identity_pass','post_upload_application_drift_blocked','post_upload_platform_boot_app0_drift_blocked')){Record $name $false 'toolchain unavailable'}}
    Record 'accepted_upload_four_segment_evidence' (Test-DgBUploadEvidence (Join-Path $freezeRoot 'accepted\C1-S1-20260817-235834-96783058\upload.stdout.log') $s1)
    $s1Serial=Get-Content -LiteralPath (Join-Path $freezeRoot 'accepted\C1-S1-20260817-235834-96783058\serial.log') -Raw
    $t1Serial=Get-Content -LiteralPath (Join-Path $freezeRoot 'accepted\C1-T1-20260818-001549-6d8af092\serial.log') -Raw
    $s1Parsed=Test-DgBSerialLog $s1Serial;$t1Parsed=Test-DgBSerialLog $t1Serial
    Record 'accepted_s1_serial_parses' ($s1Parsed.EvidenceContractValid -and $s1Parsed.LogicalPass -and $s1Parsed.Fields.UDP_TX_TOTAL -eq 499)
    Record 'accepted_t1_serial_parses' ($t1Parsed.EvidenceContractValid -and $t1Parsed.LogicalPass -and $t1Parsed.Fields.UDP_TX_TOTAL -eq 3000)
    $noFinal=($s1Serial -split '\r?\n'|Where-Object{$_ -notmatch '^C1_FINAL\s'}) -join "`n";Record 'periodic_without_c1_final_invalid' (!(Test-DgBSerialLog $noFinal).EvidenceContractValid)
    $finalLine=@($s1Serial -split '\r?\n'|Where-Object{$_ -match '^C1_FINAL\s'})[0];Record 'duplicate_c1_final_invalid' (!(Test-DgBSerialLog ($s1Serial+"`n"+$finalLine)).EvidenceContractValid)
    $terminalLine=@($s1Serial -split '\r?\n'|Where-Object{$_ -match 'TEST_COMPLETE='})[0];Record 'duplicate_test_complete_invalid' (!(Test-DgBSerialLog ($s1Serial+"`n"+$terminalLine)).EvidenceContractValid)
    $malformed=$s1Serial -replace 'C1_FINAL UDP_TX_TOTAL=499','C1_FINAL UDP_TX_TOTAL=NaN';$malformedResult=Test-DgBSerialLog $malformed;Record 'malformed_numeric_nonthrowing_invalid' (!$malformedResult.EvidenceContractValid)
    $hidOverlap=$s1Serial -replace '(C1_FINAL[^\r\n]*HID_MAX_NO_REPORT_MS=)\d+','${1}999999';Record 'duplicated_hid_max_no_report_mismatch_invalid' (!(Test-DgBSerialLog $hidOverlap).EvidenceContractValid)
    $detach=$s1Serial -replace 'TEST_COMPLETE=PASS','TEST_COMPLETE=FAIL' -replace 'REASON=DURATION_COMPLETE','REASON=USB_DETACH_OR_UNSUPPORTED' -replace 'result=PASS','result=FAIL';$detach="SCOPE_MARKER trial=C1 event=USB_DETACH`n$detach";$detachParsed=Test-DgBSerialLog $detach
    Record 'usb_detach_raw_primary' ((Get-DgBClassification $detachParsed $null $null).Primary -ceq 'DG_B_USB_HID_FAIL')
    $badPeer=Test-DgBPeerSummary 'malformed' 1;Record 'usb_detach_malformed_peer_primary_preserved' ((Get-DgBClassification $detachParsed $badPeer $null).Primary -ceq 'DG_B_USB_HID_FAIL')
    $scheduler=Test-DgBSerialLog ($s1Serial -replace 'SCHEDULER_MISSED_DEADLINE=0','SCHEDULER_MISSED_DEADLINE=1');Record 'scheduler_miss_timing_fail' ((Get-DgBClassification $scheduler $null $null).Primary -ceq 'DG_B_TIMING_FAIL')
    $phy=Test-DgBSerialLog ($s1Serial -replace 'FINAL_PHY_OK=1','FINAL_PHY_OK=0');Record 'phy_failure' ((Get-DgBClassification $phy $null $null).Primary -ceq 'DG_B_PHY_HEALTH_FAIL')
    $version=Test-DgBSerialLog ($s1Serial -replace 'VERSIONR=04','VERSIONR=03');Record 'versionr_failure' ((Get-DgBClassification $version $null $null).Primary -ceq 'DG_B_PHY_HEALTH_FAIL')
    $max=Test-DgBSerialLog ($s1Serial -replace 'MAX_REGISTER_TRIPLE_READ_MISMATCH=0','MAX_REGISTER_TRIPLE_READ_MISMATCH=1');Record 'max_mismatch_failure' ((Get-DgBClassification $max $null $null).Primary -ceq 'DG_B_MAX_SPI_CANARY_FAIL')
    $asyncPeer=Test-DgBPeerSummary (New-PeerFixture 499 'BLOCKED' 1 0 0) 3;Record 'peer_async_error_classification' ((Get-DgBClassification $s1Parsed $asyncPeer $null).Primary -ceq 'BLOCKED_DG_B_PEER_UDP_ASYNC_ERROR')
    $shortPeer=Test-DgBPeerSummary (New-PeerFixture 499 'FAIL' 0 1 0) 1;Record 'peer_short_send_classification' ((Get-DgBClassification $s1Parsed $shortPeer $null).Primary -ceq 'DG_B_PEER_INGRESS_SEND_FAIL')
    Record 'peer_missing_evidence_invalid' (!(Test-DgBPeerSummary '' 1).EvidenceContractValid)
    $peerBase=New-PeerFixture 499
    $badLast=Test-DgBPeerSummary ($peerBase -replace '(?m)^LAST_SEQUENCE=.*$','LAST_SEQUENCE=garbage');Record 'peer_last_sequence_garbage_invalid' (!$badLast.EvidenceContractValid)
    $lastOverflow=Test-DgBPeerSummary ($peerBase -replace '(?m)^LAST_SEQUENCE=.*$','LAST_SEQUENCE=4294967296');Record 'peer_last_sequence_uint32_overflow_invalid' (!$lastOverflow.EvidenceContractValid)
    $ingressLastMismatch=Test-DgBPeerSummary ($peerBase -replace '(?m)^INGRESS_LAST_SEQUENCE=.*$','INGRESS_LAST_SEQUENCE=497');Record 'peer_ingress_last_mismatch_nonpass' ($ingressLastMismatch.EvidenceContractValid -and !$ingressLastMismatch.StreamConsistent -and !$ingressLastMismatch.LogicalPass)
    Record 'peer_result_unknown_invalid' (!(Test-DgBPeerSummary ($peerBase -replace '(?m)^PEER_RESULT=.*$','PEER_RESULT=garbage')).EvidenceContractValid)
    Record 'peer_fatal_unknown_invalid' (!(Test-DgBPeerSummary ($peerBase -replace '(?m)^PEER_FATAL_REASON=.*$','PEER_FATAL_REASON=garbage')).EvidenceContractValid)
    Record 'peer_timing_nan_invalid' (!(Test-DgBPeerSummary ($peerBase -replace '(?m)^INGRESS_RX_TO_SEND_MAX_US=.*$','INGRESS_RX_TO_SEND_MAX_US=NaN')).EvidenceContractValid)
    Record 'peer_timing_infinity_invalid' (!(Test-DgBPeerSummary ($peerBase -replace '(?m)^INGRESS_SEND_CALL_MAX_US=.*$','INGRESS_SEND_CALL_MAX_US=Infinity')).EvidenceContractValid)
    Record 'peer_timing_p99_gt_max_invalid' (!(Test-DgBPeerSummary ($peerBase -replace '(?m)^INGRESS_RX_TO_SEND_P99_US=.*$','INGRESS_RX_TO_SEND_P99_US=11.000')).EvidenceContractValid)
    Record 'peer_socket_zero_non_none_phase_invalid' (!(Test-DgBPeerSummary ($peerBase -replace '(?m)^PEER_SOCKET_ERROR_PHASE=.*$','PEER_SOCKET_ERROR_PHASE=RECVFROM')).EvidenceContractValid)
    $peer499=Test-DgBPeerSummary (New-PeerFixture 499) 0;$rec499=Test-DgBReconciliation $s1Parsed $peer499
    Record 'count_499_may_pass' ((Get-DgBClassification $s1Parsed $peer499 $rec499).Primary -ceq 'DG_B_PASS')
    $peer3000=Test-DgBPeerSummary (New-PeerFixture 3000) 0;$rec3000=Test-DgBReconciliation $t1Parsed $peer3000
    Record 'count_3000_may_pass' ((Get-DgBClassification $t1Parsed $peer3000 $rec3000).Primary -ceq 'DG_B_PASS')
    $peer498=Test-DgBPeerSummary (New-PeerFixture 498) 0;$mismatch=Test-DgBReconciliation $s1Parsed $peer498
    Record 'cross_reconciliation_mismatch_nonpass' ((Get-DgBClassification $s1Parsed $peer498 $mismatch).Primary -ceq 'BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID')
    Record 'four_layers_complete_pass' ($s1Parsed.LogicalPass -and $s1Parsed.EvidenceContractValid -and $peer499.LogicalPass -and $rec499.Pass)
    Record 'missing_layer_never_pass' ((Get-DgBClassification $s1Parsed $null $null).Primary -ne 'DG_B_PASS')
    $stallSerial=Test-DgBSerialLog '';Record 'orchestration_stall_lowest' ((Get-DgBClassification $stallSerial $null $null).Primary -ceq 'ORCHESTRATION_STALL/TIMEOUT')
    Record 'orchestration_stall_does_not_overwrite_async' ((Get-DgBClassification $stallSerial $asyncPeer $null).Primary -ceq 'BLOCKED_DG_B_PEER_UDP_ASYNC_ERROR')
    $peerFive=Test-DgBPeerSummary (New-PeerFixture 5) 0
    $usbStimulus=Get-DgBClassification $detachParsed $peerFive $null
    Record 'b31_usb_detach_after_success_is_trial_fail' ($usbStimulus.Primary -ceq 'DG_B_USB_HID_FAIL' -and $usbStimulus.StimulusEstablished -ceq '1' -and $usbStimulus.TrialResult -ceq 'FAIL')
    $peerZeroShort=Test-DgBPeerSummary (New-PeerFixture 1 'FAIL' 0 1 0 0) 1
    $usbNoStimulus=Get-DgBClassification $detachParsed $peerZeroShort $null
    Record 'b31_usb_detach_zero_success_is_blocked' ($usbNoStimulus.Primary -ceq 'DG_B_USB_HID_FAIL' -and $usbNoStimulus.StimulusEstablished -ceq '0' -and $usbNoStimulus.TrialResult -ceq 'BLOCKED' -and $usbNoStimulus.TrialBlockReason -ceq 'BLOCKED_DG_B_STIMULUS_NOT_ESTABLISHED')
    $usbUnknown=Get-DgBClassification $detachParsed $null $null
    Record 'b31_usb_detach_missing_peer_is_unknown_blocked' ($usbUnknown.Primary -ceq 'DG_B_USB_HID_FAIL' -and $usbUnknown.StimulusEstablished -ceq 'UNKNOWN' -and $usbUnknown.TrialResult -ceq 'BLOCKED' -and $usbUnknown.Secondary -ceq 'BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID')
    foreach($setupReason in @('HORI_READY','UDP_BEGIN')){
        $setupParsed=Test-DgBSerialLog (New-SetupFailureFixture $setupReason);$setupResult=Get-DgBClassification $setupParsed $null $null
        Record "b31_setup_${setupReason}_is_pretrial_blocked" ($setupParsed.EvidenceContractValid -and $setupResult.Primary -ceq 'BLOCKED_DG_B_DEVICE_PRETRIAL_FAILURE' -and $setupResult.StimulusEstablished -ceq '0' -and $setupResult.TrialResult -ceq 'BLOCKED' -and $setupResult.TrialBlockReason -ceq 'BLOCKED_DG_B_DEVICE_PRETRIAL_FAILURE' -and $setupResult.DevicePretrialReason -ceq $setupReason)
    }
    $schedulerZero=Get-DgBClassification $scheduler $peerZeroShort $null
    Record 'b31_scheduler_zero_success_is_blocked' ($schedulerZero.Primary -ceq 'DG_B_TIMING_FAIL' -and $schedulerZero.StimulusEstablished -ceq '0' -and $schedulerZero.TrialResult -ceq 'BLOCKED' -and $schedulerZero.TrialBlockReason -ceq 'BLOCKED_DG_B_STIMULUS_NOT_ESTABLISHED')
    $schedulerStimulus=Get-DgBClassification $scheduler $peerFive $null
    Record 'b31_scheduler_after_success_is_trial_fail' ($schedulerStimulus.Primary -ceq 'DG_B_TIMING_FAIL' -and $schedulerStimulus.StimulusEstablished -ceq '1' -and $schedulerStimulus.TrialResult -ceq 'FAIL')
    $asyncZeroText=New-PeerFixture 1 'BLOCKED' 1 0 0 0
    $asyncZeroText=$asyncZeroText -replace '(?m)^INGRESS_TX_FAIL_TOTAL=.*$','INGRESS_TX_FAIL_TOTAL=1' -replace '(?m)^PEER_SOCKET_ERROR_PHASE=.*$','PEER_SOCKET_ERROR_PHASE=SENDTO' -replace '(?m)^PEER_SOCKET_ERROR_SEQUENCE=.*$','PEER_SOCKET_ERROR_SEQUENCE=0'
    $asyncZero=Test-DgBPeerSummary $asyncZeroText 3;$asyncZeroResult=Get-DgBClassification $s1Parsed $asyncZero $null
    Record 'b31_async_before_success_is_blocked' ($asyncZero.EvidenceContractValid -and $asyncZeroResult.Primary -ceq 'BLOCKED_DG_B_PEER_UDP_ASYNC_ERROR' -and $asyncZeroResult.StimulusEstablished -ceq '0' -and $asyncZeroResult.TrialResult -ceq 'BLOCKED')
    $asyncAfterSuccess=Get-DgBClassification $s1Parsed $asyncPeer $null
    Record 'b31_async_after_success_remains_blocked' ($asyncAfterSuccess.Primary -ceq 'BLOCKED_DG_B_PEER_UDP_ASYNC_ERROR' -and $asyncAfterSuccess.StimulusEstablished -ceq '1' -and $asyncAfterSuccess.TrialResult -ceq 'BLOCKED')
    $shortZeroResult=Get-DgBClassification $s1Parsed $peerZeroShort $null
    Record 'b31_short_first_send_is_blocked' ($peerZeroShort.EvidenceContractValid -and $shortZeroResult.Primary -ceq 'DG_B_PEER_INGRESS_SEND_FAIL' -and $shortZeroResult.StimulusEstablished -ceq '0' -and $shortZeroResult.TrialResult -ceq 'BLOCKED')
    $shortAfterSuccess=Get-DgBClassification $s1Parsed $shortPeer $null
    Record 'b31_short_send_after_success_remains_blocked' ($shortAfterSuccess.Primary -ceq 'DG_B_PEER_INGRESS_SEND_FAIL' -and $shortAfterSuccess.StimulusEstablished -ceq '1' -and $shortAfterSuccess.TrialResult -ceq 'BLOCKED')
    $pass499Result=Get-DgBClassification $s1Parsed $peer499 $rec499
    Record 'b31_499_pass_has_established_stimulus' ($pass499Result.Primary -ceq 'DG_B_PASS' -and $pass499Result.StimulusEstablished -ceq '1' -and $pass499Result.TrialResult -ceq 'PASS')
    $pass3000Result=Get-DgBClassification $t1Parsed $peer3000 $rec3000
    Record 'b31_3000_pass_has_established_stimulus' ($pass3000Result.Primary -ceq 'DG_B_PASS' -and $pass3000Result.StimulusEstablished -ceq '1' -and $pass3000Result.TrialResult -ceq 'PASS')
    $malformedTrial=Get-DgBClassification $s1Parsed $badPeer $null
    Record 'b31_malformed_peer_never_trial_pass' ($malformedTrial.StimulusEstablished -ceq 'UNKNOWN' -and $malformedTrial.TrialResult -ceq 'BLOCKED' -and $malformedTrial.Primary -ceq 'BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID')
    $passAdjudication=[pscustomobject]@{Primary='DG_B_PASS';Secondary='';StimulusEstablished='1';TrialResult='PASS';TrialBlockReason='';DevicePretrialReason=''}
    $passAdjudicationExpected=@('DG_B_CLASSIFICATION_PRIMARY=DG_B_PASS','DG_B_STIMULUS_ESTABLISHED=1','DG_B_TRIAL_RESULT=PASS')
    $passAdjudicationLines=@(Get-DgBAdjudicationLines $passAdjudication)
    Record 'b32_pass_adjudication_serialization' (($passAdjudicationLines -join "`n") -ceq ($passAdjudicationExpected -join "`n"))
    $blockedAdjudication=[pscustomobject]@{Primary='DG_B_USB_HID_FAIL';Secondary='';StimulusEstablished='0';TrialResult='BLOCKED';TrialBlockReason='BLOCKED_DG_B_STIMULUS_NOT_ESTABLISHED';DevicePretrialReason=''}
    $blockedAdjudicationExpected=@('DG_B_CLASSIFICATION_PRIMARY=DG_B_USB_HID_FAIL','DG_B_STIMULUS_ESTABLISHED=0','DG_B_TRIAL_RESULT=BLOCKED','DG_B_TRIAL_BLOCK_REASON=BLOCKED_DG_B_STIMULUS_NOT_ESTABLISHED')
    $blockedAdjudicationLines=@(Get-DgBAdjudicationLines $blockedAdjudication)
    Record 'b32_blocked_adjudication_serialization' (($blockedAdjudicationLines -join "`n") -ceq ($blockedAdjudicationExpected -join "`n"))
    $failAdjudication=[pscustomobject]@{Primary='DG_B_USB_HID_FAIL';Secondary='';StimulusEstablished='1';TrialResult='FAIL';TrialBlockReason='';DevicePretrialReason=''}
    $failAdjudicationExpected=@('DG_B_CLASSIFICATION_PRIMARY=DG_B_USB_HID_FAIL','DG_B_STIMULUS_ESTABLISHED=1','DG_B_TRIAL_RESULT=FAIL')
    Record 'b32_fail_usb_adjudication_serialization' ((@(Get-DgBAdjudicationLines $failAdjudication) -join "`n") -ceq ($failAdjudicationExpected -join "`n"))
    $pretrialAdjudication=[pscustomobject]@{Primary='BLOCKED_DG_B_DEVICE_PRETRIAL_FAILURE';Secondary='';StimulusEstablished='0';TrialResult='BLOCKED';TrialBlockReason='BLOCKED_DG_B_DEVICE_PRETRIAL_FAILURE';DevicePretrialReason='HORI_READY'}
    $pretrialAdjudicationExpected=@('DG_B_CLASSIFICATION_PRIMARY=BLOCKED_DG_B_DEVICE_PRETRIAL_FAILURE','DG_B_STIMULUS_ESTABLISHED=0','DG_B_TRIAL_RESULT=BLOCKED','DG_B_TRIAL_BLOCK_REASON=BLOCKED_DG_B_DEVICE_PRETRIAL_FAILURE','DG_B_DEVICE_PRETRIAL_REASON=HORI_READY')
    Record 'b32_pretrial_adjudication_serialization' ((@(Get-DgBAdjudicationLines $pretrialAdjudication) -join "`n") -ceq ($pretrialAdjudicationExpected -join "`n"))
    $parityRoot=Join-Path $testRoot 'b32-parity';New-Item -ItemType Directory -Path $parityRoot|Out-Null
    $stdoutLines=@(Write-DgBAdjudicationOutput $passAdjudication $parityRoot);$parityPath=Join-Path $parityRoot 'runner-adjudication.txt';$parityBytes=[IO.File]::ReadAllBytes($parityPath)
    $parityText=[IO.File]::ReadAllText($parityPath,[Text.UTF8Encoding]::new($false));$parityNoBom=!($parityBytes.Length-ge 3 -and $parityBytes[0]-eq 0xEF -and $parityBytes[1]-eq 0xBB -and $parityBytes[2]-eq 0xBF)
    Record 'b32_stdout_file_parity_utf8_no_bom_final_lf' (($stdoutLines -join "`n") -ceq ($passAdjudicationExpected -join "`n") -and $parityText -ceq (($stdoutLines -join "`n")+"`n") -and $parityNoBom -and $parityBytes[-1] -eq 0x0A)
    $passPersistenceRoot=Join-Path $testRoot 'b32-pass-persistence';New-Item -ItemType Directory -Path $passPersistenceRoot|Out-Null
    $null=@(Write-DgBAdjudicationOutput $passAdjudication $passPersistenceRoot)
    Record 'b32_pass_path_file_persistence' (([IO.File]::ReadAllText((Join-Path $passPersistenceRoot 'runner-adjudication.txt'),[Text.UTF8Encoding]::new($false))) -ceq (($passAdjudicationExpected -join "`n")+"`n"))
    $blockedPersistenceRoot=Join-Path $testRoot 'b32-blocked-persistence';New-Item -ItemType Directory -Path $blockedPersistenceRoot|Out-Null;$blockedPersistedBeforeThrow=$false
    try{$null=@(Write-DgBAdjudicationOutput $blockedAdjudication $blockedPersistenceRoot);$blockedPersistedBeforeThrow=(Test-Path -LiteralPath (Join-Path $blockedPersistenceRoot 'runner-adjudication.txt') -PathType Leaf);throw 'SIMULATED_NONPASS'}catch{}
    Record 'b32_nonpass_file_persisted_before_throw' $blockedPersistedBeforeThrow
    $fallbackRoot=Join-Path $testRoot 'b32-fallback-persistence';New-Item -ItemType Directory -Path $fallbackRoot|Out-Null
    $fallbackAdjudication=[pscustomobject]@{Primary='ORCHESTRATION_STALL/TIMEOUT';Secondary='';StimulusEstablished='UNKNOWN';TrialResult='BLOCKED';TrialBlockReason='ORCHESTRATION_STALL/TIMEOUT';DevicePretrialReason=''}
    $null=@(Write-DgBAdjudicationOutput $fallbackAdjudication $fallbackRoot)
    Record 'b32_fallback_catch_file_persistence' (Test-Path -LiteralPath (Join-Path $fallbackRoot 'runner-adjudication.txt') -PathType Leaf)
    $noTrialRoot=Join-Path $testRoot 'b32-no-trial-root';$null=@(Write-DgBAdjudicationOutput $passAdjudication)
    Record 'b32_no_trial_root_no_file_or_directory' (!(Test-Path -LiteralPath $noTrialRoot))
    Record 'serial_ready_precedes_arm' (Test-DgBControlPlaneTrace @('PEER_READY','UPLOAD_PASS','COM4_REENUMERATED','SERIAL_CAPTURE_READY','ARM_REQUESTED'))
    Record 'serial_open_failure_never_arms' ((Test-DgBControlPlaneTrace @('PEER_READY','UPLOAD_PASS','COM4_REENUMERATED','SERIAL_CAPTURE_OPEN_FAILED')) -and !(Test-DgBControlPlaneTrace @('SERIAL_CAPTURE_OPEN_FAILED','ARM_REQUESTED')))
    $marker='SCOPE_MARKER trial=C1 event=TRIAL_COMPLETE result=PASS'
    Record 'terminal_marker_one_chunk_detected' (Test-DgBTerminalMarkerChunks @($marker))
    Record 'terminal_marker_split_chunks_detected' (Test-DgBTerminalMarkerChunks @('SCOPE_MARKER trial=C1 event=TRIAL_','COMPLETE result=PASS'))
    $exactPath=Join-Path $testRoot 'serial-exact-no-newline.log';$exact='alpha';Write-ExactUtf8Text $exactPath $exact;Record 'serial_no_trailing_newline_preserved' (([IO.File]::ReadAllText($exactPath,[Text.UTF8Encoding]::new($false))) -ceq $exact -and (Get-Item $exactPath).Length -eq 5)
    $mixedPath=Join-Path $testRoot 'serial-exact-mixed.log';$mixed="a`r`nb`nc";Write-ExactUtf8Text $mixedPath $mixed;Record 'serial_crlf_lf_mix_preserved' (([IO.File]::ReadAllText($mixedPath,[Text.UTF8Encoding]::new($false))) -ceq $mixed)
    $goodCom=@([pscustomobject]@{Name='USB JTAG/serial debug unit (COM4)';PNPDeviceID=$fixedPnpDeviceId})
    Record 'fixed_exact_pnp_pass' (Test-ExactCom4Identity $goodCom $fixedPnpDeviceId)
    Record 'wrong_exact_pnp_blocked' (!(Test-ExactCom4Identity $goodCom 'USB\VID_303A&PID_1001&MI_00\DIFFERENT'))
    $ips=@([pscustomobject]@{IPAddress='192.168.50.30';PrefixLength=24;InterfaceIndex=7});$adapters=@([pscustomobject]@{InterfaceIndex=7;Status='Up'});$routes=@([pscustomobject]@{InterfaceIndex=7;DestinationPrefix='192.168.50.0/24';NextHop='0.0.0.0'})
    Record 'nic_exact_topology_pass' (Test-DgBPeerTopologyRecords $ips $adapters $routes @())
    $wrongPrefix=@([pscustomobject]@{IPAddress='192.168.50.30';PrefixLength=23;InterfaceIndex=7});Record 'nic_wrong_prefix_blocked' (!(Test-DgBPeerTopologyRecords $wrongPrefix $adapters $routes @()))
    $gateway=@([pscustomobject]@{InterfaceIndex=7;NextHop='192.168.50.1'});Record 'nic_default_gateway_blocked' (!(Test-DgBPeerTopologyRecords $ips $adapters $routes $gateway))
    $pass=@($records|Where-Object Pass).Count
    $lines=@($records|ForEach-Object{"RUNNER_OFFLINE_TEST name=$($_.Name) result=$(if($_.Pass){'PASS'}else{'FAIL'}) detail=$($_.Detail)"})
    $lines += "RUNNER_OFFLINE_TEST_TOTAL=$($records.Count)"; $lines += "RUNNER_OFFLINE_TEST_PASS=$pass"; $lines += "RUNNER_OFFLINE_TEST_FAIL=$($records.Count-$pass)"; $lines += "RUNNER_OFFLINE_RESULT=$(if($pass -eq $records.Count){'PASS'}else{'FAIL'})"
    [pscustomobject]@{Pass=($pass -eq $records.Count);Count=$records.Count;PassCount=$pass;Lines=$lines;TestRoot=$testRoot;Plan=$plan;Staging=$planStage;Toolchain=$toolchain;PreRows=$pre;PostRows=$post}
}

function Invoke-Captured([string]$File,[string[]]$Arguments,[string]$Stdout,[string]$Stderr,[switch]$AllowNonZero) {
    $p=Start-Process -FilePath $File -ArgumentList $Arguments -NoNewWindow -PassThru -Wait -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
    if(!$AllowNonZero -and $p.ExitCode -ne 0){throw "process failed file=$File exit=$($p.ExitCode)"}
    $p.ExitCode
}

function Write-Utf8([string]$Path,[string[]]$Lines) {[IO.File]::WriteAllLines($Path,$Lines,[Text.UTF8Encoding]::new($false))}

function New-SourcePatch([string[]]$Paths,[string]$OutputPath) {
    $out=[Collections.Generic.List[string]]::new()
    foreach($path in $Paths){$relative=(Get-RelativePathCompat $repoRoot $path).Replace('\','/');$lines=Get-Content -LiteralPath $path;$out.Add("diff --git a/$relative b/$relative");$out.Add('new file mode 100644');$out.Add('--- /dev/null');$out.Add("+++ b/$relative");$out.Add("@@ -0,0 +1,$($lines.Count) @@");foreach($line in $lines){$out.Add("+$line")}}
    Write-Utf8 $OutputPath $out
}

function New-DgBReviewPackage {
    foreach($required in @($peerScript,$PSCommandPath,$contractPath)){if(!(Test-Path -LiteralPath $required)){throw "review source missing: $required"}}
    $generation="DG-B-implementation-review-{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'),([guid]::NewGuid().ToString('N').Substring(0,8))
    $root=Join-Path $reviewRoot $generation;New-Item -ItemType Directory -Force -Path $root|Out-Null
    foreach($dir in @('authority','source','contract','diffs','offline-tests','artifact-authority','control-plane','serial-capture-fixtures','git')){New-Item -ItemType Directory -Path (Join-Path $root $dir)|Out-Null}
    Copy-Item -LiteralPath $peerScript -Destination (Join-Path $root 'source\usb_lan_gate_dg_b_peer.py')
    Copy-Item -LiteralPath $PSCommandPath -Destination (Join-Path $root 'source\usb_lan_gate_dg_b_runner.ps1')
    Copy-Item -LiteralPath $contractPath -Destination (Join-Path $root 'contract\usb-lan-gate-dg-b-contract.md')
    $donorRows=Assert-DonorAuthority
    $donorRows|Export-Csv -LiteralPath (Join-Path $root 'authority\donor-authority-verification.csv') -NoTypeInformation -Encoding utf8
    $runnerTests=Invoke-RunnerOfflineSelfTests;Write-Utf8 (Join-Path $root 'offline-tests\runner-offline-tests.log') $runnerTests.Lines
    $peerOut=Join-Path $root 'offline-tests\peer-offline-tests.log';$peerErr=Join-Path $root 'offline-tests\peer-offline-tests.stderr.log'
    $peerExit=Invoke-Captured 'python.exe' @($peerScript,'--self-test') $peerOut $peerErr -AllowNonZero
    if(!$runnerTests.Pass -or $peerExit -ne 0){throw 'DG_B_IMPLEMENTATION_FIX_FIRST offline tests failed'}
    $staging=$runnerTests.Plan
    $t1Staging=New-DgBArtifactStaging T1 $runnerTests.TestRoot;$t1Plan=Get-DgBUploadPlan $t1Staging
    $planLines=@("S1_FUTURE_UPLOAD_COMMAND=$($staging.Command)","T1_FUTURE_UPLOAD_COMMAND=$($t1Plan.Command)",'BUILD=NOT_RUN','COMPILE=NOT_RUN','WHOLE_FLASH_MERGED_UPLOAD=PROHIBITED')+@($staging.Segments|ForEach-Object{"S1_UPLOAD_SEGMENT OFFSET=$($_.Offset) ROLE=$($_.Role) ACTUAL_INPUT_PATH=$($_.Path) STAGED_EVIDENCE_PATH=$($_.StagedEvidencePath) SHA256=$($_.Sha256)"})+@($t1Plan.Segments|ForEach-Object{"T1_UPLOAD_SEGMENT OFFSET=$($_.Offset) ROLE=$($_.Role) ACTUAL_INPUT_PATH=$($_.Path) STAGED_EVIDENCE_PATH=$($_.StagedEvidencePath) SHA256=$($_.Sha256)"})
    Write-Utf8 (Join-Path $root 'artifact-authority\future-upload-plan.txt') $planLines
    $stageEvidence=@('STAGING_VALIDATION=PASS',"STAGING_STAGE=$($runnerTests.Plan.Stage)","STAGING_PATH=$($runnerTests.Plan.StagingPath)","C1_GENERATION=$($authority.C1Generation)","ARCHIVE_MANIFEST_SHA256=$($authority.ArchiveManifestSha256)","FREEZE_ZIP_SHA256=$($authority.FreezeZipSha256)")
    Write-Utf8 (Join-Path $root 'artifact-authority\staging-validation.txt') $stageEvidence
    $archiveManifestPath=Join-Path $freezeRoot 'archive-manifest.csv'
    $artifactRows=@(
        [pscustomobject]@{Stage='AUTHORITY';Role='c1_archive_manifest';Path=$archiveManifestPath;Size=(Get-Item $archiveManifestPath).Length;Sha256=$authority.ArchiveManifestSha256;Offset='NOT_UPLOADED'}
        [pscustomobject]@{Stage='AUTHORITY';Role='c1_final_zip';Path=$freezeZip;Size=$authority.FreezeZipSize;Sha256=$authority.FreezeZipSha256;Offset='NOT_UPLOADED'}
        foreach($stageName in @('S1','T1')){$v=Assert-StageAuthority $stageName;$a=$v.Authority
            [pscustomobject]@{Stage=$stageName;Role='application';Path=$a.Application;Size=$a.ApplicationSize;Sha256=$a.ApplicationSha256;Offset='0x10000'}
            [pscustomobject]@{Stage=$stageName;Role='bootloader';Path=$a.Bootloader;Size=$a.BootloaderSize;Sha256=$a.BootloaderSha256;Offset='0x0000'}
            [pscustomobject]@{Stage=$stageName;Role='partitions';Path=$a.Partitions;Size=$a.PartitionsSize;Sha256=$a.PartitionsSha256;Offset='0x8000'}
            [pscustomobject]@{Stage=$stageName;Role='boot_app0';Path=$a.BootApp0;Size=$a.BootApp0Size;Sha256=$a.BootApp0Sha256;Offset='0xE000'}
            [pscustomobject]@{Stage=$stageName;Role='merged_authority_not_uploaded';Path=$a.Merged;Size=$a.MergedSize;Sha256=$a.MergedSha256;Offset='NOT_UPLOADED'}
        }
    )
    $artifactRows|Export-Csv -LiteralPath (Join-Path $root 'artifact-authority\C1-artifact-authority.csv') -NoTypeInformation -Encoding utf8
    $runnerTests.PreRows|Export-Csv -LiteralPath (Join-Path $root 'artifact-authority\artifact-authority-pre-upload-fixture.csv') -NoTypeInformation -Encoding utf8
    $runnerTests.PostRows|Export-Csv -LiteralPath (Join-Path $root 'artifact-authority\artifact-authority-post-upload-fixture.csv') -NoTypeInformation -Encoding utf8
    $runnerTests.Toolchain.PSObject.Properties|ForEach-Object{"$($_.Name)=$($_.Value)"}|Set-Content -LiteralPath (Join-Path $root 'authority\toolchain-authority-evidence.txt') -Encoding utf8
    Write-Utf8 (Join-Path $root 'control-plane\future-physical-orchestration-plan.txt') @(
        '1 ACCEPTED_IMPLEMENTATION_AUTHORITY','2 EXACT_C1_ARTIFACT_AUTHORITY','3 TRIAL_ROOT_AND_ARTIFACT_STAGING','4 COM_NIC_TOOLCHAIN_PREFLIGHT','5 PEER_BOUND_NOT_ARMED','6 PEER_READY','7 EXACT_STAGED_UPLOAD','8 UPLOAD_EVIDENCE_PASS','9 POST_UPLOAD_ARTIFACT_REHASH','10 EXACT_COM4_BOUNDED_REENUMERATION','11 SERIAL_PORT_OPEN','12 SERIAL_CAPTURE_READY','13 ARM_REQUESTED','14 ARMED_ACKNOWLEDGEMENT','15 SEQUENCE_ZERO_ADMISSION','16 FIRST_DG_B_STIMULUS','17 CAPTURE_AND_ADJUDICATION','INVARIANT=NO_ARM_NO_STIMULUS_BEFORE_SERIAL_CAPTURE_READY','RETRY=NONE')
    Write-Utf8 (Join-Path $root 'control-plane\fixed-topology.txt') @("COM4_PNP_DEVICE_ID=$fixedPnpDeviceId","PEER_IPV4=$peerIp/24",'TEST_INTERFACE_DEFAULT_GATEWAY=ABSENT','DIRECT_ROUTE=192.168.50.0/24','PREFLIGHT_ACTIVE_TRAFFIC=PROHIBITED')
    Write-Utf8 (Join-Path $root 'control-plane\treatment-causal-adjudication.txt') @(
        'STIMULUS_ESTABLISHED_1=VALID_PEER_AND_INGRESS_TX_SUCCESS_TOTAL_GT_0',
        'STIMULUS_ESTABLISHED_0=VALID_PEER_AND_INGRESS_TX_SUCCESS_TOTAL_EQ_0',
        'STIMULUS_ESTABLISHED_UNKNOWN=PEER_EVIDENCE_MISSING_INVALID_OR_UNAVAILABLE',
        'SETUP_FAILURE_PRIMARY=BLOCKED_DG_B_DEVICE_PRETRIAL_FAILURE',
        'DEVICE_OBSERVATION_PLUS_STIMULUS_1=TRIAL_FAIL',
        'DEVICE_OBSERVATION_PLUS_STIMULUS_0_OR_UNKNOWN=TRIAL_BLOCKED',
        'PEER_OR_CONTROL_PLANE_FAILURE=TRIAL_BLOCKED',
        'FOUR_LAYER_PASS_PLUS_STIMULUS_1=TRIAL_PASS',
        'RAW_PHYSICAL_OBSERVATION_DOES_NOT_PROVE_TREATMENT_ESTABLISHMENT=1')
    Copy-Item -LiteralPath (Join-Path $runnerTests.TestRoot 'serial-exact-no-newline.log') -Destination (Join-Path $root 'serial-capture-fixtures\no-trailing-newline.log')
    Copy-Item -LiteralPath (Join-Path $runnerTests.TestRoot 'serial-exact-mixed.log') -Destination (Join-Path $root 'serial-capture-fixtures\mixed-crlf-lf.log')
    Write-Utf8 (Join-Path $root 'serial-capture-fixtures\README.txt') @('Fixtures are exact UTF-8/no-BOM byte streams.','no-trailing-newline.log has no added terminal newline.','mixed-crlf-lf.log preserves CRLF/LF mixture.','Runner offline tests also cover a terminal marker split across read chunks.')
    New-SourcePatch @($peerScript,$PSCommandPath,$contractPath) (Join-Path $root 'diffs\dg-b-new-files.patch')
    $gitOut=Join-Path $root 'git\git-status.txt';$gitErr=Join-Path $root 'git\git-status.stderr.txt';[void](Invoke-Captured 'git.exe' @('status','-sb') $gitOut $gitErr -AllowNonZero)
    [void](Invoke-Captured 'git.exe' @('diff','--check') (Join-Path $root 'git\git-diff-check.txt') (Join-Path $root 'git\git-diff-check.stderr.txt') -AllowNonZero)
    [void](Invoke-Captured 'git.exe' @('diff','--stat') (Join-Path $root 'git\git-diff-stat.txt') (Join-Path $root 'git\git-diff-stat.stderr.txt') -AllowNonZero)
    [void](Invoke-Captured 'git.exe' @('diff','--binary') (Join-Path $root 'git\git-diff.patch') (Join-Path $root 'git\git-diff.stderr.txt') -AllowNonZero)
    Write-Utf8 (Join-Path $root 'PHYSICAL_PROHIBITION.txt') @('IMPLEMENTATION=RUN','PEER_FUNCTIONAL_MODIFICATION=NOT_RUN','FIRMWARE_SOURCE_MODIFICATION=NOT_RUN','BUILD=NOT_RUN','COMPILE=NOT_RUN','UPLOAD=NOT_RUN','FLASH=NOT_RUN','SERIAL_OPEN=NOT_RUN','COM4_ACTIVE_ACCESS=NOT_RUN','NETWORK_TRAFFIC_GENERATED=NOT_RUN','DG_B_S1=NOT_RUN','DG_B_T1=NOT_RUN','GATE_C3=NOT_RUN','COMMIT=NOT_RUN','PUSH=NOT_RUN','PR=NOT_RUN')
    Write-Utf8 (Join-Path $root 'SUPERSEDES.txt') @('SUPERSEDES_GENERATION=DG-B-implementation-review-20260821-104642-3bbbba08','SUPERSEDED_REVIEWED_MANIFEST_SHA256=D613FB914812F38FB0C91919711F65FB84182A86B40D7725D70F9B5029DB3B84','SUPERSEDED_EVIDENCE_MUTATED=NO')
    Write-Utf8 (Join-Path $root 'README.md') @("# $generation",'','Candidate only; not accepted authority.','Supersedes DG-B-implementation-review-20260821-104642-3bbbba08 without mutating it.','Exact C1 freeze is referenced read-only and is not repacked.','Contains B-32 final evidence-root closure and all prior accepted remediations.','Offline peer/runner tests and staging-copy validation only.','No build, upload, COM, network, or physical trial occurred.')
    $sourceManifest=Join-Path $root 'authority\DG-B-reviewed-source-manifest.csv'
    @(
        [pscustomobject]@{relative_or_absolute_path=$peerScript;size=(Get-Item $peerScript).Length;sha256=Get-Sha256 $peerScript;role='dg_b_peer'},
        [pscustomobject]@{relative_or_absolute_path=$PSCommandPath;size=(Get-Item $PSCommandPath).Length;sha256=Get-Sha256 $PSCommandPath;role='dg_b_runner'},
        [pscustomobject]@{relative_or_absolute_path=$contractPath;size=(Get-Item $contractPath).Length;sha256=Get-Sha256 $contractPath;role='dg_b_contract'}
    )|Export-Csv -LiteralPath $sourceManifest -NoTypeInformation -Encoding utf8
    $sourceManifestHash=Get-Sha256 $sourceManifest;Write-Utf8 "$sourceManifest.sha256.txt" @($sourceManifestHash)
    Write-Utf8 (Join-Path $root 'authority\PROPOSED_EXPECTED_REVIEWED_MANIFEST_SHA256.txt') @("PROPOSED_EXPECTED_REVIEWED_MANIFEST_SHA256=$sourceManifestHash",'STATUS=PROPOSED_NOT_ACCEPTED')
    $packageManifest=Join-Path $root 'review-package-manifest.csv'
    Get-ChildItem -LiteralPath $root -File -Recurse|Where-Object{$_.FullName -ne $packageManifest -and $_.FullName -ne "$packageManifest.sha256.txt"}|ForEach-Object{[pscustomobject]@{relative_path=(Get-RelativePathCompat $root $_.FullName).Replace('\','/');size=$_.Length;sha256=Get-Sha256 $_.FullName}}|Sort-Object relative_path|Export-Csv -LiteralPath $packageManifest -NoTypeInformation -Encoding utf8
    $packageHash=Get-Sha256 $packageManifest;Write-Utf8 "$packageManifest.sha256.txt" @($packageHash)
    [pscustomobject]@{Generation=$generation;Path=$root;ReviewedManifest=$sourceManifest;ReviewedManifestSha256=$sourceManifestHash;ReviewPackageManifestSha256=$packageHash;RunnerTestCount=$runnerTests.Count;PeerTestLog=$peerOut}
}

function Assert-ReviewedImplementationAuthority([string]$Manifest,[string]$ExpectedHash) {
    if([string]::IsNullOrWhiteSpace($Manifest)-or[string]::IsNullOrWhiteSpace($ExpectedHash)){throw 'BLOCKED_DG_B_IMPLEMENTATION_AUTHORITY_REQUIRED'}
    Assert-FileIdentity $Manifest (Get-Item -LiteralPath $Manifest).Length $ExpectedHash 'BLOCKED_DG_B_IMPLEMENTATION_AUTHORITY_IDENTITY_MISMATCH'|Out-Null
    foreach($row in Import-Csv -LiteralPath $Manifest){Assert-FileIdentity $row.relative_or_absolute_path ([int64]$row.size) $row.sha256 'BLOCKED_DG_B_IMPLEMENTATION_AUTHORITY_IDENTITY_MISMATCH'|Out-Null}
}

function Start-DgBSerialCaptureJob([string]$TrialRoot,[int]$DurationSeconds,[string]$PnpDeviceId) {
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
                if($chunk){[void]$builder.Append($chunk);if($builder.ToString().Contains('SCOPE_MARKER trial=C1 event=TRIAL_COMPLETE')){$terminal=$true;break}}
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
        if($captureError -ne 'NONE'){throw 'BLOCKED_DG_B_SERIAL_CAPTURE_NOT_READY'}
    }
    [pscustomobject]@{Job=$job;SerialPath=$serialPath;MetadataPath=$metadataPath;ReadyPath=$readyPath;ErrorPath=$errorPath}
}

function Invoke-DgBPhysicalTrial {
    if(!($RunPhysicalTrial -and $AllowUpload -and $AllowSerial -and $AllowPeer -and $AllowNetworkTrial)){throw 'Physical trial requires all explicit permission switches.'}
    try{Assert-ReviewedImplementationAuthority $ReviewedManifestPath $ExpectedReviewedManifestSha256}catch{
        $token=Get-DgBFailureToken $_.Exception.Message
        Write-DgBAdjudicationOutput ([pscustomobject]@{Primary=$token;Secondary='';StimulusEstablished='UNKNOWN';TrialResult='BLOCKED';TrialBlockReason=$token;DevicePretrialReason=''})
        throw
    }
    $trialRoot=Join-Path $physicalEvidenceRoot ("DG-B-$Trial-{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'),([guid]::NewGuid().ToString('N').Substring(0,8)));New-Item -ItemType Directory -Force -Path $trialRoot|Out-Null
    $adjudicationEmitted=$false
    try {
    if($ExpectedPnpDeviceId -cne $fixedPnpDeviceId){throw 'BLOCKED_DG_B_COM4_PNP_IDENTITY'}
    $staging=New-DgBArtifactStaging $Trial (Join-Path $trialRoot 'artifact-staging') -UseRootAsStaging
    $plan=Get-DgBUploadPlan $staging
    $toolchain=Get-DgBToolchainAuthority
    $toolchain.PSObject.Properties|ForEach-Object{"$($_.Name)=$($_.Value)"}|Set-Content -LiteralPath (Join-Path $trialRoot 'toolchain-identity.txt') -Encoding utf8
    $pre=Get-DgBArtifactIdentityRows $staging $toolchain PRE_UPLOAD;Assert-DgBArtifactIdentityRows $pre $staging|Out-Null
    $pre|Export-Csv -LiteralPath (Join-Path $trialRoot 'artifact-authority-pre-upload.csv') -NoTypeInformation -Encoding utf8
    $planLines=@("FUTURE_UPLOAD_COMMAND=$($plan.Command)")+@($plan.Segments|ForEach-Object{"UPLOAD_SEGMENT OFFSET=$($_.Offset) ROLE=$($_.Role) ACTUAL_INPUT_PATH=$($_.Path) STAGED_EVIDENCE_PATH=$($_.StagedEvidencePath) SHA256=$($_.Sha256)"})
    Write-Utf8 (Join-Path $trialRoot 'upload-plan.txt') $planLines
    $com=Get-Com4IdentityRecords;if(!(Test-ExactCom4Identity $com $ExpectedPnpDeviceId)){throw 'BLOCKED_DG_B_COM4_PNP_IDENTITY'}
    Assert-DgBPeerTopology
    $arm=Join-Path $trialRoot 'peer.arm';$armed=Join-Path $trialRoot 'peer.armed';$ready=Join-Path $trialRoot 'peer.ready';$stop=Join-Path $trialRoot 'peer.stop';$csv=Join-Path $trialRoot 'peer.csv';$peerOut=Join-Path $trialRoot 'peer.stdout.log';$peerErr=Join-Path $trialRoot 'peer.stderr.log'
    $peer=Start-Process -FilePath 'python.exe' -ArgumentList @($peerScript,'--live','--bind-ip',$peerIp,'--port','50001','--arm-file',$arm,'--armed-file',$armed,'--ready-file',$ready,'--stop-file',$stop,'--csv',$csv) -PassThru -WindowStyle Hidden -RedirectStandardOutput $peerOut -RedirectStandardError $peerErr
    $secondary='';$armRequested=$false;$serialCapture=$null
    try{
        $watch=[Diagnostics.Stopwatch]::StartNew();while(!(Test-Path -LiteralPath $ready)){if($peer.HasExited){throw 'BLOCKED_DG_B_STIMULUS_NOT_ESTABLISHED'};if($watch.Elapsed.TotalSeconds -gt 10){throw 'ORCHESTRATION_STALL/TIMEOUT'};Start-Sleep -Milliseconds 50}
        [void](Assert-StagedArtifactIdentity $staging)
        $uploadOut=Join-Path $trialRoot 'upload.stdout.log';$uploadErr=Join-Path $trialRoot 'upload.stderr.log';$upload=Start-Process -FilePath $toolchain.ARDUINO_CLI_PATH -ArgumentList @('upload','--fqbn',$fqbn,'--port','COM4','--input-dir',$staging.Path) -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $uploadOut -RedirectStandardError $uploadErr
        if($upload.ExitCode -ne 0){throw 'BLOCKED_DG_B_EXACT_C1_ARTIFACT_UPLOAD_PATH_UNRESOLVED'}
        if(!(Test-DgBUploadEvidence $uploadOut $staging.Authority)){throw 'BLOCKED_DG_B_EXACT_C1_ARTIFACT_UPLOAD_PATH_UNRESOLVED upload_evidence_invalid'}
        $post=Get-DgBArtifactIdentityRows $staging $toolchain POST_UPLOAD;Assert-DgBArtifactIdentityRows $post $staging|Out-Null;Compare-DgBArtifactIdentityRows $pre $post|Out-Null
        $post|Export-Csv -LiteralPath (Join-Path $trialRoot 'artifact-authority-post-upload.csv') -NoTypeInformation -Encoding utf8
        [void](Wait-ExactCom4Reenumeration $ExpectedPnpDeviceId 15)
        $serialCapture=Start-DgBSerialCaptureJob $trialRoot $staging.Authority.DurationSeconds $ExpectedPnpDeviceId
        $watch.Restart();while(!(Test-Path -LiteralPath $serialCapture.ReadyPath)){if($serialCapture.Job.State -in @('Completed','Failed','Stopped')){Receive-Job $serialCapture.Job -ErrorAction SilentlyContinue|Out-File -LiteralPath (Join-Path $trialRoot 'serial-capture-job.log') -Encoding utf8;throw 'BLOCKED_DG_B_SERIAL_CAPTURE_NOT_READY'};if($watch.Elapsed.TotalSeconds -gt 5){throw 'BLOCKED_DG_B_SERIAL_CAPTURE_NOT_READY'};Start-Sleep -Milliseconds 25}
        Write-Utf8 $arm @('SERIAL_CAPTURE_READY=1','UPLOAD_PASS=1','ARM=1');$armRequested=$true
        $watch.Restart();while(!(Test-Path -LiteralPath $armed)){if($peer.HasExited){throw 'BLOCKED_DG_B_STIMULUS_NOT_ESTABLISHED'};if($watch.Elapsed.TotalSeconds -gt 10){throw 'ORCHESTRATION_STALL/TIMEOUT'};Start-Sleep -Milliseconds 50}
        if(!(Wait-Job $serialCapture.Job -Timeout ($staging.Authority.DurationSeconds+40))){$secondary='SERIAL_CAPTURE_TIMEOUT';Stop-Job $serialCapture.Job -ErrorAction SilentlyContinue}
        Receive-Job $serialCapture.Job -ErrorAction SilentlyContinue|Out-File -LiteralPath (Join-Path $trialRoot 'serial-capture-job.log') -Encoding utf8
        if(!(Test-Path -LiteralPath $serialCapture.SerialPath)){throw 'BLOCKED_DG_B_SERIAL_CAPTURE_NOT_READY'}
        $serialText=[IO.File]::ReadAllText($serialCapture.SerialPath,[Text.UTF8Encoding]::new($false));$provisional=Get-DgBRawProvisionalPrimary $serialText
        Write-Utf8 $stop @('PEER_STOP=1')
        if(!$peer.WaitForExit(10000)){$secondary='PEER_GRACEFUL_EXIT_TIMEOUT'}
        $peerText=if(Test-Path $peerOut){Get-Content -LiteralPath $peerOut -Raw}else{''}
        $serialResult=Test-DgBSerialLog $serialText;$peerResult=Test-DgBPeerSummary $peerText $(if($peer.HasExited){$peer.ExitCode}else{-1});$recon=Test-DgBReconciliation $serialResult $peerResult;$classification=Get-DgBClassification $serialResult $peerResult $recon $secondary
        Write-DgBAdjudicationOutput $classification $trialRoot;$adjudicationEmitted=$true
        if($classification.TrialResult -ne 'PASS'){throw "DG-B trial non-pass: primary=$($classification.Primary) trial_result=$($classification.TrialResult)"}
    } catch {
        Write-Utf8 (Join-Path $trialRoot 'runner-terminal-error.txt') @("ARM_REQUESTED=$(if($armRequested){1}else{0})","ERROR=$($_.Exception.Message)")
        throw
    } finally {
        if($null-ne $serialCapture -and $serialCapture.Job.State -notin @('Completed','Failed','Stopped')){Stop-Job $serialCapture.Job -ErrorAction SilentlyContinue;Receive-Job $serialCapture.Job -ErrorAction SilentlyContinue|Out-Null}
        if(!$peer.HasExited){Write-Utf8 $stop @('PEER_STOP=1');if(!$peer.WaitForExit(5000)){Stop-Process -Id $peer.Id -Force -ErrorAction SilentlyContinue}}
    }
    } catch {
        if(!$adjudicationEmitted){
            $token=Get-DgBFailureToken $_.Exception.Message
            $catchStimulus='UNKNOWN';$catchSecondary=''
            try{
                $peerOutVariable=Get-Variable -Name peerOut -ErrorAction SilentlyContinue
                if($null-ne $peerOutVariable -and (Test-Path -LiteralPath $peerOutVariable.Value -PathType Leaf)){
                    $catchPeerText=Get-Content -LiteralPath $peerOutVariable.Value -Raw
                    $peerVariable=Get-Variable -Name peer -ErrorAction SilentlyContinue
                    $catchExit=if($null-ne $peerVariable -and $peerVariable.Value.HasExited){$peerVariable.Value.ExitCode}else{-1}
                    $catchPeer=Test-DgBPeerSummary $catchPeerText $catchExit
                    $catchStimulus=Get-DgBStimulusEstablished $null $catchPeer
                    if(!$catchPeer.EvidenceContractValid){$catchSecondary='BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID'}elseif($catchPeer.AsyncError){$catchSecondary='BLOCKED_DG_B_PEER_UDP_ASYNC_ERROR'}elseif($catchPeer.AdmissionBlocked){$catchSecondary='BLOCKED_ADMISSION_SEQUENCE_MISS'}elseif($catchPeer.SendFail){$catchSecondary='DG_B_PEER_INGRESS_SEND_FAIL'}
                }
            }catch{$catchStimulus='UNKNOWN';$catchSecondary='BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID'}
            Write-DgBAdjudicationOutput ([pscustomobject]@{Primary=$token;Secondary=$catchSecondary;StimulusEstablished=$catchStimulus;TrialResult='BLOCKED';TrialBlockReason=$token;DevicePretrialReason=''}) $trialRoot
            $adjudicationEmitted=$true
        }
        if(!(Test-Path -LiteralPath (Join-Path $trialRoot 'runner-terminal-error.txt'))){Write-Utf8 (Join-Path $trialRoot 'runner-terminal-error.txt') @('ARM_REQUESTED=0',"ERROR=$($_.Exception.Message)")}
        throw
    }
}

if($OfflineSelfTest){$r=Invoke-RunnerOfflineSelfTests;$r.Lines|ForEach-Object{Write-Output $_};if(!$r.Pass){exit 1};exit 0}
if($EmitUploadPlan){$stage=New-DgBArtifactStaging $Trial (Join-Path $validationRoot 'plan-staging');$plan=Get-DgBUploadPlan $stage;Write-Output "FUTURE_UPLOAD_COMMAND=$($plan.Command)";foreach($segment in $plan.Segments){Write-Output "UPLOAD_SEGMENT OFFSET=$($segment.Offset) ROLE=$($segment.Role) ACTUAL_INPUT_PATH=$($segment.Path) STAGED_EVIDENCE_PATH=$($segment.StagedEvidencePath) SHA256=$($segment.Sha256)"};Write-Output 'BUILD=NOT_RUN';Write-Output 'COMPILE=NOT_RUN';Write-Output 'UPLOAD=NOT_RUN';exit 0}
if($CreateReviewPackage){$review=New-DgBReviewPackage;Write-Output "DG_B_REVIEW_GENERATION=$($review.Generation)";Write-Output "DG_B_REVIEW_PATH=$($review.Path)";Write-Output "DG_B_REVIEWED_SOURCE_MANIFEST=$($review.ReviewedManifest)";Write-Output "PROPOSED_EXPECTED_REVIEWED_MANIFEST_SHA256=$($review.ReviewedManifestSha256)";Write-Output "REVIEW_PACKAGE_MANIFEST_SHA256=$($review.ReviewPackageManifestSha256)";exit 0}
if($RunPhysicalTrial){Invoke-DgBPhysicalTrial;exit 0}
Write-Output 'DG-B runner safe default: no action.'
Write-Output 'Allowed offline modes: -OfflineSelfTest, -EmitUploadPlan, -CreateReviewPackage.'
Write-Output 'Physical mode is implemented but requires -RunPhysicalTrial and all explicit permission switches.'
