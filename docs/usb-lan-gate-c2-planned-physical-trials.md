# Gate C2 Planned Physical Trials

STATUS: PLAN ONLY / NOT RUN
SCOPE_RESULT: NOT_CAPTURED

This document is a physical-execution plan only. No upload, serial open,
peer network bind, or packet transmission has been performed by the task
that authored this document. See docs/usb-lan-gate-c2-contract.md for the
canonical requirements each step below implements.

## Fixed hardware

Receiver（Gate C2では使用しない）:

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
- C2 packet destinationはPC peerだけ。COM3へアクセスしない。
- Peerはtrial root配下の`peer.arm`/`peer.armed`が両方とも起動時点で不存在であることを確認してから`BOUND_NOT_ARMED`で待機する。

Runnerの物理orchestration順序（docs/usb-lan-gate-c2-contract.mdが権威）:

```text
1. peer start
2. peer is BOUND_NOT_ARMED
3. PEER_READY観測
4. reviewed source identity PASS（pre-build）
   -> REVIEWED_SOURCE_IDENTITY_PHASE=PRE_BUILD PASS=1
5. fresh build (arduino-cli compile)
6. reviewed source identity PASS（post-build。buildで
   source/dependencyが変化していればここでBLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCHとしてupload前に停止）
   -> REVIEWED_SOURCE_IDENTITY_PHASE=POST_BUILD PASS=1
7. pre-upload COM4 exact-PNP identity確認
8. peer process生存確認（buildの間にpeerが終了していればBLOCKED_PEER_PROCESS_NOT_RUNNING_PRE_UPLOADで
   upload前に停止）
9. upload
10. UPLOAD_PASS
11. arm-file作成
12. armed-file + PEER_ARMED=1確認（budget 10秒、超過はORCHESTRATION_STALL/TIMEOUT）
13. serial capture / trial evidence収集
```

arm-before-uploadは禁止する。armはUPLOAD_PASS確認後にのみ行う。exact firmwareがdeviceに書き込まれたことを確認してから、初めてpeerにtraffic受理を許可するためである。

## C2-S1: 10 seconds + condition-driven drain (external result budget: total 40s from serial-capture/result wait start, not additional)

実行時に山括弧4項目を実値へ置換する。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\tools\usb_lan_gate_c2_runner.ps1 `
  -RunPhysicalTrial -Trial C2-S1 `
  -AllowUpload -AllowSerial -AllowPeer -AllowNetworkTrial `
  -ComPort COM4 `
  -ExpectedPnpDeviceId "<EXACT_COM4_PNPDeviceID>" `
  -PeerIp "<ACTUAL_PC_ETHERNET_IPV4>" `
  -SenderIp "<SENDER_IPV4>" `
  -ReceiverIp "<PHYSICAL_RECEIVER_IPV4_NEGATIVE_CHECK_ONLY>"
```

C2-S1完了後、external reviewを経てからのみC2-T1へ進む。automatic progressionは行わない。

## C2-T1: 60 seconds + condition-driven drain (external result budget: total 90s from serial-capture/result wait start, not additional), C2-S1 external review後のみ

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  .\tools\usb_lan_gate_c2_runner.ps1 `
  -RunPhysicalTrial -Trial C2-T1 `
  -AllowUpload -AllowSerial -AllowPeer -AllowNetworkTrial `
  -ComPort COM4 `
  -ExpectedPnpDeviceId "<EXACT_COM4_PNPDeviceID>" `
  -PeerIp "<ACTUAL_PC_ETHERNET_IPV4>" `
  -SenderIp "<SENDER_IPV4>" `
  -ReceiverIp "<PHYSICAL_RECEIVER_IPV4_NEGATIVE_CHECK_ONLY>"
```

## Stop conditions

- reviewed source hash mismatch, at either the pre-build or post-build
  identity gate（`BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH`）。post-build
  gateはupload実行より前に完了させ、build中にsource/dependencyが変化した
  場合はuploadへ進まない。
- build完了後、upload前にpeer processが既に終了している
  （`BLOCKED_PEER_PROCESS_NOT_RUNNING_PRE_UPLOAD`）
- COM4 pre-upload PNP mismatch
- upload後15秒以内に同一PNPDeviceIDが再列挙しない
- 再列挙先がCOM3、identity ambiguity、serial open retry exhaustion
- Peerがlocal Up Ethernet interfaceでない、subnet不一致、multicast/broadcast、Sender/Receiver IP一致
- arm前にpeer.arm/peer.armedが既に存在する（PRECONDITION_ARM_STATE_INVALID）
- arm-file送出後、armed-fileと`PEER_ARMED=1`がarm handshake budget（10秒）以内に確認できない
  （`ORCHESTRATION_STALL/TIMEOUT purpose=peer_arm_handshake`として分類し、C2 network FAILとは区別する）
