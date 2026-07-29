# CoreS3 SE USB Host切断 段階的原因分離レポート

## 1. 結論

CoreS3 SE + USB Module v1.2 + DualSenseの`0x90 -> 0x12`は、W5500初期化、W5500周期アクセス、UDP、LCD描画のすべてを除外したMode 0でも再現した。LAN Moduleを物理的に取り外したDualSense Bでも、VID/PID `054C/0CE6`としてenumerationして108 reportを受信後、1.107秒で再現した。したがって、W5500／LCD共有SPI競合とLAN Moduleの物理的存在は現象発生の必要条件ではない。

MAX3421Eの`rREVISION`と`rHRSL`のtriple-read不一致は全条件で0、Mode 4/5のW5500 Link poll前後でもrevision変化は0だった。この診断で共有SPI read破損を示す証拠は得られていない。ただし、読取り値が一致したことだけで全種類のSPI競合を完全否定はできない。

一方、同じCoreS3 SE、USB Module、Base M5GO Bottom3、LANなし構成でHORI Pad `0F0D/0202`は、WirelessSenderの60秒3回と10分、HIDUniversal Mode 0の10分をすべてPassした。CoreS3 SE、USB Module、Bottom、CoreS3 patch、HIDUniversal基本経路は少なくともHORIでは安定しているため、現在はDualSense固有の電源負荷またはUSB protocol／driver挙動を優先する。自動再初期化、MAX3421E reset、ESP restart、watchdog復旧は追加していない。

DualSense A `054C/0CE6`をPS5USB専用driverで比較した結果、NO_OUTPUTとlibrary DEFAULTの双方が60秒screening 3回すべてで`0x90 -> 0x12`となった。NO_OUTPUTでも625～876 msでdropしたため、PS5USB標準初期化時のLED OUT reportは切断の必要条件ではなく、HIDUniversal parser固有問題でもない。PS5USBへ切り替えても現象は解消しない。

UGREEN B09DCK46PM powered hub経由では、Windowsが同一条件のDualSense Aを正常認識する一方、CoreS3/MAX3421E/UHSは対照用HORIを下流HIDとしてenumerationできなかった。global stateは`0x90`になったがtargetはreadyにならず、その後`Usb.Task()`が戻らなかった。最後に完了したinventoryはRUNNING到達前の`HUB_READY=0`で、到達後のhub addressは取得不能だった。これはCase PH4であり、powered hubによるDualSense電源改善比較は成立していない。このhub調査は現行stackではRejected topologyとして完了し、製品開発の次工程にはしない。

## 2. 0x90 -> 0x12の解釈

- `0x90`: USB Host Shield Libraryの`USB_STATE_RUNNING`
- `0x12`: `USB_DETACHED_SUBSTATE_WAIT_FOR_DEVICE`
- 実測ではHID_READYが1から0へ落ち、VID/PIDが`054C/0CE6`から`0000/0000`へ戻り、HID reportが停止した。
- これはlibraryがdevice detached待機状態へ戻ったことを示すが、VBUS瞬低、実ケーブル切断、controller側切断、library誤判定のどれかはsoftware stateだけでは確定できない。

## 3. 調査条件

### Sender identity

- upload対象: Sender `COM4`のみ
- PnP instance: `USB\VID_303A&PID_1001&MI_00\6&25A42EA3&0&0000`（各upload直前に一致確認）
- Receiver: 未使用

### Current physical setup

- CoreS3 SE + USB Module v1.2 + Base M5GO Bottom3
- Powered USB hub: UGREEN `B09DCK46PM`、external power ON
- Controller: HORI Pad `0F0D/0202`、hub経由
- Hub port: 現在switch ONの単一downstream port（物理port番号は未確認）、他port switch OFF
- LAN Module、Ethernet cable、Receiver: 取り外し／未接続
- Cable: HubUpstream
- SenderにはIsolationDiagnostic Mode 0のpowered-hub 60秒binaryが書込み済み。最後の観測stateは`0x90`、targetはreadyでなく、RUNNING到達後のhub readinessは取得不能

### Per-test hardware differences

| Test group | LAN Module | Display | Controller path |
| --- | --- | --- | --- |
| Initial Mode 0–5 | Present | mode依存 | DualSense direct |
| No-LAN reference | Removed | OFF | DualSense B direct |
| Powered hub reference | Removed | OFF | powered hub経由DualSense B（下流未検出） |
| HORI 5A/5B | Removed | WirelessSenderのみON | HORI direct、Fixed cable |
| PS5USB comparison | Removed | OFF | DualSense A direct、Fixed cable |

