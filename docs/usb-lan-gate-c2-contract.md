# USB-LAN Gate C2 Canonical Contract

This C2 contract supersedes all earlier Gate C2 proposals,
including docs/handoffs/usb-lan-antigravity/05_next_test_gates.md.

Earlier documents remain historical evidence and are not execution authority.

This document is the **sole Gate C2 execution authority**. No other draft,
prior chat content, or informally referenced "Design v2.1" document exists
inside this repository as a separate artifact; a repository-wide search
(`git grep`/`Grep` for `v2.1`, `Design v2`, `UDP_ECHO`, `Mode 16`,
`ECHO_RESPONSE_WATCHDOG`) found no such file. This contract is therefore
constructed directly from two sources, both explicit and unambiguous:

1. The C1 accepted architecture (`docs/usb-lan-fixed10-gates-c1-c4.md`,
   Mode 15, `tools/usb_lan_gate_c1_runner.ps1`, `tools/usb_lan_gate_peer.py`)
   reused as the base design pattern per the reuse-first implementation
   principle.
2. The external final decisions supplied verbatim in this task's P0-4
   section, reproduced and integrated below without weakening.

STATUS: DESIGN FROZEN (R3) / FIRMWARE+PEER LOGIC ACCEPTED / CONTROL-PLANE R3 FIXED
GATE C2 HARDWARE TEST: NOT RUN
PHYSICAL_PREFLIGHT: NOT RUN

## R3 revision note

A second external review of `C2-implementation-review-r2-20260819-130509-1823c43c`
closed all R1 findings (B-01 through B-07) and accepted the C2 firmware/peer
source logic, but found three narrow control-plane blockers before physical
preflight could be authorized. Mode 16 firmware, the C2 peer, and the build
matrix were **not** touched for R3 -- only `tools/usb_lan_gate_c2_runner.ps1`
and documentation were corrected:

```text
B-08: C2-reviewed-source-manifest.csv now carries forward the C1 recursive
      inventory identity model for the isolated M5Unified and M5GFX trees
      (previously only referenced by the build matrix's --library flags,
      not protected by manifest identity)
B-09: reviewed source identity is now verified twice in the physical
      trial -- once before the fresh build, once after, before any upload
      -- so a source/dependency change introduced during the build stops
      the trial before upload
B-10: -PreflightPhysicalTrial -EmitPlan's stale "arm before upload" plan
      output corrected to the real, current orchestration order
plus: a peer-alive check before upload (low-risk hardening)
```

## R2 revision note

An external review of the first offline implementation package
(`C2-implementation-review-20260819-120725-ce017c3e`) returned
`C2_IMPLEMENTATION=FIX_FIRST` with seven blocking defects (B-01 through
B-07). This document has been corrected in place to restore/add the
following, which the first draft omitted or weakened:

```text
B-01: condition-driven ACTIVE -> DRAIN -> finish trial completion,
      OUTSTANDING_FINAL == 0 required for PASS
B-02: exact four-way equality, no tail tolerance
B-03/B-04: device-side strict per-field echo validation, including
      source IP/port, with a dedicated hard-zero counter per failure mode
B-05/B-06: corrected physical orchestration order (arm strictly after
      UPLOAD_PASS, never before), and precise BOUND_NOT_ARMED /
      ARMED_WAIT_SEQUENCE_ZERO packet classification
      (BOUND_NOT_ARMED_PACKET_COUNT, PRE_ADMISSION_NON_C2_COUNT)
B-07: this document itself, brought back to full-authority completeness
```

The review package's own findings are not reproduced verbatim here; this
contract states the corrected, current requirements directly.

## Scope

Gate C2 extends Gate C1's transmit-only Fixed10Half UDP traffic to a
bidirectional UDP echo test. The Sender (CoreS3 SE + USB Module + LAN
Module) transmits fixed 32-byte frames to a single PC Python peer over the
same C1 large-buffer, single-socket, port-50001 configuration, and the peer
echoes each valid frame back to the exact source `(ip, port)` it was
received from. The device measures echo round-trip liveness against a hard
500 ms watchdog boundary and reports round-trip time as non-gating evidence.

