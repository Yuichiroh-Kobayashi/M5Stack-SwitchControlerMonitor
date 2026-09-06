# Offline synthetic snapshots only. Never queries or opens a COM/network device.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repo 'tools/product_validation/Preflight.ps1')
$script:checks=0
function Reject([scriptblock]$Action){
    $rejected=$false
    try{& $Action}catch{$rejected=$true}
    if(!$rejected){throw 'Expected preflight rejection'}
    $script:checks++
}
$device=[pscustomobject]@{Port='COM99';PnpDeviceId='OFFLINE_TEST';Status='OK'}
Assert-ProductIdentity @($device) 'COM99' 'OFFLINE_TEST';$checks++
Reject {Assert-ProductIdentity @($device) 'COM98' 'OFFLINE_TEST'}
Reject {Assert-ProductIdentity @($device) 'COM99' 'WRONG'}
Reject {Assert-ProductIdentity @($device,$device) 'COM99' 'OFFLINE_TEST'}
$snapshot=[pscustomobject]@{
    Nics=@([pscustomobject]@{IPAddress='192.168.50.30';PrefixLength=24;InterfaceIndex=99})
    Routes=@([pscustomobject]@{DestinationPrefix='192.168.50.0/24';NextHop='0.0.0.0';InterfaceIndex=99})
    Udp=@();Conflicts=@()
}
Assert-ProductNetwork $snapshot;$checks++
$snapshot.Udp=@('occupied');Reject {Assert-ProductNetwork $snapshot};$snapshot.Udp=@()
$snapshot.Conflicts=@('python');Reject {Assert-ProductNetwork $snapshot};$snapshot.Conflicts=@()
$snapshot.Routes+=([pscustomobject]@{DestinationPrefix='0.0.0.0/0';NextHop='192.168.50.1';InterfaceIndex=99})
Reject {Assert-ProductNetwork $snapshot}
Reject {Resolve-ProductWorkspacePath (Split-Path -Parent $repo) $repo}
foreach($file in @('tools/product_build.ps1','tools/product_trial.ps1','tools/product_validation/Preflight.ps1')){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $file),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw "PowerShell parse errors: $file"};$checks++
}
Write-Output "PRODUCT_TRIAL_OFFLINE_PS_PASS checks=$checks"
