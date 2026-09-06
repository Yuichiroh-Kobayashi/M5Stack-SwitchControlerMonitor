# USB-LAN Gate DG-A Canonical Contract

## Purpose

Gate C2 (Mode 16, `USB_FIXED10_UDP_ECHO`) failed with primary classification
`C2_USB_HID_FAIL`: HORI PAD TURBO detached 5.4s into the trial, root cause
unresolved (`ACTIVE_RUNTIME_MS=5381`, `FINAL_USB_STATE=12`, `FINAL_HID_READY=0`,
`HID_READY_DROP=1`). C2 added many variables at once versus the passing Gate C1
baseline (Mode 15, TX-only, 60004 ms, 3000/3000 packets, zero USB detaches):
incoming UDP traffic, W5500 RX buffer activity, RX-side SPI access,
`udp.parsePacket()`, `udp.read()`, payload copy, echo validation, outstanding-table
bookkeeping, watchdog/RTT.

DG-A (Diagnostic Gate A, `RX_POLL_EMPTY`) isolates the *first* of these differences:
empty `udp.parsePacket()` polling, at most once per loop, under the condition that the
DG-A peer application sends no intentional UDP datagram back to the device, and with
`udp.read()` never called. The question DG-A answers is narrow and causal:

> Does the C1-accepted condition, plus an empty `parsePacket()` poll alone, reproduce
> the USB/HID detach?

DG-A does not decide root cause. It narrows the C1→C2 causal gap by one variable.

## Authority

- Repository: `C:\Users\yu-ichirou\Documents\Arduino\M5Stack-SwitchController2CoREWirelessSender`.
- Branch: `feat/cores3se-dualsense-lan-stack-diagnostic`.
- HEAD at implementation time: `f915b1c9a33693a2010a1d9527b23743707cfa5d`.
- Baseline diagnostic source identity (matched exactly before implementation began):
  `M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino`, size 101709,
  SHA-256 `F40EB56C1DA4CB7C4FC9CC4C4AF1DC93E3F05108FA21209608D719C890A32C67`.
- Gate C1: `COMPLETE / PASS / FINAL ARCHIVED`
  (`C1-final-20260818-005403-666bf93b`). Not rerun by DG-A.
- Gate C2: `CLOSED / COMPLETE_FAIL / FINAL ARCHIVED`
  (`C2-final-failure-20260819-194013-1e8535d8`). Not rerun by DG-A. Gate C3 remains
  `NO-GO` until DG-A (and any further diagnostic gates it motivates) complete and are
  externally reviewed.

### Donor source authority verification

Every file DG-A copy-adapts from was hash-verified against accepted authority before
implementation began — not assumed from filename alone.

| File | Accepted SHA-256 | Source of authority |
|---|---|---|
| `tools/usb_lan_gate_c2_runner.ps1` | `84997d656d85aa41687a33a8ef361777f5df46b5a86536de9499906808b5b65a` | C2 accepted manifest |
| `tools/usb_lan_gate_c2_peer.py` | `b63f0c50f4b7a27964a79722dcc47e86254da7e953cbbac2827bfcbedc727598` | C2 accepted manifest |
| `tools/usb_lan_diagnostic_build_matrix.ps1` | `84d77e37e37259929a1f0c414396349091f2086fd1fa28ce7908d4db8a7222cd` | C2 accepted manifest |
| `docs/usb-lan-gate-c2-contract.md` | `31bb2f16938174479a68dd3cbd5b0c0851d0d51cf87cc4e140e1e6a67d350716` | C2 accepted manifest |
| `tools/usb_lan_gate_peer.py` | `2d1cfd91dd68daf9f2a25d0f80962315cbb0648a4ad517b3279aeaf491e8663a` | C1 final-freeze source manifest |
| `tools/usb_lan_gate_c1_runner.ps1` | `5b24705265aa3b2d3830b2446f4bf75ccbacc4389c5605f475a968ba4f93e6b6` | C1 final-freeze source manifest |

All six matched the current working tree exactly. Donor reuse was permitted without
any `git restore`/`checkout --`/`reset`.

## Evidence priority

Fixed, in order:

1. Raw serial.
2. Raw peer CSV / stderr.
3. Build / upload evidence.
4. Exact source.
5. Reviewed manifest.
6. Offline fixtures.
7. This document / implementation review package.
8. AI / operator summary.

## Changed variable

```text
DG-A changed variable:  empty udp.parsePacket() polling, at most once per loop
```

**Claim boundary (what "empty" means):** DG-A does not claim that all incoming
Ethernet activity is zero. ARP and other OS-/switch-level baseline traffic that could
equally exist during Gate C1 is not asserted absent. The precise, measurable claim is:

```text
the DG-A peer application transmits no intentional UDP datagram to the device
  -> device-side evidence: RX_POLL_POSITIVE_TOTAL == 0
  -> peer-side evidence:   PEER_TX_TO_DEVICE_TOTAL == 0 (structural: the peer has no
                            send/sendto/sendmsg/connect call anywhere in its source)
```

## Fixed conditions (unchanged from Gate C1)

```text
Fixed10Half PHY profile
LAN-first initialization order
single UDP socket, port 50001
W5500 buffer map: Socket 0/1 = 8 KB RX / 8 KB TX, Sockets 2-7 = 0/0
20 ms nominal TX cadence, 50 Hz, 32-byte frame
burst catch-up prohibited (deadline-skip scheduler, matching C1/C2)
USB Host: HORI PAD TURBO, VID/PID 0F0D/0202
Usb.Task() first, every loop iteration
same USB/HID health monitoring, PHY health monitoring, MAX3421E register canary
same shared-SPI CS discipline (prepareForLanAccess/releaseExternalSpiDevices)
Physical Receiver not used
```

### Fixed physical topology: PC peer endpoint (B-24)

DG-A is a one-variable trial layered on top of the C1/C2-accepted physical topology,
so the PC peer's Ethernet identity is reused unchanged as a fixed condition, exactly
like the sender IP and UDP port above:

```text
Sender IP:               192.168.50.10   (M5 CoreS3 SE, fixed, unchanged)
PC peer Ethernet:         192.168.50.30/24  (Python peer bind address, fixed, unchanged)
UDP:                      192.168.50.10:50001 -> 192.168.50.30:50001
Physical Receiver:        not used (192.168.50.20 exists in the C1/C2 topology but is
                          not physically present or addressed by C1/C2/DG-A)
```

`192.168.50.30` is not an arbitrary same-subnet peer address left to operator or
runner-default discretion -- it is the specific PC Ethernet identity the C1/C2 accepted
physical trials actually used. Enforcement (`tools/usb_lan_gate_dg_a_runner.ps1`):

