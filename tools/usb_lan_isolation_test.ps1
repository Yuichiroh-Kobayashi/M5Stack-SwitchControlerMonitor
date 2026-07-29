param(
    [ValidateRange(0, 7)]
    [int]$Mode = 0,
    [ValidateRange(0, 2)]
    [int]$InitOrder = 0,
    [ValidateRange(30, 3600)]
    [int]$DurationSeconds = 600,
    [string]$Port = "COM4",
    [ValidateSet("StackedLan", "NoLanModule", "PoweredHub")]
    [string]$PhysicalSetup = "StackedLan",
    [ValidateSet("DualSenseA", "DualSenseB", "HoriPad", "Mouse", "Keyboard", "Unknown")]
    [string]$Controller = "Unknown",
    [string]$ControllerVidPid = "",
    [ValidateSet("Original", "Alternate", "Fixed", "HubUpstream", "Unknown")]
    [string]$Cable = "Unknown",
    [ValidateSet("HIDUniversal", "PS5USB", "WirelessSender", "Legacy")]
    [string]$UsbDriver = "HIDUniversal",
    [ValidateSet("Present", "Removed")]
    [string]$BatteryBottom = "Present",
    [string]$HubModel = "Unknown",
    [ValidateSet("EXTERNAL_ON", "OFF", "Unknown")]
    [string]$HubPower = "Unknown",
    [string]$HubPort = "Unknown",
    [ValidateSet("ON", "OFF", "Unknown")]
    [string]$HubPortSwitch = "Unknown",
    [ValidateSet("ON", "OFF", "Unknown")]
    [string]$OtherPortSwitches = "Unknown",
    [ValidateSet("IsolationDiagnostic", "WirelessSender", "Ps5UsbDiagnostic")]
    [string]$Firmware = "IsolationDiagnostic",
    [ValidateRange(0, 1)]
    [int]$UsbHidRawLog = 0,
    [ValidateRange(0, 1)]
    [int]$Ps5InitOutput = 0,
    [ValidatePattern('^[A-Za-z0-9_-]*$')]
    [string]$TestLabel = "",
    [switch]$PrepareOnly,
    [switch]$ReuseBuild,
    [switch]$BuildOnly,
    [switch]$IncrementalBuild
)

$ErrorActionPreference = "Stop"
$ps5InitOutputText = if ($Ps5InitOutput -eq 0) { "NO_OUTPUT" } else { "DEFAULT" }
$targetReadyTimeoutMs = if ($PhysicalSetup -eq "PoweredHub" -or $Firmware -eq "Ps5UsbDiagnostic") { 15000 } else { 0 }
$poweredHubTest = if ($PhysicalSetup -eq "PoweredHub") { 1 } else { 0 }
$repoRoot = Split-Path -Parent $PSScriptRoot
$isolationRoot = Join-Path $repoRoot "build-temp\usb-lan-isolation"
$downloadPath = Join-Path $isolationRoot "downloads\USB_Host_Shield_2.0-1.7.0.zip"
$sourceRoot = Join-Path $isolationRoot "source"
$libraryRoot = Join-Path $isolationRoot "libraries"
$globalLibraryRoot = "C:\Users\yu-ichirou\Documents\Arduino\libraries"
$uhsName = "USB_Host_Shield_Library_2.0"
$uhsIsolated = Join-Path $libraryRoot $uhsName
$manifestPath = Join-Path $isolationRoot "library-hashes.txt"
$expectedPnp = "USB\VID_303A&PID_1001&MI_00\6&25A42EA3&0&0000"
$fqbn = "m5stack:esp32:m5stack_cores3"

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Assert-LibraryVersion([string]$Path, [string]$ExpectedName, [string]$ExpectedVersion) {
    $properties = Join-Path $Path "library.properties"
    if (!(Test-Path -LiteralPath $properties)) { throw "Missing library.properties: $properties" }
    $text = Get-Content -LiteralPath $properties -Raw
    if ($text -notmatch "(?m)^name=$([regex]::Escape($ExpectedName))\s*$") {
        throw "Library name mismatch at $properties"
    }
    if ($text -notmatch "(?m)^version=$([regex]::Escape($ExpectedVersion))\s*$") {
        throw "Library version mismatch at $properties; expected $ExpectedVersion"
    }
}

