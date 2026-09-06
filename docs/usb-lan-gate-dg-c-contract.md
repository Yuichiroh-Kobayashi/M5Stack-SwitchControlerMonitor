# DG-C canonical implementation contract

## Status and authorization boundary

- Gate: `DG-C / ACTIVE_OPEN_PORT_INGRESS_NO_FIRMWARE_RX_CONTINUOUS`
- Design authority: `DG_C_R2_DESIGN_EXTERNAL_REVIEW=ACCEPT`
- Design state: `DG_C_CANONICAL_DESIGN=FROZEN`
- This implementation is implementation plus offline validation only.
- `IMPLEMENTATION=RUN`
- `FIRMWARE_SOURCE_MODIFICATION=NOT_RUN`
- `BUILD=NOT_RUN`
- `COMPILE=NOT_RUN`
- `UPLOAD=NOT_RUN`
- `FLASH=NOT_RUN`
- `SERIAL_OPEN=NOT_RUN`
- `COM_ACTIVE_ACCESS=NOT_RUN`
- `PHYSICAL_PEER_BIND=NOT_RUN`
- `NETWORK_TRAFFIC_GENERATED=NOT_RUN`
- `PACKET_CAPTURE=NOT_RUN`
- `DG_C_S1=NOT_RUN`
- `DG_C_T1=NOT_RUN`
- `GATE_C3=NOT_RUN`
- `C1_RERUN=NOT_RUN`
- `C2_RERUN=NOT_RUN`
- `DG_A_RERUN=NOT_RUN`
- `DG_B_RERUN=NOT_RUN`
- `COMMIT=NOT_RUN`
- `PUSH=NOT_RUN`
- `PR=NOT_RUN`

No physical operation is authorized by this contract.

## Exact changed variable and fixed treatment

The only scientifically relevant change from accepted DG-B is:

```text
PEER_SUBMISSION_DEST_PORT: 50002 -> 50001
```

After sequence-zero admission, every admitted valid device C1UD causes:

1. receive-completion timestamp;
2. synchronous strict validation;
3. one attempt increment;
4. exactly one immediate unconnected IPv4 UDP `sendto()`;
5. destination `192.168.50.10:50001`;
6. the same exact 32-byte `bytes` object content;
7. result or exception recording.

There is no peer timer, artificial 50 Hz pacing, sleep, batching, queue, or
retry. Fifty hertz is informational only from C1's nominal 20 ms scheduler.

The peer state machine remains:

```text
BOUND_NOT_ARMED -> ARMED_WAIT_SEQUENCE_ZERO -> ADMITTED
```

The peer remains an unconnected IPv4 UDP socket bound to
`192.168.50.30:50001`; its actual identity is taken from `getsockname()`.
`socket.timeout` is polling only. No `SIO_UDP_CONNRESET` policy is changed.
All other `OSError` conditions remain fatal, with no recreate, rebind, or
retry.

## Accepted donor authority

The implementation donor is uniquely the accepted DG-B review generation:

- generation: `DG-B-implementation-review-20260821-112246-515b278a`
- reviewed manifest: size 680,
  SHA-256 `170AD83EC387124D5C8C4F9101F3893C402F152C550D004661EB2CF4DEAD7541`
- peer: size 32380,
  SHA-256 `5552F52AF823E2454CB1A412CD817474860EE282F5A502075028060C0B2276C1`
- runner: size 100161,
  SHA-256 `FE285839233E82D2CFC6016C25F9CEEEA99ED8004E3892BAB3583CC043AE9B3F`
- contract: size 23443,
  SHA-256 `82C6085D2C496963C7DBE85396BC2180C7C427C698CC564020898AF61F8D7A92`

Current worktree bytes are not donor authority. Failure to resolve all four
identities is `BLOCKED_DG_C_DONOR_AUTHORITY_IDENTITY_UNRESOLVED`.

## Exact C1 firmware and artifact authority

DG-C reuses `C1-final-20260818-005403-666bf93b` Mode15:
`TEST_MODE=15`,
`TEST_MODE_NAME=USB_FIXED10_UDP_TX_ONLY`.

- archive manifest SHA-256:
  `CBEF2EEB288F72DCCFD35797D994B3D15C3551D2E7CAD0FB423528182358B028`
- freeze ZIP SHA-256:
  `41071B6A948768E179C76627A4132C311888491A0DF0510B9533A6CBBEFC12E2`
- S1 application: size 562480,
  SHA-256 `8320BD7B6BD08D145DE47C8EBAE21497916653592CC625E5AEE55E627CFCD140`
- T1 application: size 562480,
  SHA-256 `0AFD5F98AC9D7EF440442416AB8F84E47DBCF4F4EDE30BEC4B89EC57DED5960B`
