# CoRE 次工程計画 — 2026-09-06

工程Aの実行後の手順は[製品試験runnerガイド](product-trial-guide.md)を参照。本計画の現状欄は計画作成時点の記録。

計画基準: branch `feat/cores3se-dualsense-lan-stack-diagnostic`、HEAD `709dd73f3cd24325d33397a46997bc78e49c30c5`。本書は次工程の提案であり、未確定の許容値やUART契約を採用済みにはしない。今回の作業は計画文書の作成のみ。

## 現在地

- HORI `0F0D/0202` / Switch2 の製品パーサー選択、8-byte / Report IDなしの入力構造、観測したニュートラル値を確認済み。
- USB単独の追加取得は75秒、記述子取得後の判定区間67秒で200 reports/s。累積15,187件受理、割当済み入力のnon-neutral、reject、drop、stallは0。長期安定性や操作時の適合確認ではない。
- 記述子のButton15（byte2 bit7）は物理的な用途が不明で、未割当。
- C++633項目、Python7件、protocol reference、診断target buildは合格。製品controller supportは未認定。
- 現物は申告されたCoreS3 SE + USB Module1.2 + LAN Module13.2 + BAT Bottom、HORIのみ、実機Receiverなし。PC peerは192.168.50.30/24。現在はUSB単独intake版が動作し、LANは停止している。
- 操作者は現在コントローラの物理操作ができない。USB手動mapping gate、LAN統合、fault/reconnect、耐久試験は未実施。
- Receiverは無効入力時に元フレームをUARTへ転送し、通信断時にはUART neutralを生成しない既知の課題がある。停止保証の成立にはUART契約と下流の検証が必要。

根拠: [USB intake実測](validation/product-usb-intake-20260906.md)、[開発目標](development-targets.md)、[検証ゲート](ai/validation-gates.md)、[UART設計判断案](uart-safety-decision.md)。GitHub #7–#15は計画時点で全てopen。#7/#9/#14/#15はneeds-design、#8/#10/#11/#12/#13はin-progress。

## 進める順序

| 工程 | 内容・成果物 | 開始条件 | 完了判定 | Issue |
|---|---|---|---|---|
| A | 物理操作不要の検証基盤・試験仕様を準備 | 今すぐ可能 | 下記Aの成果物、offline tests、再現build、試験条件一覧が揃う | #7/#8/#11/#12/#13 |
| B | UART安全出力の設計を確定し、承認後に実装 | 設計はAと同時に可能。実装は契約選択後 | 無効入力・通信断・再接続・sequence境界のhost testsと両endpoint buildが通る | #9/#15 |
| C | HORIのUSB単独手動mappingとUI確認 | 操作者が操作可能 | 必須入力全件が対応表に一致し、release後neutral。未対応機能を明示 | #8/#7 |
| D | 現在のWindows peer構成でSender LAN screening | A/C合格、測定条件・許容値を確定 | 条件ごとに60秒screening合格。PC peer試験の範囲を明示 | #7/#10/#11/#12 |
| E | 実機Receiver・UART下流を含む製品統合 | B/D合格、実機構成・下流契約・COM/PnP確定 | 60秒screening、endpoint間mapping/UI、10分統合、fault/reconnectが順に合格 | #7/#9/#15 |
| F | 採用構成の60分耐久・サポート判定 | E合格、採用binary/依存関係を固定 | 規定の全counterと入力・表示・UART継続性が合格し、人間が結果をレビュー | #7/#14 |

工程A/Bの設計は物理操作を待たずに進める。実機LAN通信を伴う工程D以降は、Cを通過するまで開始しない。

## A: 今すぐ進められる具体的な作業

