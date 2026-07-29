# CoRE有線コントローラ送受信機 開発引継ぎ

作成日: 2026-07-29（JST）

## 1. この文書の目的

長期化したCoreS3 SEコントローラ送受信機の開発・原因調査を次チャットへ引き継ぐ。現在までに、Ethernet双方向通信、固定バイナリプロトコル、USB Host安定性、コントローラ互換性を段階的に検証した。

> [!IMPORTANT]
> HORIはUSB-onlyのgolden referenceだが、製品`M5Stack-PS5CoRELANSender.ino`はまだDualSense専用である。現状の製品SenderへHORIを接続しても`inputValid=false`となり、CONTROLは中立値のままになる。HORIでLAN統合試験を始める前に、Legacy WirelessSenderからHORI profileを移植する必要がある。

次工程では、DualSense調査を製品開発から分離し、安定実績のあるHORI PAD TURBOのprofileを製品Senderへ移植してからLAN Sender／Receiver統合を再開する。

## 2. リポジトリ

- GitHub: `Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender`
- ローカル: `C:\Users\yu-ichirou\Documents\Arduino\M5Stack-SwitchController2CoREWirelessSender`
- 作業ブランチ: `feat/cores3se-dualsense-lan-stack-diagnostic`
- 調査開始時HEAD: `a42c788314aa4e8f328923717a9d3154aee1dc48`
- AI文書作成前baseline HEAD: `28659a24de4bbccd3d0142c4cb053b3399fa8cfd`
- この引継ぎcommit後の状態は、固定された一覧ではなく`git status -sb`と`git log`で確認する。

Git操作方針:

- ユーザーの明示許可なしにcommit、push、pull、merge、rebase、stash、reset、clean、branch変更、PR／Issue作成を行わない。
- transientなworking tree一覧をこの文書の正本にしない。

USB Host調査成果物:

- `M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino`
- `M5Stack-PS5CoREPs5UsbDiagnostic.ino`
- `M5Stack-SwitchController2CoREWirelessSender.ino`の診断instrumentation
- `tools/usb_lan_isolation_test.ps1`
- `docs/cores3se-usb-lan-root-cause-report.md`

製品LAN Sender／Receiver／`src/core_protocol`はUSB原因調査中には機能変更していない。

## 3. 製品目標

CoreS3 SEを使った有線コントローラ送受信機を構築する。

### Sender

- M5 CoreS3 SE
- M5Stack USB Module v1.2（MAX3421E）
- M5Stack LAN Module 13.2（W5500）
- Base M5GO Bottom3
- 有線ゲームコントローラ
- EthernetでReceiverへCONTROL送信
- ReceiverからSTATUS受信
- 画面にcontroller／peer／LAN／battery／counterを表示

### Receiver

- M5 CoreS3 SE
- M5Stack LAN Module 13.2（W5500）
- Base M5GO Bottom3
- CONTROL受信、STATUS返信
- Port C UARTへ同一32byte frameを出力

EthernetはSenderとReceiverをスイッチングハブへ接続する。W5500同士の直接接続ではlinkが成立しなかったが、スイッチングハブ経由で双方向通信は成立した。

## 4. 固定プロトコル

現在のwire formatは凍結扱い。

- UDP port: `50001`
- 固定長: 32 bytes
- bytes 0-1: `C`, `R`
- version: 1
- message type: CONTROL／STATUS
- sequence: big-endian
- uptime: big-endian
- payload: 20 bytes
- bytes 30-31: CRC-16/CCITT-FALSE
- CONTROL: 20 ms、50 Hz
- STATUS: 20 ms、50 Hz
- timeout: 100 ms
- packed struct禁止、明示的byte encode/decode
- Receiver UARTも同一32byte frame、115200 8N1、CRLF／ASCII変換なし

関連ファイル:

- `src/core_protocol/CoreProtocol.h`
- `src/core_protocol/CoreProtocol.cpp`
- Python reference implementation

## 5. CoreS3 SEハードウェア

共有SPI:

| 信号 | GPIO |
|---|---:|
| SCK | 36 |
| MOSI | 37 |
| MISO | 35 |

USB Module v1.2:

| 信号 | GPIO |
|---|---:|
| CS | 1 |
| INT | 14 |

DIPはCoreS3用にSS／INTともCH2。確認済み。

LAN Module 13.2:

| 信号 | GPIO |
|---|---:|
| CS | 13 |
| INT | 10 |
| RESET | 0 |

Receiver UART Port C:

