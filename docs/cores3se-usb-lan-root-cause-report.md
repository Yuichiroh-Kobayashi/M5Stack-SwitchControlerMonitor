# CoreS3 SE USB Host切断 段階的原因分離レポート

## 1. 結論

CoreS3 SE + USB Module v1.2 + DualSenseの`0x90 -> 0x12`は、W5500初期化、W5500周期アクセス、UDP、LCD描画のすべてを除外したMode 0でも3.521秒で再現した。したがって、本実測ではW5500／LCD共有SPI競合は現象発生の必要条件ではない。

MAX3421Eの`rREVISION`と`rHRSL`のtriple-read不一致は全条件で0、Mode 4/5のW5500 Link poll前後でもrevision変化は0だった。この診断で共有SPI read破損を示す証拠は得られていない。ただし、読取り値が一致したことだけで全種類のSPI競合を完全否定はできない。

Mode 0がFailしたため、次の優先調査はDualSense／USBケーブル、USB VBUS・電源経路、またはUSB Host Shield Library 1.7.0 CoreS3対応である。software logだけではこの3候補を分離できない。自動再初期化、MAX3421E reset、ESP restart、watchdog復旧は追加していない。

## 2. 0x90 -> 0x12の解釈

- `0x90`: USB Host Shield Libraryの`USB_STATE_RUNNING`
- `0x12`: `USB_DETACHED_SUBSTATE_WAIT_FOR_DEVICE`
- 実測ではHID_READYが1から0へ落ち、VID/PIDが`054C/0CE6`から`0000/0000`へ戻り、HID reportが停止した。
- これはlibraryがdevice detached待機状態へ戻ったことを示すが、VBUS瞬低、実ケーブル切断、controller側切断、library誤判定のどれかはsoftware stateだけでは確定できない。

## 3. 調査条件

- Repository HEAD: `a42c788314aa4e8f328923717a9d3154aee1dc48`
- 対象: CoreS3 SE + USB Module v1.2 + LAN Module + DualSense
- upload対象: Sender `COM4`のみ
- PnP instance: `USB\VID_303A&PID_1001&MI_00\6&25A42EA3&0&0000`（各upload直前に一致確認）
- Receiver: 未使用
- 製品Sender／Receiver／`src/core_protocol`: 本調査では機能変更なし
- reset reason: 各upload後は`USB`。試験中の意図しない再起動は観測なし

## 4. 旧BASIC baseline

| 項目 | 履歴から確認できた情報 |
| --- | --- |
| firmware commit | `f81961f`（最初の実装。試合投入commitであることは未確認） |
| Core | M5Stack Core（READMEにBasic、Gray、Fire等） |
| Arduino core | `m5stack:esp32@2.1.4` |
| M5 library | `M5Stack.h`。versionは `UNKNOWN — user confirmation required` |
| USB Host Shield Library | USB Host Shield Library 2.0。versionは `UNKNOWN — user confirmation required` |
| SS pin | `UNKNOWN — user confirmation required` |
| INT pin | `UNKNOWN — user confirmation required` |
| SPI pins | `UNKNOWN — user confirmation required` |
| Controller | HORI PAD TURBO。VID/PIDは `UNKNOWN — user confirmation required` |
| 電源構成 | `UNKNOWN — user confirmation required` |

`f81961f`は旧baseline候補にすぎず、実際の試合firmwareと同一とは確定していない。確認が必要な保存物は、旧source commit/source一式、binary、Arduino CLI/IDE build log、`library.properties`またはlibrary list、HORI Pad VID/PIDログ、BASIC・USB Module・controller・外部給電の接続写真／配線記録である。

## 5. 隔離library環境

隔離rootは`build-temp/usb-lan-isolation`。USB Host Shield Libraryは公式tag `1.7.0` archiveから展開し、隔離copyだけに現行`build.ps1`相当のCoreS3 patchを1回適用した。global UHSは旧minimal CoreS3 patch状態だったため診断buildには使用していない。verbose buildは下記4 libraryの採用pathが隔離root配下であることを確認済み。

| Library | Version |
| --- | ---: |
| M5Unified | 0.2.19 |
| M5GFX | 0.2.26 |
| M5-Ethernet | 4.0.0 |
| USB Host Shield Library 2.0 | 1.7.0 |

