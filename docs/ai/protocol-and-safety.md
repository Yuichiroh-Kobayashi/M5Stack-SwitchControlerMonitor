# Protocol and safety reference

## Fixed frame

The current LAN and receiver UART contract uses one explicitly encoded 32-byte frame.

| Bytes | Field |
|---|---|
| 0-1 | ASCII magic `CR` |
| 2 | Protocol version, currently 1 |
| 3 | Message type |
| 4-5 | Sequence, big-endian |
| 6-9 | Uptime, big-endian |
| 10-29 | 20-byte payload |
| 30-31 | CRC-16/CCITT-FALSE |

Message types:

- CONTROL: sender to receiver.
- STATUS: receiver to sender.

Transport parameters:

- UDP port: 50001.
- Nominal CONTROL frequency: 100 Hz.
- Nominal STATUS frequency: 100 Hz.
- Nominal period: 10 ms (user-confirmed target 2026-09-06, implementation candidate; physical qualification pending). The wire format/version is unchanged. An explicit 20 ms comparison build remains available.
- Validity timeout: 100 ms.
- UART: exact 32-byte frame, 115200 8N1, no CR/LF and no ASCII conversion.
- Adopted 2026-09-06: UART CONTROL sequence and uptime belong to Receiver, independently of LAN CONTROL/STATUS. UART runs every10ms even in a20ms LAN comparison build. See [the adopted UART/Mega contract](../uart-mega-contract.md) for source freshness, neutral latching, reboot, backpressure and operator rearm. Layout/version/CRC remain unchanged; byte-identical LAN forwarding ends.

## Encoding rules

- Encode and decode byte-by-byte.
- Keep multibyte fields big-endian.
- Never use a packed struct as the wire representation.
- Keep CRC coverage and constants identical in C++ and the reference implementation.
- Reject bad magic, version, type, length, and CRC.
- Track sequence gaps without hiding wraparound behavior.

## Safety state

Neutral controller state:

- D-pad neutral.
- Sticks centered at 128.
- Triggers released at 0 unless the accepted profile defines a different normalized input that is converted before the wire layer.
- All buttons false.

Use neutral state when:

- No controller has enumerated.
- The controller profile is unsupported.
- The last valid HID report is older than the controller timeout.
- The controller disconnects.
- Parser validity fails.
- A sender-side fatal input condition occurs.

Receiver behavior:

- Mark CONTROL invalid after timeout.
- Do not continue using the last active CONTROL frame.
- Keep UART output and UI consistent with current validity.

Automatic reset is not a safety substitute. Recovery behavior must be designed and validated separately after the root cause is understood.
