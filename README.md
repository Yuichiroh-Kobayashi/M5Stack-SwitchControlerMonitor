# M5Stack Switch Controller to CoRE Wireless Sender

M5Stack に USB Host Shield を接続し、Nintendo Switch 用コントローラー (HORI PAD TURBO 等) の入力値を CoRE で支給される無線送信モジュール向けに変換・送信するプログラムです。

`M5Stack Core`、`M5Stack Core2`、`M5 CoreS3 SE` を対象に、`USB Host Shield Library 2.0` ベースで `M5Stack USB Module v1.2` を利用します。
UI/電源制御は `M5Unified` 前提で実装しており、`M5Stack.h` ではなく `M5Unified.h` を使用します。

## 今回の主な変更点

- `M5Stack-PS5CoREWirelessTransmitter` と `M5Stack-PS5CoREWirelessReceiver` を追加し、M5Stack 同士を WiFi で接続できる構成に対応
- `M5Stack-PS5CoREWirelessSender` を DualSense (PS5 コントローラー) の入力解析に対応
- `build.ps1` に `-SketchName` を追加し、ビルド対象スケッチを切り替え可能化

## 機能

- **USB Host 接続**: M5Stack USB モジュール (MAX3421E) を介してコントローラーを認識
- **入力可視化**:
    - **ボタン**: A, B, X, Y, L, R, ZL, ZR, +, -, Home, Capture, Stick Click の押下状態を表示
    - **アナログスティック**: 左・右スティックの現在値を数値とグラフィックで表示
    - **十字キー (DPAD)**: 押されている方向 (UP, RIGHT, DOWN-LEFT 等) をテキストとビジュアルで表示
- **デバッグ情報**: 生の HID レポートデータ (Hex Dump) を表示
- **バッテリ残量表示**: 画面最下段の送信データ右側に `BAT: **%` 形式で M5Unified の参考残量を表示
  - 51%以上: 白色
  - 26〜50%: 黄色
  - 25%以下: 赤色
  - M5Stack Basic / Fire / M5GO系では、ハードウェア制約により 0%、25%、50%、75%、100% の5段階表示になる場合があります。
  - 残量は `M5.Power.getBatteryLevel()` による参考値であり、厳密な残量計ではありません。
- **シリアル通信 (Serial2)**: ボードに応じて UART ピンを自動切替し、フォーマットされたコントローラー情報を 115200bps で送信 (200ms 間隔)
  - Core: `RX=GPIO16`, `TX=GPIO17`
  - Core2 (Port C): `RX=GPIO13`, `TX=GPIO14`
  - CoreS3 SE (Port C): `RX=GPIO18`, `TX=GPIO17`

## 送信データフォーマット (Serial2)

**Serial2 (TX)** から送信されるデータは、以下の 7 バイトのカンマ区切り16進数文字列 + 改行コード (`\r\n`) です。
例: `00,00,00,80,80,80,80\r\n` (中立時)

| Byte | 内容 | 値の範囲・意味 |
|:---:|:---|:---|
| **0** | **Button 1** | ビットフラグ (A, B, X, Y, L, R, ZL, ZR) |
| **1** | **Button 2** | ビットフラグ (-, +, Home, Cap, LStick, RStick) |
| **2** | **DPAD** | **00:中立**, **01:上** .. **08:左上** (時計回り) |
| **3** | **Left Stick X** | 0x00(左) - 0xFF(右), 中心:0x80 |
| **4** | **Left Stick Y** | 0x00(上) - 0xFF(下), 中心:0x80 |
| **5** | **Right Stick X** | 0x00(左) - 0xFF(右), 中心:0x80 |
| **6** | **Right Stick Y** | 0x00(上) - 0xFF(下), 中心:0x80 |

### ボタン (Byte 0, Byte 1) ビット詳細

**Byte 0: Button 1**
| Bit | ボタン |
|:---:|:---|
| 0 | A |
| 1 | B |
| 2 | X |
| 3 | Y |
| 4 | L |
| 5 | R |
| 6 | ZL |
| 7 | ZR |

**Byte 1: Button 2**
| Bit | ボタン |
|:---:|:---|
| 0 | - (Minus) |
| 1 | + (Plus) |
| 2 | Home |
| 3 | Capture |
| 4 | L Stick (押し込み) |
| 5 | R Stick (押し込み) |
| 6 | (未使用) |
| 7 | (未使用) |


