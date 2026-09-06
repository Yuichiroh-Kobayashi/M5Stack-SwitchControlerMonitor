[CmdletBinding()]
param(
    [switch]$RunPhysicalTrial,
    [switch]$RunOfflineTests,
    [switch]$VerifyReviewedManifest,
    [switch]$PreflightPhysicalTrial,
    [switch]$AllowUpload,
    [switch]$AllowSerial,
    [switch]$AllowPeer,
    [switch]$AllowNetworkTrial,
    [ValidateSet("DG-A-S1", "DG-A-T1")]
    [string]$Trial = "DG-A-S1",
    [ValidatePattern('^COM4$')]
    [string]$ComPort = "COM4",
    [string]$ExpectedPnpDeviceId = "",
    [string]$PeerIp = "",
    [string]$SenderIp = "192.168.50.10",
    [string]$ReceiverIp = "192.168.50.20",
    [ValidateRange(5, 120)]
    [int]$ProcessTimeoutSeconds = 30,
    # Phase A (this session): where a fresh candidate manifest is written during
    # -BuildOnly / default build-only mode. Not an accepted authority (B-13).
    [string]$CandidateManifestPath = "",
    # Phase B (future, never used this session): the ONLY accepted way to name an
    # externally-reviewed manifest authority. Both are required together and never
    # default from current repository state (B-10) -- the runner must not compute
    # "the manifest's current hash" and adopt that as its own expectation.
    [string]$ReviewedManifestPath = "",
    [string]$ExpectedReviewedManifestSha256 = ""
)

# DG-A runner (Mode 17, USB_FIXED10_UDP_TX_RX_POLL_EMPTY). New, additive file.
# Does not modify tools/usb_lan_gate_c1_runner.ps1 or tools/usb_lan_gate_c2_runner.ps1;
# both are reused by copy-adapt only. See docs/usb-lan-gate-dg-a-contract.md for the
# canonical requirements this file implements (four-layer PASS contract, fail-closed
# classification, Phase A/Phase B manifest split, unconditional evidence teardown).
#
# What this session actually invokes: -RunOfflineTests and the default build-only
# path (Phase A candidate consistency + arduino-cli compile, no upload) and
# -PreflightPhysicalTrial -EmitPlan (planning text only). -RunPhysicalTrial and the
# live physical preflight path below are implemented as real source but are never
# invoked this session -- see the top-level dispatch at the bottom of this file.

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$matrixScript = Join-Path $PSScriptRoot "usb_lan_gate_dg_a_build_matrix.ps1"
$peerScript = Join-Path $PSScriptRoot "usb_lan_gate_dg_a_peer.py"
$runRoot = Join-Path $repoRoot "build-temp\usb-lan-isolation\gate-dg-a"
$defaultCandidateManifest = Join-Path $repoRoot "build-temp\usb-lan-isolation\review\DG-A-reviewed-source-manifest.csv"
$candidateManifest = if ([string]::IsNullOrWhiteSpace($CandidateManifestPath)) { $defaultCandidateManifest } else { $CandidateManifestPath }
$fqbn = "m5stack:esp32:m5stack_cores3"
$expectedBranch = "feat/cores3se-dualsense-lan-stack-diagnostic"
$expectedHead = "f915b1c9a33693a2010a1d9527b23743707cfa5d"
$expectedEsp32CoreVersion = "3.3.7"
$fixedSenderIp = "192.168.50.10"
# B-24: the C1/C2-accepted physical PC peer Ethernet identity. DG-A is a
# one-variable trial on top of the C1-accepted physical topology, so the PC
# peer address is a fixed condition, not an arbitrary same-subnet parameter --
# see docs/usb-lan-gate-dg-a-contract.md, "Fixed conditions."
$fixedPeerIp = "192.168.50.30"
$durationSeconds = if ($Trial -eq "DG-A-S1") { 10 } else { 60 }
$caseName = if ($Trial -eq "DG-A-S1") { "mode17-fixed10-udp-tx-rx-poll-empty-10s" } else { "mode17-fixed10-udp-tx-rx-poll-empty-60s" }
$externalResultTimeoutSeconds = $durationSeconds + $ProcessTimeoutSeconds + 60
$startedProcesses = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$startedJobs = [System.Collections.Generic.List[System.Management.Automation.Job]]::new()

