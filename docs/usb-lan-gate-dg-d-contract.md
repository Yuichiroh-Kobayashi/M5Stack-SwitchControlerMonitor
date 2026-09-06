# USB-LAN Gate DG-D Contract

## Status and authority

DG-D is `POSITIVE_PARSE_IMMEDIATE_NULL_DISCARD`. This document defines the
implementation and future evidence contract only. It does not authorize upload,
serial access, peer execution, network traffic, or a physical trial. Gate C3
remains NO-GO.

The firmware semantic baseline is the exact frozen C1 source from generation
`C1-final-20260818-005403-666bf93b`, size 68507, SHA-256
`65529BC8A41374FD113FBB844D20432C030B5FBAF051C5EBAB9624C8F060FABB`.
C2 is read-only behavioral reference and is not a source donor.

The pinned M5-Ethernet dependency is version 4.0.0. In the exact accepted
`EthernetUdp.cpp`, `EthernetUDP::available()` returns only `_remaining`. It is a
software invariant query with no SPI, socket call, W5500 register access, or
mutation. It does not prove that the W5500 RX buffer is empty, that no next
datagram is queued, or that `RX_RSR`/`RX_inc` are zero.

## Scientific question and treatment

The future physical question is whether repeated positive `parsePacket()` plus
immediate same-iteration null retirement reproduces the C2-type USB/HID failure
while non-null payload transfer and C2 application validation/bookkeeping are
absent.

The manipulated bundle is:

```text
positive receive-availability observation
8-byte UDP pseudo-header RX-memory read
EthernetUDP::_remaining creation
immediate udp.read(static_cast<uint8_t *>(nullptr), 32)
software RX pointer/cache change
conditional Sn_RX_RD write and RECV command
possible Sn_CR completion polling
additional LAN SPI and loop timing
```

The UDP payload is exactly 32 bytes. The W5500/library representation is an
8-byte pseudo-header plus the 32-byte payload, totaling 40 bytes.

DG-D excludes non-null payload-byte transfer to MCU RAM, an application payload
buffer, application payload/source access, format/magic/version/gate/flags/CRC
validation, outstanding entries, RTT, watchdog/liveness bookkeeping, retry,
pacing, sleep, batching, and recovery. M5-Ethernet is not modified and DG-D does
not claim direct `Sn_RX_RD`, `RECV`, or `Sn_CR` counts.

## Fixed firmware identity and ordering

```text
TEST_MODE=18
TEST_MODE_NAME=USB_FIXED10_UDP_POSITIVE_PARSE_IMMEDIATE_NULL_DISCARD
PHY=Fixed10Half
device=192.168.50.10:50001
peer=192.168.50.30:50001
EXPECTED_SOURCE=(192.168.50.10,50001)
REQUIRED_BIND=(192.168.50.30,50001)
INGRESS_DESTINATION=(192.168.50.10,50001)
frame=C1UD, 32 bytes
TX cadence=20 ms nominal
```

Per-loop order is fixed:

```text
Usb.Task and identity update
HORI 0F0D/0202 / HID health
periodic PHY, link, VERSIONR, buffer-map, and MAX/SPI health
pre-parse udp.available invariant
at most one parsePacket call
immediate same-iteration null discard after a positive 32-byte result
post-discard udp.available invariant
TX scheduler only while ACTIVE and only after a successful treatment iteration
loop/statistics accounting
ACTIVE/DRAIN/finalization
```

No TX may occur after a treatment invariant fails.

## Fail-closed receive invariants

Immediately before `parsePacket()`, `udp.available()` must be zero. A nonzero
value increments `RX_PRE_PARSE_REMAINING_NONZERO`, blocks with
`BLOCKED_DG_D_PRE_PARSE_REMAINING_NONZERO`, skips parsing, and permanently
prevents later TX.

Each loop starts at most one parse call. Started and completed calls are counted
separately. Zero, positive, and negative returns are mutually exclusive. A
negative return blocks with `BLOCKED_DG_D_PARSE_API_NEGATIVE`.

A positive return must be 32. Any other size records the first and last observed
size and blocks with `BLOCKED_DG_D_POSITIVE_SIZE_NOT_32`; there is no second
parse and no recovery discard.

For a 32-byte positive return, the firmware immediately calls the explicit null
pointer overload and requires return value 32. A mismatch blocks with
`BLOCKED_DG_D_NULL_DISCARD_RETURN_MISMATCH`. After releasing the LAN treatment
bracket, `udp.available()` must again be zero or the trial blocks with
`BLOCKED_DG_D_POST_DISCARD_REMAINING_NONZERO`. A later parse is never used as
the intended discard mechanism.

Timing definitions are:

