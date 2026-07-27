param(
    [ValidateRange(1, 3600)]
    [int]$DurationSeconds = 60,
    [string]$ReceiverPort = "COM3",
    [string]$SenderPort = "COM4",
    [ValidateRange(1200, 2000000)]
    [int]$Baud = 115200,
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
$ports = @()
$writer = $null

function New-CapturePort([string]$Name) {
    $port = [System.IO.Ports.SerialPort]::new($Name, $Baud, 'None', 8, 'One')
    $port.ReadTimeout = 20
    $port.NewLine = "`n"
    try {
        $port.Open()
    }
    catch {
        throw "Failed to open $Name at $Baud baud: $($_.Exception.Message)"
    }
    return $port
}

function Write-CaptureLine([string]$PortName, [string]$Line) {
    $record = "{0:O} {1} {2}" -f [DateTimeOffset]::Now, $PortName, $Line.TrimEnd("`r", "`n")
    Write-Output $record
    if ($null -ne $writer) {
        $writer.WriteLine($record)
        $writer.Flush()
    }
}

try {
    if ($OutputPath) {
        $absolute = [System.IO.Path]::GetFullPath($OutputPath)
        $parent = Split-Path -Parent $absolute
        if ($parent -and !(Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent | Out-Null
        }
        $writer = [System.IO.StreamWriter]::new($absolute, $false, [System.Text.UTF8Encoding]::new($false))
    }

    $receiver = New-CapturePort $ReceiverPort
    $ports += $receiver
    try {
        $sender = New-CapturePort $SenderPort
        $ports += $sender
    }
    catch {
        $receiver.Close()
        throw
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($DurationSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $readAny = $false
        foreach ($port in $ports) {
            while ($port.BytesToRead -gt 0) {
                try {
                    Write-CaptureLine $port.PortName $port.ReadLine()
                    $readAny = $true
                }
                catch [System.TimeoutException] {
                    break
                }
                catch {
                    throw "Serial read failed on $($port.PortName): $($_.Exception.Message)"
                }
            }
        }
        if (!$readAny) { Start-Sleep -Milliseconds 2 }
    }
}
finally {
    foreach ($port in $ports) {
        if ($port.IsOpen) { $port.Close() }
        $port.Dispose()
    }
    if ($null -ne $writer) { $writer.Dispose() }
}