function Copy-IsolatedLibrary([string]$DirectoryName) {
    $source = Join-Path $globalLibraryRoot $DirectoryName
    $destination = Join-Path $libraryRoot $DirectoryName
    if (!(Test-Path -LiteralPath $source)) { throw "Global source library missing: $source" }
    if (!(Test-Path -LiteralPath $destination)) {
        Copy-Item -LiteralPath $source -Destination $destination -Recurse
    }
}

function Apply-CoreS3Patch([string]$LibDir) {
    $avrPinsPath = Join-Path $LibDir "avrpins.h"
    $usbCorePath = Join-Path $LibDir "UsbCore.h"
    $usbHostPath = Join-Path $LibDir "usbhost.h"
    $avrPinsText = Get-Content -LiteralPath $avrPinsPath -Raw
    $usbCoreText = Get-Content -LiteralPath $usbCorePath -Raw
    $usbHostText = Get-Content -LiteralPath $usbHostPath -Raw

    if ($avrPinsText -match "ARDUINO_M5STACK_CORES3" -or
        $usbCoreText -match "ARDUINO_M5STACK_CORES3" -or
        $usbHostText -match "ARDUINO_M5STACK_CORES3") {
        throw "Pristine UHS source already contains a CoreS3 patch; duplicate or old minimal patch suspected."
    }

    $requiredPins = @(
        "MAKE_PIN(P13, 13); // Extra SS for M5Stack Core",
        "MAKE_PIN(P33, 33); // Extra SS for M5Stack Core2",
        "MAKE_PIN(P34, 34); // Extra INT for M5Stack Core/Core2",
        "MAKE_PIN(P35, 35); // Extra INT for M5Stack Core/Core2",
        "MAKE_PIN(P38, 38); // Core2 MISO"
    )
    $missingPins = @($requiredPins | Where-Object { $avrPinsText -notmatch [regex]::Escape($_) })
    if ($missingPins.Count -gt 0) {
        $markerPattern = 'MAKE_PIN\(P17,\s*17\);\s*// INT'
        $regex = [regex]$markerPattern
        if (!$regex.IsMatch($avrPinsText)) { throw "avrpins.h legacy pin insertion marker missing." }
        $insertion = $missingPins -join "`r`n"
        $avrPinsText = $regex.Replace($avrPinsText, { param($m) $m.Value + "`r`n" + $insertion }, 1)
    }

    if ($usbCoreText -notmatch "USB_HOST_SHIELD_SS_TYPE") {
        $needle = "typedef MAX3421e<P5, P17> MAX3421E; // ESP32 boards"
        $replacement = @"
#ifndef USB_HOST_SHIELD_SS_TYPE
#define USB_HOST_SHIELD_SS_TYPE P5
#endif
#ifndef USB_HOST_SHIELD_INT_TYPE
#define USB_HOST_SHIELD_INT_TYPE P17
#endif
typedef MAX3421e<USB_HOST_SHIELD_SS_TYPE, USB_HOST_SHIELD_INT_TYPE> MAX3421E; // ESP32 boards (customizable)
"@.Trim()
        if (!$usbCoreText.Contains($needle)) { throw "UsbCore.h ESP32 typedef marker missing." }
        $usbCoreText = $usbCoreText.Replace($needle, $replacement)
    }

    $avrMarker = "#elif defined(ARDUINO_XIAO_ESP32S3)"
    if (!$avrPinsText.Contains($avrMarker)) { throw "avrpins.h CoreS3 insertion marker missing." }
    $coreS3Pins = @"
#elif defined(ARDUINO_M5STACK_CORES3)
// USB Host Shield Library 2.0 PR #843: M5Stack USB Module v1.2 on CoreS3.
// SS/INT CH2 uses GPIO1/GPIO14; SPI uses SCK=36, MOSI=37, MISO=35.
#ifdef pgm_read_word
#undef pgm_read_word
#endif
#ifdef pgm_read_dword
#undef pgm_read_dword
#endif
#ifdef pgm_read_float
#undef pgm_read_float
#endif
#ifdef pgm_read_ptr
#undef pgm_read_ptr
#endif
#define pgm_read_word(addr) ({ typeof(addr) _addr = (addr); *(const unsigned short *)(_addr); })
#define pgm_read_dword(addr) ({ typeof(addr) _addr = (addr); *(const unsigned long *)(_addr); })
#define pgm_read_float(addr) ({ typeof(addr) _addr = (addr); *(const float *)(_addr); })
#define pgm_read_ptr(addr) ({ typeof(addr) _addr = (addr); *(void * const *)(_addr); })
MAKE_PIN(P35, 35); // MISO
MAKE_PIN(P37, 37); // MOSI
MAKE_PIN(P36, 36); // SCK
MAKE_PIN(P1, 1);   // SS (USB Module CH2)
MAKE_PIN(P14, 14); // INT (USB Module CH2)

"@
    $avrPinsText = $avrPinsText.Replace($avrMarker, $coreS3Pins + $avrMarker)

    $coreMarker = "#elif defined(ARDUINO_XIAO_ESP32S3)"
    if (!$usbCoreText.Contains($coreMarker)) { throw "UsbCore.h CoreS3 insertion marker missing." }
    $usbCoreText = $usbCoreText.Replace(
        $coreMarker,
        "#elif defined(ARDUINO_M5STACK_CORES3)`r`ntypedef MAX3421e<P1, P14> MAX3421E; // USB Module v1.2: SS/INT CH2`r`n" + $coreMarker)
    if (!$usbHostText.Contains($coreMarker)) { throw "usbhost.h CoreS3 insertion marker missing." }
    $usbHostText = $usbHostText.Replace(
        $coreMarker,
        "#elif defined(ARDUINO_M5STACK_CORES3)`r`ntypedef SPi< P36, P37, P35, P1 > spi; // USB Module v1.2 SPI pins`r`n" + $coreMarker)

    Set-Content -LiteralPath $avrPinsPath -Value $avrPinsText -Encoding UTF8
    Set-Content -LiteralPath $usbCorePath -Value $usbCoreText -Encoding UTF8
    Set-Content -LiteralPath $usbHostPath -Value $usbHostText -Encoding UTF8
}

