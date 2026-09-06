# M5-Ethernet低周波数・数値LCD・開発経路の検討

2026-09-06。設計検討のみ。今回追加したファイルは本書のみで、firmware・依存ライブラリ・実機設定は変更していない。

## 結論

**現行製品実装を土台に、通信SPIを低速化し、LCDを数値の変更箇所だけに絞る方策を推奨する。** 最初の候補はM5-Ethernet 4.0.0の通常アクセス/TXをともに8MHz、LCDは既存40MHz設定のまま、数値更新200ms（5Hz）。LCD処理は1フィールドずつ分散し、一度に全項目を描かない。4MHzは8MHzの評価後の比較候補であり、安定性を保証した下限ではない。

USB/MAX3421Eの26→8MHzはLANとは別の比較因子とする。低周波数で改善するかは未測定。信号品質の余裕が増える可能性と、処理時間が増える不利の両方がある。

## 比較したコード

- 現行Sender: `M5Stack-PS5CoRELANSender.ino` の `drawControllerInfoTo()`、`drawControllerInfo()`、`loop()`。
- 現行Receiver: `M5Stack-PS5CoRELANReceiver.ino` の描画関数と `loop()`。
- prototype: `he-robocon/CoRE_WirelessSender` commit `e55449ea65c6477caad7262f1e3d4abf707b8f03`。取得済み `build-temp/prototype-comparison-20260906/source/` のSender/Receiverと同梱UHSを使用。
- M5-Ethernet: `build-temp/usb-lan-isolation/libraries/M5-Ethernet/src/`。ライブラリ差分の詳細は[比較報告](prototype-comparison-he-robocon-20260906.md)、通信帯域の導出は[100Hz設計](spi-budget-and-100hz-design-20260906.md)。

| 項目 | 現行製品 | prototype | 提案 |
|---|---|---|---|
| LCD転送 | 3段階の部分描画 | 全画面sprite転送 | 固定ラベル＋数値領域のみ |
| 周期 | Sender/Receiverとも100msごとに1段階、全3段階300ms | Sender100ms、Receiver33ms | 数値200ms、カウンタ500～1000ms |
| 消去 | 変更有無にかかわらず領域消去 | RAM画面を消去して全体push | 表示文字列が変わった領域だけ |
| 図形 | スティック/D-pad図を再描画 | controller図を全体に含む | 検証時は省略、軸値/D-padコード表示 |
| USBへの配慮 | 描画直前にservice、描画内部の分割なし | 全画面pushの占有が残る | 1項目描画ごとに通信処理へ戻る |

ちらつきを許容するなら、小領域の `fillRect()` と固定幅数値印字で実装できる。単に `printf()` の出力を短くするだけでは古い桁が残るので、消去幅と最大文字数を固定する。状態色の変更も更新判定へ含める。カウンタの桁あふれ表示も決める。

初期化時にラベルと区切りを一度だけ描き、以後はLCD関数からLAN/USBへ問い合わせず、制御側が更新する状態のコピーを表示する。14個のボタンを個別に表示してもよいが、初期検証では16進bitmaskに集約すると転送が減る。

## LCD周期の計算

以下はRGB565、LCD SPI実効40MHzと仮定した**画素データの転送時間**。コマンド、文字生成、API、bus切替、待ち時間は別途必要。実測の最悪実行時間ではない。

`T = 幅 × 高さ × 2 bytes × 8 / SPI周波数`

現行Senderの消去領域をソースから合算すると以下になる。文字・図形の再描画はまだ含まない。

| 処理 | 消去画素数 | 転送時間 |
|---|---:|---:|
| phase 0: 320×27 | 8,640 | 3.456ms |
| phase 1: 230×64 | 14,720 | 5.888ms |
| phase 2: 230×22＋3×53×63＋320×16 | 20,197 | 8.079ms |
| prototype全画面1回: 320×240 | 76,800 | 30.720ms |

したがって、現行の100msを500msに変えるだけではphase 2の長い占有は解消しない。prototypeも周期延長だけでは全画面push時の占有が残る。spriteのRAMが8bitでもpanel転送まで8bitとは仮定しない。