| File | SHA256 |
| --- | --- |
| pristine `1.7.0.zip` | `3B6D75098AD1BAE0A739C25389373FEFCBBFE2876765295968168FCA05763CAE` |
| `avrpins.h` | `EE7B5473CC75E8E92511D4F5C8C0B11046241AEFD0A8B9DAB913F05E8C5A5CEB` |
| `UsbCore.h` | `7C63D4FEF96BFAB8253244B49F76B8425DB42DB3D5C2FD9C3E7E6B89F9D5C825` |
| `usbhost.h` | `00F9217A5D32691794560A8029D32B610903D2A92837D758E11836058DB98D82` |
| `library.properties` | `18EC606EAD123804645DDD928A498280DBD12019DC02CB84469F79DDCA0CDA63` |

`typedef MAX3421e<P1, P14> MAX3421E;`と`typedef SPi<P36, P37, P35, P1> spi;`は対象CoreS3 branchに各1個だけ存在する。重複定義、二重patch、旧minimal patch残存は隔離copy検証で検出されていない。hash manifestは`build-temp/usb-lan-isolation/library-hashes.txt`。

## 6. SPI.begin呼出し経路

- USB（1回）: `Usb.Init()` -> `MAX3421e::Init()` -> `spi::init()` -> `USB_SPI.begin()`。UHS `settings.h`で`USB_SPI`はglobal `SPI`に定義される。
- LAN（Mode 3以降で1回）: diagnostic `initializeLan()` -> `SPI.begin(36, 35, 37, -1)` -> `Ethernet.init(5)` -> `Ethernet.begin(...)`。
- M5-Ethernet内の`W5100.init()`にある`SPI.begin()`はcomment outされている。各LAN操作はlibrary固有の`SPI.beginTransaction()`を使用する。
- UHSもMAX3421E register accessごとにlibrary固有の`USB_SPI.beginTransaction()`を使用する。
- library内の`SPI.begin()`やtransaction管理は変更していない。

USB_FIRSTではUSB init直後、enumeration完了前にLAN側がglobal `SPI.begin(...)`を再実行し、`0x51 -> 0x12`となってRUNNINGへ到達しなかった。LAN_FIRSTではLANの`SPI.begin(...)`後に`Usb.Init()`を実行し、RUNNINGへ到達した。この差から初期化順序はUSB enumeration成否へ影響する。ただしLAN_FIRSTも後にdropする。

## 7. 自律試験比較

全条件は10分を上限とし、`0x90 -> 0x12`時は30秒追跡後に停止した。Durationは追跡時間を含む実ログ長、Drop timeは診断開始からdropまで。Mode 4/5はRUNNINGへ到達できるLAN_FIRSTで実施した。

| Core | Controller | Mode | Display | W5500 | Init order | Duration | Result | Drop time | SPI mismatch |
| ---- | ---------- | ---: | ------- | ----- | ---------- | -------: | ------ | --------: | -----------: |
| CoreS3 SE | DualSense | 0 | OFF | RESET LOW / no access | USB only | 33.521 s | Fail | 3.521 s | 0 |
| CoreS3 SE | DualSense | 1 | ON | RESET LOW / no access | USB only | 31.093 s | Fail | 1.093 s | 0 |
| CoreS3 SE | DualSense | 3 | OFF | init only | USB first | 600.000 s | Fail: RUNNING未到達 | N/A (`0x51 -> 0x12`) | 0 |
| CoreS3 SE | DualSense | 3 | OFF | init only | LAN first | 129.784 s | Fail | 99.784 s | 0 |
| CoreS3 SE | DualSense | 4 | OFF | init + 250 ms link poll | LAN first | 52.136 s | Fail | 22.136 s | 0 |
| CoreS3 SE | DualSense | 5 | ON | init + 250 ms link poll | LAN first | 42.023 s | Fail | 12.023 s | 0 |
| CoreS3 SE | HORI Pad | 0 | OFF | RESET LOW / no access | USB only | user test pending | pending | pending | pending |
| CoreS3 SE | DualSense + powered hub | 0 | OFF | RESET LOW / no access | USB only | user test pending | pending | pending | pending |
| M5 BASIC | DualSense | 0相当 | OFF | none | legacy | user test pending | pending | pending | pending |
| M5 BASIC | HORI Pad | old firmware | legacy | none | legacy | user test pending | pending | pending | pending |

Mode 3 USB_FIRSTは初版終了判定がRUNNING未到達をFailに含めず、raw log末尾に誤って`TEST_COMPLETE=PASS`と出力した。しかし600秒全域で`USB_TASK_STATE=12`、`HID_READY=0`、`HID_REPORT_TOTAL=0`であり、規定の合格条件には明確に不合格である。終了判定はその後、EVER_RUNNING、EVER_HID_READY、final state/HID、report totalを含めるよう修正した。