function Assert-UniquePatch([string]$LibDir) {
    $avr = Get-Content -LiteralPath (Join-Path $LibDir "avrpins.h") -Raw
    $core = Get-Content -LiteralPath (Join-Path $LibDir "UsbCore.h") -Raw
    $hostFile = Get-Content -LiteralPath (Join-Path $LibDir "usbhost.h") -Raw
    $coreCount = ([regex]::Matches($core, 'typedef\s+MAX3421e<P1,\s*P14>\s+MAX3421E;')).Count
    $hostCount = ([regex]::Matches($hostFile, 'typedef\s+SPi<\s*P36,\s*P37,\s*P35,\s*P1\s*>\s+spi;')).Count
    $avrGuardCount = ([regex]::Matches($avr, '#elif defined\(ARDUINO_M5STACK_CORES3\)')).Count
    if ($coreCount -ne 1 -or $hostCount -ne 1 -or $avrGuardCount -ne 1) {
        throw "Patch uniqueness failed: MAX3421E=$coreCount SPi=$hostCount avrpinsGuard=$avrGuardCount"
    }
    $branch = [regex]::Match($avr, '(?s)#elif defined\(ARDUINO_M5STACK_CORES3\)(.*?)#elif defined\(ARDUINO_XIAO_ESP32S3\)').Groups[1].Value
    if ($branch -notmatch '#define pgm_read_word\(addr\)' -or
        $branch -notmatch 'MAKE_PIN\(P1, 1\)' -or
        $branch -notmatch 'MAKE_PIN\(P14, 14\)') {
        throw "CoreS3 avrpins branch is an old minimal or incomplete patch."
    }
}