```text
$fixedPeerIp = "192.168.50.30"                    -- the single source of truth
Assert-DgAPeerIpIdentity($PeerIp)                 -- exact-value check, independent of
                                                      and in addition to the existing
                                                      same-subnet/interface safety
                                                      check (Assert-SafePeerAddress) --
                                                      BOTH must pass for a live trial
Invoke-PhysicalTrialPreflight (EmitPlan or live)  -- enforces the exact check before
                                                      either branch runs
default build-only path                           -- always compiles
                                                      Invoke-Mode17Build $trialRoot
                                                      $fixedPeerIp, never the build
                                                      matrix's own unrelated default
                                                      (192.168.50.254)
-PreflightPhysicalTrial -EmitPlan                 -- prints FIXED_PEER_IP=192.168.50.30
                                                      and shows -C1PeerIp 192.168.50.30 /
                                                      --bind-ip 192.168.50.30 in the
                                                      planned commands, so plan display
                                                      and runtime behavior cannot drift
                                                      apart (N-04/N-05 precedent)
```

A wrong-but-plausible same-subnet value (e.g. `192.168.50.2`, or the build matrix's own
unrelated default `192.168.50.254`) is rejected with `BLOCKED_DG_A_PEER_IP_IDENTITY_MISMATCH`
before any interface/safety check runs, not silently accepted as "any valid peer address."

Changing `192.168.50.30` to a different PC peer address is not a parameter this
implementation task may change on its own authority -- it requires a separate,
explicit external review, exactly like a UDP-port or protocol change.

## Prohibited variables (not added by DG-A)

```text
udp.read()
remoteIP()/remotePort() validation
payload / CRC / echo validation on receipt
outstanding-send table
watchdog / RTT
receive-drain loop
dynamic allocation
new STL container growth
automatic retry / automatic reset / automatic recovery
continuous W5500 RX register polling beyond the existing C1/C2 health monitoring
```

## Mode 17 definition

```text
Gate name:        DG-A
USB_LAN_TEST_MODE: 17
Mode name (exact, used verbatim everywhere): USB_FIXED10_UDP_TX_RX_POLL_EMPTY
Internal symbol:   SetupPlan::kUsbFixed10UdpTxRxPollEmpty
Wire format:       reused unchanged from Gate C1 (magic "C1UD", version 1, gate 1)
```

Firmware source: `M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino`, `#if
USB_LAN_TEST_MODE == 17` block, added as a third parallel block alongside the
existing Mode 15 (`#if ... == 15`) and Mode 16 (`#if ... == 16`) blocks. Neither of
those two blocks is modified — the diff against the C2-accepted baseline shows only
insertions:

```text
Mode 15 dedicated implementation block: byte-for-byte unchanged
Mode 16 dedicated implementation block: byte-for-byte unchanged
Mode 15 / Mode 16 semantic control flow: unchanged
```

(Shared/global source — the `USB_LAN_TEST_MODE` ceiling, the `kModePlans[]` table, the
buffer-mode compile guard, the `SetupPlan` enum, and the `setup()`/`loop()` dispatch
chains — is necessarily touched to add the new mode; this is not a claim that the
whole file is byte-for-byte unchanged, and rebuilt Mode 15/16 binaries are not
expected to hash-match their pre-DG-A builds.)

The device-side changed-variable function:

```cpp
void dgAPollRxEmpty(){
  if(!dgA.udpReady)return;
  prepareForLanAccess();
  const uint32_t pollStartUs=micros();
  const int packetSize=udp.parsePacket();
  dgAUpdateMax(micros()-pollStartUs,dgA.rxPollMaxUs);
  releaseExternalSpiDevices();
  ++dgA.rxPollCallTotal;
  if(packetSize>0){
    ++dgA.rxPollPositiveTotal;
    dgA.pendingFailReason="BLOCKED_DG_A_UNEXPECTED_RX_ACTIVITY";
    return;
  }
  if(packetSize<0){
    ++dgA.rxPollNegativeError;
    dgA.pendingFailReason="DG_A_RX_POLL_API_FAIL";
    return;
  }
}
```

Called from `loopDgA()` at the same relative position `c2ProcessIncomingEcho()`
occupies in `loopC2()`: after `Usb.Task()`/detach/HID-stall/link-health checks, before
TX scheduling. `udp.read()` is never called anywhere in the Mode 17 block —
`rxReadCallTotal`/`rxReadBytesTotal` stay at their zero-initializers, verified by
static source review (there is no code path from any Mode-17 function to
`udp.read()`).

## Four-layer PASS contract

No DG-A trial is adjudicated PASS on any single layer's say-so.

### Layer 1 — Firmware PASS

`dgAFinish()`'s `runtimePass`, computed **only** from passed-in logical state and
measured counters — it never reads `TEST_COMPLETE`/`TEST_MODE`/`TEST_MODE_NAME`,
because those are this function's *output*, not an input to the decision that
produces them:

```text
runtimePass =
    passed-in logical state
    AND UDP_TX_TOTAL > 0             AND UDP_TX_FAIL == 0
    AND RX_POLL_CALL_TOTAL > 0
    AND RX_POLL_POSITIVE_TOTAL == 0  AND RX_POLL_NEGATIVE_ERROR == 0
    AND RX_READ_CALL_TOTAL == 0      AND RX_READ_BYTES_TOTAL == 0
    AND SCHEDULER_MISSED_DEADLINE == 0
    AND HID_STALL_COUNT == 0         AND HID_READY_DROP == 0
    AND FINAL_USB_STATE == 0x90      AND FINAL_HID_READY == 1
    AND FINAL_PHY_OK == 1 AND FINAL_VERSION_OK == 1 AND FINAL_BUFFER_MAP_OK == 1
    AND MAX_REGISTER_TRIPLE_READ_MISMATCH == 0
    AND SPI_CORRUPTION_SUSPECTED == 0
```

Only after `runtimePass` is computed does the firmware emit
`TEST_COMPLETE=<PASS|FAIL> TEST_MODE=17 TEST_MODE_NAME=USB_FIXED10_UDP_TX_RX_POLL_EMPTY`.
`TEST_MODE`/`TEST_MODE_NAME` are static/compile-time identity on the firmware side
(sourced from `USB_LAN_TEST_MODE`/`kModePlan.name`, never measured); the runner's
Layer 2 is where they become **required evidence fields** — a mismatch (e.g. the
wrong binary was uploaded) is `BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID`, not silently
ignored.

### Layer 2 — Serial/parser PASS

The runner (`tools/usb_lan_gate_dg_a_runner.ps1`, `Test-DgASerialLog`) independently
re-parses and re-checks every Layer-1 field from raw serial text — the firmware's own
`TEST_COMPLETE=` token is never trusted alone — plus `TEST_MODE==17` and
`TEST_MODE_NAME==USB_FIXED10_UDP_TX_RX_POLL_EMPTY` as required evidence.

#### Exact evidence-field parity with the implementation (B-18)

Two fields the firmware always prints were previously extracted for informational use
only, without gating `EvidenceContractValid`. Both are now required exactly once on
the normal-schema `TEST_COMPLETE` line:

```text
REASON     -- required exactly once (dgAFinish() always prints it)
VERSIONR   -- required exactly once, parsed as a hex byte (dgAFinish()'s %02X field)
```

`VERSIONR` PASS condition is `VERSIONR == 0x04` (same value `FINAL_VERSION_OK`
already causally encodes at the firmware level — `dgA.finalVersionOk =
dgA.version==0x04` — but Layer 2 re-derives it independently from the raw hex text
rather than trusting `FINAL_VERSION_OK` alone, consistent with Layer 2 never trusting
a firmware-computed boolean without re-checking the underlying value):

