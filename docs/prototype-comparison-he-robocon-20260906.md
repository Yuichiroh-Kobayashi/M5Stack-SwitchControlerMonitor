# he-roboconプロトタイプと現行CoRE実装のコード比較

2026-09-06。結論は、**プロトタイプを独立した動作比較用実装として活用し、SPI設定・依存ライブラリ差を優先調査する。一括で製品実装へ置き換える段階ではない**。

プロトタイプはHORIのHIDをUDPで往復させる小さな構成として読みやすい。現行実装より機能が少ないことは、問題切り分けでは利点になる。一方、controller同定・入力鮮度・sequence拒否・ロボットへのUART出力は製品要件まで実装されていない。現行側にもHORI製品profileとUART安全出力の未完事項があり、現行全体をそのまま優位と評価する比較ではない。

## 比較対象と確認範囲

- 外部: `he-robocon/CoRE_WirelessSender`、master取得時commit **`e55449ea65c6477caad7262f1e3d4abf707b8f03`**。以降のリンクはこのcommit固定。
- ローカル: branch `feat/cores3se-dualsense-lan-stack-diagnostic`、HEAD **`f915b1c9a33693a2010a1d9527b23743707cfa5d`** ＋現在のworking tree。製品Sender/Receiver、legacy HORI parser、CoreProtocol、隔離UHS/M5-Ethernetを比較。
- 外部の独自runtime codeはSender、Receiver、USB probe、CoreLanProtocol、CoreControllerUiの5ファイルを全文確認。READMEとUHSのpin/SPI/settings/versionを確認。取得11ファイルはGit blob SHAを照合。
- 同梱UHS全driverの網羅reviewではない。EthernetはREADME指定の公式2.0.2 sourceを参照したもので、相手が実際にbuildした依存path/board core/ELFとは未照合。
- 実機接続、controller VID/PID、連続時間、link speedのraw証拠は今回未取得。READMEの中立値・対象機種記述は作者の記載として扱う。正常動作画面の表示条件だけではdurability PASSとしない。