- bootloader: size 19984,
  SHA-256 `5403BA8CDF81CBB47F2DEBE13C0F5FF5903540075CCAF3FAC65F0EE68213CB7D`
- partitions: size 3072,
  SHA-256 `ACE02503447D0F470692E65FA76002F2D77A92DC81CD3813D8AA66718D716DA9`
- boot_app0: size 8192,
  SHA-256 `F94C5D786A7A8FAB06AC5D10E33BF37711A6697636DC037559EA19CC410A17F0`
- S1 merged: size 16777216,
  SHA-256 `0F172CFC1286D369B8D8652688FE1A4071863DA5A9AC7B33352EE10ACB154F07`
- T1 merged: size 16777216,
  SHA-256 `70424920B0529D733704EE95493FB268EAE38D09FC5595CA9A329B1FEAADB5C0`

There is no firmware source change, new Mode, fresh build, build matrix, or
RX-register instrumentation. The runner stages immutable accepted artifacts
inside the future trial root, hashes before and after the future upload, and
verifies the boot_app0 merged-image slice. Offline upload-plan generation does
not execute the command.

## Fixed physical and network conditions

- CoreS3 SE
- USB Module v1.2
- HORI PAD TURBO, VID `0F0D`, PID `0202`, physical mode `Switch 2`
- LAN Module 13.2
- BAT Bottom
- Sender `192.168.50.10`
- S0 UDP/open/local port `50001`
- peer `192.168.50.30:50001`
- peer submission destination `192.168.50.10:50001`
- PHY `Fixed10Half`
- exact accepted C1 Mode15 artifact
- no firmware `parsePacket()`, `udp.read()`, RX validation, or RX
  bookkeeping
- physical Receiver not used
- no unrelated intentional device on the isolated test segment

M5GO Bottom3 is not part of DG-C.

## FACT / HYP / UNKNOWN boundary

| Status | Statement |
|---|---|
| FACT | Exact accepted C1 authority proves S0 is UDP/open/local port 50001. |
| FACT | S0 RX capacity is 8192 bytes. |
| FACT | The library-visible receive-path layout is an 8-byte pseudo-header plus a 32-byte payload, 40 bytes total. |
| FACT | Valid complete peer evidence with at least one exact successful submission establishes only `PEER_APPLICATION_SUBMISSION_TO_PROVEN_OPEN_PORT=1`. |
| HYP | Every physically accepted DG-C datagram stores 40 bytes. |
| HYP | No-drain occupancy grows exactly 40 bytes per accepted datagram. |
| HYP | About 204 accepted datagrams fill the region. |
| HYP | At nominal 50 Hz the region fills in about 4.1 seconds. |
| HYP | Full-buffer operation is an anticipated possible mediator. |
| UNKNOWN | Actual physical arrival at the W5500. |
| UNKNOWN | W5500 socket match/acceptance. |
| UNKNOWN | W5500 RX storage. |
| UNKNOWN | Actual RX-buffer saturation. |
| UNKNOWN | W5500 matched-port internal semantics and subsequent packet behavior. |

The following fields remain literal `UNKNOWN`, including after successful
`sendto()`:

```text
W5500_PACKET_ARRIVAL=UNKNOWN
W5500_SOCKET_MATCH_ACCEPTANCE=UNKNOWN
W5500_RX_STORAGE=UNKNOWN
W5500_RX_BUFFER_SATURATION=UNKNOWN
W5500_MATCHED_PORT_INTERNAL_SEMANTICS=UNKNOWN
```

## Treatment establishment

`DG_C_STIMULUS_ESTABLISHED=1` only when a valid complete peer summary proves
`INGRESS_TX_SUCCESS_TOTAL > 0` and the successful destination is exactly
`192.168.50.10:50001`.

`DG_C_STIMULUS_ESTABLISHED=0` means valid peer evidence proves zero
successful submissions. `UNKNOWN` means peer evidence cannot determine the
count. Configuration, S0-open authority, arm, admission, or attempt count alone
never establishes treatment.

For a valid complete peer summary,
`PEER_APPLICATION_SUBMISSION_TO_PROVEN_OPEN_PORT` is 1 when successful exact
submissions are positive and 0 when they are zero. Invalid or unavailable peer
evidence is reported by the runner as `UNKNOWN`.

## Device and peer evidence contract

The exact C1 Mode15 serial parser is reused. It requires exact C1 final and
terminal authority, C1_FINAL-only counters, terminal `TEST_COMPLETE`,
`SCHEDULER_MISSED_DEADLINE=0`, USB/HID, PHY, VERSIONR, buffer map, MAX/SPI
canary, UDP TX, and startup-versus-trial observations. A raw Tier-1 USB/HID
detector runs before structured parsing. No W5500 RX occupancy or interrupt
field is required.