- arm後、最初の完全valid C2 frameがsequence 0でない
  （`BLOCKED_ADMISSION_SEQUENCE_MISS`として分類し、C2 network FAILとは区別し、automatic retryしない）
- ECHO_LATE_AT_OR_AFTER_WATCHDOG、OUTSTANDING_TABLE_OVERFLOW、OUTSTANDING_FINAL、SCHEDULER_MISSED_DEADLINEのいずれかが非ゼロ
- UDP_RX_INVALID、またはECHO_MAGIC_ERROR/ECHO_VERSION_ERROR/ECHO_GATE_ERROR/ECHO_LENGTH_ERROR/
  ECHO_CRC_ERROR/ECHO_PAYLOAD_ERROR/ECHO_FLAGS_ERROR/ECHO_SOURCE_IP_ERROR/ECHO_SOURCE_PORT_ERROR/
  ECHO_UNMATCHED/ECHO_TIMESTAMP_MISMATCHのいずれかが非ゼロ
- RTT_BUCKET_SUM_OK=0（8 bucket合計とUDP_ECHO_VALID_TOTALの不一致）
- 四者間reconciliationのexact equality不一致（device UDP_TX_TOTAL / peer VALID_RX_TOTAL_POST_ADMISSION /
  peer ECHO_SENT_TOTAL / device UDP_ECHO_VALID_TOTALのいずれかが1frameでも不一致。tail toleranceは存在しない）
- peer ECHO_SENT_TOTAL > peer VALID_RX_TOTAL_POST_ADMISSION（peer側のdouble consume）
- Firmware、Serial parser、Peer、Cross-reconciliationのいずれかがFail
- reset、PANIC、WDT、BROWNOUT、USB detach、HID stall、PHY/VERSIONR/buffer-map異常
- 外部result timeout（C2-S1=40秒、C2-T1=90秒）超過
  （`ORCHESTRATION_STALL/TIMEOUT`として分類し、Firmware/Peer FAILとは区別する）

## Expected logs

- `PEER_PROCESS_STARTED=1`, `PEER_PID`, `PEER_STATE=BOUND_NOT_ARMED`, `PEER_READY=1`
- `REVIEWED_SOURCE_IDENTITY_PHASE=PRE_BUILD PASS=1` (after PEER_READY=1, before build)
- `BUILD_ONLY_PASS=1` (fresh build occurs after the pre-build identity gate, before upload)
- `REVIEWED_SOURCE_IDENTITY_PHASE=POST_BUILD PASS=1` (after build, before upload)
- `UPLOAD_PASS=1 PORT=COM4` (arm is requested only after this line)
- `C2_ARM_REQUESTED=1`, `C2_ARMED_ACKNOWLEDGED=1`
- COM reenumeration and serial parameters including DTR/RTS 0
- `C2_ACTIVE_COMPLETE=1 ACTIVE_RUNTIME_MS=... OUTSTANDING_AT_DRAIN_START=...`
  at the ACTIVE->DRAIN transition
- Firmware terminal summary including `UDP_ECHO_VALID_TOTAL`,
  `ECHO_LATE_AT_OR_AFTER_WATCHDOG=0`, `OUTSTANDING_TABLE_OVERFLOW=0`,
  `OUTSTANDING_FINAL=0`, `UDP_RX_INVALID=0`, all `ECHO_*_ERROR=0`/`ECHO_UNMATCHED=0`/
  `ECHO_TIMESTAMP_MISMATCH=0`, `SCHEDULER_MISSED_DEADLINE=0`, `RTT_BUCKET_SUM_OK=1`,
  `ACTIVE_RUNTIME_MS`, `DRAIN_RUNTIME_MS`, and scope terminal result
- `PEER_STOP_REQUESTED=1`, `PEER_EXIT_CODE=0`, `PEER_SUMMARY_CAPTURED=1`
- Peer summary including `PEER_ARMED=1`, `ADMISSION_SEQUENCE_ZERO_OK=1`,
  `BOUND_NOT_ARMED_PACKET_COUNT`, `PRE_ADMISSION_NON_C2_COUNT` (informational,
  need not be zero), `ECHO_SEND_FAILURES=0`, `UNSOLICITED_ECHO_SENT=0`
- `SERIAL_CONTRACT=PASS`, `PEER_CONTRACT=PASS`, `C2_PACKET_RECONCILIATION=PASS`
- all four layers Pass followed by `C2_TRIAL_RESULT=PASS TRIAL=C2-S1` (or `C2-T1`)