Gate C2 does not use the physical Receiver. It does not change
`src/core_protocol`, the product Sender, or the Receiver.

## Architecture reuse (from C1 / Mode 15)

The following C1 elements are reused unchanged and must not be refactored
by C2:

```text
InitOrder 0 (LAN first, then USB Host)
PHY profile 2 (Fixed10Half)
MAX_SOCK_NUM=2, ETHERNET_LARGE_BUFFERS compile-time flags
Shared SPI ownership helpers (CS/RESET sequencing, GPIO1/GPIO13/GPIO0)
W5500 setup / PHYCFGR / VERSIONR / buffer-map readback sequence
udp.begin(50001), single UDP socket
20 ms nominal TX cadence, burst catch-up prohibited
Usb.Task() first each loop
HID stall derivation (100 ms threshold) and terminal marker discipline
```

C2 adds Mode 16 alongside Mode 15 without modifying Mode 15's existing
control flow, buffer map, or terminal marker contract.

## Mode 16 frame format

```text
USB_LAN_TEST_MODE=16
USB_FIXED10_UDP_ECHO
```

| Offset | Size | Field |
| ---: | ---: | --- |
| 0 | 4 | Magic `C2UD` |
| 4 | 1 | Version `1` |
| 5 | 1 | Gate ID `2` |
| 6 | 1 | Flags |
| 7 | 1 | Frame length `32` |
| 8 | 4 | Sequence, uint32 big-endian |
| 12 | 4 | Device micros, uint32 big-endian |
| 16 | 14 | `((sequence + index * 17 + 0x5A) & 0xFF)` |
| 30 | 2 | CRC16/CCITT-FALSE over bytes 0-29 |

Required flags: `0x03` (same bit-0/bit-1 HORI-running / Fixed10Half-link
semantics as Mode 15). Reserved bits `0xFC` must be 0.

The peer echoes the identical 32-byte frame back verbatim to the exact
source `(ip, port)` observed via `recvfrom`. The device correlates the echo
by sequence number against its outstanding-send table and computes RTT from
`device micros` at send time versus receive time of the matching echo.

Fixed condition (unchanged from C1):

```text
Fixed10Half
LAN first
single UDP socket
port 50001
same C1 large-buffer map
20 ms nominal TX
burst catch-up prohibited
Usb.Task() first
```

## Final timing / liveness

```text
ECHO_RESPONSE_WATCHDOG_MS = 500
OUTSTANDING_CAPACITY = 32

dynamic allocation:
prohibited

silent eviction:
prohibited

table overflow:
hard FAIL
```

500 ms is a finite liveness bound, not a latency performance requirement.
The outstanding-send table is a fixed-size array of 32 slots
(sequence, device-micros-sent, in-use flag). No `malloc`/`new`/STL
container growth is used. If a 33rd send would be required while all 32
slots are occupied and unacknowledged/unexpired, this is a hard FAIL
(`OUTSTANDING_TABLE_OVERFLOW`), not a silently dropped or evicted entry.

## Device-side strict echo validation (B-03/B-04)

Every received UDP datagram on the device is validated field-by-field, in
this order, before it may be consumed as a valid echo. Each rejection
increments its own dedicated hard-zero counter and hard-fails the trial
immediately (no packet is silently dropped or merely counted):

```text
source IP != Config::kC1PeerIp        -> ECHO_SOURCE_IP_ERROR   -> hard FAIL
source port != Config::kPort          -> ECHO_SOURCE_PORT_ERROR -> hard FAIL
length != 32                          -> ECHO_LENGTH_ERROR      -> hard FAIL
magic != "C2UD"                       -> ECHO_MAGIC_ERROR       -> hard FAIL
version != 1                          -> ECHO_VERSION_ERROR     -> hard FAIL
gate != 2                             -> ECHO_GATE_ERROR        -> hard FAIL
flags != 0x03                         -> ECHO_FLAGS_ERROR       -> hard FAIL
CRC mismatch                          -> ECHO_CRC_ERROR         -> hard FAIL
payload pattern mismatch              -> ECHO_PAYLOAD_ERROR     -> hard FAIL
sequence has no outstanding entry     -> ECHO_UNMATCHED         -> hard FAIL
echoed device-micros != sent value    -> ECHO_TIMESTAMP_MISMATCH-> hard FAIL
```

