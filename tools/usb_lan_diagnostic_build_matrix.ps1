param(
    [ValidateRange(5, 3600)]
    [int]$DurationSeconds = 60,
    [ValidatePattern('^[A-Za-z0-9-]*$')]
    [string]$CaseName = "",
    [string]$C1PeerIp = "192.168.50.254",
    [string]$OutputRoot = ""
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$matrixParent = Join-Path $repoRoot "build-temp\usb-lan-build-matrix-runs"
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $runIdentity = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), ([guid]::NewGuid().ToString("N").Substring(0, 8))
    $matrixRoot = Join-Path $matrixParent $runIdentity
} else {
    $matrixRoot = [IO.Path]::GetFullPath($OutputRoot)
}
if (Test-Path -LiteralPath $matrixRoot) {
    throw "Build output root must be fresh and absent: $matrixRoot"
}
$isolationLibraryRoot = Join-Path $repoRoot "build-temp\usb-lan-isolation\libraries"
$fqbn = "m5stack:esp32:m5stack_cores3"
$durationMs = $DurationSeconds * 1000
$c1PeerAddress = [Net.IPAddress]::Parse($C1PeerIp)
if ($c1PeerAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
    throw "C1PeerIp must be IPv4: $C1PeerIp"
}
$c1PeerBytes = $c1PeerAddress.GetAddressBytes()

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Assert-LibraryVersion([string]$Directory, [string]$Name, [string]$Version) {
    $properties = Join-Path $Directory "library.properties"
    if (!(Test-Path -LiteralPath $properties)) { throw "Missing library.properties: $properties" }
    $text = Get-Content -LiteralPath $properties -Raw
    if ($text -notmatch "(?m)^name=$([regex]::Escape($Name))\s*$" -or
        $text -notmatch "(?m)^version=$([regex]::Escape($Version))\s*$") {
        throw "Library baseline mismatch: $properties; expected $Name $Version"
    }
}

function Assert-ChildPath([string]$Parent, [string]$Child) {
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $childFull = [IO.Path]::GetFullPath($Child)
    if (!$childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Output path escapes build-temp matrix root: $childFull"
    }
}

$libraries = [ordered]@{
    M5Unified = Join-Path $isolationLibraryRoot "M5Unified"
    M5GFX = Join-Path $isolationLibraryRoot "M5GFX"
    M5Ethernet = Join-Path $isolationLibraryRoot "M5-Ethernet"
    Uhs = Join-Path $isolationLibraryRoot "USB_Host_Shield_Library_2.0"
}
Assert-LibraryVersion $libraries.M5Unified "M5Unified" "0.2.19"
Assert-LibraryVersion $libraries.M5GFX "M5GFX" "0.2.26"
Assert-LibraryVersion $libraries.M5Ethernet "M5-Ethernet" "4.0.0"
Assert-LibraryVersion $libraries.Uhs "USB Host Shield Library 2.0" "1.7.0"

$uhsCore = Get-Content -LiteralPath (Join-Path $libraries.Uhs "UsbCore.h") -Raw
$uhsHost = Get-Content -LiteralPath (Join-Path $libraries.Uhs "usbhost.h") -Raw
if (([regex]::Matches($uhsCore, 'typedef\s+MAX3421e<P1,\s*P14>\s+MAX3421E;')).Count -ne 1 -or
    ([regex]::Matches($uhsHost, 'typedef\s+SPi<\s*P36,\s*P37,\s*P35,\s*P1\s*>\s+spi;')).Count -ne 1) {
    throw "Isolated UHS CoreS3 patch is missing or duplicated."
}

