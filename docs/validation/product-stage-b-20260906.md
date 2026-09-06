# 工程B: Receiver UART安全出力・Mega非ブロッキング化 — 2026-09-06

承認された[UART/Mega契約](../uart-mega-contract.md)を実装し、Receiver・Sender・Megaのbuildとoffline検証を完了した。指定されたMegaスケッチにはバックアップ後に変更を反映し、作業用候補と全ファイルのSHA-256が一致することを確認した。実機upload、COM open、LAN/UART通信、コントローラ操作、配線・電源変更は行っていない。

branch: `feat/cores3se-dualsense-lan-stack-diagnostic`。開始HEAD `deeb07d04b29bfef5443f7360b23e021e5254bc1`、実装commit `1349662329c95dd5ad05d3e3947eac89b413c03f`。本報告は後続の文書commitで同branchへ反映する。

## 実装

- ReceiverはLANフレームの単純転送を廃止し、自身のsequence/uptimeを持つ32-byte UART CONTROLを10ms周期で送る。CRC・payload配置・UDP50001・LAN周期は変更しない。
- 起動・入力無効・100msのsource timeout・UART backpressure/short writeでは無効neutralを送る。無効イベント直後に有効入力が戻っても、neutralを1件送るまで保持する。周期UART送信でsource期限を延長しない。
- Megaは非ブロッキングのbinary parser、CRC/sequence/uptime継続性、独立100ms期限を持つ。停止後はneutral確認とLの新しい押下が必要。Lは押している間のみ操作許可。
- Rollerの2箇所のdelay(50)を状態管理へ置換。50msずつの安定押下・安定releaseを確認し、500msの連打防止を独立管理する。停止で待機中の切替や射出状態も消去する。
- mainはUARTと停止入力を毎ループ処理し、制御/CANは10ms周期。元のMotorOFFの配列添字誤り、停止時のCAN電流/PID再計算、8スロットを超えるCAN受信IDも停止経路に関係する修正として扱った。

SenderソースとHORI mappingは変更していない。動作割当はLY=左車輪、RY=右車輪、RX=射出角度、L=操作許可、B=ローラー、A=射出。実機の回転方向・サーボ範囲は未確認。

repo変更はReceiver、`src/core_safety/`、Mega adapter、候補生成/適用tool、reference/tests/CI、契約文書。Mega側の既存5ファイルはcontroller.ino、CoRE2_sample.ino、define.h、process.ino、motor.ino。新規5ファイルはCoREUartSafety.h、CoreProtocol.h/.cpp、UartInput.h、RollerSwitch.h。その他4つの既存ファイルは保持した。正確なbefore/after hashは[JSON](product-stage-b-20260906.json)に記載。

元のMega全9ファイルはlocal `build-temp/mega-uart-20260906-candidate01/original-backup/` に保存した。反映記録は同ディレクトリの`applied.json`。ローカルの対象パスを含む完全なmanifestや元スケッチ全体は公開repoへ追加していない。

## 検証と再現

[CI](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/actions/runs/34029307636)は合格。C++973項目（既存642、UART安全314、実Mega受信関数17）、Python25件、PowerShell20項目（事前検査12、ファイル適用8）、既存protocol golden vectorsが合格。

主な異常系はinvalid/nonneutral、source/consumerの100ms境界、CRC破損、重複/逆順/gap、uptimeとsequence wrap、再起動後の再同期、UART容量不足/部分write、遅延時のcatch-up禁止、停止後のL保持復帰拒否、ローラー待機中断。ファイル適用はwrong hash・同時編集・再適用の拒否とbackup/readbackを模擬環境で検証した。

CoreS3はArduino CLI1.5.1、M5Stack core3.3.7、M5Unified0.2.19、M5GFX0.2.26、M5-Ethernet4.0.0、UHS1.7.0の既存隔離構成。Ethernet normal/TX8/8MHz・USB26MHz候補を維持。Megaは既存AVR1.8.8、avr-gcc7.3.0-atmel3.6.1-arduino7、Servo1.2.2、SPI1.0を隔離コピーで使用した。パッケージ・global libraryを更新していない。