Source validation uses `EthernetUDP::remoteIP()`/`remotePort()`, which
`EthernetUdp.cpp`'s `parsePacket()` (frozen reviewed source, role
`m5_ethernet_udp`) populates before returning, and which are readable
immediately after `parsePacket()` and before `read()`. This API was
confirmed present and usable during R2 remediation; no dependency source
change was needed or made.

Every one of these fields, plus `UDP_RX_INVALID`, is required `== 0` for a
device PASS (see Firmware PASS condition below). A field is never left
unenforced merely because a different check would also have caught the
same bad packet.

## Echo age boundary

Only after a packet passes every check above does the watchdog age
boundary apply:

```text
age_us = uint32_wrap_safe(now - sentMicros)

if age_us >= 500000:
    do not consume as valid echo
    ECHO_LATE_AT_OR_AFTER_WATCHDOG++
    hard FAIL
```

The periodic watchdog sweep (checking outstanding entries that have not yet
received an echo) uses the identical `age_us >= 500000` condition to
classify an entry as expired. `uint32_wrap_safe` subtraction is
`(uint32_t)(now - sentMicros)`, which is correct across `micros()` wraparound
because both operands and the result are unsigned 32-bit.

## RTT evidence

RTT is non-gating evidence. Firmware emits only:

```text
ECHO_RTT_MIN_US
ECHO_RTT_MAX_US

ECHO_RTT_BUCKET_0_5MS
ECHO_RTT_BUCKET_5_10MS
ECHO_RTT_BUCKET_10_20MS
ECHO_RTT_BUCKET_20_50MS
ECHO_RTT_BUCKET_50_100MS
ECHO_RTT_BUCKET_100_200MS
ECHO_RTT_BUCKET_200_400MS
ECHO_RTT_BUCKET_400_500MS
```

Hard evidence invariant:

```text
sum(all 8 RTT bucket counts) == UDP_ECHO_VALID_TOTAL
```

An echo with `age_us >= 500000` is never placed into a bucket (it is
counted only in `ECHO_LATE_AT_OR_AFTER_WATCHDOG` and triggers hard FAIL, per
the echo age boundary above). Firmware does not compute percentiles; buckets
are raw counters incremented at echo-consume time using half-open intervals
`[bucket_lo_us, bucket_hi_us)`, with the final bucket `[400000, 500000)`.

## Peer admission

Three-state:

```text
BOUND_NOT_ARMED
-> ARMED_WAIT_SEQUENCE_ZERO
-> ADMITTED
```

IPC:

```text
--arm-file
runner -> peer request

--armed-file
peer -> runner acknowledgement
```

Both files live inside the fresh trial root (the per-trial output directory
created by the C2 runner, matching the C1 convention of never reusing an
existing directory).

At peer start:

```text
arm-file must not exist
armed-file must not exist
```

If either already exists at peer start, the peer FAILs immediately
(`PEER_RESULT=FAIL`, `REASON=PRECONDITION_ARM_STATE_INVALID`) rather than
guessing intent.

Peer behavior:

```text
detect arm-file
-> transition to ARMED_WAIT_SEQUENCE_ZERO
-> atomically create armed-file
-> log PEER_ARMED=1
```

"Atomically create" means write to a temporary file in the same directory
and `os.replace()` it onto the final `armed-file` path, so the runner never
observes a partially written armed-file.

The runner confirms admission readiness only after observing both the
armed-file's existence and a `PEER_ARMED=1` line in the peer's log/CSV
stream.

While in `BOUND_NOT_ARMED`:

```text
all packets:
log only
BOUND_NOT_ARMED_PACKET_COUNT++
no echo
no strict counters (rx_total, crc_error, format_error, etc. untouched)
```

While in `ARMED_WAIT_SEQUENCE_ZERO`, every received packet is classified
into exactly one of three outcomes, evaluated against the expected source
`(ip, port)` and full C2UD structural validity (magic/version/gate/length/
flags/CRC/payload) without yet touching the strict per-packet validator
state:

```text
fully valid C2 frame, sequence == 0:
    -> admit (state becomes ADMITTED)
    -> this frame is then the FIRST frame counted by the strict validator
       (RX_TOTAL, VALID_RX_TOTAL, FIRST_SEQUENCE=0, ...) and is echoed

fully valid C2 frame, sequence != 0:
    -> BLOCKED_ADMISSION_SEQUENCE_MISS (see below)

anything else (wrong source, wrong magic/version/gate/CRC/payload/flags,
garbage, or genuinely old C1UD-magic traffic still in flight):
    -> log only
    -> PRE_ADMISSION_NON_C2_COUNT++
    -> no echo
    -> the strict per-packet validator counters (CRC_ERROR, FORMAT_ERROR,
       UNEXPECTED_SOURCE, etc.) are NOT incremented -- pre-admission noise
       must never poison the counters that gate the final Peer PASS
       contract
    -> remains in ARMED_WAIT_SEQUENCE_ZERO, waiting for the next packet
```

This means old/stale traffic (e.g. a leftover C1UD frame still in flight
from a prior gate, or any other non-C2 noise) observed before the genuine
Mode 16 stream starts does not by itself block or fail admission: it is
tracked in `PRE_ADMISSION_NON_C2_COUNT` and otherwise ignored, and a
subsequent genuine C2 sequence-0 frame still admits normally, potentially
leading to a final `PEER_RESULT=PASS`.

After arming, if the first fully-valid C2 frame received is not sequence 0:

```text
BLOCKED_ADMISSION_SEQUENCE_MISS
```

This is classified separately from a C2 network FAIL — it indicates the
device started transmitting before the operator-driven arm handshake
completed, not a protocol or link defect. Automatic retry of admission is
prohibited; the trial ends and requires a fresh trial root and a human
decision to re-run.

Once `ADMITTED`, all subsequent frame handling reverts to the strict C1-style
per-packet validation contract (magic/version/gate/length/flags/CRC/payload/
source-IP/source-port), extended with exactly-once echo semantics.

## Scheduler

Both C2-S1 and C2-T1:

```text
SCHEDULER_MISSED_DEADLINE == 0
```

is a hard criterion (unlike C1-S1, where a single missed deadline was
recorded as warning-only). Any missed deadline is classified:

```text
C2_TIMING_FAIL
```

Burst catch-up remains prohibited; a missed 20 ms period is skipped, not
compensated, and its occurrence alone fails the trial.

## Condition-driven trial completion: ACTIVE -> DRAIN (B-01)

Reaching the nominal trial duration (`USB_LAN_TEST_DURATION_MS`) does
**not** finish the trial directly. The device runs a two-phase state
machine:

```text
ACTIVE:
    TX (20 ms scheduler) / RX / watchdog / USB-HID-PHY monitoring all active

duration reached:
    stop scheduling new TX
    enter DRAIN
    record drainStartMs
    emit C2_ACTIVE_COMPLETE=1 ACTIVE_RUNTIME_MS=... OUTSTANDING_AT_DRAIN_START=...

DRAIN:
    Usb.Task() first (unchanged)
    USB/HID/PHY monitoring continue (detach, stall, register-mismatch,
      link-change checks all remain hard-fail-capable)
    RX: parsePacket()/read() max once per loop (unchanged bound)
    watchdog sweep continues
    TX prohibited (no new frames scheduled)

PASS termination (from DRAIN):
    outstanding count == 0
    -> c2Finish(true, "DRAIN_COMPLETE_OUTSTANDING_EMPTY")

FAIL termination (from ACTIVE or DRAIN):
    watchdog expiry, or any other existing hard-failure condition
```