```text
RX_PARSE_MAX_US=parsePacket function call only
RX_NULL_DISCARD_MAX_US=udp.read(nullptr, 32) function call only
RX_TREATMENT_MAX_US=prepareForLanAccess through releaseExternalSpiDevices
```

All elapsed calculations use unsigned wrap-safe subtraction.

## Evidence fields

The final device evidence includes at least:

```text
RX_PARSE_CALL_STARTED_TOTAL
RX_PARSE_CALL_COMPLETED_TOTAL
RX_PARSE_ZERO_TOTAL
RX_PARSE_POSITIVE_TOTAL
RX_PARSE_NEGATIVE_TOTAL
RX_POSITIVE_SIZE_32_TOTAL
RX_POSITIVE_OTHER_SIZE_TOTAL
RX_POSITIVE_OTHER_SIZE_FIRST
RX_POSITIVE_OTHER_SIZE_LAST
RX_PRE_PARSE_REMAINING_NONZERO
RX_NULL_DISCARD_CALL_TOTAL
RX_NULL_DISCARD_RETURN_TOTAL
RX_NULL_DISCARD_REQUEST_BYTES_TOTAL
RX_NULL_DISCARD_BYTES_TOTAL
RX_NULL_DISCARD_FAIL_TOTAL
RX_NULL_DISCARD_LAST_RETURN
RX_POST_DISCARD_REMAINING_NONZERO
RX_PARSE_MAX_US
RX_NULL_DISCARD_MAX_US
RX_TREATMENT_MAX_US
UDP_TX_TOTAL
UDP_TX_FAIL
SCHEDULER_MISSED_DEADLINE
SCHEDULER_MAX_LATENESS_US
LOOP_MAX_US
```

C1-style initial/final USB and HID identity, report/stall/drop evidence, USB
transitions, VID/PID, PHY/link, VERSIONR, buffer map, and MAX/SPI canary evidence
remain present.

## ACTIVE and bounded DRAIN

The only phases are `ACTIVE`, `DRAIN`, `COMPLETE`, and `BLOCKED`. S1 ACTIVE is
nominally 10 seconds and T1 ACTIVE is nominally 60 seconds. Actual successful TX
count is authoritative; 500 and 3000 are never required.

At nominal duration, new TX creation stops permanently and the firmware records
`DRAIN_TARGET_TX_TOTAL=UDP_TX_TOTAL` and `DRAIN_ENTER_MS`. RX treatment and all
USB/HID/PHY/MAX health checks continue.

```text
DG_D_DRAIN_QUIET_REQUIRED_MS=100
DG_D_DRAIN_TIMEOUT_MS=1000
```

Clean drain requires positive-parse total and null-discard-return total to equal
the snapshotted TX target, followed by 100 ms in which subsequent parses are
zero and no invariant fails. Counts exceeding the target block as reconciliation
mismatch. Failure to complete by 1000 ms blocks with
`BLOCKED_DG_D_DRAIN_TIMEOUT`. A timeout or mismatch is never a PASS.

Drain evidence includes target, entry/completion timestamps, constants, observed
quiet time, start/end positive totals, zero confirmations, result, and reason.

## Exact peer reuse

No DG-D peer exists. The only peer is the accepted DG-C file
`tools/usb_lan_gate_dg_c_peer.py`, size 34102, SHA-256
`0D770B8C02ECCBC382A3F5A484F401A3DF9EF9318701ED0C3A2395EEB66E830A`.
Its unconnected IPv4 UDP socket, bind/admission states, strict C1UD validation,
one-for-one immediate echo, sequence tracking, and no-timer/no-pacing/no-retry
behavior are reused byte-for-byte.

## Stimulus and reconciliation

`DG_D_STIMULUS_ESTABLISHED=1` requires peer echo success above zero and complete
device proof that every positive parse was size 32, every positive caused one
call and one returned null discard, request/returned byte totals equal 32 times
the positive count, pre/post invariants are zero, parse started equals completed,
and negative parse count is zero. Missing or temporally ambiguous evidence is
`UNKNOWN`, never silently zero.

A complete PASS additionally requires exact equality of actual counts:

```text
device UDP_TX_TOTAL
= peer VALID_DEVICE_TX_RX_TOTAL
= peer INGRESS_TX_ATTEMPT_TOTAL
= peer INGRESS_TX_SUCCESS_TOTAL
= device RX_PARSE_POSITIVE_TOTAL
= device RX_POSITIVE_SIZE_32_TOTAL
= device RX_NULL_DISCARD_CALL_TOTAL
= device RX_NULL_DISCARD_RETURN_TOTAL
= DRAIN_TARGET_TX_TOTAL
```

