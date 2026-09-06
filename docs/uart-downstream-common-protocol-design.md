# QUESTiX / ジュニアロボットキットの共通UART設計案

2026-09-06、設計・受信契約調査。推奨は **LANの現行32-byte binaryを維持し、M5 ReceiverのUARTをQUESTiX互換7項目ASCIIへ変換する構成**。同じSender/Receiver firmwareを両ロボットに使用し、キット側の `controller.ino` で既存の機能配列へ変換する。

この提案は現行UARTの32-byte契約を変更するため、まだ採用・実装していない。製品firmware、CoreProtocol、QUESTiX repository、添付ZIPは変更していない。コントローラの製品profile実装やUSB/LAN gateとは別の作業である。

## 受信契約の根拠

QUESTiXは取得時mainのcommit `5dbdd7b44fd9dfda7cffc4a9f026858f6c2341cf` に固定して調査した。Raspberry Pi5 / Ubuntu24.04 LTS / ROS2 Jazzy、旧SwitchSenderの使用実績はユーザー提供情報。今回実機での再確認はしていない。

- [parseControllerLineと軸・ボタン変換](https://github.com/scramble-robot/questix/blob/5dbdd7b44fd9dfda7cffc4a9f026858f6c2341cf/uart_joy_driver/src/joy_line_parser.cpp)
- [定数・型](https://github.com/scramble-robot/questix/blob/5dbdd7b44fd9dfda7cffc4a9f026858f6c2341cf/uart_joy_driver/include/uart_joy_driver/joy_line_parser.hpp)
- [conformance tests](https://github.com/scramble-robot/questix/blob/5dbdd7b44fd9dfda7cffc4a9f026858f6c2341cf/uart_joy_driver/test/test_joy_line_parser.cpp)
- [readLine・timeout・publish処理](https://github.com/scramble-robot/questix/blob/5dbdd7b44fd9dfda7cffc4a9f026858f6c2341cf/uart_joy_driver/src/uart_joy_driver_component.cpp)
- [UART設定](https://github.com/scramble-robot/questix/blob/5dbdd7b44fd9dfda7cffc4a9f026858f6c2341cf/serial_utils/src/serial_port.cpp)
- [timeoutとrelease filterの設定](https://github.com/scramble-robot/questix/blob/5dbdd7b44fd9dfda7cffc4a9f026858f6c2341cf/uart_joy_driver/config/uart_joy_driver_params.yaml)

キットauthorityは `CoRE2_sample_Document.zip`（2,686,664 bytes、SHA256 `C5A1F7A0BD4518B441FFCBC744D726235D0C41ED8447FD28B625B7C9385DC608`）。`CoRE2_sample/controller.ino` は1,847 bytes、SHA256 `F028899B65AD8CA8C73906A1CFD1559396A5291ABD02B550B34E9C4F1F305440`。`define.h`、main sketch、`process.ino`、`motor.ino` も読んで配列と停止経路を確認した。Doxygen生成HTMLを現行コードの代わりにauthorityとしない。

## 現状の相違と選択肢

| 項目 | QUESTiX | キット現状 | CoRE製品現状 |
|---|---|---|---|
| framing | LF、直前CRを許容 | LFまでString読取、先頭14文字を削除 | UARTも固定32 bytes、改行無し |
| 内容 | b0,b1,dpad,LX,LY,RX,RY | pitch、未使用、右wheel、左wheel、switch群、残り | flags/buttons/dpad/axes/triggers等 |
| validity | parse成功で受信時刻更新 | UARTに1 byteでもあれば先に時刻更新 | LAN CRC/sequence/input validity |
| 無受信timeout | 既定0.5秒 | 300ms | LAN100ms |
| neutral | buttons0、dpad0、axes128 | wheel0とlock等の制御が必要 | dpad8、axes128、triggers0 |

案A（推奨）はLAN binaryを保持してUARTだけをadapterで共通化。QUESTiX parserを変更せず、キット側を適応できる。案Bは両下流に32-byte binary parserを追加する方法で、CRC/sequence/validity/analog triggersをUARTにも持てるが、固定されたQUESTiX契約の変更とROS側移行が必要。案CはM5 Receiverに機器別出力modeを持たせる方法で、互換性は残るが選択ミス・試験組合せが増える。LAN自体をASCII化する必要はない。

## 提案する送信形式（既存QUESTiX契約の狭い共通部分）

```text
BB,BB,DD,LX,LY,RX,RY\n
00,00,00,80,80,80,80\n   ← neutral（説明部分は送らない）
```

1項目は必ず大文字16進2桁。7項目、comma6個、LF1個で21 bytes。prefix、function ID、空白、末尾commaを送らない。115200 8N1、50Hzを提案する。UART占有は1行約1.82ms、平均1050 bytes/s。

QUESTiX実装は7項目に加え、8項目なら先頭function ID=01を許容し、最初のcolon以前も捨てる。hex parserは1〜2文字を受け付ける。これらの許容幅を送信仕様として広げない。D-pad9/FFは既存testでneutralになるが、送信側は0〜8のみを生成する。

| UART項目 | 値と変換 |
|---|---|
| b0 | bits0..7 = A,B,X,Y,L,R,ZL,ZR。現行CONTROL buttons下位8bit |
| b1 | bits0..5 = Minus,Plus,Home,Capture,LStick,RStick。CONTROL buttons bits8..13。上位2bitは0 |
| dpad | neutral0、上1、右上2、右3、右下4、下5、左下6、左7、左上8。CONTROLの8→0、0..7→1..8 |
| LX,LY,RX,RY | 0..255、center128。方向反転はここで重ねない |

QUESTiXは `(byte-128)/127` を[-1,1]へclipし、4軸とも符号反転、deadzone処理する。ROS axesはLX0/LY1/RX3/RY4、dpad H6/V7で左・上が正。UARTにはanalog trigger量、sequence、CRC、input-valid、batteryが無いため、それらを維持できると説明してはいけない。ZL/ZRはbutton bitのみ。

## Receiverの安全責務

CONTROL decode/CRC/type/sequence/age/input validityを確認してから変換する。invalid flag付きnon-neutral payloadをそのまま出力しない。最後の有効入力が100msを超えた場合、disconnect/unsupported時、起動時はneutralを定期出力する。UIだけをneutralへ変更する現状のtimeout処理では不十分。

UART出力周期を受信packet arrivalから分離し、無受信でもneutralの50Hz出力を継続する。ただし有効入力ageは元の有効CONTROL受信時刻から計算し、定期再送で更新しない。CRC不正・duplicate/reverse等の拒否packetも有効入力時刻を更新しない。復帰時のsequence restart方針は既存契約をレビューして決め、弱めて通さない。

QUESTiXのrelease filterは既定2連続neutralを必要とし、1行だけのneutralでは以前の押下・軸を保持し得る。neutral継続が必要。UART自体が切れた場合は既定0.5秒timeoutとなり、CoREの100ms停止保証と同一ではない。必要な停止時間を決めた後、QUESTiX側のtimeout/release設定とROS下流の停止処理を別途検証する。100msのLAN閾値にUART周期・受信poll・filter・ROS配送遅延を足した実測を行い、end-to-end100msを未測定で保証しない。

ASCIIには破損を検出するCRCがない。hexの別の有効値への化けは検出できない。UARTでもCRC/validityが必須なら案Bを選ぶ判断になる。

## キットのcontroller.ino置換設計

`RxData` をQUESTiXの7byteで直接置き換えてはいけない。既存 `define.h` は `RxData[0]=pitch`、`[2]=right wheel`、`[3]=left wheel`、`[4] bit0=LOCK / bit1=ROLLER / bit2=SHOT` として参照している。

置換実装は固定長bufferのnonblocking byte蓄積とLF単位の検証を行い、7×2桁hexとcomma位置を検証してから一時配列をまとめて採用する。CRLFも受けられるがprefix削除は廃止する。過長行は次LFまで捨て、途中timeout・壊れた行・連続garbageで有効時刻を延命しない。`String.readStringUntil()` と `delay(10)` を取り除く。全経路でboolを返し、32-bit millis差のunsigned演算でwraparoundを扱う。

以下は具体的な操作割当案であり、実機の操作仕様としては未確定。

| キット機能 | 共通UARTからの変換案 |
|---|---|
| left/right wheel | LY/RYをcenter128から[-100,100]へ変換しRxData[3]/[2]へ。前進極性は車輪浮上試験で確認 |
| pitch | RXをRxData[0]へ（既存式では90〜180度、neutral128で約135度）。可動範囲・安全角を要確認 |
| operation enable | Lを押している間のみ許可。L=0ならRxData[4] bit0 LOCK=1 |
| roller / shot | B→bit1、A→bit2。ただしarmed状態での新規押下のみ受理 |

起動・invalid・100ms timeoutは `ControllerTimeout=true`、wheel0、LOCK=1、ROLLER/SHOT=0とする。接続復帰直後はLOCKを維持し、一度enable/roller/shotが全て離された正常frameを確認してから新しいenable押下でarmedへ戻す。切断前の押しっぱなしで再始動させない。通常の有効neutralもL=0なのでLOCKになる。

main loopはLOCK/timeoutでOperationEnable=0にし、RollerOnOff/ShotSeq/Shotmoveをreset、MotorAllOFF、SHOT待機角へ移行する。RMmotorTxDataはOperationEnable=0でTxVelを0にする。この既存経路へ接続する。ただし速度0を目標にするPD出力は電流0と同義ではなく、機械的な安全停止の検証が必要。

`controller.ino` だけで受信・配列変換を収める方針は可能。しかし既存 `Roller()` のdelay50やmotor.inoの `MotorOFF` にある `Dir[motor]`（2次元配列行をpin引数に渡す）など、別ファイルにもbuild/停止時間の確認事項がある。controllerの置換だけで全機安全・build成功と認定しない。停止時のpitch保持/退避、ローラー制動、射出の中断処理も確認する。

## 実装前の判断と検証

推奨案Aを採用する場合は、UART契約変更とキットの上記ボタン割当・enable方式・pitch範囲を確定する。次にM5 Receiver adapter、参照encoder/golden vectors、キットcontroller置換を同じ仕様で実装する。QUESTiXは受信形式を維持し、timeout/filterの設定変更は必要性を確認して別変更とする。

受入vector: neutral、14buttonの個別bit、8方向dpad、4軸の00/80/FF、同時押下。例 `01,00,00,80,80,80,80` はAのみ、`00,00,01,80,80,80,80` は上。CONTROL neutral dpad8をUART00に変換するtestを必須とする。

異常系: partial/連結/CRLF/過長/非hex/項目不足・過多/連続garbage/時刻wrap、input-invalid nonneutral、CRC不正、stale/duplicate、LAN loss、UART unplug、controller detach、押下中再接続。キットはneutralでLOCKし、unarmed状態から新しい操作なしにroller/shotが動かないことを検証する。

順序はhost conformance→M5とキットの個別clean build→UART loopback/capture→車輪浮上・射出無効で停止試験→許可された実機gate。配線・電圧レベル・共通GNDは現物資料で確認する。ユーザーの物理操作なしに接続実績を追加しない。添付ZIPは原本のまま保持し、実装時に差分と新ZIPを別名で作る。