### Git baselines

- Investigation-start HEAD: `a42c788314aa4e8f328923717a9d3154aee1dc48`
- Current HEAD: `28659a24de4bbccd3d0142c4cb053b3399fa8cfd`
- Origin/upstream HEAD: `28659a24de4bbccd3d0142c4cb053b3399fa8cfd`
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
| CoreS3 SE | DualSense | 0 | OFF | LAN Module physically removed | USB only | 600.000 s | Invalid comparison: device未検出 | N/A (`0x11 -> 0x12`) | 0 |
| CoreS3 SE | DualSense B | 0 | OFF | LAN Module physically removed | USB only | 31.107 s | Fail | 1.107 s | 0 |
| CoreS3 SE | DualSense B + powered hub | 0 | OFF | LAN Module physically removed | USB only | 347.335 s | Invalid for power comparison — downstream HID not enumerated | N/A | 0 |
| CoreS3 SE | HORI Pad (`0F0D/0202`) | 0 | OFF | LAN Module physically removed | USB only | 600.000 s | Pass | 0 | 0 |
| CoreS3 SE | DualSense A + powered hub | 0 | OFF | LAN Module physically removed | USB only | Not run — blocked by PH-HORI failure | stopped by gate | N/A | N/A |
| M5 BASIC | DualSense | 0相当 | OFF | none | legacy | user test pending | pending | pending | pending |
| M5 BASIC | HORI Pad | old firmware | legacy | none | legacy | user test pending | pending | pending | pending |

Mode 3 USB_FIRSTは初版終了判定がRUNNING未到達をFailに含めず、raw log末尾に誤って`TEST_COMPLETE=PASS`と出力した。しかし600秒全域で`USB_TASK_STATE=12`、`HID_READY=0`、`HID_REPORT_TOTAL=0`であり、規定の合格条件には明確に不合格である。終了判定はその後、EVER_RUNNING、EVER_HID_READY、final state/HID、report totalを含めるよう修正した。

LAN Module物理取り外し第1回はMAX3421E revision `0x13`を読めたが、DualSenseが一度もenumerationされず、初期state `0x11 -> 0x12`、HID report 0のまま10分終了した。これはRUNNING後のdropではなくdevice未検出であり、LAN Module有無の比較結果としては未成立。USB-A側の物理接続／VBUS／cable／controllerを確認して同条件を再試験する。

別個体DualSense BではLAN Moduleを物理的に外した同じMode 0でenumerationに成功し、VID/PID `054C/0CE6`、HID report 108件を受信後、1.107秒で`0x90 -> 0x12`を再現した。drop snapshotはREV `13/13/13`、HRSL `00/00/00`、MODE `D1`、HCTL `20`、SPI mismatch 0。これによりLAN Moduleの物理的存在も現象の必要条件ではないことが確認された。

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

PS5USBのDualSense A試験でも全7回のdrop snapshotでrevisionは`13/13/13`だった。drop時のHRSL単読値はNO_OUTPUT 60秒3回と600秒条件が順に`10`、`00`、`10`、`10`、DEFAULT 3回が`30`、`20`、`30`。MODEはいずれも`D1`で、USB stateとPS5 connectedは同時に`90 -> 12`、`1 -> 0`へ変化した。PS5USB診断ではHRSL triple-readを追加していないため、これらをHRSL不一致判定には使用しない。

## 9. 原因判定

| 仮説 | 現時点の判定 |
| --- | --- |
| MAX3421EとW5500／LCD間の共有SPI破損 | 必要条件ではない。Mode 0で再現。要求したtriple-read／W5500前後比較では破損証拠なし。ただし完全否定ではない |
| DualSenseまたはCoreS3電源経路によるVBUS低下 | 未判定。HORIは同じ構成で安定したため、CoreS3共通電源障害よりDualSense固有負荷を優先。VBUSは未測定 |
| USB Host Shield Library 1.7.0 CoreS3 patch問題 | HORIのHIDUniversal経路は安定。DualSense AはHIDUniversalとは別のPS5USBでもNO_OUTPUT／DEFAULT双方でFailしたため、個別parserだけの問題ではない。UHS／CoreS3／MAX3421EとDualSenseの組合せは候補として残る |
| 実USBケーブル／controller切断 | 未判定。試験中の手動切断はしていないが、ケーブル・connector・controller内部状態は未測定 |
| 初期化順序 | 影響あり。USB_FIRSTはRUNNING未到達、LAN_FIRSTはRUNNING到達後にFail |

