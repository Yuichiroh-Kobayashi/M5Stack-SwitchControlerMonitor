# 工程A: 物理操作不要の試験準備 — 2026-09-06

工程Aのソース・試験・手順を実装し、offline checksと6構成のclean target buildを完了した。実機へのupload、COM open、UDP送受信、配線・電源操作は行っていない。LAN適合・UART安全性・製品controller supportは未認定。

実装commit: `e693db7e2c02f1cab16b22feb750cae099c0bc06`、branch `feat/cores3se-dualsense-lan-stack-diagnostic`。作業前HEADは `709dd73f3cd24325d33397a46997bc78e49c30c5`。既存の未追跡参考資料3ディレクトリは保持した。

## 変更と検証

- HORI `0F0D/0202` / Switch 2の実測記述子・neutral・既存button mappingをfixture化。Button15は未同定・未割当のまま。
- USB手動mappingの16秒×30step runner、操作者review、同一source/PnPへのgate bindingを追加。
- CR v1 / 32-byte binary Windows peer、CRC/sequence/100ms期限、20/10ms deadline、raw CSV再decode判定を追加。STATUSは実機UART有効を偽装しない。
- `.10`→PC `.30` / UDP50001 / Fixed10Halfの試験専用profileを追加。通常product peer `.20`と区別し、LAN→USBの初期化順は維持。
- LCD snapshot更新から描画完了まで、最古の未描画更新から描画完了まで、現在のpending時間を追加。初期描画を累積update最大値から除外し、coalescingでstarvationを隠さない。
- exact COM/PnP、binary hash、NIC/route/port占有のpreflight、終了済み証拠のmanifest/ZIP/SHA-256を追加。

変更対象はSender/Receiverの計測、`src/numeric_ui`、試験専用`src/core_runtime/PcPeerTest.h`、`tools/product_build.ps1`、`tools/product_trial.*`と`tools/product_validation/`、`tests/product/`、host CI、計画/手順書。ReceiverのUART出力処理とMegaのコードは変更していない。

[CI run](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/actions/runs/34019924311)は成功。実ソースのC++検証642項目（profile438/runtime49/display87/intake68）、Python23件、Windows PowerShell12項目、protocol referenceのgolden vectorsが合格。CRC破損、重複、誤ったsource、100ms境界、欠落/短い記録、未承認limits、mapping不一致、証拠改変をofflineで検査した。C++はCI上のAPI doubleであり実機のSPI時間を測定していない。PowerShell runnerのlive COM/UDP部分は未実行。

## 再現build

Arduino CLI `1.5.1`、M5Stack core `3.3.7`、M5Unified `0.2.19`、M5GFX `0.2.26`、M5-Ethernet `4.0.0`、UHS `1.7.0`。workspace内のCoreS3 isolated patch、Ethernet normal/TX 8/8MHz・USB26MHz候補を使用。global library/core/packageは変更していない。

```powershell
$config = 'build-temp/product-toolchain-20260906/arduino-cli.json'
$libraries = 'build-temp/product-libraries-8-8-usb26-20260906/libraries'
./tools/product_build.ps1 -ConfigFile $config -LibraryRoot $libraries -OutputRoot build-temp/product-builds/20260906-stage-a-product
./tools/product_build.ps1 -ConfigFile $config -LibraryRoot $libraries -Cases sender-usb-only -UsbIntake 1 -OutputRoot build-temp/product-builds/20260906-stage-a-mapping
./tools/product_build.ps1 -ConfigFile $config -LibraryRoot $libraries -Cases sender -PcPeerTest 1 -PeriodMs 20 -OutputRoot build-temp/product-builds/20260906-stage-a-pc20
./tools/product_build.ps1 -ConfigFile $config -LibraryRoot $libraries -Cases sender -PcPeerTest 1 -PeriodMs 10 -OutputRoot build-temp/product-builds/20260906-stage-a-pc10
```

上記出力先は実施済みなので、再実行時には新しい名前を指定する。全buildに`--clean`を用い、Receiver、Sender、USB-onlyを個別にbuildした。全ソース・ライブラリ・bin・build logのhashと正確な引数は各build evidenceに保存。ビルド後に全ソースhashを現worktreeと照合し、5種類のSender source manifestsが同一、全6構成のlibrary manifestsが同一であることを確認した。

| 構成 | 周期ms | bin bytes | application SHA-256 |
|---|---:|---:|---|
| product / receiver | 10 | 564752 | `A6184B6F485C8B17F134D3ACEACED673DB8E6189AE54EB5456342FB9663E7EEB` |
| product / sender | 10 | 574288 | `5BA1109BBA19D133E736A7C3799AB8559EF12588E967845658DFD99D15492287` |
| product / sender-usb-only | 10 | 572208 | `A46F7050F7296B30EF948B84515A02EE42EA50B42A85B4860F941D64A0AEEB99` |
| mapping / sender-usb-only | 10 | 574016 | `77B9B4FCFC1FA483079BE701D788445E9528C8043BAE2E091DFB120EE322CDCD` |
| pc20 / sender | 20 | 574720 | `9C4D4D5A032DB1E554AA10742506EAC41BD1E5667B84282F440D346BA8744EC7` |
| pc10 / sender | 10 | 574720 | `6D579268AFD12CC43C1836A272DF29BA248537962ED0884C00090D5E8C81E986` |

build log SHA-256、source/library manifest SHA-256、ローカル証拠の相対パスは[JSON](product-stage-a-20260906.json)に記録。`LogElapsedSeconds`はWindowsのbuild.log作成時刻～最終更新時刻による概算で、実機試験時間ではない。今回serial logは生成していない。

## 判定範囲と次の条件

証明済み: 上記offline checks、clean build、source/artifact identity。推論: これらの準備により手動操作時の記録・比較を再現しやすくなる。未測定: live runnerの実機動作、電気的要因、LCDの実時間、LAN fault/recovery、Receiver/UART下流、耐久性。PC peerと実機Receiver、BAT Bottom直結構成と製品Bottom3/ハブ構成は同じ比較条件ではない。

今回のHID/CONTROL/STATUS/CRC/sequence gap/timeout/link/resetの実機counterはすべて `NOT_RUN`（ゼロ件合格とはしない）。予定しているscreeningは標準75秒capture、10秒warmup後に各系列60秒以上。20msは45–55Hz、10msは95–105Hzとし、その他の時間許容値は判断者の確定が必要。example limitsはpendingのままで実行を拒否する。

操作者が操作可能になったら、現物・COM/PnP・power/DIPを再確認し、USB手動mappingとUI確認を先に行う。その人間のreviewとtiming契約が成立するまでLAN screeningを開始しない。②のUART設計も別途採用判断が必要。手順は[runnerガイド](../product-trial-guide.md)に記載。

`git diff --check`は合格。実装を承認済みの既存branchへcommit/pushし、証拠文書も同branchへ反映する。PR作成・merge・release・Slack送信はしていない。最終確認で残る既存未追跡資料は `docs/Datasheet/`、`docs/Schematic/`、`docs/handoffs/usb-lan-antigravity/` のみ。