```text
VERSIONR missing or malformed -> BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID
VERSIONR parseable but != 0x04 -> DG_A_PHY_HEALTH_FAIL (measured hard-criterion,
                                    not an evidence-contract problem)
```

#### Normal-runtime REASON is a closed-world vocabulary (B-21)

`REASON` being merely *present* is not sufficient evidence. The exact set of values
`dgAFinish()` can ever emit was read-only-inventoried from every `dgAFinish(...)` call
site in the diagnostic source (distinct from the setup-failure reason inventory,
which comes from `dgAFailSetup(...)` call sites):

```text
DURATION_COMPLETE                     -- the only reason consistent with PASS
USB_DETACH_OR_UNSUPPORTED             -- Tier-1 (also caught by the raw provisional
                                          detector before this vocabulary is even
                                          consulted)
HID_STALL                             -- Tier-1 (same)
MAX_REGISTER_MISMATCH                 -- named classification (DG_A_MAX_SPI_CANARY_FAIL)
LINK_OR_PHY_CHANGED                   -- named classification (DG_A_PHY_HEALTH_FAIL)
BLOCKED_DG_A_UNEXPECTED_RX_ACTIVITY   -- named classification
DG_A_RX_POLL_API_FAIL                 -- named classification
```

**PASS semantics**: `TEST_COMPLETE=PASS` is only evidence-consistent with
`REASON==DURATION_COMPLETE` exactly. Any other REASON accompanying PASS — even a
plausible-looking one — is `BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID`, never a logical
firmware failure classification: the terminal evidence itself is semantically
inconsistent with what the accepted firmware can produce, which is an
evidence-contract violation, not something to interpret charitably.

**FAIL semantics** (unchanged from B-19, restated for completeness): a known named
reason maps to its named classification; `REASON=DURATION_COMPLETE` with
`TEST_COMPLETE=FAIL` falls to the measured-hard-criterion tier (B-19); any other,
unrecognized REASON is `DG_A_FIRMWARE_FAIL_UNCLASSIFIED`.

**Setup-failure vocabulary**: agreement between the `DG_A_SETUP_FAIL` and
`TEST_COMPLETE` lines' REASON values is not sufficient on its own — the (agreeing)
value must also belong to `$dgAKnownSetupFailureReasons` (the source-inventoried
`dgAFailSetup(...)` reason set). Two lines agreeing on a token neither
`dgAFailSetup()` nor any other code path can actually emit is still malformed
evidence, not a valid setup-failure trial.

#### Evidence authority (B-16): `DG_A_DIAG` is informational only

`loopDgA()` prints a periodic `DG_A_DIAG` statistics line (same field names as
`DG_A_FINAL`, once per second) purely for live progress visibility. **It is never
final adjudication authority.** A normal runtime trial has exactly two authority
lines and no more:

```text
exactly one DG_A_FINAL line   -- final statistics (dgAPrintStatistics("DG_A_FINAL"),
                                  called once from dgAFinish())
exactly one TEST_COMPLETE line -- terminal/health/identity (dgAFinish())
```

Zero or two-or-more of either line is malformed evidence, not a normal trial —
`EvidenceContractValid=false`, never silently tolerated by falling back to an older
`DG_A_DIAG` value or a duplicate line's first/last occurrence.

**Field ownership** (each field is read from exactly one authority line, never from
the whole text via a last-match scan):

```text
DG_A_FINAL-only fields: UDP_TX_TOTAL, UDP_TX_FAIL, UDP_BEGIN_COUNT, UDP_BEGIN_FAIL,
  UDP_BEGIN_MAX_US, UDP_BEGIN_PACKET_MAX_US, UDP_WRITE_MAX_US, UDP_END_PACKET_MAX_US,
  UDP_MAX_GAP_US, SCHEDULER_MISSED_DEADLINE, SCHEDULER_MAX_LATENESS_US, LOOP_MAX_US,
  HID_STALL_COUNT, HID_MAX_NO_REPORT_MS, RX_POLL_CALL_TOTAL, RX_POLL_POSITIVE_TOTAL,
  RX_POLL_NEGATIVE_ERROR, RX_READ_CALL_TOTAL, RX_READ_BYTES_TOTAL, RX_POLL_MAX_US

TEST_COMPLETE-only fields: TEST_COMPLETE, TEST_MODE, TEST_MODE_NAME, REASON,
  DURATION_MS, TRIAL_RUNTIME_MS, FINAL_USB_STATE, FINAL_HID_READY, HID_READY_DROP,
  HID_STALL_COUNT, HID_MAX_NO_REPORT_MS, VID, PID, HID_REPORT_TOTAL, FINAL_PHY_OK,
  FINAL_VERSION_OK, FINAL_BUFFER_MAP_OK, VERSIONR, MAX_REGISTER_TRIPLE_READ_MISMATCH,
  SPI_CORRUPTION_SUSPECTED
```

**Dual-authority fields (B-18 5)**: `HID_STALL_COUNT`/`HID_MAX_NO_REPORT_MS` are
printed on *both* lines by the firmware, from the same underlying counters
(`dgA.hidStallCount`, the no-report-ms max). Each occurrence is read from its own
line — never cross-substituted into a single shared dictionary key, which would
silently let one authority's value overwrite the other's — and **both are required
to agree**:

```text
DG_A_FINAL.HID_STALL_COUNT       == TEST_COMPLETE.HID_STALL_COUNT
DG_A_FINAL.HID_MAX_NO_REPORT_MS  == TEST_COMPLETE.HID_MAX_NO_REPORT_MS
```

Either side missing, or the two sides disagreeing, is
`BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID`. If any other field is found (by future
source review) to be printed on both authority lines, the same required-both-present,
required-equal treatment applies — this is not scoped to only these two fields by
coincidence, it is the general rule for any dual-authority field.

A required key that appears more than once *on its own* authority line (e.g. two
`RX_POLL_CALL_TOTAL=` tokens both on the `DG_A_FINAL` line) is duplicate-on-line
malformed evidence, not silently resolved to either value.

#### Exact USB target identity: VID/PID (B-23)

`VID`/`PID` on the normal-schema `TEST_COMPLETE` line are typed as 16-bit hex
(non-throwing) and required to equal the fixed DG-A USB target identity exactly —
HORI PAD TURBO:

```text
VID == 0x0F0D
PID == 0x0202
```

Missing, malformed, or a wrong-but-parseable identity (e.g. a different controller
plugged in) is `BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID` — an identity/evidence
problem, never classified as `PASS`, `DG_A_PEER_FAIL`, or `DG_A_PHY_HEALTH_FAIL`. Like
every other `EvidenceContractValid` check, this is only reached once the Tier-0
provisional-primary check (raw `USB_DETACH` etc.) has already found nothing — if a raw
Tier-1 physical failure already applies, `Get-DgAClassification` short-circuits before
`VID`/`PID` are ever consulted, so a wrong identity never overrides an established
Tier-1 primary; it simply never gets the chance to be evaluated in that case.

#### Setup / pre-trial failure schema