1. **試験データを固定する。** 実測configuration/report descriptor、生neutral、既存mappingをclone可能なfixtureにまとめ、元raw logとSHA-256の対応を記録する。Button15は「未同定・未割当」として保持し、物理名称を推測しない。
2. **USB手動mapping記録を準備する。** 一項目ずつの操作順、raw/decoded値、開始・終了時刻、release後neutralを保存するrunnerと対応表を用意する。画面のhex値を読み上げる負担を減らし、短時間の操作で全入力を記録できるようにする。自動記録は操作者による方向・名称の確認を代替しない。
3. **Windows用binary UDP peerと判定器を準備する。** 32-byte CR v1、CRC、sequence、CONTROL/STATUSの既存referenceを使う。周期送受信、送受信時刻、欠落・逆順・重複、timeout、再開を記録する。offline fixtureで異常系を先に検証し、この工程では実機LANへ送信しない。
4. **試験専用build profileを用意する。** Sender .10 → PC peer .30 / UDP50001 / Fixed10Halfを独立設定にする。製品既定peer .20と区別し、通常product buildに試験設定が混入したら拒否する。PCのIP、route、firewall、配線は変更しない。LAN-first/USB-secondの初期化順を維持する。
5. **証拠保存を共通化する。** 今回のlocal runnerを整理し、実行前COM/PnP・NIC・route・port占有・binary hash検証、raw serial、peer CSV/stdout/stderr、判定JSON、ZIP/hashを一組で保存する。初期化・計測・意図したfault区間を区別し、不完全な記録から合格を出さない。
6. **時刻・表示計測を設計する。** `millis()`の期限遅れと`micros()`の実行時間を区別する。PCの単調時計で記録するpacket間隔はOS schedulingを含むため、PCとdeviceの観測を別々に扱う。時計同期なしに片道遅延を算出しない。LCDは1項目時間に加え、各変更値のsnapshotから描画までの最大待ち時間を測れるようにする。

Aの完了時点で、手動操作の結果だけを追加すれば次の試験を再現できるbuild・runner・判定仕様が揃っている状態を目指す。ここでLAN適合や画面可読性を合格にはしない。

## B: UART契約の決定と安全実装

推奨する設計候補は、**Receiverが独立した周期UART CONTROL streamのsequence/uptimeを管理する方式**。起動時・入力無効時・CONTROL timeout時にneutralを送れるようにする。32-byteレイアウトを維持しても、元フレームをそのまま転送する現在の契約とは異なるため、下流の受信仕様と合わせた明示的な採用判断が必要。

選択前に確認する項目:

- 実際の下流consumerと使用firmware、binary CR frame対応、CRC・sequence・watchdogの挙動。
- sequenceとuptimeの所有者、wrap、Sender/Receiverそれぞれの再起動、再接続時の再同期規則。
- UART送信周期、起動時neutral、無効入力の扱い、部分write・backpressure時の扱い。
- 「100msの入力/peer期限」と「下流で停止が完了する時刻」の区別。

採用後の実装では、invalid/nonneutral、CRC不良、duplicate/reverse、silence、reconnect、wrap/rebootをhost testsで検証する。周期再送によって元の入力鮮度を延長しない。protocol/reference/consumer側の必要な変更を同じ変更単位に揃える。

115200 8N1の32-byte UART frameは線上で約2.778msを要する。期限判定後の送信slot待ち、serialization、下流処理を停止時間へ加える。100ms timeout設定だけでend-to-end100ms停止を保証しない。既存の透明転送＋下流watchdogを採る場合も、下流の実装と計測を必須にする。ASCII adapterはこの計画で採用しない。

## C: 操作者が戻ったら最初に行う検証

操作項目: D-pad8方向＋neutral、両stickの中心・方向・端点・押込、A/B/X/Y/L/R/ZL/ZR/−/＋/HOME/CAPTURE、release後neutral。ZL/ZRはbuttonとdigital trigger0/255の両方を照合する。Button15の発生条件とturbo/macro設定を調べるが、実験的な出力commandは送らない。

Sender UIの読みやすさ、数値の追従、残像・欠落を人間が確認する。未同定のButton15を製品の必須操作に含めるか、明示的な非対応機能とするかを決定する。必須mappingの不一致を残したままDへ進まない。

初回操作枠の見積りは20～30分程度（準備済みrunnerで異常がない場合）。これは検証実績や終了保証ではない。Button15の特定やUI修正が必要なら、記録・修正・再検証を追加する。

## D: Windows peerでのLAN screening

固定条件: 現在申告されたstack/power/topology、PC .30、Sender .10、Fixed10Half、W5500通常/TX8/8MHz、USB26MHz、数値snapshot40ms、同じ32-byte frame。intake診断は無効にし、計測に必要な最小限のloggingを固定する。起動の順序を保持する。