```powershell
$config = 'build-temp/product-toolchain-20260906/arduino-cli.json'
$libraries = 'build-temp/product-libraries-8-8-usb26-20260906/libraries'
./tools/product_build.ps1 -ConfigFile $config -LibraryRoot $libraries -Cases @('receiver','sender') -OutputRoot build-temp/product-builds/20260906-stage-b02
./tools/product_build.ps1 -ConfigFile $config -LibraryRoot $libraries -Cases receiver -OutputRoot build-temp/product-builds/20260906-stage-b-receiver-final
arduino-cli --config-file $config compile --clean --verbose --fqbn arduino:avr:mega:cpu=atmega2560 --library build-temp/mega-uart-20260906-candidate01/Servo --build-path build-temp/mega-uart-20260906-candidate01/build-verified build-temp/mega-uart-20260906-candidate01/CoRE2_sample
```

再実行には新しい出力先を用いる。stage-b02のReceiverはUART起動期限の最終整理前なので最終authorityから除外し、再buildしたreceiver-finalを採用。Senderはstage-b02を採用。各caseの全source hashを現worktreeと照合した。Megaはbuild候補・実際に反映したsource・バックアップの全hashを照合した。Mega使用量はflash13,354 bytes/253,952 bytes、static RAM1,072 bytes/8,192 bytes。

| 最終authority | application SHA-256 | build log SHA-256 |
|---|---|---|
| receiver | `D4AB6FA1455F6671203D29C41C280F3CBBD648516E2894C9983929B5C6A3647F` | `08B519C326E8D7AD6DC483E78D9B8F6897FC515BCA6BCB1B1D7175097FB9DC6B` |
| sender | `A7F25DEA7DD753FEB4FFA45226C5414D325ED0F22148A3339E9444828CCA671C` | `C52AFFB3B35CB5A56558DDBAFB07F58F7AB8834ECA658445F85076E15B1F6C64` |
| Mega application HEX | `715074E1CA02FC2C8A8BD02F1D1766D3BA08F5B01F5D0C26E4FD1AB4868195D1` | `97EB0C53F60CC5B07CEB2EF84DDBF998B93CDD27DAC26E8E1E974FD42E63412A` |

正確な引数、library root、source/library/bin/log hashは各local build evidenceに保存。初回sandbox内のMega buildは固定toolchainの読取拒否で失敗し、制限外で同じ隔離toolchainを読み取って成功した。初回のPowerShell -Fileによる配列引数の渡し方も実行前に拒否され、script内の配列呼び出しへ修正した。これらをソース不良や実機障害の比較には使わない。

## 未検証・次のgate

今回の実機HID/CONTROL/STATUS/CRC/sequence gap/timeout/link/reset counterおよび実機試験時間は `NOT_RUN`。通信0件の成功とはしない。確認対象のhardwareはCoreS3 SE＋USB/LAN stack、HORI0F0D/0202 Switch2とMega2560だが、現物や配線はこの工程で確認していない。

証明済みなのはソース反映、offline tests、build identity。推論として、50msの処理停止を除くことでUART処理機会が増える。buffer overflowやLCD/USB/LAN timing、電気的原因、機械的停止時間は未測定。API doubleでのC++試験やMega buildを電気・実機挙動の証明にしない。

起動時のhardware初期化中はUARTが一時停止し得る。運用中も2つの独立100ms期限に加え、周期待ち・約2.778msのUART線上時間・Mega処理・アクチュエータ応答があるため、end-to-end100ms停止は主張しない。zero-current出力の停止特性、実際の入力割当、USB手動mapping→LAN→Receiver/UART→fault/reconnect→耐久の各gateを順に確認する。製品controller supportは未認定。

`git diff --check`は合格。既存branchへ承認済みcommit/pushを行い、PR作成・merge・release・Slack送信は行っていない。最終Git確認では既存の未追跡参考資料 `docs/Datasheet/`、`docs/Schematic/`、`docs/handoffs/usb-lan-antigravity/` のみを保持する。