電源問題をsoftware logだけで確定しない。今回のpowered hub比較はCoreS3側でHORIをenumerationできず不成立だったため、電源改善の有無は未判定である。将来電源を再調査する場合は、USB Module USB-A VBUSとM5-Bus 5Vをオシロスコープ推奨（最低限DMM）で測定する。未測定電圧値は記載しない。

## 10. 調査完了状態と分離した候補

Test H、PS5USB純粋比較、PH-HORI gateまで完了した。DualSense AのNO_OUTPUT 600秒条件は開始後1.031秒でdropし、30秒追跡後に早期Fail終了した。DEFAULTは60秒screening 3回すべてFailしたため、明示されたPass gateに従いDEFAULT 600秒は実施していない。

UGREEN B09DCK46PMはCoreS3/MAX3421E/UHSで対照用HORIを下流HIDとしてenumerationできず、RUNNING後に`Usb.Task()`が戻らなくなった。PH-HORI 600秒とCoreS3 hub経由DualSenseは未実施で、powered hubによるDualSense電源比較は成立していない。hub調査は現行stackではRejected topologyとして完了し、次工程にはしない。DualSense調査は製品完成条件から分離した。M5 BASIC比較や実電圧測定は、将来別の調査として明示的に再開する場合だけ行う。

## 11. ログと成果物

- build/serial logs: `build-temp/usb-lan-isolation/logs`
- library hash manifest: `build-temp/usb-lan-isolation/library-hashes.txt`
- diagnostic sketch: `M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino`
- PS5USB diagnostic sketch: `M5Stack-PS5CoREPs5UsbDiagnostic.ino`
- test runner: `tools/usb_lan_isolation_test.ps1`
- report: `docs/cores3se-usb-lan-root-cause-report.md`

## 12. HORI機能試験とcontroller／driver比較

| Test | Core | Controller | Firmware | Driver | Cable | Hub | Bottom | Duration | Result | Drop |
| ---- | ---- | ---------- | -------- | ------ | ----- | --- | ------ | -------: | ------ | ---: |
| 5A screening 1 | CoreS3 SE | HORI `0F0D/0202` | WirelessSender | WirelessSender | Fixed | none | Present | 60.004 s | Pass | 0 |
| 5A screening 2 | CoreS3 SE | HORI `0F0D/0202` | WirelessSender | WirelessSender | Fixed | none | Present | 60.004 s | Pass | 0 |
| 5A screening 3 | CoreS3 SE | HORI `0F0D/0202` | WirelessSender | WirelessSender | Fixed | none | Present | 60.004 s | Pass | 0 |
| 5A long | CoreS3 SE | HORI `0F0D/0202` | WirelessSender | WirelessSender | Fixed | none | Present | 600.000 s | Pass | 0 |
| 5B Mode 0 | CoreS3 SE | HORI `0F0D/0202` | IsolationDiagnostic | HIDUniversal | Fixed | none | Present | 600.000 s | Pass | 0 |
| Direct reference | CoreS3 SE | DualSense B `054C/0CE6` | IsolationDiagnostic | HIDUniversal | Unknown | none | Present | 31.107 s | Fail | 1.107 s |
| Powered hub reference | CoreS3 SE | DualSense B `054C/0CE6` | IsolationDiagnostic | HIDUniversal | Unknown | powered | Present | 347.335 s | Invalid for power comparison — downstream HID not enumerated | N/A |
| PS5USB NO_OUTPUT 1 | CoreS3 SE | DualSense A `054C/0CE6` | Ps5UsbDiagnostic | PS5USB NO_OUTPUT | Fixed | none | Present | 30.838 s | Fail, 67 reports | 0.838 s |
| PS5USB NO_OUTPUT 2 | CoreS3 SE | DualSense A `054C/0CE6` | Ps5UsbDiagnostic | PS5USB NO_OUTPUT | Fixed | none | Present | 30.876 s | Fail, 76 reports | 0.876 s |
| PS5USB NO_OUTPUT 3 | CoreS3 SE | DualSense A `054C/0CE6` | Ps5UsbDiagnostic | PS5USB NO_OUTPUT | Fixed | none | Present | 30.625 s | Fail, 13 reports | 0.625 s |
| PS5USB NO_OUTPUT long | CoreS3 SE | DualSense A `054C/0CE6` | Ps5UsbDiagnostic | PS5USB NO_OUTPUT | Fixed | none | Present | 31.031 s of 600 s condition | Fail, 115 reports | 1.031 s |
| PS5USB DEFAULT 1 | CoreS3 SE | DualSense A `054C/0CE6` | Ps5UsbDiagnostic | PS5USB DEFAULT | Fixed | none | Present | 30.976 s | Fail, 1 report | 0.976 s |
| PS5USB DEFAULT 2 | CoreS3 SE | DualSense A `054C/0CE6` | Ps5UsbDiagnostic | PS5USB DEFAULT | Fixed | none | Present | 30.690 s | Fail, 30 reports | 0.690 s |
| PS5USB DEFAULT 3 | CoreS3 SE | DualSense A `054C/0CE6` | Ps5UsbDiagnostic | PS5USB DEFAULT | Fixed | none | Present | 30.823 s | Fail, 63 reports | 0.823 s |

