# Post-DG-D Runner修正・設計の検証記録

2026-09-06。作業区分はdiagnostic tooling修正、offline検証、設計、文書整理。ユーザー許可: Runner/fixture修正と設計、明確に不要な文書の削除、AI文書更新。共有先は現在のrepository、必要者のaccessはユーザー確認済み。

## Gitと変更境界

- branch: `feat/cores3se-dualsense-lan-stack-diagnostic`
- HEAD: `f915b1c9a33693a2010a1d9527b23743707cfa5d`（作業前後同じ）
- 作業前からroot診断inoと `tools/usb_lan_isolation_test.ps1` にtracked変更、diagnostics/tools/tests/docs等に多数のuntrackedあり。これらを保存した。
- 直前レビューのcurrent88 filesと比較し、今回予定した8既存file変更・削除のみ。無関係な差分0。`git diff --check` exit0。LF→CRLF警告あり、whitespace error無し。untrackedの今回変更・新規ファイルも末尾空白を別検査した。
- commit/push/pull/fetch/PR/branch操作、Slack投稿は行っていない。

変更ファイル（今回の差分。既存未commit差分とは区別）:

| ファイル | 変更 |
|---|---|
| tools/usb_lan_gate_dg_d_runner.ps1 | ゼロID切断証拠の限定判定、realistic fixtures、16 regression cases、offline temp削除のpath確認 |
| tests/usb-lan-gate-dg-d/README.md | 新しい判定coverageの説明 |
| docs/usb-lan-gate-dg-d-contract.md | post-freeze addendum。旧freezeの変更ではない |
| AGENTS.md / .agents/rules/usb-lan-investigation.md | 現在工程と下流receiver contractへの案内 |
| docs/handoffs/usb-lan-antigravity/00_README.md | 履歴snapshotであることを入口に明記 |
| README.md | 旧TCPツールを製品UDP試験として案内していた記述を訂正、build経路の注意、設計へのリンク |
| docs/CODEX_REVIEW_POLICY.md | 重複・古いtarget/build指示のため削除。参照する現行ファイルなし |
| docs/ai/investigation-status.md | 新規。現在地・順序・保存/共有方針 |
| docs/usb-lan-next-non-null-read-design.md | 新規。次診断の具体的処置・判定・gate設計 |
| docs/uart-downstream-common-protocol-design.md | 新規。QUESTiX固定contractとキット配列/安全動作の共通化設計 |
| 本文書 | 新規。検証と限界 |

削除したpolicyの元SHA256は `F2EBA5EBE060AC0C3E7014CB340CDD774274755D5300DB04E8F99D80B5061EAC`。履歴証拠、freeze/raw/build、gate contractは削除していない。

## Runnerの修正と結果

原因: firmware `updateUsbIdentity()` はHID not readyでVID/PIDをゼロにするが、旧parserはterminalにHORI IDを一律要求し、fixtureは切断状態でもHORI IDを保持していた。このため実際の切断表現ではclean USB failureが誤ってBLOCKEDになり得た。

修正はterminal `FAIL / USB_DETACH_OR_UNSUPPORTED`、ready0/drop>0/reports>0、開始前のuniqueなHORI readyとstability、uniqueなDIAGNOSTIC_STARTの順序を満たす場合に限り `0000/0000` を受け付ける。unsupported/mixed ID、ready証拠不足/重複/遅延、PASSのゼロIDは拒否する。peer刺激とB37のfail-closed判定、healthy PASS条件は変更しない。

Runner SHA256: 修正前 `A6D9B983280BCE9BDF8B7CF9B694D8D05892221456D1A2749DD2150A0AB9AC46` → 修正後 `695BD2EB7672BA2521BBA71007D58D5A87B01CB2AB279727EA311E511717EC19`。

Windows PowerShell `5.1.26100.9168`、Python `3.12.10`。以下を実行した。ExecutionPolicy Bypassはrepositoryの既存offline実行方式に合わせた子process限定指定であり、Windows policy設定自体は変更していない。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/usb_lan_gate_dg_d_runner.ps1 -OfflineSelfTest
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/usb-lan-gate-dg-d/run_offline_tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-temp/post-dg-d-followup-20260906/replay-frozen.ps1
python -B build-temp/post-dg-d-followup-20260906/audit_changes.py
git diff --check
git status -sb
```

| 検証 | 結果 |
|---|---|
| Runner embedded suite | 76/76 PASS（従来60 + 新規16） |
| wrapper fixtures | 20/20 PASS。上記Runnerとexact DG-C peer fake-socket suiteを含む |
| B37-A〜G | 全PASS。serial/peer timeoutはBLOCKED、raw primaryは保存 |
| accepted DG-D S1 raw replay | EvidenceContractValid=true、LogicalPass=true |
| accepted DG-D T1 raw replay | EvidenceContractValid=true、LogicalPass=true |
| current88file drift audit | 許可範囲8のみ、予期しない差分0 |
| 添付ZIP hash | 原本と一致、未変更 |

replayはRunnerのpure parser functionsだけをASTから読み出し、既存rawをhash照合して評価した。Runnerのupload/network orchestrationを起動していない。S1 raw SHA256 `4D7CAF16104F8835D58A77BA5B7BFA8F4E4B150D2CDB08E5E87694883ECF40CB`、T1 raw SHA256 `2E7EDA0372EDFEF508A18E4DF661BB9A5EE4965CC7B797017A1323EAB9BF7580`。結果再生は物理再試験ではない。

## 設計の結論と未実施事項

事実: QUESTiX受信は7項目ASCIIを受け、現行キットの7項目とは配置が違う。共通化案はLAN32-byte維持＋Receiver UART adapter＋キットcontroller内部の配列変換。QUESTiX既定0.5秒timeoutと2-frame release filter、キットのlatched操作を安全設計へ含めた。protocol変更・キット新ZIP作成は提案採用後の実装工程。

推論: non-null payload readはDG-D後の追加処置として識別力がある。ただしSPI転送/RAM/時間/queue等が同時に変わり、電気的root causeを特定する試験ではない。DG-D PASSとC2 FAILだけでapplication処理を原因と断定できない。

未測定: 新しいHID/CONTROL/STATUS/CRC/sequence gap/timeout/link/reset counter、UART停止遅延、電圧/EMI、ロボット動作。offline fixture内のcounterは合成値であり実測値ではない。今回の実機試験時間は0秒。

build command: 未実行（firmware・libraryを変更していない）。固定baselineはcore3.3.7 / M5Unified0.2.19 / M5GFX0.2.26 / M5-Ethernet4.0.0 / isolated UHS1.7.0。依存upgrade/Arduino global patch無し。

物理操作: COM open、upload、UART/LAN traffic、controller/stack/DIP/配線/電源変更は未実施。今後の接続・PnP確認・車輪浮上・射出無効化・S1/T1等はユーザーの現物確認と当該gateの許可が必要。現物構成を今回確認したという主張はしない。

ログ・hash・Git前後記録は `build-temp/post-dg-d-followup-20260906/` に保存。ここはローカル検証証拠でありGit共有済みではない。共有用変更は上表のrepository fileにまとめてある。
