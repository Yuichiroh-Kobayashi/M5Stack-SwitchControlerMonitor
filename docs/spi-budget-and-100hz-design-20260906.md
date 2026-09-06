# 10ms周期のSPI帯域見積り・送信方式・Ethernet比較

2026-09-06。開発目標を **CONTROL 10ms周期＝100Hz** として評価する。結論は、**USB/LANの小packet通信の帯域要件だけでは26MHzは必要ない。通信デバイスの検証開始値は8MHz、条件付きの設計下限候補は4MHz**。ただしこれは実機で成立済みの下限ではない。LCD描画、API呼出し時間、USB/ネットワーク待ち、poll頻度を含む最悪実行時間は別に測る必要がある。

現在の製品20ms定数、protocol/timeout、ライブラリ、freezeをこの報告では変更していない。10msは今後の開発目標として扱う。SenderのHORI製品profile未実装とUART安全出力の未完事項も残る。

## 1. 前提と下限の意味

- 1台のSenderの共有SPIバスを計算対象とする。Receiverは別MCUなので、そのSPI転送をSenderへ再加算しない。
- CONTROL32 bytesを100回/秒送信、STATUS32 bytesを100回/秒受信する仮定。STATUSを現行50Hzに維持するなら、ここでのネットワーク負荷より小さい。
- USBはHORIの8-byte report、1 interrupt-IN endpointを想定。HID受信rateはLAN送信周期とは独立なので、100/125/250/1000Hzの条件を分ける。1000Hzは計算シナリオで、実機HORIで測った値ではない。
- normal SPIのSCKクロック数をbyte換算する。MISOの受信時に送るdummy byteをさらに別の8bitとして二重加算しない。
- ネットワークのARP/再試行、USB NAK/timeout、初期enumeration、その他endpoint、LCD、API overheadは正常最短経路のbyte数に入らない。これらが無制限なら、SPI周波数だけから10ms達成を保証できない。