$modePlans = @(
    [pscustomobject]@{ Mode=0; Name="LEGACY_MODE_0"; Display=0; LanInit=0; LinkPoll=0; FullDuplex=0; FailFast=0; Order="0" },
    [pscustomobject]@{ Mode=1; Name="LEGACY_MODE_1"; Display=1; LanInit=0; LinkPoll=0; FullDuplex=0; FailFast=0; Order="0" },
    [pscustomobject]@{ Mode=2; Name="LEGACY_MODE_2"; Display=1; LanInit=0; LinkPoll=0; FullDuplex=0; FailFast=0; Order="0" },
    [pscustomobject]@{ Mode=3; Name="LEGACY_MODE_3"; Display=0; LanInit=1; LinkPoll=0; FullDuplex=0; FailFast=0; Order="1 or 2" },
    [pscustomobject]@{ Mode=4; Name="LEGACY_MODE_4"; Display=0; LanInit=1; LinkPoll=1; FullDuplex=0; FailFast=0; Order="1 or 2" },
    [pscustomobject]@{ Mode=5; Name="LEGACY_MODE_5"; Display=1; LanInit=1; LinkPoll=1; FullDuplex=0; FailFast=0; Order="1 or 2" },
    [pscustomobject]@{ Mode=6; Name="LEGACY_MODE_6"; Display=0; LanInit=1; LinkPoll=1; FullDuplex=1; FailFast=0; Order="1 or 2" },
    [pscustomobject]@{ Mode=7; Name="LEGACY_MODE_7"; Display=1; LanInit=1; LinkPoll=1; FullDuplex=1; FailFast=0; Order="1 or 2" },
    [pscustomobject]@{ Mode=8; Name="RESET_RELEASE_ONLY"; Display=0; LanInit=0; LinkPoll=0; FullDuplex=0; FailFast=1; Order="0 fixed" },
    [pscustomobject]@{ Mode=9; Name="INIT_THEN_RESET_HELD"; Display=0; LanInit=1; LinkPoll=0; FullDuplex=0; FailFast=1; Order="2 fixed" },
    [pscustomobject]@{ Mode=10; Name="PHY_POWER_DOWN"; Display=0; LanInit=1; LinkPoll=0; FullDuplex=0; FailFast=1; Order="2 fixed" },
    [pscustomobject]@{ Mode=11; Name="USB_RUNNING_RESET_HELD_CONTROL"; Display=0; LanInit=0; LinkPoll=0; FullDuplex=0; FailFast=1; Order="0 fixed" },
    [pscustomobject]@{ Mode=12; Name="USB_RUNNING_THEN_RESET_RELEASE"; Display=0; LanInit=0; LinkPoll=0; FullDuplex=0; FailFast=1; Order="0 fixed" },
    [pscustomobject]@{ Mode=13; Name="LAN_ONLY_PHY_LINK_TIMING"; Display=0; LanInit=0; LinkPoll=0; FullDuplex=0; FailFast=0; Order="0 fixed" },
    [pscustomobject]@{ Mode=14; Name="USB_RUNNING_THEN_PHY_PROFILE"; Display=0; LanInit=0; LinkPoll=0; FullDuplex=0; FailFast=1; Order="0 fixed" },
    [pscustomobject]@{ Mode=15; Name="USB_FIXED10_UDP_TX_ONLY"; Display=0; LanInit=0; LinkPoll=0; FullDuplex=0; FailFast=1; Order="0 fixed" },
    [pscustomobject]@{ Mode=16; Name="USB_FIXED10_UDP_ECHO"; Display=0; LanInit=0; LinkPoll=0; FullDuplex=0; FailFast=1; Order="0 fixed" }
)
if ($modePlans.Count -ne 17 -or ($modePlans.Mode -join ',') -ne '0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16') {
    throw "ModePlan matrix must cover each mode from 0 through 16 exactly once."
}
Write-Output "MODE_PLAN_TABLE"
$modePlans | Format-Table -AutoSize | Out-String | Write-Output

