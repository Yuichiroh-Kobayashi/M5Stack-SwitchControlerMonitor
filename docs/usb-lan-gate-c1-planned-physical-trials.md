# Gate C1 Planned Physical Trials

STATUS: PLAN ONLY / NOT RUN
SCOPE_RESULT: NOT_CAPTURED

## Fixed hardware

Receiver（Gate C1では使用しない）:

```text
CoreS3 SE + LAN Module + BAT Bottom
COM3: NO ACCESS
```

Sender:

```text
CoreS3 SE + USB Module v1.2 + HORI PAD TURBO 0F0D/0202 Switch 2
+ LAN Module 13.2 + BAT Bottom
COM4: future Sender upload only
```

開始条件:

- PC Ethernet interfaceが同じswitching hubへ物理接続済み。
- Exact COM4 PNPDeviceIDをread-onlyで取得し記録。
- Actual PC Ethernet IPv4を記録し、Senderと同一subnetのlocal Up interfaceであることを確認。
- Sender IPを入力。
- Physical Receiver IPをnegative safety check専用に入力。送信先として使用しない。
- reviewed source manifestが全一致。
- C1 packet destinationはPC peerだけ。COM3へアクセスしない。

## C1-S1: 10 seconds only

実行時に山括弧4項目を実値へ置換する。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\tools\usb_lan_gate_c1_runner.ps1 `
  -RunPhysicalTrial -Trial C1-S1 `
  -AllowUpload -AllowSerial -AllowPeer -AllowNetworkTrial `
  -ComPort COM4 `
  -ExpectedPnpDeviceId "<EXACT_COM4_PNPDeviceID>" `
  -PeerIp "<ACTUAL_PC_ETHERNET_IPV4>" `
  -SenderIp "<SENDER_IPV4>" `
  -ReceiverIp "<PHYSICAL_RECEIVER_IPV4_NEGATIVE_CHECK_ONLY>"
```

## C1-T1: 60 seconds after C1-S1 external review only

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\tools\usb_lan_gate_c1_runner.ps1 `
  -RunPhysicalTrial -Trial C1-T1 `
  -AllowUpload -AllowSerial -AllowPeer -AllowNetworkTrial `
  -ComPort COM4 `
  -ExpectedPnpDeviceId "<EXACT_COM4_PNPDeviceID>" `
  -PeerIp "<ACTUAL_PC_ETHERNET_IPV4>" `
  -SenderIp "<SENDER_IPV4>" `
  -ReceiverIp "<PHYSICAL_RECEIVER_IPV4_NEGATIVE_CHECK_ONLY>"
```

## Stop conditions

- reviewed source hash mismatch
- COM4 pre-upload PNP mismatch
- upload後15秒以内に同一PNPDeviceIDが再列挙しない
- 再列挙先がCOM3、identity ambiguity、serial open retry exhaustion
- Peerがlocal Up Ethernet interfaceでない、subnet不一致、multicast/broadcast、Sender/Receiver IP一致
- Firmware、Serial parser、Peer、Cross-reconciliationのいずれかがFail
- reset、PANIC、WDT、BROWNOUT、USB detach、HID stall、PHY/VERSIONR/buffer-map異常

## Expected logs

- `REVIEWED_SOURCE_IDENTITY=PASS` before and after fresh build
- `PEER_PROCESS_STARTED=1`, `PEER_PID`, `PEER_READY=1`
- COM reenumeration and serial parameters including DTR/RTS 0
- Firmware terminal summary and scope terminal result
- `PEER_STOP_REQUESTED=1`, `PEER_EXIT_CODE=0`, `PEER_SUMMARY_CAPTURED=1`
- `SERIAL_CONTRACT=PASS`, `PEER_CONTRACT=PASS`, `C1_PACKET_RECONCILIATION=PASS`
- all four layers Pass followed by `C1_S1_RESULT=PASS`
