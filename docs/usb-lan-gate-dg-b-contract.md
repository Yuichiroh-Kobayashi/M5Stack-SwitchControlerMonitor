# DG-B UNMATCHED_PORT_INGRESS implementation contract

Status: implementation candidate for external review. It is not authority for a
physical trial until its reviewed-source manifest is accepted externally and a
separate S1 authorization is issued.

## 1. Accepted question and claim boundary

DG-B asks whether controlled one-for-one UDP submission toward an unbound local
UDP port on the W5500 reproduces the USB/HID detach while the exact accepted C1
Mode15 firmware remains installed and executes no firmware RX processing.

For each admitted valid C1UD packet, the peer application submits exactly one
identical 32-byte UDP datagram:

- operational source socket: `192.168.50.30:50001`
- destination: `192.168.50.10:50002`
- `50002_UNBOUND_BY_C1_FIRMWARE=PROVEN`
- `W5500_UNMATCHED_PORT_INTERNAL_SEMANTICS=UNKNOWN`

All autonomous W5500 behavior caused by this unmatched-port submission is part
of the treatment. This contract does not assert silent drop, unchanged RX
memory or interrupts, absence of autonomous W5500 transmission, or physical
arrival of every application-submitted datagram.

Operational stimulus evidence means only that the peer application successfully
submitted one-for-one datagrams to the local network stack toward the specified
destination.

## 2. Immutable device authority

No DG-B firmware exists. The implementation must not modify
`M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino`, create Mode18, create a firmware
build matrix, or compile C1.

Final C1 authority:

- generation: `C1-final-20260818-005403-666bf93b`
- archive-manifest SHA-256:
  `CBEF2EEB288F72DCCFD35797D994B3D15C3551D2E7CAD0FB423528182358B028`
- freeze ZIP size: `4482569`
- freeze ZIP SHA-256:
  `41071B6A948768E179C76627A4132C311888491A0DF0510B9533A6CBBEFC12E2`

Upload artifacts:

| Role | Size | SHA-256 | Offset |
|---|---:|---|---:|
| S1 application | 562480 | `8320BD7B6BD08D145DE47C8EBAE21497916653592CC625E5AEE55E627CFCD140` | `0x10000` |
| T1 application | 562480 | `0AFD5F98AC9D7EF440442416AB8F84E47DBCF4F4EDE30BEC4B89EC57DED5960B` | `0x10000` |
| bootloader | 19984 | `5403BA8CDF81CBB47F2DEBE13C0F5FF5903540075CCAF3FAC65F0EE68213CB7D` | `0x0000` |
| partitions | 3072 | `ACE02503447D0F470692E65FA76002F2D77A92DC81CD3813D8AA66718D716DA9` | `0x8000` |
| boot_app0 | 8192 | `F94C5D786A7A8FAB06AC5D10E33BF37711A6697636DC037559EA19CC410A17F0` | `0xE000` |
| S1 merged authority, not uploaded | 16777216 | `0F172CFC1286D369B8D8652688FE1A4071863DA5A9AC7B33352EE10ACB154F07` | N/A |
| T1 merged authority, not uploaded | 16777216 | `70424920B0529D733704EE95493FB268EAE38D09FC5595CA9A329B1FEAADB5C0` | N/A |

`boot_app0.bin` is usable only when its exact identity matches the table and its
bytes equal the stage-specific merged image slice at `0xE000` for 8192 bytes.
No current rebuilt application, bootloader, or partitions may substitute for
the frozen bytes.

## 3. Donor authorities

Copy-adapt work is grounded in these exact frozen/reviewed donors:

| Role | Size | SHA-256 |
|---|---:|---|
| C1 runner/parser | 50138 | `5B24705265AA3B2D3830B2446F4BF75CCBACC4389C5605F475A968BA4F93E6B6` |
| C1 peer/parser | 19422 | `2D1CFD91DD68DAF9F2A25D0F80962315CBB0648A4AD517B3279AEAF491E8663A` |
| C2 peer/admission/send | 40178 | `B63F0C50F4B7A27964A79722DCC47E86254DA7E953CBBAC2827BFCBEDC727598` |
| C2 runner/control plane | 73380 | `84997D656D85AA41687A33A8EF361777F5DF46B5A86536DE9499906808B5B65A` |
| DG-A peer/evidence | 40843 | `6BA4D03C7FC517DC1A958D5A3FA34D55B8DEC92B393B52AB78F6FF8BE7EE4CFF` |
| DG-A runner/Tier-1 teardown | 122259 | `58FF23B9FC8577F9D63A45E3B0F4A1C3754EB5300D7ABE181710F24793952AB7` |

Filename similarity is not authority. Size and SHA-256 must both pass against
the resolved frozen path.

## 4. Artifact staging and future upload

The runner must:

1. create a dedicated physical trial root under
   `build-temp/usb-lan-isolation/gate-dg-b/DG-B-<S1|T1>-<timestamp>-<id>`;
2. verify the original frozen path, size, and SHA-256;
3. create `<trial-root>/artifact-staging` before starting the peer;
4. copy application, bootloader, partitions, boot_app0, and merged authority;
5. verify every staged size and SHA-256;
6. compare staged boot_app0 with the staged merged `0xE000` slice;
7. emit exactly four upload segment identities;
8. leave all freeze bytes untouched.

Before upload, the runner writes
`artifact-authority-pre-upload.csv` with
`ARTIFACT_IDENTITY_PHASE=PRE_UPLOAD`. It records role, offset, actual path,
size, and SHA-256 for the staged application, bootloader, partitions,
boot_app0 evidence copy, actual platform boot_app0 upload input, merged
authority, and the merged `0xE000` slice. After upload and before arm it
rehashes those same paths into `artifact-authority-post-upload.csv` with
`ARTIFACT_IDENTITY_PHASE=POST_UPLOAD`. POST values are compared with both PRE
values and the accepted C1 constants; they never become their own expected
authority. Any drift is
`BLOCKED_DG_B_UPLOAD_ARTIFACT_IDENTITY_DRIFT`, with no arm and no retry.

Upload toolchain authority is fixed and verified before peer start:

| Item | Required authority |
|---|---|
| Arduino CLI path | `C:\Program Files\Arduino IDE\resources\app\lib\backend\resources\arduino-cli.exe` |
| Arduino CLI version | `1.5.1` |
| m5stack ESP32 core | `3.3.7` |
| platform.txt SHA-256 | `E778787B6C8521AB1C5F6185AC32398F88DFBE4F943813A8CFF052FE924F152B` |
| actual platform boot_app0 SHA-256 | `F94C5D786A7A8FAB06AC5D10E33BF37711A6697636DC037559EA19CC410A17F0` |

The runner records CLI path/version, core path/version, platform path/hash, and
actual boot_app0 path/hash. A mismatch is
`BLOCKED_DG_B_UPLOAD_TOOLCHAIN_IDENTITY_MISMATCH`; no install or update is
allowed.

The future command is:

```text
"C:\Program Files\Arduino IDE\resources\app\lib\backend\resources\arduino-cli.exe" upload --fqbn m5stack:esp32:m5stack_cores3 --port COM4 --input-dir <trial-root>\artifact-staging
```

It is upload-only. No compile/build command and no whole-flash merged upload is
permitted. Future upload stdout/stderr must be preserved and must establish the
four expected offsets and writes.

## 5. Peer state and packet contract

State machine:

```text
BOUND_NOT_ARMED
  -> ARMED_WAIT_SEQUENCE_ZERO
  -> ADMITTED
```

Before arm, packets are logged only and do not modify strict counters. Arm is
requested only after `UPLOAD_PASS`. While waiting, non-C1 or wrong-source
traffic increments only `PRE_ADMISSION_NON_C1_COUNT`.