Peer evidence includes completion, arm and admission states; strict parser
errors; valid count and sequence range; attempt/success/failure counts and
sequence range; actual bound identity; source and destination identities;
socket errors; monotonic timing; fatal reason; peer result; treatment claim;
and the literal W5500 UNKNOWN boundary.

Timing uses `time.perf_counter_ns()` at receive completion, send attempt, and
send result. Ordering must be monotonic. Summaries include RX-to-send maximum
and p99 and send-call maximum. There is no latency or 50 Hz threshold.

Complete PASS reconciliation requires:

```text
device UDP_TX_TOTAL
 == peer VALID_DEVICE_TX_RX_TOTAL
 == peer INGRESS_TX_ATTEMPT_TOTAL
 == peer INGRESS_TX_SUCCESS_TOTAL
INGRESS_TX_FAIL_TOTAL=0
```

The sequence is continuous from zero, strict receive errors are zero, and peer
socket errors are zero. Counts 500 or 3000 are not hardcoded. For an early raw
physical failure, only an internally consistent prefix may be used.

Missing or malformed evidence fails closed. Evidence priority is raw serial,
raw peer CSV/stdout/stderr, artifact/build/upload evidence, frozen
source/dependency authority, reviewed manifests, offline fixtures, design
documents, then summaries.

## Closed-world causal adjudication

One canonical serializer always emits this exact ordered eight-line array to
stdout and, after trial-root creation, to
`<trialRoot>/runner-adjudication.txt`:

```text
DG_C_CLASSIFICATION_PRIMARY=<token>
DG_C_CLASSIFICATION_SECONDARY=<token|NONE>
DG_C_STIMULUS_ESTABLISHED=1|0|UNKNOWN
DG_C_TRIAL_RESULT=PASS|FAIL|BLOCKED
DG_C_TRIAL_BLOCK_REASON=<token|NONE>
DG_C_DEVICE_PRETRIAL_REASON=<raw-reason|NONE>
C2_TYPE_USB_HID_REPRODUCTION=ESTABLISHED|NOT_ESTABLISHED
PEER_APPLICATION_SUBMISSION_TO_PROVEN_OPEN_PORT=1|0|UNKNOWN
```

The file is UTF-8 without BOM with deterministic LF line endings. The exact
same line array is persisted for PASS, FAIL, BLOCKED, and fallback after
trial-root creation. Raw evidence remains higher authority.

Raw implementation observations and canonical adjudication tokens are separate
namespaces. In particular:

```text
SERIAL_CAPTURE_TIMEOUT -> BLOCKED_DG_C_ORCHESTRATION
PEER_GRACEFUL_EXIT_TIMEOUT -> BLOCKED_DG_C_ORCHESTRATION
```

Neither raw timeout string may appear in
`DG_C_CLASSIFICATION_PRIMARY`, `DG_C_CLASSIFICATION_SECONDARY`, or
`DG_C_TRIAL_BLOCK_REASON`. The exact low-level observation is supplementary
evidence in `<trialRoot>/runner-control-plane-observation.txt`, encoded as
deterministic UTF-8 without BOM and LF line endings. It is not a ninth
adjudication line and does not change the evidence authority order.

Before serialization, Primary, Secondary, and TrialBlockReason are validated
against a defined closed-world set containing the R2 vocabulary and the
runner's required authority/preflight blockers. `NONE` is accepted only
where defined. An arbitrary or unknown value fails closed to:

```text
DG_C_CLASSIFICATION_PRIMARY=BLOCKED_DG_C_EVIDENCE_CONTRACT_INVALID
DG_C_TRIAL_RESULT=BLOCKED
DG_C_TRIAL_BLOCK_REASON=BLOCKED_DG_C_EVIDENCE_CONTRACT_INVALID
```

The rejected value is preserved only in supplementary control-plane evidence;
it is never copied into the canonical eight-line array. Fallback construction
uses fixed canonical values and does not recursively invoke itself.

Deterministic precedence:

1. raw USB/HID observation: `DG_C_USB_HID_FAIL`;
2. other device health observation: `DG_C_DEVICE_LOGICAL_FAIL`;
3. peer/control blocker, preserving a higher device primary as secondary;
4. artifact/evidence/orchestration blocker;
5. treatment-not-established blocker;
6. `DG_C_PASS` only after all four layers reconcile.

USB/HID failure plus established stimulus and no peer/control break is FAIL
with C2 reproduction ESTABLISHED. USB/HID failure plus stimulus 0 or UNKNOWN
is BLOCKED and NOT_ESTABLISHED. A later peer/control break makes the trial
BLOCKED even after earlier success and cannot overwrite the raw USB primary.