function Prepare-IsolatedLibraries {
    New-Item -ItemType Directory -Force -Path $isolationRoot, $sourceRoot, $libraryRoot | Out-Null
    if (!(Test-Path -LiteralPath $downloadPath)) {
        throw "Official UHS 1.7.0 archive is missing: $downloadPath"
    }
    Copy-IsolatedLibrary "M5Unified"
    Copy-IsolatedLibrary "M5GFX"
    Copy-IsolatedLibrary "M5-Ethernet"

    if (!(Test-Path -LiteralPath $uhsIsolated)) {
        $expandedMarker = Join-Path $sourceRoot "USB_Host_Shield_2.0-1.7.0"
        if (!(Test-Path -LiteralPath $expandedMarker)) {
            Expand-Archive -LiteralPath $downloadPath -DestinationPath $sourceRoot
        }
        if (!(Test-Path -LiteralPath $expandedMarker)) { throw "Unexpected UHS archive layout." }
        Copy-Item -LiteralPath $expandedMarker -Destination $uhsIsolated -Recurse
        Apply-CoreS3Patch $uhsIsolated
    }

    Assert-LibraryVersion (Join-Path $libraryRoot "M5Unified") "M5Unified" "0.2.19"
    Assert-LibraryVersion (Join-Path $libraryRoot "M5GFX") "M5GFX" "0.2.26"
    Assert-LibraryVersion (Join-Path $libraryRoot "M5-Ethernet") "M5-Ethernet" "4.0.0"
    Assert-LibraryVersion $uhsIsolated "USB Host Shield Library 2.0" "1.7.0"
    Assert-UniquePatch $uhsIsolated

    $hashLines = @(
        "ARCHIVE SHA256=$(Get-Sha256 $downloadPath)",
        "avrpins.h SHA256=$(Get-Sha256 (Join-Path $uhsIsolated 'avrpins.h'))",
        "UsbCore.h SHA256=$(Get-Sha256 (Join-Path $uhsIsolated 'UsbCore.h'))",
        "usbhost.h SHA256=$(Get-Sha256 (Join-Path $uhsIsolated 'usbhost.h'))",
        "library.properties SHA256=$(Get-Sha256 (Join-Path $uhsIsolated 'library.properties'))"
    )
    Set-Content -LiteralPath $manifestPath -Value $hashLines -Encoding UTF8
    $hashLines | ForEach-Object { Write-Output $_ }
    Write-Output "ISOLATED_LIBRARIES_READY=$libraryRoot"
}

function Assert-SenderIdentity {
    $device = Get-CimInstance Win32_SerialPort |
        Where-Object { $_.DeviceID -eq $Port } |
        Select-Object -First 1
    if ($null -eq $device) { throw "Sender port not found: $Port" }
    Write-Output "PNP_CHECK PORT=$($device.DeviceID) PNP=$($device.PNPDeviceID)"
    if ($device.PNPDeviceID -ne $expectedPnp) {
        throw "Sender identity mismatch. Expected '$expectedPnp', got '$($device.PNPDeviceID)'"
    }
}

function Capture-Diagnostic([string]$LogPath) {
    $serial = [System.IO.Ports.SerialPort]::new($Port, 115200, 'None', 8, 'One')
    $serial.ReadTimeout = 100
    $serial.DtrEnable = $false
    $serial.RtsEnable = $false
    $writer = [System.IO.StreamWriter]::new($LogPath, $false, [System.Text.UTF8Encoding]::new($false))
    $buffer = ""
    $complete = $null
    try {
        $metadata = @(
            "TEST_METADATA",
            "PHYSICAL_SETUP=$PhysicalSetup",
            "CONTROLLER=$Controller",
            "CONTROLLER_VID_PID=$ControllerVidPid",
            "CABLE=$Cable",
            "USB_DRIVER=$UsbDriver",
            "BATTERY_BOTTOM=$BatteryBottom",
            "HUB_MODEL=$HubModel",
            "HUB_POWER=$HubPower",
            "HUB_PORT=$HubPort",
            "HUB_PORT_SWITCH=$HubPortSwitch",
            "OTHER_PORT_SWITCHES=$OtherPortSwitches",
            "LAN_MODULE=$(if ($PhysicalSetup -eq 'StackedLan') { 'PRESENT' } else { 'REMOVED' })",
            "FIRMWARE=$Firmware",
            "PORT=$Port",
            "MODE=$Mode",
            "INIT_ORDER=$InitOrder",
            "DURATION_SECONDS=$DurationSeconds",
            "PS5_INIT_OUTPUT=$ps5InitOutputText",
            "TEST_LABEL=$TestLabel"
        )
        foreach ($metadataLine in $metadata) {
            $record = "$(Get-Date -Format o) HOST $metadataLine"
            $writer.WriteLine($record)
            Write-Output $record
        }
        $writer.Flush()
        $serial.Open()
        $deadline = [DateTime]::UtcNow.AddSeconds($DurationSeconds + 120)
        while ([DateTime]::UtcNow -lt $deadline -and $null -eq $complete) {
            $chunk = $serial.ReadExisting()
            if ($chunk.Length -eq 0) { Start-Sleep -Milliseconds 10; continue }
            $buffer += $chunk
            while (($newline = $buffer.IndexOf("`n")) -ge 0) {
                $line = $buffer.Substring(0, $newline).TrimEnd("`r")
                $buffer = $buffer.Substring($newline + 1)
                if ($line.Length -eq 0) { continue }
                $record = "{0:O} {1} {2}" -f [DateTimeOffset]::Now, $Port, $line
                $writer.WriteLine($record)
                $writer.Flush()
                Write-Output $record
                if ($line -match '^TEST_COMPLETE=(PASS|FAIL)' -or
                    $line -match '^TEST_RESULT=(NO_TARGET_HID|OSC_INIT_FAILED|SET_REPORT_PARSER_ERROR|WRONG_BOOT_MODE|PANIC|WDT)') {
                    $complete = $line
                }
            }
        }
    }
    finally {
        if ($serial.IsOpen) { $serial.Close() }
        $serial.Dispose()
        $writer.Dispose()
    }
    if ($null -eq $complete) { throw "Diagnostic timed out without TEST_COMPLETE marker." }
    Write-Output "CAPTURE_RESULT $complete"
}