# ---------------------------------------------------------------------------
# Generic helpers, reused by copy-adapt from tools/usb_lan_gate_c1_runner.ps1
# (donor-hash-verified in the implementation plan, B-12). Unmodified in shape.
# ---------------------------------------------------------------------------

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-TextSha256([string]$Text) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-ReviewedDirectoryInventory([string]$Root) {
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (!(Test-Path -LiteralPath $rootFull -PathType Container)) {
        throw "BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH missing_inventory_root=$rootFull"
    }
    $extensions = @('.h','.hpp','.c','.cpp','.cc','.s','.properties','.json')
    $entries = @(Get-ChildItem -LiteralPath $rootFull -Recurse -File | ForEach-Object {
        if ($extensions -contains $_.Extension.ToLowerInvariant()) {
            [pscustomobject]@{
                RelativePath = $_.FullName.Substring($rootFull.Length).TrimStart('\').Replace('\','/')
                Size = $_.Length
                Sha256 = Get-Sha256 $_.FullName
            }
        }
    } | Sort-Object RelativePath)
    if ($entries.Count -eq 0) {
        throw "BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH empty_inventory_root=$rootFull"
    }
    $lines = @('relative_path|size|sha256')
    foreach ($entry in $entries) {
        $lines += "$($entry.RelativePath)|$($entry.Size)|$($entry.Sha256)"
    }
    $content = ($lines -join "`n") + "`n"
    return [pscustomobject]@{ Content=$content; Sha256=Get-TextSha256 $content; Files=$entries.Count }
}

function Assert-ChildPath([string]$Parent, [string]$Child) {
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $childFull = [IO.Path]::GetFullPath($Child)
    if (!$childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes runner output root: $childFull"
    }
}

function Quote-ProcessArgument([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Start-OwnedProcess(
    [string]$FilePath,
    [string[]]$ArgumentList,
    [string]$StdoutPath,
    [string]$StderrPath
) {
    $arguments = ($ArgumentList | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
    $process = Start-Process -FilePath $FilePath -ArgumentList $arguments -PassThru `
        -WindowStyle Hidden -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath
    try {
        $null = $process.Handle
    } catch {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "BLOCKED_PROCESS_HANDLE_ACQUISITION file=$FilePath PID=$($process.Id)"
    }
    $startedProcesses.Add($process)
    return $process
}

function Wait-OwnedProcess(
    [System.Diagnostics.Process]$Process,
    [int]$TimeoutSeconds,
    [string]$Purpose,
    [switch]$AllowNonZero
) {
    if (!$Process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        throw "$Purpose timed out after $TimeoutSeconds seconds (PID=$($Process.Id))."
    }
    $Process.WaitForExit()
    $exitCode = $Process.ExitCode
    if ($null -eq $exitCode) {
        throw "BLOCKED_PROCESS_EXITCODE_UNAVAILABLE purpose=$Purpose PID=$($Process.Id)"
    }
    if (!$AllowNonZero -and $exitCode -ne 0) {
        throw "$Purpose failed with exit code $exitCode (PID=$($Process.Id))."
    }
    return [int]$exitCode
}

function Get-Ipv4Bytes([string]$Address) {
    $parsed = [Net.IPAddress]::Parse($Address)
    if ($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw "IPv4 address required: $Address"
    }
    return $parsed.GetAddressBytes()
}

function ConvertTo-Ipv4UInt32([string]$Address) {
    $bytes = Get-Ipv4Bytes $Address
    return ([uint32]$bytes[0] -shl 24) -bor ([uint32]$bytes[1] -shl 16) -bor `
        ([uint32]$bytes[2] -shl 8) -bor [uint32]$bytes[3]
}

function Get-PrefixMask([int]$PrefixLength) {
    if ($PrefixLength -eq 0) { return [uint32]0 }
    $shifted = ([uint64][uint32]::MaxValue) -shl (32 - $PrefixLength)
    return [uint32]($shifted -band [uint64][uint32]::MaxValue)
}

function Assert-SafePeerAddressCore(
    [string]$Address,
    [string]$DeviceAddress,
    [string]$PhysicalReceiverAddress,
    [int]$PrefixLength,
    [bool]$IsLocalInterface,
    [bool]$IsInterfaceUp
) {
    if ($DeviceAddress -cne $fixedSenderIp) {
        throw "Sender IP must equal the fixed firmware address $fixedSenderIp."
    }
    $peerBytes = Get-Ipv4Bytes $Address
    if ($peerBytes[0] -ge 224 -and $peerBytes[0] -le 239) {
        throw "Peer IP must not be multicast: $Address"
    }
    if ($Address -eq "255.255.255.255") { throw "Peer IP must not be broadcast." }
    if ($Address -eq $DeviceAddress) { throw "Peer IP must not equal Sender IP." }
    if ($Address -eq $PhysicalReceiverAddress) {
        throw "Peer IP must not equal the physical Receiver IP."
    }
    if (!$IsLocalInterface) { throw "Peer IP must identify exactly one PC IPv4 interface: $Address" }
    if (!$IsInterfaceUp) { throw "Peer network interface is not Up: $Address" }
    $mask = Get-PrefixMask 24
    $peerValue = ConvertTo-Ipv4UInt32 $Address
    $senderValue = ConvertTo-Ipv4UInt32 $DeviceAddress
    if (($peerValue -band $mask) -ne ($senderValue -band $mask)) {
        throw "Peer and Sender are not in the same IPv4 subnet."
    }
    $network = $peerValue -band $mask
    $broadcast = $network -bor ([uint32]::MaxValue -bxor $mask)
    if ($peerValue -eq $network -or $peerValue -eq $broadcast) {
        throw "Peer IP is a subnet network/broadcast address."
    }
}

function Assert-SafePeerAddress(
    [string]$Address,
    [string]$DeviceAddress,
    [string]$PhysicalReceiverAddress
) {
    try {
        $interfaceAddress = @(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $Address -ErrorAction Stop)
    } catch {
        throw "BLOCKED_PC_NETWORK_PREFLIGHT Peer IP is not assigned to a PC IPv4 interface: $Address"
    }
    if ($interfaceAddress.Count -ne 1) {
        throw "Peer IP must identify exactly one PC IPv4 interface: $Address"
    }
    try {
        $adapter = Get-NetAdapter -InterfaceIndex $interfaceAddress[0].InterfaceIndex -ErrorAction Stop
    } catch {
        throw "BLOCKED_PC_NETWORK_PREFLIGHT adapter lookup failed for Peer IP: $Address"
    }
    Assert-SafePeerAddressCore $Address $DeviceAddress $PhysicalReceiverAddress `
        ([int]$interfaceAddress[0].PrefixLength) $true ($adapter.Status -eq "Up")
    return $interfaceAddress[0]
}

# B-24: the PC peer address is a fixed physical condition (192.168.50.30,
# reused unchanged from the C1/C2-accepted topology), not an arbitrary
# same-subnet parameter -- exact-value identity, checked independently of and
# in addition to the existing same-subnet/interface safety validation in
# Assert-SafePeerAddress.
function Assert-DgAPeerIpIdentity([string]$CandidatePeerIp) {
    if ($CandidatePeerIp -cne $fixedPeerIp) {
        throw "BLOCKED_DG_A_PEER_IP_IDENTITY_MISMATCH expected=$fixedPeerIp actual=$CandidatePeerIp"
    }
}

function Get-ComIdentityRecords {
    $records = @()
    foreach ($entity in @(Get-CimInstance Win32_PnPEntity)) {
        $nameMatch = [regex]::Match([string]$entity.Name, '\((COM[0-9]+)\)$')
        if ($nameMatch.Success) {
            $records += [pscustomobject]@{
                PortName = $nameMatch.Groups[1].Value
                PnpDeviceId = [string]$entity.PNPDeviceID
                Name = [string]$entity.Name
            }
        }
    }
    return $records
}

function Assert-PreUploadCom4Identity([string]$ExpectedIdentity) {
    if ([string]::IsNullOrWhiteSpace($ExpectedIdentity)) {
        throw "-ExpectedPnpDeviceId is required for a physical trial."
    }
    $identityCandidates = @(Get-ComIdentityRecords | Where-Object {
        $_.PortName -ceq "COM4" -and $_.PnpDeviceId -ceq $ExpectedIdentity
    })
    if ($identityCandidates.Count -ne 1) {
        throw "COM4 must resolve to exactly one exact PNPDeviceID before upload."
    }
    Write-Output "COM4_IDENTITY_OK=1 PNPDeviceID=$ExpectedIdentity"
    Write-Output "COM3_ACCESS=PROHIBITED_AND_NOT_PERFORMED"
}

function Wait-ComIdentityReenumeration(
    [string]$ExpectedIdentity,
    [scriptblock]$Resolver,
    [int]$TimeoutMilliseconds = 15000,
    [int]$PollMilliseconds = 100,
    [scriptblock]$Sleeper = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
) {
    $attempts = [Math]::Floor($TimeoutMilliseconds / $PollMilliseconds) + 1
    for ($attempt = 0; $attempt -lt $attempts; $attempt++) {
        $reenumerationCandidates = @(& $Resolver | Where-Object {
            $_.PnpDeviceId -ceq $ExpectedIdentity -and
            [regex]::IsMatch([string]$_.PortName, '^COM[0-9]+$') -and $_.PortName -cne 'COM3'
        })
        if ($reenumerationCandidates.Count -eq 1) { return $reenumerationCandidates[0] }
        if ($reenumerationCandidates.Count -gt 1) { throw "Ambiguous reenumeration for exact PNPDeviceID." }
        if ($attempt + 1 -lt $attempts) { & $Sleeper $PollMilliseconds }
    }
    throw "BLOCKED_COM4_REENUMERATION"
}

function Resolve-ManifestPath([string]$ManifestFile, [string]$Value) {
    if ([IO.Path]::IsPathRooted($Value)) { return [IO.Path]::GetFullPath($Value) }
    $manifestDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($ManifestFile))
    return [IO.Path]::GetFullPath((Join-Path $manifestDirectory $Value))
}

function Assert-GitBaseline {
    $branch = (& git -C $repoRoot branch --show-current 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $branch -cne $expectedBranch) {
        throw "BLOCKED_GIT_BASELINE_MISMATCH branch=$branch"
    }
    $head = (& git -C $repoRoot rev-parse HEAD 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -cne $expectedHead) {
        throw "BLOCKED_GIT_BASELINE_MISMATCH head=$head"
    }
    Write-Output "GIT_BASELINE=PASS BRANCH=$branch HEAD=$head"
}

function Assert-ToolchainIdentity {
    $cliVersion = (& arduino-cli version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($cliVersion)) {
        throw "BLOCKED_TOOLCHAIN_IDENTITY_MISMATCH arduino_cli"
    }
    $arduinoData = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Arduino15'
    $corePath = Join-Path $arduinoData "packages\m5stack\hardware\esp32\$expectedEsp32CoreVersion"
    $platformFile = Join-Path $corePath 'platform.txt'
    if (!(Test-Path -LiteralPath $platformFile -PathType Leaf)) {
        throw "BLOCKED_TOOLCHAIN_IDENTITY_MISMATCH missing_core_path=$corePath"
    }
    $platformText = Get-Content -LiteralPath $platformFile -Raw
    if ($platformText -notmatch "(?m)^version=$([regex]::Escape($expectedEsp32CoreVersion))\s*$") {
        throw "BLOCKED_TOOLCHAIN_IDENTITY_MISMATCH expected=m5stack:esp32@$expectedEsp32CoreVersion path=$corePath"
    }
    Write-Output "ARDUINO_CLI_IDENTITY=PASS VERSION=$($cliVersion -replace '\s+',' ')"
    Write-Output "M5STACK_ESP32_CORE_IDENTITY=PASS CORE=m5stack:esp32 VERSION=$expectedEsp32CoreVersion PATH=$corePath"
}

function Get-KeyValue([string]$Text, [string]$Key) {
    $matches = [regex]::Matches($Text, "(?m)(?:^|\s)$([regex]::Escape($Key))=([^\s]+)")
    if ($matches.Count -eq 0) { return $null }
    return $matches[$matches.Count - 1].Groups[1].Value
}

# ---------------------------------------------------------------------------
# B-13: Phase A candidate identity CONSISTENCY (this session only). Not an
# authority check -- proves the build did not silently alter source/dependency
# bytes. Reuses the same file/row set the C2-accepted manifest uses (donor-hash-
# verified, B-12): the DG-A source files plus the carried-forward M5-Ethernet /
# USB Host Shield / CoreProtocol / M5Unified+M5GFX recursive-inventory rows.
# ---------------------------------------------------------------------------

function Get-DgACandidateFileSet {
    return [ordered]@{
        diagnostic_source = Join-Path $repoRoot "M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"
        dg_a_peer = Join-Path $repoRoot "tools\usb_lan_gate_dg_a_peer.py"
        dg_a_runner = Join-Path $repoRoot "tools\usb_lan_gate_dg_a_runner.ps1"
        dg_a_build_matrix = Join-Path $repoRoot "tools\usb_lan_gate_dg_a_build_matrix.ps1"
        dg_a_contract = Join-Path $repoRoot "docs\usb-lan-gate-dg-a-contract.md"
        m5_ethernet_public_header = Join-Path $repoRoot "build-temp\usb-lan-isolation\libraries\M5-Ethernet\src\M5_Ethernet.h"
        m5_ethernet_core = Join-Path $repoRoot "build-temp\usb-lan-isolation\libraries\M5-Ethernet\src\M5_Ethernet.cpp"
        m5_ethernet_udp = Join-Path $repoRoot "build-temp\usb-lan-isolation\libraries\M5-Ethernet\src\EthernetUdp.cpp"
        m5_ethernet_w5100_header = Join-Path $repoRoot "build-temp\usb-lan-isolation\libraries\M5-Ethernet\src\utility\w5100.h"
        m5_ethernet_w5100_core = Join-Path $repoRoot "build-temp\usb-lan-isolation\libraries\M5-Ethernet\src\utility\w5100.cpp"
        m5_ethernet_socket = Join-Path $repoRoot "build-temp\usb-lan-isolation\libraries\M5-Ethernet\src\socket.cpp"
        m5_ethernet_metadata_4_0_0 = Join-Path $repoRoot "build-temp\usb-lan-isolation\libraries\M5-Ethernet\library.properties"
        uhs_include_root = Join-Path $repoRoot "build-temp\usb-lan-isolation\libraries\USB_Host_Shield_Library_2.0\Usb.h"
        uhs_usb_core_api = Join-Path $repoRoot "build-temp\usb-lan-isolation\libraries\USB_Host_Shield_Library_2.0\UsbCore.h"
        uhs_max3421e_spi = Join-Path $repoRoot "build-temp\usb-lan-isolation\libraries\USB_Host_Shield_Library_2.0\usbhost.h"
        uhs_usb_task_implementation = Join-Path $repoRoot "build-temp\usb-lan-isolation\libraries\USB_Host_Shield_Library_2.0\Usb.cpp"
        uhs_spi_platform_selection = Join-Path $repoRoot "build-temp\usb-lan-isolation\libraries\USB_Host_Shield_Library_2.0\settings.h"
        uhs_hid_universal_api = Join-Path $repoRoot "build-temp\usb-lan-isolation\libraries\USB_Host_Shield_Library_2.0\hiduniversal.h"
        uhs_hid_report_path = Join-Path $repoRoot "build-temp\usb-lan-isolation\libraries\USB_Host_Shield_Library_2.0\hiduniversal.cpp"
        core_protocol_header = Join-Path $repoRoot "src\core_protocol\CoreProtocol.h"
        core_protocol_implementation = Join-Path $repoRoot "src\core_protocol\CoreProtocol.cpp"
    }
}

function Get-DgACandidateInventoryRoots {
    return [ordered]@{
        m5unified_recursive_inventory = Join-Path $repoRoot "build-temp\usb-lan-isolation\libraries\M5Unified"
        m5gfx_recursive_inventory = Join-Path $repoRoot "build-temp\usb-lan-isolation\libraries\M5GFX"
    }
}

function Get-DgACandidateSnapshot {
    $snapshot = [ordered]@{}
    foreach ($entry in (Get-DgACandidateFileSet).GetEnumerator()) {
        if (!(Test-Path -LiteralPath $entry.Value)) {
            throw "BLOCKED_CANDIDATE_SOURCE_IDENTITY_CHANGED_DURING_BUILD missing=$($entry.Value)"
        }
        $item = Get-Item -LiteralPath $entry.Value
        $snapshot[$entry.Key] = [pscustomobject]@{
            Path = $entry.Value; Size = $item.Length; Sha256 = Get-Sha256 $entry.Value; InventoryRoot = ""
        }
    }
    foreach ($entry in (Get-DgACandidateInventoryRoots).GetEnumerator()) {
        $inventory = Get-ReviewedDirectoryInventory $entry.Value
        $snapshot[$entry.Key] = [pscustomobject]@{
            Path = $entry.Value; Size = $inventory.Files; Sha256 = $inventory.Sha256; InventoryRoot = $entry.Value
        }
    }
    return $snapshot
}

function Assert-DgACandidateConsistency($PreSnapshot, $PostSnapshot) {
    $mismatches = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $PreSnapshot.Keys) {
        $pre = $PreSnapshot[$key]
        $post = $PostSnapshot[$key]
        if ($null -eq $post -or $pre.Size -ne $post.Size -or $pre.Sha256 -cne $post.Sha256) {
            $mismatches.Add($key)
        }
    }
    if ($mismatches.Count -gt 0) {
        throw "BLOCKED_CANDIDATE_SOURCE_IDENTITY_CHANGED_DURING_BUILD roles=$($mismatches -join ',')"
    }
    Write-Output "CANDIDATE_IDENTITY_CONSISTENCY=PASS FILES=$($PreSnapshot.Count)"
}

function New-DgACandidateManifest($Snapshot, [string]$OutputPath) {
    $rows = @()
    foreach ($entry in $Snapshot.GetEnumerator()) {
        $rows += [pscustomobject]@{
            relative_or_absolute_path = $entry.Value.Path
            size = $entry.Value.Size
            sha256 = $entry.Value.Sha256
            role = $entry.Key
            inventory_root = $entry.Value.InventoryRoot
        }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
    $rows | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8
    $manifestSha256 = Get-Sha256 $OutputPath
    # N-07: the manifest's own hash is recorded as separate sibling evidence, not a
    # row inside the manifest it describes -- no self-reference either direction.
    $shaSidecar = "$OutputPath.sha256.txt"
    [IO.File]::WriteAllText($shaSidecar, "$manifestSha256`n", [Text.UTF8Encoding]::new($false))
    Write-Output "CANDIDATE_MANIFEST_WRITTEN=1 PATH=$OutputPath ROWS=$($rows.Count)"
    Write-Output "PROPOSED_EXPECTED_REVIEWED_MANIFEST_SHA256=$manifestSha256"
    return [pscustomobject]@{ Path=$OutputPath; Sha256Sidecar=$shaSidecar; Sha256=$manifestSha256 }
}

# ---------------------------------------------------------------------------
# B-10/B-13 Phase B: post-external-review manifest AUTHORITY verification.
# Never exercised this session (no externally accepted authority exists yet
# for DG-A) -- implemented as real source only for a future, separately
# authorized physical task. Two-level: Step A (manifest's own hash vs. an
# externally supplied expected hash) before Step B (listed content vs. actual
# bytes) -- the runner never self-derives Step A's expectation.
# ---------------------------------------------------------------------------

function Assert-ReviewedManifestAuthority([string]$ManifestFile, [string]$ExpectedManifestSha256) {
    if ([string]::IsNullOrWhiteSpace($ExpectedManifestSha256)) {
        throw "-ExpectedReviewedManifestSha256 is required for Phase B verification; it must come from external review, never be self-derived."
    }
    if (!(Test-Path -LiteralPath $ManifestFile)) {
        throw "BLOCKED_REVIEWED_MANIFEST_IDENTITY_MISMATCH missing_manifest=$ManifestFile"
    }
    # Step A: manifest file's own identity, against the externally supplied hash.
    $actualManifestSha256 = Get-Sha256 $ManifestFile
    if ($actualManifestSha256 -cne $ExpectedManifestSha256) {
        throw "BLOCKED_REVIEWED_MANIFEST_IDENTITY_MISMATCH expected=$ExpectedManifestSha256 actual=$actualManifestSha256"
    }
    Write-Output "REVIEWED_MANIFEST_IDENTITY=PASS MANIFEST=$ManifestFile SHA256=$actualManifestSha256"
    # Step B: only reached once Step A has passed -- listed content vs. actual bytes.
    $rows = @(Import-Csv -LiteralPath $ManifestFile)
    if ($rows.Count -eq 0) { throw "BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH empty_manifest" }
    foreach ($row in $rows) {
        $path = Resolve-ManifestPath $ManifestFile $row.relative_or_absolute_path
        if (!(Test-Path -LiteralPath $path)) {
            throw "BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH missing=$path"
        }
        if (![string]::IsNullOrWhiteSpace($row.inventory_root)) {
            $inventory = Get-ReviewedDirectoryInventory $row.inventory_root
            if ($inventory.Sha256 -cne $row.sha256) {
                throw "BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH role=$($row.role) inventory_root=$($row.inventory_root)"
            }
            continue
        }
        $item = Get-Item -LiteralPath $path
        $actualHash = Get-Sha256 $path
        if ($item.Length -ne [int64]$row.size -or $actualHash -cne $row.sha256) {
            throw "BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH role=$($row.role) path=$path"
        }
    }
    Write-Output "REVIEWED_SOURCE_IDENTITY=PASS FILES=$($rows.Count) MANIFEST=$ManifestFile"
}

# ---------------------------------------------------------------------------
# DG-A-specific: three-state peer admission handshake (arm-file / armed-file),
# copy-adapted from tools/usb_lan_gate_c2_runner.ps1's New-C2ArmRequest /
# Wait-C2ArmedAcknowledgement (donor-hash-verified, B-12).
# ---------------------------------------------------------------------------

function New-DgAArmRequest([string]$ArmFile) {
    if (Test-Path -LiteralPath $ArmFile) { throw "Arm-file already exists before request: $ArmFile" }
    [IO.File]::WriteAllText($ArmFile, "ARM=1`n", [Text.UTF8Encoding]::new($false))
    Write-Output "DG_A_ARM_REQUESTED=1 FILE=$ArmFile"
}

function Wait-DgAArmedAcknowledgement(
    [string]$ArmedFile,
    [string]$PeerLogPath,
    [int]$TimeoutSeconds = 10
) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path -LiteralPath $ArmedFile) {
            $peerText = if (Test-Path -LiteralPath $PeerLogPath) {
                Get-Content -LiteralPath $PeerLogPath -Raw -ErrorAction SilentlyContinue
            } else { "" }
            if ($peerText -match '(?m)^PEER_ARMED=1\s*$') {
                Write-Output "DG_A_ARMED_ACKNOWLEDGED=1 FILE=$ArmedFile"
                return
            }
        }
        Start-Sleep -Milliseconds 100
    }
    throw "ORCHESTRATION_STALL/TIMEOUT purpose=peer_arm_handshake budget_seconds=$TimeoutSeconds"
}

# ---------------------------------------------------------------------------
# Layer 2 (serial/parser), Layer 3 (peer), Layer 4 (cross-reconciliation), and
# the fail-closed classifier (B-07/B-11/B-14/B-15/B-16/B-17).
#
# B-16 evidence authority: DG_A_DIAG is periodic and informational only, never
# final adjudication authority. A normal runtime trial's only authority lines are
# exactly one DG_A_FINAL line (final statistics, dgAPrintStatistics()) and exactly
# one TEST_COMPLETE line (terminal/health/identity, dgAFinish()). A setup/pre-trial
# failure trial instead has exactly one DG_A_SETUP_FAIL=1 line and exactly one
# (sparser) TEST_COMPLETE line, and never has a DG_A_FINAL line -- dgAFailSetup()
# never calls dgAPrintStatistics(). Both schemas were read-only-inventoried from
# the actual firmware source (M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino), not
# invented; firmware itself is not modified by this remediation.
# ---------------------------------------------------------------------------

# Parsing never throws: malformed/missing/duplicated required evidence becomes
# EvidenceContractValid=false, not a PowerShell exception that could abort the
# runner before a classification is produced (B-17).
function ConvertTo-DgADecimalOrNull([string]$Value) {
    if ($null -eq $Value -or $Value -notmatch '^[0-9]+$') { return $null }
    try { return [uint64]$Value } catch { return $null }
}

function ConvertTo-DgAHexByteOrNull([string]$Value) {
    if ($null -eq $Value -or $Value -notmatch '^[0-9A-Fa-f]{1,2}$') { return $null }
    try { return [Convert]::ToUInt64($Value, 16) } catch { return $null }
}

# B-23: 16-bit hex field (VID/PID's %04X format) -- 1-4 hex digits only.
function ConvertTo-DgAHex16OrNull([string]$Value) {
    if ($null -eq $Value -or $Value -notmatch '^[0-9A-Fa-f]{1,4}$') { return $null }
    try { return [Convert]::ToUInt64($Value, 16) } catch { return $null }
}

# Returns $null unless Key appears exactly once on Line -- duplicate-on-line
# detection, so a duplicated required key on the same authority line is treated
# as malformed evidence rather than silently taking one of the two values.
function Get-DgALineFieldStrict([string]$Line, [string]$Key) {
    if ([string]::IsNullOrEmpty($Line)) { return $null }
    $lineMatches = [regex]::Matches($Line, "(?:^|\s)$([regex]::Escape($Key))=([^\s]+)")
    if ($lineMatches.Count -ne 1) { return $null }
    return $lineMatches[0].Groups[1].Value
}

# Read-only-inventoried from every dgAFailSetup(...) call site in the diagnostic
# source. Informational only -- used to recognize the setup-failure schema, not
# to add new per-reason classification granularity.
$dgAKnownSetupFailureReasons = @(
    'W5100_INIT','CHIP_ID','VERSIONR','BUFFER_MAP_INIT','PHY_PROFILE',
    'PHY_PROFILE_READBACK','BUFFER_MAP_FIXED10','NETWORK_CONFIG',
    'PHY_AFTER_NETWORK_CONFIG','BUFFER_MAP_NETWORK_CONFIG','LINK_PROFILE_CHANGED',
    'LINK_TIMEOUT','UDP_BEGIN','UDP_SOCKET','PHY_AFTER_UDP_BEGIN',
    'BUFFER_MAP_UDP_BEGIN','VERSION_AFTER_UDP_BEGIN','BUFFER_MAP_USB_INIT',
    'USB_INIT','PHY_DURING_USB_STABILITY','HORI_READY'
)

# B-21: exact normal-runtime REASON vocabulary, read-only-inventoried from every
# dgAFinish(...) call site in the diagnostic source (distinct from
# $dgAKnownSetupFailureReasons, which covers dgAFailSetup()'s separate call sites).
# DURATION_COMPLETE is the only reason semantically consistent with
# TEST_COMPLETE=PASS (B-21 2.2); the rest are FAIL-path reasons already handled by
# the classifier's explicit named-reason checks or the measured-hard-criterion tier.
$dgANormalRuntimeKnownReasons = @(
    'DURATION_COMPLETE','USB_DETACH_OR_UNSUPPORTED','HID_STALL',
    'MAX_REGISTER_MISMATCH','LINK_OR_PHY_CHANGED',
    'BLOCKED_DG_A_UNEXPECTED_RX_ACTIVITY','DG_A_RX_POLL_API_FAIL'
)

# B-23: the fixed DG-A USB target identity (HORI PAD TURBO), required exactly on
# normal-schema evidence -- a wrong-but-parseable VID/PID is an identity/evidence
# problem, never classified as a peer or PHY failure.
$dgAExpectedVid = 0x0F0D
$dgAExpectedPid = 0x0202

# DG_A_FINAL-only fields (dgAPrintStatistics()) -- decimal, read ONLY from a line
# starting with "DG_A_FINAL ", never from "DG_A_DIAG " (same field names, printed
# periodically, informational only) and never as a whole-text last-match lookup.
# HID_STALL_COUNT/HID_MAX_NO_REPORT_MS are deliberately excluded here -- the
# firmware prints both on this line AND on TEST_COMPLETE (B-18 5), so they are
# handled as dual-authority fields below rather than by this generic loop, to
# avoid one silently overwriting the other in a single shared dictionary key.
$dgAFinalRequiredFields = @(
    'UDP_TX_TOTAL','UDP_TX_FAIL','UDP_BEGIN_COUNT','UDP_BEGIN_FAIL',
    'UDP_BEGIN_MAX_US','UDP_BEGIN_PACKET_MAX_US','UDP_WRITE_MAX_US',
    'UDP_END_PACKET_MAX_US','UDP_MAX_GAP_US','SCHEDULER_MISSED_DEADLINE',
    'SCHEDULER_MAX_LATENESS_US','LOOP_MAX_US',
    'RX_POLL_CALL_TOTAL','RX_POLL_POSITIVE_TOTAL',
    'RX_POLL_NEGATIVE_ERROR','RX_READ_CALL_TOTAL','RX_READ_BYTES_TOTAL',
    'RX_POLL_MAX_US'
)

# TEST_COMPLETE-only decimal fields for the normal runtime schema (dgAFinish()'s
# longer terminal line). FINAL_USB_STATE/VERSIONR (hex), REASON, and the dual-
# authority HID_STALL_COUNT/HID_MAX_NO_REPORT_MS pair are handled separately below.
$dgATerminalDecimalFields = @(
    'DURATION_MS','TRIAL_RUNTIME_MS','FINAL_HID_READY','HID_READY_DROP',
    'HID_REPORT_TOTAL','FINAL_PHY_OK',
    'FINAL_VERSION_OK','FINAL_BUFFER_MAP_OK','MAX_REGISTER_TRIPLE_READ_MISMATCH',
    'SPI_CORRUPTION_SUSPECTED'
)

# Dual-authority fields: printed on both DG_A_FINAL and TEST_COMPLETE from the
# same underlying firmware counters (dgA.hidStallCount / the no-report-ms max).
# Required on both lines and required to agree (B-18 5) -- never silently
# resolved to whichever line's value happens to be parsed last.
$dgADualAuthorityFields = @('HID_STALL_COUNT','HID_MAX_NO_REPORT_MS')

# The setup-failure schema's sparser TEST_COMPLETE line (dgAFailSetup()) only
# carries these two decimal fields besides identity/REASON/FINAL_USB_STATE.
$dgASetupTerminalDecimalFields = @('FINAL_HID_READY','HID_READY_DROP')

function Test-DgASerialLog([string]$Text) {
    $setupFailLines = @([regex]::Matches($Text, '(?m)^DG_A_SETUP_FAIL=1.*$'))
    $finalLines = @([regex]::Matches($Text, '(?m)^DG_A_FINAL\s.*$'))
    $terminalLines = @([regex]::Matches($Text, '(?m)^.*TEST_COMPLETE=(?:PASS|FAIL).*$'))
    $terminalLine = if ($terminalLines.Count -gt 0) { $terminalLines[-1].Value } else { "" }

    $noEvidence = ($setupFailLines.Count -eq 0) -and ($finalLines.Count -eq 0) -and ($terminalLines.Count -eq 0)
    $isSetupFailureSchema = ($setupFailLines.Count -eq 1) -and ($terminalLines.Count -eq 1) -and ($finalLines.Count -eq 0)
    $isNormalSchema = ($setupFailLines.Count -eq 0) -and ($finalLines.Count -eq 1) -and ($terminalLines.Count -eq 1)

    $missing = [System.Collections.Generic.List[string]]::new()
    $fields = @{}
    $testMode = Get-DgALineFieldStrict $terminalLine 'TEST_MODE'
    $testModeName = Get-DgALineFieldStrict $terminalLine 'TEST_MODE_NAME'
    $modeIdentityOk = ($testMode -ceq '17') -and ($testModeName -ceq 'USB_FIXED10_UDP_TX_RX_POLL_EMPTY')
    $completion = Get-DgALineFieldStrict $terminalLine 'TEST_COMPLETE'
    $reason = Get-DgALineFieldStrict $terminalLine 'REASON'

    $evidenceContractValid = $false
    $hardCriteriaPass = $false
    $schema = 'Invalid'

    if ($isSetupFailureSchema) {
        $schema = 'SetupFailure'
        $setupReason = Get-DgALineFieldStrict $setupFailLines[0].Value 'REASON'
        if ($null -eq $setupReason) { $missing.Add('DG_A_SETUP_FAIL.REASON') }
        foreach ($key in $dgASetupTerminalDecimalFields) {
            $value = ConvertTo-DgADecimalOrNull (Get-DgALineFieldStrict $terminalLine $key)
            if ($null -eq $value) { $missing.Add("TEST_COMPLETE.$key") } else { $fields[$key] = $value }
        }
        $finalUsbStateValue = ConvertTo-DgAHexByteOrNull (Get-DgALineFieldStrict $terminalLine 'FINAL_USB_STATE')
        if ($null -eq $finalUsbStateValue) { $missing.Add('TEST_COMPLETE.FINAL_USB_STATE') } else { $fields['FINAL_USB_STATE'] = $finalUsbStateValue }
        if ($null -eq $completion) { $missing.Add('TEST_COMPLETE') }
        if ($null -eq $reason -or $null -eq $setupReason -or $setupReason -cne $reason) { $missing.Add('SETUP_REASON_CONSISTENCY') }
        # B-21 2.4: the setup REASON must belong to the exact source-inventoried
        # vocabulary -- DG_A_SETUP_FAIL/TEST_COMPLETE agreeing with each other is
        # not sufficient if neither matches any reason dgAFailSetup() can actually
        # emit (e.g. a corrupted or unexpected token on both lines identically).
        if ($null -ne $setupReason -and $dgAKnownSetupFailureReasons -notcontains $setupReason) {
            $missing.Add('DG_A_SETUP_FAIL.REASON_UNKNOWN')
        }
        $evidenceContractValid = $modeIdentityOk -and ($missing.Count -eq 0) -and ($completion -ceq 'FAIL')
        # Setup failure is never PASS by construction; hardCriteriaPass stays false.
    } elseif ($isNormalSchema) {
        $schema = 'Normal'
        $finalLine = $finalLines[0].Value
        foreach ($key in $dgAFinalRequiredFields) {
            $value = ConvertTo-DgADecimalOrNull (Get-DgALineFieldStrict $finalLine $key)
            if ($null -eq $value) { $missing.Add("DG_A_FINAL.$key") } else { $fields[$key] = $value }
        }
        foreach ($key in $dgATerminalDecimalFields) {
            $value = ConvertTo-DgADecimalOrNull (Get-DgALineFieldStrict $terminalLine $key)
            if ($null -eq $value) { $missing.Add("TEST_COMPLETE.$key") } else { $fields[$key] = $value }
        }
        # B-18 5: dual-authority fields must be present on BOTH lines and equal.
        foreach ($dualKey in $dgADualAuthorityFields) {
            $finalValue = ConvertTo-DgADecimalOrNull (Get-DgALineFieldStrict $finalLine $dualKey)
            $terminalValue = ConvertTo-DgADecimalOrNull (Get-DgALineFieldStrict $terminalLine $dualKey)
            if ($null -eq $finalValue) { $missing.Add("DG_A_FINAL.$dualKey") }
            if ($null -eq $terminalValue) { $missing.Add("TEST_COMPLETE.$dualKey") }
            if ($null -ne $finalValue -and $null -ne $terminalValue) {
                if ($finalValue -ne $terminalValue) {
                    $missing.Add("$dualKey.CROSS_AUTHORITY_CONSISTENCY")
                } else {
                    $fields[$dualKey] = $finalValue
                }
            }
        }
        $finalUsbStateValue = ConvertTo-DgAHexByteOrNull (Get-DgALineFieldStrict $terminalLine 'FINAL_USB_STATE')
        if ($null -eq $finalUsbStateValue) { $missing.Add('TEST_COMPLETE.FINAL_USB_STATE') } else { $fields['FINAL_USB_STATE'] = $finalUsbStateValue }
        # B-18 2.4: VERSIONR is a required hex field (typo-free of Revision-1
        # ambiguity between decimal "04" and hex 0x04 -- both read identically
        # here since 0x04 has no letters, but the parser is explicit about it).
        $versionrValue = ConvertTo-DgAHexByteOrNull (Get-DgALineFieldStrict $terminalLine 'VERSIONR')
        if ($null -eq $versionrValue) { $missing.Add('TEST_COMPLETE.VERSIONR') } else { $fields['VERSIONR'] = $versionrValue }
        # B-23: VID/PID are typed as 16-bit hex AND required to equal the exact
        # fixed DG-A USB target identity (HORI PAD TURBO, 0F0D/0202) -- a wrong-but-
        # parseable identity is an evidence/identity contract failure, never a
        # peer/PHY-level classification and never silently accepted as valid.
        $vidValue = ConvertTo-DgAHex16OrNull (Get-DgALineFieldStrict $terminalLine 'VID')
        # $pid is a readonly PowerShell automatic variable (current process ID) --
        # must not be assigned to, hence $pidValue rather than $pid here.
        $pidValue = ConvertTo-DgAHex16OrNull (Get-DgALineFieldStrict $terminalLine 'PID')
        if ($null -eq $vidValue -or $vidValue -ne $dgAExpectedVid) { $missing.Add('TEST_COMPLETE.VID') }
        if ($null -eq $pidValue -or $pidValue -ne $dgAExpectedPid) { $missing.Add('TEST_COMPLETE.PID') }
        if ($null -eq $completion) { $missing.Add('TEST_COMPLETE') }
        # B-18 2.3: REASON is required exactly once on the normal-schema terminal
        # line too (previously only extracted for informational use, not gated).
        if ($null -eq $reason) { $missing.Add('TEST_COMPLETE.REASON') }
        # B-21 2.2: TEST_COMPLETE=PASS is only evidence-consistent with the exact
        # firmware source's normal-completion reason. An unrecognized REASON
        # accompanying PASS is not a logical firmware failure -- it means the
        # terminal evidence itself is semantically inconsistent with the accepted
        # firmware, which is an evidence-contract problem, not a classification
        # to make on faith.
        if ($null -ne $reason -and $completion -ceq 'PASS' -and $reason -cne 'DURATION_COMPLETE') {
            $missing.Add('TEST_COMPLETE.REASON_PASS_SEMANTICS')
        }

        $evidenceContractValid = $modeIdentityOk -and ($missing.Count -eq 0)
        if ($evidenceContractValid) {
            $hardCriteriaPass =
                $fields['UDP_TX_TOTAL'] -gt 0 -and $fields['UDP_TX_FAIL'] -eq 0 -and
                $fields['RX_POLL_CALL_TOTAL'] -gt 0 -and $fields['RX_POLL_POSITIVE_TOTAL'] -eq 0 -and
                $fields['RX_POLL_NEGATIVE_ERROR'] -eq 0 -and $fields['RX_READ_CALL_TOTAL'] -eq 0 -and
                $fields['RX_READ_BYTES_TOTAL'] -eq 0 -and $fields['SCHEDULER_MISSED_DEADLINE'] -eq 0 -and
                $fields['HID_STALL_COUNT'] -eq 0 -and $fields['HID_READY_DROP'] -eq 0 -and
                $fields['FINAL_USB_STATE'] -eq 0x90 -and $fields['FINAL_HID_READY'] -eq 1 -and
                $fields['FINAL_PHY_OK'] -eq 1 -and $fields['FINAL_VERSION_OK'] -eq 1 -and
                $fields['FINAL_BUFFER_MAP_OK'] -eq 1 -and $fields['VERSIONR'] -eq 0x04 -and
                $fields['MAX_REGISTER_TRIPLE_READ_MISMATCH'] -eq 0 -and
                $fields['SPI_CORRUPTION_SUSPECTED'] -eq 0
        }
    }

    return [pscustomobject]@{
        Schema = $schema
        NoEvidence = $noEvidence
        IsSetupFailure = $isSetupFailureSchema
        SetupFailLineCount = $setupFailLines.Count
        FinalLineCount = $finalLines.Count
        TerminalCount = $terminalLines.Count
        TerminalLine = $terminalLine
        TerminalFound = $terminalLines.Count -eq 1
        Completion = $completion
        Reason = $reason
        MissingRequiredFields = @($missing)
        ModeIdentityOk = $modeIdentityOk
        Fields = $fields
        HardCriteriaPass = $hardCriteriaPass
        EvidenceContractValid = $evidenceContractValid
    }
}

# Peer summary decimal fields (tools/usb_lan_gate_dg_a_peer.py's summary_lines(),
# one KEY=VALUE per line).
$dgAPeerRequiredDecimalFields = @(
    'RX_TOTAL','VALID_RX_TOTAL','CRC_ERROR','LENGTH_ERROR','FORMAT_ERROR',
    'PAYLOAD_ERROR','UNEXPECTED_SOURCE','SEQ_GAP','DUPLICATE','OUT_OF_ORDER',
    'FLAGS_ERROR','SOURCE_PORT_ERROR','PEER_COMPLETE','PEER_ARMED',
    'ADMISSION_SEQUENCE_ZERO_OK','BLOCKED_ADMISSION_SEQUENCE_MISS',
    'BOUND_NOT_ARMED_PACKET_COUNT','PRE_ADMISSION_NON_C1_COUNT',
    'PEER_TX_TO_DEVICE_TOTAL'
)
# The fixed peer bind identity this DG-A trial always expects (Config::kC1PeerIp /
# Config::kPort in the firmware, --expected-source-ip/--expected-source-port in the
# peer CLI) -- B-20: EXPECTED_SOURCE_IP/PORT are typed AND checked against this
# exact expected value, not merely required to be present.
$dgAExpectedSourceIp = '192.168.50.10'
$dgAExpectedSourcePort = '50001'
# N-09: closed-world PEER_RESULT vocabulary -- read-only-inventoried from the
# unmodified tools/usb_lan_gate_dg_a_peer.py's actual final-value producers
# (summary_lines()'s PEER_RESULT is one of exactly these three). A value
# outside this set is malformed evidence, not a logical peer failure, so it
# must never reach the PEER_RESULT-vs-'PASS' logical-reason check below.
$dgAPeerResultKnownValues = @('PASS', 'FAIL', 'BLOCKED_ADMISSION_SEQUENCE_MISS')

# Returns $null unless Key appears on exactly one line of the (multi-line) peer
# summary text -- duplicate-field detection across the whole peer output.
function Get-DgAPeerFieldStrict([string]$Text, [string]$Key) {
    $lineMatches = [regex]::Matches($Text, "(?m)^$([regex]::Escape($Key))=([^\s]+)\s*`$")
    if ($lineMatches.Count -ne 1) { return $null }
    return $lineMatches[0].Groups[1].Value
}

# B-22: FIRST_SEQUENCE/LAST_SEQUENCE schema is exactly "decimal uint32 in
# [0, 4294967295]" or the literal string "NONE" -- nothing else is valid evidence.
# True uint32-range validated (not merely "digits only"): "4294967296" and
# "18446744073709551616" are both rejected, the latter without throwing even
# though it overflows uint64 too. Returns a typed object so no later code needs
# an unchecked numeric cast of the raw string.
function ConvertTo-DgAUInt32OrNone([string]$Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -ceq 'NONE') { return [pscustomobject]@{ IsValid = $true; IsNone = $true; Value = $null } }
    if ($Value -notmatch '^[0-9]+$') { return [pscustomobject]@{ IsValid = $false; IsNone = $false; Value = $null } }
    $parsed = [uint64]0
    if (![uint64]::TryParse($Value, [ref]$parsed)) { return [pscustomobject]@{ IsValid = $false; IsNone = $false; Value = $null } }
    if ($parsed -gt [uint32]::MaxValue) { return [pscustomobject]@{ IsValid = $false; IsNone = $false; Value = $null } }
    return [pscustomobject]@{ IsValid = $true; IsNone = $false; Value = [uint32]$parsed }
}