A scheduler, PHY, VERSIONR, buffer-map, MAX/SPI, or UDP-TX failure is
`DG_C_DEVICE_LOGICAL_FAIL`. With stimulus 1 and no peer/control break it is
FAIL; with stimulus 0 or UNKNOWN it is BLOCKED. It never establishes C2-type
USB/HID reproduction.

`DG_C_DEVICE_PRETRIAL_REASON` is the exact raw reason only when temporal
evidence proves the device failure preceded the first successful DG-C
submission. Stimulus UNKNOWN alone does not prove pretrial ordering; otherwise
the field is `NONE`.

Admission miss, async UDP error, short send, peer execution failure, or
evidence/control-plane break always makes TrialResult BLOCKED. No default PASS
exists.

Closed-world tokens include:

- `DG_C_PASS`
- `DG_C_USB_HID_FAIL`
- `DG_C_DEVICE_LOGICAL_FAIL`
- `DG_C_PEER_INGRESS_SEND_FAIL`
- `BLOCKED_DG_C_ARTIFACT_IDENTITY`
- `BLOCKED_DG_C_ADMISSION_SEQUENCE_MISS`
- `BLOCKED_DG_C_TREATMENT_NOT_ESTABLISHED`
- `BLOCKED_DG_C_PEER_UDP_ASYNC_ERROR`
- `BLOCKED_DG_C_CONTROL_PLANE`
- `BLOCKED_DG_C_EVIDENCE_CONTRACT_INVALID`
- `BLOCKED_DG_C_ORCHESTRATION`

## Claim boundary

PASS permits only:

> Under the exact accepted C1 condition, one-for-one peer application UDP
> submissions addressed to the device port proven open as S0 UDP/50001,
> together with whatever autonomous W5500 behavior actually occurred under
> that condition, were not sufficient to reproduce the C2 USB/HID detach in
> the accepted trial.

PASS does not prove physical arrival, socket match, RX storage, fill,
saturation, interrupt/status change, post-full drops, or universal safety.

FAIL with raw USB/HID evidence and established treatment permits only:

> A C2-type USB/HID failure occurred while continuous application submissions
> were being made toward the device's proven-open UDP port and the firmware
> executed no parsePacket/read/validation/bookkeeping.

It does not distinguish receipt, matching, buffering, saturation,
interrupt/status behavior, full-buffer behavior, or other autonomous W5500
effects without separate higher-authority evidence.

## Packet-capture policy

`DG_C_PACKET_CAPTURE=NOT_USED`. Wireshark, Npcap, pktmon, tcpdump, and any
optional capture path are absent. This keeps host-side treatment aligned with
accepted DG-B and avoids an extra runtime process, driver, and timing variable.
A later packet-level evidence enhancement requires a separate external review.

## Future physical sequence

The future capability, not authorized here, preserves:

```text
implementation authority
-> trial evidence root
-> exact C1 authority
-> in-root staging
-> toolchain / COM / NIC checks
-> peer BOUND_NOT_ARMED / READY
-> exact artifact upload only
-> POST_UPLOAD rehash
-> exact COM4 re-enumeration
-> serial open
-> SERIAL_CAPTURE_READY
-> arm
-> sequence-zero admission
-> first DG-C submission
-> raw capture
-> bounded teardown
-> parsing
-> causal/four-layer adjudication
-> runner-adjudication persistence
```

Arm before serial ready is prohibited. There is no automatic retry.

## S1 and T1

- S1: 10 seconds using the exact accepted C1-S1 Mode15 application
  `8320BD7B6BD08D145DE47C8EBAE21497916653592CC625E5AEE55E627CFCD140`.
- T1: 60 seconds using the exact accepted C1-T1 Mode15 application
  `0AFD5F98AC9D7EF440442416AB8F84E47DBCF4F4EDE30BEC4B89EC57DED5960B`.

There is no automatic S1-to-T1 progression, no automatic rerun, and the first
physical FAIL stops progression. Actual reconciled counters are authoritative;
nominal packet counts are informational only.

## Implementation and review lifecycle

Implementation source is limited to:

- `docs/usb-lan-gate-dg-c-contract.md`
- `tools/usb_lan_gate_dg_c_peer.py`
- `tools/usb_lan_gate_dg_c_runner.ps1`

Accepted DG-B files are not edited. Offline review output is generated under
`build-temp/usb-lan-isolation/review/DG-C-implementation-review-<timestamp>-<id>/`.
The candidate reviewed-source manifest locks exactly the three files above
with columns `path,size,sha256,role`, excludes itself, has a sibling SHA
sidecar, and is labeled `PROPOSED_EXPECTED_REVIEWED_MANIFEST_SHA256`. It is
not accepted authority until external review. The review-package manifest
also excludes itself and its sidecar to avoid circular authority.