Peer and device failure counters must be zero. Sequence begins at zero with no
gap, duplicate, or out-of-order event. Reconciled totals such as 497, 499, 2999,
and 3000 are equally valid.

## Adjudication and serialization

Final fields are:

```text
DG_D_CLASSIFICATION_PRIMARY
DG_D_CLASSIFICATION_SECONDARY
DG_D_STIMULUS_ESTABLISHED=1|0|UNKNOWN
DG_D_TRIAL_RESULT=PASS|FAIL|BLOCKED
DG_D_TRIAL_BLOCK_REASON
DG_D_DEVICE_PRETRIAL_REASON
C2_TYPE_USB_HID_REPRODUCTION=ESTABLISHED|NOT_ESTABLISHED
```

Raw USB/HID evidence remains primary even when causal evidence is inadequate.
USB/HID failure with established stimulus and no proven pretrial cause is
`DG_D_USB_HID_FAIL`, `FAIL`, and reproduction `ESTABLISHED`. The same raw failure
with stimulus 0 or UNKNOWN remains primary but the causal result is BLOCKED.
The B-37 rule is that raw USB/HID observation authority and causal trial validity
are separate. A raw
C2-type USB/HID failure remains `DG_D_USB_HID_FAIL` Primary evidence, but an
existing causal-evidence-invalidating control-plane condition takes precedence
over causal FAIL. `SERIAL_CAPTURE_TIMEOUT` and `PEER_GRACEFUL_EXIT_TIMEOUT` map
to `BLOCKED_DG_D_ORCHESTRATION`. In that combination the USB Primary is
preserved, Secondary and TrialBlockReason are the exact control-plane blocker,
TrialResult is BLOCKED, and C2 reproduction is NOT_ESTABLISHED even if valid
prefix treatment had already established stimulus 1. Unexpected raw control
observations remain fail-closed as `BLOCKED_DG_D_EVIDENCE_CONTRACT_INVALID` and
are preserved only in the raw control evidence file.
This USB/HID rule uses valid prefix treatment evidence and does not require the
complete end-of-trial reconciliation or a completed DRAIN. An abrupt ACTIVE-phase
detach may therefore be a causal FAIL when the prefix treatment is established,
even though its device, peer, and DRAIN terminal totals cannot fully reconcile.

`FAIL` is reserved exclusively for `DG_D_USB_HID_FAIL`. Scheduler/timing,
PHY/link/VERSIONR/buffer-map, MAX/SPI canary, DRAIN, reconciliation, and receive
treatment invariant failures are always exact `BLOCKED_DG_D_*` classifications
with `DG_D_TRIAL_RESULT=BLOCKED`, regardless of whether valid treatment occurred
earlier. `DG_D_DEVICE_LOGICAL_FAIL`, if retained for raw/internal compatibility,
never produces a causal FAIL.

The classification registry is closed-world and includes all contract tokens,
including every treatment invariant, peer/reconciliation/drain/timing/PHY/MAX
block reason. Unknown tokens invalidate the evidence contract.

Exactly one canonical serializer produces the deterministic LF-terminated UTF-8
without BOM line sequence used for both stdout and
`<trialRoot>/runner-adjudication.txt`. It persists PASS, FAIL, BLOCKED, and
fallback outcomes. Raw serial and peer evidence have higher authority than this
derived file.

## Claim boundary

A future accepted PASS permits only:

> Repeated positive parse plus immediate null retirement bundle was not
> sufficient in the accepted trial.

A future accepted FAIL permits only:

> C2-type USB/HID failure occurred while non-null payload transfer and C2
> application validation/bookkeeping were absent.

Neither result separates header access, null discard, software pointer/cache
changes, `Sn_RX_RD` writes, `RECV`, `Sn_CR` polling, SPI timing, or interactions
among them. Those physical frequencies and causal contributions remain UNKNOWN.

## Post-freeze runner clarification (2026-09-06)

This addendum describes the current runner repair, not a revision of accepted
S1/T1 source or manifests. Firmware clears VID/PID after HID loss. Terminal
`0000/0000` may therefore satisfy runtime evidence only for
`FAIL / USB_DETACH_OR_UNSUPPORTED`, ready=0, ready-drop>0, reports>0, and a unique
valid HORI C1_READY record (USB90, ready=1, USB stable>=1000ms, link stable>=500ms)
before a unique DIAGNOSTIC_START and the final evidence block. Other terminal
identities remain restricted to the target `0F0D/0202`. PASS still requires the
target identity and all original health, timing, peer and drain conditions.
Missing stimulus or orchestration failures still block causal FAIL. New physical
use requires a newly reviewed implementation authority for the changed runner.
See [repair validation](post-dg-d-runner-repair-validation.md).