$cases = @(
    [pscustomobject]@{ Name="mode0-order0"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=0; Order=0; PhyProfile=0 },
    [pscustomobject]@{ Name="mode1-order0"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=1; Order=0; PhyProfile=0 },
    [pscustomobject]@{ Name="mode2-order0"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=2; Order=0; PhyProfile=0 },
    [pscustomobject]@{ Name="mode3-order1"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=3; Order=1; PhyProfile=0 },
    [pscustomobject]@{ Name="mode3-order2"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=3; Order=2; PhyProfile=0 },
    [pscustomobject]@{ Name="mode4-order1"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=4; Order=1; PhyProfile=0 },
    [pscustomobject]@{ Name="mode4-order2"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=4; Order=2; PhyProfile=0 },
    [pscustomobject]@{ Name="mode5-order1"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=5; Order=1; PhyProfile=0 },
    [pscustomobject]@{ Name="mode5-order2"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=5; Order=2; PhyProfile=0 },
    [pscustomobject]@{ Name="mode6-order1"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=6; Order=1; PhyProfile=0 },
    [pscustomobject]@{ Name="mode6-order2"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=6; Order=2; PhyProfile=0 },
    [pscustomobject]@{ Name="mode7-order1"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=7; Order=1; PhyProfile=0 },
    [pscustomobject]@{ Name="mode7-order2"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=7; Order=2; PhyProfile=0 },
    [pscustomobject]@{ Name="mode8-order0"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=8; Order=0; PhyProfile=0 },
    [pscustomobject]@{ Name="mode9-order2"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=9; Order=2; PhyProfile=0 },
    [pscustomobject]@{ Name="mode10-order2"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=10; Order=2; PhyProfile=0 },
    [pscustomobject]@{ Name="mode11-order0"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=11; Order=0; PhyProfile=0 },
    [pscustomobject]@{ Name="mode12-order0"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=12; Order=0; PhyProfile=0 },
    [pscustomobject]@{ Name="mode13-hardware-strap"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=13; Order=0; PhyProfile=0 },
    [pscustomobject]@{ Name="mode13-power-down"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=13; Order=0; PhyProfile=1 },
    [pscustomobject]@{ Name="mode13-fixed-10-half"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=13; Order=0; PhyProfile=2 },
    [pscustomobject]@{ Name="mode13-fixed-100-half"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=13; Order=0; PhyProfile=3 },
    [pscustomobject]@{ Name="mode13-auto-100-half"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=13; Order=0; PhyProfile=4 },
    [pscustomobject]@{ Name="mode13-auto-all"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=13; Order=0; PhyProfile=5 },
    [pscustomobject]@{ Name="mode14-power-down"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=14; Order=0; PhyProfile=1 },
    [pscustomobject]@{ Name="mode14-fixed-10-half"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=14; Order=0; PhyProfile=2 },
    [pscustomobject]@{ Name="mode14-fixed-100-half"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=14; Order=0; PhyProfile=3 },
    [pscustomobject]@{ Name="mode14-auto-100-half"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=14; Order=0; PhyProfile=4 },
    [pscustomobject]@{ Name="mode14-auto-all"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=14; Order=0; PhyProfile=5 },
    [pscustomobject]@{ Name="mode15-fixed10-udp-tx-only-10s"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=15; Order=0; PhyProfile=2; CaseDurationSeconds=10 },
    [pscustomobject]@{ Name="mode15-fixed10-udp-tx-only-60s"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=15; Order=0; PhyProfile=2; CaseDurationSeconds=60 },
    [pscustomobject]@{ Name="mode16-fixed10-udp-echo-10s"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=16; Order=0; PhyProfile=2; CaseDurationSeconds=10 },
    [pscustomobject]@{ Name="mode16-fixed10-udp-echo-60s"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"; Mode=16; Order=0; PhyProfile=2; CaseDurationSeconds=60 },
    [pscustomobject]@{ Name="product-lan-sender-regression"; Sketch="M5Stack-PS5CoRELANSender.ino"; Mode=0; Order=0; PhyProfile=0 },
    [pscustomobject]@{ Name="legacy-wireless-sender-regression"; Sketch="M5Stack-SwitchController2CoREWirelessSender.ino"; Mode=0; Order=0; PhyProfile=0 }
)
$runProtocolReference = $CaseName.Length -eq 0 -or $CaseName -eq "core-protocol-reference-self-test"
if ($CaseName.Length -gt 0 -and !$runProtocolReference) {
    $cases = @($cases | Where-Object { $_.Name -eq $CaseName })
    if ($cases.Count -ne 1) { throw "Unknown build matrix case: $CaseName" }
} elseif ($CaseName -eq "core-protocol-reference-self-test") {
    $cases = @()
}

New-Item -ItemType Directory -Path $matrixRoot | Out-Null
$results = @()
if ($runProtocolReference) {
    $protocolReference = Join-Path $repoRoot "tools\core_protocol_reference.py"
    $protocolLog = Join-Path $matrixRoot "core-protocol-reference-self-test.log"
    $protocolOutput = & python $protocolReference 2>&1
    $protocolExitCode = $LASTEXITCODE
    $protocolOutput | Out-File -LiteralPath $protocolLog -Encoding utf8
    if ($protocolExitCode -ne 0 -or ($protocolOutput -join "`n") -notmatch "PROTOCOL_REFERENCE_SELF_TEST=OK") {
        throw "CoreProtocol reference self-test failed; log=$protocolLog"
    }
    $results += [pscustomobject]@{
        Case = "core-protocol-reference-self-test"
        Sketch = "tools/core_protocol_reference.py"
        FQBN = "N/A"
        Mode = "N/A"
        InitOrder = "N/A"
        PhyProfile = "N/A"
        DurationMs = 0
        Defines = "N/A"
        BinarySize = 0
        FirmwareSha256 = "N/A"
        BuildLogSha256 = Get-Sha256 $protocolLog
        SourceSha256 = Get-Sha256 $protocolReference
        BuildResult = "PASS"
        Upload = "NOT RUN - BUILD MATRIX PROHIBITS UPLOAD"
        Serial = "NOT RUN - BUILD MATRIX PROHIBITS SERIAL"
        FirmwarePath = "N/A"
        BuildLogPath = $protocolLog
    }
    Write-Output "SELF_TEST_PASS CASE=core-protocol-reference-self-test LOG=$protocolLog"
}
foreach ($case in $cases) {
    $caseDurationSeconds = if ($null -ne $case.CaseDurationSeconds) {
        [int]$case.CaseDurationSeconds
    } else {
        $DurationSeconds
    }
    $caseDurationMs = $caseDurationSeconds * 1000
    $caseRoot = Join-Path $matrixRoot $case.Name
    $sketchBase = [IO.Path]::GetFileNameWithoutExtension($case.Sketch)
    $sketchDir = Join-Path $caseRoot "sketch\$sketchBase"
    $buildPath = Join-Path $caseRoot "build"
    $buildLog = Join-Path $caseRoot "build.log"
    Assert-ChildPath $matrixRoot $caseRoot
    New-Item -ItemType Directory -Path $sketchDir, $buildPath | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot $case.Sketch) -Destination $sketchDir
    if ($case.Sketch -in @("M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino", "M5Stack-PS5CoRELANSender.ino")) {
        $coreDestination = Join-Path $sketchDir "src\core_protocol"
        New-Item -ItemType Directory -Force -Path $coreDestination | Out-Null
        Copy-Item -LiteralPath (Join-Path $repoRoot "src\core_protocol\CoreProtocol.h") -Destination $coreDestination -Force
        Copy-Item -LiteralPath (Join-Path $repoRoot "src\core_protocol\CoreProtocol.cpp") -Destination $coreDestination -Force
        if ($case.Sketch -eq "M5Stack-PS5CoRELANSender.ino") {
            foreach ($module in @('controller_profile','core_runtime','numeric_ui')) {
                Copy-Item -LiteralPath (Join-Path $repoRoot "src\$module") -Destination (Join-Path $sketchDir 'src') -Recurse
            }
        }
    }

    $defines = @(
        "-DESP32", "-DUSB_HOST_SHIELD_SS_TYPE=P1", "-DUSB_HOST_SHIELD_INT_TYPE=P14",
        "-DPIN_SPI_SCK=36", "-DPIN_SPI_MOSI=37", "-DPIN_SPI_MISO=35", "-DPIN_SPI_SS=1",
        "-DUSB_HOST_SHIELD_SS_GPIO=1", "-DUSB_HOST_SHIELD_INT_GPIO=14",
        "-DBUILD_TARGET_CORES3SE", "-DARDUINO_M5STACK_CORES3", "-DBOARD_HAS_PSRAM",
        "-DARDUINO_USB_MODE=1", "-DARDUINO_USB_CDC_ON_BOOT=1",
        "-DARDUINO_USB_MSC_ON_BOOT=0", "-DARDUINO_USB_DFU_ON_BOOT=0",
        "-DUSB_LAN_TEST_MODE=$($case.Mode)", "-DUSB_LAN_INIT_ORDER=$($case.Order)",
        "-DUSB_LAN_TEST_DURATION_MS=$caseDurationMs", "-DUSB_TEST_DURATION_MS=$caseDurationMs",
        "-DUSB_HID_RAW_LOG=0", "-DUSB_TARGET_READY_TIMEOUT_MS=0",
        "-DUSB_POWERED_HUB_TEST=0", "-DPS5USB_INIT_OUTPUT=0",
        "-DUSB_LAN_W5500_RELEASE_AFTER_RUNNING_MS=1000",
        "-DUSB_LAN_PHY_PROFILE=$($case.PhyProfile)"
    )
    if ($case.Mode -eq 15 -or $case.Mode -eq 16) {
        $defines += @(
            "-DUSB_LAN_C1_PEER_IP_A=$($c1PeerBytes[0])",
            "-DUSB_LAN_C1_PEER_IP_B=$($c1PeerBytes[1])",
            "-DUSB_LAN_C1_PEER_IP_C=$($c1PeerBytes[2])",
            "-DUSB_LAN_C1_PEER_IP_D=$($c1PeerBytes[3])"
        )
    }
    $extraFlags = $defines -join ' '
    $compileArgs = @(
        "compile", "--verbose", "--clean", "--jobs", "8", "--fqbn", $fqbn,
        "--build-path", $buildPath,
        "--library", $libraries.M5Unified,
        "--library", $libraries.M5GFX,
        "--library", $libraries.M5Ethernet,
        "--library", $libraries.Uhs,
        "--build-property", "build.extra_flags=$extraFlags",
        $sketchDir
    )
    Write-Output "BUILD_BEGIN CASE=$($case.Name) MODE=$($case.Mode) INIT_ORDER=$($case.Order)"
    & arduino-cli @compileArgs 2>&1 | Out-File -LiteralPath $buildLog -Encoding utf8
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Get-Content -LiteralPath $buildLog -Tail 80 | Write-Output
        throw "Build failed: $($case.Name); log=$buildLog"
    }
    $firmware = Join-Path $buildPath "$($case.Sketch).bin"
    if (!(Test-Path -LiteralPath $firmware)) { throw "Firmware missing: $firmware" }
    $result = [pscustomobject]@{
        Case = $case.Name
        Sketch = $case.Sketch
        FQBN = $fqbn
        Mode = $case.Mode
        InitOrder = $case.Order
        PhyProfile = $case.PhyProfile
        DurationMs = $caseDurationMs
        Defines = $extraFlags
        BinarySize = (Get-Item -LiteralPath $firmware).Length
        FirmwareSha256 = Get-Sha256 $firmware
        BuildLogSha256 = Get-Sha256 $buildLog
        SourceSha256 = Get-Sha256 (Join-Path $repoRoot $case.Sketch)
        BuildResult = "PASS"
        Upload = "NOT RUN - NO PHYSICAL ACCESS"
        Serial = "NOT RUN - NO PHYSICAL ACCESS"
        FirmwarePath = $firmware
        BuildLogPath = $buildLog
    }
    $results += $result
    Write-Output "BUILD_PASS CASE=$($case.Name) BIN_SIZE=$($result.BinarySize) FIRMWARE_SHA256=$($result.FirmwareSha256)"
}

$summaryLeaf = if ($CaseName.Length -gt 0) {
    "build-matrix-summary-$CaseName.csv"
} else {
    "build-matrix-summary.csv"
}
$summaryCsv = Join-Path $matrixRoot $summaryLeaf
$results | Export-Csv -LiteralPath $summaryCsv -NoTypeInformation -Encoding UTF8
Write-Output "BUILD_MATRIX_RESULT=PASS CASES=$($results.Count)"
Write-Output "BUILD_MATRIX_SUMMARY=$summaryCsv"