WirelessSenderは起動時に`Boot mode: USB Host`と`USB Host Init OK`を確認した。60秒3回は正本負荷確認として`USB_HID_RAW_LOG=1`、10分試験は`USB_HID_RAW_LOG=0`で1Hz summaryだけを出力した。report総数は順に5,924、5,930、5,930、59,931。Mode 0 HIDUniversalは119,865 report、`HID_READY_DROP=0`、`MAX_SPI_READ_MISMATCH=0`、`SPI_CORRUPTION_SUSPECTED=0`だった。

WirelessSenderとMode 0はいずれもenumeration中の`0x51 -> 0x90`で約406.7 msの単発`USB_TASK_SLOW`を記録した。HORIはその後10分安定したため、このslow call単独ではdetach原因にならない。Mode 0のslow snapshotはREV `13/13/13`、HRSL `85/85/85`、MODE `C9`、HCTL `20`、HIRQ `69`、USBIRQ `01`、PINCTL `18`だった。

Powered hub再診断用にはUHS public APIの`USB::ForEachUsbDevice`、`USB::getDevDescr`、`USBHub::GetAddress`を使うinventoryをIsolationDiagnosticへ追加した。address、parent、port、class、VID/PIDを1Hzで出力し、hub、downstream HID、target controllerを分離する。target HIDが15秒以内にreadyにならなければ`TEST_RESULT=NO_TARGET_HID`で停止する。PH-HORIではRUNNING前のinventoryまでは取得できたが、RUNNING後の`Usb.Task()`が非復帰となり更新後inventoryを取得できなかった。最終結果は第14節のCase PH4である。

ログSHA256:

- screening 1: `F454BD049E81507BAA286118960DCC121C0860BAEC98B0C7C12E234E937AFB07`
- screening 2: `3B44B337145E46EE89110E995E7D91B52BBCDC19B901265C1F3155C9ED731DA3`
- screening 3: `364EE1FCE4AE7CECAA99B48F6EB8BBFB7E0AB654C49E7619EDE9225C4DC8469C`
- WirelessSender 10分: `74FB5CE91CC9CBFC0F5F867F075ECE5D3F403AF8268589A47CDA3E5517ACB702`
- Mode 0 HORI 10分: `2D0815453C3D21CF848BE2DC3BDCD79FE0C2A750D48C3845389F66551EE277CC`

## 13. PS5USB純粋比較

`PS5USB_INIT_OUTPUT=0`では`Ps5.attachOnInit(onPs5InitNoOutput)`を`Usb.Init()`前に設定する。callbackは`PS5_INIT_CALLBACK=NO_OUTPUT`をSerialへ出すだけで、`setLed`、rumble、player/mic LED、trigger effectなどのoutput APIを呼ばない。`PS5USB_INIT_OUTPUT=1`ではcallbackを登録せずlibrary default outputを保持する。起動時にそれぞれ`PS5_INIT_OUTPUT=NO_OUTPUT`または`PS5_INIT_OUTPUT=DEFAULT`を記録する。

dropは、RUNNINGから他stateへ離れた時、または接続済みtargetを失った時の早い方を初回だけ記録する。理由は`LEFT_RUNNING`、`LOST_TARGET`、同時なら`BOTH`。既存の`USB_STATE_TRANSITION=90->12`ログも継続する。

BuildOnly結果:

| Init output | Duration | Target timeout | Build | Binary SHA256 |
| --- | ---: | ---: | --- | --- |
| NO_OUTPUT (`0`) | 60 s | 15 s | Pass | `D4825BD78A8D0F1BADA073D4C03E1F41296BD1BC63A5B916014CD23AEE4A39C3` |
| NO_OUTPUT (`0`) | 600 s | 15 s | Pass | `BC2FD583430AE72058E373A1C0EE3CAB837778DB0821B1FF7A82BF8B470656BE` |
| DEFAULT (`1`) | 60 s | 15 s | Pass | `787D642F460B610309830BDA5A4BAB9EC2E6D45DB1E3A22BE5989667D9441BBE` |

build case名はfirmware、mode、init order、duration、target timeout、PS5 init output、RAW modeを含む。61秒条件から60秒NO_OUTPUT binaryを`-ReuseBuild`しようとした検証は、対応build logなしとして拒否された。これによりdurationまたはoutput modeが異なるbinaryの誤再利用を防ぐ。

2026-07-29のcommit前BuildOnlyでは、現runnerのcase名（powered-hub flagを含む）で再buildし、IsolationDiagnostic Mode 0が`0AA139C68D156D0F60C4B304F4C1FB372C8E0F5CC1071ACAF2A3193AA88FD7BB`、PS5USB NO_OUTPUT 60秒が`C2E279CA776194555A32522C0FFD4174AA46B39582F65730D52AC71537450680`、PS5USB DEFAULT 60秒が`3BC5258301CFC6BD2DE39495A39B70E2C7160F1233A5CEA92333B488D5B77545`だった。いずれも`build-temp/usb-lan-isolation/libraries`のM5Unified 0.2.19、M5GFX 0.2.26、USB Host Shield Library 2.0 1.7.0を使用し、IsolationDiagnosticは同じ隔離pathのM5-Ethernet 4.0.0も使用した。

実機結果:

| Init output | Run | Drop time | Reports | Drop reason | MAX_USB_TASK_US | MAX_USB_GAP_US | REV at drop |
| --- | ---: | ---: | ---: | --- | ---: | ---: | --- |
| NO_OUTPUT | 1 | 838 ms | 67 | BOTH (`90 -> 12`, connected `1 -> 0`) | 304,232 | 304,785 | `13/13/13` |
| NO_OUTPUT | 2 | 876 ms | 76 | BOTH (`90 -> 12`, connected `1 -> 0`) | 304,239 | 304,782 | `13/13/13` |
| NO_OUTPUT | 3 | 625 ms | 13 | BOTH (`90 -> 12`, connected `1 -> 0`) | 304,239 | 304,782 | `13/13/13` |
| NO_OUTPUT 600 s condition | 1 | 1,031 ms | 115 | BOTH (`90 -> 12`, connected `1 -> 0`) | 304,265 | 304,810 | `13/13/13` |
| DEFAULT | 1 | 976 ms | 1 | BOTH (`90 -> 12`, connected `1 -> 0`) | 705,207 | 705,774 | `13/13/13` |
| DEFAULT | 2 | 690 ms | 30 | BOTH (`90 -> 12`, connected `1 -> 0`) | 304,236 | 304,801 | `13/13/13` |
| DEFAULT | 3 | 823 ms | 63 | BOTH (`90 -> 12`, connected `1 -> 0`) | 304,236 | 304,803 | `13/13/13` |

全7回でPnP identityをupload直前に一致確認し、DualSense Aを`054C/0CE6`としてenumerationできた。意図しないreset、panic、WDTはなく、reset reasonはuploadに伴う`USB`だった。NO_OUTPUTでは毎回`PS5_INIT_CALLBACK=NO_OUTPUT`を確認した。DEFAULT 1回目だけenumerationを含むslow taskが705,207 usで、他6回は約304.2 msだった。いずれもslow taskの終了時にはRUNNING／connectedへ到達しており、その後にdropした。MAX3421E revision triple-readは全drop snapshotで一致している。

NO_OUTPUT 600秒条件も実行したが、1.031秒でdropし、30秒追跡後の31.031秒で早期Fail終了した。DEFAULTは3回すべてFailしたため、Pass時のみ実施するDEFAULT 600秒は行っていない。PS5USB標準`setLed(Red)`に伴う初期OUT reportは現象の必要条件ではない。ただし、電力負荷、USB physical layer、DualSense側挙動、UHSのDualSense共通処理のどれかは本試験だけでは分離できない。