The first fully valid expected-source frame decides admission:

- sequence 0: transition to ADMITTED and process it through the normal strict path;
- nonzero sequence: `BLOCKED_ADMISSION_SEQUENCE_MISS`, stop, no recovery.

C1UD requirements:

- magic `C1UD`
- version 1
- gate 1
- 32 bytes
- required flags `0x03`, reserved flags clear
- CRC-16/CCITT-FALSE
- deterministic accepted C1 payload
- source `192.168.50.10:50001`
- continuous sequence beginning at zero

Length, magic/version/gate, flags, CRC, payload, source IP/port, gaps,
duplicates, and out-of-order packets have separate strict counters.

## 6. Socket identity and stimulus

The future peer uses one unconnected IPv4 UDP socket bound to
`192.168.50.30:50001`. Immediately after bind and before `PEER_READY`, it calls
`getsockname()`. The actual tuple must equal the required tuple. Mismatch blocks
the trial before ready/arm/stimulus.

`PEER_BOUND_*` and `INGRESS_SOURCE_*` are derived from the actual tuple, not
from configured constants.

For each strictly valid admitted packet:

1. retain receive-completion monotonic timestamp;
2. validate synchronously;
3. increment ATTEMPT immediately before `sendto()`;
4. make exactly one call with the unchanged packet and destination
   `192.168.50.10:50002`;
5. record return or exception;
6. do not sleep, queue, batch, reconnect, recreate, rebind, or retry.

Successful submission requires `sendto()` to return exactly 32. A shorter
normal return increments FAIL and produces `DG_B_PEER_INGRESS_SEND_FAIL`.

## 7. Monotonic timing evidence

The peer uses `time.perf_counter_ns()` and records per attempt:

```text
INGRESS_RX_MONOTONIC_NS
INGRESS_SEND_ATTEMPT_MONOTONIC_NS
INGRESS_SEND_RESULT_MONOTONIC_NS
INGRESS_RX_TO_SEND_ATTEMPT_US
INGRESS_SEND_CALL_US
INGRESS_SEND_RESULT
```

Ordering must be receive <= attempt <= result. Missing or reversed evidence is
`BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID`.

Summary fields are:

```text
INGRESS_RX_TO_SEND_MAX_US
INGRESS_RX_TO_SEND_P99_US
INGRESS_SEND_CALL_MAX_US
```

P99 is nearest-rank `sorted[ceil(0.99*n)-1]`. There is no latency threshold;
these statistics are review evidence.

## 8. Windows asynchronous UDP error handling

The peer does not use or change `SIO_UDP_CONNRESET`. `socket.timeout` is a
normal polling outcome. Every other bind, getsockname, recvfrom, or sendto
`OSError` is fatal for that trial and records:

```text
PEER_SOCKET_ERROR_TOTAL
PEER_SOCKET_ERROR_PHASE
PEER_SOCKET_ERROR_SEQUENCE
PEER_SOCKET_ERROR_ERRNO
PEER_SOCKET_ERROR_WINERROR
PEER_SOCKET_ERROR_MESSAGE
```

Phases are `BIND`, `GETSOCKNAME`, `RECVFROM`, `SENDTO`, or `NONE`. Missing
numeric properties use `NA`; message text is JSON escaped. Summary generation
must remain non-throwing.

The socket is not claimed to be permanently unusable by Winsock. It is
experimentally unusable for the current trial because recovery could lose the
one-to-one mapping and would introduce rebind/recreation behavior absent from
the accepted treatment. The peer flushes evidence, closes, and stops without
retry.

Without an already-established physical failure, the classification is
`BLOCKED_DG_B_PEER_UDP_ASYNC_ERROR`. With raw USB/HID failure, it is SECONDARY.

## 9. Exact C1 serial evidence

Device identity remains:

```text
TEST_MODE=15
TEST_MODE_NAME=USB_FIXED10_UDP_TX_ONLY
```