新UIの計算用レイアウトを「最大24項目、各48×8pxの固定値領域」とする。1項目最大8文字を6×8px固定セルに収める設計例であり、実装時は選んだフォントの寸法を確認する。固定ラベルは転送量に含めない。直接描画で領域消去と領域全面相当の文字描画を各1回と見積もると、

`1項目 = 48×8×2×2 = 1,536 bytes → 0.3072ms`

`24項目 = 36,864 bytes → 7.3728ms`

| 全項目の更新周期 | 画素転送の平均占有率（全24項目が毎回変化） | 判断 |
|---|---:|---|
| 10ms / 100Hz | 73.73% | LCD用として採用しない |
| 100ms / 10Hz | 7.37% | 実測後の候補 |
| **200ms / 5Hz** | **3.69%** | **検証開始値** |
| 500ms / 2Hz | 1.47% | カウンタ等に適する |

平均画素転送予算を5%以下と置くと、必要周期は `7.3728/0.05 = 147.456ms以上`。丸めと余裕から200msを選ぶ。これは設計上の予算配分であり、5%以下なら必ず安定するという物理的境界ではない。

**読みやすさのため縦横2倍（96×16px）にすると面積は4倍。** 24項目では200msで14.75%、同じ5%予算には約590msが必要なので600ms以上、または項目数削減が必要になる。数字の寸法を決めずに周期だけを確定することはできない。

24項目を200ms内に均等配置するなら約8.3msごとに1項目。通信期限に近いときは描画を延期し、遅れた描画をまとめて追いつかせない。0.3072msは1項目の画素計算であり、実行時間0.5ms以下を保証しない。初期の計測目標として1描画単位0.5ms以下を置き、超えるなら文字単位へ分割、または小領域RGB565 spriteの1回転送に変更する。48×8px spriteなら画素転送は0.1536msとなる。

各フィールドは描画直前の最新状態を使う。通常値の更新目標200ms、電池/カウンタ500～1000ms、切断・無効・peer timeout表示は変化時に次の小描画枠へ優先する。安全判定とneutral化はLCD更新を待たず制御経路で行う。100ms timeoutは維持する。

## M5-Ethernet 4.0.0で下げる箇所

通常アクセスの `SPI_ETHERNET_SETTINGS` は26MHzだが、TXの `write_data()` 経路は40MHzへ切り替える。**通常側だけ8MHzにしても全経路の低速化にならない。** アプリ外側の `SPI.beginTransaction(8MHz)` だけでも内部設定を固定できない。

新しい隔離ライブラリコピーで通常/TXそれぞれのクロックを設定可能にし、元の26/40MHzを既定値として保存する。比較profileは8/8MHz、その後4/4MHz。USBの4つのSPIアクセス設定は別の8MHz profileとする。RX転送方式、PHYモード、SPI初期化順、reset挙動は同時変更しない。全SPIを8MHzに揃える提案ではなく、LCDは別設定である。

前報の仮予算1000 SPI bytes/10msでは8MHzで1ms、4MHzで2msの通信クロック時間。LCDは小単位に分ければ共存を検討できる。ただし空poll、USB NAK、SEND待ち、API時間が予算内に収まるかは未確認。周波数を下げるほど単独処理は長くなる。

グローバルライブラリと既存の診断freezeは編集しない。新しい隔離コピー、patch、設定値、全対象ファイルSHA-256、実際に選択されたライブラリパス、生成binary hashを残す。M5-Ethernet 4.0.1やEthernet 2.0.2への変更はこの比較へ含めない。

## 開発経路の判断

| 観点 | 現行実装の負荷を下げる | prototypeに機能追加 |
|---|---|---|
| 再利用 | 32-byte protocol、CRC、sequence、CONTROL/STATUS、UART骨格、検証基盤 | 小さいraw HID/echo経路、UIのHORI decode |
| 必要変更 | LCD縮小、隔離clock設定、HORI profile移植、既知UART安全出力の修正 | 左記に加えwire format置換、controller検証、freshness/neutral、周期送信、STATUS、UART、fault tests |
| 原因比較 | 既存診断から1因子ずつ比較できる | library/PHY/rate/UI等が異なり原因を絞れない |
| 製品化の負担 | 既存契約を維持して進められる | 制御・通信の主要部分を作り直す |

