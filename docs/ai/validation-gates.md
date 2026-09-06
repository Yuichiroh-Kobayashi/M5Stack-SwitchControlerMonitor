# Validation gates

## Gate 0: repository safety

Record before work:

```powershell
git status -sb
git diff --stat
git diff --check
git rev-parse HEAD
```

Preserve unrelated modifications. Do not perform Git writes unless explicitly authorized.

## Gate 1: static and build validation

- Verify exact board core and library paths.
- Run PowerShell parser checks for changed scripts.
- Run `git diff --check`.
- Clean-build Receiver.
- Clean-build Sender.
- Record binary sizes and hashes.
- Confirm `CoreProtocol` is included in both builds.

A build pass does not authorize upload.

## Gate 2: product controller profile

- Product Sender detects VID/PID `0F0D/0202`.
- The HORI profile is selected.
- Report ID and report length are validated before parsing.
- Neutral values are correct.
- Unsupported VID/PID remains neutral.
- No DualSense offsets are reused without evidence.
- USB-only manual mapping passes.

Until this gate passes, HORI is a USB-validated development baseline, not a product-supported controller. Do not begin product LAN integration.

## Gate 3: upload identity

Before every upload:

- Verify COM port.
- Verify exact PnP instance ID.
- Stop on mismatch.
- Upload Receiver first, then Sender, unless running a sender-only diagnostic.

## Gate 4: 60-second screening

Expected product conditions:

- The implemented product controller profile's VID/PID is detected.
- HID reports continue.
- USB target remains ready.
- CONTROL: 95-105 Hz for the 100Hz development candidate; also record deadline lateness and skipped periods.
- STATUS: 95-105 Hz for the 100Hz development candidate. Keep the earlier 45-55Hz criteria only in historical 20ms evidence.
- CRC failures: 0.
- Unexpected sequence gaps: 0.
- CONTROL timeout: 0.
- STATUS timeout: 0.
- Link remains ON.
- Unintended reset/panic/WDT: 0.

Stop on a failed gate. Do not compensate with automatic reset.

## Gate 5: manual mapping

User verifies:

- D-pad neutral and eight directions.
- Left and right stick center, range, and direction.
- All required buttons.
- Triggers.
- Sender UI.
- Receiver UI or decoded values.
- Neutral state after release.

Record unsupported or duplicated buttons explicitly.

## Gate 6: 10-minute integrated run

- Continuous HID updates.
- Continuous CONTROL and STATUS traffic.
- UI remains responsive.
- Battery display updates.
- UART software path continues.
- No USB drop, link drop, timeout, CRC failure, sequence gap, or reset.

## Gate 7: fault and recovery

Controller disconnect:

1. Disconnect the controller.
2. Confirm neutralization within 100 ms.
3. Confirm stale active input is not retained.
4. Reconnect.
5. Confirm recovery without ESP reset.

LAN disconnect:

1. Disconnect Ethernet while operating the controller.
2. Confirm controller USB/UI remains active.
3. Confirm peer timeout is reported.
4. Reconnect Ethernet.
5. Confirm bidirectional traffic recovers without ESP reset.

## Gate 8: 60-minute durability

Acceptance:

- HID drop: 0.
- Link drop: 0.
- Unintended reset: 0.
- CRC failure: 0.
- Unexpected sequence gap: 0.
- Unexpected timeout: 0.
- UI and UART path remain active.

Save final sender and receiver logs and their hashes.
