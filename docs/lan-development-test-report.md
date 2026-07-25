# CoreS3 SE 有線LAN開発・試験記録

Hardware note:
DualSense was not connected during this run.
HID connection and controller input tests were intentionally skipped.

## 試験コンテキスト

- 実施日: 2026-07-26 (Asia/Tokyo)
- Source HEAD: `9499d41053761d1b3a4450e47954a7d6eff84535`
- Branch: `feat/cores3se-dualsense-lan-stack-diagnostic`
- Working tree: 未コミット差分あり（既存差分を維持したまま試験）
- Board: M5 CoreS3 SE
- Modules: USB Module v1.2、LAN Module 13.2
- USB Module DIP: SS CH2 / INT CH2
- Port: COM8
- Windows: `イーサネット`、`192.168.50.20/24`、DHCP disabled
- Windows接続状態: Connected、AddressState=Preferred
- Firewall: `M5Stack LAN UDP 50000 Test`、enabled、inbound、UDP local port 50000、Allow
- 診断M5 / LANSender: `192.168.50.10/24`
- 最終LANReceiver: `192.168.50.20/24`
- Receiver単体試験時のみ: M5=`192.168.50.10`、Windows sender=`192.168.50.20`

## フェーズ判定

| フェーズ | 判定 | 根拠 |
|---|---|---|
| A: 固定IP診断 | Go | 明示設定後のIP/GW/subnet readback、UDP socket、Linkが全て正常 |
| B: Windows診断UDP受信 | Go | 24バイト`M5DS`を1,556件受信、欠損0、重複0 |
| C: Wireless仕様確定 | Go | TCP/12345/20文字ASCII+LFを事実ベースで抽出 |
| D/E: LANSender | Go（DualSense統合はNot Tested） | Windowsで3,064件受信、全件中立、形式エラー0 |
| F: LANReceiver単体 | Go | 正常262件、意図した異常6件を破棄、timeout/切断時中立化 |
| Sender→第2M5 Receiver統合 | 未実施 | 第2のM5Stackが必要な停止点 |

## 固定IP問題

M5-Ethernet 4.0.0の固定IP版`Ethernet.begin()`は`IPAddress::_address.bytes`を先頭から使用する一方、m5stack:esp32 3.3.7の`IPAddress`はIPv4を`IPADDRESS_V4_BYTES_INDEX=12`から格納する。`Ethernet.setLocalIP()`等は`raw_address()`を使用するため、診断スケッチ側でMAC/IP/gateway/subnet/DNSを明示設定すると正常値を読み戻せた。

実測は`IP_AFTER_BEGIN=0.0.0.0`から、明示設定後に`IP_ACT=192.168.50.10`、`GATEWAY_ACT=192.168.50.1`、`SUBNET_ACT=255.255.255.0`、`LAN_CFG=OK`となった。このため、固定IP版`begin()`と現在の`IPAddress`内部表現の互換性問題が強く支持される。インストール済みライブラリは変更していない。

## フェーズA実測

- 使用バイナリ: `M5Stack-PS5CoRELanStackDiagnostic.ino`、CoreS3 SE、SS/INT CH2
- 開始/終了: 2026-07-26 04:16:50頃 / 04:17:30頃
- `USB_INIT=OK`、`PARSER=OK`、`W5500_INIT=OK`
- `IP_CFG=192.168.50.10`、`IP_AFTER_BEGIN=0.0.0.0`
- `IP_ACT=192.168.50.10`、`GATEWAY_ACT=192.168.50.1`、`SUBNET_ACT=255.255.255.0`
- `EXPLICIT_CFG=OK`、`LAN_CFG=OK`、`UDP_SOCKET=OK`、`LINK=ON`
- 約40秒で`UDP_OK`は0から1,314へ増加、`UDP_FAIL=0`
- `LOOP_PER_SEC` / `USB_TASK_PER_SEC`は概ね87,000、panic/WDT/brownout/意図しないリセットなし
- ログ: `%TEMP%\m5stack-lan-dev\diagnostic-ip-final-20260726-041650.log`

HIDセッション安全化:

- 実装: 完了
- ビルド: 成功
- 静的レビュー: 実施
- DualSense実機確認: 未実施

## フェーズB実測

- 使用バイナリ: フェーズAと同じ診断スケッチ
- 開始/終了: 2026-07-26 04:31:52頃 / 04:32:23頃
- Windows bind: `192.168.50.20:50000/UDP`
- 送信元: `192.168.50.10`
- 受信/妥当: 1,556 / 1,556
- 長さ、magic、version、フィールド異常: 全て0
- sequence欠損0、重複0、逆転1（試験開始時の意図的M5リセット境界）
- Windows受信間隔: 平均20.230ms、p99 32ms
- sender uptime差分: 平均20.233ms、p99 20ms、最大82ms（5秒LCD更新を含む）
- 全受信で`input_valid=0`、buttons=0、dpad=8、4軸=128
- ログ: `%TEMP%\m5stack-lan-dev\diagnostic-udp-verified-20260726-043152.log`

