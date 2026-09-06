param(
    [ValidateRange(5, 3600)]
    [int]$DurationSeconds = 60,
    [ValidatePattern('^[A-Za-z0-9-]*$')]
    [string]$CaseName = "",
    [string]$C1PeerIp = "192.168.50.30",
    [string]$OutputRoot = ""
)

# DG-D build matrix (Mode 18, USB_FIXED10_UDP_POSITIVE_PARSE_IMMEDIATE_NULL_DISCARD). New, additive file.
# Does not modify tools/usb_lan_diagnostic_build_matrix.ps1 (the accepted C1/C2
# matrix, donor-hash-verified in the implementation plan, B-12) -- reused by
# copy-adapt only, restricted to the two DG-D build cases. Build is
# arduino-cli compile only; this script never uploads.

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
if ($C1PeerIp -cne "192.168.50.30") {
    throw "BLOCKED_DG_D_REPAIR_ENDPOINT_BUILD_MISMATCH expected=192.168.50.30 actual=$C1PeerIp"
}
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

function Get-InventoryRows([string[]]$Paths) {
    $rows = foreach ($path in $Paths) {
        if (!(Test-Path -LiteralPath $path)) { throw "BLOCKED_DG_D_BUILD_ENVIRONMENT_UNRESOLVED missing=$path" }
        $item = Get-Item -LiteralPath $path
        $files = if ($item.PSIsContainer) { Get-ChildItem -LiteralPath $item.FullName -Recurse -File | Sort-Object FullName } else { @($item) }
        foreach ($file in $files) {
            [pscustomobject]@{ Path=$file.FullName; Size=[int64]$file.Length; Sha256=Get-Sha256 $file.FullName }
        }
    }
    @($rows | Sort-Object Path -Unique)
}