`dgAFailSetup()` never calls `dgAPrintStatistics()` — a setup/pre-trial failure trial
has **no** `DG_A_FINAL` line at all, and a sparser `TEST_COMPLETE` line than the normal
runtime schema:

```text
exactly one DG_A_SETUP_FAIL=1 REASON=<reason> line
exactly one TEST_COMPLETE=FAIL TEST_MODE=17 TEST_MODE_NAME=... REASON=<reason>
  FINAL_USB_STATE=... FINAL_HID_READY=... HID_READY_DROP=... line (no DURATION_MS,
  TRIAL_RUNTIME_MS, HID_STALL_COUNT, HID_MAX_NO_REPORT_MS, VID, PID, HID_REPORT_TOTAL,
  FINAL_PHY_OK, FINAL_VERSION_OK, FINAL_BUFFER_MAP_OK, VERSIONR, or MAX-canary fields)
```

Read-only-inventoried exact reason tokens from every `dgAFailSetup(...)` call site in
the diagnostic source (informational only — this list does not add per-reason
classification granularity):

```text
W5100_INIT, CHIP_ID, VERSIONR, BUFFER_MAP_INIT, PHY_PROFILE, PHY_PROFILE_READBACK,
BUFFER_MAP_FIXED10, NETWORK_CONFIG, PHY_AFTER_NETWORK_CONFIG,
BUFFER_MAP_NETWORK_CONFIG, LINK_PROFILE_CHANGED, LINK_TIMEOUT, UDP_BEGIN, UDP_SOCKET,
PHY_AFTER_UDP_BEGIN, BUFFER_MAP_UDP_BEGIN, VERSION_AFTER_UDP_BEGIN,
BUFFER_MAP_USB_INIT, USB_INIT, PHY_DURING_USB_STABILITY, HORI_READY
```

A recognized setup-failure schema classifies as `DG_A_SETUP_FAIL` — **never** `PASS`
and **never** `ORCHESTRATION_STALL/TIMEOUT`.

#### Parsing never throws (B-17)

`Test-DgASerialLog`/`Test-DgAPeerSummary`/`Test-DgAReconciliation` are designed to be
non-throwing: a missing, duplicated, or numerically-unparsable required field becomes
`EvidenceContractValid=false`, never a PowerShell exception. Values are never
defaulted to `0`, an empty string, or a previous line's value to paper over malformed
evidence.

### Layer 3 — Peer PASS

The DG-A peer's admission-controller (`tools/usb_lan_gate_dg_a_peer.py`,
`DgAAdmissionController.passed()`) reads **only** underlying state/counters — never
`PEER_COMPLETE`/`PEER_RESULT`, which are serialized *from* `passed()`'s result in
`summary_lines()`, never read back into it (a strictly one-directional flow):

```text
passed() =
    peer_armed == true
    AND admission_sequence_zero_ok == true
    AND blocked_admission_sequence_miss == false
    AND valid_rx_total > 0
    AND first_sequence == 0
    AND crc_error == 0 AND length_error == 0 AND format_error == 0
        AND payload_error == 0
    AND unexpected_source == 0 AND source_port_error == 0
    AND flags_error == 0
    AND seq_gap == 0 AND duplicate == 0 AND out_of_order == 0
```

`bound_not_armed_packet_count` and `pre_admission_non_c1_count` are informational
only, never required to be zero. `PEER_TX_TO_DEVICE_TOTAL=0` is a structural
invariant of the peer (no send code path exists), asserted on every run, and is the
runner's required evidence for the "no intentional peer return traffic" claim.

#### Peer evidence: `EvidenceContractValid` and `LogicalPass` are distinct (B-16)

The runner (`Test-DgAPeerSummary`) evaluates the peer summary text in two explicit
stages, never conflated:

```text
1. EvidenceContractValid: every required peer summary field (PEER_COMPLETE, RX_TOTAL,
   VALID_RX_TOTAL, FIRST_SEQUENCE, LAST_SEQUENCE, EXPECTED_SOURCE_IP,
   EXPECTED_SOURCE_PORT, the ten strict-validator error counters, PEER_ARMED,
   ADMISSION_SEQUENCE_ZERO_OK, BLOCKED_ADMISSION_SEQUENCE_MISS,
   BOUND_NOT_ARMED_PACKET_COUNT, PRE_ADMISSION_NON_C1_COUNT,
   PEER_TX_TO_DEVICE_TOTAL, PEER_RESULT) is present exactly once and parseable.
   Missing, duplicated, or unparsable -> EvidenceContractValid=false, no exception.

2. LogicalPass: only evaluated once EvidenceContractValid=true -- the strict-validator
   error counters, PEER_RESULT, VALID_RX_TOTAL, and FIRST_SEQUENCE are checked against
   their required values.
```

A missing or malformed peer summary is `BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID`
(an evidence-contract problem), unless a higher-authority Tier-1 primary already
applies (see "Provisional raw Tier-1 detection" below) — it is never silently treated
as `DG_A_PEER_FAIL` (which is reserved for evidence that parsed cleanly but failed its
own strict contract, e.g. `CRC_ERROR>0`).

#### Typed peer field validation (B-20)

`present exactly once and parseable` above is enforced with real types, not merely
"non-empty string":

```text
EXPECTED_SOURCE_IP:    required exactly once, must parse as IPv4, AND must equal the
                        fixed expected value 192.168.50.10 exactly
                        (missing/malformed/wrong-value -> EvidenceContractValid=false)
EXPECTED_SOURCE_PORT:  required exactly once, must parse as a decimal integer, AND
                        must equal the fixed expected value 50001 exactly
                        (missing/malformed/wrong-value -> EvidenceContractValid=false)
FIRST_SEQUENCE:        schema is exactly "decimal uint32 in [0, 4294967295]" OR the
                        literal string "NONE" -- nothing else is valid evidence
LAST_SEQUENCE:         same schema as FIRST_SEQUENCE
```

**True uint32-range validation, not merely "digits" (B-22)**: `ConvertTo-DgAUInt32OrNone`
range-checks against the real `uint32` bound, not just a digits-only regex. A value
that is all-digits but out of range (`4294967296`, or something too large even for
`uint64` like `18446744073709551616`) is malformed evidence, never a logical peer
failure, and the parser never throws regardless of magnitude:

```text
FIRST_SEQUENCE / LAST_SEQUENCE out of uint32 range, or otherwise malformed
    -> BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID (no exception raised)
```

The typed parsed value (not a re-cast of the raw string) is what every downstream
logical check — `FIRST_SEQUENCE==0`, the `LAST_SEQUENCE` stream-consistency
comparison below — actually consumes; there is no unchecked numeric cast anywhere
past the initial parse.

**`PEER_RESULT` is a closed-world enum, not a free-form string (N-09)**: the
unmodified peer source (`tools/usb_lan_gate_dg_a_peer.py`) has exactly two producers of
this field's value — the `BLOCKED_ADMISSION_SEQUENCE_MISS` short-circuit, and
`"PASS" if controller.passed() else "FAIL"` — so exactly three values are ever
physically possible:

```text
PEER_RESULT allowed values (read-only-inventoried from the unmodified peer source):
  PASS
  FAIL
  BLOCKED_ADMISSION_SEQUENCE_MISS
```

Anything else (a truncated line, a corrupted transport, a future peer bug) is
malformed evidence, not a logical peer failure — it must resolve to
`EvidenceContractValid=false` (`BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID` at the
classifier), never to `DG_A_PEER_FAIL`, which is reserved for a peer summary that
parsed cleanly under the closed-world enum but failed its own strict contract:

```text
PEER_RESULT=garbage -> BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID (not DG_A_PEER_FAIL)
```

The existing semantics of the three known values are unchanged: `PASS` is
PASS-compatible pending every other Layer-3 check; `FAIL` and
`BLOCKED_ADMISSION_SEQUENCE_MISS` continue to drive `DG_A_PEER_FAIL` and
`BLOCKED_ADMISSION_SEQUENCE_MISS` respectively exactly as before this fix.

A wrong-but-plausible `EXPECTED_SOURCE_IP`/`EXPECTED_SOURCE_PORT` (e.g. a stray peer
bound to the wrong address) is treated as an **evidence/identity contract failure**,
not a peer network `FAIL` — the peer is not even validating the trial it claims to be
validating, which is a different problem than a validating peer observing bad packets.

**Stream consistency (B-20 5.4)**: once `FIRST_SEQUENCE==0` and the strict-validator
sequence counters (`SEQ_GAP`, `DUPLICATE`, `OUT_OF_ORDER`) are all zero — i.e. once
sequence integrity itself already holds — `LAST_SEQUENCE` must equal
`VALID_RX_TOTAL - 1` (S1/T1 durations never wrap a `uint32` sequence, so no wrap
accommodation is needed). This is checked only once `LAST_SEQUENCE` is already a
well-formed decimal value (a malformed `LAST_SEQUENCE` is caught earlier as an
evidence-contract failure, never reaching this check):

```text
LAST_SEQUENCE field itself malformed        -> BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID
LAST_SEQUENCE valid decimal but != VALID_RX_TOTAL-1 -> DG_A_PEER_FAIL (LogicalPass=false;
                                                         a logical peer failure, not an
                                                         evidence-contract problem)
```

### Layer 4 — Cross-reconciliation PASS

Consumes only already-validated parsed authority objects from Layers 2 and 3
(`Test-DgAReconciliation(SerialResult, PeerResult)`) — it never re-parses raw serial
or peer text. Both inputs must already have `EvidenceContractValid=true`, or
reconciliation itself is reported unavailable (`EvidenceValid=false`), never guessed
at from partial data:

```text
device UDP_TX_TOTAL == peer VALID_RX_TOTAL   (exact equality; DG-A is receive-only,
                                               no loss tolerated for PASS)
peer FIRST_SEQUENCE == 0
peer SEQ_GAP == 0, DUPLICATE == 0, OUT_OF_ORDER == 0
```

### PASS is a positive allow-list (B-15)

`PASS` is reachable through exactly one path in `Get-DgAClassification` — there is no
fall-through `else` that reaches `PASS`:

```text
PASS iff:
    no provisional Tier-1 evidence
    AND Serial evidence contract valid AND Serial logical PASS (HardCriteriaPass)
    AND Peer summary available
    AND Peer evidence contract valid
    AND Peer logical PASS
    AND Reconciliation evidence valid
    AND Reconciliation PASS
```

In particular, a serial-logical-PASS trial with **no peer summary at all** is
`BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID` — never `PASS`. `DG_A_TRIAL_RESULT=PASS
TRIAL=<name>` (`Get-DgATrialResultMarker`) is emitted only when all four complete,
valid layers agree; otherwise `DG_A_TRIAL_RESULT=FAIL TRIAL=<name> PRIMARY=<token>`,
and the primary classification token is never dropped or overwritten by that umbrella
marker.

### Layer 3/4 failure classification

```text
Peer summary valid, parses cleanly, but its own strict contract fails
    -> DG_A_PEER_FAIL
Firmware (Layer 1/2) and peer (Layer 3) each individually valid, but the
cross-stream equality (Layer 4) fails
    -> DG_A_RECONCILIATION_FAIL
Peer summary missing, malformed, ambiguously duplicated, or unparsable
    -> BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID (an evidence-contract problem, never
       conflated with DG_A_PEER_FAIL)
```

### Provisional raw Tier-1 detection precedes structured parsing (B-17)

`Get-DgARawProvisionalPrimary` is a pure, non-throwing function that scans only raw
serial text (`USB_DETACH` marker, `REASON=USB_DETACH_OR_UNSUPPORTED`,
`REASON=HID_STALL`) — it depends on no numeric parsing, no peer summary, no
reconciliation, and no generated report. In the physical trial flow
(`Invoke-DgAPhysicalTrial`), it runs immediately after raw serial bytes are preserved,
*before* any structured parsing is attempted, and its result (if not `NONE`) fixes the
final `PRIMARY` regardless of what happens afterward. If structured parsing still
throws for any reason (defense in depth beyond the non-throwing guarantee above), the
provisional primary — or `BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID` if there is none —
is used rather than ending the trial with no classification at all.

**Parser/teardown errors after a Tier-1 primary is fixed are `SECONDARY` only** — they
are recorded (e.g. `SECONDARY=PEER_EVIDENCE_INCOMPLETE`,
`SECONDARY=PEER_GRACEFUL_EXIT_TIMEOUT`, `SECONDARY=EVIDENCE_PARSER_INCOMPLETE`) but
never replace `PRIMARY`, mirroring the Gate C2-T1 precedent this design exists to
prevent from recurring (see "Peer termination / evidence-flush boundary" below).

## Peer admission (three-state, receive-only)

Reused from Gate C2's three-state admission machine
(`tools/usb_lan_gate_c2_peer.py`, `C2AdmissionController`), copy-adapted with echo
removed entirely (no `EchoSender`, no dispatch method, no send/sendto/sendmsg/connect
call anywhere in `tools/usb_lan_gate_dg_a_peer.py`):

```text
BOUND_NOT_ARMED
    | arm-file created by runner, strictly after UPLOAD_PASS
    v
ARMED_WAIT_SEQUENCE_ZERO
    | first fully-valid expected-source C1UD frame
    | sequence == 0  -> ADMITTED (this packet becomes the first strict packet)
    | sequence != 0  -> BLOCKED_ADMISSION_SEQUENCE_MISS (trial stops, latched)
    v
ADMITTED
    strict per-packet validation only (length/magic/version/gate/flags/CRC/payload/
    source IP/source port/sequence continuity/duplicate/out-of-order) -- no echo,
    no transmit
```

The simpler Gate C1 peer mechanism (`require_first_sequence_zero`) was considered and
rejected for DG-A: because DG-A reuses the unmodified `C1UD` wire format, stray
pre-upload traffic could otherwise be indistinguishable from the trial itself. The
three-state arm/armed handshake (reused from C2's reviewed control-plane,
`New-DgAArmRequest`/`Wait-DgAArmedAcknowledgement` in the runner) removes that
ambiguity by gating admission on an explicit, runner-driven arm signal sent only after
`UPLOAD_PASS`.