## Wirelessプロトコル流用

製品通信は既存Wirelessと同じTCP port 12345を使用する。Senderがserver、Receiverがclientで、1レコードは20文字ASCII `BB,BB,DD,LX,LY,RX,RY`とLF終端である。各フィールドは2桁16進、byte orderの概念はない。magic/version/sequence/input-validフィールドも既存仕様には存在しない。診断用UDP 24バイト`M5DS`は製品通信へ流用していない。詳細は`docs/lan-protocol-reuse-analysis.md`を参照。

## LANSender実測

- 使用バイナリ: `M5Stack-PS5CoRELANSender.ino`、CoreS3 SE、COM8
- 開始/終了: 2026-07-26 04:51:20頃 / 04:52:25頃（65秒以上）
- Windows TCP client: `192.168.50.20`から`192.168.50.10:12345`へ接続
- 接続2、意図的リセット境界による切断1
- 受信/妥当/異常: 3,064 / 3,064 / 0
- 中立/非中立: 3,064 / 0
- 受信間隔: 平均20.202ms、p99 32ms
- M5側: W5500/LAN_CFG/Link OK、`TX_FAIL=0`、panic/WDT/brownoutなし
- Windowsログ: `%TEMP%\m5stack-lan-dev\lan-sender-rx-20260726-045120.log`
- COM8ログ: `%TEMP%\m5stack-lan-dev\lan-sender-serial-20260726-045120.log`

判定:

- LAN transport: Go
- 固定IP設定: Go
- Wirelessプロトコル互換送信: Go
- 中立時fail-safe: Go
- DualSense入力統合: Not Tested
- 物理LANケーブル抜線/再接続: Not Tested

## LANReceiver単体試験

最終ソースの既定値はReceiver=`192.168.50.20`、Sender=`192.168.50.10`。単体試験時だけコンパイル対象をReceiver=`192.168.50.10`、Windows sender=`192.168.50.20`としてCOM8へ書き込み、試験後にソースを最終値へ復元した。

- 使用バイナリ: 一時IP版`M5Stack-PS5CoRELANReceiver.ino`、CoreS3 SE、COM8
- 最終確認開始/終了: 2026-07-26 05:30:48頃 / 05:31:03頃
- W5500/LAN_CFG/Link: OK/OK/ON
- 正常受信262件
- 意図した異常6件を破棄、overflow 1件を計上
- 100ms受信停止で中立化し、再開後に正常受信
- Windows送信終了/切断後に`INPUT_VALID=0`、`OUTPUT=NEUTRAL`
- 既存仕様にsequenceがないため、重複/逆転/飛びは検出不能で`SEQUENCE=N/A`
- TCP server不在時の`connect()`最大時間: 修正前約1,001ms、50ms設定後51.316ms
- panic/WDT/brownout/意図しないリセットなし
- Windowsログ: `%TEMP%\m5stack-lan-dev\lan-receiver-windows-sender-verified-20260726-053048.log`
- COM8ログ: `%TEMP%\m5stack-lan-dev\lan-receiver-serial-verified-20260726-053048.log`
- 無送信時ログ: `%TEMP%\m5stack-lan-dev\lan-receiver-timeout-20260726-052955.log`

## ビルド結果

| Sketch | Board | Flash | RAM | Build | Upload | Port |
|---|---|---:|---:|---|---|---|
| `M5Stack-PS5CoRELanStackDiagnostic.ino` | cores3se | 553,283 (17%) | 26,264 (8%) | 成功 | 成功 | COM8 |
| `M5Stack-PS5CoRELANSender.ino` | cores3se | 566,591 (18%) | 26,248 (8%) | 成功 | 成功 | COM8 |
| `M5Stack-PS5CoRELANReceiver.ino` 一時試験IP版 | cores3se | 545,027 (17%) | 25,784 (7%) | 成功 | 成功 | COM8 |
| `M5Stack-PS5CoRELANReceiver.ino` 最終IP版 | cores3se | 545,027 (17%) | 25,784 (7%) | 成功 | 未実施（IP競合回避） | - |

最終IP版ReceiverはWindowsのIPと競合するためCOM8へ書き込まない。既存Wireless/その他ボードの回帰ビルドは未実施。`build.ps1`はLAN 3スケッチをCoreS3 SE限定として拒否する。

## 完了・未実施・停止点

完了:

- 固定IP設定
- W5500 readback
- UDP socket
- Windows UDP受信
- LAN transport
- 中立値送信
- Receiver単体試験

未実施:

- DualSense認識
- VID/PID確認
- HID入力
- ボタン／dpad／スティック
- DualSense切断／再接続
- LANSenderの物理LANケーブル抜線／再接続
- 第2M5Stackを使うSender→Receiver統合試験

次の停止点は第2M5Stackが必要な統合試験である。Windows IP、DHCP、Firewall、インストール済みArduino core/libraryは変更していない。commit、push、PRは実施していない。