Prepare-IsolatedLibraries
if ($PrepareOnly) { exit 0 }

if ($Mode -lt 3 -and $InitOrder -ne 0) { throw "Modes 0..2 require InitOrder 0." }
if ($Mode -ge 3 -and $InitOrder -eq 0) { throw "Modes 3..7 require InitOrder 1 or 2." }
if ($PhysicalSetup -eq "NoLanModule" -and $Mode -ge 2) {
    throw "NoLanModule is limited to Mode 0 or 1; LAN-capable modes require the LAN Module."
}
if ($Firmware -eq "WirelessSender" -and ($Mode -ne 0 -or $InitOrder -ne 0)) {
    throw "WirelessSender tests require Mode 0 and InitOrder 0 metadata."
}
if ($Firmware -eq "WirelessSender" -and $UsbDriver -ne "WirelessSender") {
    throw "WirelessSender firmware requires UsbDriver WirelessSender."
}
if ($Firmware -eq "Ps5UsbDiagnostic" -and ($Mode -ne 0 -or $InitOrder -ne 0)) {
    throw "Ps5UsbDiagnostic tests require Mode 0 and InitOrder 0 metadata."
}
if ($Firmware -eq "Ps5UsbDiagnostic" -and $UsbDriver -ne "PS5USB") {
    throw "Ps5UsbDiagnostic firmware requires UsbDriver PS5USB."
}

$firmwareSlug = $Firmware.ToLowerInvariant()
$sourceSketchName = switch ($Firmware) {
    "WirelessSender" { "M5Stack-SwitchController2CoREWirelessSender.ino" }
    "Ps5UsbDiagnostic" { "M5Stack-PS5CoREPs5UsbDiagnostic.ino" }
    default { "M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino" }
}
$sketchBaseName = [System.IO.Path]::GetFileNameWithoutExtension($sourceSketchName)
$durationMs = $DurationSeconds * 1000
$caseName = "$firmwareSlug-mode-$Mode-order-$InitOrder-duration-$DurationSeconds-timeout-$targetReadyTimeoutMs-hub-$poweredHubTest-ps5out-$Ps5InitOutput-raw-$UsbHidRawLog"
$sketchDir = Join-Path $isolationRoot "sketches\$caseName\$sketchBaseName"
$buildPath = Join-Path $isolationRoot "build\$caseName"
$logDir = Join-Path $isolationRoot "logs"
New-Item -ItemType Directory -Force -Path $sketchDir, $buildPath, $logDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot $sourceSketchName) -Destination $sketchDir -Force
if ($Firmware -eq "IsolationDiagnostic") {
    $coreSource = Join-Path $repoRoot "src\core_protocol"
    $coreDestination = Join-Path $sketchDir "src\core_protocol"
    New-Item -ItemType Directory -Force -Path $coreDestination | Out-Null
    Copy-Item -LiteralPath (Join-Path $coreSource "CoreProtocol.h") -Destination $coreDestination -Force
    Copy-Item -LiteralPath (Join-Path $coreSource "CoreProtocol.cpp") -Destination $coreDestination -Force
}