Receive-only proof (five-part combination — not a source self-scan alone):

1. Reuse of the already-accepted C1/C2 receive-only code shape.
2. Manual call-path review (recorded in the implementation review package): every
   function reachable from `run_sink()` traced to confirm none reaches a socket-send
   call.
3. Source grep across the finished file for `send`, `sendto`, `sendmsg`, `connect`
   (a `connect()`'d UDP socket is itself transmit-capable and must not appear) — saved
   as evidence, not just asserted.
4. Grep output + manual review notes placed in the review package, independently
   checkable.
5. Runtime invariant `PEER_TX_TO_DEVICE_TOTAL=0`, printed every run, asserted by every
   offline fixture.

## Static reviewed-source manifest — Phase A / Phase B

DG-A has no prior *externally accepted* manifest authority yet — the implementation
task produces the first candidate. The manifest's lifecycle is split into two
non-overlapping phases to avoid a circular authority claim.

### Phase A — pre-review candidate identity CONSISTENCY (implementation session)

Not an authority check — a self-consistency check that the build did not silently
alter source/dependency bytes:

```text
CANDIDATE_IDENTITY_PHASE=PRE_BUILD
  -> snapshot size/SHA-256/recursive-inventory for: diagnostic source, DG-A peer,
     DG-A runner, DG-A build matrix, DG-A contract, actual isolated dependencies
        |
  arduino-cli compile
        |
CANDIDATE_IDENTITY_PHASE=POST_BUILD
  -> re-snapshot the same set from actual on-disk bytes
        |
  PRE_BUILD snapshot == POST_BUILD snapshot, byte-for-byte, field-for-field
```

Mismatch -> `BLOCKED_CANDIDATE_SOURCE_IDENTITY_CHANGED_DURING_BUILD` (distinct from
both Phase-B tokens below; `tools/usb_lan_gate_dg_a_runner.ps1`,
`Assert-DgACandidateConsistency`).

Once consistent, the final candidate bytes are written to
`DG-A-reviewed-source-manifest.csv` (same column model as the C2-accepted manifest:
`relative_or_absolute_path,size,sha256,role,inventory_root`) via
`New-DgACandidateManifest`. The manifest's own SHA-256 is recorded as separate sibling
evidence (`<manifest>.sha256.txt`) — never a row inside the manifest it describes, no
self-reference — and printed as:

```text
PROPOSED_EXPECTED_REVIEWED_MANIFEST_SHA256=<hash>
```

This is a **proposal** for external review to accept — this implementation session
never treats its own freshly-generated hash as already-accepted authority.

### Phase B — post-external-review AUTHORITY verification (future, not exercised this session)

Only once external review accepts `PROPOSED_EXPECTED_REVIEWED_MANIFEST_SHA256` does a
future physical runner take `-ReviewedManifestPath` and
`-ExpectedReviewedManifestSha256` as required, externally-supplied inputs (never
defaulted from current repository state) and perform two-level verification
(`Assert-ReviewedManifestAuthority`):

```text
Step A: manifest file's own SHA-256 == externally accepted ExpectedReviewedManifestSha256
        -> failure: BLOCKED_REVIEWED_MANIFEST_IDENTITY_MISMATCH
Step B: (only if Step A passes) manifest-listed file bytes == actual on-disk bytes
        -> failure: BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH
```

`Expected Manifest SHA -> Manifest bytes -> Source/dependency bytes`, always in that
order. A future physical trial's `PRE_BUILD`/`POST_BUILD` steps both diff against this
same, Step-A-verified manifest — never regenerated at `POST_BUILD`.

### Authority lifecycle

External review accepts source + peer + runner + build matrix + contract +
dependency identity + manifest as **one unit**. If a build-only defect is found before
external review, the old candidate manifest is superseded: fix the source, generate a
new candidate generation directory, a new manifest, a new
`PROPOSED_EXPECTED_REVIEWED_MANIFEST_SHA256`, and rerun Phase A — automatic manifest
regeneration at `POST_BUILD` is prohibited. After external review, any subsequent
change to any of those seven items invalidates the prior review's authority; a new
external review is required before any further build or physical step.

## Peer termination / evidence-flush boundary — unconditional teardown

Reused for its bounded-wait *mechanics* from the already-accepted Gate C1 runner's
termination sequence, but **not** for its pass-oriented *ordering*. C1's ordering
(serial-contract PASS confirmed before the peer is told to stop) works for C1 because
C1's only failure path ends the trial the same way either way; DG-A's whole purpose is
to observe a possible USB detach (a FAIL), so raw peer evidence must be preserved on
that path too — evidence capture must not depend on the trial's eventual verdict.

Separation: **(A)** evidence capture / graceful teardown — always runs to completion
(bounded), regardless of what **(B)** will conclude; **(B)** — PASS/FAIL adjudication
— only starts once (A) has finished attempting to preserve everything it can.

```text
1. bounded serial capture ends (terminal marker observed, OR external timeout, OR
   the capture otherwise reaches its bound -- never unbounded)
2. raw serial bytes preserved immediately, as-is
3. `Get-DgARawProvisionalPrimary` (B-17) inspects the raw text (non-throwing, no
   numeric parsing, no peer/report dependency) for USB_DETACH / REASON=
   USB_DETACH_OR_UNSUPPORTED / REASON=HID_STALL and, if found, fixes PRIMARY now
4. regardless of the eventual trial verdict: if the peer process is still alive, the
   stop-file is written now (unconditional, not gated on a PASS classification)
5. bounded graceful peer exit wait (same finite-budget pattern as the accepted C1
   runner's Wait-OwnedProcess)
6. if the peer produced a summary, it is preserved/flushed; if not, a SECONDARY
   evidence-incomplete condition is recorded (this is not itself a trial outcome)
7. only now, wrapped so no exception can escape without a classification:
   `Test-DgASerialLog` (Layer 2), `Test-DgAPeerSummary` where available (Layer 3),
   `Test-DgAReconciliation` where applicable (Layer 4), then
   `Get-DgAClassification` assigns the final PRIMARY (the step-3 provisional value
   if set, else a fresh evaluation; a parser exception falls back to the step-3
   provisional value or `BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID`)
8. finally: force-stop any still-running owned processes/jobs as a safety-net only,
   never the primary termination path
```

**Classification rule**: if raw serial already contains Tier-1 evidence (`USB_DETACH`
/ `REASON=USB_DETACH_OR_UNSUPPORTED` / `REASON=HID_STALL`), `PRIMARY=DG_A_USB_HID_FAIL`
is fixed at step 3 and is never overwritten by anything that happens in steps 4-8. A
subsequent peer-summary-missing, graceful-exit-timeout, or report-generation problem
is recorded only as a non-overriding `SECONDARY=<condition>` annotation (e.g.
`SECONDARY=PEER_EVIDENCE_INCOMPLETE`) — mirroring the already-established Gate C2-T1
precedent (primary `C2_USB_HID_FAIL` fixed, `ORCHESTRATION_STALL` demoted to
secondary-at-most) and preventing that classification defect's reoccurrence.

Layer 2/3/4 PASS are conditions for the *final trial verdict*, never conditions for
whether the peer stop-file gets sent or whether raw peer evidence gets flushed. A
firmware `TEST_COMPLETE=FAIL` never causes graceful peer shutdown to be skipped.

## Scheduler

Unchanged from Gate C1/C2: 20 ms nominal deadline, deadline-skip (no burst
catch-up). `SCHEDULER_MISSED_DEADLINE > 0` on an otherwise-PASS trial downgrades the
classification to `DG_A_TIMING_FAIL` (Layer 1/2 re-check), not a silent pass.

## Trial staging: S1 / T1 separation

```text
DG-A-S1: 10 seconds
DG-A-T1: 60 seconds
```

No automatic progression: `DG-A-S1 PASS != DG-A-T1 authorized`. External review is
required after S1 before T1 may run; T1 requires separate physical authorization.
Neither S1 nor T1 physically ran during the implementation task described by this
document.

## Physical orchestration order

Implemented as real source in `tools/usb_lan_gate_dg_a_runner.ps1`
(`Invoke-DgAPhysicalTrial`, `Invoke-PhysicalTrialPreflight -EmitPlan`), never invoked
by the implementation task:

```text
1. peer start
2. peer BOUND_NOT_ARMED
3. PEER_READY observed
4. reviewed source/dependency identity -- PRE_BUILD (Phase B Step A then Step B,
   post-external-review only)
5. fresh DG-A build
6. reviewed source/dependency identity -- POST_BUILD (SAME verified manifest)
7. pre-upload COM4 exact PNP identity check
8. peer-alive check
9. upload
10. UPLOAD_PASS
11. arm-file create
12. armed-file + PEER_ARMED acknowledgement
13. bounded serial capture -> preserve raw serial -> inspect for Tier-1 evidence ->
    unconditional peer stop -> bounded peer exit -> preserve peer evidence (flush or
    SECONDARY=incomplete) -> serial/peer/reconciliation parsing -> final PRIMARY
    classification (+ optional SECONDARY) -> four-layer PASS evaluation
```

Arming before upload is prohibited: the peer must already be past `UPLOAD_PASS` —
i.e. the exact firmware under test is confirmed on the device — before it is told to
admit traffic.

## Acceptance criteria (isolation / UDP baseline / scheduler / USB-HID / PHY-W5500-MAX)

```text
Isolation:
  RX_POLL_CALL_TOTAL > 0
  RX_POLL_POSITIVE_TOTAL == 0     RX_POLL_NEGATIVE_ERROR == 0
  RX_READ_CALL_TOTAL == 0         RX_READ_BYTES_TOTAL == 0
  PEER_TX_TO_DEVICE_TOTAL == 0

UDP baseline:
  UDP_TX_TOTAL > 0                UDP_TX_FAIL == 0
  DEVICE_UDP_TX_TOTAL == PEER_VALID_RX_TOTAL
  FIRST_SEQUENCE == 0             continuous sequence
  packet / CRC / payload / source / port / flags errors: 0

Scheduler:
  SCHEDULER_MISSED_DEADLINE == 0

USB/HID:
  HID_READY_DROP == 0             HID_STALL_COUNT == 0
  FINAL_USB_STATE == 0x90         FINAL_HID_READY == 1

PHY/W5500/MAX:
  FINAL_PHY_OK == 1               FINAL_VERSION_OK == 1
  FINAL_BUFFER_MAP_OK == 1        VERSIONR == 04
  MAX_REGISTER_TRIPLE_READ_MISMATCH == 0
  SPI_CORRUPTION_SUSPECTED == 0
```

## Failure classification (fail-closed, closed-world)

Evaluated in this exact precedence order by `Get-DgAClassification`
(`tools/usb_lan_gate_dg_a_runner.ps1`):

```text
Tier 0 (highest, checked first, from raw text alone -- B-17):
  provisional Tier-1 (Get-DgARawProvisionalPrimary): raw serial USB_DETACH /
  REASON=USB_DETACH_OR_UNSUPPORTED / REASON=HID_STALL
    -> DG_A_USB_HID_FAIL, never overridden by anything below, including a
       SECONDARY teardown/parser problem recorded afterward

Tier NE (no evidence at all -- checked before evidence-contract validity):
  no DG_A_FINAL, no DG_A_SETUP_FAIL, no TEST_COMPLETE line anywhere in the text
    -> ORCHESTRATION_STALL/TIMEOUT

Tier EC (evidence contract, B-16):
  serial schema is not exactly one of {Normal, SetupFailure} (0 or 2+ of any
  authority line, a required field missing/duplicated/unparsable on its owning
  line, or TEST_MODE/TEST_MODE_NAME mismatched)
    -> BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID

Tier SF (setup/pre-trial failure schema):
  DG_A_SETUP_FAIL=1 + TEST_COMPLETE=FAIL, recognized cleanly
    -> DG_A_SETUP_FAIL (never PASS, never ORCHESTRATION_STALL/TIMEOUT)

Tier 2 (experiment-isolation BLOCKED):
  REASON=BLOCKED_DG_A_UNEXPECTED_RX_ACTIVITY      -> BLOCKED_DG_A_UNEXPECTED_RX_ACTIVITY
  RX_READ_CALL_TOTAL>0 or RX_READ_BYTES_TOTAL>0    -> BLOCKED_DG_A_RX_READ_PATH_REACHED
  PEER_TX_TO_DEVICE_TOTAL>0 (peer evidence contract valid)  -> BLOCKED_PEER_TX_TO_DEVICE_NONZERO
  peer BLOCKED_ADMISSION_SEQUENCE_MISS (peer evidence contract valid) -> BLOCKED_ADMISSION_SEQUENCE_MISS
  Phase-B manifest content mismatch (Step B)       -> BLOCKED_REVIEWED_SOURCE_IDENTITY_MISMATCH
  Phase-B manifest self-hash mismatch (Step A)      -> BLOCKED_REVIEWED_MANIFEST_IDENTITY_MISMATCH
  Phase-A build-time drift                          -> BLOCKED_CANDIDATE_SOURCE_IDENTITY_CHANGED_DURING_BUILD

Tier 3 (defined firmware/network/timing/health/reconciliation failure), evaluated in
this sub-order -- **measured hard-criterion classification runs before the generic
"remaining FAIL" fallback and regardless of TEST_COMPLETE PASS/FAIL** (B-19; see
rationale below):
  REASON=DG_A_RX_POLL_API_FAIL                     -> DG_A_RX_POLL_API_FAIL
  REASON=LINK_OR_PHY_CHANGED                       -> DG_A_PHY_HEALTH_FAIL
  REASON=MAX_REGISTER_MISMATCH                     -> DG_A_MAX_SPI_CANARY_FAIL
  ANY valid normal-schema evidence with a Layer-1/2 hard-criterion counter failing
  re-check (checked in this order: RX_POLL_CALL_TOTAL==0; then
  SCHEDULER_MISSED_DEADLINE>0; then FINAL_PHY_OK/FINAL_VERSION_OK/
  FINAL_BUFFER_MAP_OK/VERSIONR; then MAX_REGISTER_TRIPLE_READ_MISMATCH/
  SPI_CORRUPTION_SUSPECTED; then FINAL_USB_STATE/FINAL_HID_READY/HID_READY_DROP/
  HID_STALL_COUNT as a closed-world fallback)
    -> DG_A_RX_POLL_PATH_STALL / DG_A_TIMING_FAIL / DG_A_PHY_HEALTH_FAIL /
       DG_A_MAX_SPI_CANARY_FAIL / DG_A_USB_HID_FAIL (as applicable)
  TEST_COMPLETE=FAIL with an unrecognized REASON=, evidence otherwise valid and no
  measured hard-criterion violated (a real "current vocabulary can't classify this
  FAIL" case)
    -> DG_A_FIRMWARE_FAIL_UNCLASSIFIED (original REASON token preserved as evidence)
  TEST_COMPLETE=PASS, Layer 1/2 valid (including all hard criteria), but no peer
  summary at all (B-15)
    -> BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID
  TEST_COMPLETE=PASS, Layer 1/2 valid, but peer evidence contract invalid
    -> BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID
  Peer summary valid but its own strict contract fails      -> DG_A_PEER_FAIL
  TEST_COMPLETE=PASS, Layer 1/2/3 valid, but reconciliation evidence unavailable
    -> BLOCKED_DG_A_EVIDENCE_CONTRACT_INVALID
  Firmware+peer both individually valid, cross-stream fails -> DG_A_RECONCILIATION_FAIL
  All four complete, valid layers agree                     -> PASS (positive
    allow-list, B-15 -- this is the only path to PASS in the entire function)
```

**Why measured hard criteria precede "remaining FAIL" (B-19)**: firmware's own
`runtimePass` already folds every hard criterion into a single boolean and reports
`TEST_COMPLETE=FAIL` whenever any of them fails — so a real, detach-free measurement
problem commonly looks like `TEST_COMPLETE=FAIL REASON=DURATION_COMPLETE
SCHEDULER_MISSED_DEADLINE=1`, i.e. an *ordinary* `REASON` with an abnormal measured
value, not an unusual `REASON` string. Checking `Completion==FAIL` before the measured
criteria would misreport this as merely "unclassified" and lose the actual, known
cause. `DG_A_FIRMWARE_FAIL_UNCLASSIFIED` is reserved for the residual case: evidence
valid, no Tier-1/2/named/measured classification applies, and `TEST_COMPLETE=FAIL`
anyway.

```text
Orthogonal, pre-trial gate (stops before any trial evidence exists):
  isolated library tree missing -> BLOCKED_BUILD_ENVIRONMENT_MISSING_ISOLATED_LIBRARIES
```

`ORCHESTRATION_STALL/TIMEOUT` may carry a non-overriding `SECONDARY=` annotation but
is never allowed to overwrite a Tier 0-3 primary classification once established —
this is the specific defect class that occurred at Gate C2-T1 (raw-serial `USB_DETACH`
primary vs. `ORCHESTRATION_STALL` secondary-reporting-condition), and DG-A's
classifier is designed not to repeat it.

## Stop conditions (future physical runner)

```text
USB detach
HID_READY_DROP
HID stall threshold exceeded
parsePacket() > 0
parsePacket() < 0
scheduler miss
PHY / link / VERSIONR / buffer-map failure
MAX register mismatch
source/dependency identity mismatch (Phase A or Phase B)
peer application TX nonzero
external timeout
```

Prohibited: automatic reset, automatic reconnect, automatic rerun, automatic
recovery, continuation of testing after failure.

## Evidence contract

Firmware raw-serial minimum: `RX_POLL_CALL_TOTAL`, `RX_POLL_POSITIVE_TOTAL`,
`RX_POLL_NEGATIVE_ERROR`, `RX_READ_CALL_TOTAL`, `RX_READ_BYTES_TOTAL`,
`RX_POLL_MAX_US`, `UDP_TX_TOTAL`, `UDP_TX_FAIL`, `UDP_BEGIN_COUNT`, `UDP_BEGIN_FAIL`,
`SCHEDULER_MISSED_DEADLINE`, `SCHEDULER_MAX_LATENESS_US`, `LOOP_MAX_US`,
`HID_STALL_COUNT`, `HID_MAX_NO_REPORT_MS`, `HID_READY_DROP`, `FINAL_USB_STATE`,
`FINAL_HID_READY`, `FINAL_PHY_OK`, `FINAL_VERSION_OK`, `FINAL_BUFFER_MAP_OK`,
`VERSIONR`, `MAX_REGISTER_TRIPLE_READ_MISMATCH`, `SPI_CORRUPTION_SUSPECTED`,
`TEST_MODE`, `TEST_MODE_NAME`, `TEST_COMPLETE`, `REASON`.

Peer summary minimum: `PEER_COMPLETE`, `PEER_ARMED`, `ADMISSION_SEQUENCE_ZERO_OK`,
`BLOCKED_ADMISSION_SEQUENCE_MISS`, `BOUND_NOT_ARMED_PACKET_COUNT`,
`PRE_ADMISSION_NON_C1_COUNT`, `VALID_RX_TOTAL`, `FIRST_SEQUENCE`, `LAST_SEQUENCE`,
per-field strict error counters, `PEER_TX_TO_DEVICE_TOTAL`, `PEER_RESULT`.

## Claim boundary

Completing DG-A implementation permits claiming only:

```text
DG-A implementation has been prepared and validated offline sufficiently for
external source review.
```

Not permitted, at any point in the implementation task:

```text
DG-A PASS / DG-A FAIL
USB detach reproduced
empty parsePacket is safe / empty parsePacket causes detach
root cause identified
DG-B authorized
Gate C3 authorized
```

## Implementation scope

Implementation-only: firmware Mode 17, receive-only peer, dedicated runner, dedicated
build matrix, offline self-tests, this contract, and an implementation review
package. Build-only (`arduino-cli compile`) validation is in scope; upload, serial
open, and physical trials are not.

## Physical prohibition

```text
PHYSICAL_EXECUTION=NOT_RUN
UPLOAD=NOT_RUN
SERIAL_OPEN=NOT_RUN
COM3_ACTIVE_ACCESS=NOT_RUN
COM4_ACTIVE_ACCESS=NOT_RUN
PHYSICAL_PEER_BIND=NOT_RUN
NETWORK_TRAFFIC_GENERATED=NOT_RUN
NIC_CHANGE=NOT_RUN
FIREWALL_CHANGE=NOT_RUN
C1_RERUN=NOT_RUN
C2_RERUN=NOT_RUN
GATE_C3=NOT_RUN
BUILD_ONLY=RUN (arduino-cli compile only, no upload)
```

`-PreflightPhysicalTrial`/`-RunPhysicalTrial` and `Invoke-DgAPhysicalTrial` exist as
real, reviewable source in `tools/usb_lan_gate_dg_a_runner.ps1` but were not invoked
during the implementation task this contract describes.

## Marker

`DG_A_IMPLEMENTATION_READY_FOR_EXTERNAL_REVIEW` is the highest claim this document or
the implementation review package may carry until an external reviewer says
otherwise.
