# 製品試験runnerの使い方

このrunnerは、HORI `0F0D/0202` / Switch 2のUSB単独確認と、その手動確認後のWindows対向LAN screening用。実機Receiver/UART、切断復帰、耐久試験を代替しない。ソフトウェア準備の完了は製品対応の認定ではない。

## 事前に用意するもの

- workspace内の隔離Arduino CLI設定と固定版ライブラリ。build scriptは既存版を確認し、インストールや更新はしない。
- 現物を確認したCOM番号・完全一致のPnP instance ID。例の値を実機の値として使わない。
- 試験ごとのphysical attestationテキスト。確認日時、操作者、stack/power、DIP、HORI hardware mode、turbo/macro、配線、最後の書き込み以降に別firmwareを書いていないことを記録する。
- LAN試験はUSB手動mapping reviewと、判断者が確定したtiming limits JSON。

物理的な接続・差替え・DIP変更は操作者が行う。stackの変更前には電源を切る。runnerはIP・route・firewall・電源を変更しない。明示的な`-Upload`だけが書き込みを行い、その直前にCOM/PnPを再検査する。

## ビルド

以下の`$config`と`$libraries`は、実在するworkspace内の隔離設定・ライブラリへの絶対パスを設定してから使う。各出力先は新規ディレクトリにする。

```powershell
# USB専用、raw/decoded intake付き
./tools/product_build.ps1 -ConfigFile $config -LibraryRoot $libraries -Cases sender-usb-only -UsbIntake 1 -OutputRoot build-temp/my-mapping-build
# PC .30対向の試験専用版。20ms→10msは周期だけを変える。
./tools/product_build.ps1 -ConfigFile $config -LibraryRoot $libraries -Cases sender -PcPeerTest 1 -PeriodMs 20 -OutputRoot build-temp/my-pc20-build
./tools/product_build.ps1 -ConfigFile $config -LibraryRoot $libraries -Cases sender -PcPeerTest 1 -PeriodMs 10 -OutputRoot build-temp/my-pc10-build
```

通常product peerは`.20`。PC試験専用版はSender `.10`→Windows `.30`、UDP50001、W5500 Fixed10Half。試験macroとtest-build markerを一致させ、USB-only/intakeとの混在をコンパイル時に拒否する。PHY設定はLAN初期化中の一度だけで、LAN→USBの順序を維持する。USB26MHz・Ethernet normal/TX 8/8MHzの隔離候補を使う場合、その同じライブラリを全比較で固定する。

`results.json`のapplication SHA-256をrunnerへ渡す。`binary-hashes.csv`には全bin、`source-hashes.csv`には全ソース、上位の`library-hashes.csv`には依存関係のSHA-256を保存する。mappingとPC試験のsource manifestが一致しなければLAN gateを拒否する。build flagsとbinaryは用途ごとに異なる。

## USB単独と手動mapping

```powershell
python tools/product_trial.py mapping-plan
# $commonにはMode以外の必須引数を設定する。
$common = @{
  BuildRoot = 'build-temp/my-mapping-build'
  ExpectedBinarySha256 = $verifiedBinarySha256
  Port = $verifiedCom
  ExpectedPnpDeviceId = $verifiedPnp
  PhysicalAttestationFile = $currentPhysicalAttestation
}
# 前提確認と証拠保存だけ。COMを開かず、送信・uploadしない。
./tools/product_trial.ps1 @common -Mode UsbScreen -PreflightOnly
# 実際に開始する際の明示的upload。初回は受動neutralで確認する。
./tools/product_trial.ps1 @common -Mode UsbScreen -Upload -ConfigFile $config
# 以後は成功したupload trialのmetadata.jsonを指定する。
./tools/product_trial.ps1 @common -Mode UsbMapping -MappingStep A -RunningFirmwareEvidenceFile $priorUploadMetadata
```

`-RunningFirmwareEvidenceFile`は保存済みmanifestの完全性と成功したupload記録、binary/PnPを検査する。フラッシュを直接readbackする機能ではないため、以後の別書き込みがないことは操作者の申告に依存する。

各stepは16秒。0–4秒neutral、4–10秒指定入力を保持、10–16秒release。runnerが表示するHOLD/RELEASEに従う。14ボタン、D-pad8方向、4軸の両端8項目で必須30step。Button15は別の探索項目で、物理機能を推測しない。探索できない場合も未同定・未割当であることをreviewに残す。

