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
    [ValidateSet("C1-S1", "C1-T1")]
    [string]$Trial = "C1-S1",
    [ValidatePattern('^COM4$')]
    [string]$ComPort = "COM4",
    [string]$ExpectedPnpDeviceId = "",
    [string]$PeerIp = "",
    [string]$SenderIp = "192.168.50.10",
    [string]$ReceiverIp = "192.168.50.20",
    [ValidateRange(5, 120)]
    [int]$ProcessTimeoutSeconds = 30,
    [string]$ReviewedManifestPath = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$matrixScript = Join-Path $PSScriptRoot "usb_lan_diagnostic_build_matrix.ps1"
$peerScript = Join-Path $PSScriptRoot "usb_lan_gate_peer.py"
$runRoot = Join-Path $repoRoot "build-temp\usb-lan-isolation\gate-c1"
$defaultManifest = Join-Path $repoRoot "build-temp\usb-lan-isolation\review\C1-reviewed-source-manifest.csv"
$reviewManifest = if ([string]::IsNullOrWhiteSpace($ReviewedManifestPath)) { $defaultManifest } else { $ReviewedManifestPath }
$fqbn = "m5stack:esp32:m5stack_cores3"
$expectedBranch = "feat/cores3se-dualsense-lan-stack-diagnostic"
$expectedHead = "f915b1c9a33693a2010a1d9527b23743707cfa5d"
$expectedEsp32CoreVersion = "3.3.7"
$fixedSenderIp = "192.168.50.10"
$durationSeconds = if ($Trial -eq "C1-S1") { 10 } else { 60 }
$caseName = if ($Trial -eq "C1-S1") { "mode15-fixed10-udp-tx-only-10s" } else { "mode15-fixed10-udp-tx-only-60s" }
$startedProcesses = [System.Collections.Generic.List[System.Diagnostics.Process]]::new()
$startedJobs = [System.Collections.Generic.List[System.Management.Automation.Job]]::new()

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

    # Windows PowerShell can lose ExitCode for Start-Process -PassThru when
    # stdout/stderr are redirected unless the process handle is materialized
    # before the child exits.  Cache it immediately for every owned process.
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

    # Complete redirected-stream processing before reading the administrative
    # process result, then capture ExitCode exactly once.
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
    # The firmware always uses 255.255.255.0.  The PC interface prefix may be
    # wider, but it must not widen the address range accepted for Gate C1.
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

