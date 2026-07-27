# M5-Ethernet 4.0.1 固定IP互換性試験報告

## 1. 目的

`M5Stack-PS5CoRELanStackDiagnostic.ino`を変更せず、M5-Ethernet 4.0.1の固定IP版`Ethernet.begin()`、明示setter回避策、およびWindowsへの診断UDP送信を実機確認し、既存の4.0.0結果と比較することを目的とした。

## 2. 試験日時

- 実施日: 2026-07-26
- Timezone: Asia/Tokyo
- 結果: 4.0.1がArduino CLI library indexに存在しないため、導入ゲートで停止

## 3. Source HEAD

- Branch: `feat/cores3se-dualsense-lan-stack-diagnostic`
- Source HEAD: `a42c788314aa4e8f328923717a9d3154aee1dc48`
- Checkpoint: `chore: checkpoint before DualSense and two-board LAN integration tests`
- 開始時working tree: clean

## 4. ハードウェア

- M5 CoreS3 SE
- M5Stack USB Module v1.2
- M5Stack LAN Module 13.2
- COM8
- Windows Ethernet: `192.168.50.20/24`
- M5想定IP: `192.168.50.10/24`
- UDP port: 50000
- DualSense: 未接続（今回の正常状態）

## 5. Arduino core

- `m5stack:esp32@3.3.7`
- core更新は実施していない

## 6. M5-Ethernet 4.0.0／4.0.1

### 試験前の4.0.0

- 使用パス: `C:\Users\yu-ichirou\Documents\Arduino\libraries\M5-Ethernet`
- `library.properties`: `version=4.0.0`
- `arduino-cli lib list`: `M5-Ethernet 4.0.0 user`
- 同名ライブラリディレクトリ: 上記1件のみ
- `src\M5_Ethernet.cpp` SHA256: `5F2E94B80A1FCDAB7594870AA377F530A5A49B3400549DADF7860DE1A001261A`
- `src\M5_Ethernet.h` SHA256: `1370C27F9CFA7BF0EFF05F5C534E67BABD089DDB570E069F0088E53674E28A3B`
- `library.properties` SHA256: `3B37881CDC1EA7706306C7F674BCB005A5429DCBAC803AD3C20F2F1355CAE8C1`

指定された`src\Ethernet.h`は4.0.0配布物に存在しない。`library.properties`の`includes=M5_Ethernet.h`と実ファイル配置に従い、主要ヘッダー`src\M5_Ethernet.h`を代わりに記録した。

### 4.0.1導入結果

Arduino CLIの正式手順を確認し、検証済みバックアップ作成後に次を一度だけ実行した。

```text
arduino-cli lib uninstall M5-Ethernet
arduino-cli lib install M5-Ethernet@4.0.1 --no-deps
```

アンインストールは成功したが、4.0.1導入は次のエラーで失敗した。

```text
Error installing M5-Ethernet: Library 'M5-Ethernet@4.0.1' not found
```

続く`arduino-cli lib search M5-Ethernet --format json`の応答は`latest.version=4.0.0`、`available_versions=["4.0.0"]`であり、現在のArduino CLI library indexに4.0.1は登録されていなかった。失敗操作は反復していない。

## 7. 4.0.1ソース確認

4.0.1を正式導入できなかったため未実施。4.0.1のファイル、パス、SHA256、および固定IP版`begin()`／setter実装を推測で評価していない。

参考として、試験前4.0.0の`src\M5_Ethernet.cpp`では次を確認した。

- 固定IP版`begin()`:
  - line 87: `W5100.setIPAddress(ip._address.bytes);`
  - line 88: `W5100.setGatewayIp(gateway._address.bytes);`
  - line 89: `W5100.setSubnetMask(subnet._address.bytes);`
- 明示setter:
  - line 194: `EthernetClass::setLocalIP(...)`
  - line 198: `W5100.setIPAddress(ip.raw_address());`
  - line 202: `EthernetClass::setSubnetMask(...)`
  - line 206: `W5100.setSubnetMask(ip.raw_address());`
  - line 210: `EthernetClass::setGatewayIP(...)`
  - line 214: `W5100.setGatewayIp(ip.raw_address());`

## 8. ビルド結果

4.0.1の使用パスとバージョンを一意に確認できないため、停止条件に従い未実施。

| 項目 | 結果 |
|---|---|
| Board | cores3se（予定） |
| Sketch | `M5Stack-PS5CoRELanStackDiagnostic.ino`（予定） |
| Core | 3.3.7（環境確認済み） |
| M5-Ethernet 4.0.1 build | 未実施 |
| Flash | 未測定 |
| RAM | 未測定 |
| COM8 upload | 未実施 |