MAX3421Eの26MHzはSPIの上限仕様であり、USB full-speedの12MbpsをSPIで常時流す義務ではない。W5500もEthernet frameの生成・受信をハードウェアで処理するため、SPIを100Mbpsへ合わせる必要はない。[MAX3421E仕様](https://www.analog.com/en/products/max3421e.html)、[W5500概要](https://docs.wiznet.io/Product/Chip/Ethernet/W5500?module=hat)

## 2. 実ソースに沿ったSPI byte数

### W5500: 32-byte送信＋32-byte受信で正常最短152 bytes

W5500の1アクセスはaddress/control計3 bytes＋data。単一packet、サイズレジスタが最初の2回で一致、command registerが最初のreadで0、SEND_OKが最初に成立、RX cacheが空から1packet入る場合を数える。

| 送信経路 | SPI bytes |
|---|---:|
| 宛先IP・port設定 | 7＋5＝12 |
| TX空き量の16-bit read×2 | 10 |
| TX write pointer read | 5 |
| payload write | 3＋32＝35 |
| TX write pointer更新 | 5 |
| SEND command write＋完了read | 8 |
| SEND_OK read＋clear | 8 |
| **送信小計** | **83** |

| 受信経路 | SPI bytes |
|---|---:|
| RX残量の16-bit read×2 | 10 |
| UDP packet-info 8 bytesをread | 3＋8＝11 |
| payload read | 3＋32＝35 |
| RX pointer更新 | 5 |
| RECV command write＋完了read | 8 |
| **受信小計** | **69** |

したがってLANだけの最短クロック帯域は `(83+69)×8×100 = 121,600 bit/s`。単純なpayload64 bytesだけから算出する51,200 bit/sより大きいが、MHz級の帯域には十分小さい。

RX残量cacheや連続packetによってRECV/pointer更新回数は変わるため、152は全状態での固定値でも最大値でもない。通常の単発往復シナリオの値である。[W5500 UDP packet-info](https://docs.wiznet.io/Product/Chip/Ethernet/W5500/Application/udp)、[Ethernet2.0.2 socket.cpp](https://github.com/arduino-libraries/Ethernet/blob/2.0.2/src/socket.cpp)

### MAX3421E: 8-byte reportの成功最短33 bytes

ローカルUHS1.7.0の `SetAddress()`→`InTransfer()`→`dispatchPkt()` をたどると、状態待ちのreadが1回で済む成功経路は12回の1-byte register accessとFIFO read1回になる。

`12×(command1＋data1)＋(command1＋report8) = 33 bytes/report`

追加のIRQ確認・NAK・再試行・USB Taskの他処理は別加算。report rateとphaseを考慮し、10ms window当たりのreport数を切り上げると次のようになる。

| 仮定HID rate | 10ms内report数 | LAN＋USB最短bytes | クロック時間だけの下限 |
|---|---:|---:|---:|
| 100Hz | 1 | 185 | 0.148MHz |
| 125Hz | 2 | 218 | 0.1744MHz |
| 250Hz | 3 | 251 | 0.2008MHz |
| 1000Hz | 10 | 482 | 0.3856MHz |

**この0.15〜0.39MHzを実用設定にしてよいという意味ではない。** CPU/待ち時間0、余裕0の計算値である。低周波数化により1回の転送が遅くなり、USB poll/状態待ち自体も変化し得る。

## 3. 余裕を割り当てた設計値

計画用に、通信SPIを **1000 bytes/10ms** 以内へ収める予算を仮置きする。

| 予算項目 | bytes/10ms |
|---|---:|
| LAN往復（152に追加余裕） | 200 |
| USB最大10 reports × 64 bytesの処理予算 | 640 |
| 追加の空受信poll最大10回 × 10 bytes | 100 |
| health等の追加枠 | 60 |
| 合計 | **1000** |

USBの64はreport payload長ではなく、8-byte reportとregister/追加readを合わせた仮の処理予算。**この表はソースから証明された最大値ではなく、測定して守れるか確認すべき予算**である。

共通クロックfで転送するとした概算は `T_SPI = 1000×8/f`。通信SPIのクロック時間に周期の25%＝2.5msを割り当てる案なら、

**f ≥ 8000 bits / 0.0025s = 3.2MHz**

| 通信SPIクロック | クロック時間/10ms | 占有率 |
|---|---:|---:|
| 1MHz | 8.00ms | 80% |
| 2MHz | 4.00ms | 40% |
| **4MHz** | **2.00ms** | **20%** |
| **8MHz** | **1.00ms** | **10%** |
| 14MHz | 0.571ms | 5.7% |
| 26MHz | 0.308ms | 3.1% |
| 40MHz | 0.200ms | 2.0% |

以上から、4MHzを検証する価値はあり、8MHzを最初の候補にするのが妥当。8→26MHzで節約できるクロック時間はこの予算で約0.69ms/10ms。26MHzを使い続ける帯域上の必然性は見当たらない。ただしAPI overheadや電気的実測が未確定なので、4MHzで必ず安定・10ms達成とは結論しない。

USBとLANは別々に設定できる。共有busであっても一律同じクロックにする必要はなく、実際には `8B_USB/f_USB + 8B_LAN/f_LAN` を加算する。SPISettingsの要求値と実SCKは分周の都合で異なり得るので、最終値は波形か実dividerでも確認する。

### 空pollを放置すると下限が変わる

cache空の `parsePacket()` はRX残量を少なくとも2回読むため、空確認1回でも約10 bytes。追加で1,000回/秒なら0.08Mbpsだが、10,000回/秒で0.8Mbps、100,000回/秒で8Mbpsになる。上記予算は空pollを最大1,000回/秒相当に制限した仮定である。

USBのHXFR完了待ち、W5500のSEND_OK/command待ちも回数可変。`beginTransaction()` の設定変更や関数呼出し時間はクロックbyte数に含まれない。

実際の期限条件は、各10ms windowで

`通信SPI時間＋LCD bus占有＋CPU/API処理＋USB/LAN待ち＋scheduler遅延 ≤ 10ms`

さらにUSBが必要とするservice間隔を満たすこと。SPI速度だけでは異常時のblockingを解決できない。

## 4. LCDは通信クロックと分ける

M5GFX0.2.26のCoreS3/SE設定ではLCDもSCK36/MOSI37を使い、GPIO35を外部MISOとLCD D/Cで切り替える。LCD write設定は40MHz。これはUSB8MHz/LAN8MHzへ下げる議論と分けて扱う。[M5GFX source](https://github.com/m5stack/M5GFX/blob/0.2.26/src/M5GFX.cpp#L1514)

RGB565で320×240全画面を送る例では153,600 bytes。転送だけで40MHzでも **30.72ms**、8MHzなら153.6msとなる。これは計算例で実測ではないが、全画面の連続転送は10ms deadlineより長い。prototype Senderは100msごとのfull sprite push、Receiverは33msごとのfull sprite pushなので、実際のpanel転送形式・bus保持時間を測る必要がある。spriteのRAM色深度8bitだけでpanelへの転送量も8bitになるとは仮定しない。

現行製品は描画phaseを分けているが、各phase内のfill/text描画の最大占有時間は未確認。更新頻度を落とすだけでは、更新時の長い占有は残る。

10ms化ではdirty領域・小さな描画単位への分割と、USB/送信の期限前に描画を始めない制御を優先する。例としてRGB565の320×3行なら40MHzで0.384msの転送計算となるが、API overheadも加えて実際の単位を決める。LCDも含めて全SPIを4〜8MHzへ統一する提案ではない。

## 5. 送信周期の設定方式

| 方式 | 通信速度・遅延 | 周期・安定性 | 評価 |
|---|---|---|---|
| 処理後 `delay(10)` | 周期は10ms＋処理時間 | USB/LAN/UIの処理量でrate低下 | 不採用 |
| `next = now + 10ms` | 実装が簡単 | 遅延のたび位相が後ろへずれる | 固定位相目標には弱い |
| **絶対期限を10msずつ進める** | 100Hz上限、直前の最新入力を送る | deadline missを数え、遅れをburst再送しない | **推奨** |
| HID callbackごとの送信 | 入力到着からの待ちを小さくできる | HID rate・NAK・loop負荷で送信rate変動 | raw診断には便利 |
| 変化時のみ送信 | 最小通信量 | 無変化と断線を区別できずheartbeatが別途必要 | 単独採用しない |

現行 `sendAtMostOneControlFrame()` は既に絶対期限を進め、遅延slotをskipしてcounterを増やす方式。製品10ms化の基礎として適している。送信直前に最新の有効入力をsnapshotし、古い入力queueを順番に送らない。USB pollは10msごとに間引かず、deviceの必要間隔でserviceする。

prototypeのreportGenerationは「変化」だけでなく全HID callbackで増える。HID1000HzならLANも最大でそのrateに近づき得る。固定100HzはLAN負荷を予測可能にする一方、HID受信から送信まで0〜10ms（位相が一様なら平均5ms）の待ちが増える。現在の20ms固定ではその部分が0〜20ms、平均10msなので、10ms化には入力待ち短縮の意味がある。

同じreportの定期再送は新しいHID入力が来た意味ではない。last-valid-HID時刻を再送で更新せず、timeout時にはneutralを送る。100ms timeoutを10msへ連動して短縮する提案ではない。短いbutton pulseの取りこぼしは別途確認する。

FreeRTOSを使う場合も絶対期限型のdelay-untilが同じ考え方だが、現行の単一loopでも実装可能。timer ISRからSPI/UDP/UIを直接呼ばず、共有busの所有を一元化する。複数task化だけでdeadlineやSPI干渉は解決しない。[FreeRTOS periodic scheduling](https://github.com/FreeRTOS/FreeRTOS-Kernel-Book/blob/main/ch04.md)

## 6. Ethernetライブラリを速度と安定性で比較

比較したのはローカルのexact M5-Ethernet4.0.0と、公式Arduino Ethernet2.0.2の `EthernetUdp.cpp / socket.cpp / utility/w5100.{h,cpp}`。prototypeの実際のboard core/library選択までは未照合。

| 項目 | Ethernet2.0.2 | M5-Ethernet4.0.0 | 意味 |
|---|---|---|---|
| 通常SPI要求 | 14MHz | 26MHz | 小packetでは高周波数の節約時間は小さい |
| TX payload | 14MHz。buffer対応macroが無ければbyteループ | `transferBytes`、40MHzへ切替 | M5版はTX高速化志向。切替overheadとbus条件も変化 |
| W5500 RX payload | buffer単位 `SPI.transfer(buf,len)` | 1byteずつ `SPI.transfer(0)` | **低周波数の2.0.2がCPU処理まで必ず遅いとは限らない** |
| 初期化待ち | 560ms | 20ms | 起動・再初期化差。定常100Hzの転送周期とは別 |
| SPI初期化 | W5100 init内で `SPI.begin()` | 同箇所はコメントアウト | shared bus初期化順に影響し得る |
| UDP上位処理 | parse/read/send、RX cache/RECV | 比較範囲はほぼ同じ | 全く別のUDPアルゴリズムではない |
| UDP `flush()` | 空実装 | 空実装 | RX残留退役は次parseのnull-read等による |

32-byte payloadのRXだけでも、2.0.2のbuffer呼出し1回に対してM5版はbyte呼出し32回。実CPU時間はArduino coreや最適化で変わるのでbenchmarkが必要だが、MHzだけで性能順位を決められない。

M5版の通常SPI定数だけを8MHzへ変えてもTXは40MHzのまま。低clock試験では **通常・TX用の両設定と実際のcall path** を記録する。sketch外側の `SPI.beginTransaction(8MHz)` で包んでも、内側のlibrary transactionが別設定を使うので、一括8MHz化にはならない。

出典: [Ethernet2.0.2 w5100.cpp](https://github.com/arduino-libraries/Ethernet/blob/2.0.2/src/utility/w5100.cpp)、[SPI settings](https://github.com/arduino-libraries/Ethernet/blob/2.0.2/src/utility/w5100.h)、[UDP実装](https://github.com/arduino-libraries/Ethernet/blob/2.0.2/src/EthernetUdp.cpp)。ローカルexact source hashesは検証directoryに保存した。

低clock化でMISO samplingの時間余裕は増え得るが、立上り時間・反射・電源・CS/GPIO35切替の問題が必ず消えるわけではない。逆にbyteごとの処理時間が増えてUSB service gapが悪化する可能性もある。26MHzは過剰帯域の可能性が高いが、現在のdetachの原因が26MHzだという証拠はまだない。[Espressif SPI transaction/timing説明](https://docs.espressif.com/projects/esp-idf/en/release-v5.3/esp32s3/api-reference/peripherals/spi_master.html)

## 7. Ethernet線上速度はボトルネックか

32-byte UDP payload、IPv4 options/VLANなしでは、preamble/SFD8＋Ethernet header14＋IP20＋UDP8＋data32＋FCS4＋IFG12＝98 byte相当/packet。Ethernet framingの根拠は [Microchip Ethernet frame資料](https://ww1.microchip.com/downloads/en/devicedoc/39935b.pdf) と [96 bit-timeのinterframe gap](https://onlinedocs.microchip.com/oxy/GUID-4D282FC5-82FC-4934-8BAD-D4A5D8422E6C-en-US-7/GUID-53D555E8-77F3-4DF4-A323-EE206DD5D1E1.html)。

100Hz片方向で78.4kbps、往復でも **156.8kbps**。10Mbps half-duplexに対する合計占有は理論約1.57%（collision/ARP/他traffic等を除く）。100Mbpsへ上げないと10ms周期の帯域が足りない状況ではない。

1frame分の線上時間は10Mbpsで78.4µs、100Mbpsで7.84µs。差は約70.6µsであり、10ms周期の主要因ではない。ただしhubのqueue、ARP、link変動、peer処理時間を含むRTTとは別の数字。

Fixed10Halfを製品設定へ採用済みという意味ではない。既存のPHYに関する失敗証拠を保持し、SPI clockとPHY link speedは別因子として比較する。

UARTも参考として、115200 8N1で21-byte ASCIIは1.823ms/行、32-byte binaryは2.778ms/frame。100Hzは帯域内だが、buffer満杯時のblockingとneutral出力を確認する。共通ASCII案はまだ未採用。

## 8. 開発方針と受入測定

推奨設定方針は **固定10ms、USBは8MHzから検証、LANも8MHz候補を独立検証、LCDは既存設定を保って占有を分割**。4MHzは8MHzで余裕・品質が確認できてから下限確認する候補。1〜2MHzは計算予算上の余裕が小さく、最初の標準値にはしない。

最初からlibraryを交換せず、隔離された現行依存でUSB clockだけを変え、その後LAN通常/TX clockを切り分ける。同等clock・同等10ms rate・同じPHY/packet/UI条件でEthernet2.0.2と比較すれば、library実装差を見やすくできる。26MHz＋20msと8MHz＋10msを比べてclock効果だけと呼ばない。

必要な測定は次のとおり。

- 送信予定時刻と実送信時刻、packet間隔のmin/median/p99/max、deadline miss/skip。平均100Hzだけでは合格にしない。
- USB Task duration/max gap、HID report間隔/age、ready drop/stall、実VID/PID/report長。
- SPIごとの実byte数、transaction数、busy/empty poll回数、SCK/CS、LAN通常とTXの実clock。
- UDP begin/write/endとparse/readの最大時間、TX/RX実数、CRC/sequence/timeout、link/reset。
- UI1回のbus占有、最長連続占有、UI有無での期限差。LANが正常でも全画面描画時に10msを超えれば要改善。

通常負荷で1000-byte予算と10ms期限を守れるかをまず確認し、fault時にblockingでneutral処理が遅れないかを別gateで確認する。許容jitterの数値は未指定なので、例えば±1msを既に合意済みの基準とはしない。まず実測分布とmiss0を確認し、ロボットの要求に合わせ許容値を確定する。

新firmware/build・物理gateはこの報告では未実施。HORI製品profile→USB-only mapping→LANという既存の順序を守り、diagnostic clock比較を製品PASSと混同しない。global libraryの書換え・upgradeや自動resetは行わない。

## 9. 再現と実施記録

- branch: `feat/cores3se-dualsense-lan-stack-diagnostic`
- HEAD: `f915b1c9a33693a2010a1d9527b23743707cfa5d`
- 比較prototype: `he-robocon/CoRE_WirelessSender` commit `e55449ea65c6477caad7262f1e3d4abf707b8f03`
- 固定baseline: M5Stack core3.3.7 / M5Unified0.2.19 / M5GFX0.2.26 / M5-Ethernet4.0.0 / isolated UHS1.7.0。prototype READMEはM5Unified0.2.21/Ethernet2.0.2、実coreは不明。
- 計算: `python -B build-temp/spi-100hz-budget-20260906/calculate.py`。数値と前提は同directoryの `calculation.json`、source identityは `source-hashes.csv`。
- 追加repository fileは本文書。既存source変更なし。Git開始前status/diff/stat/HEADを確認、終了diff check exit0、既存差分を保存。
- Arduino build未実施、実機試験0秒。HID/CONTROL/STATUS/CRC/sequence/timeout/link/resetの新規実測値なし。表は計算・設計予算で、実測counterではない。
- COM open/upload、stack/DIP/controller/LAN/電源変更、commit/push/PR/Slack投稿なし。物理測定・接続確認はユーザー操作が必要。

**確定したのは必要帯域が小さいこととsource実装差。実用下限・安定性・最悪遅延は未測定。** 26MHzの継続には帯域以外の理由が必要であり、8MHzと4MHzを候補に実測する方針を推奨する。