function Get-C1TrialResultMarker([string]$TrialName) {
    if ($TrialName -notin @('C1-S1','C1-T1')) { throw "Unsupported C1 trial: $TrialName" }
    return "C1_TRIAL_RESULT=PASS TRIAL=$TrialName"
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

function Assert-ReviewedSourceManifest([string]$ManifestFile) {
    if (!(Test-Path -LiteralPath $ManifestFile)) {
        throw "BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH missing_manifest=$ManifestFile"
    }
    $rows = @(Import-Csv -LiteralPath $ManifestFile)
    if ($rows.Count -eq 0) { throw "BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH empty_manifest" }
    foreach ($row in $rows) {
        $path = Resolve-ManifestPath $ManifestFile $row.relative_or_absolute_path
        if (!(Test-Path -LiteralPath $path)) {
            throw "BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH missing=$path"
        }
        $item = Get-Item -LiteralPath $path
        $actualHash = Get-Sha256 $path
        if ($item.Length -ne [int64]$row.size -or $actualHash -cne $row.sha256) {
            throw "BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH role=$($row.role) path=$path"
        }
        if (![string]::IsNullOrWhiteSpace($row.inventory_root)) {
            $inventory = Get-ReviewedDirectoryInventory $row.inventory_root
            if ($inventory.Sha256 -cne $row.sha256) {
                throw "BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH role=$($row.role) inventory_root=$($row.inventory_root)"
            }
            Write-Output "REVIEWED_DIRECTORY_IDENTITY=PASS ROLE=$($row.role) FILES=$($inventory.Files) ROOT=$($row.inventory_root)"
        }
    }
    Write-Output "REVIEWED_SOURCE_IDENTITY=PASS FILES=$($rows.Count) MANIFEST=$ManifestFile"
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
    # `arduino-cli core list` may auto-install missing builtin discovery tools.
    # Preflight must be side-effect free, so verify the installed platform files directly.
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

function Invoke-PhysicalTrialPreflight([switch]$EmitPlan) {
    if ($ComPort -cne 'COM4') { throw 'Only verified COM4 is permitted; COM3 is prohibited.' }
    if ([string]::IsNullOrWhiteSpace($ExpectedPnpDeviceId)) { throw '-ExpectedPnpDeviceId is required.' }
    if ([string]::IsNullOrWhiteSpace($PeerIp)) { throw '-PeerIp is required.' }
    if ($SenderIp -cne $fixedSenderIp) { throw "Sender IP must equal $fixedSenderIp." }
    Assert-ReviewedSourceManifest $reviewManifest
    Assert-GitBaseline
    Assert-ToolchainIdentity
    Assert-PreUploadCom4Identity $ExpectedPnpDeviceId
    $peerInterface = Assert-SafePeerAddress $PeerIp $SenderIp $ReceiverIp
    Write-Output "PEER_INTERFACE_OK=1 IP=$PeerIp INTERFACE_INDEX=$($peerInterface.InterfaceIndex) PC_PREFIX_LENGTH=$($peerInterface.PrefixLength) FIRMWARE_PREFIX_LENGTH=24"
    if ($EmitPlan) {
        $plannedRoot = Join-Path $runRoot "$Trial-<timestamp-guid>"
        Write-Output "PLANNED_BUILD_COMMAND=powershell -NoProfile -ExecutionPolicy Bypass -File $matrixScript -CaseName $caseName -C1PeerIp $PeerIp -OutputRoot <fresh-build-root>"
        Write-Output "PLANNED_UPLOAD_COMMAND=arduino-cli upload --fqbn $fqbn --port COM4 --input-dir <fresh-build-path>"
        Write-Output "PLANNED_PEER_COMMAND=python $peerScript --mode tx-sink --bind-ip $PeerIp --port 50001 --expected-source-ip $SenderIp --expected-source-port 50001"
        Write-Output "PLANNED_SERIAL=COM4 exact-PNP baud=115200 data=8 parity=None stop=One DTR=0 RTS=0"
        Write-Output "TIMEOUTS process_seconds=$ProcessTimeoutSeconds com_reenumeration_seconds=15 peer_ready_seconds=10 build_seconds=1200"
        Write-Output "EXPECTED_OUTPUT_ROOT=$plannedRoot"
    }
}

function Get-KeyValue([string]$Text, [string]$Key) {
    $matches = [regex]::Matches($Text, "(?m)(?:^|\s)$([regex]::Escape($Key))=([^\s]+)")
    if ($matches.Count -eq 0) { return $null }
    return $matches[$matches.Count - 1].Groups[1].Value
}

function Test-C1SerialLog([string]$Text) {
    $reasons = [System.Collections.Generic.List[string]]::new()
    $terminal = @([regex]::Matches($Text, '(?m)^.*TEST_COMPLETE=(?:PASS|FAIL).*$'))
    if ($terminal.Count -ne 1) { $reasons.Add("terminal_count_$($terminal.Count)") }
    $terminalLine = if ($terminal.Count -gt 0) { $terminal[-1].Value } else { "" }
    $required = [ordered]@{
        TEST_COMPLETE = "PASS"
        TEST_MODE = "15"
        TEST_MODE_NAME = "USB_FIXED10_UDP_TX_ONLY"
        FINAL_USB_STATE = "90"
        FINAL_HID_READY = "1"
        HID_READY_DROP = "0"
        HID_STALL_COUNT = "0"
        FINAL_PHY_OK = "1"
        FINAL_VERSION_OK = "1"
        FINAL_BUFFER_MAP_OK = "1"
        MAX_REGISTER_TRIPLE_READ_MISMATCH = "0"
        SPI_CORRUPTION_SUSPECTED = "0"
    }
    foreach ($entry in $required.GetEnumerator()) {
        $actual = Get-KeyValue $terminalLine $entry.Key
        if ($actual -cne $entry.Value) { $reasons.Add("$($entry.Key)_$actual") }
    }
    if ($Text -notmatch '(?m)^SCOPE_MARKER trial=C1 event=TRIAL_COMPLETE result=PASS\s*$') {
        $reasons.Add("missing_trial_complete_scope_pass")
    }
    $forbidden = @(
        'C1_SETUP_FAIL=1', 'TEST_COMPLETE=FAIL',
        'event=TRIAL_COMPLETE result=FAIL', 'USB_DETACH',
        '(?m)(?:^|\s)FAIL_FAST_DETACH=1(?:\s|$)',
        '(?m)(?:^|\s)FAIL_FAST_FINAL_SUMMARY(?:\s|$)',
        '(?m)(?:^|\s)RESET_REASON=(?:PANIC|WDT|BROWNOUT)(?:\s|$)',
        'BUFFER_MAP_OK=0', 'PHY_PROFILE_READBACK_OK=0'
    )
    foreach ($pattern in $forbidden) {
        if ($Text -match $pattern) { $reasons.Add("forbidden_$pattern") }
    }
    $txTotal = Get-KeyValue $Text "UDP_TX_TOTAL"
    $txFail = Get-KeyValue $Text "UDP_TX_FAIL"
    if ($null -eq $txTotal -or [uint64]$txTotal -eq 0) { $reasons.Add("UDP_TX_TOTAL") }
    if ($null -eq $txFail -or [uint64]$txFail -ne 0) { $reasons.Add("UDP_TX_FAIL") }
    return [pscustomobject]@{
        Pass = $reasons.Count -eq 0
        Reasons = @($reasons)
        TerminalLine = $terminalLine
        UdpTxTotal = if ($null -eq $txTotal) { 0 } else { [uint64]$txTotal }
        UdpTxFail = if ($null -eq $txFail) { [uint64]::MaxValue } else { [uint64]$txFail }
        TrialRuntimeMs = [uint64](Get-KeyValue $terminalLine "TRIAL_RUNTIME_MS")
        SchedulerMissedDeadline = [uint64](Get-KeyValue $Text "SCHEDULER_MISSED_DEADLINE")
    }
}

function Test-PeerSummary([string]$Text, [int]$ExitCode) {
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($ExitCode -ne 0) { $reasons.Add("exit_$ExitCode") }
    $requiredZero = @('CRC_ERROR','LENGTH_ERROR','FORMAT_ERROR','PAYLOAD_ERROR',
        'UNEXPECTED_SOURCE','SEQ_GAP','DUPLICATE','OUT_OF_ORDER','FLAGS_ERROR','SOURCE_PORT_ERROR')
    if ((Get-KeyValue $Text 'PEER_RESULT') -cne 'PASS') { $reasons.Add('PEER_RESULT') }
    if ((Get-KeyValue $Text 'PEER_COMPLETE') -cne '1') { $reasons.Add('PEER_COMPLETE') }
    $valid = Get-KeyValue $Text 'VALID_RX_TOTAL'
    if ($null -eq $valid -or [uint64]$valid -eq 0) { $reasons.Add('VALID_RX_TOTAL') }
    foreach ($key in $requiredZero) {
        $value = Get-KeyValue $Text $key
        if ($null -eq $value -or [uint64]$value -ne 0) { $reasons.Add($key) }
    }
    if ((Get-KeyValue $Text 'FIRST_SEQUENCE') -cne '0') { $reasons.Add('FIRST_SEQUENCE') }
    return [pscustomobject]@{ Pass=$reasons.Count -eq 0; Reasons=@($reasons) }
}

function Test-C1PacketReconciliation([string]$SerialText, [string]$PeerText) {
    $reasons = [System.Collections.Generic.List[string]]::new()
    $deviceTotalValue = Get-KeyValue $SerialText 'UDP_TX_TOTAL'
    $deviceFailValue = Get-KeyValue $SerialText 'UDP_TX_FAIL'
    $peerValidValue = Get-KeyValue $PeerText 'VALID_RX_TOTAL'
    $peerFirstValue = Get-KeyValue $PeerText 'FIRST_SEQUENCE'
    $peerLastValue = Get-KeyValue $PeerText 'LAST_SEQUENCE'
    if ($null -eq $deviceTotalValue -or $null -eq $deviceFailValue -or
        $null -eq $peerValidValue -or $null -eq $peerFirstValue -or $null -eq $peerLastValue) {
        return [pscustomobject]@{ Pass=$false; Reasons=@('missing_summary_field'); RateResult='FAIL' }
    }
    $deviceTotal = [uint64]$deviceTotalValue
    $deviceFail = [uint64]$deviceFailValue
    $peerValid = [uint64]$peerValidValue
    if ($deviceTotal -eq 0) { $reasons.Add('device_total_zero') }
    if ($deviceFail -ne 0) { $reasons.Add('device_tx_fail') }
    if ((Get-KeyValue $PeerText 'PEER_RESULT') -cne 'PASS') { $reasons.Add('peer_result') }
    if ($peerValid -eq 0 -or $peerValid -ne $deviceTotal) { $reasons.Add('valid_total_mismatch') }
    if ($peerFirstValue -cne '0') { $reasons.Add('first_sequence') }
    if ($deviceTotal -gt 0) {
        $expectedLast = [uint32](($deviceTotal - 1) -band [uint64][uint32]::MaxValue)
        if ([uint32]$peerLastValue -ne $expectedLast) { $reasons.Add('last_sequence') }
    }
    foreach ($key in @('SEQ_GAP','DUPLICATE','OUT_OF_ORDER','CRC_ERROR','LENGTH_ERROR',
        'FORMAT_ERROR','PAYLOAD_ERROR','UNEXPECTED_SOURCE','FLAGS_ERROR','SOURCE_PORT_ERROR')) {
        $value = Get-KeyValue $PeerText $key
        if ($null -eq $value -or [uint64]$value -ne 0) { $reasons.Add($key) }
    }
    $runtimeValue = Get-KeyValue $SerialText 'TRIAL_RUNTIME_MS'
    $rateResult = 'WARN_MISSING_RUNTIME'
    if ($null -ne $runtimeValue) {
        $runtimeMs = [uint64]$runtimeValue
        $nominalCount = [Math]::Floor($runtimeMs / 20.0)
        $lowThreshold = [Math]::Floor($nominalCount * 0.90)
        $rateResult = if ($deviceTotal -lt $lowThreshold) { 'WARN_UNEXPECTEDLY_LOW' } else { 'PASS' }
    }
    return [pscustomobject]@{ Pass=$reasons.Count -eq 0; Reasons=@($reasons); RateResult=$rateResult }
}

function Invoke-Mode15Build([string]$TrialRoot, [string]$PeerAddress = "") {
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
    Wait-OwnedProcess $process 1200 "Mode 15 build" | Out-Null
    $buildPath = Join-Path $matrixRoot "$caseName\build"
    if (!(Test-Path -LiteralPath $buildPath)) { throw "Mode 15 fresh build output missing: $buildPath" }
    # Return build metadata as exactly one success-stream object.  Do not emit
    # status text from this function: callers may assign its output, and any
    # additional success-stream item would contaminate the value passed to
    # arduino-cli --input-dir.
    return [pscustomobject]@{
        BuildPath = $buildPath
        MatrixRoot = $matrixRoot
        StdoutPath = $stdout
    }
}

function Start-C1SerialCaptureJob(
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
                if((Test-Path -LiteralPath $Path) -and
                   ([IO.File]::ReadAllText($Path) -match 'SCOPE_MARKER trial=C1 event=TRIAL_COMPLETE result=(?:PASS|FAIL)')){break}
                Start-Sleep -Milliseconds 20
            }
        }finally{if($port.IsOpen){$port.Close()};$port.Dispose()}
    }
    $startedJobs.Add($job)
    return $job
}

