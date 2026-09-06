# USB-LAN Fixed10Half Gate C1 Implementation and Test Plan

STATUS: IMPLEMENTED / OFFLINE VALIDATED
GATE C1 HARDWARE TEST: NOT RUN
GATE C2-C4: NOT IMPLEMENTED
SCOPE_RESULT: NOT_CAPTURED

## Scope

Gate C1は、SenderのW5500をFixed10Halfへ固定し、HORI PAD TURBO `0F0D/0202`をUSB Hostで維持しながら、C1専用32-byte UDP frameを20 ms nominal cadenceでPC Python peerだけへ送信する試験である。physical ReceiverはGate C1で使用せず、`ReceiverIp`はPC peerがphysical Receiver IPと一致しないことを確認するnegative safety checkだけに使用する。

この文書はsourceとoffline validationを記録する。upload、COM access、serial capture、実LAN packet送受信、実機試験、オシロ取得は未実施であり、Gate C1 hardware Passを主張しない。

## Existing observations O1 / O2

- O1 Auto100Half: 100 Mbps Half link後にUSB detach再現。
- O2 Fixed10Half: 10 Mbps Half link後60秒Pass。
- Grove 5 V: 両条件で大きな持続的voltage droopは観測されなかった。
- 高周波成分: 両条件でユーザーが観測。
- 比較制約: O1とO2でtimebase／vertical scaleが異なるため定量比較不能。
- 電源／EMI根因: 未確定。

画像だけから電圧値または周波数を推定していない。

## Blocking finding resolution

| Finding | Status | Fix | Evidence |
| --- | --- | --- | --- |
| B-01 | FIXED | build matrixの`DurationSeconds`を5～3600秒へ変更し、Mode 15を10秒／60秒の別caseへ分離。 | `mode15-fixed10-udp-tx-only-10s`および`-60s` build result。 |
| B-02 | FIXED | upload前COM4 exact PNPDeviceID、upload後15秒poll、同一PNPからCOM再解決、COM3除外、115200 8N1/DTR=0/RTS=0有限retry。 | Runner COM reconnect fixtures: immediate、700 ms、5 s、different PNP、no reconnect、COM3 exclusion。 |
| B-03 | FIXED | terminal line、scope marker、final USB/HID、drop/stall/final hardware fieldsと全forbidden markerを関数で厳格判定。 | Serial fixture suite。 |
| B-04 | FIXED | zero/invalid/error/sequence/source/flags/port異常で`PEER_RESULT=FAIL`、exit code 2。 | Peer negative suite。 |
| B-05 | FIXED | Device `UDP_TX_TOTAL/FAIL`とPeer count/first/last/error fieldsをuint32 wrap対応で照合。 | Packet reconciliation fixtures。 |
| B-06 | FIXED | Firmware PassをUDP、HID stall/drop、final USB/HID/PHY/VERSIONR/buffer、MAX register mismatch、SPI corruptionへ拡張。 | Mode 15 sourceと10秒／60秒build。 |
| B-07 | FIXED | 実buildのM5-Ethernet 4.0.0からheader、implementation、UDP、socket、propertiesを固定。 | reviewed source manifestとv2 package。 |
| B-08 | FIXED | Runnerがphysical trial開始前とfresh build後にreviewed source manifestのsize/hashを全検証。 | Runner offline hash match/mismatch fixtures。 |

Non-blocking findings:

- N-01: M5-Ethernet内部blocking loopはlibraryを変更しない。serial/peer/processの有限timeoutとfail-safeで扱う。`udp.endPacket()`自体を外部からpreemptできない残存riskは維持する。
- N-02: Runner/matrixは不存在のtrial ID＋timestamp＋random suffix directoryだけを使用し、既存build directoryを削除・再利用しない。
- N-03: Peerはflags、source IP、source port `50001`を検証する。
- N-04: Peer PID、ready、stop request、exit code、summary flushをrunner logへ明示し、runnerが開始したprocessだけを停止する。

## Mode 15 architecture

`USB_LAN_TEST_MODE=15`は`USB_FIXED10_UDP_TX_ONLY`で、InitOrder 0、PHY profile 2だけを許可する。M5-Ethernet 4.0.0の`MAX_SOCK_NUM=2`と`ETHERNET_LARGE_BUFFERS`をcompile-timeで必須化する。