Normal runtime requires exactly one each, in order:

```text
C1_FINAL ...
TEST_COMPLETE=<PASS|FAIL> ...
SCOPE_MARKER trial=C1 event=TRIAL_COMPLETE result=<same result>
```

`C1_DIAG` is informational only. It may never supply a missing final field.
`C1_FINAL` requires every available final statistic emitted by frozen C1,
including UDP totals, begin/timing fields, scheduler counters, loop timing, and
HID stall fields. The terminal requires every available frozen C1 terminal
field, including identity, duration/reason, USB/HID, VID/PID, PHY/version/buffer,
MAX canary, and scope result.

Duplicated semantics such as `HID_STALL_COUNT` remain separately parsed and
must agree. The exact frozen overlap is `HID_STALL_COUNT` and
`HID_MAX_NO_REPORT_MS`; both C1_FINAL and TEST_COMPLETE values are retained and
compared. A mismatch is evidence-contract invalid, and the later value never
silently replaces the earlier value.

Runtime reasons:

```text
DURATION_COMPLETE
USB_DETACH_OR_UNSUPPORTED
HID_STALL
MAX_REGISTER_MISMATCH
LINK_OR_PHY_CHANGED
```

Exact setup reasons are inventoried in the runner from frozen source and use a
separate `C1_SETUP_FAIL` schema. Unknown or impossible terminal semantics fail
closed as `BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID`.

Raw provisional Tier-1 detection precedes parsing and recognizes at least
`USB_DETACH`, `REASON=USB_DETACH_OR_UNSUPPORTED`, and `REASON=HID_STALL`.
Once detected, `DG_B_USB_HID_FAIL` remains PRIMARY despite later parser, peer,
teardown, or reporting failure.

## 10. Scheduler and four-layer PASS

DG-B adds the external criterion:

```text
SCHEDULER_MISSED_DEADLINE == 0
```

It does not change C1 firmware. A nonzero value without higher-priority USB/HID
failure is `DG_B_TIMING_FAIL`.

PASS requires all four layers:

1. exact C1 firmware logical health;
2. strict raw serial evidence validity;
3. peer and stimulus contract PASS;
4. cross reconciliation PASS.

Reconciliation is:

```text
device C1_FINAL.UDP_TX_TOTAL
== peer VALID_DEVICE_TX_RX_TOTAL
== peer INGRESS_TX_ATTEMPT_TOTAL
== peer INGRESS_TX_SUCCESS_TOTAL
```

It also requires `INGRESS_TX_FAIL_TOTAL=0`, `PEER_SOCKET_ERROR_TOTAL=0`, all
strict counters zero, sequence zero first, and continuity. Counts 500 and 3000
are not hardcoded. Accepted shapes 499 and 3000 can both PASS when all layers
reconcile.

The runner parses the peer summary fail-closed. Boolean fields accept only `0`
or `1`; sequence fields accept only `NONE` or decimal uint32; result is one of
`PASS`, `FAIL`, or `BLOCKED`; fatal reason is one of the exact peer-source
tokens. Timing values must be finite, numeric, and nonnegative, with maximum
not less than P99. For complete PASS, both first sequences are zero and both
last sequences equal `VALID_DEVICE_TX_RX_TOTAL - 1`; wrap is not accepted in
S1/T1. Malformed types or unknown enums are
`BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID`. A parseable but stream-inconsistent
summary is `BLOCKED_DG_B_STIMULUS_NOT_ESTABLISHED` unless higher-authority raw
USB/HID failure exists.

With `PEER_SOCKET_ERROR_TOTAL=0`, phase must be `NONE` and sequence, errno, and
winerror must be `NA`. A PASS-compatible summary also requires fatal reason
`NONE`. With a nonzero socket-error total, phase must be a defined non-NONE
phase and result/fatal/error fields must agree. Raw async error evidence is
preserved; it is never converted into an orchestration timeout.