## 9. `IP_AFTER_BEGIN`

- 4.0.0既存実測: `0.0.0.0`
- 4.0.1: 未測定

## 10. 明示setter後のreadback

- 4.0.0既存実測:
  - `IP_ACT=192.168.50.10`
  - `GATEWAY_ACT=192.168.50.1`
  - `SUBNET_ACT=255.255.255.0`
  - `EXPLICIT_CFG=OK`
  - `LAN_CFG=OK`
- 4.0.1: 未測定

## 11. UDP受信結果

4.0.1バイナリを生成できなかったため未実施。

4.0.0既存実測は、1,556/1,556件が妥当、欠損0、重複0、Windows受信間隔平均20.230ms、sender uptime差分p99 20ms、全件`input_valid=0`かつ中立値だった。

## 12. 4.0.0との比較

| 項目 | 4.0.0 | 4.0.1 | 差 |
|---|---:|---:|---|
| Build | 成功 | 未実施 | 比較不能 |
| Flash | 553,283 bytes | 未測定 | 比較不能 |
| RAM | 26,264 bytes | 未測定 | 比較不能 |
| IP_AFTER_BEGIN | `0.0.0.0` | 未測定 | 比較不能 |
| IP_ACT | `192.168.50.10` | 未測定 | 比較不能 |
| LAN_CFG | OK | 未測定 | 比較不能 |
| UDP_SOCKET | OK | 未測定 | 比較不能 |
| UDP_FAIL | 0 | 未測定 | 比較不能 |
| 平均受信間隔 | 20.230ms | 未測定 | 比較不能 |
| p99 | sender uptime差分20ms | 未測定 | 比較不能 |
| 最大間隔 | sender uptime差分82ms | 未測定 | 比較不能 |
| reset/panic/WDT | なし | 未測定 | 比較不能 |

## 13. 固定IP互換性判定

**判定不能（No-Go）**。

ケースA/B/Cのいずれにも分類できない。4.0.1を実際に使用できていないため、「問題が再現」「修正済み」「setterも失敗」のいずれも主張しない。

## 14. 公式Issue提出要否

固定IP互換性についてのIssue提出は、4.0.1実体を公式かつ一意な経路で取得し、同じ診断バイナリで実測するまで保留を推奨する。現時点で提出できる確実な事実は「Arduino CLI library indexが4.0.0だけを公開し、`M5-Ethernet@4.0.1`を導入できない」ことに限られる。

Issue本文案（固定IP問題用）は4.0.1実測値を得た後、次を添えて作成する。

```text
Environment:
- M5 CoreS3 SE
- m5stack:esp32 3.3.7
- M5-Ethernet <verified version and SHA256>

Observed:
- IP_AFTER_BEGIN=<measured>
- Explicit setters read back IP/GW/subnet=<measured>
- Windows UDP result=<measured>

Source evidence:
- fixed-IP begin() pointer expression=<verified line>
- setter pointer expression=<verified line>
```

Issue、PR、投稿は実施していない。

## 15. 保存ログ

保存ルート:

`%TEMP%\m5-ethernet-4.0.1-test\logs\`

- `library-switch-4.0.1.log`: 4.0.0アンインストール成功と4.0.1導入失敗

4.0.1のbuild/upload/serial/UDPログは、当該フェーズへ進んでいないため存在しない。4.0.0既存実測ログは`%TEMP%\m5stack-lan-dev\`に保存済み。

## 16. 環境復元結果

4.0.1導入失敗直後、検証済みバックアップを元パスへ復元した。

- `library.properties`: `version=4.0.0`
- `arduino-cli lib list`: `M5-Ethernet 4.0.0 user`
- `M5_Ethernet.cpp` SHA256: 試験前と一致
- `M5_Ethernet.h` SHA256: 試験前と一致
- 他ライブラリ更新: なし
- Arduino core更新: なし
- 一時worktree: 削除・prune済み
- ログと4.0.0バックアップ: `%TEMP%\m5-ethernet-4.0.1-test\`に保持
- M5実機: 4.0.1を書き込んでいないため、書戻し不要

## 17. 未実施事項

- M5-Ethernet 4.0.1ソース確認とSHA256
- 4.0.1診断スケッチbuild
- COM8 upload
- 40秒serial log
- 30秒Windows UDP受信
- 4.0.1の`IP_AFTER_BEGIN`
- 4.0.0対4.0.1実機比較

再試験には、M5-Ethernet 4.0.1の公式配布元（Arduino index登録、公式release archive、または公式tag）を一意に指定する必要がある。

## 最新結論（公式Gitタグ直接試験）

2026-07-27に公式Gitタグ`4.0.1`を隔離Arduino環境へ直接cloneして再試験した。公式タグでも固定IP版`Ethernet.begin()`直後は`IP_AFTER_BEGIN=0.0.0.0`となり、問題を実機再現した。既存の明示setter後はIP、gateway、subnetを正しく読み戻し、Windowsへ診断UDPを継続送信できた。

判定はケースAである。

```text
公式Gitタグ4.0.1でも固定IP版begin()問題を実機再現。
明示setter回避策は必要。
4.0.0と4.0.1の両方で再現。
```

## Arduino Library Manager試験

- 実施日: 2026-07-26
- `arduino-cli lib install M5-Ethernet@4.0.1 --no-deps`はindexに4.0.1が存在せず失敗した。
- indexの`latest.version`および`available_versions`は4.0.0だけだった。
- 後述する公式タグ`4.0.1`の`library.properties`も`version=4.0.0`のため、Library Managerでは4.0.1として識別・指定できない。
- この試験のNo-Go経緯、エラー、復元結果は本書の前半に記録したとおりで、削除していない。

## 公式Gitタグ直接試験

### 試験識別情報

- 実施日: 2026-07-27 (Asia/Tokyo)
- Source HEAD: `a42c788314aa4e8f328923717a9d3154aee1dc48`
- Main repository: `Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender`
- Sketch: `M5Stack-PS5CoRELanStackDiagnostic.ino`（変更なし）
- Board / port: M5 CoreS3 SE / COM8
- Core: `m5stack:esp32@3.3.7`
- Windows / M5: `192.168.50.20/24` / `192.168.50.10/24`
- UDP port: 50000
- DualSense: 未接続（HID入力試験対象外）

### 隔離環境

- Test root: `%TEMP%\m5-ethernet-4.0.1-direct-tag-test`
- Arduino libraries: `%TEMP%\m5-ethernet-4.0.1-direct-tag-test\Arduino\libraries`
- M5Unified: グローバルから141ファイルを隔離コピーし、元・先の件数一致
- USB Host Shield Library 2.0: グローバルから185ファイルを隔離コピーし、元・先の件数一致
- メイン`build.ps1`は変更せず、一時worktreeだけに`--verbose`を追加
- 一時worktreeだけに隔離`ArduinoDir`を指す`config.json`を作成

### 公式タグの同一性

```text
Remote: https://github.com/m5stack/M5-Ethernet.git
Exact tag: 4.0.1
Commit: 6099288546ca9f009bd7bd8d844ca3979c71ebf5
Git status: clean
Manifest: version=4.0.0
M5_Ethernet.cpp SHA256: 95D80F65816FCFED5EACC44646EEFACA63E8F5B1DCC6D07EFED3E649A30B9A77
M5_Ethernet.h SHA256: 3FCB06729057A9E38C93C0ABFFF991C01DFAD964CF846B5F45773E804B046534
```

判定:

```text
Official Git tag: 4.0.1
Manifest version: 4.0.0
Static begin address API: _address.bytes
Explicit setter address API: raw_address()
```

### 静的ソース確認

公式タグ`4.0.1`の`src/M5_Ethernet.cpp`で確認した。

- line 87: `W5100.setIPAddress(ip._address.bytes);`
- line 88: `W5100.setGatewayIp(gateway._address.bytes);`
- line 89: `W5100.setSubnetMask(subnet._address.bytes);`
- line 194: `EthernetClass::setLocalIP(...)`
- line 198: `W5100.setIPAddress(ip.raw_address());`
- line 202: `EthernetClass::setSubnetMask(...)`
- line 206: `W5100.setSubnetMask(ip.raw_address());`
- line 210: `EthernetClass::setGatewayIP(...)`
- line 214: `W5100.setGatewayIp(ip.raw_address());`

### ビルドと使用パス

- Build: 成功
- Flash: 553,355 bytes (17%)
- RAM: 26,264 bytes (8%)
- Upload: COM8へ成功
- Target identity: ESP32-S3 QFN56 revision v0.2、MAC `10:51:db:3d:ef:68`
- 使用M5-Ethernet:
  `%TEMP%\m5-ethernet-4.0.1-direct-tag-test\Arduino\libraries\M5-Ethernet`
- verboseログではグローバル`Documents\Arduino\libraries\M5-Ethernet`を明示的に「未使用」と表示した。
- Arduino CLI上の表示バージョンはmanifestに従い4.0.0だが、使用パス、exact tag、commit、SHA256で公式タグ4.0.1ソースと確定した。

### シリアル実測

起動から45秒取得した。

```text
USB_INIT=OK
PARSER=OK
W5500_INIT=OK
IP_CFG=192.168.50.10
IP_AFTER_BEGIN=0.0.0.0
IP_ACT=192.168.50.10
GATEWAY_ACT=192.168.50.1
SUBNET_ACT=255.255.255.0
EXPLICIT_CFG=OK
LAN_CFG=OK
UDP_SOCKET=OK
LINK=ON（起動直後OFFから約2.5秒でON）
UDP_FAIL=0
RESET=USB
HID_READY=0
DS=DISCONNECTED
INPUT_VALID=0
```

45秒ログ内で`UDP_OK`は0から2,042まで増加した。定常時の`LOOP_PER_SEC`と`USB_TASK_PER_SEC`は概ね127,800、5秒画面更新を含む秒は概ね117,700だった。panic、WDT、brownout、反復再起動はなかった。

### Windows UDP受信結果

- Duration: 35秒
- Source: `192.168.50.10:50000`
- Destination: `192.168.50.20:50000`
- Received / valid: 1,730 / 1,730
- Length: 全件24 bytes
- magic/version異常: 0 / 0
- sequence欠損 / 重複 / 逆転: 0 / 0 / 0
- Windows受信間隔: 平均20.234ms、p99 32ms、最大93ms
- sender uptime差分: 平均20.243ms、p99 20ms、最大80ms
- 全件: `input_valid=0`、buttons=0、dpad=8、4軸=128

### 4.0.0との比較

| 項目 | 4.0.0 | 公式タグ4.0.1 | 差 |
|---|---:|---:|---|
| Build | 成功 | 成功 | なし |
| Flash | 553,283 bytes | 553,355 bytes | +72 bytes |
| RAM | 26,264 bytes | 26,264 bytes | なし |
| IP_AFTER_BEGIN | `0.0.0.0` | `0.0.0.0` | なし |
| IP_ACT | `192.168.50.10` | `192.168.50.10` | なし |
| gateway/subnet | 正常 | 正常 | なし |
| LAN_CFG | OK | OK | なし |
| UDP_SOCKET | OK | OK | なし |
| UDP_FAIL | 0 | 0 | なし |
| UDP受信件数 | 1,556 | 1,730 | 試験時間差 |
| 平均受信間隔 | 20.230ms | 20.234ms | +0.004ms |
| p99 | 32ms | 32ms | なし |
| 最大受信間隔 | 93ms | 93ms | なし |
| sender uptime最大 | 82ms | 80ms | -2ms |
| reset/panic/WDT | なし | なし | なし |

### 公式側フィードバック候補

Issue A — Static IP begin() uses IPAddress internal storage directly:

- 公式タグ4.0.1でも固定IP版`begin()`は`_address.bytes`を使用する。
- m5stack:esp32 3.3.7 / CoreS3 SE実機で`IP_AFTER_BEGIN=0.0.0.0`を再現した。
- `raw_address()`を使う明示setter後はIP/GW/subnetが正常になりUDP送信できた。
- 4.0.0と公式タグ4.0.1の両方で同じ実測結果であり、Issue提出を推奨する。

Issue B — Release/tag 4.0.1 still declares version=4.0.0:

- exact tagは4.0.1だが`library.properties`は`version=4.0.0`のまま。
- Arduino Library Manager indexには4.0.0しかなく、`M5-Ethernet@4.0.1`として導入できない。
- release metadata修正またはLibrary Manager登録手順の確認を求めるIssue提出を推奨する。

Issue、commit、push、PRは実施していない。

### 保存ログ

`%TEMP%\m5-ethernet-4.0.1-direct-tag-test\logs\`

- `build-official-tag-4.0.1.log`
- `upload-official-tag-4.0.1.log`
- `serial-official-tag-4.0.1.log`
- `udp-official-tag-4.0.1.log`
- `restore-global-4.0.0-upload.log`
- `serial-restored-global-4.0.0.log`

### 4.0.0実機復元

メインのグローバル4.0.0環境から再ビルドし、COM8へ書き戻した。

- Flash: 553,283 bytes
- RAM: 26,264 bytes
- Upload: 成功
- `W5500_INIT=OK`
- `LAN_CFG=OK`
- `UDP_SOCKET=OK`
- Linkは起動後ON
- `UDP_FAIL=0`

グローバルM5-Ethernetは試験中変更しておらず、復元前後とも`version=4.0.0`、`M5_Ethernet.cpp` SHA256=`5F2E94B80A1FCDAB7594870AA377F530A5A49B3400549DADF7860DE1A001261A`である。