## 必要ハードウェア

- **M5Stack Core / Core2 / CoreS3 SE**
- **M5Stack USB Module** (MAX3421E 搭載の USB Host Shield)
- **Nintendo Switch 対応 USB コントローラー** (動作確認済み: HORI PAD TURBO)
- **HORI PAD TURBO 本体の切替スイッチ**: `Switch 2` 側で使用（`PC` 側だと想定配列になりません）

### USB Module v1.2 の DIP スイッチ設定 (シルク準拠)

実機シルクの `PIN MAP` に合わせ、`SS Select(CH1-CH3)` と `INT Select(CH1-CH2)` を選択します。

| 信号 (Signal) | チャンネル | Core (GPIO) | Core2 (GPIO) | 設定値 | 備考 |
|:---|:---:|:---:|:---:|:---:|:---|
| **SS** (Slave Select) | **CH1** | **G13** | **G19** | **ON** | デフォルトの選択信号 |
| | CH2 | G5 | G33 | OFF | CoreではmicroSDと競合するため |
| | CH3 | G0 | G0 | OFF | 未使用 |
| **INT** (Interrupt) | **CH1** | **G35** | **G35** | **ON** | デフォルトの通知信号 |
| | CH2 | G34 | G34 | OFF | 未使用 |

**CoreS3 SE は USB Module v1.2 の SS / INT を必ず両方 CH2 に設定してください。** USB Host Shield Library 2.0 PR #843 のCoreS3実装に従い、SS=GPIO1、INT=GPIO14、SPI=`SCK=GPIO36/MOSI=GPIO37/MISO=GPIO35` を使用します。CoreS3 SE のCH1/CH3 GPIOは確認済みではないため、このターゲットでは選択できません。

## ビルド済みバイナリを使う（コンパイル不要）

コンパイル環境を用意しなくても、GitHub Releases からダウンロードしたビルド済みバイナリを書き込めます。