## 11. Treatment establishment and causal adjudication

Raw physical failure evidence and proof that the DG-B treatment was
established are separate facts. A raw USB/HID failure remains the highest
authority for the observed technical event, but it does not by itself prove
that unmatched-port ingress had begun. The Gate can therefore report
`DG_B_USB_HID_FAIL` as its primary observation while its experimental trial
result remains `BLOCKED`.

The runner externally adjudicates:

```text
DG_B_STIMULUS_ESTABLISHED=1|0|UNKNOWN
```

- `1`: valid peer evidence proves `INGRESS_TX_SUCCESS_TOTAL > 0`.
- `0`: valid peer evidence proves `INGRESS_TX_SUCCESS_TOTAL == 0`.
- `UNKNOWN`: peer evidence is missing, invalid, or unavailable.

Configuration, peer arm, sequence-zero admission, and
`INGRESS_TX_ATTEMPT_TOTAL` do not establish the stimulus. A failed `sendto()`
attempt does not establish the accepted operational treatment.

The final experimental result is a separate field:

```text
DG_B_TRIAL_RESULT=PASS|FAIL|BLOCKED
```

`PASS` requires the existing complete four-layer PASS and
`DG_B_STIMULUS_ESTABLISHED=1`. `FAIL` requires a defined device-side treatment
effect observation and stimulus establishment `1`. Device-side treatment
effect observations are `DG_B_USB_HID_FAIL`, `DG_B_DEVICE_TX_FAIL`,
`DG_B_TIMING_FAIL`, `DG_B_PHY_HEALTH_FAIL`, and
`DG_B_MAX_SPI_CANARY_FAIL`.

For any such device observation with stimulus state `0`, the primary technical
observation is preserved, but the final result is `BLOCKED` with
`DG_B_TRIAL_BLOCK_REASON=BLOCKED_DG_B_STIMULUS_NOT_ESTABLISHED`. With state
`UNKNOWN`, the result is `BLOCKED` and the missing or invalid peer-evidence
condition is retained as secondary evidence; it is never converted into an
orchestration stall.

A valid C1 `C1_SETUP_FAIL` occurs before admission and intentional DG-B
stimulus. It is classified as:

```text
DG_B_CLASSIFICATION_PRIMARY=BLOCKED_DG_B_DEVICE_PRETRIAL_FAILURE
DG_B_STIMULUS_ESTABLISHED=0
DG_B_TRIAL_RESULT=BLOCKED
DG_B_TRIAL_BLOCK_REASON=BLOCKED_DG_B_DEVICE_PRETRIAL_FAILURE
DG_B_DEVICE_PRETRIAL_REASON=<exact C1 setup reason>
```

It is not reclassified as a DG-B USB/HID, TX, or PHY treatment failure.

Peer async/socket failure, admission failure, short send, malformed evidence,
or another peer/control-plane failure remains `BLOCKED`, even if one or more
successful submissions preceded it, because the intended complete treatment
did not complete. Its exact technical/control-plane primary or secondary token
is preserved. These peer failures are not conflated with a USB/HID
treatment-effect failure.

The adjudication object retains separate `Primary`, `Secondary`,
`StimulusEstablished`, `TrialResult`, `TrialBlockReason`, and
`DevicePretrialReason` fields. There is no default PASS or FAIL branch.

## 12. Closed-world classification

Primary vocabulary:

```text
DG_B_PASS
DG_B_USB_HID_FAIL
DG_B_DEVICE_TX_FAIL
DG_B_PEER_INGRESS_SEND_FAIL
DG_B_TIMING_FAIL
DG_B_PHY_HEALTH_FAIL
DG_B_MAX_SPI_CANARY_FAIL
BLOCKED_DG_B_DEVICE_PRETRIAL_FAILURE
BLOCKED_DG_B_C1_ARTIFACT_IDENTITY_MISMATCH
BLOCKED_DG_B_EXACT_C1_ARTIFACT_UPLOAD_PATH_UNRESOLVED
BLOCKED_DG_B_UPLOAD_TOOLCHAIN_IDENTITY_MISMATCH
BLOCKED_DG_B_UPLOAD_ARTIFACT_IDENTITY_DRIFT
BLOCKED_DG_B_DROP_PORT_NOT_PROVEN_UNBOUND
BLOCKED_DG_B_COM4_PNP_IDENTITY
BLOCKED_DG_B_COM4_REENUMERATION
BLOCKED_DG_B_SERIAL_CAPTURE_NOT_READY
BLOCKED_DG_B_PEER_TOPOLOGY
BLOCKED_DG_B_STIMULUS_NOT_ESTABLISHED
BLOCKED_DG_B_PEER_UDP_ASYNC_ERROR
BLOCKED_ADMISSION_SEQUENCE_MISS
BLOCKED_DG_B_EVIDENCE_CONTRACT_INVALID
ORCHESTRATION_STALL/TIMEOUT
```

Raw USB/HID failure is highest. Concrete named failures precede BLOCKED
evidence states. `Primary` classifies the observed technical or control-plane
event; it is not overloaded with the final causal trial result. Orchestration
stall is used only when no more specific raw evidence exists. PASS is a
positive allow-list with no default branch.

## 13. Future physical control plane

The runner's physical path exists but is guarded by `-RunPhysicalTrial` plus
all four explicit permission switches. It also requires externally supplied
`ReviewedManifestPath` and `ExpectedReviewedManifestSha256`. If the retained
`ExpectedPnpDeviceId` parameter is supplied, it must equal exactly:

```text
USB\VID_303A&PID_1001&MI_00\6&25A42EA3&0&0000
```

Passive enumeration must find exactly that entity on COM4. After upload, the
copy-adapted bounded re-enumeration gate must find the same exact entity on
COM4 within its timeout; ad-hoc fixed sleeps are not authority.

The Ethernet preflight is read-only. It requires one unambiguous
`192.168.50.30/24` address on an Up adapter, no default gateway on that test
interface, and one direct `192.168.50.0/24` route on it. Ping, ARP probe, and
other active preflight traffic are prohibited. A mismatch is
`BLOCKED_DG_B_PEER_TOPOLOGY`.

Future physical ordering is closed:

1. accepted implementation authority;
2. exact C1 artifact authority;
3. trial root and in-root artifact staging;
4. COM, NIC, and toolchain preconditions;
5. peer `BOUND_NOT_ARMED`, then `PEER_READY`;
6. exact staged upload and upload-evidence PASS;
7. POST_UPLOAD artifact rehash;
8. bounded exact COM4 re-enumeration;
9. serial port open and `SERIAL_CAPTURE_READY`;
10. only then write the arm file and await armed acknowledgement;
11. sequence-zero admission, first DG-B stimulus, capture, and adjudication.

`SERIAL_CAPTURE_READY` must precede `ARM_REQUESTED`. If serial open fails, the
primary pretrial token is `BLOCKED_DG_B_SERIAL_CAPTURE_NOT_READY`; arm is never
requested. Peer bind/getsockname failure, COM re-enumeration failure,
toolchain mismatch, artifact drift, upload failure, and serial-open failure all
preserve available trial-root evidence and stop without retry.

Serial capture appends raw `ReadExisting()` characters to one accumulated
buffer and searches that accumulated stream for the terminal marker, so a
marker split across chunks is recognized. `serial.log` is written once as
UTF-8 without BOM using exact text preservation: no newline is appended and
mixed CRLF/LF sequences are retained. Separate metadata records COM identity,
capture start/end, terminal detection or timeout, character length, and SHA-256
of the exact UTF-8 representation.