function Test-DgAPeerSummary([string]$Text, [int]$ExitCode) {
    $missing = [System.Collections.Generic.List[string]]::new()
    $fields = @{}
    $strings = @{}
    foreach ($key in $dgAPeerRequiredDecimalFields) {
        $value = ConvertTo-DgADecimalOrNull (Get-DgAPeerFieldStrict $Text $key)
        if ($null -eq $value) { $missing.Add($key) } else { $fields[$key] = $value }
    }
    $firstSequenceRaw = Get-DgAPeerFieldStrict $Text 'FIRST_SEQUENCE'
    $firstSequenceParsed = ConvertTo-DgAUInt32OrNone $firstSequenceRaw
    if ($null -eq $firstSequenceParsed -or !$firstSequenceParsed.IsValid) { $missing.Add('FIRST_SEQUENCE') } else { $strings['FIRST_SEQUENCE'] = $firstSequenceRaw }
    $lastSequenceRaw = Get-DgAPeerFieldStrict $Text 'LAST_SEQUENCE'
    $lastSequenceParsed = ConvertTo-DgAUInt32OrNone $lastSequenceRaw
    if ($null -eq $lastSequenceParsed -or !$lastSequenceParsed.IsValid) { $missing.Add('LAST_SEQUENCE') } else { $strings['LAST_SEQUENCE'] = $lastSequenceRaw }
    # B-20 5.1: EXPECTED_SOURCE_IP -- required exactly once, valid IPv4, exact value.
    $rawIp = Get-DgAPeerFieldStrict $Text 'EXPECTED_SOURCE_IP'
    $ipValid = $false
    if ($null -ne $rawIp) {
        $parsedIp = $null
        $ipValid = [Net.IPAddress]::TryParse($rawIp, [ref]$parsedIp) -and
            $parsedIp.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
            $rawIp -ceq $dgAExpectedSourceIp
    }
    if (!$ipValid) { $missing.Add('EXPECTED_SOURCE_IP') } else { $strings['EXPECTED_SOURCE_IP'] = $rawIp }
    # B-20 5.2: EXPECTED_SOURCE_PORT -- required exactly once, decimal, exact value.
    $rawPort = Get-DgAPeerFieldStrict $Text 'EXPECTED_SOURCE_PORT'
    $portValid = ($null -ne $rawPort) -and ($rawPort -match '^[0-9]+$') -and ($rawPort -ceq $dgAExpectedSourcePort)
    if (!$portValid) { $missing.Add('EXPECTED_SOURCE_PORT') } else { $strings['EXPECTED_SOURCE_PORT'] = $rawPort }
    # N-09: PEER_RESULT is a closed-world enum (read-only-inventoried from the
    # unmodified peer source's only two producers of this field -- the
    # BLOCKED_ADMISSION_SEQUENCE_MISS short-circuit and PASS/FAIL from
    # controller.passed()). A value outside the vocabulary (e.g. "garbage") is
    # malformed evidence -- it must land in $missing (EvidenceContractValid=false)
    # here, never survive to the PEER_RESULT-vs-'PASS' logical-reason check below,
    # which would otherwise misreport it as a logical DG_A_PEER_FAIL.
    $rawPeerResult = Get-DgAPeerFieldStrict $Text 'PEER_RESULT'
    if ($null -eq $rawPeerResult -or $dgAPeerResultKnownValues -notcontains $rawPeerResult) {
        $missing.Add('PEER_RESULT')
    } else {
        $strings['PEER_RESULT'] = $rawPeerResult
    }

    if (!($missing.Count -eq 0)) {
        return [pscustomobject]@{
            Available = $true; EvidenceContractValid = $false; Blocked = $false
            LogicalPass = $false; PeerTxNonzero = $false; Pass = $false
            MissingRequiredFields = @($missing); Reasons = @($missing); Fields = $fields; Strings = $strings
        }
    }
    $blocked = $fields['BLOCKED_ADMISSION_SEQUENCE_MISS'] -eq 1
    $peerTxNonzero = $fields['PEER_TX_TO_DEVICE_TOTAL'] -ne 0
    if ($blocked) {
        return [pscustomobject]@{
            Available = $true; EvidenceContractValid = $true; Blocked = $true
            LogicalPass = $false; PeerTxNonzero = $peerTxNonzero; Pass = $false
            MissingRequiredFields = @(); Reasons = @('BLOCKED_ADMISSION_SEQUENCE_MISS'); Fields = $fields; Strings = $strings
        }
    }
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($fields['PEER_COMPLETE'] -ne 1) { $reasons.Add('PEER_COMPLETE') }
    if ($fields['PEER_ARMED'] -ne 1) { $reasons.Add('PEER_ARMED') }
    if ($fields['ADMISSION_SEQUENCE_ZERO_OK'] -ne 1) { $reasons.Add('ADMISSION_SEQUENCE_ZERO_OK') }
    if ($strings['PEER_RESULT'] -cne 'PASS') { $reasons.Add('PEER_RESULT') }
    if ($fields['VALID_RX_TOTAL'] -eq 0) { $reasons.Add('VALID_RX_TOTAL') }
    # B-22: logical checks use the already-typed parsed values, never a re-cast of
    # the raw string -- by this point EvidenceContractValid is already true, so
    # both parsed objects are guaranteed IsValid.
    $firstSequenceIsZero = (!$firstSequenceParsed.IsNone) -and ($firstSequenceParsed.Value -eq 0)
    if (!$firstSequenceIsZero) { $reasons.Add('FIRST_SEQUENCE') }
    foreach ($key in @('CRC_ERROR','LENGTH_ERROR','FORMAT_ERROR','PAYLOAD_ERROR',
        'UNEXPECTED_SOURCE','SEQ_GAP','DUPLICATE','OUT_OF_ORDER','FLAGS_ERROR','SOURCE_PORT_ERROR')) {
        if ($fields[$key] -ne 0) { $reasons.Add($key) }
    }
    if ($peerTxNonzero) { $reasons.Add('PEER_TX_TO_DEVICE_TOTAL') }
    # B-20 5.4 / B-22 3.3: stream consistency -- only meaningful once sequence
    # integrity already holds (FIRST_SEQUENCE==0, no gap/duplicate/out-of-order). A
    # valid, in-range LAST_SEQUENCE that is merely inconsistent with the stream is
    # a logical peer failure, not an evidence-contract problem (an out-of-range or
    # malformed LAST_SEQUENCE never reaches this point -- it was already caught
    # above as EvidenceContractValid=false).
    if ($firstSequenceIsZero -and $fields['VALID_RX_TOTAL'] -gt 0 -and
        $fields['SEQ_GAP'] -eq 0 -and $fields['DUPLICATE'] -eq 0 -and $fields['OUT_OF_ORDER'] -eq 0 -and
        !$lastSequenceParsed.IsNone) {
        $expectedLast = $fields['VALID_RX_TOTAL'] - 1
        if ($lastSequenceParsed.Value -ne $expectedLast) { $reasons.Add('LAST_SEQUENCE_STREAM_CONSISTENCY') }
    }
    if ($ExitCode -ne 0) { $reasons.Add("exit_$ExitCode") }
    $logicalPass = ($reasons.Count -eq 0)
    return [pscustomobject]@{
        Available = $true; EvidenceContractValid = $true; Blocked = $false
        LogicalPass = $logicalPass; PeerTxNonzero = $peerTxNonzero; Pass = $logicalPass
        MissingRequiredFields = @(); Reasons = @($reasons); Fields = $fields; Strings = $strings
    }
}