### 必要なもの
- [Arduino CLI](https://arduino.github.io/arduino-cli/installation/) のインストール
- M5Stack を PC に接続

### 手順

1. [Releases](../../releases) から M5Stack のボードに合う `.bin` をダウンロードする

   | ファイル名 | 対象ボード |
   |---|---|
   | `SwitchSender_core2_SS-CH1_INT-CH1.bin` | M5Stack Core2 (デフォルト) |
   | `SwitchSender_core_SS-CH1_INT-CH1.bin` | M5Stack Core |
   | `SwitchSender_cores3se_SS-CH2_INT-CH2.bin` | M5 CoreS3 SE |

2. ダウンロードした `.bin` を任意のフォルダに置く（例: `C:\Downloads\SwitchSender\`）

3. M5Stack を PC に接続し、対象ボードを明示して `flash.ps1` を実行する

```powershell
# build/ に .bin がある場合（build.ps1 -ExportBinaries 実行後）
.\flash.ps1 -Board core -Port COMx
.\flash.ps1 -Board core2 -Port COMx
.\flash.ps1 -Board cores3se -Port COM9

# ダウンロードした Arduino CLI のバイナリ一式を指定して書き込む場合
.\flash.ps1 -Board cores3se -Port COM9 -BinDir C:\Downloads\SwitchSender
```

`build` ディレクトリに複数ボードの成果物が存在する場合、誤書き込み防止のため `flash.ps1` は `-Board` 未指定をエラーにします。書き込み時は対象ボードを明示してください。

---

## 開発環境 & 依存ライブラリ

ビルドには [Arduino CLI](https://arduino.github.io/arduino-cli/) を使用します。

### 依存ライブラリ (自動インストールされます)
- M5Unified
- USB Host Shield Library 2.0

`build.ps1` は `Documents/Arduino/libraries/USB_Host_Shield_Library_2.0` を事前チェックし、無ければインストールします。古いライブラリにのみ Core/Core2 のピン別名と、USB Host Shield Library 2.0 PR #843 相当のCoreS3定義を冪等に追加します。upstream に定義済みなら追加変更しません。

既存のCoreS3 SE＋USB Module v1.2構成は、`m5stack:esp32@3.3.7`でビルド・実機動作を確認済みです。LAN Module 13.2との積層動作は、本診断スケッチによる検証前です。

## 環境設定

設定ファイル `config.json` を作成することで、環境ごとのデフォルト値を固定できます。
リポジトリにある `config.json.sample` を `config.json` にコピーして編集してください。

```powershell
cp config.json.sample config.json
```

### 設定項目

- `Board`: デフォルトのターゲットボードを指定します (`core`、`core2`、`cores3se`)。
- `ArduinoDir`: Arduino ライブラリのルートパスを指定します。未指定の場合は `$HOME/Documents/Arduino` が使用されます。

### 優先順位

1. `build.ps1` 実行時の引数 (例: `-Board core`)
2. `config.json` 内の設定
3. `build.ps1` 内の既定値

## 使い方
```powershell
.\build.ps1
```

### ビルドのみ
```powershell
.\build.ps1 -SkipUpload
```

### ビルドと書き込み (COMポート指定)
```powershell
.\build.ps1 -Port COM5
```

### バイナリを build/ フォルダに出力する
```powershell
.\build.ps1 -ExportBinaries
```
`build/` フォルダに `.bin` が生成されます。書き込みはスキップされます。

### 旧 Core 向けにビルドする場合
```powershell
.\build.ps1 -Board core
```

### CoreS3 SE 向けにビルドする場合

```powershell
# SS/INT は、指定しない限り双方 CH2 になる
.\build.ps1 -Board cores3se -SkipUpload

# DIP設定を含むリリース用ファイルを出力
.\build.ps1 -Board cores3se -SsChannel 2 -IntChannel 2 -ExportBinaries
```

## CoreS3 SE + DualSense + LAN積層診断

`M5Stack-PS5CoRELanStackDiagnostic.ino` は、M5 CoreS3 SEにUSB Module v1.2（MAX3421E）とModule13.2 LAN（W5500）を積層し、共有SPI上でDualSense入力と固定周期UDP送信を同時に動かすための最小診断スケッチです。製品用通信プロトコルではありません。また、このスケッチは `cores3se` 専用です。

> CoreS3 SE積層診断が完了するまでは、CoreS3 SE＋USB Module v1.2＋LAN Module 13.2＋純正DualSenseのみを検証対象とする。Basic、Core2、既存Wi-Fi送受信スケッチ等の回帰検証は後続フェーズで実施する。

### 根拠資料と採用ピン

- [M5Stack Module USB v1.2公式資料](https://docs.m5stack.com/en/module/USB%20v1.2%20Module)
- [M5Stack Module13.2 LAN公式資料・回路図](https://docs.m5stack.com/en/module/LAN%20Module%2013.2)
- [M5Stack CoreS3公式M5-Bus表](https://docs.m5stack.com/en/core/CoreS3)
- [M5Stack公式Module13.2 LAN Arduino例](https://github.com/m5stack/M5Module-LAN-13.2)

両モジュールの `SCK/MOSI/MISO` は `GPIO36/GPIO37/GPIO35` を共有します。USBのCoreS3 SE既存設定はSS CH2=`GPIO1`、INT CH2=`GPIO14`です。LAN公式例のCoreS3既定CS=`GPIO1`はUSB SSと衝突するため使用せず、LAN基板のCSジャンパをもう一方のM5-Bus 23番へ切り替えて `GPIO13` を使用します。

Module13.2 LANの回路図上のGPIO名は従来CoreのM5-Bus名です。次表では物理的なM5-Busピン番号を介してCoreS3 SEのGPIOへ読み替えています。実装値は診断スケッチ先頭の `DiagnosticConfig` に集約しています。

| 対象 | 信号 | 採用する設定 | M5-Bus | CoreS3 SE GPIO | 競合回避・根拠 |
|:---|:---|:---|:---:|:---:|:---|
| USB v1.2 | SS | `SS CH2`のみON（CH1/CH3はOFF） | 20 | G1 | 既存CoreS3 SE実装とUSB Host Shield Library 2.0 PR #843相当の設定 |
| USB v1.2 | INT | `INT CH2`のみON（CH1はOFF） | 26 | G14 | 同上 |
| LAN 13.2 | CSN | M5-Bus 23番側（回路図上の `GPIO15` 側） | 23 | G13 | LAN標準候補のM5-Bus 20番/G1はUSB SSと衝突するため不採用 |
| LAN 13.2 | INTN | M5-Bus 2番側（回路図上の `GPIO35` 側） | 2 | G10 | M5-Bus 26番/G14はUSB INTと衝突するため不採用 |
| LAN 13.2 | RSTN | M5-Bus 24番側（回路図上の `GPIO0` 側） | 24 | G0 | USBと非競合で、公式CoreS3例のRESET設定を維持 |
| 共有 | SCK / MOSI / MISO | 固定 | 11 / 7 / 9 | G36 / G37 / G35 | CoreS3公式M5-Bus SPI |

> [!CAUTION]
> 電源を切った状態でジャンパ／DIPを変更してください。LAN基板のジャンパ向きは基板の表裏やロットで見え方を取り違えやすいため、「左右」ではなく上表のM5-Busピン番号とテスターの導通で確認してください。同一信号の2候補を同時に短絡しないでください。

LAN CSのG13は`I2S_DOUT`、LAN RESETのG0は`I2S_LRCK`、USB INTのG14は`I2S_DIN`と兼用です。このため、診断スケッチは `M5.begin()` より前に `M5.config()` の `internal_spk` と `internal_mic` の双方を無効にし、内蔵音声機能との競合を避けます。LAN INTは競合確認のため非重複ピンへ配線しますが、現在使用する `M5-Ethernet` はポーリング動作のため割り込み処理には使用しません。

### 診断設定

ネットワーク値、送信周期、LANピン、入力有効期限、診断モード、初期化順序は、すべて `M5Stack-PS5CoRELanStackDiagnostic.ino` 冒頭の `DiagnosticConfig` にあります。診断モードと初期化順序は独立して変更できます。

| 設定 | 初期値 |
|:---|:---|
| M5Stack IP / subnet | `192.168.50.10/24` |
| Gateway / DNS | `192.168.50.1` |
| 送信先 | `192.168.50.20:50000` |
| ローカルUDP port | `50000` |
| UDP送信周期 | `20 ms` |
| 入力有効期限 | 最終HID受信から `500 ms` |
| 診断モード | `FullUdp` |
| 初期化順序 | `UsbThenLan` |

| 診断モード | LAN RESET | LAN用`SPI.begin`／Ethernet初期化 | 周期的link取得 | UDP |
|:---|:---:|:---:|:---:|:---:|
| `UsbOnlyWithLanHeldReset` | LOW保持 | なし | なし | なし |
| `LanInitializedNoRuntimeAccess` | 初期化時に解除 | あり | なし | なし |
| `LanLinkStatusOnly` | 初期化時に解除 | あり | あり | なし |
| `FullUdp` | 初期化時に解除 | あり | あり | 20ms周期 |

| 診断モード | USB認識の期待値 | W5500表示 | Link表示 | UDPの期待値 |
|:---|:---|:---:|:---:|:---|
| `UsbOnlyWithLanHeldReset` | DualSenseを継続認識 | `SKIP` | `SKIP` | 送信なし、カウント0 |
| `LanInitializedNoRuntimeAccess` | DualSenseを継続認識 | `OK` | `SKIP` | 送信なし、カウント0 |
| `LanLinkStatusOnly` | DualSenseを継続認識 | `OK` | LAN接続時`ON` | 送信なし、カウント0 |
| `FullUdp` | DualSenseを継続認識 | `OK` | LAN接続時`ON` | 20ms周期で`UDP OK`増加 |

診断モードを変更する場合は、次の1行を変更して再ビルドします。

```cpp
constexpr DiagnosticMode kDiagnosticMode = DiagnosticMode::UsbOnlyWithLanHeldReset;
```

初期化順序を反転する場合は、次の1行だけを変更して再ビルドします。

```cpp
constexpr InitializationOrder kInitializationOrder = InitializationOrder::LanThenUsb;
```

USB HostまたはW5500の初期化が失敗しても停止せず、もう一方の初期化と画面／シリアル診断を続行します。

### 診断UDPパケット

パケットはリトルエンディアン固定長24バイトです。`reserved0` はゼロで、将来の製品プロトコルとの互換性は保証しません。

| Offset | Size | Field | 内容 |
|---:|---:|:---|:---|
| 0 | 4 | `magic` | ASCII `M5DS` |
| 4 | 1 | `version` | `1` |
| 5 | 3 | `reserved0` | `0` |
| 8 | 4 | `sequence` | 送信試行ごとに増加 |
| 12 | 4 | `uptime_ms` | `millis()` |
| 16 | 2 | `button_bits` | 下記ボタンビット |
| 18 | 1 | `dpad` | DualSense hat値 `0..7`、中立=`8` |
| 19 | 1 | `left_x` | `0..255` |
| 20 | 1 | `left_y` | `0..255` |
| 21 | 1 | `right_x` | `0..255` |
| 22 | 1 | `right_y` | `0..255` |
| 23 | 1 | `input_valid` | DualSense接続中かつ最終HID受信から500ms以内なら `1` |

`button_bits` はbit 0から順に Cross、Circle、Square、Triangle、L1、R1、L2、R2、Share、Options、PS、Touchpad、L3、R3です。

`input_valid=0`の場合、`button_bits=0`、`dpad=8`、4軸=`0x80`となり、送信データ本体も中立値になります。受信側は`input_valid=0`のパケットを操作指令として使用してはなりません。

`UDP OK` はW5500へパケットを渡せた回数であり、送信先アプリでの受信を保証する値ではありません。ケーブル切断は別途 `Link` で確認してください。`UDP FAIL` はソケット未初期化、`beginPacket`、書き込み、または `endPacket` の失敗回数です。

#### FullUdpのLink OFF時動作

`FullUdp`でもLinkが`ON`でない場合（`OFF`、`UNKNOWN`、またはLink取得を行わない`SKIP`相当）は、`udp.beginPacket()`、`udp.write()`、`udp.endPacket()`を呼びません。この場合は`UDP SKIP`だけが増加し、意図的に送信しなかった回数を`UDP FAIL`へ加算しません。Link OFF中もUSB HID処理と画面更新が通常速度を維持することを期待します。

Link状態は画面描画およびUDP送信とは独立して250ms周期で再確認します。Linkが`ON`へ復帰すると20ms周期のUDP送信を再開しますが、Link OFF中の未送信分は蓄積せず、復帰時に連続送信しません。

#### 追加診断値

実際にUDP送信を試行したとき、`micros()`で`beginPacket()`、`write()`、`endPacket()`、UDP処理全体の直近所要時間と最大所要時間を個別に計測します。Link OFFによるスキップでは直近値と最大値を変更しません。さらに、1秒ごとの`loop()`回数と`Usb.Task()`呼出し回数をカウンタ差分で記録し、UDP処理によるUSB処理の飢餓を確認できるようにします。

### 再現ビルド

必要ライブラリは `M5Unified`、`USB Host Shield Library 2.0`、LAN診断／Sender／Receiverの場合は `M5-Ethernet@4.0.0` です。`build.ps1` は既存どおり `m5stack:esp32@3.3.7` を使用し、不足ライブラリをArduino CLIで導入します。`M5-Ethernet` が未導入の場合は4.0.0を導入しますが、異なるバージョンが既に存在する場合は共有ライブラリ環境を上書きせず、必要版・現在版・パスを表示してエラー終了します。

```powershell
# ビルドのみ
.\build.ps1 -Board cores3se `
  -SketchName M5Stack-PS5CoRELanStackDiagnostic.ino `
  -SsChannel 2 -IntChannel 2 -SkipUpload

# ビルドして指定ポートへ書き込み
.\build.ps1 -Board cores3se `
  -SketchName M5Stack-PS5CoRELanStackDiagnostic.ino `
  -SsChannel 2 -IntChannel 2 -Port COM9

# 診断用の名前付きbinをbuild/へ出力
.\build.ps1 -Board cores3se `
  -SketchName M5Stack-PS5CoRELanStackDiagnostic.ino `
  -SsChannel 2 -IntChannel 2 -ExportBinaries
```

### 画面・シリアル表示

画面と115200bpsのUSBシリアルへ、USB Host初期化、HIDパーサ取付結果、DualSense接続、VID/PID、HID受信回数、最終HID受信時刻と経過時間、W5500初期化、Ethernetリンク、設定IPと実IP、IP一致判定、UDP socket状態、UDP成功／失敗／Link OFFスキップ回数、シーケンス、稼働時間、ESP32リセット理由、`input_valid` を表示します。画面にはさらにUDP総処理時間の直近値／最大値、実経過時間で正規化した`loop()`回数/秒と`Usb.Task()`呼出し回数/秒を表示します。

IP表示の`IP cfg`はスケッチで指定した固定IP、`IP act`はW5500から読み出した実IP、`IP check`は両者の一致判定です。`IP check=FAIL`の場合はUDP socketを開始しません。`IP act=0.0.0.0`は有効な固定IP設定がW5500から読み出せていない状態であり、`ping 0.0.0.0`はM5Stackとの疎通確認として扱いません。疎通確認対象は`192.168.50.10`です。

UDP socket表示は、UDP無効、W5500未初期化、IP不一致などで`udp.begin()`を実施していない場合は`SKIP`、実施して成功した場合は`OK`、実施したが失敗した場合は`FAIL`です。

`UDP OK` はあくまでW5500側の送信処理成功回数であり、送信先Raspberry Piでの受信を保証しません。到達確認にはRaspberry Pi側の受信ログを使用します。

シリアルの定期状態行は`[STATUS]`で始まり、パーサ状態は`PARSER=OK`または`PARSER=FAIL`で表示されます。詳細な性能行は`[PERF]`で始まり、UDP各処理と総処理の直近値／最大値（マイクロ秒）、`LOOP_PER_SEC`、`USB_TASK_PER_SEC`を出力します。画面とログはキャッシュ済み診断値だけを参照し、表示処理から`Ethernet.*`または`udp.*`を呼びません。

### 次の実機試験

#### 試験5-A: Link OFF

期待値:

```text
LINK=OFF
UDP_OK=0
UDP_FAIL=0
UDP_SKIP=増加
HIDカウント=通常速度で増加
VID=054C
PID=0CE6
READY_DROP=0
画面更新=通常速度
```

#### 試験5-B: Link ON、受信側なし

- LANケーブルをリンク成立するスイッチまたはPCへ接続する。
- 送信先アプリは起動しない。
- UDP各処理／総処理の所要時間とHID更新頻度を確認する。

#### 試験5-C: Link ON、受信側あり

- 送信先を`192.168.50.20/24`に設定する。
- UDP port `50000`を使用する。
- 24バイトパケットを約20ms周期で受信する。
- HID更新、UDP送信、画面更新が同時に継続することを確認する。

### 実機試験チェックリスト

以下の10分、60分、15分試験は、前段の切り分けで`FullUdp`モードまで到達し、USB認識、W5500初期化、Link取得、UDP送信が同時に成立した後に実施します。

- [ ] 電源OFFでUSB DIPがSS CH2／INT CH2のみONであることを確認する。
- [ ] 電源OFFでLAN CSN/INTN/RSTNが上表のM5-Bus 23/2/24番へ導通し、G1/G14と短絡していないことを確認する。
- [ ] LAN、USB、CoreS3 SEの積層方向、ピンずれ、スペーサー、給電方法を確認してから電源を入れる。
- [ ] 起動ログの `RESET` が想定理由で、初期化順序が `USB->LAN` と表示されることを確認する。
- [ ] `USB_INIT=OK`、`PARSER=OK`、`W5500_INIT=OK`、IP=`192.168.50.10` を確認する。
- [ ] LANケーブル接続時に `LINK=ON`、抜線時に `LINK=OFF` へ変化することを確認する。
- [ ] 純正DualSenseをUSB有線接続し、VID=`054C`、PID=`0CE6`、`DS=CONNECTED` を確認する。
- [ ] DualSense操作中にHID受信回数と最終HID時刻が更新され、`INPUT_VALID=1` になることを確認する。
- [ ] 送信先 `192.168.50.20:50000` で24バイトを約20ms周期に受信し、magic/version/sequence/各入力値を確認する。
- [ ] LANリンクありで `UDP_OK` が増加し、`UDP_FAIL` が連続増加しないことを確認する。

#### 段階1: 10分間のスモークテスト

- [ ] USB Host、HIDパーサ、W5500の初期化失敗がない。
- [ ] HID受信回数と最終HID時刻の更新停止がない。
- [ ] Ethernetリンク状態に異常がない。
- [ ] WDT／brownoutを含む意図しないリセットがない。

#### 段階2: 20ms周期・50Hz・60分間の必須耐久試験

- [ ] `kUdpIntervalMs=20`で60分間継続し、意図しない再起動が0回である。
- [ ] DualSense HID入力とUDP送信が同時に継続する。
- [ ] 受信側でシーケンスから欠損数を記録する。
- [ ] 受信側で最大受信間隔を記録する。
- [ ] 受信側で受信間隔の99パーセンタイルを記録する。

#### 段階3: 10ms周期・100Hz・15分間の開発目標試験

- [ ] 段階2の必須耐久試験に合格した後でのみ実施する。
- [ ] `kUdpIntervalMs=10`へ変更し、15分間HID入力とUDP送信が同時継続することを確認する。
- [ ] 試験後は`kUdpIntervalMs=20`へ戻す。

初期化順序を `LanThenUsb` に変更する試験は、上記の既定順序試験結果を記録した後に同じCoreS3 SE積層構成で実施します。

### この診断追加の変更ファイル

- `M5Stack-PS5CoRELanStackDiagnostic.ino`（新規）
- `build.ps1`（診断スケッチ選択、CoreS3 SE限定チェック、`M5-Ethernet@4.0.0`、診断bin名）
- `README.md`（本手順）

### 現フェーズのビルド確認

CoreS3 SE積層診断スケッチの `cores3se` ビルドのみを実施します。Basic、Core2、既存Wi-Fi送受信、Switch向けスケッチの回帰ビルドは後続フェーズで実施します。

### 未確認事項

- CoreS3 SE、USB Module v1.2、Module13.2 LAN、純正DualSenseを実際に積層した電気的・機械的動作。
- G13をLAN CSへ切り替えた状態での各Module13.2 LAN基板ロットのジャンパ表示と導通。
- MAX3421E、W5500、LCDが共有するSPI上での長時間安定性と20ms周期の実効ジッタ。
- USB給電、LAN ModuleのDC入力、DualSenseの消費電流を含む安全な給電構成とbrownout余裕。
- DualSenseのPIDが `0CE6` 以外となる純正リビジョン。未知PIDはVID/PIDを表示しますが `DS=CONNECTED` にはしません。
- `LanThenUsb` 順序での実機結果。
- DualSense Wi-Fi TransmitterのArduino CLI待機問題と、Wi-Fi Receiverを含む既存スケッチの回帰ビルド。いずれも後続フェーズの対象です。
- CoreS3 SE以外の実機動作（この診断スケッチはビルド対象外）。

## CoreS3 SE 有線LAN Sender／Receiver

製品用LANスケッチは次の2ファイルです。

- `M5Stack-PS5CoRELANSender.ino`: `192.168.50.10`で待受けるTCP server
- `M5Stack-PS5CoRELANReceiver.ino`: `192.168.50.20`からSenderへ接続するTCP client

製品通信は既存Wireless実装をそのまま引き継ぎ、TCP port `12345`、20文字ASCII `BB,BB,DD,LX,LY,RX,RY`とLF区切りを使用します。診断スケッチのUDP port `50000`／24バイト`M5DS`パケットはネットワーク診断専用であり、製品プロトコルではありません。事実ベースの比較は `docs/lan-protocol-reuse-analysis.md` を参照してください。

```powershell
# LAN Sender
.\build.ps1 -Board cores3se `
  -SketchName M5Stack-PS5CoRELANSender.ino `
  -SsChannel 2 -IntChannel 2 -SkipUpload

# LAN Receiver
.\build.ps1 -Board cores3se `
  -SketchName M5Stack-PS5CoRELANReceiver.ino `
  -SsChannel 2 -IntChannel 2 -SkipUpload
```

Windows試験ツールは `tools/lan_test/` にあります。`udp_receiver.py` は診断UDP、`core_protocol_receiver.py` はLANSender、`core_protocol_sender.py` は一時IPでビルドしたLANReceiverの単体試験に使用します。LANReceiverの最終既定IPはWindowsと同じ `192.168.50.20` なので、最終バイナリを現在の単体構成へ書き込んで試験しないでください。

## ライセンス

[MIT License](LICENSE)

Copyright (c) 2026 Noriki Nakamura
