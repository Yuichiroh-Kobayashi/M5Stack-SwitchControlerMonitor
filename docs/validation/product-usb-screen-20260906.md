# Product HORI USB-only physical screening — 2026-09-06

Result: **USB screening passes; manual mapping/UI gate remains pending.** This is a new product candidate trial, not a rerun of C1/C2/DG-A/B/C/D. Product controller support remains unqualified.

## Authority and configuration

- The operator stated the attached `CoRE USB-LAN Physical Test Environment.md` described the current physical connection and explicitly authorized firmware upload and physical validation.
- Reported stack: CoreS3 SE + USB Module v1.2 + LAN Module 13.2 + BAT Bottom; HORI PAD TURBO only, Switch 2; physical Receiver absent. Cable identities, exact stacking order and detailed power paths remain unknown. Software identity does not establish physical equality with historical tests.
- COM4 exact PnP identity matched the existing repository's expected device immediately before upload and again afterward. Exact identity is saved in the local evidence package.
- Windows test NIC: 192.168.50.30/24, direct 192.168.50.0/24 route with NextHop 0.0.0.0, no default route on that NIC. UDP 50001 was unoccupied and checked serial/capture tools were absent. Other NICs were not changed.
- Firmware: build package `20260906-100256-c5590789`, case `sender-usb-only`, `SENDER_USB_ONLY=1`, `PRODUCT_TRANSPORT_PERIOD_MS=10`, `PRODUCT_NUMERIC_UI=1`. Firmware source is unchanged from the build snapshot recorded in [candidate validation](product-candidate-20260906.md).
- Branch: `feat/cores3se-dualsense-lan-stack-diagnostic`; source HEAD: `c1492aa27d59ddf7486859553f2cbe76ab76a619`.
- Pinned versions: Arduino CLI 1.5.1; M5Stack ESP32 core 3.3.7; M5Unified 0.2.19; M5GFX 0.2.26; M5-Ethernet 4.0.0; UHS 1.7.0 with isolated CoreS3 patch. Library/source paths and hashes remain in the original build package. W5500 library settings are 8/8MHz, UHS setting 26MHz; actual electrical clocks are not measured. W5500 is held in reset for this USB-only trial.

Existing clean build command (not repeated for this upload):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/product_build.ps1 -ConfigFile build-temp/product-toolchain-20260906/arduino-cli.json -LibraryRoot build-temp/product-libraries-8-8-usb26-20260906/libraries -PeriodMs 10 -NumericUi 1
```

Physical command, from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File build-temp/product-physical-20260906-usb01/run.ps1 -Upload -DurationSeconds 65
python build-temp/product-physical-20260906-usb01/analyze.py
```

The runner verifies identity and the application binary hash, then calls the workspace-configured Arduino CLI upload with FQBN `m5stack:esp32:m5stack_cores3`, COM4 and the existing USB-only build input directory. Upload verified flash data and performed its normal RTS reset. No automatic recovery/reset was added. Serial capture uses 115200 8N1, DTR/RTS disabled. Initial CLI discovery was slow but completed without intervention.

## Observations and acceptance

Capture duration was 65.0152742 seconds. The first startup record was truncated and is retained in raw evidence, excluded explicitly from adjudication. There are 65 complete status records covering uptime 3,000–67,000ms, a 64-second interval.

USB-screen criteria: at least 60 seconds of complete records, correct controller/profile, ready and valid input throughout, report counter advances continuously, no reported drop/stall/rejection, no observed runtime reset, and no LAN traffic in USB-only mode. All checks passed.

| Measurement | Observed result |
|---|---:|
| Controller | 0F0D/0202, HORI_SWITCH2 |
| HID reports across complete interval | 387 → 13,187; delta 12,800 |
| HID rate | 200.0Hz |
| HID ready drops / stalls / rejected reports | 0 / 0 / 0 |
| Maximum HID report age at status sampling | 5ms |
| Maximum Usb.Task duration | 447µs |
| Maximum USB service gap | 3,204µs |
| Maximum loop duration | 3,447µs |
| Maximum LCD field draw duration | 507µs |
| CONTROL TX / STATUS RX | 0 / 0, disabled by USB-only build |
| STATUS CRC failure / sequence-gap counters | 0 / 0; no network traffic, not a protocol pass |
| Peer timeout / link | 1 / UNKNOWN, expected in USB-only mode |
| Unexpected runtime resets observed | 0 |

`RESET=USB` is the recorded boot reason following the authorized upload, not a cumulative reset counter. Monotonic uptime and continuously advancing reports support the screening result. The incomplete startup record prevents claiming complete boot-log coverage.

The observed 507µs LCD maximum is slightly above the preliminary 500µs sizing target; it is not evidence that all fields refresh at 25Hz or meet maximum display age under active input. Manual readability and mapping results are pending. LAN timing/lateness and receiver UART behavior have not been physically measured.

## Evidence

Local trial root: `build-temp/product-physical-20260906-usb01`. It contains attachment copy, runner, preflight, exact COM/PnP records, upload log, raw/timestamped serial, artifact hashes, analyzer and adjudication JSON. Local ZIP preserves the full trial; public upload of this raw package has not been performed.

| Artifact | SHA-256 |
|---|---|
| Application binary | `DB56CF9A35651A5F539147D0AD1ADB361DB5B158C8A57FF20930B8AFE1144012` |
| Upload log | `3222055616A5C6D5BE1C1F4D8AFFEE54602F0D2E09751B35DC697B8CB12E8FE8` |
| Raw serial | `D232B5DBE505B9E0A60CB782AFDFA9F5BF8692BE4552F462F332B6C90EF87119` |
| Timestamped serial | `6F9EBE0F02500A1FC1C9EB03996621AD2F18A620F2BBC6E4FAF829CDD2BE4BCE` |
| Adjudication JSON | `10A8DA8F875416889983EC31AA6EA0ECA99CA3F5BE52EDFCAF57BC0A6C75AF3D` |
| Trial ZIP | `2DA794BAC72DAD9C592127818232DFBFF988B5BD1F90585AFCA2641485612D3C` |

## Remaining gates and boundaries

Manual actions requested of the operator: verify all D-pad positions, both sticks including direction/center/range, individual buttons, digital trigger values, return to neutral, and screen readability/update behavior. No module, DIP, controller, cable or power changes have been performed by the agent.

LAN integration has not begun. The current product binary uses peer .20 and default PHY handling; a separately identified test build must use peer .30 and the attached Fixed10Half condition before a Windows-peer trial. PC topology must remain unchanged. A Windows-peer trial cannot validate physical Receiver/UART behavior. No 10-minute run, fault/reconnect test or durability run has been performed.

Electrical causes and comparative stability improvements remain unmeasured. This USB-only result does not prove that reduced W5500 SPI clock improves integrated stability.

Repository checks before the trial: tracked changes absent, `git diff --stat` empty, `git diff --check` exit 0. Existing untracked `docs/Datasheet/`, `docs/Schematic/`, and `docs/handoffs/usb-lan-antigravity/` were preserved. Changed tracked-source candidates for this trial: this new report only; the runner and logs are in ignored `build-temp/`. Report-finalization `git diff --check` passes. No commit, push, PR, merge or release was performed during this USB trial.
