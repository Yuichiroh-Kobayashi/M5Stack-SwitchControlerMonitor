[CmdletBinding()]
param(
    [string]$BuildRoot=''
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repoRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$runner=Join-Path $repoRoot 'tools\usb_lan_gate_dg_d_runner.ps1'
$peer=Join-Path $repoRoot 'tools\usb_lan_gate_dg_c_peer.py'
$firmware=Join-Path $repoRoot 'diagnostics\usb-lan-gate-dg-d\M5Stack-PS5CoREUsbLanIsolationDiagnosticDG_D\M5Stack-PS5CoREUsbLanIsolationDiagnosticDG_D.ino'
$buildMatrix=Join-Path $repoRoot 'tools\usb_lan_gate_dg_d_build_matrix.ps1'
$contract=Join-Path $repoRoot 'docs\usb-lan-gate-dg-d-contract.md'
$expectedC1='65529BC8A41374FD113FBB844D20432C030B5FBAF051C5EBAB9624C8F060FABB'
$expectedEthernetUdp='49E726E19E2C14788F53D4761D323419B49107D7867E4810E77A6C420ACD9CAB'
$expectedPeer='0D770B8C02ECCBC382A3F5A484F401A3DF9EF9318701ED0C3A2395EEB66E830A'
$records=[Collections.Generic.List[object]]::new()

function Record([string]$Name,[bool]$Pass){$records.Add([pscustomobject]@{Name=$Name;Pass=$Pass})}
function Sha([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash}
function Resolve-UniqueIdentity([object[]]$Candidates,[string]$ExpectedHash){
    $matches=@($Candidates|Where-Object{(Test-Path -LiteralPath $_)-and (Sha $_)-ceq $ExpectedHash})
    if($matches.Count -ne 1){throw 'BLOCKED_DG_D_AUTHORITY_IDENTITY_UNRESOLVED'}
    $matches[0]
}
function Same-Inventory([object[]]$Pre,[object[]]$Post){
    if($Pre.Count-ne$Post.Count){return $false}
    for($i=0;$i-lt$Pre.Count;$i++){if($Pre[$i].Path-cne$Post[$i].Path-or$Pre[$i].Size-ne$Post[$i].Size-or$Pre[$i].Sha256-cne$Post[$i].Sha256){return $false}}
    $true
}

$c1=Join-Path $repoRoot 'build-temp\usb-lan-isolation\freeze\C1-final-20260818-005403-666bf93b\source\reviewed-files\diagnostic_source\M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino'
$udp=Join-Path $repoRoot 'build-temp\usb-lan-isolation\libraries\M5-Ethernet\src\EthernetUdp.cpp'
Record 'authority_all_identities_match' ((Sha $c1)-ceq$expectedC1 -and (Sha $udp)-ceq$expectedEthernetUdp -and (Sha $peer)-ceq$expectedPeer)
try{Resolve-UniqueIdentity @((Join-Path $repoRoot 'missing-c1.ino')) $expectedC1|Out-Null;Record 'authority_missing_c1' $false}catch{Record 'authority_missing_c1' ($_.Exception.Message-like'*AUTHORITY_IDENTITY_UNRESOLVED*')}
try{Resolve-UniqueIdentity @($udp) $expectedC1|Out-Null;Record 'authority_wrong_c1_sha' $false}catch{Record 'authority_wrong_c1_sha' $true}
try{Resolve-UniqueIdentity @($c1) $expectedEthernetUdp|Out-Null;Record 'authority_wrong_ethernet_sha' $false}catch{Record 'authority_wrong_ethernet_sha' $true}
try{Resolve-UniqueIdentity @($c1,$c1) $expectedC1|Out-Null;Record 'authority_ambiguous_freeze_path' $false}catch{Record 'authority_ambiguous_freeze_path' $true}
try{Resolve-UniqueIdentity @($c1) $expectedPeer|Out-Null;Record 'authority_wrong_dg_c_peer_sha' $false}catch{Record 'authority_wrong_dg_c_peer_sha' $true}
$modeMatches=@(Select-String -LiteralPath $c1 -Pattern '(?i)(TEST_MODE\s*[=:]\s*18\b|Mode\s*18\b|kMode\w*\s*=\s*18\b)')
Record 'authority_mode18_collision_zero' ($modeMatches.Count-eq 0)
$collisionFixture=@(@('TEST_MODE=18')|Select-String -Pattern 'TEST_MODE=18')
Record 'authority_mode18_collision_detected' ($collisionFixture.Count-eq 1)
$pre=@([pscustomobject]@{Path='a';Size=1;Sha256='A'});$post=@([pscustomobject]@{Path='a';Size=1;Sha256='A'});$drift=@([pscustomobject]@{Path='a';Size=2;Sha256='B'})
Record 'pre_post_inventory_equal' (Same-Inventory $pre $post)
Record 'pre_post_inventory_drift' (!(Same-Inventory $pre $drift))

$runnerOutput=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -OfflineSelfTest 2>&1
Record 'runner_offline_suite' ($LASTEXITCODE-eq 0 -and $runnerOutput -match 'OFFLINE_TEST_RESULT=PASS')
$runnerOutputText=$runnerOutput -join "`n"
$requiredB37=@('b37_a_usb_stimulus_1_clean_fail_established','b37_b_usb_stimulus_1_serial_capture_timeout_blocked','b37_c_usb_stimulus_1_peer_graceful_timeout_blocked','b37_d_usb_stimulus_0_normal_blocked','b37_e_usb_stimulus_unknown_normal_blocked','b37_f_raw_orchestration_preserved_not_invented_primary','b37_g_unexpected_control_token_fail_closed_no_causal_fail')
Record 'canonical_b37_cases_executed' (@($requiredB37|Where-Object{!$runnerOutputText.Contains("OFFLINE_TEST name=$_ result=PASS")}).Count -eq 0)
$peerOutput=& python.exe $peer --self-test 2>&1
Record 'exact_peer_fake_socket_suite' ($LASTEXITCODE-eq 0)
$firmwareText=Get-Content -LiteralPath $firmware -Raw
Record 'firmware_explicit_null_overload' ($firmwareText.Contains('udp.read(static_cast<uint8_t*>(nullptr)'))
Record 'firmware_drain_constants' ($firmwareText.Contains('DG_D_DRAIN_QUIET_REQUIRED_MS=100') -and $firmwareText.Contains('DG_D_DRAIN_TIMEOUT_MS=1000'))
$buildText=Get-Content -LiteralPath $buildMatrix -Raw
Record 'build_matrix_compile_only' ($buildText -match '"compile"' -and $buildText -notmatch '(?im)^\s*&\s*arduino-cli\s+upload\b')
$contractText=Get-Content -LiteralPath $contract -Raw
$runnerText=Get-Content -LiteralPath $runner -Raw
Record 'single_authoritative_runner_offline_path' (!$runnerText.Contains('function Invoke-RunnerOfflineSelfTests'))
$peerText=Get-Content -LiteralPath $peer -Raw
$endpointSourceAgreement=(
    $contractText.Contains('device=192.168.50.10:50001') -and $contractText.Contains('peer=192.168.50.30:50001') -and
    $runnerText.Contains("`$senderIp = '192.168.50.10'") -and $runnerText.Contains("`$peerIp = '192.168.50.30'") -and $runnerText.Contains('$peerPort = 50001') -and $runnerText.Contains('$submissionPort = 50001') -and
    $peerText.Contains('EXPECTED_SOURCE = ("192.168.50.10", 50001)') -and $peerText.Contains('REQUIRED_BIND = ("192.168.50.30", 50001)') -and $peerText.Contains('INGRESS_DESTINATION = ("192.168.50.10", 50001)') -and
    $buildText.Contains('[string]$C1PeerIp = "192.168.50.30"') -and $buildText.Contains('BLOCKED_DG_D_REPAIR_ENDPOINT_BUILD_MISMATCH') -and
    $firmwareText.Contains('USB_LAN_C1_PEER_IP_D == 30') -and $firmwareText.Contains('Mode 18 requires DG-D peer 192.168.50.30')
)
Record 'endpoint_cross_file_source_authority_192_168_50_30_50001' $endpointSourceAgreement
Record 'mode18_static_assert_present' ($firmwareText -match '(?s)#if USB_LAN_TEST_MODE == 18.*USB_LAN_C1_PEER_IP_A == 192.*USB_LAN_C1_PEER_IP_B == 168.*USB_LAN_C1_PEER_IP_C == 50.*USB_LAN_C1_PEER_IP_D == 30.*#endif')
Record 'historical_mode15_default_unchanged' ($firmwareText.Contains('#define USB_LAN_C1_PEER_IP_D 254') -and $firmwareText.Contains('USB_LAN_TEST_MODE != 15 || USB_LAN_PHY_PROFILE == 2'))
if(![string]::IsNullOrWhiteSpace($BuildRoot)){
    $resolvedBuildRoot=[IO.Path]::GetFullPath($BuildRoot)
    foreach($stage in @('S1','T1')){
        $log=Join-Path $resolvedBuildRoot "DG-D-$stage\build.log"
        $authorityLog=Join-Path $resolvedBuildRoot "DG-D-$stage\build-authority.txt"
        $compilerText='';$authorityText=''
        if(Test-Path -LiteralPath $log -PathType Leaf){$compilerText=Get-Content -LiteralPath $log -Raw}
        if(Test-Path -LiteralPath $authorityLog -PathType Leaf){$authorityText=Get-Content -LiteralPath $authorityLog -Raw}
        $requiredFlags=@('-DUSB_LAN_C1_PEER_IP_A=192','-DUSB_LAN_C1_PEER_IP_B=168','-DUSB_LAN_C1_PEER_IP_C=50','-DUSB_LAN_C1_PEER_IP_D=30')
        $flagsOk=(@($requiredFlags|Where-Object{!$compilerText.Contains($_)}).Count -eq 0) -and (@($requiredFlags|Where-Object{!$authorityText.Contains($_)}).Count -eq 0) -and !$compilerText.Contains('-DUSB_LAN_C1_PEER_IP_D=254') -and !$authorityText.Contains('-DUSB_LAN_C1_PEER_IP_D=254')
        Record "endpoint_actual_${stage}_compile_flags" $flagsOk
    }
}

$pass=@($records|Where-Object Pass).Count;$fail=$records.Count-$pass
$records|ForEach-Object{Write-Output "DG_D_OFFLINE_FIXTURE name=$($_.Name) result=$(if($_.Pass){'PASS'}else{'FAIL'})"}
Write-Output "DG_D_OFFLINE_FIXTURE_RESULT=$(if($fail-eq 0){'PASS'}else{'FAIL'}) PASS=$pass FAIL=$fail TOTAL=$($records.Count)"
if($fail-ne 0){exit 1}