# Layer 4: consumes only already-validated parsed authority objects (SerialResult/
# PeerResult), never re-parsing raw text -- both inputs must already have
# EvidenceContractValid=true, or reconciliation itself is reported unavailable.
function Test-DgAReconciliation([pscustomobject]$SerialResult, [pscustomobject]$PeerResult) {
    if ($null -eq $SerialResult -or $null -eq $PeerResult -or
        !$SerialResult.EvidenceContractValid -or !$PeerResult.EvidenceContractValid) {
        return [pscustomobject]@{ EvidenceValid = $false; Pass = $false; Reasons = @('evidence_unavailable') }
    }
    $reasons = [System.Collections.Generic.List[string]]::new()
    $deviceTotal = $SerialResult.Fields['UDP_TX_TOTAL']
    $peerValid = $PeerResult.Fields['VALID_RX_TOTAL']
    if ($deviceTotal -eq 0 -or $peerValid -ne $deviceTotal) { $reasons.Add('valid_total_mismatch') }
    if ($PeerResult.Strings['FIRST_SEQUENCE'] -cne '0') { $reasons.Add('first_sequence') }
    if ($PeerResult.Fields['SEQ_GAP'] -ne 0) { $reasons.Add('seq_gap') }
    if ($PeerResult.Fields['DUPLICATE'] -ne 0) { $reasons.Add('duplicate') }
    if ($PeerResult.Fields['OUT_OF_ORDER'] -ne 0) { $reasons.Add('out_of_order') }
    return [pscustomobject]@{ EvidenceValid = $true; Pass = ($reasons.Count -eq 0); Reasons = @($reasons) }
}

# B-17: pure, non-throwing raw-text Tier-1 detector. Depends only on raw serial
# text -- never on numeric parsing, peer summary, reconciliation, or any
# generated report -- so it can run, and its result be fixed, before any
# structured parsing is attempted.
function Get-DgARawProvisionalPrimary([string]$SerialText) {
    if ($SerialText -match 'USB_DETACH') { return 'DG_A_USB_HID_FAIL' }
    if ($SerialText -match '(?m)REASON=USB_DETACH_OR_UNSUPPORTED(?:\s|$)') { return 'DG_A_USB_HID_FAIL' }
    if ($SerialText -match '(?m)REASON=HID_STALL(?:\s|$)') { return 'DG_A_USB_HID_FAIL' }
    return 'NONE'
}

# Fail-closed, closed-world classification (B-07/B-11/B-14/B-15/B-16/B-17).
#
# B-17: ProvisionalPrimary (from Get-DgARawProvisionalPrimary, computed on raw
# text before any structured parsing) is checked first and, once set, is never
# overridden by anything computed later -- including a SECONDARY teardown/
# evidence problem, which is recorded but never replaces PRIMARY.
#
# B-15: PASS is a positive allow-list, reached only through the final `else` at
# the bottom of the nested Completion-eq-'PASS' branch, after every prerequisite
# (serial evidence valid+logical-pass, peer summary available+evidence-valid+
# logical-pass, reconciliation evidence-valid+pass) has been explicitly checked.
# There is no other path to 'PASS' anywhere in this function.
#
# Manifest/candidate identity failures (Tier 2's BLOCKED_REVIEWED_*/
# BLOCKED_CANDIDATE_* tokens) are thrown earlier in the pipeline (Assert-*
# functions above) and never reach this function.
function Get-DgAClassification(
    [string]$ProvisionalPrimary,
    [pscustomobject]$SerialResult,
    [bool]$PeerSummaryAvailable,
    [pscustomobject]$PeerResult,
    [pscustomobject]$ReconciliationResult,
    [string]$SecondaryCondition = ""
) {
    $primary = $null
    if ($ProvisionalPrimary -and $ProvisionalPrimary -ne 'NONE') {
        $primary = $ProvisionalPrimary
    } elseif ($SerialResult.NoEvidence) {
        # Tier 4: reached only when no terminal completion, no DG_A_FINAL, no
        # DG_A_SETUP_FAIL, AND no provisional Tier-1 evidence of any kind exists.
        $primary = 'ORCHESTRATION_STALL/TIMEOUT'
    } elseif (!$SerialResult.EvidenceContractValid) {
        $primary = 'BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID'
    } elseif ($SerialResult.IsSetupFailure) {
        $primary = 'DG_A_SETUP_FAIL'
    } elseif ($SerialResult.Reason -eq 'BLOCKED_DG_A_UNEXPECTED_RX_ACTIVITY') {
        $primary = 'BLOCKED_DG_A_UNEXPECTED_RX_ACTIVITY'
    } elseif ($SerialResult.Fields.ContainsKey('RX_READ_CALL_TOTAL') -and $SerialResult.Fields['RX_READ_CALL_TOTAL'] -gt 0) {
        $primary = 'BLOCKED_DG_A_RX_READ_PATH_REACHED'
    } elseif ($SerialResult.Fields.ContainsKey('RX_READ_BYTES_TOTAL') -and $SerialResult.Fields['RX_READ_BYTES_TOTAL'] -gt 0) {
        $primary = 'BLOCKED_DG_A_RX_READ_PATH_REACHED'
    } elseif ($PeerSummaryAvailable -and $PeerResult.EvidenceContractValid -and $PeerResult.PeerTxNonzero) {
        $primary = 'BLOCKED_PEER_TX_TO_DEVICE_NONZERO'
    } elseif ($PeerSummaryAvailable -and $PeerResult.EvidenceContractValid -and $PeerResult.Blocked) {
        $primary = 'BLOCKED_ADMISSION_SEQUENCE_MISS'
    } elseif ($SerialResult.Reason -eq 'DG_A_RX_POLL_API_FAIL') {
        $primary = 'DG_A_RX_POLL_API_FAIL'
    } elseif ($SerialResult.Reason -eq 'LINK_OR_PHY_CHANGED') {
        $primary = 'DG_A_PHY_HEALTH_FAIL'
    } elseif ($SerialResult.Reason -eq 'MAX_REGISTER_MISMATCH') {
        $primary = 'DG_A_MAX_SPI_CANARY_FAIL'
    } elseif (!$SerialResult.HardCriteriaPass) {
        # B-19: measured hard-criterion classification is evaluated for ANY valid
        # normal-schema evidence, regardless of whether TEST_COMPLETE says PASS or
        # FAIL -- firmware's own runtimePass already folds a hard-criterion
        # failure into TEST_COMPLETE=FAIL, so a real detach-free FAIL commonly
        # looks like "TEST_COMPLETE=FAIL REASON=DURATION_COMPLETE
        # SCHEDULER_MISSED_DEADLINE=1", not an unrecognized REASON. This check
        # must therefore run before the generic Completion-eq-FAIL fallback below,
        # or a measured failure would be misreported as merely "unclassified."
        $f = $SerialResult.Fields
        if ($f['RX_POLL_CALL_TOTAL'] -eq 0) { $primary = 'DG_A_RX_POLL_PATH_STALL' }
        elseif ($f['SCHEDULER_MISSED_DEADLINE'] -gt 0) { $primary = 'DG_A_TIMING_FAIL' }
        elseif ($f['FINAL_PHY_OK'] -ne 1 -or $f['FINAL_VERSION_OK'] -ne 1 -or $f['FINAL_BUFFER_MAP_OK'] -ne 1 -or $f['VERSIONR'] -ne 0x04) { $primary = 'DG_A_PHY_HEALTH_FAIL' }
        elseif ($f['MAX_REGISTER_TRIPLE_READ_MISMATCH'] -gt 0 -or $f['SPI_CORRUPTION_SUSPECTED'] -ne 0) { $primary = 'DG_A_MAX_SPI_CANARY_FAIL' }
        elseif ($f['FINAL_USB_STATE'] -ne 0x90 -or $f['FINAL_HID_READY'] -ne 1 -or $f['HID_READY_DROP'] -ne 0 -or $f['HID_STALL_COUNT'] -ne 0) {
            # Not expected to occur without a raw Tier-1 marker or a recognized
            # REASON already having short-circuited above -- kept as a defensive,
            # closed-world completion of the measured-criteria chain rather than
            # an invented new token.
            $primary = 'DG_A_USB_HID_FAIL'
        }
        else {
            # Unreachable in practice (HardCriteriaPass is the AND of exactly the
            # conditions checked above), retained as a fail-closed safety net.
            $primary = 'BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID'
        }
    } elseif ($SerialResult.Completion -eq 'FAIL') {
        # Reached only once no Tier-1/BLOCKED/named-reason/measured-hard-criterion
        # classification applied -- a genuine "current vocabulary cannot classify
        # this FAIL more narrowly" case.
        $primary = 'DG_A_FIRMWARE_FAIL_UNCLASSIFIED'
    } elseif ($SerialResult.Completion -eq 'PASS') {
        if (!$PeerSummaryAvailable) {
            # B-15: no peer evidence at all -- PASS can never be reached this way.
            $primary = 'BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID'
        } elseif (!$PeerResult.EvidenceContractValid) {
            $primary = 'BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID'
        } elseif (!$PeerResult.LogicalPass) {
            $primary = 'DG_A_PEER_FAIL'
        } elseif ($null -eq $ReconciliationResult -or !$ReconciliationResult.EvidenceValid) {
            $primary = 'BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID'
        } elseif (!$ReconciliationResult.Pass) {
            $primary = 'DG_A_RECONCILIATION_FAIL'
        } else {
            $primary = 'PASS'
        }
    } else {
        $primary = 'BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID'
    }
    return [pscustomobject]@{
        Primary = $primary
        Secondary = $SecondaryCondition
        OriginalReason = $SerialResult.Reason
        ProvisionalPrimary = $ProvisionalPrimary
    }
}

function Get-DgATrialResultMarker([string]$TrialName, [pscustomobject]$Classification) {
    if ($TrialName -notin @('DG-A-S1','DG-A-T1')) { throw "Unsupported DG-A trial: $TrialName" }
    if ($Classification.Primary -ne 'PASS') {
        return "DG_A_TRIAL_RESULT=FAIL TRIAL=$TrialName PRIMARY=$($Classification.Primary)"
    }
    return "DG_A_TRIAL_RESULT=PASS TRIAL=$TrialName"
}

# ---------------------------------------------------------------------------
# Build / preflight / serial capture.
# ---------------------------------------------------------------------------

function Invoke-Mode17Build([string]$TrialRoot, [string]$PeerAddress = "") {
    $matrixRoot = Join-Path $TrialRoot "build-matrix"
    if (Test-Path -LiteralPath $matrixRoot) { throw "Fresh matrix root already exists: $matrixRoot" }
    $stdout = Join-Path $TrialRoot "build.stdout.log"
    $stderr = Join-Path $TrialRoot "build.stderr.log"
    $buildArguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $matrixScript,
        "-CaseName", $caseName, "-OutputRoot", $matrixRoot
    )
    if (![string]::IsNullOrWhiteSpace($PeerAddress)) {
        $buildArguments += @("-C1PeerIp", $PeerAddress)
    }
    $process = Start-OwnedProcess "powershell.exe" $buildArguments $stdout $stderr
    Wait-OwnedProcess $process 1200 "Mode 17 build" | Out-Null
    $buildPath = Join-Path $matrixRoot "$caseName\build"
    if (!(Test-Path -LiteralPath $buildPath)) { throw "Mode 17 fresh build output missing: $buildPath" }
    return [pscustomobject]@{ BuildPath = $buildPath; MatrixRoot = $matrixRoot; StdoutPath = $stdout }
}

function Start-DgASerialCaptureJob(
    [string]$ExpectedIdentity,
    [string]$LogPath,
    [int]$CaptureSeconds
) {
    $job = Start-Job -ArgumentList $ExpectedIdentity,$LogPath,$CaptureSeconds -ScriptBlock {
        param($Identity,$Path,$Seconds)
        $ErrorActionPreference='Stop'
        function Resolve-Port {
            $portCandidates=@()
            foreach($entity in @(Get-CimInstance Win32_PnPEntity)){
                $nameMatch=[regex]::Match([string]$entity.Name,'\((COM[0-9]+)\)$')
                if($nameMatch.Success -and [string]$entity.PNPDeviceID -ceq $Identity){
                    $candidatePort=$nameMatch.Groups[1].Value
                    if($candidatePort -cne 'COM3'){$portCandidates += $candidatePort}
                }
            }
            if($portCandidates.Count -eq 1){return $portCandidates[0]}
            return $null
        }
        $openWatch=[Diagnostics.Stopwatch]::StartNew();$port=$null;$portName=$null
        while($openWatch.Elapsed.TotalSeconds -lt 15){
            $portName=Resolve-Port
            if(!$portName){Start-Sleep -Milliseconds 100;continue}
            try{
                $candidate=[IO.Ports.SerialPort]::new($portName,115200,'None',8,'One')
                $candidate.DtrEnable=$false;$candidate.RtsEnable=$false;$candidate.ReadTimeout=250
                $candidate.Open();$port=$candidate;break
            }catch{if($candidate){$candidate.Dispose()};Start-Sleep -Milliseconds 250}
        }
        if(!$port){Write-Output 'BLOCKED_COM4_REENUMERATION';throw 'BLOCKED_COM4_REENUMERATION'}
        Write-Output "COM_REENUMERATED=1 PORT=$portName PNPDeviceID=$Identity"
        Write-Output "SERIAL_OPENED=1 PORT=$portName BAUD=115200 DATA_BITS=8 PARITY=None STOP_BITS=One DTR=0 RTS=0"
        try{
            $capture=[Diagnostics.Stopwatch]::StartNew()
            while($capture.Elapsed.TotalSeconds -lt $Seconds){
                $text=$port.ReadExisting()
                if($text.Length -gt 0){[IO.File]::AppendAllText($Path,$text,[Text.UTF8Encoding]::new($false))}
                # B-14: capture ends on a terminal marker regardless of PASS or FAIL --
                # evidence capture must not depend on the trial outcome.
                if((Test-Path -LiteralPath $Path) -and
                   ([IO.File]::ReadAllText($Path) -match 'SCOPE_MARKER trial=DG-A event=TRIAL_COMPLETE result=(?:PASS|FAIL)')){break}
                Start-Sleep -Milliseconds 20
            }
        }finally{if($port.IsOpen){$port.Close()};$port.Dispose()}
    }
    $startedJobs.Add($job)
    return $job
}

function Invoke-PhysicalTrialPreflight([switch]$EmitPlan) {
    if ($ComPort -cne 'COM4') { throw 'Only verified COM4 is permitted; COM3 is prohibited.' }
    if ([string]::IsNullOrWhiteSpace($ExpectedPnpDeviceId)) { throw '-ExpectedPnpDeviceId is required.' }
    if ([string]::IsNullOrWhiteSpace($PeerIp)) { throw '-PeerIp is required.' }
    # B-24: exact fixed-identity requirement, independent of and in addition to
    # the same-subnet/interface safety validation below -- both must pass.
    Assert-DgAPeerIpIdentity $PeerIp
    if ($SenderIp -cne $fixedSenderIp) { throw "Sender IP must equal $fixedSenderIp." }
    if (!$EmitPlan) {
        # Live preflight (never invoked this session) requires Phase B authority
        # inputs -- both required, neither defaulted from repository state (B-10).
        Assert-ReviewedManifestAuthority $ReviewedManifestPath $ExpectedReviewedManifestSha256
        Assert-GitBaseline
        Assert-ToolchainIdentity
        Assert-PreUploadCom4Identity $ExpectedPnpDeviceId
        $peerInterface = Assert-SafePeerAddress $PeerIp $SenderIp $ReceiverIp
        Write-Output "PEER_INTERFACE_OK=1 IP=$PeerIp INTERFACE_INDEX=$($peerInterface.InterfaceIndex) PC_PREFIX_LENGTH=$($peerInterface.PrefixLength) FIRMWARE_PREFIX_LENGTH=24"
        return
    }
    $plannedRoot = Join-Path $runRoot "$Trial-<timestamp-guid>"
    # B-24: the fixed physical peer endpoint, restated explicitly so plan display
    # and runtime behavior cannot drift apart again -- $PeerIp is already proven
    # equal to $fixedPeerIp by the Assert-DgAPeerIpIdentity call above.
    Write-Output "FIXED_PEER_IP=$fixedPeerIp"
    Write-Output "PLANNED_ORCHESTRATION_ORDER=PEER_START -> BOUND_NOT_ARMED -> PEER_READY -> PRE_BUILD_MANIFEST_STEP_A_STEP_B -> FRESH_BUILD -> POST_BUILD_MANIFEST_STEP_A_STEP_B -> PRE_UPLOAD_COM4_IDENTITY -> PEER_ALIVE_CHECK -> UPLOAD -> UPLOAD_PASS -> ARM_REQUEST -> ARMED_ACK -> BOUNDED_SERIAL_CAPTURE -> PRESERVE_RAW_SERIAL -> UNCONDITIONAL_PEER_STOP -> BOUNDED_PEER_EXIT -> PRESERVE_PEER_EVIDENCE -> CLASSIFY -> FOUR_LAYER_EVALUATION"
    Write-Output "PLANNED_BUILD_COMMAND=powershell -NoProfile -ExecutionPolicy Bypass -File $matrixScript -CaseName $caseName -C1PeerIp $PeerIp -OutputRoot <fresh-build-root>"
    Write-Output "PLANNED_UPLOAD_COMMAND=arduino-cli upload --fqbn $fqbn --port COM4 --input-dir <fresh-build-path>"
    Write-Output "PLANNED_PEER_COMMAND=python $peerScript --mode sink --bind-ip $PeerIp --port 50001 --expected-source-ip $SenderIp --expected-source-port 50001 --arm-file <trial-root>\peer.arm --armed-file <trial-root>\peer.armed"
    Write-Output "PLANNED_SERIAL=COM4 exact-PNP baud=115200 data=8 parity=None stop=One DTR=0 RTS=0"
    Write-Output "TIMEOUTS process_seconds=$ProcessTimeoutSeconds com_reenumeration_seconds=15 peer_ready_seconds=10 build_seconds=1200 external_result_seconds=$externalResultTimeoutSeconds"
    Write-Output "EXPECTED_OUTPUT_ROOT=$plannedRoot"
    Write-Output "PHASE_B_REQUIRED_INPUTS=-ReviewedManifestPath,-ExpectedReviewedManifestSha256 (both required, neither defaulted)"
}