実機Serial log SHA256:

- NO_OUTPUT 1: `CE71D533A588DD8EAEE7152CF19C881DD7D40F40D58E0D7DA9BDA53172DF03DE`
- NO_OUTPUT 2: `EB23DD56FA3493211EA2E263D54A527D4918E9DF599B141EBFF8AAB674B04B25`
- NO_OUTPUT 3: `EA555F9B4254A9FB6E74D2C3FA848F8F6D2143D5C58643859A33EA45855AC99A`
- NO_OUTPUT 600秒条件: `D9596956D571B48724820EC5667D648C720C2108F6F8F3A6A29CCA05268DC5AF`
- DEFAULT 1: `DF734EC24859C1846DCE10893BF54399C14C828F0D36E0A86901957FD6AD2A56`
- DEFAULT 2: `313AB0602B82BD1C9619719C364AE0E6D11B5F00C93DC8DF3AB985B8562865EE`
- DEFAULT 3: `D35D0CF7ED4AE8490817B2588336BAC7FCEF993D00DCA13BD0B211F7006A915F`

## 14. Powered USB hub経由比較

### Windows hub validation

DualSense A `054C/0CE6` was successfully enumerated through UGREEN B09DCK46PM on Windows as a composite USB device. Windowsでは同じexternal power、upstream cable、downstream port、port switch、DualSense cable、DualSense Aの条件で`USB Composite Device`、HID準拠ゲームコントローラー、USB入力デバイス、DualSense audio interfaceを認識し、device statusはOKだった。

### PH-HORI結果

| Test | Host | Hub | Controller | Enumeration | Duration | Result | Drop |
| --- | --- | --- | --- | --- | ---: | --- | ---: |
| Windows reference | Windows | UGREEN powered | DualSense A `054C/0CE6` | Pass | manual | Pass | 0 |
| CoreS3 hub control | CoreS3/MAX3421E | UGREEN powered | HORI `0F0D/0202` | Fail: target not enumerated | host observed >15 s; Serial stopped at 0.579 s | Fail / Usb.Task blocked | N/A |
| CoreS3 hub target | CoreS3/MAX3421E | UGREEN powered | DualSense A `054C/0CE6` | Not run | 0 | stopped by PH-HORI gate | N/A |

PH-HORI 60秒screeningでは、COM4 PnP identity一致後にuploadした。`Usb.Init()`はOK、MAX3421E revisionは`13/13/13`で、global USB task stateは`0x51 -> 0x90`へ到達した。RUNNING到達前に最後に完了したinventoryは`USB_DEVICE_COUNT=0`、`HUB_READY=0`、`TARGET_CONTROLLER_READY=0`、hub／target address `00`、VID/PID `0000/0000`、HID report 0だった。RUNNING到達後は次の`Usb.Task()`が戻らずinventoryを再取得できないため、hub address／VID/PIDはUNKNOWNである。`USB_TASK_STATE=90`だけをPassとは判定していない。

RUNNING到達時の`Usb.Task()`は307,545 usで戻ったが、その直後の次回`Usb.Task()`からSerial出力が止まり、firmwareの15秒`TEST_RESULT=NO_TARGET_HID`判定へ到達できなかった。host runnerはtarget未検出のままcapture deadlineで終了した。自動`Usb.Init()`、MAX3421E reset、`ESP.restart()`は行っていない。

この結果はCase PH4に該当する。Windowsでは同一hub経由DualSenseが正常である一方、CoreS3/MAX3421E/UHSでは対照用HORIすらhub配下へenumerationできない。したがってDualSenseのpowered-hub電源改善比較は無効であり、PH-HORI 600秒、DualSense BuildOnly／60秒×3／600秒へは進んでいない。UGREEN B09DCK46PMは現行stackではRejected topologyとし、hub調査を製品開発の次工程にはしない。

PH-HORI build／log:

- isolated build: Pass、binary SHA256 `75B3FFB93C199041DD43452DB8301979D4D5E8F3FA0004E2DE0050BF70B65C04`
- Serial log SHA256: `F2298486F5422AB5918180486979D455DE356EE837DF8F216A438CA4F659CD5C`
- libraries: M5Unified 0.2.19、M5GFX 0.2.26、M5-Ethernet 4.0.0、USB Host Shield Library 2.0 1.7.0（すべて隔離path）