## 8. MAX3421E snapshotとtriple-read

| Condition | Transition | REV A/B/C | HRSL A/B/C | MODE | HCTL | HIRQ | USBIRQ | PINCTL | INT |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | ---: |
| Mode 0 | `90 -> 12` | `13/13/13` | `10/10/10` | `D1` | `10` | `69` | `01` | `18` | 0 |
| Mode 1 | `90 -> 12` | `13/13/13` | `10/10/10` | `D1` | `10` | `49` | `01` | `18` | 0 |
| Mode 3 USB_FIRST | `51 -> 12` | `13/13/13` | `03/03/03` | `D1` | `00` | `69` | `01` | `18` | 0 |
| Mode 3 LAN_FIRST | `90 -> 12` | `13/13/13` | `10/10/10` | `D1` | `10` | `69` | `01` | `18` | 0 |
| Mode 4 | `90 -> 12` | `13/13/13` | `10/10/10` | `D1` | `10` | `59` | `01` | `18` | 0 |
| Mode 5 | `90 -> 12` | `13/13/13` | `10/10/10` | `D1` | `10` | `69` | `01` | `18` | 0 |

全条件で`MAX_REV_MISMATCH=0`、`MAX_HRSL_MISMATCH=0`、`MAX_SPI_READ_MISMATCH=0`。Mode 4のdrop直前は`MAX_REV_BEFORE=13`、`MAX_REV_AFTER=13`、`MAX_HRSL_BEFORE=10`、`MAX_HRSL_AFTER=10`。Mode 5のdrop直前1Hz sampleはrevision `13 -> 13`、HRSL `90 -> 90`で、その後のdrop snapshotはHRSL `10/10/10`。いずれも`SPI_CORRUPTION_SUSPECTED=0`。

Mode 4では`MAX_USB_TASK_US=1,209,271 us`の単発長時間実行を観測した。これはUSB task/library内部の長い処理を示すが、それだけで原因は確定できない。

## 9. 原因判定

| 仮説 | 現時点の判定 |
| --- | --- |
| MAX3421EとW5500／LCD間の共有SPI破損 | 必要条件ではない。Mode 0で再現。要求したtriple-read／W5500前後比較では破損証拠なし。ただし完全否定ではない |
| DualSenseまたはCoreS3電源経路によるVBUS低下 | 未判定。Mode 0 Failに整合するがVBUS未測定 |
| USB Host Shield Library 1.7.0 CoreS3 patch問題 | 未判定。Mode 0 Failに整合する |
| 実USBケーブル／controller切断 | 未判定。試験中の手動切断はしていないが、ケーブル・connector・controller内部状態は未測定 |
| 初期化順序 | 影響あり。USB_FIRSTはRUNNING未到達、LAN_FIRSTはRUNNING到達後にFail |

電源問題をsoftware logだけで確定しない。powered hubで差が出た場合、USB Module USB-A VBUSとM5-Bus 5Vをオシロスコープ推奨（最低限DMM）で測定する。未測定電圧値は記載しない。

## 10. 物理試験待ち

次の優先ゲートはTest H（HORI Pad）である。

1. CoreS3 SEの電源を切る。
2. LAN Moduleはstackされたままでよいが、LAN cableは不要。USB Module v1.2へDualSenseの代わりにHORI Padを接続する。
3. Sender COM4とPnP instanceが指定値であることを確認する。
4. `tools/usb_lan_isolation_test.ps1 -Mode 0 -InitOrder 0 -DurationSeconds 600 -Port COM4`を実行する。
5. 期待判定: HORIが10分PassならDualSense固有（電源負荷またはprotocol挙動）を優先。HORIもFailならCoreS3 USB Host／電源経路／library対応を優先する。

その後のTest PはセルフパワーUSBハブへ先に給電し、`CoreS3 SE -> USB Module -> powered hub -> DualSense`でMode 0を10分実施する。powered hubだけPassなら電源系対策を設計し、上記2点を実測する。Test B1はM5 BASIC + USB Module + DualSense + LANなし、Test B2はM5 BASIC + USB Module + HORI Pad + 旧試合firmwareで各10分。旧binary/sourceが見つからない場合、B2は実施不能として記録する。

## 11. ログと成果物

- build/serial logs: `build-temp/usb-lan-isolation/logs`
- library hash manifest: `build-temp/usb-lan-isolation/library-hashes.txt`
- diagnostic sketch: `M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino`
- test runner: `tools/usb_lan_isolation_test.ps1`
- report: `docs/cores3se-usb-lan-root-cause-report.md`
