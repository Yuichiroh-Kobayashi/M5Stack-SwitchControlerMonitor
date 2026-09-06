[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConfigFile,
    [string]$LibraryRoot='',
    [string]$OutputRoot='',
    [ValidateSet(10,20)][int]$PeriodMs=10,
    [ValidateSet(0,1)][int]$NumericUi=1
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent $PSScriptRoot
$workspacePrefix=[IO.Path]::GetFullPath($repoRoot).TrimEnd('\')+'\'
function Assert-WorkspacePath([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if (!$full.StartsWith($workspacePrefix,[StringComparison]::OrdinalIgnoreCase)) {
        throw "Path must be isolated inside workspace: $full"
    }
    $full
}
$ConfigFile=Assert-WorkspacePath $ConfigFile
$cfg=Get-Content -LiteralPath $ConfigFile -Encoding UTF8 -Raw | ConvertFrom-Json
foreach($key in @('data','downloads','user')) {
    $resolved=Assert-WorkspacePath $cfg.directories.$key
    if (!(Test-Path -LiteralPath $resolved -PathType Container)) {throw "Missing isolated directory: $key"}
}
$core=Join-Path $cfg.directories.data 'packages\m5stack\hardware\esp32\3.3.7'
if (!(Test-Path -LiteralPath (Join-Path $core 'platform.txt'))) {throw 'Pinned core3.3.7 is missing; no installation attempted'}
if ((Get-Content -LiteralPath (Join-Path $core 'platform.txt') -Raw) -notmatch '(?m)^version=3\.3\.7\s*$') {throw 'Wrong core version'}
if (!$LibraryRoot) {$LibraryRoot=Join-Path $repoRoot 'build-temp\usb-lan-isolation\libraries'}
$LibraryRoot=Assert-WorkspacePath $LibraryRoot
$libraries=@(
    @{Folder='M5Unified';Name='M5Unified';Version='0.2.19'},
    @{Folder='M5GFX';Name='M5GFX';Version='0.2.26'},
    @{Folder='M5-Ethernet';Name='M5-Ethernet';Version='4.0.0'},
    @{Folder='USB_Host_Shield_Library_2.0';Name='USB Host Shield Library 2.0';Version='1.7.0'}
)
foreach($lib in $libraries) {
    $lib.Path=Join-Path $LibraryRoot $lib.Folder
    $properties=Get-Content -LiteralPath (Join-Path $lib.Path 'library.properties') -Raw
    if($properties -notmatch "(?m)^name=$([regex]::Escape($lib.Name))\s*$" -or
       $properties -notmatch "(?m)^version=$([regex]::Escape($lib.Version))\s*$") {throw "Library version mismatch: $($lib.Folder)"}
}
$uhs=Join-Path $LibraryRoot 'USB_Host_Shield_Library_2.0'
if((Get-Content (Join-Path $uhs 'UsbCore.h') -Raw) -notmatch 'typedef\s+MAX3421e<P1,\s*P14>\s+MAX3421E;' -or
   (Get-Content (Join-Path $uhs 'usbhost.h') -Raw) -notmatch 'typedef\s+SPi<\s*P36,\s*P37,\s*P35,\s*P1\s*>\s+spi;') {throw 'Missing isolated CoreS3 UHS patch'}
if (!$OutputRoot) {$OutputRoot=Join-Path $repoRoot ('build-temp\product-builds\'+(Get-Date -Format yyyyMMdd-HHmmss)+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))}
$OutputRoot=Assert-WorkspacePath $OutputRoot
if (Test-Path -LiteralPath $OutputRoot) {throw 'Build evidence root must be new'}
New-Item -ItemType Directory -Path $OutputRoot | Out-Null
Copy-Item -LiteralPath $ConfigFile -Destination (Join-Path $OutputRoot 'cli-config.json')
$libraryHashes=@(foreach($lib in $libraries){foreach($file in (Get-ChildItem -LiteralPath $lib.Path -Recurse -File | Sort-Object FullName)){
    [pscustomobject]@{Library=$lib.Folder;Path=$file.FullName.Substring($lib.Path.Length+1);Sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
}})
$libraryHashes | Export-Csv -LiteralPath (Join-Path $OutputRoot 'library-hashes.csv') -NoTypeInformation -Encoding UTF8
& arduino-cli --config-file $ConfigFile version | Out-File (Join-Path $OutputRoot 'cli-version.txt') -Encoding UTF8
if($LASTEXITCODE -ne 0){throw 'CLI version failed'}
$plans=@(
    @{Name='receiver';Sketch='M5Stack-PS5CoRELANReceiver.ino';UsbOnly=0},
    @{Name='sender';Sketch='M5Stack-PS5CoRELANSender.ino';UsbOnly=0},
    @{Name='sender-usb-only';Sketch='M5Stack-PS5CoRELANSender.ino';UsbOnly=1}
)
$results=@()
foreach($plan in $plans) {
    $caseRoot=Join-Path $OutputRoot $plan.Name
    $sketch=Join-Path $caseRoot ([IO.Path]::GetFileNameWithoutExtension($plan.Sketch))
    $build=Join-Path $caseRoot 'build'
    New-Item -ItemType Directory -Path $sketch,$build -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot $plan.Sketch) -Destination $sketch
    Copy-Item -LiteralPath (Join-Path $repoRoot 'src') -Destination $sketch -Recurse
    $sourceHashes=@(Get-ChildItem -LiteralPath $sketch -Recurse -File | Sort-Object FullName | ForEach-Object {
        [pscustomobject]@{Path=$_.FullName.Substring($sketch.Length+1);Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
    })
    $sourceHashes | Export-Csv -LiteralPath (Join-Path $caseRoot 'source-hashes.csv') -NoTypeInformation -Encoding UTF8
    $flags=@('-DESP32','-DUSB_HOST_SHIELD_SS_TYPE=P1','-DUSB_HOST_SHIELD_INT_TYPE=P14',
      '-DPIN_SPI_SCK=36','-DPIN_SPI_MOSI=37','-DPIN_SPI_MISO=35','-DPIN_SPI_SS=1',
      '-DUSB_HOST_SHIELD_SS_GPIO=1','-DUSB_HOST_SHIELD_INT_GPIO=14',
      '-DBUILD_TARGET_CORES3SE','-DARDUINO_M5STACK_CORES3','-DBOARD_HAS_PSRAM',
      '-DARDUINO_USB_MODE=1','-DARDUINO_USB_CDC_ON_BOOT=1','-DARDUINO_USB_MSC_ON_BOOT=0',
      '-DARDUINO_USB_DFU_ON_BOOT=0','-DSERIAL2_RX_PIN=18','-DSERIAL2_TX_PIN=17',
      "-DSENDER_USB_ONLY=$($plan.UsbOnly)","-DPRODUCT_TRANSPORT_PERIOD_MS=$PeriodMs",
      "-DPRODUCT_NUMERIC_UI=$NumericUi") -join ' '
    $argsList=@('--config-file',$ConfigFile,'compile','--verbose','--clean','--jobs','8',
      '--fqbn','m5stack:esp32:m5stack_cores3','--build-path',$build)
    foreach($lib in $libraries){$argsList+=@('--library',$lib.Path)}
    $argsList+=@('--build-property',"build.extra_flags=$flags",$sketch)
    $argsList | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $caseRoot 'arguments.json') -Encoding UTF8
    $log=Join-Path $caseRoot 'build.log'
    Write-Output "BUILD_BEGIN=$($plan.Name)"
    & arduino-cli @argsList *> $log
    if($LASTEXITCODE -ne 0){Get-Content $log -Tail 50;throw "Build failed: $($plan.Name); evidence=$caseRoot"}
    $bin=Join-Path $build ($plan.Sketch+'.bin')
    $results+=[pscustomobject]@{Case=$plan.Name;SourceSha256=(Get-FileHash (Join-Path $sketch $plan.Sketch)).Hash;BinaryBytes=(Get-Item $bin).Length;BinarySha256=(Get-FileHash $bin).Hash;LogSha256=(Get-FileHash $log).Hash;Result='TARGET_BUILD_PASS';Physical='NOT_RUN'}
    $results | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutputRoot 'results.json') -Encoding UTF8
    Write-Output "BUILD_PASS=$($plan.Name)"
}
Write-Output "PRODUCT_BUILD_PASS CASES=$($results.Count) EVIDENCE=$OutputRoot"