1. speaker/micを無効化し`M5.begin()`。
2. USB CS GPIO1とLAN CS GPIO13をHIGH、W5500 RESET GPIO0をLOWへ設定。
3. RESET LOWを500 µs以上保持しshared SPI GPIO36/35/37を開始。
4. RESET release後、`Ethernet.init(GPIO13)`、`W5100.init(1)`を直接1回実行。以後external RESETなし。
5. chip 55、VERSIONR `04`、`SSIZE=8192`、`SMASK=8191`、8/8/0... buffer mapをreadback。
6. Mode 14由来helperでFixed10Halfを設定しPHYCFGRをreadback。
7. `Ethernet.begin()`／DHCPを使用せずMAC、local IP、gateway、subnet、DNSを設定・readback。
8. 10 Mbps Half Link ONを500 ms連続確認。10秒でfail-fast。
9. `udp.begin(50001)`後、UDP socketが1個だけであることを確認。
10. PHY、VERSIONR、buffer map再確認後にUSB Hostを初期化。
11. USB state `90`、HID ready、HORI `0F0D/0202`を1000 ms連続確認してtrial開始。
12. 各loop先頭で`Usb.Task()`を実行し、deadline schedulerで1 loop最大1 frameを送信。

## Frame, flags, and source port

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic `C1UD` |
| 4 | 1 | Version `1` |
| 5 | 1 | Gate ID `1` |
| 6 | 1 | Flags |
| 7 | 1 | Frame length `32` |
| 8 | 4 | Sequence, uint32 big-endian |
| 12 | 4 | Device micros, uint32 big-endian |
| 16 | 14 | `((sequence + index * 17 + 0x5A) & 0xFF)` |
| 30 | 2 | CRC16/CCITT-FALSE over bytes 0～29 |

Firmwareのflags式は次のとおり。

- bit 0 `0x01`: `targetHoriRunning()`、すなわちUSB state `90`、HID ready、VID/PID `0F0D/0202`。
- bit 1 `0x02`: Fixed10Half linkがsetupで成立しruntime監視中。
- required flags: `0x03`。
- forbidden flags: `0x00`（個別に定義された禁止feature bitはない）。
- reserved bits: `0xFC`、すべて0必須。

通常runtime frameは常にflags `0x03`でなければならない。`udp.begin(50001)`によりSender source portは`50001`であり、Peerは`EXPECTED_SOURCE_PORT=50001`として検証する。

## HID stall derivation

保存済みHORI HIDUniversalログを根拠とする。Mode 0、Mode 10、Mode 11、Mode 14 Fixed10Halfの正常steady-stateでは`HID_REPORT_DELTA`が概ね毎秒200、すなわち約5 ms/reportだった。正常なMode 14 Fixed10Half 60秒反復と600秒試験でもsteady値は約200 reports/sで、runtime `MAX_USB_GAP_US`は概ね2.4 msだった。

Gate C1のstall thresholdは100 msとする。これは実測report周期約5 msの20倍であり、通常jitterを十分超えながら10秒smoke内でreport停止を検出できる。thresholdは推測値ではなく保存ログの実測rateから導出した。trial開始前のenumeration slow callと初期1000 ms stability windowは`HID_STALL_COUNT`／runtime USB timingから分離する。

Runtimeはreport counterの最終更新からの経過を監視し、100 ms超で`HID_STALL_COUNT`を加算して即Failする。`HID_MAX_NO_REPORT_MS`を必ず出力する。

## Firmware terminal validation

すべてのsetup failureは一度だけ次を出力する。

```text
C1_SETUP_FAIL=1 REASON=<FIXED_TOKEN>
TEST_COMPLETE=FAIL TEST_MODE=15 TEST_MODE_NAME=USB_FIXED10_UDP_TX_ONLY REASON=<FIXED_TOKEN> ...
SCOPE_MARKER trial=C1 event=TRIAL_COMPLETE result=FAIL
```

Trial終了直前にFixed10Half/link、VERSIONR `04`、全buffer map、USB/HID、MAX3421E triple readを再検証する。

Firmware PASS条件:

