# DG-D後の full non-null read 診断設計

状態: 設計案、2026-09-06。ユーザーからRunner/fixture修正と設計を許可された範囲。新mode実装、build、実機試験の実施記録ではない。製品の通信・PHY・USB初期化順を変更しない。

## 問いと比較

DG-Dの即時null-discardは、UDP payloadをMCU RAMへコピーせずに退役させる。一方、`parsePacket()` は8-byte pseudo-headerを既にnon-nullで読む。したがって比較する追加処置は **32-byte UDP payloadのnon-null read** であり、「SPI readなし対あり」ではない。

DG-D由来の新しい隔離sourceで、positive size=32の直後の `udp.read(static_cast<uint8_t*>(nullptr),32)` を、寿命が試験全体を覆う固定 `uint8_t payload[32]` への1回のreadへ置き換える。payloadのCRC/内容検証、remote tuple検証、outstanding管理、RTT、watchdog、checksum、dump、追加resetは導入しない。新mode番号は既存衝突とrunner/buildとの対応を実装時に確認して割り当てる。

基底はaccepted DG-D T1 freezeの診断sourceと依存関係。peerは既存DG-C peer（SHA256 `0D770B8C02ECCBC382A3F5A484F401A3DF9EF9318701ED0C3A2395EEB66E830A`）をそのまま使用。現在修正したRunnerは別revisionとして新authorityに収録する。accepted DG-Dのmanifestを新hashへ上書きしない。

## 固定する条件

- HORI `0F0D/0202`、Switch 2、LAN-first、Fixed10Half。診断時のBottom/電源/stackはDG-D accepted evidenceを照合し、製品Bottom3構成を無断で代入しない。
- CoreS3 SPI SCK36/MOSI37/MISO35、MAX CS1/INT14、W5500 CS13/INT10/RESET0。inactive CS highを維持。
- M5Stack core3.3.7、M5Unified0.2.19、M5GFX0.2.26、M5-Ethernet4.0.0、隔離UHS1.7.0 patch。exact paths/hashesを再取得。global library変更無し。
- 診断C1UD 32-byte payload、20ms送信、device `192.168.50.10:50001`、peer `192.168.50.30:50001`、one-for-one echo。これは製品CONTROL packetではない。
- DG-Dと同じUSB Task位置、health/print cadence、scheduler、terminal stop、bounded drain。drain targetは実TX数、timeout1000ms、quiet100ms。

## 観測とacceptance

新prefixで `READ_CALL_TOTAL / READ_RETURN_TOTAL / READ_REQUEST_BYTES_TOTAL / READ_BYTES_TOTAL / READ_FAIL_TOTAL / READ_LAST_RETURN / READ_MAX_US` を記録。既存のparse started/completed、zero/positive/negative、size、pre/post remaining、treatment max、drain、HID、PHY/version/buffer-map/MAX canary、TX/peer sequenceを保持する。nullという名称を新readの意味で流用しない。

正常完了時は次をすべて満たす。

- positive32 > 0、positive other size=0、negative=0、parse started=completed=zero+positive+negative。
- read calls=full returns=positive、request bytes=read bytes=32×positive、fail=0、last return=32、pre/post software remaining=0。
- 実TX数=peer受信数=echo送信数=device positive/read数。sequence gap/duplicate/reverse、peer send failは0。予定時間から499/2999等を強制しない。
- USB90、HORI ready、HID reports増加、ready drop/stall=0、health/timing異常=0。drain完了とquiet100msを満たす。

`available()` はsoftware `_remaining` でありW5500 queueの実測ではない。M5-Ethernetのnull pathでもRX_RD cache更新や条件付きSn_RX_RD/RECVは行われる。packetごとにRECVが1回という換算は禁止。

non-null→`socketRecv`→`read_data`→W5500 RX buffer readのsource経路と、build後ELF/disassemblyにbufferへの転送が残ることをレビューする。単に戻り値32だけでは全payload bitの正しさを証明しない。最適化で転送が消える場合は開始不可とし、最小compiler barrier案を別レビューする。最初からvolatile走査/checksumを混ぜない。

## 判定と止め方

| 状況 | 判定 | 言えること |
|---|---|---|
| 全条件成立してS1/T1完了 | PASS | この追加処置bundleと観測時間では非再現。C2 applicationが原因と確定しない |
| valid target prefixと刺激成立後のclean USB/HID failure | FAIL | C2のvalidation/bookkeepingはその再現の必要条件ではない。電気/時間/RAM/queueのどれかは未分離 |
| partial read、size/health/timing異常、peer/capture/identity不成立 | BLOCKED | 主raw現象を保持するが、cleanな因果比較としない |

ACTIVEでUSB failureなら未完drainだけを理由にFAILを失わせない。ゼロVID/PIDの限定処理とB37-A〜Gを引き継ぐ。刺激0/UNKNOWN、serial timeout、peer shutdown timeoutはFAILへ昇格しない。

## 実装後の順序（未実施）

1. isolated source/runner/build script/contractの差分レビュー。offlineでshort/negative read、missing return、size31/33、counter矛盾、drain境界、ゼロID detachとB37を確認。
2. pinned clean S1/T1 build、PRE/POST依存hash、binary hash、ELF read経路を確認。BuildOnlyは実機PASSではない。
3. ユーザーによるstack/電源/DIP/接続確認、COMとexact PnP照合、当該S1 uploadの許可。10秒S1→rawレビュー/freeze。
4. S1成立後に60秒T1の別gateを実施。FAIL/BLOCKEDなら延長・自動復帰で通過させない。

追加処置にはSPI転送、RAM書込み、時間、binary layout、queue状態の交絡が残る。PASS後はC2 application群の1群ずつの分解を検討。比較が不安定ならrail/CS/SCK/MAXイベントの同期計測設計へ戻る。今回、電気測定・物理操作・reset・uploadは行っていない。