# ---------------------------------------------------------------------------
# Real (never invoked this session) physical trial implementation.
# B-14: evidence capture / graceful teardown is unconditional and runs before
# PASS/FAIL adjudication -- the peer stop-file is written once the bounded
# serial capture ends, regardless of what TEST_COMPLETE said. A raw-serial
# Tier-1 physical failure, once observed, is preserved as PRIMARY and never
# overwritten by a later teardown/reporting problem (SECONDARY only).
# ---------------------------------------------------------------------------

function Invoke-DgAPhysicalTrial {
    if (!($AllowUpload -and $AllowSerial -and $AllowPeer -and $AllowNetworkTrial)) {
        throw "Physical trial requires -AllowUpload -AllowSerial -AllowPeer -AllowNetworkTrial together."
    }
    Invoke-PhysicalTrialPreflight

    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $trialIdentity = "{0}-{1}-{2}" -f $Trial,(Get-Date -Format "yyyyMMdd-HHmmss"),([guid]::NewGuid().ToString("N").Substring(0,8))
    $trialRoot = Join-Path $runRoot $trialIdentity
    Assert-ChildPath $runRoot $trialRoot
    New-Item -ItemType Directory -Path $trialRoot | Out-Null

    try {
        $armFile = Join-Path $trialRoot "peer.arm"
        $armedFile = Join-Path $trialRoot "peer.armed"
        $readyFile = Join-Path $trialRoot "peer.ready"
        $stopFile = Join-Path $trialRoot "peer.stop"
        $peerCsv = Join-Path $trialRoot "peer.csv"
        $peerStdout = Join-Path $trialRoot "peer.stdout.log"
        $peerStderr = Join-Path $trialRoot "peer.stderr.log"
        $peerProcess = Start-OwnedProcess "python.exe" @(
            $peerScript, "--mode", "sink", "--bind-ip", $PeerIp,
            "--port", "50001", "--expected-source-ip", $SenderIp, "--expected-source-port", "50001",
            "--arm-file", $armFile, "--armed-file", $armedFile,
            "--csv", $peerCsv, "--ready-file", $readyFile, "--stop-file", $stopFile
        ) $peerStdout $peerStderr
        Write-Output "PEER_PROCESS_STARTED=1"
        Write-Output "PEER_PID=$($peerProcess.Id)"
        Write-Output "PEER_STATE=BOUND_NOT_ARMED"
        $readyWatch = [Diagnostics.Stopwatch]::StartNew()
        while (!(Test-Path -LiteralPath $readyFile)) {
            if ($peerProcess.HasExited) { throw "PC peer exited before readiness." }
            if ($readyWatch.Elapsed.TotalSeconds -ge 10) { throw "PC peer readiness timed out." }
            Start-Sleep -Milliseconds 100
        }
        Write-Output "PEER_READY=1"

        Assert-ReviewedManifestAuthority $ReviewedManifestPath $ExpectedReviewedManifestSha256
        Write-Output "REVIEWED_SOURCE_IDENTITY_PHASE=PRE_BUILD PASS=1"

        $buildResult = Invoke-Mode17Build $trialRoot $PeerIp
        $buildPath = [string]$buildResult.BuildPath
        Write-Output "BUILD_ONLY_PASS=1 CASE=$caseName ROOT=$($buildResult.MatrixRoot) LOG=$($buildResult.StdoutPath)"

        Assert-ReviewedManifestAuthority $ReviewedManifestPath $ExpectedReviewedManifestSha256
        Write-Output "REVIEWED_SOURCE_IDENTITY_PHASE=POST_BUILD PASS=1"

        Assert-PreUploadCom4Identity $ExpectedPnpDeviceId
        if ($peerProcess.HasExited) { throw "BLOCKED_PEER_PROCESS_NOT_RUNNING_PRE_UPLOAD" }

        $uploadStdout = Join-Path $trialRoot "upload.stdout.log"
        $uploadStderr = Join-Path $trialRoot "upload.stderr.log"
        $uploadProcess = Start-OwnedProcess "arduino-cli.exe" @(
            "upload", "--fqbn", $fqbn, "--port", "COM4", "--input-dir", $buildPath
        ) $uploadStdout $uploadStderr
        Wait-OwnedProcess $uploadProcess $ProcessTimeoutSeconds "COM4 upload" | Out-Null
        Write-Output "UPLOAD_PASS=1 PORT=COM4"

        New-DgAArmRequest $armFile
        Wait-DgAArmedAcknowledgement $armedFile $peerStderr 10

        # --- (A) Evidence capture / graceful teardown: unconditional, bounded ---
        $serialLog = Join-Path $trialRoot "serial.log"
        $serialJob = Start-DgASerialCaptureJob $ExpectedPnpDeviceId $serialLog ($durationSeconds + 30)
        $secondary = ""
        if (!(Wait-Job -Job $serialJob -Timeout $externalResultTimeoutSeconds)) {
            Stop-Job -Job $serialJob -ErrorAction SilentlyContinue
            $secondary = "SERIAL_CAPTURE_TIMEOUT"
        }
        $serialWorkerOutput = @(Receive-Job -Job $serialJob -ErrorAction SilentlyContinue)
        $serialWorkerOutput | ForEach-Object { Write-Output $_ }
        $serialText = if (Test-Path -LiteralPath $serialLog) { Get-Content -LiteralPath $serialLog -Raw } else { "" }
        Write-Output "RAW_SERIAL_PRESERVED=1 BYTES=$($serialText.Length)"

        # B-17: fix a Tier-1 physical-failure primary from raw text alone, before
        # any structured parsing is attempted, so it survives even if structured
        # parsing later fails for any reason.
        $provisionalPrimary = Get-DgARawProvisionalPrimary $serialText
        if ($provisionalPrimary -ne 'NONE') {
            Write-Output "DG_A_RAW_PRIMARY_PROVISIONAL=$provisionalPrimary"
        }

        # Regardless of what the serial evidence will turn out to say: the peer is
        # told to stop now, not gated on a PASS classification (B-14).
        if (!$peerProcess.HasExited) {
            [IO.File]::WriteAllText($stopFile,"PEER_STOP=1`n",[Text.UTF8Encoding]::new($false))
            Write-Output "PEER_STOP_REQUESTED=1 UNCONDITIONAL=1"
        }
        $peerText = ""
        $peerExit = -1
        $peerSummaryAvailable = $false
        try {
            $peerExit = Wait-OwnedProcess $peerProcess ($ProcessTimeoutSeconds + 10) "DG-A PC peer" -AllowNonZero
            if (Test-Path -LiteralPath $peerStdout) { $peerText = Get-Content -LiteralPath $peerStdout -Raw }
            if ($peerText -match 'PEER_COMPLETE=1') {
                $peerSummaryAvailable = $true
                Write-Output "PEER_SUMMARY_CAPTURED=1"
            } else {
                $secondary = if ($secondary) { "$secondary;PEER_EVIDENCE_INCOMPLETE" } else { "PEER_EVIDENCE_INCOMPLETE" }
                Write-Output "PEER_SUMMARY_CAPTURED=0"
            }
        } catch {
            $secondary = if ($secondary) { "$secondary;PEER_GRACEFUL_EXIT_TIMEOUT" } else { "PEER_GRACEFUL_EXIT_TIMEOUT" }
            Write-Output "PEER_GRACEFUL_EXIT_TIMEOUT=1 DETAIL=$($_.Exception.Message)"
        }

        # --- (B) PASS/FAIL adjudication: only now, after (A) has run to completion ---
        # Wrapped defensively: the parsers above are designed to be non-throwing
        # (malformed evidence becomes EvidenceContractValid=false, not an
        # exception), but if something still escapes, the provisional Tier-1
        # primary (or a BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID fallback) is used
        # rather than letting the trial end with no classification at all (B-17).
        try {
            $serialResult = Test-DgASerialLog $serialText
            $peerResult = if ($peerSummaryAvailable) { Test-DgAPeerSummary $peerText $peerExit } else { $null }
            $reconciliation = if ($peerSummaryAvailable) { Test-DgAReconciliation $serialResult $peerResult } else { $null }
            $classification = Get-DgAClassification $provisionalPrimary $serialResult `
                $peerSummaryAvailable $peerResult $reconciliation $secondary
        } catch {
            $secondary = if ($secondary) { "$secondary;EVIDENCE_PARSER_INCOMPLETE" } else { "EVIDENCE_PARSER_INCOMPLETE" }
            Write-Output "EVIDENCE_PARSER_EXCEPTION=1 DETAIL=$($_.Exception.Message)"
            $classification = [pscustomobject]@{
                Primary = if ($provisionalPrimary -ne 'NONE') { $provisionalPrimary } else { 'BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID' }
                Secondary = $secondary
                OriginalReason = $null
                ProvisionalPrimary = $provisionalPrimary
            }
        }
        Write-Output "DG_A_CLASSIFICATION_PRIMARY=$($classification.Primary)"
        if ($classification.Secondary) { Write-Output "DG_A_CLASSIFICATION_SECONDARY=$($classification.Secondary)" }
        Write-Output (Get-DgATrialResultMarker $Trial $classification)
        if ($classification.Primary -ne 'PASS') {
            throw "DG-A trial did not reach PASS: $($classification.Primary)"
        }
    } finally {
        foreach ($job in $startedJobs) {
            if ($job.State -eq "Running") { Stop-Job -Job $job -ErrorAction SilentlyContinue }
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
        foreach ($process in $startedProcesses) {
            if (!$process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Offline self-tests (-RunOfflineTests). Pure text/state/filesystem-fixture
# processing only -- no COM, no socket bind to a real network interface, no
# upload. Covers: manifest Phase A/B fixtures, classification tiers (including
# B-11 split and B-14 SECONDARY), serial/peer/reconciliation contract fixtures,
# COM reconnect fixtures (reused pattern), process lifecycle fixtures (reused
# pattern), and the peer self-test.
# ---------------------------------------------------------------------------

function Invoke-OfflineTests {
    $results = [System.Collections.Generic.List[object]]::new()
    function Record([string]$Group,[string]$Name,[bool]$Passed,[string]$Detail='') {
        $results.Add([pscustomobject]@{Group=$Group;Name=$Name;Pass=$Passed;Detail=$Detail})
        Write-Output "$Group case=$Name result=$(if($Passed){'PASS'}else{'FAIL'}) detail=$Detail"
    }
    function Expect-Throw([scriptblock]$Action,[string]$Pattern) {
        try{& $Action;return $false}catch{return $_.Exception.Message -match $Pattern}
    }

    $fixtureRoot=Join-Path $repoRoot ("build-temp\usb-lan-isolation\runner-fixtures\dg-a-{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'),([guid]::NewGuid().ToString('N').Substring(0,8)))
    New-Item -ItemType Directory -Path $fixtureRoot|Out-Null

    # --- Peer self-test (invoked, not duplicated) ---
    $peerSelfTestOut = Join-Path $fixtureRoot 'peer-self-test.stdout.log'
    $peerSelfTestErr = Join-Path $fixtureRoot 'peer-self-test.stderr.log'
    try {
        $peerSelfTestProcess = Start-OwnedProcess "python.exe" @($peerScript,'--mode','self-test') $peerSelfTestOut $peerSelfTestErr
        $peerSelfTestExit = Wait-OwnedProcess $peerSelfTestProcess 60 'DG-A peer self-test' -AllowNonZero
        Record 'PEER_SELF_TEST_INVOCATION' 'peer_self_test_exit_zero' ($peerSelfTestExit -eq 0) "exit=$peerSelfTestExit"
    } catch {
        Record 'PEER_SELF_TEST_INVOCATION' 'peer_self_test_exit_zero' $false $_.Exception.Message
    }

    # --- Phase A candidate manifest fixtures (B-13) ---
    $fixtureFile=Join-Path $fixtureRoot 'candidate.txt';[IO.File]::WriteAllText($fixtureFile,'candidate',[Text.UTF8Encoding]::new($false))
    $preSnapshot = [ordered]@{ fixture = [pscustomobject]@{ Path=$fixtureFile; Size=(Get-Item $fixtureFile).Length; Sha256=Get-Sha256 $fixtureFile; InventoryRoot="" } }
    try { Assert-DgACandidateConsistency $preSnapshot $preSnapshot; Record 'CANDIDATE_CONSISTENCY_TEST' 'identical_snapshots_pass' $true } catch { Record 'CANDIDATE_CONSISTENCY_TEST' 'identical_snapshots_pass' $false $_.Exception.Message }
    [IO.File]::AppendAllText($fixtureFile,' CHANGED',[Text.UTF8Encoding]::new($false))
    $postSnapshot = [ordered]@{ fixture = [pscustomobject]@{ Path=$fixtureFile; Size=(Get-Item $fixtureFile).Length; Sha256=Get-Sha256 $fixtureFile; InventoryRoot="" } }
    Record 'CANDIDATE_CONSISTENCY_TEST' 'changed_during_build_blocked' (Expect-Throw {Assert-DgACandidateConsistency $preSnapshot $postSnapshot} 'BLOCKED_CANDIDATE_SOURCE_IDENTITY_CHANGED_DURING_BUILD')
    $manifestOut = New-DgACandidateManifest $postSnapshot (Join-Path $fixtureRoot 'candidate-manifest.csv')
    $manifestRows = @(Import-Csv -LiteralPath $manifestOut.Path)
    Record 'CANDIDATE_MANIFEST_TEST' 'manifest_excludes_itself' (($manifestRows | Where-Object { $_.relative_or_absolute_path -eq $manifestOut.Path }).Count -eq 0)
    $sidecarText = (Get-Content -LiteralPath $manifestOut.Sha256Sidecar -Raw).Trim()
    Record 'CANDIDATE_MANIFEST_TEST' 'sidecar_matches_manifest_hash' ($sidecarText -ceq $manifestOut.Sha256)
    Record 'CANDIDATE_MANIFEST_TEST' 'sidecar_excluded_from_manifest' (($manifestRows | Where-Object { $_.relative_or_absolute_path -eq $manifestOut.Sha256Sidecar }).Count -eq 0)

    # --- Phase B manifest authority fixtures (B-10), never touching a real accepted authority ---
    Record 'MANIFEST_AUTHORITY_TEST' 'requires_expected_hash' (Expect-Throw {Assert-ReviewedManifestAuthority $manifestOut.Path ''} '-ExpectedReviewedManifestSha256 is required')
    Record 'MANIFEST_AUTHORITY_TEST' 'step_a_wrong_hash_blocked' (Expect-Throw {Assert-ReviewedManifestAuthority $manifestOut.Path ('0'*64)} 'BLOCKED_REVIEWED_MANIFEST_IDENTITY_MISMATCH')
    try { Assert-ReviewedManifestAuthority $manifestOut.Path $manifestOut.Sha256; Record 'MANIFEST_AUTHORITY_TEST' 'step_a_then_step_b_pass' $true } catch { Record 'MANIFEST_AUTHORITY_TEST' 'step_a_then_step_b_pass' $false $_.Exception.Message }
    [IO.File]::AppendAllText($fixtureFile,' AGAIN',[Text.UTF8Encoding]::new($false))
    # Piped to Out-Null: Assert-ReviewedManifestAuthority's Step-A success line would
    # otherwise leak into Expect-Throw's own return value (it succeeds at Step A here
    # and only throws at Step B), corrupting the boolean passed to Record.
    Record 'MANIFEST_AUTHORITY_TEST' 'step_b_content_mismatch_blocked' (Expect-Throw {Assert-ReviewedManifestAuthority $manifestOut.Path $manifestOut.Sha256 | Out-Null} 'BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH')

    # --- Reused generic fixtures (donor pattern, unchanged shape) ---
    try{Assert-SafePeerAddressCore '192.168.50.2' '192.168.50.10' '192.168.50.20' 24 $true $true;Record 'RUNNER_DRY_RUN_TEST' 'safe_peer_ip' $true}catch{Record 'RUNNER_DRY_RUN_TEST' 'safe_peer_ip' $false $_.Exception.Message}
    Record 'RUNNER_DRY_RUN_TEST' 'sender_ip_not_fixed' (Expect-Throw {Assert-SafePeerAddressCore '192.168.50.2' '192.168.51.10' '192.168.50.20' 24 $true $true} 'fixed firmware')
    Record 'RUNNER_DRY_RUN_TEST' 'multicast' (Expect-Throw {Assert-SafePeerAddressCore '224.0.0.1' '192.168.50.10' '192.168.50.20' 24 $true $true} 'multicast')

    $identity='USB\VID_1234&PID_5678\ABC';$sleep={param($ms)}
    foreach($fixture in @(
        [pscustomobject]@{Name='immediate_reconnect';Empty=0;Identity=$identity;Expected=$true},
        [pscustomobject]@{Name='reconnect_700ms';Empty=7;Identity=$identity;Expected=$true},
        [pscustomobject]@{Name='no_reconnect';Empty=999;Identity=$identity;Expected=$false}
    )){
        $script:index=0;$resolver={
            $current=$script:index;$script:index++
            if($current -lt $fixture.Empty){return @()}
            return @([pscustomobject]@{PortName='COM5';PnpDeviceId=$fixture.Identity})
        }
        try{$resolved=Wait-ComIdentityReenumeration $identity $resolver 15000 100 $sleep;$actual=$resolved.PortName -eq 'COM5'}catch{$actual=$false}
        Record 'COM_RECONNECT_FIXTURE' $fixture.Name ($actual -eq $fixture.Expected)
    }

    $processZeroOut=Join-Path $fixtureRoot 'exit-zero.stdout.log'
    $processZeroErr=Join-Path $fixtureRoot 'exit-zero.stderr.log'
    try {
        $processZero=Start-OwnedProcess 'powershell.exe' @('-NoProfile','-Command',"exit 0") $processZeroOut $processZeroErr
        $processZeroExit=Wait-OwnedProcess $processZero 10 'offline exit-zero fixture'
        Record 'PROCESS_LIFECYCLE_TEST' 'redirected_exit_zero' ($processZeroExit -eq 0) "exit=$processZeroExit"
    } catch { Record 'PROCESS_LIFECYCLE_TEST' 'redirected_exit_zero' $false $_.Exception.Message }

    # --- Serial log contract fixtures (Layer 2): canonical evidence authority
    # (B-16), fail-closed classification (B-07/B-11), PASS positive allow-list
    # (B-15), raw provisional Tier-1 (B-17). ---
    $passTerminal='TEST_COMPLETE=PASS TEST_MODE=17 TEST_MODE_NAME=USB_FIXED10_UDP_TX_RX_POLL_EMPTY DURATION_MS=10000 TRIAL_RUNTIME_MS=10000 REASON=DURATION_COMPLETE FINAL_USB_STATE=90 FINAL_HID_READY=1 HID_READY_DROP=0 HID_STALL_COUNT=0 HID_MAX_NO_REPORT_MS=5 VID=0F0D PID=0202 HID_REPORT_TOTAL=2000 FINAL_PHY_OK=1 FINAL_VERSION_OK=1 FINAL_BUFFER_MAP_OK=1 VERSIONR=04 MAX_REGISTER_TRIPLE_READ_MISMATCH=0 SPI_CORRUPTION_SUSPECTED=0'
    $passStats='DG_A_FINAL UDP_TX_TOTAL=500 UDP_TX_FAIL=0 UDP_BEGIN_COUNT=1 UDP_BEGIN_FAIL=0 UDP_BEGIN_MAX_US=100 UDP_BEGIN_PACKET_MAX_US=50 UDP_WRITE_MAX_US=30 UDP_END_PACKET_MAX_US=40 UDP_MAX_GAP_US=21000 SCHEDULER_MISSED_DEADLINE=0 SCHEDULER_MAX_LATENESS_US=0 LOOP_MAX_US=200 HID_STALL_COUNT=0 HID_MAX_NO_REPORT_MS=5 RX_POLL_CALL_TOTAL=500 RX_POLL_POSITIVE_TOTAL=0 RX_POLL_NEGATIVE_ERROR=0 RX_READ_CALL_TOTAL=0 RX_READ_BYTES_TOTAL=0 RX_POLL_MAX_US=15'
    $oldDiagLine='DG_A_DIAG UDP_TX_TOTAL=250 UDP_TX_FAIL=0 UDP_BEGIN_COUNT=1 UDP_BEGIN_FAIL=0 UDP_BEGIN_MAX_US=100 UDP_BEGIN_PACKET_MAX_US=50 UDP_WRITE_MAX_US=30 UDP_END_PACKET_MAX_US=40 UDP_MAX_GAP_US=21000 SCHEDULER_MISSED_DEADLINE=0 SCHEDULER_MAX_LATENESS_US=0 LOOP_MAX_US=200 HID_STALL_COUNT=0 HID_MAX_NO_REPORT_MS=5 RX_POLL_CALL_TOTAL=250 RX_POLL_POSITIVE_TOTAL=0 RX_POLL_NEGATIVE_ERROR=0 RX_READ_CALL_TOTAL=0 RX_READ_BYTES_TOTAL=0 RX_POLL_MAX_US=15'
    $scope='SCOPE_MARKER trial=DG-A event=TRIAL_COMPLETE result=PASS'
    $passSerial="$oldDiagLine`n$passStats`n$passTerminal`n$scope"
    $noProvisional = 'NONE'
    $sr = Test-DgASerialLog $passSerial
    Record 'SERIAL_FIXTURE_TEST' 'pass_evidence_contract_valid' $sr.EvidenceContractValid
    Record 'SERIAL_FIXTURE_TEST' 'pass_hard_criteria_pass' $sr.HardCriteriaPass
    Record 'SERIAL_FIXTURE_TEST' 'pass_normal_schema' ($sr.Schema -ceq 'Normal')
    # B-16: DG_A_DIAG is informational only, never authority -- RX_POLL_CALL_TOTAL
    # must come from DG_A_FINAL (500), never the earlier DG_A_DIAG (250).
    Record 'SERIAL_FIXTURE_TEST' 'diag_line_ignored_as_authority' ($sr.Fields['RX_POLL_CALL_TOTAL'] -eq 500)

    $peerPassText=@('PEER_COMPLETE=1','RX_TOTAL=500','VALID_RX_TOTAL=500','FIRST_SEQUENCE=0','LAST_SEQUENCE=499','EXPECTED_SOURCE_IP=192.168.50.10','EXPECTED_SOURCE_PORT=50001','PEER_RESULT=PASS','CRC_ERROR=0','LENGTH_ERROR=0','FORMAT_ERROR=0','PAYLOAD_ERROR=0','UNEXPECTED_SOURCE=0','SEQ_GAP=0','DUPLICATE=0','OUT_OF_ORDER=0','FLAGS_ERROR=0','SOURCE_PORT_ERROR=0','PEER_ARMED=1','ADMISSION_SEQUENCE_ZERO_OK=1','BLOCKED_ADMISSION_SEQUENCE_MISS=0','BOUND_NOT_ARMED_PACKET_COUNT=0','PRE_ADMISSION_NON_C1_COUNT=0','PEER_TX_TO_DEVICE_TOTAL=0') -join "`n"
    $prAll = Test-DgAPeerSummary $peerPassText 0
    Record 'PEER_FIXTURE_TEST' 'peer_pass_evidence_contract_valid' $prAll.EvidenceContractValid
    Record 'PEER_FIXTURE_TEST' 'peer_pass_logical_pass' $prAll.LogicalPass
    $reconAll = Test-DgAReconciliation $sr $prAll
    Record 'RECONCILIATION_FIXTURE_TEST' 'reconciliation_evidence_valid' $reconAll.EvidenceValid
    Record 'RECONCILIATION_FIXTURE_TEST' 'reconciliation_pass' $reconAll.Pass

    # Positive PASS: exactly one valid DG_A_FINAL, exactly one valid TEST_COMPLETE,
    # complete valid peer summary, exact reconciliation, all four complete layers pass.
    $clsAll = Get-DgAClassification $noProvisional $sr $true $prAll $reconAll ""
    Record 'CLASSIFICATION_TEST' 'all_four_layers_pass' ($clsAll.Primary -eq 'PASS')
    Record 'CLASSIFICATION_TEST' 'trial_result_marker_pass' ((Get-DgATrialResultMarker 'DG-A-S1' $clsAll) -ceq 'DG_A_TRIAL_RESULT=PASS TRIAL=DG-A-S1')

    # --- B-15: PASS is a positive allow-list -- unreachable without peer evidence ---
    $clsNoPeer = Get-DgAClassification $noProvisional $sr $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'b15_serial_pass_peer_unavailable_never_pass' ($clsNoPeer.Primary -ne 'PASS')
    Record 'CLASSIFICATION_TEST' 'b15_serial_pass_peer_unavailable_evidence_invalid' ($clsNoPeer.Primary -eq 'BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID')

    $malformedPeerText = 'PEER_COMPLETE=1'
    $prMalformed = Test-DgAPeerSummary $malformedPeerText 0
    Record 'PEER_FIXTURE_TEST' 'peer_malformed_no_exception' $true
    Record 'PEER_FIXTURE_TEST' 'peer_malformed_evidence_invalid' (!$prMalformed.EvidenceContractValid)
    $clsMalformedPeer = Get-DgAClassification $noProvisional $sr $true $prMalformed $null ""
    Record 'CLASSIFICATION_TEST' 'b15_serial_pass_peer_malformed_evidence_invalid' ($clsMalformedPeer.Primary -eq 'BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID')

    # --- B-16: two DG_A_FINAL lines -> evidence contract invalid ---
    $twoFinalSerial = "$passStats`n$passStats`n$passTerminal`n$scope"
    $srTwoFinal = Test-DgASerialLog $twoFinalSerial
    Record 'SERIAL_FIXTURE_TEST' 'two_dg_a_final_lines_invalid' (!$srTwoFinal.EvidenceContractValid)

    # --- B-16: two TEST_COMPLETE lines -> evidence contract invalid ---
    $twoTerminalSerial = "$passStats`n$passTerminal`n$passTerminal`n$scope"
    $srTwoTerminal = Test-DgASerialLog $twoTerminalSerial
    Record 'SERIAL_FIXTURE_TEST' 'two_test_complete_lines_invalid' (!$srTwoTerminal.EvidenceContractValid)

    # --- B-16: DG_A_FINAL missing (old DG_A_DIAG only) + TEST_COMPLETE=PASS -> invalid ---
    $finalMissingSerial = "$oldDiagLine`n$passTerminal`n$scope"
    $srFinalMissing = Test-DgASerialLog $finalMissingSerial
    Record 'SERIAL_FIXTURE_TEST' 'final_missing_diag_only_invalid' (!$srFinalMissing.EvidenceContractValid)

    # --- B-16: DG_A_FINAL required numeric field missing -> invalid ---
    $finalFieldMissingSerial = ($passStats -replace ' RX_POLL_CALL_TOTAL=500','') + "`n$passTerminal`n$scope"
    $srFinalFieldMissing = Test-DgASerialLog $finalFieldMissingSerial
    Record 'SERIAL_FIXTURE_TEST' 'final_required_field_missing_invalid' (!$srFinalFieldMissing.EvidenceContractValid)

    # --- B-16: DG_A_FINAL required numeric field = garbage -> no exception, invalid ---
    $finalGarbageSerial = ($passStats -replace 'RX_POLL_CALL_TOTAL=500','RX_POLL_CALL_TOTAL=notanumber') + "`n$passTerminal`n$scope"
    $srFinalGarbage = Test-DgASerialLog $finalGarbageSerial
    Record 'SERIAL_FIXTURE_TEST' 'final_garbage_field_no_exception' $true
    Record 'SERIAL_FIXTURE_TEST' 'final_garbage_field_invalid' (!$srFinalGarbage.EvidenceContractValid)

    # --- Setup/pre-trial failure schema (dgAFailSetup(), read-only-inventoried
    # reasons): never PASS, never ORCHESTRATION_STALL, own classification token ---
    $setupFailSerial = "DIAGNOSTIC_BOOT TEST_MODE=17`nDG_A_SETUP_FAIL=1 REASON=LINK_TIMEOUT`nTEST_COMPLETE=FAIL TEST_MODE=17 TEST_MODE_NAME=USB_FIXED10_UDP_TX_RX_POLL_EMPTY REASON=LINK_TIMEOUT FINAL_USB_STATE=00 FINAL_HID_READY=0 HID_READY_DROP=0`nSCOPE_MARKER trial=DG-A event=TRIAL_COMPLETE result=FAIL"
    $srSetupFail = Test-DgASerialLog $setupFailSerial
    Record 'SERIAL_FIXTURE_TEST' 'setup_failure_schema_recognized' ($srSetupFail.Schema -ceq 'SetupFailure')
    Record 'SERIAL_FIXTURE_TEST' 'setup_failure_known_reason_inventoried' ($dgAKnownSetupFailureReasons -contains $srSetupFail.Reason)
    $clsSetupFail = Get-DgAClassification $noProvisional $srSetupFail $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'setup_failure_never_pass' ($clsSetupFail.Primary -ne 'PASS')
    Record 'CLASSIFICATION_TEST' 'setup_failure_never_orchestration_stall' ($clsSetupFail.Primary -ne 'ORCHESTRATION_STALL/TIMEOUT')
    Record 'CLASSIFICATION_TEST' 'setup_failure_classification' ($clsSetupFail.Primary -eq 'DG_A_SETUP_FAIL')

    # --- Peer evidence: PEER_COMPLETE=1 but a required field missing -> invalid ---
    $peerMissingFieldText = ($peerPassText -replace "`nVALID_RX_TOTAL=500",'')
    $prPeerMissing = Test-DgAPeerSummary $peerMissingFieldText 0
    Record 'PEER_FIXTURE_TEST' 'peer_required_field_missing_no_exception' $true
    Record 'PEER_FIXTURE_TEST' 'peer_required_field_missing_invalid' (!$prPeerMissing.EvidenceContractValid)

    # --- Peer evidence: required numeric field = garbage -> no exception, invalid ---
    $peerGarbageText = ($peerPassText -replace 'CRC_ERROR=0','CRC_ERROR=notanumber')
    $prPeerGarbage = Test-DgAPeerSummary $peerGarbageText 0
    Record 'PEER_FIXTURE_TEST' 'peer_garbage_field_no_exception' $true
    Record 'PEER_FIXTURE_TEST' 'peer_garbage_field_invalid' (!$prPeerGarbage.EvidenceContractValid)

    # --- Peer evidence: duplicate required field -> invalid ---
    $peerDuplicateText = $peerPassText + "`nCRC_ERROR=0"
    $prPeerDuplicate = Test-DgAPeerSummary $peerDuplicateText 0
    Record 'PEER_FIXTURE_TEST' 'peer_duplicate_field_invalid' (!$prPeerDuplicate.EvidenceContractValid)

    # --- Peer evidence: valid summary, CRC_ERROR=1 -> evidence valid, logical FAIL ---
    $peerCrcErrorText = ($peerPassText -replace 'CRC_ERROR=0','CRC_ERROR=1' -replace 'PEER_RESULT=PASS','PEER_RESULT=FAIL')
    $prCrcError = Test-DgAPeerSummary $peerCrcErrorText 0
    Record 'PEER_FIXTURE_TEST' 'peer_crc_error_evidence_still_valid' $prCrcError.EvidenceContractValid
    Record 'PEER_FIXTURE_TEST' 'peer_crc_error_logical_fail' (!$prCrcError.LogicalPass)
    $clsPeerFail = Get-DgAClassification $noProvisional $sr $true $prCrcError $reconAll ""
    Record 'CLASSIFICATION_TEST' 'peer_strict_fail_dg_a_peer_fail' ($clsPeerFail.Primary -eq 'DG_A_PEER_FAIL')

    # --- Reconciliation: firmware PASS + peer PASS + count mismatch -> DG_A_RECONCILIATION_FAIL ---
    # LAST_SEQUENCE is adjusted alongside VALID_RX_TOTAL (498 = 499-1) so the peer
    # stays internally stream-consistent (Layer 3 / B-20 5.4 still LogicalPass) --
    # only the cross-stream device-vs-peer count (Layer 4) disagrees.
    $peerReconMismatchText = ($peerPassText -replace 'VALID_RX_TOTAL=500','VALID_RX_TOTAL=499' -replace 'LAST_SEQUENCE=499','LAST_SEQUENCE=498')
    $prReconMismatch = Test-DgAPeerSummary $peerReconMismatchText 0
    Record 'PEER_FIXTURE_TEST' 'reconciliation_mismatch_peer_internally_consistent' $prReconMismatch.LogicalPass
    $reconMismatch = Test-DgAReconciliation $sr $prReconMismatch
    Record 'RECONCILIATION_FIXTURE_TEST' 'reconciliation_mismatch_detected' (!$reconMismatch.Pass)
    $clsRecon = Get-DgAClassification $noProvisional $sr $true $prReconMismatch $reconMismatch ""
    Record 'CLASSIFICATION_TEST' 'reconciliation_mismatch' ($clsRecon.Primary -eq 'DG_A_RECONCILIATION_FAIL')

    # --- USB detach precedence (Tier 1), via the B-17 raw provisional detector ---
    $detachSerial="$passStats`nUSB_DETACH`nTEST_COMPLETE=FAIL TEST_MODE=17 TEST_MODE_NAME=USB_FIXED10_UDP_TX_RX_POLL_EMPTY REASON=USB_DETACH_OR_UNSUPPORTED FINAL_USB_STATE=12 FINAL_HID_READY=0 HID_READY_DROP=1 HID_STALL_COUNT=0 FINAL_PHY_OK=1 FINAL_VERSION_OK=1 FINAL_BUFFER_MAP_OK=1 MAX_REGISTER_TRIPLE_READ_MISMATCH=0 SPI_CORRUPTION_SUSPECTED=0`nSCOPE_MARKER trial=DG-A event=TRIAL_COMPLETE result=FAIL"
    $srDetach = Test-DgASerialLog $detachSerial
    $detachProvisional = Get-DgARawProvisionalPrimary $detachSerial
    Record 'RAW_PROVISIONAL_TEST' 'usb_detach_provisional_detected' ($detachProvisional -eq 'DG_A_USB_HID_FAIL')
    $clsDetach = Get-DgAClassification $detachProvisional $srDetach $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'usb_detach_primary' ($clsDetach.Primary -eq 'DG_A_USB_HID_FAIL')

    # USB detach + peer graceful flush succeeds -> PRIMARY unchanged
    $clsDetachFlushOk = Get-DgAClassification $detachProvisional $srDetach $true $prAll $reconAll ""
    Record 'CLASSIFICATION_TEST' 'usb_detach_peer_flush_ok_primary_unchanged' ($clsDetachFlushOk.Primary -eq 'DG_A_USB_HID_FAIL')

    # USB detach + peer graceful flush fails/times out -> PRIMARY unchanged, SECONDARY set (B-14)
    $clsDetachFlushFail = Get-DgAClassification $detachProvisional $srDetach $false $null $null "PEER_EVIDENCE_INCOMPLETE"
    Record 'CLASSIFICATION_TEST' 'usb_detach_peer_flush_fail_primary_unchanged' ($clsDetachFlushFail.Primary -eq 'DG_A_USB_HID_FAIL')
    Record 'CLASSIFICATION_TEST' 'usb_detach_peer_flush_fail_secondary_set' ($clsDetachFlushFail.Secondary -eq 'PEER_EVIDENCE_INCOMPLETE')

    # --- B-17: raw USB detach + malformed peer numeric data -> PRIMARY unchanged ---
    $clsDetachMalformedPeer = Get-DgAClassification $detachProvisional $srDetach $true $prMalformed $null "EVIDENCE_PARSER_INCOMPLETE"
    Record 'CLASSIFICATION_TEST' 'b17_usb_detach_malformed_peer_primary_unchanged' ($clsDetachMalformedPeer.Primary -eq 'DG_A_USB_HID_FAIL')
    Record 'CLASSIFICATION_TEST' 'b17_usb_detach_malformed_peer_secondary_set' ($clsDetachMalformedPeer.Secondary -eq 'EVIDENCE_PARSER_INCOMPLETE')

    # --- B-17: raw USB detach + serial structured parser invalid -> PRIMARY unchanged, no exception ---
    $detachMalformedSerial = ($detachSerial -replace 'FINAL_USB_STATE=12','FINAL_USB_STATE=ZZ')
    $detachMalformedProvisional = Get-DgARawProvisionalPrimary $detachMalformedSerial
    $srDetachMalformed = Test-DgASerialLog $detachMalformedSerial
    Record 'SERIAL_FIXTURE_TEST' 'b17_detach_malformed_serial_no_exception' $true
    $clsDetachMalformedSerial = Get-DgAClassification $detachMalformedProvisional $srDetachMalformed $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'b17_usb_detach_malformed_serial_primary_unchanged' ($clsDetachMalformedSerial.Primary -eq 'DG_A_USB_HID_FAIL')

    # RX_POLL_POSITIVE_TOTAL > 0 -> BLOCKED_DG_A_UNEXPECTED_RX_ACTIVITY
    # (Built from $passTerminal, not hand-typed, so every required normal-schema
    # TEST_COMPLETE field -- DURATION_MS/TRIAL_RUNTIME_MS/HID_REPORT_TOTAL/VID/PID/
    # etc, all always present on a real dgAFinish() line -- stays complete.)
    $rxPositiveSerial="$passStats`n$($passTerminal -replace 'TEST_COMPLETE=PASS','TEST_COMPLETE=FAIL' -replace 'REASON=DURATION_COMPLETE','REASON=BLOCKED_DG_A_UNEXPECTED_RX_ACTIVITY')`n$($scope -replace 'result=PASS','result=FAIL')"
    $srRxPositive = Test-DgASerialLog $rxPositiveSerial
    $rxPositiveProvisional = Get-DgARawProvisionalPrimary $rxPositiveSerial
    $clsRxPositive = Get-DgAClassification $rxPositiveProvisional $srRxPositive $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'rx_poll_positive_blocked_unexpected_rx' ($clsRxPositive.Primary -eq 'BLOCKED_DG_A_UNEXPECTED_RX_ACTIVITY')

    # RX_POLL_NEGATIVE_ERROR > 0 -> DG_A_RX_POLL_API_FAIL
    $rxNegativeSerial="$passStats`n$($passTerminal -replace 'TEST_COMPLETE=PASS','TEST_COMPLETE=FAIL' -replace 'REASON=DURATION_COMPLETE','REASON=DG_A_RX_POLL_API_FAIL')`n$($scope -replace 'result=PASS','result=FAIL')"
    $srRxNegative = Test-DgASerialLog $rxNegativeSerial
    $rxNegativeProvisional = Get-DgARawProvisionalPrimary $rxNegativeSerial
    $clsRxNegative = Get-DgAClassification $rxNegativeProvisional $srRxNegative $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'rx_poll_negative_api_fail' ($clsRxNegative.Primary -eq 'DG_A_RX_POLL_API_FAIL')

    # RX_READ_CALL_TOTAL > 0 -> BLOCKED_DG_A_RX_READ_PATH_REACHED
    $rxReadCallSerial=($passSerial -replace 'RX_READ_CALL_TOTAL=0','RX_READ_CALL_TOTAL=1')
    $srRxReadCall = Test-DgASerialLog $rxReadCallSerial
    $rxReadCallProvisional = Get-DgARawProvisionalPrimary $rxReadCallSerial
    $clsRxReadCall = Get-DgAClassification $rxReadCallProvisional $srRxReadCall $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'rx_read_call_total_blocked' ($clsRxReadCall.Primary -eq 'BLOCKED_DG_A_RX_READ_PATH_REACHED')

    # RX_READ_BYTES_TOTAL > 0 -> BLOCKED_DG_A_RX_READ_PATH_REACHED
    $rxReadBytesSerial=($passSerial -replace 'RX_READ_BYTES_TOTAL=0','RX_READ_BYTES_TOTAL=32')
    $srRxReadBytes = Test-DgASerialLog $rxReadBytesSerial
    $rxReadBytesProvisional = Get-DgARawProvisionalPrimary $rxReadBytesSerial
    $clsRxReadBytes = Get-DgAClassification $rxReadBytesProvisional $srRxReadBytes $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'rx_read_bytes_total_blocked' ($clsRxReadBytes.Primary -eq 'BLOCKED_DG_A_RX_READ_PATH_REACHED')

    # PEER_TX_TO_DEVICE_TOTAL > 0 -> BLOCKED_PEER_TX_TO_DEVICE_NONZERO
    $peerTxNonzeroText = ($peerPassText -replace 'PEER_TX_TO_DEVICE_TOTAL=0','PEER_TX_TO_DEVICE_TOTAL=1')
    $prTxNonzero = Test-DgAPeerSummary $peerTxNonzeroText 0
    $clsTxNonzero = Get-DgAClassification $noProvisional $sr $true $prTxNonzero $reconAll ""
    Record 'CLASSIFICATION_TEST' 'peer_tx_nonzero_blocked' ($clsTxNonzero.Primary -eq 'BLOCKED_PEER_TX_TO_DEVICE_NONZERO')

    # peer BLOCKED_ADMISSION_SEQUENCE_MISS
    $peerBlockedText = @('PEER_COMPLETE=1','RX_TOTAL=1','VALID_RX_TOTAL=0','FIRST_SEQUENCE=NONE','LAST_SEQUENCE=NONE','EXPECTED_SOURCE_IP=192.168.50.10','EXPECTED_SOURCE_PORT=50001','PEER_RESULT=BLOCKED_ADMISSION_SEQUENCE_MISS','CRC_ERROR=0','LENGTH_ERROR=0','FORMAT_ERROR=0','PAYLOAD_ERROR=0','UNEXPECTED_SOURCE=0','SEQ_GAP=0','DUPLICATE=0','OUT_OF_ORDER=0','FLAGS_ERROR=0','SOURCE_PORT_ERROR=0','PEER_ARMED=1','ADMISSION_SEQUENCE_ZERO_OK=0','BLOCKED_ADMISSION_SEQUENCE_MISS=1','BOUND_NOT_ARMED_PACKET_COUNT=0','PRE_ADMISSION_NON_C1_COUNT=0','PEER_TX_TO_DEVICE_TOTAL=0') -join "`n"
    $prBlocked = Test-DgAPeerSummary $peerBlockedText 3
    Record 'PEER_FIXTURE_TEST' 'peer_blocked_evidence_contract_valid' $prBlocked.EvidenceContractValid
    $clsBlocked = Get-DgAClassification $noProvisional $sr $true $prBlocked $null ""
    Record 'CLASSIFICATION_TEST' 'peer_blocked_admission_sequence_miss' ($clsBlocked.Primary -eq 'BLOCKED_ADMISSION_SEQUENCE_MISS')

    # scheduler missed deadline -> DG_A_TIMING_FAIL (firmware PASS re-checked and downgraded)
    $timingSerial = "$($passStats -replace 'SCHEDULER_MISSED_DEADLINE=0','SCHEDULER_MISSED_DEADLINE=3')`n$passTerminal`n$scope"
    $srTiming = Test-DgASerialLog $timingSerial
    $timingProvisional = Get-DgARawProvisionalPrimary $timingSerial
    $clsTiming = Get-DgAClassification $timingProvisional $srTiming $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'scheduler_missed_deadline_timing_fail' ($clsTiming.Primary -eq 'DG_A_TIMING_FAIL')

    # PHY/version/buffer-map failure -> DG_A_PHY_HEALTH_FAIL
    $phySerial = "$passStats`n$($passTerminal -replace 'FINAL_PHY_OK=1','FINAL_PHY_OK=0')`n$scope"
    $srPhy = Test-DgASerialLog $phySerial
    $phyProvisional = Get-DgARawProvisionalPrimary $phySerial
    $clsPhy = Get-DgAClassification $phyProvisional $srPhy $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'phy_health_fail' ($clsPhy.Primary -eq 'DG_A_PHY_HEALTH_FAIL')

    # MAX register mismatch -> DG_A_MAX_SPI_CANARY_FAIL
    $maxSerial = "$passStats`n$($passTerminal -replace 'MAX_REGISTER_TRIPLE_READ_MISMATCH=0','MAX_REGISTER_TRIPLE_READ_MISMATCH=2')`n$scope"
    $srMax = Test-DgASerialLog $maxSerial
    $maxProvisional = Get-DgARawProvisionalPrimary $maxSerial
    $clsMax = Get-DgAClassification $maxProvisional $srMax $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'max_spi_canary_fail' ($clsMax.Primary -eq 'DG_A_MAX_SPI_CANARY_FAIL')

    # reviewed source/dependency identity mismatch -> thrown directly, not classified (see manifest fixtures above)
    Record 'CLASSIFICATION_TEST' 'reviewed_source_identity_mismatch_thrown_not_classified' $true 'covered by MANIFEST_AUTHORITY_TEST step_b_content_mismatch_blocked'

    # TEST_COMPLETE=FAIL, unknown REASON -> DG_A_FIRMWARE_FAIL_UNCLASSIFIED (B-07)
    $unknownSerial = "$passStats`n$($passTerminal -replace 'TEST_COMPLETE=PASS','TEST_COMPLETE=FAIL' -replace 'REASON=DURATION_COMPLETE','REASON=SOME_UNKNOWN_REASON')`n$($scope -replace 'result=PASS','result=FAIL')"
    $srUnknown = Test-DgASerialLog $unknownSerial
    $unknownProvisional = Get-DgARawProvisionalPrimary $unknownSerial
    $clsUnknown = Get-DgAClassification $unknownProvisional $srUnknown $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'unknown_fail_reason_unclassified' ($clsUnknown.Primary -eq 'DG_A_FIRMWARE_FAIL_UNCLASSIFIED')
    Record 'CLASSIFICATION_TEST' 'unknown_fail_reason_preserved' ($clsUnknown.OriginalReason -ceq 'SOME_UNKNOWN_REASON')

    # TEST_COMPLETE=PASS, required field missing -> BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID (B-07)
    $missingFieldSerial = ($passSerial -replace ' RX_POLL_CALL_TOTAL=500','')
    $srMissing = Test-DgASerialLog $missingFieldSerial
    $missingProvisional = Get-DgARawProvisionalPrimary $missingFieldSerial
    $clsMissing = Get-DgAClassification $missingProvisional $srMissing $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'missing_required_field_evidence_invalid' ($clsMissing.Primary -eq 'BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID')

    # TEST_COMPLETE=PASS, TEST_MODE_NAME wrong -> BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID (B-07)
    $wrongModeNameSerial = ($passSerial -replace 'TEST_MODE_NAME=USB_FIXED10_UDP_TX_RX_POLL_EMPTY','TEST_MODE_NAME=USB_FIXED10_UDP_ECHO')
    $srWrongModeName = Test-DgASerialLog $wrongModeNameSerial
    $wrongModeNameProvisional = Get-DgARawProvisionalPrimary $wrongModeNameSerial
    $clsWrongModeName = Get-DgAClassification $wrongModeNameProvisional $srWrongModeName $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'wrong_test_mode_name_evidence_invalid' ($clsWrongModeName.Primary -eq 'BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID')

    # BLOCKED_DG_A_UNEXPECTED_RX_ACTIVITY terminal + peer summary flush succeeds -> primary unchanged
    $clsRxPositiveFlushOk = Get-DgAClassification $rxPositiveProvisional $srRxPositive $true $prAll $reconAll ""
    Record 'CLASSIFICATION_TEST' 'blocked_rx_activity_peer_flush_ok_unchanged' ($clsRxPositiveFlushOk.Primary -eq 'BLOCKED_DG_A_UNEXPECTED_RX_ACTIVITY')

    # missing terminal evidence entirely (no DG_A_FINAL/TEST_COMPLETE/DG_A_SETUP_FAIL)
    # + peer graceful stop attempted -> ORCHESTRATION_STALL/TIMEOUT
    $noTerminalSerial = "STARTUP_ONLY=1"
    $srNoTerminal = Test-DgASerialLog $noTerminalSerial
    $noTerminalProvisional = Get-DgARawProvisionalPrimary $noTerminalSerial
    Record 'SERIAL_FIXTURE_TEST' 'no_evidence_flag_set' $srNoTerminal.NoEvidence
    $clsNoTerminal = Get-DgAClassification $noTerminalProvisional $srNoTerminal $false $null $null "PEER_GRACEFUL_STOP_ATTEMPTED"
    Record 'CLASSIFICATION_TEST' 'missing_terminal_orchestration_stall' ($clsNoTerminal.Primary -eq 'ORCHESTRATION_STALL/TIMEOUT')

    # --- B-18: REASON / VERSIONR required exactly once; dual-authority consistency ---
    $reasonMissingSerial = ($passSerial -replace ' REASON=DURATION_COMPLETE','')
    $srReasonMissing = Test-DgASerialLog $reasonMissingSerial
    Record 'SERIAL_FIXTURE_TEST' 'terminal_reason_missing_invalid' (!$srReasonMissing.EvidenceContractValid)

    $versionrMissingSerial = ($passSerial -replace ' VERSIONR=04','')
    $srVersionrMissing = Test-DgASerialLog $versionrMissingSerial
    Record 'SERIAL_FIXTURE_TEST' 'terminal_versionr_missing_invalid' (!$srVersionrMissing.EvidenceContractValid)

    $versionrWrongSerial = ($passSerial -replace 'VERSIONR=04','VERSIONR=00')
    $srVersionrWrong = Test-DgASerialLog $versionrWrongSerial
    Record 'SERIAL_FIXTURE_TEST' 'terminal_versionr_wrong_evidence_valid' $srVersionrWrong.EvidenceContractValid
    Record 'SERIAL_FIXTURE_TEST' 'terminal_versionr_wrong_hard_criteria_fail' (!$srVersionrWrong.HardCriteriaPass)
    $versionrWrongProvisional = Get-DgARawProvisionalPrimary $versionrWrongSerial
    $clsVersionrWrong = Get-DgAClassification $versionrWrongProvisional $srVersionrWrong $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'versionr_wrong_phy_health_fail' ($clsVersionrWrong.Primary -eq 'DG_A_PHY_HEALTH_FAIL')

    $hidStallMismatchSerial = "$($passStats -replace 'HID_STALL_COUNT=0','HID_STALL_COUNT=1')`n$passTerminal`n$scope"
    $srHidStallMismatch = Test-DgASerialLog $hidStallMismatchSerial
    Record 'SERIAL_FIXTURE_TEST' 'dual_authority_hid_stall_count_mismatch_invalid' (!$srHidStallMismatch.EvidenceContractValid)

    $hidMaxNoReportMismatchSerial = "$($passStats -replace 'HID_MAX_NO_REPORT_MS=5','HID_MAX_NO_REPORT_MS=99')`n$passTerminal`n$scope"
    $srHidMaxNoReportMismatch = Test-DgASerialLog $hidMaxNoReportMismatchSerial
    Record 'SERIAL_FIXTURE_TEST' 'dual_authority_hid_max_no_report_ms_mismatch_invalid' (!$srHidMaxNoReportMismatch.EvidenceContractValid)

    # --- B-19: actual-firmware-shaped TEST_COMPLETE=FAIL + REASON=DURATION_COMPLETE
    # + a measured hard-criterion violation must classify by the measured criterion,
    # not fall through to DG_A_FIRMWARE_FAIL_UNCLASSIFIED. ---
    $timingFailShapeSerial = "$($passStats -replace 'SCHEDULER_MISSED_DEADLINE=0','SCHEDULER_MISSED_DEADLINE=1')`n$($passTerminal -replace 'TEST_COMPLETE=PASS','TEST_COMPLETE=FAIL')`n$($scope -replace 'result=PASS','result=FAIL')"
    $srTimingFailShape = Test-DgASerialLog $timingFailShapeSerial
    $timingFailShapeProvisional = Get-DgARawProvisionalPrimary $timingFailShapeSerial
    $clsTimingFailShape = Get-DgAClassification $timingFailShapeProvisional $srTimingFailShape $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'b19_actual_shape_scheduler_missed_deadline_timing_fail' ($clsTimingFailShape.Primary -eq 'DG_A_TIMING_FAIL')

    $phyFailShapeSerial = "$passStats`n$($passTerminal -replace 'TEST_COMPLETE=PASS','TEST_COMPLETE=FAIL' -replace 'FINAL_PHY_OK=1','FINAL_PHY_OK=0')`n$($scope -replace 'result=PASS','result=FAIL')"
    $srPhyFailShape = Test-DgASerialLog $phyFailShapeSerial
    $phyFailShapeProvisional = Get-DgARawProvisionalPrimary $phyFailShapeSerial
    $clsPhyFailShape = Get-DgAClassification $phyFailShapeProvisional $srPhyFailShape $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'b19_actual_shape_final_phy_not_ok_phy_health_fail' ($clsPhyFailShape.Primary -eq 'DG_A_PHY_HEALTH_FAIL')

    $rxPollStallShapeSerial = "$($passStats -replace 'RX_POLL_CALL_TOTAL=500','RX_POLL_CALL_TOTAL=0')`n$($passTerminal -replace 'TEST_COMPLETE=PASS','TEST_COMPLETE=FAIL')`n$($scope -replace 'result=PASS','result=FAIL')"
    $srRxPollStallShape = Test-DgASerialLog $rxPollStallShapeSerial
    $rxPollStallShapeProvisional = Get-DgARawProvisionalPrimary $rxPollStallShapeSerial
    $clsRxPollStallShape = Get-DgAClassification $rxPollStallShapeProvisional $srRxPollStallShape $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'b19_actual_shape_rx_poll_call_total_zero_path_stall' ($clsRxPollStallShape.Primary -eq 'DG_A_RX_POLL_PATH_STALL')

    $maxCanaryShapeSerial = "$passStats`n$($passTerminal -replace 'TEST_COMPLETE=PASS','TEST_COMPLETE=FAIL' -replace 'MAX_REGISTER_TRIPLE_READ_MISMATCH=0','MAX_REGISTER_TRIPLE_READ_MISMATCH=1')`n$($scope -replace 'result=PASS','result=FAIL')"
    $srMaxCanaryShape = Test-DgASerialLog $maxCanaryShapeSerial
    $maxCanaryShapeProvisional = Get-DgARawProvisionalPrimary $maxCanaryShapeSerial
    $clsMaxCanaryShape = Get-DgAClassification $maxCanaryShapeProvisional $srMaxCanaryShape $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'b19_actual_shape_max_register_mismatch_canary_fail' ($clsMaxCanaryShape.Primary -eq 'DG_A_MAX_SPI_CANARY_FAIL')

    # --- B-20: peer typed field validation (IP/port exact value, sequence schema) ---
    $peerPortGarbageText = ($peerPassText -replace 'EXPECTED_SOURCE_PORT=50001','EXPECTED_SOURCE_PORT=garbage')
    $prPeerPortGarbage = Test-DgAPeerSummary $peerPortGarbageText 0
    Record 'PEER_FIXTURE_TEST' 'peer_port_garbage_no_exception' $true
    Record 'PEER_FIXTURE_TEST' 'peer_port_garbage_invalid' (!$prPeerPortGarbage.EvidenceContractValid)

    $peerPortWrongText = ($peerPassText -replace 'EXPECTED_SOURCE_PORT=50001','EXPECTED_SOURCE_PORT=50002')
    $prPeerPortWrong = Test-DgAPeerSummary $peerPortWrongText 0
    Record 'PEER_FIXTURE_TEST' 'peer_port_wrong_value_invalid' (!$prPeerPortWrong.EvidenceContractValid)

    $peerIpGarbageText = ($peerPassText -replace 'EXPECTED_SOURCE_IP=192.168.50.10','EXPECTED_SOURCE_IP=garbage')
    $prPeerIpGarbage = Test-DgAPeerSummary $peerIpGarbageText 0
    Record 'PEER_FIXTURE_TEST' 'peer_ip_garbage_invalid' (!$prPeerIpGarbage.EvidenceContractValid)

    $peerIpWrongText = ($peerPassText -replace 'EXPECTED_SOURCE_IP=192.168.50.10','EXPECTED_SOURCE_IP=192.168.50.99')
    $prPeerIpWrong = Test-DgAPeerSummary $peerIpWrongText 0
    Record 'PEER_FIXTURE_TEST' 'peer_ip_wrong_value_invalid' (!$prPeerIpWrong.EvidenceContractValid)

    $peerLastSeqGarbageText = ($peerPassText -replace 'LAST_SEQUENCE=499','LAST_SEQUENCE=garbage')
    $prPeerLastSeqGarbage = Test-DgAPeerSummary $peerLastSeqGarbageText 0
    Record 'PEER_FIXTURE_TEST' 'peer_last_sequence_garbage_no_exception' $true
    Record 'PEER_FIXTURE_TEST' 'peer_last_sequence_garbage_invalid' (!$prPeerLastSeqGarbage.EvidenceContractValid)

    # valid stream FIRST_SEQUENCE=0 VALID_RX_TOTAL=500 LAST_SEQUENCE=499 -> peer PASS-compatible
    Record 'PEER_FIXTURE_TEST' 'peer_valid_stream_pass_compatible' $prAll.LogicalPass

    # parseable but stream-inconsistent (LAST_SEQUENCE=498, expected 499) -> DG_A_PEER_FAIL
    $peerStreamInconsistentText = ($peerPassText -replace 'LAST_SEQUENCE=499','LAST_SEQUENCE=498')
    $prStreamInconsistent = Test-DgAPeerSummary $peerStreamInconsistentText 0
    Record 'PEER_FIXTURE_TEST' 'peer_stream_inconsistent_evidence_valid' $prStreamInconsistent.EvidenceContractValid
    Record 'PEER_FIXTURE_TEST' 'peer_stream_inconsistent_logical_fail' (!$prStreamInconsistent.LogicalPass)
    $clsStreamInconsistent = Get-DgAClassification $noProvisional $sr $true $prStreamInconsistent $null ""
    Record 'CLASSIFICATION_TEST' 'peer_stream_inconsistent_dg_a_peer_fail' ($clsStreamInconsistent.Primary -eq 'DG_A_PEER_FAIL')

    # --- B-21: normal-runtime REASON closed-world validation ---
    $unknownPassReasonSerial = ($passSerial -replace 'REASON=DURATION_COMPLETE','REASON=SOME_UNKNOWN_REASON')
    $srUnknownPassReason = Test-DgASerialLog $unknownPassReasonSerial
    Record 'SERIAL_FIXTURE_TEST' 'b21_unknown_pass_reason_evidence_invalid' (!$srUnknownPassReason.EvidenceContractValid)
    $unknownPassReasonProvisional = Get-DgARawProvisionalPrimary $unknownPassReasonSerial
    $clsUnknownPassReason = Get-DgAClassification $unknownPassReasonProvisional $srUnknownPassReason $true $prAll $reconAll ""
    Record 'CLASSIFICATION_TEST' 'b21_unknown_pass_reason_never_pass' ($clsUnknownPassReason.Primary -ne 'PASS')
    Record 'CLASSIFICATION_TEST' 'b21_unknown_pass_reason_evidence_contract_invalid' ($clsUnknownPassReason.Primary -eq 'BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID')

    Record 'CLASSIFICATION_TEST' 'b21_duration_complete_reason_pass_compatible' ($clsAll.Primary -eq 'PASS')

    $unknownSetupReasonSerial = "DIAGNOSTIC_BOOT TEST_MODE=17`nDG_A_SETUP_FAIL=1 REASON=SOME_UNKNOWN_SETUP_REASON`nTEST_COMPLETE=FAIL TEST_MODE=17 TEST_MODE_NAME=USB_FIXED10_UDP_TX_RX_POLL_EMPTY REASON=SOME_UNKNOWN_SETUP_REASON FINAL_USB_STATE=00 FINAL_HID_READY=0 HID_READY_DROP=0`nSCOPE_MARKER trial=DG-A event=TRIAL_COMPLETE result=FAIL"
    $srUnknownSetupReason = Test-DgASerialLog $unknownSetupReasonSerial
    Record 'SERIAL_FIXTURE_TEST' 'b21_unknown_setup_reason_evidence_invalid' (!$srUnknownSetupReason.EvidenceContractValid)
    $unknownSetupReasonProvisional = Get-DgARawProvisionalPrimary $unknownSetupReasonSerial
    $clsUnknownSetupReason = Get-DgAClassification $unknownSetupReasonProvisional $srUnknownSetupReason $false $null $null ""
    Record 'CLASSIFICATION_TEST' 'b21_unknown_setup_reason_blocked' ($clsUnknownSetupReason.Primary -eq 'BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID')

    # B-21 coverage check: every known named FAIL-path reason from
    # $dgANormalRuntimeKnownReasons (excluding DURATION_COMPLETE, the PASS-semantics
    # reason already covered above) must resolve to a *specific* classification,
    # never the generic DG_A_FIRMWARE_FAIL_UNCLASSIFIED fallback -- a direct,
    # source-grounded coverage check rather than an assumption that the classifier
    # handles the whole inventoried vocabulary.
    foreach ($knownReason in ($dgANormalRuntimeKnownReasons | Where-Object { $_ -ne 'DURATION_COMPLETE' })) {
        $knownReasonSerial = "$passStats`n$($passTerminal -replace 'TEST_COMPLETE=PASS','TEST_COMPLETE=FAIL' -replace 'REASON=DURATION_COMPLETE',"REASON=$knownReason")`n$($scope -replace 'result=PASS','result=FAIL')"
        $srKnownReason = Test-DgASerialLog $knownReasonSerial
        $knownReasonProvisional = Get-DgARawProvisionalPrimary $knownReasonSerial
        $clsKnownReason = Get-DgAClassification $knownReasonProvisional $srKnownReason $false $null $null ""
        Record 'CLASSIFICATION_TEST' "b21_known_reason_not_unclassified_$knownReason" ($clsKnownReason.Primary -ne 'DG_A_FIRMWARE_FAIL_UNCLASSIFIED')
    }

    # --- B-22: true uint32-range, non-throwing FIRST_SEQUENCE/LAST_SEQUENCE parsing ---
    $peerFirstSeqOverflowText = ($peerPassText -replace 'FIRST_SEQUENCE=0','FIRST_SEQUENCE=4294967296')
    $prFirstSeqOverflow = Test-DgAPeerSummary $peerFirstSeqOverflowText 0
    Record 'PEER_FIXTURE_TEST' 'b22_first_sequence_overflow_no_exception' $true
    Record 'PEER_FIXTURE_TEST' 'b22_first_sequence_overflow_invalid' (!$prFirstSeqOverflow.EvidenceContractValid)

    $peerLastSeqOverflowText = ($peerPassText -replace 'LAST_SEQUENCE=499','LAST_SEQUENCE=4294967296')
    $prLastSeqOverflow = Test-DgAPeerSummary $peerLastSeqOverflowText 0
    Record 'PEER_FIXTURE_TEST' 'b22_last_sequence_overflow_no_exception' $true
    Record 'PEER_FIXTURE_TEST' 'b22_last_sequence_overflow_invalid' (!$prLastSeqOverflow.EvidenceContractValid)

    $peerLastSeqHugeOverflowText = ($peerPassText -replace 'LAST_SEQUENCE=499','LAST_SEQUENCE=18446744073709551616')
    $prLastSeqHugeOverflow = Test-DgAPeerSummary $peerLastSeqHugeOverflowText 0
    Record 'PEER_FIXTURE_TEST' 'b22_last_sequence_huge_overflow_no_exception' $true
    Record 'PEER_FIXTURE_TEST' 'b22_last_sequence_huge_overflow_invalid' (!$prLastSeqHugeOverflow.EvidenceContractValid)

    # --- B-23: exact HORI VID/PID identity validation ---
    $vidWrongSerial = ($passSerial -replace 'VID=0F0D','VID=1234')
    $srVidWrong = Test-DgASerialLog $vidWrongSerial
    Record 'SERIAL_FIXTURE_TEST' 'b23_vid_wrong_invalid' (!$srVidWrong.EvidenceContractValid)

    $pidWrongSerial = ($passSerial -replace 'PID=0202','PID=5678')
    $srPidWrong = Test-DgASerialLog $pidWrongSerial
    Record 'SERIAL_FIXTURE_TEST' 'b23_pid_wrong_invalid' (!$srPidWrong.EvidenceContractValid)

    Record 'SERIAL_FIXTURE_TEST' 'b23_vid_pid_correct_identity_pass_compatible' $sr.EvidenceContractValid

    # --- B-24: fixed physical PC peer IP identity (192.168.50.30, reused
    # unchanged from the C1/C2-accepted physical topology) ---
    try { Assert-DgAPeerIpIdentity $fixedPeerIp; Record 'PEER_IP_IDENTITY_TEST' 'exact_fixed_value_pass_compatible' $true } catch { Record 'PEER_IP_IDENTITY_TEST' 'exact_fixed_value_pass_compatible' $false $_.Exception.Message }
    Record 'PEER_IP_IDENTITY_TEST' 'wrong_value_192_168_50_2_blocked' (Expect-Throw {Assert-DgAPeerIpIdentity '192.168.50.2'} 'BLOCKED_DG_A_PEER_IP_IDENTITY_MISMATCH')
    Record 'PEER_IP_IDENTITY_TEST' 'wrong_value_192_168_50_254_blocked' (Expect-Throw {Assert-DgAPeerIpIdentity '192.168.50.254'} 'BLOCKED_DG_A_PEER_IP_IDENTITY_MISMATCH')

    # B-24: default build-only must compile against the fixed peer identity, not
    # the build matrix's own unrelated default -- a direct, source-grounded check
    # on this script's own on-disk text (arduino-cli is never invoked here).
    $selfSourceText = Get-Content -LiteralPath $PSCommandPath -Raw
    Record 'BUILD_ONLY_TEST' 'default_path_uses_fixed_peer_ip' ($selfSourceText -match [regex]::Escape('Invoke-Mode17Build $trialRoot $fixedPeerIp'))

    # B-24: -PreflightPhysicalTrial -EmitPlan must declare and use the fixed
    # peer identity so plan display and runtime behavior cannot drift apart
    # again (N-04/N-05 precedent).
    $script:PeerIp = $fixedPeerIp
    $script:ExpectedPnpDeviceId = 'USB\VID_1234&PID_5678\DGA_FIXTURE'
    $emitPlanOutput = (Invoke-PhysicalTrialPreflight -EmitPlan | Out-String)
    Record 'EMIT_PLAN_TEST' 'fixed_peer_ip_declared' ($emitPlanOutput -match [regex]::Escape("FIXED_PEER_IP=$fixedPeerIp"))
    Record 'EMIT_PLAN_TEST' 'planned_build_command_has_fixed_ip' ($emitPlanOutput -match [regex]::Escape("-C1PeerIp $fixedPeerIp"))
    Record 'EMIT_PLAN_TEST' 'planned_peer_command_has_fixed_ip' ($emitPlanOutput -match [regex]::Escape("--bind-ip $fixedPeerIp"))
    $script:PeerIp = '192.168.50.2'
    Record 'EMIT_PLAN_TEST' 'wrong_peer_ip_blocked' (Expect-Throw {Invoke-PhysicalTrialPreflight -EmitPlan} 'BLOCKED_DG_A_PEER_IP_IDENTITY_MISMATCH')
    $script:PeerIp = ''
    $script:ExpectedPnpDeviceId = ''

    # --- N-09: PEER_RESULT closed-world enum validation ---
    $peerResultGarbageText = ($peerPassText -replace 'PEER_RESULT=PASS','PEER_RESULT=garbage')
    $prPeerResultGarbage = Test-DgAPeerSummary $peerResultGarbageText 0
    Record 'PEER_FIXTURE_TEST' 'n09_peer_result_garbage_no_exception' $true
    Record 'PEER_FIXTURE_TEST' 'n09_peer_result_garbage_invalid' (!$prPeerResultGarbage.EvidenceContractValid)
    $clsPeerResultGarbage = Get-DgAClassification $noProvisional $sr $true $prPeerResultGarbage $null ""
    Record 'CLASSIFICATION_TEST' 'n09_peer_result_garbage_not_peer_fail' ($clsPeerResultGarbage.Primary -ne 'DG_A_PEER_FAIL')
    Record 'CLASSIFICATION_TEST' 'n09_peer_result_garbage_evidence_contract_invalid' ($clsPeerResultGarbage.Primary -eq 'BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID')

    # N-09: existing PASS/FAIL/BLOCKED_ADMISSION_SEQUENCE_MISS semantics preserved
    # (peer_pass_logical_pass / peerCrcErrorText / peer_blocked_admission_sequence_miss
    # above already exercise these; this is a direct re-affirmation tied to the enum
    # change itself).
    Record 'PEER_FIXTURE_TEST' 'n09_known_value_pass_still_evidence_valid' $prAll.EvidenceContractValid
    Record 'PEER_FIXTURE_TEST' 'n09_known_value_blocked_still_evidence_valid' $prBlocked.EvidenceContractValid

    $failed=@($results|Where-Object Pass -eq $false)
    Write-Output "RUNNER_OFFLINE_TESTS=$(if($failed.Count -eq 0){'PASS'}else{'FAIL'}) TESTS=$($results.Count) FAILED=$($failed.Count)"
    if($failed.Count){throw "Runner offline fixture failure: $($failed.Name -join ',')"}
}

# ---------------------------------------------------------------------------
# Top-level dispatch. Only -RunOfflineTests, the default build-only path
# (Phase A), and -PreflightPhysicalTrial -EmitPlan run in this session.
# ---------------------------------------------------------------------------

if ($RunOfflineTests) {
    if ($RunPhysicalTrial -or $VerifyReviewedManifest -or $PreflightPhysicalTrial -or $AllowUpload -or $AllowSerial -or $AllowPeer -or $AllowNetworkTrial) {
        throw "Offline tests prohibit physical permission switches."
    }
    Invoke-OfflineTests
    return
}

if ($VerifyReviewedManifest) {
    if ($RunPhysicalTrial -or $PreflightPhysicalTrial -or $AllowUpload -or $AllowSerial -or $AllowPeer -or $AllowNetworkTrial) {
        throw "Manifest-only verification prohibits physical permission switches."
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedReviewedManifestSha256)) {
        # No accepted Phase B authority exists yet for DG-A this session: only
        # Phase A candidate consistency can be verified.
        if (!(Test-Path -LiteralPath $candidateManifest)) { throw "No candidate manifest to verify: $candidateManifest" }
        Write-Output "CANDIDATE_MANIFEST_PRESENT=1 PATH=$candidateManifest"
        Write-Output "PHASE_B_AUTHORITY=NOT_AVAILABLE_THIS_SESSION"
    } else {
        Assert-ReviewedManifestAuthority $ReviewedManifestPath $ExpectedReviewedManifestSha256
        Write-Output "REVIEWED_SOURCE_MANIFEST_RESULT=PASS"
    }
    Write-Output "UPLOAD=NOT_RUN SERIAL=NOT_OPENED PEER=NOT_STARTED NETWORK_TRIAL=NOT_RUN"
    return
}

if ($PreflightPhysicalTrial) {
    if ($RunPhysicalTrial -or $AllowUpload -or $AllowSerial -or $AllowPeer -or $AllowNetworkTrial) {
        throw "Physical preflight is read-only and prohibits all physical permission switches."
    }
    Invoke-PhysicalTrialPreflight -EmitPlan
    Write-Output "DG_A_PHYSICAL_PREFLIGHT=PLAN_EMITTED_ONLY"
    Write-Output "UPLOAD=NOT_RUN"
    Write-Output "SERIAL=NOT_OPENED"
    Write-Output "PEER=NOT_STARTED"
    Write-Output "NETWORK_TRAFFIC=NOT_RUN"
    return
}

if ($RunPhysicalTrial) {
    # Implemented as real source (Invoke-DgAPhysicalTrial above) but never invoked
    # by this implementation task -- see docs/usb-lan-gate-dg-a-contract.md,
    # "Physical prohibition."
    Invoke-DgAPhysicalTrial
    return
}

# Default: build-only, Phase A candidate identity consistency only.
if ($AllowUpload -or $AllowSerial -or $AllowPeer -or $AllowNetworkTrial) {
    throw "Permission switches are invalid without -RunPhysicalTrial."
}
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
$trialIdentity = "{0}-{1}-{2}" -f $Trial,(Get-Date -Format "yyyyMMdd-HHmmss"),([guid]::NewGuid().ToString("N").Substring(0,8))
$trialRoot = Join-Path $runRoot $trialIdentity
Assert-ChildPath $runRoot $trialRoot
New-Item -ItemType Directory -Path $trialRoot | Out-Null
Write-Output "RUNNER_MODE=BUILD_ONLY"
Write-Output "FIXED_PEER_IP=$fixedPeerIp"
$preSnapshot = Get-DgACandidateSnapshot
Write-Output "CANDIDATE_IDENTITY_PHASE=PRE_BUILD FILES=$($preSnapshot.Count)"
# B-24: build-only always compiles the fixed C1/C2-accepted physical peer
# identity, never the build matrix's own unrelated default -- so a build-only
# PASS is evidence about the actual physical topology DG-A will use.
$buildResult = Invoke-Mode17Build $trialRoot $fixedPeerIp
Write-Output "BUILD_ONLY_PASS=1 CASE=$caseName ROOT=$($buildResult.MatrixRoot) LOG=$($buildResult.StdoutPath)"
$postSnapshot = Get-DgACandidateSnapshot
Write-Output "CANDIDATE_IDENTITY_PHASE=POST_BUILD FILES=$($postSnapshot.Count)"
Assert-DgACandidateConsistency $preSnapshot $postSnapshot
New-DgACandidateManifest $postSnapshot $candidateManifest | Out-Null
Write-Output "UPLOAD=NOT_RUN SERIAL=NOT_OPENED PEER=NOT_STARTED NETWORK_TRIAL=NOT_RUN"
