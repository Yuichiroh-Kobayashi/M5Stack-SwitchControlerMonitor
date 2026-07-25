# LAN protocol reuse analysis

## Scope and source of truth

This analysis is based on the current working tree versions of:

- `M5Stack-PS5CoREWirelessTransmitter.ino`
- `M5Stack-PS5CoREWirelessReceiver.ino`

The LAN product sketches must reuse this on-wire representation. The packed
24-byte `M5DS` datagram from `M5Stack-PS5CoRELanStackDiagnostic.ino` is a
diagnostic-only format and is not a product protocol.

## Existing Wireless transport

| Item | Existing implementation |
|---|---|
| Network transport | Wi-Fi AP plus TCP stream |
| Sender role | TCP server (`WiFiServer`) |
| Receiver role | TCP client (`WiFiClient`) |
| TCP port | `12345` |
| Sender address | SoftAP fixed at `192.168.4.1/24` |
| Receiver target | Literal `192.168.4.1:12345` |
| Additional output | Sender also emits every line on Serial2 at 115200 bps |
| Receiver output | Accepted newline-delimited text is forwarded to Serial2 with CRLF |

The transmitter writes one payload followed by LF to the connected TCP
client. TCP is a byte stream, so the receiver accumulates bytes until LF and
ignores CR. It does not assume that one TCP read equals one controller update.

## Existing on-wire record

The payload is a fixed-width, uppercase hexadecimal text record:

```text
BB,BB,DD,LX,LY,RX,RY
```

It is 20 ASCII bytes, followed by LF on TCP. Each field is exactly two hex
digits and commas separate the seven fields. There is no binary byte order;
the values are text. Serial2 uses the same 20-byte record followed by CRLF.

| Field | Meaning |
|---|---|
| first `BB` | A, B, X, Y, L, R, ZL, ZR in bits 0 through 7 |
| second `BB` | Minus, Plus, Home, Capture, L3, R3 in bits 0 through 5 |
| `DD` | 0 for neutral; otherwise DualSense hat value 0..7 plus one |
| `LX`, `LY` | left stick bytes, 00..FF |
| `RX`, `RY` | right stick bytes, 00..FF |

The receiver converts `DD=0` to internal dpad neutral value 8. Nonzero `DD`
is converted with `(DD - 1) & 0x0F`.

## Protocol properties requested for LAN reuse

| Property | Fact from Wireless implementation |
|---|---|
| UDP/TCP | TCP |
| Port | 12345 |
| Packet/record size | 20 ASCII payload bytes plus LF on TCP |
| Magic | none |
| Version | none |
| Sequence | none |
| Input-valid flag | none |
| Button bits | two hexadecimal bytes as described above |
| Dpad | one hexadecimal byte; neutral=0, directions=hat+1 |
| Stick values | four hexadecimal bytes |
| Sender interval | 20 ms |
| Receiver timeout | none |
| Sender client handling | one active TCP client; `setNoDelay(true)` |
| Receiver reconnect | Wi-Fi retry 3000 ms, TCP retry 1000 ms |

## Existing validation and fail-safe behavior

The receiver parses with `sscanf("%x,%x,%x,%x,%x,%x,%x", ...)` and clamps
all parsed integers to 0..255. A line longer than its 63-byte buffer is
discarded by resetting the buffer length.

There are two important limitations in the current Wireless receiver:

1. `parseRxLine()` returns false unless exactly seven fields parse, but its
   caller ignores the return value, increments `rxCount`, and forwards the
   original line to Serial2 anyway.
2. There is no receive timeout and no explicit neutralization after TCP or
   Wi-Fi loss. The last parsed controller state remains displayed.

The Wireless transmitter initializes its state to neutral, but it has no
on-wire validity flag and does not clear state on HID Ready transitions. The
LAN sketches therefore must add local session/timeout safety while keeping the
20-byte record unchanged. For invalid or stale input, the sender will transmit
the existing neutral record:

```text
00,00,00,80,80,80,80
```

The LAN receiver will validate before forwarding and will emit the same
neutral record on startup, before the first valid record, and after timeout.
Those changes strengthen local fail-safe behavior without defining a new
on-wire format.

## Wi-Fi-specific versus protocol logic

Wi-Fi-specific code comprises AP/STA configuration, SSID/password handling,
Wi-Fi connection state, and Wi-Fi/TCP reconnect scheduling. Protocol code
comprises the seven-field encoder, LF record framing, parser, clamping, button
mapping, dpad conversion, and Serial2 forwarding.

For LAN reuse:

- `WiFiServer`/`WiFiClient` are replaced with M5-Ethernet
  `EthernetServer`/`EthernetClient`.
- Sender remains the TCP server and receiver remains the TCP client.
- TCP port remains 12345.
- Sender LAN IP is `192.168.50.10/24`.
- Final receiver LAN IP is `192.168.50.20/24` and it connects to
  `192.168.50.10:12345`.
- The Sender may restrict the accepted peer to `192.168.50.20`.
- The seven-field payload and LF framing remain unchanged.

The project-level diagnostic UDP port 50000 remains reserved for the `M5DS`
diagnostic test. Using UDP 50000 for the product sketches would change both
the transport and port relative to the Wireless source of truth, so it is not
used by `M5Stack-PS5CoRELANSender.ino` or
`M5Stack-PS5CoRELANReceiver.ino`.

## Difference from the diagnostic datagram

| Item | Diagnostic | Wireless/LAN product reuse |
|---|---|---|
| Transport | UDP | TCP |
| Port | 50000 | 12345 |
| Size | fixed 24-byte binary datagram | 20 ASCII bytes plus LF record delimiter |
| Magic/version | `M5DS`, version 1 | none |
| Sequence/uptime | present | absent |
| Input-valid flag | present | absent; invalid input is encoded as neutral values |
| Byte order | packed little-endian integers | not applicable to hexadecimal text |