DRAIN has no separate device-side timeout: because every outstanding entry
is individually bounded by the 500 ms echo watchdog, DRAIN always
terminates within at most one watchdog boundary past its start — either
every outstanding entry is echoed and consumed (`outstanding == 0`, PASS)
or the watchdog sweep catches an aged entry (hard FAIL). This is bounded
well inside the runner's 40 s/90 s external result budget.

Required output fields (emitted by both the periodic statistics line and
the `TEST_COMPLETE` terminal line):

```text
ACTIVE_RUNTIME_MS
DRAIN_RUNTIME_MS
OUTSTANDING_FINAL
```

`runtimePass` (the firmware's own PASS/FAIL decision) always requires:

```text
OUTSTANDING_FINAL == 0
```

in addition to every other condition in "Firmware PASS condition" below.
This holds regardless of which termination path was taken: a FAIL during
ACTIVE (before DRAIN was ever entered) reports `OUTSTANDING_FINAL` as
whatever was outstanding at the moment of failure (informational), while
`runtimePass` is already `false` from the failing condition itself.

## M5-Ethernet RX residual risk

Using the exact reviewed source frozen under C1
(`build-temp\usb-lan-isolation\freeze\C1-final-20260818-005403-666bf93b\source\reviewed-files\m5_ethernet_udp\EthernetUdp.cpp`
and `...\m5_ethernet_socket\socket.cpp`) as authority: `EthernetUdp::parsePacket()`
and the underlying `socket.cpp` receive path contain internal loops whose
worst-case bound is governed by W5500 hardware/driver state rather than by
an application-visible iteration cap. This is a residual, undocumented,
unbounded-loop risk on the RX path that C2 does not attempt to fix, because
fixing it would require modifying M5-Ethernet dependency source, which this
task's implementation writes explicitly prohibit.

Dependency source is not modified. Application-side mitigation is bounding
how often and how the application calls into that path:

```text
Usb.Task() first
udp.parsePacket() max once per loop
udp.read() max once per loop
unbounded receive-drain loop prohibited
```

If the internal call nonetheless hangs, this manifests as the device loop
stalling (no further serial terminal progress, no further TX/RX), which is
indistinguishable on-device from a true infinite loop. C2 does not attempt
to detect this from firmware itself (no watchdog-triggered reset is added,
per the safety invariant against hiding root cause with automatic
recovery). Instead, this failure mode is caught externally:

```text
ORCHESTRATION_STALL / TIMEOUT
```

raised by the C2 runner's external result timeout (below), which is
explicitly classified as separate from a firmware or peer logical FAIL —
it means "the process stopped producing expected evidence within the
external time budget," not "the device reported a defined error."

## Runner external result timeout

```text
C2-S1:
40 seconds

C2-T1:
90 seconds
```

These are the **total** wall-clock budgets the PowerShell runner enforces
for the serial-capture/result wait (`Wait-Job -Job $serialJob -Timeout
$externalResultTimeoutSeconds` in `tools/usb_lan_gate_c2_runner.ps1`),
measured from the moment that wait starts (immediately after upload,
before the device has even begun its ACTIVE phase). They are **not** an
additional 40 s/90 s added on top of the nominal ACTIVE duration (10 s for
C2-S1, 60 s for C2-T1) — the entire ACTIVE + DRAIN trial, plus evidence
flush, must complete within this single budget. (The serial-capture job's
own internal capture window, `durationSeconds + 30`, is a generous inner
allowance; the binding constraint reported to the operator is the external
`$externalResultTimeoutSeconds` budget.) The armed-file handshake has its
own, separate, smaller budget (10 s, see "Peer admission").

Exceeding the external timeout is `ORCHESTRATION_STALL/TIMEOUT` and is
recorded and reported distinctly from `C2_TIMING_FAIL`,
`BLOCKED_ADMISSION_SEQUENCE_MISS`, or any Firmware/Peer `FAIL`.

## Physical orchestration order (B-05/B-06/B-09/B-10)

The runner's physical trial follows this exact order. Arming strictly
after `UPLOAD_PASS` is mandatory; arming before upload is prohibited,
because the peer must not be told to admit traffic until the exact
firmware under test is confirmed present on the device. Reviewed source
identity is verified twice -- once before the fresh build, once after --
so that a source or dependency change introduced during the (potentially
long) build stops the trial before any upload is attempted:

```text
1. peer start
2. peer is BOUND_NOT_ARMED
3. PEER_READY observed
4. reviewed source identity PASS (pre-build)
   -> REVIEWED_SOURCE_IDENTITY_PHASE=PRE_BUILD PASS=1
5. fresh build (arduino-cli compile)
6. reviewed source identity PASS (post-build)
   -> REVIEWED_SOURCE_IDENTITY_PHASE=POST_BUILD PASS=1
   -> a mismatch here is BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH,
      raised before upload is attempted
7. pre-upload COM4 exact-PNP identity check
8. peer-alive check: if the trial peer process already exited during the
   build, stop with BLOCKED_PEER_PROCESS_NOT_RUNNING_PRE_UPLOAD before
   upload (low-risk hardening; does not change the C2 experiment itself)
9. upload
10. UPLOAD_PASS
11. arm-file create
12. armed-file + PEER_ARMED=1 acknowledgement (budget 10 s,
    ORCHESTRATION_STALL/TIMEOUT on timeout)
13. serial capture / trial evidence collection
```

This is the corrected order used both by the runner's actual
`-RunPhysicalTrial` implementation and by `-PreflightPhysicalTrial
-EmitPlan`'s `PLANNED_ORCHESTRATION_ORDER` output; the two must never
diverge.

## Physical progression

```text
C2-S1:
10 s + condition-driven drain
external review required

C2-T1:
60 s + condition-driven drain
external review required

automatic progression:
prohibited
```

"Condition-driven drain" means the runner keeps the peer and serial capture
alive past the nominal 10 s / 60 s duration only until the expected
completion evidence (serial `TRIAL_COMPLETE`, peer summary, watchdog-final
state) is observed or the external result timeout above is hit — it does
not mean an unbounded wait. C2-T1 may only be executed after a human has
reviewed the C2-S1 evidence; the runner and this contract do not
automatically chain C2-S1 into C2-T1.

Both C2-S1 and C2-T1 physical execution are out of scope for this
implementation task (see the task's absolute physical prohibition); the
runner's `-RunPhysicalTrial` / `-PreflightPhysicalTrial` surface may be
implemented as future capability but is not invoked here.

## Firmware PASS condition (Mode 16)

Reusing the C1 firmware-PASS pattern, extended for echo/watchdog/RTT:

```text
UDP_TX_TOTAL > 0
UDP_TX_FAIL == 0
UDP_ECHO_VALID_TOTAL > 0
ECHO_LATE_AT_OR_AFTER_WATCHDOG == 0
OUTSTANDING_TABLE_OVERFLOW == 0
OUTSTANDING_FINAL == 0
SCHEDULER_MISSED_DEADLINE == 0
sum(ECHO_RTT_BUCKET_*) == UDP_ECHO_VALID_TOTAL
UDP_RX_INVALID == 0
ECHO_MAGIC_ERROR == 0
ECHO_VERSION_ERROR == 0
ECHO_GATE_ERROR == 0
ECHO_LENGTH_ERROR == 0
ECHO_CRC_ERROR == 0
ECHO_PAYLOAD_ERROR == 0
ECHO_FLAGS_ERROR == 0
ECHO_SOURCE_IP_ERROR == 0
ECHO_SOURCE_PORT_ERROR == 0
ECHO_UNMATCHED == 0
ECHO_TIMESTAMP_MISMATCH == 0
HID_STALL_COUNT == 0
HID_READY_DROP == 0
FINAL_USB_STATE == 90
FINAL_HID_READY == 1
FINAL_PHY_OK == 1
FINAL_VERSION_OK == 1
FINAL_BUFFER_MAP_OK == 1
MAX_REGISTER_TRIPLE_READ_MISMATCH == 0
SPI_CORRUPTION_SUSPECTED == 0
TEST_MODE == 16
TEST_MODE_NAME == USB_FIXED10_UDP_ECHO
```

Any single violation is a hard FAIL of the corresponding named category
(`C2_TIMING_FAIL` for the scheduler condition; a dedicated FAIL reason token
for each other condition). No condition is skipped or downgraded to
warning-only for C2 (contrast with C1-S1's scheduler warning allowance,
which does not carry over).

## Peer PASS contract (C2)

In addition to the C1-style per-packet validation counters (CRC, length,
format, payload, source IP, source port, flags, sequence gap, duplicate,
out-of-order, all `== 0` required for PASS), the C2 peer additionally
requires:

```text
PEER_ARMED == 1
ADMISSION_SEQUENCE_ZERO_OK == 1
ECHO_SENT_TOTAL == VALID_RX_TOTAL_POST_ADMISSION
ECHO_SEND_FAILURES == 0
UNSOLICITED_ECHO_SENT == 0
```

`UNSOLICITED_ECHO_SENT` guards the exactly-once echo contract: the peer
must never send an echo that was not directly triggered by a validated
inbound frame, and must never re-send an echo for a frame it already
echoed (no retransmission on timeout — the device's watchdog, not the peer,
owns liveness classification).

`BOUND_NOT_ARMED_PACKET_COUNT` and `PRE_ADMISSION_NON_C2_COUNT` are always
reported but are informational — neither is required to be zero for PASS,
since legitimate pre-admission noise (operator arming slightly after the
device has already sent a stray frame from a prior state, or leftover
traffic from an earlier gate) does not by itself indicate a defect. See
"Peer admission" above for exactly how each state classifies a packet.

## Four-way reconciliation (C2)

Condition-driven drain (B-01) guarantees `OUTSTANDING_FINAL == 0` at a true
device PASS: every frame the device sent was either validly echoed and
consumed, or the trial hard-failed before reaching a clean finish. This
makes exact equality achievable and required — there is no tolerance for
in-flight tail packets, because DRAIN's purpose is precisely to eliminate
them before the trial is allowed to report PASS:

```text
device UDP_TX_TOTAL > 0, UDP_TX_FAIL == 0
device UDP_TX_TOTAL == peer VALID_RX_TOTAL_POST_ADMISSION   (exact)
device UDP_TX_TOTAL == peer ECHO_SENT_TOTAL                 (exact)
device UDP_ECHO_VALID_TOTAL == peer ECHO_SENT_TOTAL         (exact)
device ECHO_LATE_AT_OR_AFTER_WATCHDOG == 0
device OUTSTANDING_TABLE_OVERFLOW == 0
device OUTSTANDING_FINAL == 0
peer ECHO_SENT_TOTAL <= peer VALID_RX_TOTAL_POST_ADMISSION
  (guards against a peer "double consume": it must never report sending
  more echoes than frames it counted as validly admitted)
per-sequence invariant: every device-sent sequence has at most one
  device-consumed echo and at most one peer-sent echo
```

A difference of even one frame in any of the three exact-equality checks
above is a FAIL, not a warning. There is no tail-tolerance window in this
contract or in the runner implementation.

All four layers (Firmware PASS, Serial parser PASS, Peer PASS, Cross-
reconciliation PASS) must hold simultaneously for
`C2_TRIAL_RESULT=PASS TRIAL=C2-S1` / `C2_TRIAL_RESULT=PASS TRIAL=C2-T1`
(the marker actually emitted by `Get-C2TrialResultMarker` in
`tools/usb_lan_gate_c2_runner.ps1`), mirroring the C1 four-layer contract
structure.

## Not verified by this contract alone

This contract document defines requirements only. It does not itself
constitute implementation, offline validation, or hardware Pass evidence.
Those are produced by Phase I / V / R of this task and by any future
physical trial, respectively.

## Marker

```text
P0_4_C2_CANONICAL_CONTRACT_FROZEN=PASS
```