| 信号 | GPIO |
|---|---:|
| TX | 17 |
| RX | 18 |

UARTは115200 8N1。RXは`Serial2.begin()`前に`INPUT_PULLUP`設定。

製品Senderの現在の初期化順序:

1. LAN/W5500初期化
2. USB Host/MAX3421E初期化

USB_FIRST診断ではRUNNING未到達、LAN_FIRST診断ではRUNNING到達の実測がある。ただしLAN_FIRSTでもDualSenseは後にdetachしたため、初期化成立とcontroller安定性を混同しない。HORI profile移植時も根拠なく順序を変更しない。

## 6. ソフトウェアbaseline

- M5Stack ESP32 core: 3.3.7
- M5Unified: 0.2.19
- M5GFX: 0.2.26
- M5-Ethernet: 4.0.0
- USB Host Shield Library 2.0: 1.7.0
- UHSはCoreS3対応patchを隔離ライブラリへ1回適用

隔離UHS hash:

- archive: `3B6D75098AD1BAE0A739C25389373FEFCBBFE2876765295968168FCA05763CAE`
- `avrpins.h`: `EE7B5473CC75E8E92511D4F5C8C0B11046241AEFD0A8B9DAB913F05E8C5A5CEB`
- `UsbCore.h`: `7C63D4FEF96BFAB8253244B49F76B8425DB42DB3D5C2FD9C3E7E6B89F9D5C825`
- `usbhost.h`: `00F9217A5D32691794560A8029D32B610903D2A92837D758E11836058DB98D82`
- `library.properties`: `18EC606EAD123804645DDD928A498280DBD12019DC02CB84469F79DDCA0CDA63`

M5-Ethernet 4.0.0ではstatic beginだけでは`0.0.0.0`になる挙動があり、明示的setterでIPを設定することで正常化した。4.0.1へは移行しない。

## 7. Ethernet実装進捗

送受信プロトコル、50 Hz schedule、CRC、sequence、timeout、UI統一を実装済み。

スイッチングハブ導入後:

- Sender TX増加
- Receiver RX／SEQ増加
- AGE約18 ms
- CONTROL 50 Hz
- STATUS 50 Hz
- CRC fail 0
- sequence gap 0
- timeout 0
- Link ON

USB問題が発生してもEthernet通信は継続していたため、当初の「画面全体freeze」ではなくUSB Host側controller detachであることを切り分けた。

## 8. USB Host原因調査の経緯

### 8.1 当初現象

DualSenseは接続後しばらく入力が更新されるが、その後controller表示が停止した。

診断により:

```text
USB state: 0x90 -> 0x12
HID_READY: 1 -> 0
VID/PID: 054C/0CE6 -> 0000/0000
```

となる実detachであることを確認。

### 8.2 除外した原因

次を除外または優先度低下させた。

- UDP送受信負荷
- CONTROL／STATUS 50 Hz schedule
- W5500周期アクセス
- LAN Moduleの物理的存在
- LCD描画
- USB service gap
- MAX3421E revision読取り破損
- PS5USB標準LED OUT report
- 独自parserだけの問題
- enumeration時の約300～700 ms slow `Usb.Task()`単独

### 8.3 DualSense結果

DualSense A/Bとも不安定。

代表結果:

- HIDUniversal、LANなし: 1.107秒でdetach
- PS5USB NO_OUTPUT: 625～1,031 msで全試験Fail
- PS5USB DEFAULT: 690～976 msで全試験Fail
- 全条件で`0x90 -> 0x12`
- MAX3421E revision `13/13/13`
- reset、panic、WDTなし

結論:

- 現行CoreS3 SE + USB Module v1.2 + UHS 1.7.0構成でDualSenseは非対応／調査保留。
- 自動`Usb.Init()`、MAX3421E reset、`ESP.restart()`による隠蔽は行わない。

## 9. HORI PAD baseline

HORI PAD TURBO:

- VID/PID: `0F0D/0202`
- 本体切替: `Switch 2`

試験結果:

- WirelessSender 60秒 x 3: 全Pass
- reports: 5,924／5,930／5,930
- WirelessSender 600秒: 59,931 reports、Pass
- HIDUniversal Mode 0 600秒: 119,865 reports、Pass
- `HID_READY_DROP=0`
- SPI mismatch 0
- state `0x90`維持

合計22分以上安定。HORIはUSB-validated development baselineである。ただし製品SenderのHORI profileは未実装であり、product-supported controllerは現在存在しない。

## 10. Powered USB hub結果

対象:

- UGREEN powered hub
- Amazon ASIN `B09DCK46PM`