```text
UDP_TX_TOTAL > 0
UDP_TX_FAIL == 0
HID_STALL_COUNT == 0
HID_READY_DROP == 0
FINAL_USB_STATE == 90
FINAL_HID_READY == 1
FINAL_PHY_OK == 1
FINAL_VERSION_OK == 1
FINAL_BUFFER_MAP_OK == 1
MAX_REGISTER_TRIPLE_READ_MISMATCH == 0
SPI_CORRUPTION_SUSPECTED == 0
TEST_MODE == 15
TEST_MODE_NAME == USB_FIXED10_UDP_TX_ONLY
```

`SCHEDULER_MISSED_DEADLINE`は必ず記録するがC1-S1ではwarning扱いとする。Gate目的はUSB/HIDとUDPの共存およびpacket integrityであり、single missed deadlineを隠さず記録しつつ、Device/Peer完全照合を主判定にするためである。burst catch-upは禁止し、missed periodをskipする。

## Peer PASS contract

Peerは次をすべて満たす場合だけexit code 0と`PEER_RESULT=PASS`を出す。

```text
RX_TOTAL > 0
VALID_RX_TOTAL > 0
FIRST_SEQUENCE == 0
CRC_ERROR == 0
LENGTH_ERROR == 0
FORMAT_ERROR == 0
PAYLOAD_ERROR == 0
UNEXPECTED_SOURCE == 0
SEQ_GAP == 0
DUPLICATE == 0
OUT_OF_ORDER == 0
FLAGS_ERROR == 0
SOURCE_PORT_ERROR == 0
```

異常時は`PEER_RESULT=FAIL`、exit code 2とする。Sequence trackerはuint32 wrapを許容する。

## C1-S1 complete four-layer Pass contract

### Firmware PASS

上記Firmware PASS条件、final hardware canary、`TEST_COMPLETE=PASS`、scope `TRIAL_COMPLETE result=PASS`がすべて成立する。

### Serial parser PASS

Terminal resultが正確に1件、Mode 15/name/final fieldsが全一致し、setup fail、runtime fail、detach、FAIL_FAST、PANIC、WDT、BROWNOUT、buffer/PHY failure markerが1件もない。

### Peer PASS

Peer PASS contractを満たし、exit code 0、summary flush完了。

### Cross-reconciliation PASS

```text
device UDP_TX_FAIL == 0
device UDP_TX_TOTAL > 0
peer VALID_RX_TOTAL == device UDP_TX_TOTAL
peer FIRST_SEQUENCE == 0
peer LAST_SEQUENCE == (device UDP_TX_TOTAL - 1) modulo 2^32
peer error/sequence/source/flags/port counters == 0
```

全4層がPassした場合だけrunnerは`C1_S1_RESULT=PASS`を出力する。

## UDP count rate classification

Packet reconciliationを主判定とする。別途、実際の`TRIAL_RUNTIME_MS`と20 ms nominal periodから`floor(runtime/20)`を算出し、その90%未満を`WARN_UNEXPECTEDLY_LOW`とする。固定500 packetをhard-codeせず、実runtimeを使う。このrate classification単独はPass/Failを決めず、packet lossは厳格なDevice/Peer count照合でFailになる。

## Reviewed source identity and fresh build

Runnerはphysical trial開始前とfresh build直後に`C1-reviewed-source-manifest.csv`を読み、diagnostic、Peer、Runner自身、matrix、M5-Ethernet exact source、UHS critical sourceのsize/SHA-256一致を要求する。不一致は`BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH`。

実機buildは次の新規directoryだけを使用する。

```text
build-temp/usb-lan-isolation/gate-c1/<trial>-<timestamp>-<random>/build-matrix/
```

destinationが存在すれば停止し、削除・再利用しない。

## Physical plan

C1-S1は10秒だけ。C1-T1はC1-S1の外部review後のみ60秒実行する。Exact commandと開始条件は`docs/usb-lan-gate-c1-planned-physical-trials.md`を参照。

## Not verified

- 実UDP送信／PC実interface受信
- runtime 10 Mbps Half link
- USB/HIDとUDP同時動作
- COM4 upload後の実再列挙
- Grove 5 V、高周波成分、EMI、電源根因
- C1-S1／C1-T1 hardware Pass