$extraFlags = @(
    "-DESP32", "-DUSB_HOST_SHIELD_SS_TYPE=P1", "-DUSB_HOST_SHIELD_INT_TYPE=P14",
    "-DPIN_SPI_SCK=36", "-DPIN_SPI_MOSI=37", "-DPIN_SPI_MISO=35", "-DPIN_SPI_SS=1",
    "-DUSB_HOST_SHIELD_SS_GPIO=1", "-DUSB_HOST_SHIELD_INT_GPIO=14",
    "-DBUILD_TARGET_CORES3SE", "-DARDUINO_M5STACK_CORES3", "-DBOARD_HAS_PSRAM",
    "-DARDUINO_USB_MODE=1", "-DARDUINO_USB_CDC_ON_BOOT=1",
    "-DARDUINO_USB_MSC_ON_BOOT=0", "-DARDUINO_USB_DFU_ON_BOOT=0",
    "-DUSB_LAN_TEST_MODE=$Mode", "-DUSB_LAN_INIT_ORDER=$InitOrder",
    "-DUSB_LAN_TEST_DURATION_MS=$durationMs", "-DUSB_TEST_DURATION_MS=$durationMs",
    "-DUSB_HID_RAW_LOG=$UsbHidRawLog",
    "-DUSB_TARGET_READY_TIMEOUT_MS=$targetReadyTimeoutMs",
    "-DUSB_POWERED_HUB_TEST=$poweredHubTest",
    "-DPS5USB_INIT_OUTPUT=$Ps5InitOutput"
) -join " "

$buildLog = Join-Path $logDir "$caseName-build.log"
$compileArgs = @(
    "compile", "--verbose", "--fqbn", $fqbn,
    "--build-path", $buildPath,
    "--library", (Join-Path $libraryRoot "M5Unified"),
    "--library", (Join-Path $libraryRoot "M5GFX"),
    "--library", (Join-Path $libraryRoot "M5-Ethernet"),
    "--library", $uhsIsolated,
    "--build-property", "build.extra_flags=$extraFlags",
    $sketchDir
)
if (!$IncrementalBuild) { $compileArgs = @("compile", "--verbose", "--clean") + $compileArgs[2..($compileArgs.Count - 1)] }
Write-Output "BUILD_CASE=$caseName"
if (!$ReuseBuild) {
    & arduino-cli @compileArgs 2>&1 | Tee-Object -FilePath $buildLog
    if ($LASTEXITCODE -ne 0) { throw "Build failed for $caseName" }
} elseif (!(Test-Path -LiteralPath $buildLog)) {
    throw "ReuseBuild requested but verbose build log is missing: $buildLog"
}
$buildText = Get-Content -LiteralPath $buildLog -Raw
$requiredPaths = @(
    (Join-Path $libraryRoot "M5Unified"),
    (Join-Path $libraryRoot "M5GFX"),
    $uhsIsolated
)
if ($Firmware -eq "IsolationDiagnostic") {
    $requiredPaths += (Join-Path $libraryRoot "M5-Ethernet")
}
foreach ($requiredPath in $requiredPaths) {
    $includePattern = '-I"?' + [regex]::Escape($requiredPath)
    if ($buildText -notmatch $includePattern) {
        throw "Verbose build did not prove isolated library use: $requiredPath"
    }
}
foreach ($globalPath in @(
    (Join-Path $globalLibraryRoot "M5Unified"), (Join-Path $globalLibraryRoot "M5GFX"),
    (Join-Path $globalLibraryRoot "M5-Ethernet"), (Join-Path $globalLibraryRoot $uhsName))) {
    $includePattern = '-I"?' + [regex]::Escape($globalPath)
    if ($buildText -match $includePattern) {
        throw "Verbose build selected a global library include path: $globalPath"
    }
}
$firmwareBin = Join-Path $buildPath "$sourceSketchName.bin"
if (!(Test-Path -LiteralPath $firmwareBin)) { throw "Compiled firmware is missing: $firmwareBin" }
Write-Output "ISOLATED_BUILD_PATHS_VERIFIED=1"
if ($BuildOnly) { exit 0 }

Assert-SenderIdentity
& arduino-cli upload --fqbn $fqbn --port $Port --input-dir $buildPath
if ($LASTEXITCODE -ne 0) { throw "Upload failed for $caseName" }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$physicalSlug = $PhysicalSetup.ToLowerInvariant()
$labelSlug = if ($TestLabel.Length -gt 0) { "-$($TestLabel.ToLowerInvariant())" } else { "" }
$controllerSlug = $Controller.ToLowerInvariant()
$driverSlug = $UsbDriver.ToLowerInvariant()
$cableSlug = $Cable.ToLowerInvariant()
$serialLog = Join-Path $logDir "$caseName-$physicalSlug-$controllerSlug-$driverSlug-$cableSlug$labelSlug-$timestamp-serial.log"
Capture-Diagnostic $serialLog
Write-Output "SERIAL_LOG=$serialLog"