判定は遷移直後を除いた複数の1Hz sampleを用い、開始neutral・指定入力・release後neutralを確認する。neutral128、軸端0/255を観測条件にする。実物が異なるときは不一致の証拠を残して再検討し、自動的に許容幅を拡大しない。画面、方向、物理ラベル、turbo/macroは操作者が別途確認する。

```powershell
python tools/product_trial.py --output build-temp/manual-review.json mapping-review --observations $observationJsonPaths --operator $operator --button15-disposition '未同定・未割当' --confirm-physical-labels-ranges-ui-turbo
```

`OBSERVED_MATCH`だけではgateを通らない。必須30件すべての同一source/PnP観測と明示的な人間のreviewが必要。offline testで作る合成観測を実機証拠に転用しない。

## LAN screening

`tools/product_validation/timing-limits.example.json`をlocal evidence用にコピーし、判断者・承認状態と全数値を記入する。未承認またはnullのままなら実行を拒否する。許容値は本変更では採用していない。

```powershell
# $lanCommonはPC試験buildのhash、現COM/PnP、physical attestationを指定する。
./tools/product_trial.ps1 @lanCommon -Mode LanScreen -MappingReview build-temp/manual-review.json -TimingLimits $approvedTimingLimits -Upload -ConfigFile $config
```

PC `.30/24`と同じNICのdirect route、default gatewayなし、UDP50001未使用、競合serial/capture processなしを確認する。UsbScreen/UsbMappingでも同じ現場のNIC条件を確認するため、別トポロジーで使う前には手順を再検討する。

標準captureは75秒。先頭10秒をwarmupとして除いた後、serial・CONTROL受信・STATUS送信の各記録が60秒以上必要。20msは45–55Hz、10msは95–105Hz。ready/input/status/link、HID増加、CRC・sequence・timeout・reset・skip、PHY設定、packet間隔、送信期限遅れ、LCD待ち時間を検査する。peer CSVの自己申告だけを信用せず、保存した32-byte rawを再decodeする。

peerのSTATUSはUART無効を明示する。Windowsの送信成功はUDP socketへの受理を意味し、実線上到達はSenderのSTATUS受信counterと合わせて評価する。PCが実機Receiverに相当するという判定は出さない。

## 時間の意味と保存

- Sender `MAX_SEND_LATE_MS`: device `millis()`での送信期限遅れ。1ms粒度。
- peer `deadline_late_ns`: Windows単調時計での送信開始遅れ。scheduler遅延を含む。
- peer packet gap: 同一host時計で観測した連続packet間隔。片道遅延ではない。
- serial `elapsed_ns`: 完成した行をhostが読み取った時刻。USB reportそのものの発生時刻ではない。peerとは開始基準が異なるため直接引き算しない。
- `LCD_MAX_US`: 1描画単位の実行時間。
- `LCD_SNAPSHOT_MAX_MS`: 最後にdesired値が変わってから描画完了まで。
- `LCD_DIRTY_MAX_MS`: 未描画状態が始まってから描画完了まで。上書きで古い待ち時間を消さない。
- `LCD_PENDING_MS`: 現在まだ描画されていない項目の最大待ち時間。starvationの検出用。

最初の画面描画にはhardware初期化時間が入るため、累積update最大値からは除外する。pendingには初期描画待ちも見える。40msの表示snapshot周期は別途存在し、LCDの数値から操作→画面の全遅延を断定しない。

終了時にはraw serial、JSONL、peer CSV、preflight、attestation、hash manifests、引数、判定・失敗理由を閉じてから、全ファイルhashを持つmanifestとZIP・ZIP SHA-256を作る。再finalizeや上書きを拒否する。異常終了時も証拠を残す。privateなPnP・ネットワーク情報を含むので、`build-temp`のraw証拠を公開repoへ追加しない。

```powershell
python tools/product_trial.py verify --root build-temp/product-trials/<trial>
python -m unittest discover -s tests/product -p 'test_*.py'
powershell -NoProfile -ExecutionPolicy Bypass -File tests/product/run_trial_preflight_tests.ps1
```

`SCREEN_DATA_PASS`/`PASSIVE_DATA_PASS`はデータscreening結果で、必ず`physical_qualification=false`。実機gateの最終判断は別途人間が行う。
