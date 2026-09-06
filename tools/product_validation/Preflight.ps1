# Pure validators are shared by the physical runner and offline PowerShell tests.
Set-StrictMode -Version Latest
function Assert-ProductIdentity($Devices,[string]$Port,[string]$ExpectedIdentity) {
    $matched=@($Devices | Where-Object { $_.Port -ceq $Port })
    if($matched.Count -ne 1 -or $matched[0].PnpDeviceId -cne $ExpectedIdentity -or $matched[0].Status -ne 'OK') {
        throw 'Exact COM/PnP identity mismatch'
    }
}
function Assert-ProductNetwork($Snapshot) {
    $nic=@($Snapshot.Nics | Where-Object { $_.IPAddress -eq '192.168.50.30' -and $_.PrefixLength -eq 24 })
    if($nic.Count -ne 1){throw 'Test NIC/prefix mismatch'}
    $routes=@($Snapshot.Routes | Where-Object { $_.InterfaceIndex -eq $nic[0].InterfaceIndex })
    if(@($routes | Where-Object {$_.DestinationPrefix -eq '0.0.0.0/0'}).Count){throw 'Test NIC has a default gateway'}
    if(@($routes | Where-Object {$_.DestinationPrefix -eq '192.168.50.0/24' -and $_.NextHop -eq '0.0.0.0'}).Count -ne 1){throw 'Test direct route mismatch'}
    if(@($Snapshot.Udp).Count){throw 'UDP50001 is occupied'}
    if(@($Snapshot.Conflicts).Count){throw 'Conflicting serial/peer/capture process'}
}
function Get-ProductDevices {
    @(Get-CimInstance Win32_PnPEntity | ForEach-Object {
        if($_.Name -match '\((COM\d+)\)$') {
            [pscustomobject]@{Port=$Matches[1];PnpDeviceId=[string]$_.PNPDeviceID;Status=[string]$_.Status}
        }
    })
}
function Get-ProductSnapshot {
    [pscustomobject]@{
        Devices=@(Get-ProductDevices)
        Nics=@(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceIndex,InterfaceAlias,IPAddress,PrefixLength)
        Routes=@(Get-NetRoute -AddressFamily IPv4 | Select-Object InterfaceIndex,DestinationPrefix,NextHop)
        Udp=@(Get-NetUDPEndpoint -LocalPort 50001 -ErrorAction SilentlyContinue | Select-Object LocalAddress,LocalPort,OwningProcess)
        Conflicts=@(Get-Process | Where-Object {$_.ProcessName -match '^(arduino|arduino-cli|python|pythonw|putty|ttermpro|wireshark|dumpcap|pktmon)$'} | Select-Object Id,ProcessName)
    }
}
function Resolve-ProductWorkspacePath([string]$Path,[string]$Workspace) {
    $resolved=[IO.Path]::GetFullPath($Path)
    $prefix=[IO.Path]::GetFullPath($Workspace).TrimEnd('\')+'\'
    if(!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Path must stay inside workspace'}
    $resolved
}