Windowsでは同一hub経由でDualSenseを正常認識した。

CoreS3/MAX3421E/UHSでは、対照用HORIすら下流HIDとしてenumerationできなかった。

- `Usb.Init=OK`
- MAX3421E revision `13/13/13`
- state `0x51 -> 0x90`
- target readyにならない
- RUNNING後の次回`Usb.Task()`が戻らない

結論:

- このhubはCoreS3/MAX3421E/UHS構成のpower isolation試験や製品回避策に使用できない。
- DualSenseの電源問題は未確定だが、製品完成条件から外す。

## 11. 新規コントローラ候補

選定担当者が次の有線PS4互換controllerを選定。

- OULEKE
- Amazon ASIN `B0FL6VS3JF`
- 現物未着

到着後に確認する項目:

1. Windows接続前後のPnP差分
2. VID/PID
3. composite device／interface構成
4. HID report descriptorとhash
5. report ID／length／rate
6. D-pad、button、stick、trigger mapping
7. neutral値、axis方向
8. macro／turbo／背面button
9. USB-only 60秒 x 3
10. USB-only 600秒
11. 抜線時100 ms以内neutral化
12. resetなし再接続
13. 可能なら3個体、各60分

現物評価完了前に製品firmwareへOULEKE専用mappingを追加しない。

## 12. AI向けドキュメント方針

QUESTiX PR #49の設計を参考に、共通情報をroot `AGENTS.md`へ集約し、各toolは薄いadapterとする。

提案構成:

```text
AGENTS.md
CLAUDE.md
GEMINI.md
.github/copilot-instructions.md
docs/ai/README.md
docs/ai/hardware-baseline.md
docs/ai/protocol-and-safety.md
docs/ai/controller-compatibility.md
docs/ai/validation-gates.md
```

対象:

- Codex: `AGENTS.md`
- Claude Code: `CLAUDE.md`から`@AGENTS.md`
- Antigravity 2.0: `GEMINI.md`から`@AGENTS.md`
- GitHub Copilot: `.github/copilot-instructions.md`を軽量adapterとし、`AGENTS.md`を正本と明記

規範は`AGENTS.md`、詳細な実測記録は`docs/ai/`と既存root-cause reportへ置く。

## 13. 次工程

### Phase A: AI向け文書をレビュー・導入

1. 下書きの内容を現リポジトリと照合
2. 既存README／docsとの重複と矛盾を確認
3. docs-only変更としてbuild不要範囲を定義
4. `git diff --check`
5. commit／PRはユーザー許可後

### Phase B1: HORI product profile implementation

1. Legacy WirelessSenderのHORI parserを確認
2. 製品SenderのDualSense固有箇所を分離
3. controller profile abstractionを追加
4. VID/PID `0F0D/0202`でHORI profileを選択
5. unsupported controllerをneutral化
6. USB-onlyでmappingを確認
7. build・静的確認

### Phase B2: HORI LAN integration

1. LAN Moduleを戻す
2. Receiver／Sender build・upload
3. 60秒双方向試験
4. manual mapping確認
5. 10分統合試験
6. controller／LAN disconnect・reconnect
7. 60分耐久

### 60秒合格条件

- HORI `0F0D/0202`
- HID ready継続
- CONTROL 45～55 Hz
- STATUS 45～55 Hz
- CRC fail 0
- sequence gap 0
- timeout 0
- reset 0

### 手動試験

- D-pad 8方向
- 左右stick全方向
- 全button
- trigger
- 30秒連続操作
- Sender／Receiver表示一致
- release後neutral

### 障害試験

Controller抜線:

- 100 ms以内にneutral化
- stale inputなし
- 再接続後resetなし復旧

LAN抜線:

- HORI UI／HID継続
- peer timeout表示
- 再接続後双方向復旧

### 60分耐久

- HID drop 0
- Link drop 0
- reset 0
- CRC fail 0
- sequence gap 0
- unexpected timeout 0

## 14. 次チャットで最初に確認すること

```powershell
cd C:\Users\yu-ichirou\Documents\Arduino\M5Stack-SwitchController2CoREWirelessSender

git status -sb
git diff --stat
git diff --check
git rev-parse HEAD
git rev-parse origin/feat/cores3se-dualsense-lan-stack-diagnostic
```

その後、AI向けMD下書きと現在のローカル実装を照合する。未コミット変更を破棄しない。

製品実機試験へ移る前に、現在COM4へ書き込まれている診断firmwareと物理stack状態を確認する。
