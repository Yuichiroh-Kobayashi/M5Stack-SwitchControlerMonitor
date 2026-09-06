# USB/LAN 調査の現在地（2026-09-06）

この文書は現在の作業順を示す。規範は `AGENTS.md`、各試験の事実はその世代の source / build / raw / manifest を正本とする。過去handoffの「next C1」は当時の予定であり、現在の作業指示ではない。

## 到達点と今回の変更

- C2ではUSB/HID failureを観測。DG-Dの即時null-discard診断はS1/T1でPASSしたが、root causeは未解決。payloadのnon-null転送やapplication処理の必要性は未分離。
- DG-D Runnerは、切断後の `VID=0000 PID=0000` を一律に証拠不成立としていた。今回、開始前のHORI ready証拠、開始順、report実績、ready drop、terminal failure reasonを確認する限定処理に修正した。PASS条件、peer刺激成立、B37の制御異常によるBLOCKEDは維持。
- これは将来の判定器修正。既存DG-D freezeのsource/hash/結果は書き換えない。変更後Runnerで物理試験を行うには、新しいimplementation authorityのレビューが必要。
- HORI製品profileは候補実装済み（Issue #8）、製品USB-only mappingは未検証、製品対応controllerは引き続き無し。診断PASSを製品LAN統合・耐久性のPASSと扱わない。

## 作業の順序

1. [Issue一覧](../development-issues.md)の#8/#10/#11/#12/#13に対応するHORI・低SPI生成器・100Hz周期・25Hz数値表示・隔離ビルド候補をレビューする。旧診断Runnerのoffline回帰は保持する。
2. 製品USB-only mappingを#7で確認する。合格前に製品LAN実機試験へ進まない。今回の作業はupload/配線変更を含まない。
3. #9/#15の[Receiver独立UART・Mega2560契約](../uart-mega-contract.md)は採用・ソフトウェア実装済み。[工程Bの検証記録](../validation/product-stage-b-20260906.md)にbuild/testsとMegaへのsource反映を記録する。実機UART停止・復帰のgateは未実施。QUESTiX向け[共通化設計](../uart-downstream-common-protocol-design.md)は別判断で、ASCII adapter案は未採用。
4. #14で[non-null read診断設計](../usb-lan-next-non-null-read-design.md)と低SPI/UI比較の因子を分離する。新しいnon-null診断の物理PASSを意味しない。
5. 各候補のauthorityと測定条件を固定し、#7のLAN統合・故障・耐久gateへ進む。source/build合格と実機適合は区別する。

## 共有と保存

共有先は現在のリポジトリのoriginフォーク。2026-09-06の後続依頼で、現行source/docs/testsのcommit/push、Issue化、その後の実装・非実機検証が許可された。mainへのmerge、release、未確認機器へのuploadは含めない。開発目標は[確定目標](../development-targets.md)、Issue運用は[CoRE運用方針](../issue-management.md)を参照する。

`build-temp/` のraw/freezeはGit cloneだけでは再現できない。レビュー用source/docsと、機器識別子を含むraw/build一式の保存を区別する。既存レビューのmanifestとローカルarchiveを保持し、将来の共有作業でリポジトリのRelease添付等の具体的保存先・取得手順を決める。現在のアクセス権の確認を再要求する必要はない。

## 履歴と削除

`docs/CODEX_REVIEW_POLICY.md` は削除した。参照する現行ファイルが無く、独立review専用役割、DualSense target、旧buildコマンドが現在の `AGENTS.md` と重複・不整合だったため。規範は `AGENTS.md` に統一する。

raw、freeze、accepted gate contract、handoffの証拠・patch・manifest、旧実験結果は削除対象にしていない。古い日付だけでは不要と判断しない。handoff入口には履歴であることを明記した。

今回の検証記録: [post-DG-D Runner修正記録](../post-dg-d-runner-repair-validation.md)。