現行も完成品ではない。HORI `0F0D/0202` の製品profileが未実装で、Receiverのtimeout/invalid時UART安全出力にも既知の未完事項がある。これらを残したまま「機能を減らしたので安全」とは判断しない。

prototypeは比較用の最小通信例として保持する。同一hardware・周期・payload・SPI・LCD条件で、prototypeだけ長時間安定する証拠が得られれば、その差分を現行へ個別移植する。現時点のコードの短さやRUNNING表示だけでは、製品土台を置き換える根拠にならない。

## 実施順と判定

1. 新しい隔離診断profileを作成。既存条件のままLCD有無を比較し、その後LCD条件を固定してLAN26/40→8/8MHzを比較。USB26→8MHzはさらに別試験とする。PHY、payload、送信周期を固定し、失敗結果も保存する。
2. 数値UIを追加し、LCDなしとの比較で最大描画時間・USB service間隔・送信遅延を測る。まず200ms、必要なら項目削減/分割を行う。平均負荷低下だけで合格にしない。
3. legacy HORI parserを確認し、製品Senderへprofile抽象化とVID/PID選択を実装。unsupportedをneutralに保ち、**USB-only mapping gateを先に通す**。
4. 製品LAN統合は既存20ms条件を基準に開始。その後、開発目標10msを独立変更として両endpoint・文書・互換試験へ反映する。絶対期限を10msずつ進め、最新入力を周期送信。遅延時の連続追送を避け、欠落回数を記録する。
5. ReceiverのUART安全出力を修正・確認し、60秒screening、手動mapping/UI、10分統合、controller/LAN断再接続、60分durabilityの順に進む。失敗gateを長時間試験や自動resetで飛ばさない。

計測項目はHID ready/report増加、CONTROL/STATUS送受信、CRC不良、duplicate/reverse/sequence gap、input/peer timeout、link遷移、reset数、UART neutral出力、max Usb.Task時間/service間隔、LCD単位max時間、送信lateness/欠落周期数。正常区間で意図しないdetach/reset/CRC不良/timeoutがなく、reportsと両方向packetが進むことを要求する。10ms段階ではdeadline missを記録し、最大間隔と許容jitterを試験前に契約化する。故障試験の意図したtimeoutは正常区間と分ける。

書き込み前にはCOM/PnPを毎回確認しReceiver→Senderの順。機材、DIP、controller、LAN配線、電源の変更はユーザーによる物理操作が必要。今回これらは行っていない。

## 証拠と制約

- Proven: 上記ソースの描画範囲・周期・library設定・製品/prototype機能差。
- Inference: 8MHz＋小単位数値描画＋200ms更新を開始値とする設計判断。計算は画素形式と実効周波数の仮定付き。
- 未測定の電気仮説: 低SPIによる信号品質改善。電源/EMI/CS競合が原因との断定はしない。
- 不完全な比較: prototypeと現在のstackの同条件durability証拠は未取得。
- 本検討の実機試験時間0秒。HID/CONTROL/STATUS/CRC/gap/timeout/link/resetの実測値はすべて未取得（ゼロ件合格ではない）。build/upload未実施、物理操作なし。
- 維持する環境: M5Stack ESP32 core3.3.7、M5Unified0.2.19、M5GFX0.2.26、M5-Ethernet4.0.0、UHS1.7.0＋隔離CoreS3 patch。製品構成CoreS3 SE＋LAN Module13.2＋Bottom3、SenderにUSB Module v1.2。HORI Switch 2を開発baselineとし、製品サポート合格は未達。
- Branch: `feat/cores3se-dualsense-lan-stack-diagnostic`。HEAD: `f915b1c9a33693a2010a1d9527b23743707cfa5d`。
- 編集前に `git status -sb`、`git diff --stat`、`git diff --check`、`git rev-parse HEAD` を確認。既存変更を保持。本書は新規文書のみでbuild command/binary hashは該当なし。作成後の `git diff --check` はexit 0（既存ファイルのLF→CRLF警告あり）。最終 `git status -sb` は同一branch、既存変更に本書のuntracked追加のみ。製品Sender/Receiverのdiffなし。計算式をPowerShellで再確認し、本書のUTF-8置換文字がないことも確認した。
- commit/push/pull/PR/branch変更は行っていない。