function Invoke-OfflineTests {
    $results = [System.Collections.Generic.List[object]]::new()
    function Record([string]$Group,[string]$Name,[bool]$Passed,[string]$Detail='') {
        $results.Add([pscustomobject]@{Group=$Group;Name=$Name;Pass=$Passed;Detail=$Detail})
        Write-Output "$Group case=$Name result=$(if($Passed){'PASS'}else{'FAIL'}) detail=$Detail"
    }
    function Expect-Throw([scriptblock]$Action,[string]$Pattern) {
        try{& $Action;return $false}catch{return $_.Exception.Message -match $Pattern}
    }

    $fixtureRoot=Join-Path $repoRoot ("build-temp\usb-lan-isolation\runner-fixtures\{0}-{1}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'),([guid]::NewGuid().ToString('N').Substring(0,8)))
    New-Item -ItemType Directory -Path $fixtureRoot|Out-Null
    $fixtureFile=Join-Path $fixtureRoot 'identity.txt';[IO.File]::WriteAllText($fixtureFile,'reviewed',[Text.UTF8Encoding]::new($false))
    $fixtureManifest=Join-Path $fixtureRoot 'manifest.csv'
    @([pscustomobject]@{relative_or_absolute_path=$fixtureFile;size=(Get-Item $fixtureFile).Length;sha256=Get-Sha256 $fixtureFile;role='fixture'})|Export-Csv $fixtureManifest -NoTypeInformation -Encoding UTF8
    try{Assert-ReviewedSourceManifest $fixtureManifest|Out-Null;Record 'RUNNER_DRY_RUN_TEST' 'reviewed_hash_all_match' $true}catch{Record 'RUNNER_DRY_RUN_TEST' 'reviewed_hash_all_match' $false $_.Exception.Message}
    (Import-Csv $fixtureManifest)|ForEach-Object{$_.sha256='0'*64;$_}|Export-Csv $fixtureManifest -NoTypeInformation -Encoding UTF8
    Record 'RUNNER_DRY_RUN_TEST' 'reviewed_hash_mismatch' (Expect-Throw {Assert-ReviewedSourceManifest $fixtureManifest} 'BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH')

    $inventoryRoot=Join-Path $fixtureRoot 'inventory-library';New-Item -ItemType Directory -Path $inventoryRoot|Out-Null
    $inventorySource=Join-Path $inventoryRoot 'fixture.h';[IO.File]::WriteAllText($inventorySource,'#define FIXTURE 1',[Text.UTF8Encoding]::new($false))
    $inventory=Get-ReviewedDirectoryInventory $inventoryRoot
    $inventoryFile=Join-Path $fixtureRoot 'inventory.txt';[IO.File]::WriteAllText($inventoryFile,$inventory.Content,[Text.UTF8Encoding]::new($false))
    $inventoryManifest=Join-Path $fixtureRoot 'inventory-manifest.csv'
    @([pscustomobject]@{relative_or_absolute_path=$inventoryFile;size=(Get-Item $inventoryFile).Length;sha256=$inventory.Sha256;role='fixture_inventory';inventory_root=$inventoryRoot})|Export-Csv $inventoryManifest -NoTypeInformation -Encoding UTF8
    try{Assert-ReviewedSourceManifest $inventoryManifest|Out-Null;Record 'RUNNER_DRY_RUN_TEST' 'reviewed_directory_inventory_match' $true}catch{Record 'RUNNER_DRY_RUN_TEST' 'reviewed_directory_inventory_match' $false $_.Exception.Message}
    [IO.File]::AppendAllText($inventorySource,' CHANGED',[Text.UTF8Encoding]::new($false))
    Record 'RUNNER_DRY_RUN_TEST' 'reviewed_directory_inventory_mismatch' (Expect-Throw {Assert-ReviewedSourceManifest $inventoryManifest} 'BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH')

    # Real child-process lifecycle fixtures.  These intentionally use redirected
    # stdout/stderr because that is the Windows path that previously returned a
    # null ExitCode after an otherwise successful child process.
    $processFixtureRoot=Join-Path $fixtureRoot 'owned-process';New-Item -ItemType Directory -Path $processFixtureRoot|Out-Null
    $processZeroOut=Join-Path $processFixtureRoot 'exit-zero.stdout.log'
    $processZeroErr=Join-Path $processFixtureRoot 'exit-zero.stderr.log'
    try {
        $processZero=Start-OwnedProcess 'powershell.exe' @(
            '-NoProfile','-Command',
            "[Console]::Out.WriteLine('PROCESS_STDOUT_OK'); [Console]::Error.WriteLine('PROCESS_STDERR_OK'); exit 0"
        ) $processZeroOut $processZeroErr
        $processZeroExit=Wait-OwnedProcess $processZero 10 'offline exit-zero fixture'
        Record 'PROCESS_LIFECYCLE_TEST' 'redirected_exit_zero' ($processZeroExit -eq 0) "exit=$processZeroExit"
        $zeroLogsOk=(Test-Path -LiteralPath $processZeroOut) -and (Test-Path -LiteralPath $processZeroErr) -and `
            ((Get-Content -LiteralPath $processZeroOut -Raw) -match 'PROCESS_STDOUT_OK') -and `
            ((Get-Content -LiteralPath $processZeroErr -Raw) -match 'PROCESS_STDERR_OK')
        Record 'PROCESS_LIFECYCLE_TEST' 'redirected_stdout_stderr_preserved' $zeroLogsOk
    } catch {
        Record 'PROCESS_LIFECYCLE_TEST' 'redirected_exit_zero' $false $_.Exception.Message
        Record 'PROCESS_LIFECYCLE_TEST' 'redirected_stdout_stderr_preserved' $false $_.Exception.Message
    }

    $processNonZeroOut=Join-Path $processFixtureRoot 'exit-seven.stdout.log'
    $processNonZeroErr=Join-Path $processFixtureRoot 'exit-seven.stderr.log'
    try {
        $processNonZero=Start-OwnedProcess 'powershell.exe' @('-NoProfile','-Command','exit 7') $processNonZeroOut $processNonZeroErr
        $processNonZeroExit=Wait-OwnedProcess $processNonZero 10 'offline exit-seven allow fixture' -AllowNonZero
        Record 'PROCESS_LIFECYCLE_TEST' 'redirected_nonzero_exact' ($processNonZeroExit -eq 7) "exit=$processNonZeroExit"
    } catch {
        Record 'PROCESS_LIFECYCLE_TEST' 'redirected_nonzero_exact' $false $_.Exception.Message
    }

    $processRejectOut=Join-Path $processFixtureRoot 'reject-seven.stdout.log'
    $processRejectErr=Join-Path $processFixtureRoot 'reject-seven.stderr.log'
    $processReject=Start-OwnedProcess 'powershell.exe' @('-NoProfile','-Command','exit 7') $processRejectOut $processRejectErr
    Record 'PROCESS_LIFECYCLE_TEST' 'redirected_nonzero_rejected' `
        (Expect-Throw {Wait-OwnedProcess $processReject 10 'offline exit-seven reject fixture'|Out-Null} 'failed with exit code 7')

    $processTimeoutOut=Join-Path $processFixtureRoot 'timeout.stdout.log'
    $processTimeoutErr=Join-Path $processFixtureRoot 'timeout.stderr.log'
    $processTimeout=Start-OwnedProcess 'powershell.exe' @('-NoProfile','-Command','Start-Sleep -Seconds 5; exit 0') $processTimeoutOut $processTimeoutErr
    $timeoutThrown=Expect-Throw {Wait-OwnedProcess $processTimeout 1 'offline timeout fixture'|Out-Null} 'timed out after 1 seconds'
    try { $null=$processTimeout.WaitForExit(5000) } catch {}
    $timeoutStopped=$false
    try { $timeoutStopped=$processTimeout.HasExited } catch { $timeoutStopped=$true }
    Record 'PROCESS_LIFECYCLE_TEST' 'timeout_owned_process_stopped' ($timeoutThrown -and $timeoutStopped)

    # Regression guard for the C1-S1 upload blocker observed after a successful
    # fresh build. Invoke-Mode15Build must not emit status text on the success
    # stream because the physical path assigns its return value and passes
    # BuildPath to arduino-cli --input-dir.
    $mode15BuildDefinition = (Get-Command Invoke-Mode15Build).Definition
    $mode15BuildReturnStreamPure = `
        ($mode15BuildDefinition -notmatch 'Write-Output') -and `
        ($mode15BuildDefinition -match 'BuildPath\s*=\s*\$buildPath') -and `
        ($mode15BuildDefinition -match 'MatrixRoot\s*=\s*\$matrixRoot') -and `
        ($mode15BuildDefinition -match 'StdoutPath\s*=\s*\$stdout')
    Record 'BUILD_RETURN_CONTRACT_TEST' 'mode15_build_success_stream_pure' $mode15BuildReturnStreamPure

    # Regression guard for the post-upload serial worker failure caused by
    # PowerShell's case-insensitive variable names: $matches aliases the
    # automatic $Matches hashtable populated by the -match operator.  The COM
    # resolver paths must avoid both identifiers and use explicit regex APIs.
    $comIdentityDefinition = (Get-Command Get-ComIdentityRecords).Definition
    $comReenumerationDefinition = (Get-Command Wait-ComIdentityReenumeration).Definition
    $serialWorkerDefinition = (Get-Command Start-C1SerialCaptureJob).Definition
    $comResolverAvoidsAutomaticMatches = `
        ($comIdentityDefinition -cnotmatch '\$Matches\b') -and `
        ($comIdentityDefinition -cnotmatch '\$matches\b') -and `
        ($comIdentityDefinition -match '\[regex\]::Match') -and `
        ($comReenumerationDefinition -cnotmatch '\$Matches\b') -and `
        ($comReenumerationDefinition -cnotmatch '\$matches\b') -and `
        ($comReenumerationDefinition -match '\[regex\]::IsMatch') -and `
        ($serialWorkerDefinition -cnotmatch '\$Matches\b') -and `
        ($serialWorkerDefinition -cnotmatch '\$matches\b') -and `
        ($serialWorkerDefinition -match '\[regex\]::Match') -and `
        ($serialWorkerDefinition -match '\$portCandidates')
    Record 'SERIAL_WORKER_CONTRACT_TEST' 'com_resolvers_avoid_matches_collision' $comResolverAvoidsAutomaticMatches

    try{Assert-SafePeerAddressCore '192.168.50.2' '192.168.50.10' '192.168.50.20' 24 $true $true;Record 'RUNNER_DRY_RUN_TEST' 'safe_peer_ip' $true}catch{Record 'RUNNER_DRY_RUN_TEST' 'safe_peer_ip' $false $_.Exception.Message}
    try{Assert-SafePeerAddressCore '192.168.50.2' '192.168.50.10' '192.168.50.20' 16 $true $true;Record 'RUNNER_DRY_RUN_TEST' 'safe_peer_wide_pc_prefix' $true}catch{Record 'RUNNER_DRY_RUN_TEST' 'safe_peer_wide_pc_prefix' $false $_.Exception.Message}
    Record 'RUNNER_DRY_RUN_TEST' 'sender_ip_not_fixed' (Expect-Throw {Assert-SafePeerAddressCore '192.168.50.2' '192.168.51.10' '192.168.50.20' 24 $true $true} 'fixed firmware')
    Record 'RUNNER_DRY_RUN_TEST' 'receiver_equals_peer' (Expect-Throw {Assert-SafePeerAddressCore '192.168.50.20' '192.168.50.10' '192.168.50.20' 24 $true $true} 'physical Receiver')
    Record 'RUNNER_DRY_RUN_TEST' 'multicast' (Expect-Throw {Assert-SafePeerAddressCore '224.0.0.1' '192.168.50.10' '192.168.50.20' 24 $true $true} 'multicast')
    Record 'RUNNER_DRY_RUN_TEST' 'firmware_subnet_zero' (Expect-Throw {Assert-SafePeerAddressCore '192.168.50.0' '192.168.50.10' '192.168.50.20' 16 $true $true} 'network/broadcast')
    Record 'RUNNER_DRY_RUN_TEST' 'broadcast' (Expect-Throw {Assert-SafePeerAddressCore '192.168.50.255' '192.168.50.10' '192.168.50.20' 24 $true $true} 'network/broadcast')

    $identity='USB\VID_1234&PID_5678\ABC';$sleep={param($ms)}
    foreach($fixture in @(
        [pscustomobject]@{Name='immediate_reconnect';Empty=0;Identity=$identity;Expected=$true},
        [pscustomobject]@{Name='reconnect_700ms';Empty=7;Identity=$identity;Expected=$true},
        [pscustomobject]@{Name='reconnect_5s';Empty=50;Identity=$identity;Expected=$true},
        [pscustomobject]@{Name='different_pnp';Empty=0;Identity='OTHER';Expected=$false},
        [pscustomobject]@{Name='com3_not_candidate';Empty=0;Identity=$identity;Expected=$false;PortName='COM3'},
        [pscustomobject]@{Name='no_reconnect';Empty=999;Identity=$identity;Expected=$false}
    )){
        $script:index=0;$resolver={
            $current=$script:index;$script:index++
            if($current -lt $fixture.Empty){return @()}
            $fixturePort = if ($null -ne $fixture.PortName) { $fixture.PortName } else { 'COM5' }
            return @([pscustomobject]@{PortName=$fixturePort;PnpDeviceId=$fixture.Identity})
        }
        try{$resolved=Wait-ComIdentityReenumeration $identity $resolver 15000 100 $sleep;$actual=$resolved.PortName -eq 'COM5'}catch{$actual=$false}
        Record 'COM_RECONNECT_FIXTURE' $fixture.Name ($actual -eq $fixture.Expected)
    }

    $passTerminal='TEST_COMPLETE=PASS TEST_MODE=15 TEST_MODE_NAME=USB_FIXED10_UDP_TX_ONLY DURATION_MS=10000 TRIAL_RUNTIME_MS=10000 REASON=DURATION_COMPLETE FINAL_USB_STATE=90 FINAL_HID_READY=1 HID_READY_DROP=0 HID_STALL_COUNT=0 HID_MAX_NO_REPORT_MS=5 VID=0F0D PID=0202 HID_REPORT_TOTAL=2000 FINAL_PHY_OK=1 FINAL_VERSION_OK=1 FINAL_BUFFER_MAP_OK=1 VERSIONR=04 MAX_REGISTER_TRIPLE_READ_MISMATCH=0 SPI_CORRUPTION_SUSPECTED=0'
    $passStats='C1_FINAL UDP_TX_TOTAL=500 UDP_TX_FAIL=0 SCHEDULER_MISSED_DEADLINE=0'
    $scope='SCOPE_MARKER trial=C1 event=TRIAL_COMPLETE result=PASS'
    $bootUsb='DIAGNOSTIC_BOOT TEST_MODE=15 INIT_ORDER=0 DISPLAY=0 LAN_INIT=0 LINK_POLL=0 FULL_DUPLEX=0 FAIL_FAST=1 RESET_REASON=USB'
    $modeMetadata='MODE_PLAN TEST_MODE_NAME=USB_FIXED10_UDP_TX_ONLY DISPLAY=0 LAN_INIT=0 LINK_POLL=0 FULL_DUPLEX=0 FAIL_FAST=1'
    $realisticPass=@($bootUsb,$modeMetadata,'TEST_MODE_NAME=USB_FIXED10_UDP_TX_ONLY','',$passStats,'',$passTerminal,'',$scope) -join "`n"
    $serialFixtures=[ordered]@{
        pass="$passStats`n$passTerminal`n$scope"
        realistic_pass_with_fail_fast_metadata=$realisticPass
        fail_fast_metadata_only="$bootUsb`n$passStats`n$passTerminal`n$scope"
        actual_fail_fast_marker="$realisticPass`nFAIL_FAST_DETACH=1 DETACH_USB_STATE_BEFORE=90 DETACH_USB_STATE_AFTER=12"
        reset_reason_usb=$realisticPass
        reset_reason_wdt=($realisticPass -replace 'RESET_REASON=USB','RESET_REASON=WDT')
        reset_reason_panic=($realisticPass -replace 'RESET_REASON=USB','RESET_REASON=PANIC')
        reset_reason_brownout=($realisticPass -replace 'RESET_REASON=USB','RESET_REASON=BROWNOUT')
        reboot_then_pass_rejected="DIAGNOSTIC_BOOT TEST_MODE=15 FAIL_FAST=1 RESET_REASON=WDT`n$realisticPass"
        setup_fail='C1_SETUP_FAIL=1 REASON=W5100_INIT`nTEST_COMPLETE=FAIL TEST_MODE=15 TEST_MODE_NAME=USB_FIXED10_UDP_TX_ONLY REASON=W5100_INIT`nSCOPE_MARKER trial=C1 event=TRIAL_COMPLETE result=FAIL'
        runtime_fail="$passStats`n$($passTerminal -replace 'TEST_COMPLETE=PASS','TEST_COMPLETE=FAIL')`nSCOPE_MARKER trial=C1 event=TRIAL_COMPLETE result=FAIL"
        usb_detach="$passStats`nUSB_DETACH`n$passTerminal`n$scope"
        missing_test_complete="$passStats`n$scope"
        missing_trial_complete="$passStats`n$passTerminal"
        wrong_test_mode="$passStats`n$($passTerminal -replace 'TEST_MODE=15','TEST_MODE=14')`n$scope"
        wrong_final_usb="$passStats`n$($passTerminal -replace 'FINAL_USB_STATE=90','FINAL_USB_STATE=12')`n$scope"
        wrong_final_hid="$passStats`n$($passTerminal -replace 'FINAL_HID_READY=1','FINAL_HID_READY=0')`n$scope"
    }
    $serialPassFixtures=@('pass','realistic_pass_with_fail_fast_metadata','fail_fast_metadata_only','reset_reason_usb')
    foreach($entry in $serialFixtures.GetEnumerator()){$actual=(Test-C1SerialLog $entry.Value).Pass;$expected=$serialPassFixtures -contains $entry.Key;Record 'SERIAL_FIXTURE_TEST' $entry.Key ($actual -eq $expected)}

    $peerPass=@('PEER_COMPLETE=1','RX_TOTAL=500','VALID_RX_TOTAL=500','FIRST_SEQUENCE=0','LAST_SEQUENCE=499','PEER_RESULT=PASS','CRC_ERROR=0','LENGTH_ERROR=0','FORMAT_ERROR=0','PAYLOAD_ERROR=0','UNEXPECTED_SOURCE=0','SEQ_GAP=0','DUPLICATE=0','OUT_OF_ORDER=0','FLAGS_ERROR=0','SOURCE_PORT_ERROR=0') -join "`n"
    Record 'RUNNER_DRY_RUN_TEST' 'peer_pass_fixture' (Test-PeerSummary $peerPass 0).Pass
    $peerZero=$peerPass -replace 'RX_TOTAL=500','RX_TOTAL=0' -replace 'VALID_RX_TOTAL=500','VALID_RX_TOTAL=0' -replace 'FIRST_SEQUENCE=0','FIRST_SEQUENCE=NONE' -replace 'LAST_SEQUENCE=499','LAST_SEQUENCE=NONE' -replace 'PEER_RESULT=PASS','PEER_RESULT=FAIL'
    Record 'RUNNER_DRY_RUN_TEST' 'peer_zero_packet_fixture' (!(Test-PeerSummary $peerZero 2).Pass)
    $serialPass="$passStats`n$passTerminal`n$scope"
    Record 'PACKET_RECONCILIATION_TEST' 'matching_counts' (Test-C1PacketReconciliation $serialPass $peerPass).Pass
    $peerMismatch=$peerPass -replace 'VALID_RX_TOTAL=500','VALID_RX_TOTAL=499'
    Record 'PACKET_RECONCILIATION_TEST' 'count_mismatch' (!(Test-C1PacketReconciliation $serialPass $peerMismatch).Pass)
    $wrapSerial=$serialPass -replace 'UDP_TX_TOTAL=500','UDP_TX_TOTAL=4294967297'
    $wrapPeer=$peerPass -replace 'RX_TOTAL=500','RX_TOTAL=4294967297' -replace 'VALID_RX_TOTAL=500','VALID_RX_TOTAL=4294967297' -replace 'LAST_SEQUENCE=499','LAST_SEQUENCE=0'
    Record 'PACKET_RECONCILIATION_TEST' 'uint32_wrap' (Test-C1PacketReconciliation $wrapSerial $wrapPeer).Pass
    Record 'RUNNER_DRY_RUN_TEST' 'trial_result_marker_s1' ((Get-C1TrialResultMarker 'C1-S1') -ceq 'C1_TRIAL_RESULT=PASS TRIAL=C1-S1')
    Record 'RUNNER_DRY_RUN_TEST' 'trial_result_marker_t1' ((Get-C1TrialResultMarker 'C1-T1') -ceq 'C1_TRIAL_RESULT=PASS TRIAL=C1-T1')

    $failed=@($results|Where-Object Pass -eq $false)
    Write-Output "RUNNER_OFFLINE_TESTS=$(if($failed.Count -eq 0){'PASS'}else{'FAIL'}) TESTS=$($results.Count) FAILED=$($failed.Count)"
    if($failed.Count){throw "Runner offline fixture failure: $($failed.Name -join ',')"}
}

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
    Assert-ReviewedSourceManifest $reviewManifest
    Write-Output "REVIEWED_SOURCE_MANIFEST_RESULT=PASS"
    Write-Output "UPLOAD=NOT_RUN SERIAL=NOT_OPENED PEER=NOT_STARTED NETWORK_TRIAL=NOT_RUN"
    return
}