After capture, raw evidence preservation, provisional Tier-1 detection,
unconditional bounded peer teardown, structured parsing, four-layer
adjudication, and primary/secondary reporting follow. One canonical serializer
creates the ordered adjudication lines used by both stdout and
`<trial-root>/runner-adjudication.txt`. Future execution emits and persists:

```text
DG_B_CLASSIFICATION_PRIMARY=<token>
[DG_B_CLASSIFICATION_SECONDARY=<token>]
DG_B_STIMULUS_ESTABLISHED=1|0|UNKNOWN
DG_B_TRIAL_RESULT=PASS|FAIL|BLOCKED
[DG_B_TRIAL_BLOCK_REASON=<token>]
[DG_B_DEVICE_PRETRIAL_REASON=<exact reason>]
```

Bracketed fields are present only when applicable. Secondary follows Primary;
StimulusEstablished and TrialResult follow any Secondary; TrialBlockReason
follows a BLOCKED result; DevicePretrialReason is last. Stdout and the file use
the exact same line array and cannot be formatted independently.

`runner-adjudication.txt` is UTF-8 without BOM, uses LF line separators, and
has exactly one final LF after the last adjudication line. It contains no
timestamp or random metadata. Once a physical trial root exists, structured
PASS, FAIL, and BLOCKED adjudications are persisted before physical-function
success or the non-PASS exception. If an outer catch synthesizes a fallback
adjudication after trial-root creation, it persists that fallback before the
exception escapes. Implementation-authority failure before trial-root creation
emits stdout only and does not invent a trial root.

`runner-adjudication.txt` and `runner-terminal-error.txt` have distinct roles.
The former preserves structured causal/technical adjudication; the latter,
when applicable, preserves terminal exception/control-flow detail. Neither
replaces the other.

Evidence authority remains, from highest to lowest:

1. raw device serial;
2. raw peer CSV, stdout, and stderr;
3. exact artifact and upload evidence;
4. structured runner adjudication;
5. review and freeze documents.

External review may independently reconstruct or override structured runner
adjudication from higher-authority raw evidence. Raw USB/HID failure remains
primary over teardown or reporting failures.

There is no automatic retry and no S1-to-T1 progression.

## 14. Staging

- DG-B-S1: 10 seconds, exact C1-S1 application.
- DG-B-T1: 60 seconds, exact C1-T1 application.
- Stage/artifact mismatch is blocked.
- Early physical failure preserves partial device TX, peer RX, ingress
  attempts/results, sequence, timing, socket errors, raw serial, CSV, stdout,
  and stderr. Nominal counts are not required.

A normal physical trial root is the self-contained evidence source for a later
freeze, together with immutable external authority references. It preserves:

```text
artifact-staging/
artifact-authority-pre-upload.csv
artifact-authority-post-upload.csv
toolchain-identity.txt
upload-plan.txt
upload.stdout.log
upload.stderr.log
serial.log
serial-capture-metadata.txt
peer.csv
peer.stdout.log
peer.stderr.log
runner-adjudication.txt
```

Where applicable it also preserves `runner-terminal-error.txt`,
`serial-capture-error.txt`, serial/peer readiness and arm control evidence, and
other already-defined control-plane evidence. A later freeze must not depend on
an uncaptured parent-console transcript for final runner adjudication.

## 15. Implementation authority lifecycle

Candidate review generation creates a reviewed-source manifest that locks only:

- `tools/usb_lan_gate_dg_b_peer.py`
- `tools/usb_lan_gate_dg_b_runner.ps1`
- `docs/usb-lan-gate-dg-b-contract.md`

The manifest does not list itself. Its sibling SHA is a proposed expected hash,
not accepted authority. A future physical runner takes both manifest path and
expected SHA as external inputs and never self-derives the expected value.

## 16. Prohibitions for this implementation session

No peer functional edit, firmware edit, build, compile, upload, flash, COM access, real peer bind,
network traffic, NIC/firewall change, C1/C2/DG-A rerun, DG-B-S1/T1, Gate C3,
commit, push, or PR is authorized.