| 条件 | CONTROL/STATUS周期 | 目的 |
|---|---:|---|
| D0 | 両方20ms | 同一build系列で50Hz比較基準を取得（45～55Hz） |
| D1 | 両方10ms | 周期だけを変更して100Hz目標をscreening（95～105Hz） |

各条件は60秒、D0が失敗したら原因を調べて同条件を再検証する。D1へ進む際にPHY・SPI・UI・配線を同時変更しない。D0/D1比較は周期の影響を見るもので、過去の異なるprototypeやDG条件との因果比較にはしない。

必須記録: HID ready/report/age/drop/stall、CONTROL TX/fail、STATUS RX/invalid/CRC/sequence/timeout、link、意図しないreset、送信欠落slotとlateness、USB service gap、LCD時間、peerの各受信間隔とSTATUS送信遅れ。

通常区間でdrop/stall/CRC不良/予期しないsequence gap/timeout/link drop/resetが出たら停止し、ログを保持する。長時間化や自動resetで通過扱いにしない。PC peerの遅れはPC側送信時刻とdevice側受信を照合し、直ちにfirmware不良と断定しない。

**試験前に確定する追加許容値:** 最大送信lateness、最大packet間隔、許容欠落slot数、LCD dirty値の最大表示待ち時間、測定分解能。案として正常区間の欠落slot0、LCD描画単位1ms未満を初期検討条件にする。最大lateness/間隔と表示待ち時間の数値は、現状のUSB-only実測からは確定できない。nominal100Hz/25Hzと混同せず、測定系のoffline確認後に#7で凍結する。既存の100ms safety timeoutは変更しない。

Windows peer試験はSender側のUSB/LAN共存・通信挙動の検証に限定する。実機Receiver・UART・製品のswitching hub構成の合格には数えない。

## E/F: 製品構成の統合から耐久まで

実機Receiverと下流が用意できた時点で、製品のpower/module/LAN構成を別途確認する。現在のBAT Bottom/PC direct構成と、製品予定のBottom3/switching hub/実機Receiver構成が同一とは扱わない。機材や配線変更は電源を切ったうえで操作者が実施し、変更後のattestationを残す。

採用設定でReceiver、Senderの順にクリーンビルド・COM/PnP照合・書き込みを行う。60秒screening、両endpointのmapping/UI確認、10分統合、controller/LAN切断再接続、60分耐久の順に進む。実際のUART outputとconsumerの受理・停止を記録する。機材がなければUART物理gateは未完了のまま保持する。

耐久はHID/CONTROL/STATUSとUI/UARTの継続、CRC/gap/予期しないtimeout/link drop/resetが0であることを要求する。断線試験の意図したtimeoutを正常区間のcounterへ混ぜない。全ゲートと人間のレビューを終えてからサポート範囲を更新する。

## 不具合が出たときの調査分岐

- 最初の失敗区間を固定し、同一条件で原因を絞る。ソース、binary、ライブラリ、物理構成、時刻情報を保持する。
- SPI比較が必要な場合はW5500通常/TXの設定、USB26→8MHz、LCD負荷を一因子ずつ比較する。USB8MHzは採用を前提にしない。8MHz W5500が十分な場合、4MHz探索は優先しない。
- PHYとinitialization orderは比較中に変更しない。USB/LAN設定値だけで電気的原因を断定しない。追加の電気計測やpacket captureが必要なら、現行条件との差を示した別の実験計画を作る。

## 次の作業単位と終了条件

最初の作業単位は **Aのfixture/runner/PC peer準備と、BのUART契約の具体化**。成果物はレビュー可能な小単位に分け、未承認のUART挙動変更を混ぜない。完了後、操作者の都合がつくまでC以降を待てる状態にする。

PC上の準備工数は、runnerの再利用範囲と下流仕様の確認結果で変わるため、現時点で日付を固定しない。実機の固定計測時間はscreening60秒単位、10分、60分であり、build/upload・操作・fault確認・解析・失敗後の再試験時間を別に確保する。

今回、firmware変更、build、upload、serial取得、物理操作、Issue状態変更は行っていない。新規変更は本計画文書のみ。開始時`git diff --stat`空、`git diff --check`成功、既存untrackedのDatasheet/Schematic/historical handoffを保持。計画作成後も`git diff --check`成功。commit/push/PR/mergeはこの計画作成では行っていない。