if ($PreflightPhysicalTrial) {
    if ($RunPhysicalTrial -or $AllowUpload -or $AllowSerial -or $AllowPeer -or $AllowNetworkTrial) {
        throw "Physical preflight is read-only and prohibits all physical permission switches."
    }
    Invoke-PhysicalTrialPreflight -EmitPlan
    Write-Output "C1_PHYSICAL_PREFLIGHT=PASS"
    Write-Output "UPLOAD=NOT_RUN"
    Write-Output "SERIAL=NOT_OPENED"
    Write-Output "PEER=NOT_STARTED"
    Write-Output "NETWORK_TRAFFIC=NOT_RUN"
    return
}

New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
$trialIdentity = "{0}-{1}-{2}" -f $Trial,(Get-Date -Format "yyyyMMdd-HHmmss"),([guid]::NewGuid().ToString("N").Substring(0,8))
$trialRoot = Join-Path $runRoot $trialIdentity
Assert-ChildPath $runRoot $trialRoot
if (Test-Path -LiteralPath $trialRoot) { throw "Fresh trial root already exists: $trialRoot" }
New-Item -ItemType Directory -Path $trialRoot | Out-Null

try {
    if (!$RunPhysicalTrial) {
        if ($AllowUpload -or $AllowSerial -or $AllowPeer -or $AllowNetworkTrial) {
            throw "Permission switches are invalid without -RunPhysicalTrial."
        }
        Write-Output "RUNNER_MODE=BUILD_ONLY"
        $buildResult = Invoke-Mode15Build $trialRoot
        Write-Output "BUILD_ONLY_PASS=1 CASE=$caseName ROOT=$($buildResult.MatrixRoot) LOG=$($buildResult.StdoutPath)"
        Write-Output "UPLOAD=NOT_RUN SERIAL=NOT_OPENED PEER=NOT_STARTED NETWORK_TRIAL=NOT_RUN"
        return
    }

    if (!($AllowUpload -and $AllowSerial -and $AllowPeer -and $AllowNetworkTrial)) {
        throw "Physical trial requires -AllowUpload -AllowSerial -AllowPeer -AllowNetworkTrial together."
    }
    Invoke-PhysicalTrialPreflight

    $buildResult = Invoke-Mode15Build $trialRoot $PeerIp
    $buildPath = [string]$buildResult.BuildPath
    Write-Output "BUILD_ONLY_PASS=1 CASE=$caseName ROOT=$($buildResult.MatrixRoot) LOG=$($buildResult.StdoutPath)"
    Assert-ReviewedSourceManifest $reviewManifest
    $readyFile = Join-Path $trialRoot "peer.ready"
    $stopFile = Join-Path $trialRoot "peer.stop"
    $peerCsv = Join-Path $trialRoot "peer.csv"
    $peerStdout = Join-Path $trialRoot "peer.stdout.log"
    $peerStderr = Join-Path $trialRoot "peer.stderr.log"
    $peerDurationSeconds = $durationSeconds + $ProcessTimeoutSeconds + 60
    $peerProcess = Start-OwnedProcess "python.exe" @(
        $peerScript, "--mode", "tx-sink", "--bind-ip", $PeerIp,
        "--port", "50001", "--duration-seconds", $peerDurationSeconds,
        "--expected-source-ip", $SenderIp, "--expected-source-port", "50001",
        "--output-csv", $peerCsv, "--ready-file", $readyFile, "--stop-file", $stopFile
    ) $peerStdout $peerStderr
    Write-Output "PEER_PROCESS_STARTED=1"
    Write-Output "PEER_PID=$($peerProcess.Id)"
    $readyWatch = [Diagnostics.Stopwatch]::StartNew()
    while (!(Test-Path -LiteralPath $readyFile)) {
        if ($peerProcess.HasExited) { throw "PC peer exited before readiness." }
        if ($readyWatch.Elapsed.TotalSeconds -ge 10) { throw "PC peer readiness timed out." }
        Start-Sleep -Milliseconds 100
    }
    Write-Output "PEER_READY=1"

    Assert-PreUploadCom4Identity $ExpectedPnpDeviceId
    $uploadStdout = Join-Path $trialRoot "upload.stdout.log"
    $uploadStderr = Join-Path $trialRoot "upload.stderr.log"
    $uploadProcess = Start-OwnedProcess "arduino-cli.exe" @(
        "upload", "--fqbn", $fqbn, "--port", "COM4", "--input-dir", $buildPath
    ) $uploadStdout $uploadStderr
    try {
        Wait-OwnedProcess $uploadProcess $ProcessTimeoutSeconds "COM4 upload" | Out-Null
    } catch {
        Write-Output "UPLOAD_FAILURE_STDOUT_LOG=$uploadStdout"
        Write-Output "UPLOAD_FAILURE_STDERR_LOG=$uploadStderr"
        if (Test-Path -LiteralPath $uploadStdout) {
            $uploadStdoutText = Get-Content -LiteralPath $uploadStdout -Raw
            if (![string]::IsNullOrEmpty($uploadStdoutText)) {
                Write-Output "UPLOAD_STDOUT_BEGIN"
                Write-Output $uploadStdoutText.TrimEnd("`r","`n")
                Write-Output "UPLOAD_STDOUT_END"
            }
        }
        if (Test-Path -LiteralPath $uploadStderr) {
            $uploadStderrText = Get-Content -LiteralPath $uploadStderr -Raw
            if (![string]::IsNullOrEmpty($uploadStderrText)) {
                Write-Output "UPLOAD_STDERR_BEGIN"
                Write-Output $uploadStderrText.TrimEnd("`r","`n")
                Write-Output "UPLOAD_STDERR_END"
            }
        }
        throw
    }
    Write-Output "UPLOAD_PASS=1 PORT=COM4"

    $serialLog = Join-Path $trialRoot "serial.log"
    $serialJob = Start-C1SerialCaptureJob $ExpectedPnpDeviceId $serialLog ($durationSeconds + 30)
    if (!(Wait-Job -Job $serialJob -Timeout ($durationSeconds + 60))) {
        Stop-Job -Job $serialJob -ErrorAction SilentlyContinue
        throw "BLOCKED_COM4_REENUMERATION_OR_SERIAL_TIMEOUT"
    }
    $serialWorkerOutput = @(Receive-Job -Job $serialJob -ErrorAction Stop)
    $serialWorkerOutput | ForEach-Object { Write-Output $_ }
    if (!(Test-Path -LiteralPath $serialLog)) { throw "COM4 serial log was not created." }
    $serialText = Get-Content -LiteralPath $serialLog -Raw
    $serialResult = Test-C1SerialLog $serialText
    Write-Output "SERIAL_CONTRACT=$(if($serialResult.Pass){'PASS'}else{'FAIL'})"
    if (!$serialResult.Pass) { throw "C1 serial contract failed: $($serialResult.Reasons -join ',')" }

    [IO.File]::WriteAllText($stopFile,"PEER_STOP=1`n",[Text.UTF8Encoding]::new($false))
    Write-Output "PEER_STOP_REQUESTED=1"
    $peerExit = Wait-OwnedProcess $peerProcess ($ProcessTimeoutSeconds + 10) "C1 PC peer" -AllowNonZero
    Write-Output "PEER_EXIT_CODE=$peerExit"
    if (!(Test-Path -LiteralPath $peerStdout)) { throw "Peer summary output missing." }
    $peerText = Get-Content -LiteralPath $peerStdout -Raw
    if ($peerText -notmatch 'PEER_COMPLETE=1') { throw "Peer summary was not flushed." }
    Write-Output "PEER_SUMMARY_CAPTURED=1"
    $peerResult = Test-PeerSummary $peerText $peerExit
    Write-Output "PEER_CONTRACT=$(if($peerResult.Pass){'PASS'}else{'FAIL'})"
    if (!$peerResult.Pass) { throw "C1 peer contract failed: $($peerResult.Reasons -join ',')" }

    $reconciliation = Test-C1PacketReconciliation $serialText $peerText
    Write-Output "UDP_TX_RATE_CHECK=$($reconciliation.RateResult)"
    Write-Output "C1_PACKET_RECONCILIATION=$(if($reconciliation.Pass){'PASS'}else{'FAIL'})"
    if (!$reconciliation.Pass) { throw "Packet reconciliation failed: $($reconciliation.Reasons -join ',')" }
    Write-Output "SCHEDULER_MISSED_DEADLINE=$($serialResult.SchedulerMissedDeadline) CLASSIFICATION=WARNING_ONLY"
    Write-Output (Get-C1TrialResultMarker $Trial)
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