function Write-Inventory([object[]]$Rows,[string]$Path) {
    $Rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    Get-Sha256 $Path
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

$cases = @(
    [pscustomobject]@{ Name="DG-D-S1"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnosticDG_D.ino"; SourceRelative="diagnostics\usb-lan-gate-dg-d\M5Stack-PS5CoREUsbLanIsolationDiagnosticDG_D\M5Stack-PS5CoREUsbLanIsolationDiagnosticDG_D.ino"; Mode=18; Order=0; PhyProfile=2; CaseDurationSeconds=10 },
    [pscustomobject]@{ Name="DG-D-T1"; Sketch="M5Stack-PS5CoREUsbLanIsolationDiagnosticDG_D.ino"; SourceRelative="diagnostics\usb-lan-gate-dg-d\M5Stack-PS5CoREUsbLanIsolationDiagnosticDG_D\M5Stack-PS5CoREUsbLanIsolationDiagnosticDG_D.ino"; Mode=18; Order=0; PhyProfile=2; CaseDurationSeconds=60 }
)
if ($CaseName.Length -gt 0) {
    $cases = @($cases | Where-Object { $_.Name -eq $CaseName })
    if ($cases.Count -ne 1) { throw "Unknown DG-D build matrix case: $CaseName" }
}

New-Item -ItemType Directory -Path $matrixRoot | Out-Null
$results = @()
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
    $candidateSource = Join-Path $repoRoot $case.SourceRelative
    Copy-Item -LiteralPath $candidateSource -Destination (Join-Path $sketchDir $case.Sketch)
    $coreDestination = Join-Path $sketchDir "src\core_protocol"
    New-Item -ItemType Directory -Force -Path $coreDestination | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot "src\core_protocol\CoreProtocol.h") -Destination $coreDestination -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "src\core_protocol\CoreProtocol.cpp") -Destination $coreDestination -Force

    $coreRoot = Join-Path $env:LOCALAPPDATA "Arduino15\packages\m5stack\hardware\esp32\3.3.7"
    $platformPath = Join-Path $coreRoot "platform.txt"
    $cliCommand = Get-Command arduino-cli -ErrorAction SilentlyContinue
    if ($null -eq $cliCommand -or !(Test-Path -LiteralPath $platformPath)) {
        throw "BLOCKED_DG_D_BUILD_ENVIRONMENT_UNRESOLVED"
    }
    $cliPath = $cliCommand.Source
    $cliIdentity = (& $cliPath version 2>&1 | Out-String).Trim()
    $sourcePaths = @((Join-Path $sketchDir $case.Sketch),(Join-Path $coreDestination 'CoreProtocol.h'),(Join-Path $coreDestination 'CoreProtocol.cpp'))
    $dependencyPaths = @($libraries.M5Unified,$libraries.M5GFX,$libraries.M5Ethernet,$libraries.Uhs,$platformPath)
    $preSourcePath=Join-Path $caseRoot 'PRE_BUILD-source-inventory.csv'
    $preDependencyPath=Join-Path $caseRoot 'PRE_BUILD-dependency-inventory.csv'
    $preSourceHash=Write-Inventory (Get-InventoryRows $sourcePaths) $preSourcePath
    $preDependencyHash=Write-Inventory (Get-InventoryRows $dependencyPaths) $preDependencyPath

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
        "-DUSB_LAN_PHY_PROFILE=$($case.PhyProfile)",
        "-DUSB_LAN_C1_PEER_IP_A=$($c1PeerBytes[0])",
        "-DUSB_LAN_C1_PEER_IP_B=$($c1PeerBytes[1])",
        "-DUSB_LAN_C1_PEER_IP_C=$($c1PeerBytes[2])",
        "-DUSB_LAN_C1_PEER_IP_D=$($c1PeerBytes[3])"
    )
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
    $compileCommand = '"{0}" {1}' -f $cliPath, (($compileArgs | ForEach-Object { if($_ -match '\s'){ '"'+($_.Replace('"','\"'))+'"' } else { $_ } }) -join ' ')
    [IO.File]::WriteAllLines((Join-Path $caseRoot 'build-authority.txt'),@(
        "ARDUINO_CLI_PATH=$cliPath","ARDUINO_CLI_IDENTITY=$cliIdentity","ARDUINO_CORE=m5stack:esp32@3.3.7","FQBN=$fqbn","PLATFORM_TXT_PATH=$platformPath","PLATFORM_TXT_SHA256=$(Get-Sha256 $platformPath)","COMPILE_COMMAND=$compileCommand","UPLOAD_COMMAND=NOT_PRESENT","PHYSICAL_EXECUTION=NOT_RUN"
    ),[Text.UTF8Encoding]::new($false))
    Write-Output "BUILD_BEGIN CASE=$($case.Name) MODE=$($case.Mode) INIT_ORDER=$($case.Order)"
    & arduino-cli @compileArgs 2>&1 | Out-File -LiteralPath $buildLog -Encoding utf8
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Get-Content -LiteralPath $buildLog -Tail 80 | Write-Output
        throw "Build failed: $($case.Name); log=$buildLog"
    }
    $postSourcePath=Join-Path $caseRoot 'POST_BUILD-source-inventory.csv'
    $postDependencyPath=Join-Path $caseRoot 'POST_BUILD-dependency-inventory.csv'
    $postSourceHash=Write-Inventory (Get-InventoryRows $sourcePaths) $postSourcePath
    $postDependencyHash=Write-Inventory (Get-InventoryRows $dependencyPaths) $postDependencyPath
    if($preSourceHash -cne $postSourceHash -or $preDependencyHash -cne $postDependencyHash){
        throw "BLOCKED_DG_D_PRE_POST_BUILD_DRIFT"
    }
    $firmware = Join-Path $buildPath "$($case.Sketch).bin"
    if (!(Test-Path -LiteralPath $firmware)) { throw "Firmware missing: $firmware" }
    $elf=Join-Path $buildPath "$($case.Sketch).elf"
    $merged=Join-Path $buildPath "$($case.Sketch).merged.bin"
    $bootloader=Join-Path $buildPath "$($case.Sketch).bootloader.bin"
    $partitions=Join-Path $buildPath "$($case.Sketch).partitions.bin"
    foreach($artifact in @($elf,$merged,$bootloader,$partitions)){if(!(Test-Path -LiteralPath $artifact)){throw "Build artifact missing: $artifact"}}
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
        SourceSha256 = Get-Sha256 $candidateSource
        PreBuildSourceInventorySha256 = $preSourceHash
        PostBuildSourceInventorySha256 = $postSourceHash
        PreBuildDependencyInventorySha256 = $preDependencyHash
        PostBuildDependencyInventorySha256 = $postDependencyHash
        ElfSize = (Get-Item $elf).Length
        ElfSha256 = Get-Sha256 $elf
        MergedBinSize = (Get-Item $merged).Length
        MergedBinSha256 = Get-Sha256 $merged
        BootloaderSize = (Get-Item $bootloader).Length
        BootloaderSha256 = Get-Sha256 $bootloader
        PartitionsSize = (Get-Item $partitions).Length
        PartitionsSha256 = Get-Sha256 $partitions
        ArduinoCliPath = $cliPath
        ArduinoCliIdentity = $cliIdentity
        CoreIdentity = 'm5stack:esp32@3.3.7'
        CompileCommand = $compileCommand
        BuildResult = "PASS"
        Upload = "NOT_RUN"
        Serial = "NOT_RUN"
        FirmwarePath = $firmware
        BuildLogPath = $buildLog
    }
    $results += $result
    Write-Output "BUILD_PASS CASE=$($case.Name) BIN_SIZE=$($result.BinarySize) FIRMWARE_SHA256=$($result.FirmwareSha256)"
}

$summaryLeaf = if ($CaseName.Length -gt 0) {
    "dg-d-build-matrix-summary-$CaseName.csv"
} else {
    "dg-d-build-matrix-summary.csv"
}
$summaryCsv = Join-Path $matrixRoot $summaryLeaf
$results | Export-Csv -LiteralPath $summaryCsv -NoTypeInformation -Encoding UTF8
Write-Output "BUILD_MATRIX_RESULT=PASS CASES=$($results.Count)"
Write-Output "BUILD_MATRIX_SUMMARY=$summaryCsv"
