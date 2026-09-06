# UART safety: historical decision record

Superseded on 2026-09-06 by the user's approval of [the Receiver-owned UART and Mega2560 contract](uart-mega-contract.md). The facts and pending-decision language below describe the pre-change implementation; they are retained as the rationale, not the current behavior.

Owner: [#9](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/9). Physical acceptance: [#7](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/7). This is a proposal, not an adopted protocol/output change.

## FACT

`M5Stack-PS5CoRELANReceiver.ino::processControlFrame()` validates LAN framing/CRC/sequence, neutralizes its display state for input-invalid, then writes the original frame to Serial2. `serviceTimeout()` neutralizes display state without emitting a UART neutral frame. Therefore an input-invalid/nonneutral packet may reach UART, and LAN silence produces no UART stop frame. The current nominal100Hz change does not fix either behavior.

## Why sequence ownership must be explicit

Example: the downstream accepted CONTROL sequence100 with active input. If Receiver emits a timeout neutral with the same sequence100, a duplicate-rejecting downstream may ignore it. If Receiver synthesizes101, the next real Sender101 may be rejected as a duplicate. Repeated local neutral frames can move the UART sequence further ahead of LAN. Disabling downstream sequence checks to make this work is not acceptable.

| Option | Result | Required agreement |
|---|---|---|
| Preserve transparent UART forwarding; downstream enforces its own100ms watchdog | No new UART sequence producer; does not itself fulfill a Receiver-emitted neutral requirement | Pin and test every downstream consumer's timeout/invalid handling; cannot claim current downstream compatibility |
| Receiver owns an independent periodic UART CONTROL stream | Receiver can output neutral on startup/invalid/timeout and continue on silence | Specify UART sequence/uptime ownership, initialization and reconnect rules; update source, reference vectors, contract docs and consumer expectations together |
| Explicit ASCII adapter for existing QUESTiX contract | Fits the previously studied line parser | Separate decision in #15; loses binary CRC/sequence and needs kit adaptation; not adopted here |

For a binary UART that must actively emit neutral, the second option is the recommended design candidate. It preserves32-byte layout but changes header provenance and exact-forwarding semantics. A successful LAN build is not authorization to assume an unknown consumer accepts that change. Repository maintainer approval of the selected output contract is the resume condition for this task.

## Acceptance to carry into implementation

- Define exactly which clock and sequence the UART producer owns, including wrap and reboot.
- Check input-invalid/nonneutral, CRC failure, duplicate/reverse, silence, reconnect, partial UART write and UART backpressure.
- Never refresh source input age from a periodic UART resend.
- Retain100ms detection threshold and measure the additional scheduling/serialization/consumer delay. At115200 8N1, a32-byte frame takes about2.778ms on the wire; do not call a frame started at100ms an end-to-end stop completed within100ms.
- Transfer physical producer-to-consumer capture to #7 and #15 as appropriate. Keep source/host/build acceptance separate.

No UART safety fix, format change, flash, consumer modification or physical stop test was performed by this decision record.
