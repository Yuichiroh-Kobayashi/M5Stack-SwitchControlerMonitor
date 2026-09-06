# DG-D offline fixtures

Run `run_offline_tests.ps1` in Windows PowerShell. The suite uses only source
text, fake summaries/logs, the accepted peer's fake-socket self-test, and
temporary in-memory fixtures. It does not open COM/serial, bind a UDP socket,
send network traffic, capture packets, upload firmware, or access physical
hardware.

The runner's embedded suite covers device evidence parsing, positive-size and
null-discard failures, drain outcomes, peer/sequence reconciliation,
non-nominal actual totals, adjudication, and the canonical UTF-8 serializer.
This wrapper adds authority-resolution, Mode18 collision, PRE/POST inventory,
exact peer identity, build-only source inspection, and firmware static checks.

The runner also tests firmware-realistic detach logs: terminal VID/PID are zero,
with a unique target-ready record before DIAGNOSTIC_START. Missing, late,
duplicate, unsupported, unstable, mixed-identity, and zero-on-PASS cases remain
blocked. A valid ACTIVE failure prefix retains FAIL only when peer stimulus is
established and B37 control-plane conditions permit it. Accepted frozen S1/T1
logs are unchanged; see `docs/post-dg-d-runner-repair-validation.md`.