出典: [README](https://github.com/he-robocon/CoRE_WirelessSender/blob/e55449ea65c6477caad7262f1e3d4abf707b8f03/README.md)、[Sender](https://github.com/he-robocon/CoRE_WirelessSender/blob/e55449ea65c6477caad7262f1e3d4abf707b8f03/sender/sender.ino)、[Receiver](https://github.com/he-robocon/CoRE_WirelessSender/blob/e55449ea65c6477caad7262f1e3d4abf707b8f03/receiver/receiver.ino)、[protocol](https://github.com/he-robocon/CoRE_WirelessSender/blob/e55449ea65c6477caad7262f1e3d4abf707b8f03/libraries/CoreLanProtocol/src/CoreLanProtocol.h)、[UI/parser](https://github.com/he-robocon/CoRE_WirelessSender/blob/e55449ea65c6477caad7262f1e3d4abf707b8f03/libraries/CoreControllerUi/src/CoreControllerUi.h)。

## 構成の比較

| 項目 | プロトタイプ | 現行CoRE |
|---|---|---|
| 主目的 | HORI raw inputのLAN転送・画面確認・echo RTT | 正規化CONTROL/STATUSとUARTへの製品経路、別系統の原因調査 |
| HORI mapping | UIのdecodeに実装。raw先頭7byteの配置はlegacyと一致 | legacyでUSB検証済み。製品SenderはDualSense専用のまま |
| LAN payload | packed struct 28 bytes、HID8 bytes入り | 明示byte encodeの32 bytes、CRC-16/CCITT-FALSE |
| endian/sequence | native endian、uint32 sequence | big-endian、uint16 sequence、wrap/duplicate/reverse判定 |
| IP/port | .10 subnet、Sender5001 / Receiver5000 | .50 subnet、双方50001 |
| 送信周期 | 新しいHID callback世代があれば送る | CONTROL20ms、STATUS20ms |
| 返信 | packet typeをACKへ変えてecho | 受信validity/timeout/counterを含むSTATUS |
| timeout | 500msで画面の状態文字を切替 | input/peer100ms。UART安全出力に既知の不足あり |
| Receiver UART | 無し。Serialにdebug textを出す | Port C TX17/RX18、115200 8N1、32-byte binary |
| Sender LAN CS / USB CS,INT | 13 / 1,14 | 同じ |
| Receiver LAN CS | **1**（header既定） | **13** |
| USB init順 | LAN→USB | LAN→USB |
| Ethernet依存 | Arduino Ethernet2.0.2 | M5-Ethernet4.0.0 |
| M5Unified | README0.2.21 | 検証baseline0.2.19 |
| board/power | CoreS3表記。SE、Bottom、電源条件未確認 | 製品CoreS3 SE+Bottom3、診断は個別freezeの構成がauthority |

名前はWirelessSenderだが、このプロトタイプのSender/Receiver経路は有線Ethernet UDP。既存のLAN製品やQUESTiX UARTとそのまま通信できるwire formatではない。ReceiverのCSも異なるので、現在の機器へそのままuploadする比較は不可。

## 安定性調査に重要な差

### 1. SPI要求クロックが異なる

| 経路 | プロトタイプ側のsource設定 | 現行隔離依存のsource設定 |
|---|---|---|
| MAX3421E regRd/regWr/bytesRd/bytesWr | **8 MHz** | **26 MHz** |
| W5500通常socket操作 | Ethernet2.0.2の **14 MHz** | M5-Ethernet4.0.0の **26 MHz** |
| W5500 TX buffer write | 2.0.2では上記transaction内 | `write_data()` がtransactionを閉じ **40 MHz** で再開 |
| PHY読み・IP等の直接設定 | sketch明示8 MHz | 診断/製品ごとに実装を確認する必要あり |

これはSPISettingsに要求する値の比較であり、SCK波形の実測ではない。プロトタイプ全体が8 MHz動作という説明は誤り。W5500のUDP APIはlibrary側の設定を使う。

UHS差分ではCoreS3 pin mappingはほぼ共通。主な差は4か所の26→8 MHzと `USB_SPI.begin(36,35,37,1)` の明示指定だった。現行のgeneric ESP32用pin拡張差はCoreS3分岐では使われない。

現行M5-Ethernetの `socketBufferData()`→`write_data()` はUDP送信でも通るため、40 MHzは未使用定数ではない。この差は「applicationを小さくした」以外の有力な比較軸になる。速度を下げればSPI時間は増えるので、電気的余裕とscheduler負荷の両方が変わる。root causeがクロック・EMI・電圧だと断定はできない。

出典: [prototype usbhost.h](https://github.com/he-robocon/CoRE_WirelessSender/blob/e55449ea65c6477caad7262f1e3d4abf707b8f03/libraries/USB_Host_Shield_Library_2.0/usbhost.h)、[Ethernet2.0.2 SPI settings](https://github.com/arduino-libraries/Ethernet/blob/2.0.2/src/utility/w5100.h)、[socket implementation](https://github.com/arduino-libraries/Ethernet/blob/2.0.2/src/socket.cpp)。ローカルauthorityは `build-temp/usb-lan-isolation/libraries/M5-Ethernet/src/{socket.cpp,utility/w5100.h}`。

### 2. ライブラリ切替にはクロック以外の差もある

M5-Ethernet4.0.0とEthernet2.0.2ではSPI初期化、待ち時間、transfer API等も異なる。現行M5版はW5100 init内の `SPI.begin()` がコメントアウトされ、prototype側UHSはpin指定beginを持つ。library一括交換で改善しても、クロックだけの効果とは判定できない。

両系列の `parsePacket()` は前回payload残留をnull-readで退役させる。Ethernet2.0.2の `flush()` は空実装で、prototypeの `udp.flush()` がRX残留を消しているわけではない。正常28-byte readで残留は無くなるが、長いdatagram等の残りは次parseで扱われる。従来調査の「parseはheader-onlyではない」という注意は引き続き有効。[EthernetUdp.cpp](https://github.com/arduino-libraries/Ethernet/blob/2.0.2/src/EthernetUdp.cpp)

### 3. full payload RXを既に含むが、DG-Dの直接対照ではない

prototype SenderはACK28 bytesをnon-null bufferへ読み、Receiverもpayloadを読み込む。もし長時間安定しているraw証拠が得られれば、別実装条件での重要な対照になる。

ただしDG-DはFixed10Half、診断32-byte payload/50Hz/固定peer/health cadence。一方prototypeは28-byte raw HID、callback依存rate、別library/SPI/UI、PHY固定処理無し。双方の結果だけでC2 failureの要因を1つに絞れない。既存non-null read設計は、同じ基底で処置を分ける役割が残る。

## 製品へ使う前に補う点

### A. controller identityと入力鮮度

`ControllerHID::ParseHIDData()` はVID/PID・report IDを確認せず、任意HIDの先頭最大8 bytesを採用する。8 bytes超は切り詰めるため元report長も失われる。parser callbackでhasReport=trueとなり、disconnectでclearする経路やlast-valid-report ageがない。

最後の世代を送信済みならdetach後は通常新規送信が止まる。しかし未送信世代が残っていれば、送信条件にUSB ready/age検査が無いため古い状態を再送し得る。unsupported/invalid/disconnectedをneutralにする製品要件には未達。

対処は明示HORI profile（0F0D/0202、実report長/ID確認）、valid timestamp、100ms判定、loss時neutral、unsupported表示。汎用raw probeとしての利便性は診断側に残す。

### B. timeout表示と操作停止は別

Receiverは500msでRECEIVING→WAITING DATAになるが `lastHidReport` をneutral化せず、controller絵は最後の状態を表示し続ける。Sender側も最後のreportを描画する。現状はUART/robot制御が無いので「実機が動き続けた」とは言えないが、このbufferをそのままUARTへ接続してはいけない。

現行CoRE Receiverにも、timeoutでUIはneutralにしてもUARTへneutral frameを出さず、input-invalid non-neutral frameをそのままforwardする問題がある。双方とも下流停止経路の実装・実測が必要。[現行UART設計](uart-downstream-common-protocol-design.md)にその責務を整理済み。

### C. sequence/ACKの表示は受信品質を保証しない

`recordSequence()` は最初の500受信でlostCount=0にし続ける。501受信以降もduplicate/reverseを拒否せずlastSequenceを書き換え、既にlastReceiveMsとHIDを更新している。例: 600→599→601なら古い599を採用したうえで601でlossを誤計上し得る。起動時の基準化は初回1回で十分であり、最初の500packetの欠落を無かったことにしない方がよい。

Sender ACKはmagic/version/type/size/lengthのみで受け付け、remote tupleや送信済sequenceとの照合が無い。古いACKでもlastAckMsが更新され、RTTはechoされたuptimeとの差だけ。STREAMING表示やACK countを、最新controller入力の正常配送の証明として扱わない。

### D. 周期とUSB service budget

reportGenerationは「値が変わった時」ではなくHID callbackごとに増える。したがって送信は変化時限定でも50Hz固定でもなく、実際のUSB poll・loop処理に依存する。停止時の周期neutral/heartbeatも無い。

`receiveAck()` と `receiveControllerData()` はqueueが空になるまでwhile処理する。通常負荷では小さくても、backlog時にUSB Taskの間隔を伸ばし得る。現行製品の最大2packet/loop処理とUSB gap計測は取り込む価値がある。対策は受信budget・20ms schedulerと、その実測である。

Ethernet初期化に失敗した場合は2秒ごとのLAN reset/SPI beginを行う。USB稼働後にも実行し得るので、既存診断へ自動retry部分を無条件に移植しない。単なるLAN link downで必ずこのretryへ入るという実装ではない。USBの周期再Initは見当たらない。

### E. wire formatと検証再現性

packed structのmemoryを直接送る28-byte形式は、現行32-byte protocolと互換性がなく、application CRC/input-validも無い。同一ESP32同士ではlayoutが揃っても、他CPUへの展開ではbyte orderの明示が必要。protocol helperはreportLength=0〜8を許容し、HORIとして正常長かは検証しない。

READMEはM5Unified0.2.21/Ethernet2.0.2を指定するが、board coreとM5GFX version、実際のlibrary resolution/build hashは不明。同じ名前のUHSが複数ある環境ではbuildログで選択先を確認する。treeにはM5-Max3421E-USBShieldのgitlinkがあるが `.gitmodules` は無く、現在のsketch includeが使う同梱UHSとは別。再現手順の整理対象。

## QUESTiX / キットとの接続

raw HIDを7項目ASCII化するだけではQUESTiX互換にならない。例えばHORI raw byte0のbit2はAだが、QUESTiX byte0のbit2はX。raw byte1のHomeとLStick等も配置が違い、raw dpad0（上）はQUESTiXではneutralになる。

UIのdecodeは現在のlegacy HORI mappingと一致するので、その**意味状態**から既存CONTROL buttonsへ正規化し、UART境界でQUESTiX形式へ変換する案が適切。プロトタイプのUI/parser分離は移植の参考になるが、controller同定と安全neutralを加える。

キットはさらにwheel/pitch/lock/roller/shot配列への変換が必要。プロトタイプにはPort C送信・UART仕様がまだ無いため、前回の共通UART案を不要にする実装ではない。

## 推奨する進め方

1. **独立した比較用実装として保存する。** このcommit・相手のbuild依存・CoreS3/SE/Bottom/電源・HORI VID/PID・link speed・時間・HID/TX/ACK推移を揃える。CS1のReceiverを現在のCS13機体へ無確認でuploadしない。
2. **SPI差を独立した診断候補に加える。** 検証済み失敗条件の隔離copyで、まずUSB要求クロック26→8 MHzだけを変える案を設計する。次にW5500の通常/送信clockを別の処置として検討する。library交換・PHY設定・packet形式・rateまで同時に変えない。既存8MHz試験の有無はraw inventoryも照合し、重複trialを避ける。
3. **non-null read gateとの順序を実機証拠で決める。** 同等hardwareでprototypeが安定する証拠があればSPI差の比較を高優先にする。証拠がまだ無ければ、既存DG-D基底のnon-null設計を捨てずに併置する。今回新しい実機gateへ進む許可は得ていない。
4. **製品は良い部分を小さく取り込む。** HORIのdecode/UI分離・raw観測を参考にprofile化。現行の32-byte encode/CRC/sequence/50Hz/100msとbounded loopを維持し、両実装のUART安全不足を解消する。Ethernet2.0.2や低clockの採用は比較結果に基づく別変更。

プロトタイプの価値は、既存実装にないcontroller対応・低clock・別Ethernet実装を組み合わせた、理解しやすい比較対象を得られたことにある。動いた場合も「小さく書けば解決」「既存調査が不要」とは結論しない。同時に、現行の複雑な診断機能を製品側へ全部持ち込む必要もない。

## 実施記録と限界

今回追加したrepository fileは本比較文書のみ。取得source/11file hash inventory/USB差分は `build-temp/prototype-comparison-20260906/`。実装・設定・依存library・既存freezeを変更していない。

Git開始/終了: 上記branch/HEAD、既存未commit変更を維持。`git status -sb`、`git diff --stat`、`git diff --check`、`git rev-parse HEAD`実施。diff check exit0（既存LF→CRLF警告あり）。詳細stdoutは同directoryのinventory.json。

build/test: Git blob hash11件一致と静的source比較のみ。Arduino build、host動作test、実機screeningは未実施。相手の指定依存をglobal installしていない。新規HID/CONTROL/STATUS/CRC/sequence/timeout/link/reset実測counterは無し、実機時間0秒。試験比較のacceptanceは同条件・同期間・identity付きraw成立が前提。

事実はsourceに存在する経路・設定・不足。安定性への寄与は推論。SPI波形、電圧、EMI、実際のlink speedは未測定。機種/電源/依存/負荷が一致しない結果は不完全な比較として扱う。

COM open/upload、配線/DIP/stack変更、commit/push/PR/Slack投稿は行っていない。物理比較にはユーザーの機体・PnP・配線確認が必要。
