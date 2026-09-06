# CoRE Controller Sender Agent Guide

## Purpose and precedence

This file is the canonical repository instruction for AI coding tools.

- Follow this file before tool-specific adapters such as `CLAUDE.md`, `GEMINI.md`, and `.github/copilot-instructions.md`.
- Tool-specific files may add workflow details, but must not redefine the hardware baseline, wire protocol, safety rules, or controller support policy.
- Keep normative rules here. Put detailed evidence, test history, and compatibility records under `docs/ai/`.
- Human review and real-hardware validation are authoritative. A successful build is not proof of hardware correctness.

## Project purpose

This repository develops M5Stack-based controller sender and receiver firmware for CoRE robot operation.

The current product direction is:

- Sender: M5 CoreS3 SE + M5Stack USB Module v1.2 + M5Stack LAN Module 13.2 + Base M5GO Bottom3.
- Receiver: M5 CoreS3 SE + M5Stack LAN Module 13.2 + Base M5GO Bottom3.
- USB validation baseline: HORI PAD TURBO, VID/PID `0F0D/0202`, controller switch set to `Switch 2`.
- Current product LAN Sender profile: HORI Switch 2 candidate is implemented; USB-only product mapping and integration remain unvalidated.
- Product-supported controller: none yet.
- Required product validation: verify the migrated HORI profile in USB-only operation before product LAN integration testing. Current diagnostic work is tracked in `docs/ai/investigation-status.md`; do not substitute a historical handoff's next gate.
- Network: wired Ethernet through a switching hub.
- Product transport: UDP with a fixed binary protocol.
- Receiver output: UART Port C using the same fixed binary frame.

Do not confuse this repository with QUESTiX ROS 2 firmware. CoRE and QUESTiX are separate systems.

QUESTiX is an intended UART downstream (Raspberry Pi 5 / Ubuntu 24.04 / ROS 2 Jazzy), alongside the Scramble junior robot kit. For compatibility design, treat QUESTiX `parseControllerLine()`, its constants/tests, `readLine()`, and `serial_port.cpp` as the receiver contract. See `docs/uart-downstream-common-protocol-design.md` for pinned sources. The proposed common ASCII UART adapter is not yet adopted; the current binary LAN/UART contract below remains in force.

## Canonical files

Product firmware:

- `M5Stack-PS5CoRELANSender.ino`: current LAN sender implementation. It selects the HORI profile by VID/PID; unsupported controllers, including suspended DualSense, remain neutral.
- `M5Stack-PS5CoRELANReceiver.ino`: current LAN receiver implementation.
- `src/core_protocol/CoreProtocol.h`
- `src/core_protocol/CoreProtocol.cpp`

Legacy/reference firmware:

- `M5Stack-SwitchController2CoREWirelessSender.ino`: legacy wireless/UART sender containing the validated HORI parsing behavior used as the migration reference. Its old transport format is not the current LAN protocol.

Diagnostics:

- `M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino`
- `M5Stack-PS5CoREPs5UsbDiagnostic.ino`
- `tools/usb_lan_isolation_test.ps1`
- `tools/dual_serial_capture.ps1`

Reference documentation:

- `docs/ai/hardware-baseline.md`
- `docs/ai/protocol-and-safety.md`
- `docs/ai/controller-compatibility.md`
- `docs/ai/validation-gates.md`
- `docs/cores3se-usb-lan-root-cause-report.md`
- `docs/ai/investigation-status.md`: current diagnostic status, next work, and sharing scope.
- `docs/usb-lan-next-non-null-read-design.md`: proposed diagnostic treatment, not a physical PASS.
- `docs/uart-downstream-common-protocol-design.md`: downstream compatibility design, not a protocol revision.

Before changing a behavior, locate its current source of truth and update the code, tests, and documentation consistently.

## Environment baseline

Use the existing repository scripts and pinned versions unless the user explicitly approves an upgrade.

Current validated CoreS3 SE baseline:

- Arduino CLI: repository-supported PowerShell workflow.
- M5Stack ESP32 core: `3.3.7`.
- M5Unified: `0.2.19`.
- M5GFX: `0.2.26`.
- M5-Ethernet: `4.0.0`.
- USB Host Shield Library 2.0: `1.7.0` with the isolated CoreS3 patch recorded by the diagnostic tooling.

Rules:

- Do not silently upgrade libraries, board cores, or the compiler toolchain.
- Do not replace M5-Ethernet `4.0.0` with `4.0.1` without an explicit compatibility task.
- Do not modify global Arduino libraries during diagnostic work. Prefer the isolated library tree under `build-temp/`.
- Record the exact library paths and hashes used for diagnostic or release evidence.
- Preserve PowerShell compatibility on Windows.

## Hardware baseline and pin ownership

CoreS3 SE shared SPI bus:

- SCK: GPIO36
- MOSI: GPIO37
- MISO: GPIO35

USB Module v1.2:

- MAX3421E CS: GPIO1
- MAX3421E INT: GPIO14
- USB Module DIP switches must select the CoreS3 CH2 mapping for both SS and INT.

LAN Module 13.2:

- W5500 CS: GPIO13
- W5500 INT: GPIO10
- W5500 RESET: GPIO0

Receiver UART, Port C:

- TX: GPIO17
- RX: GPIO18
- `115200 8N1`

Shared-SPI rules:

- Keep the inactive device chip-select high before accessing the other device.
- Do not add ad-hoc `SPI.beginTransaction()` calls around library internals without a focused diagnostic task.
- Do not reinitialize the shared SPI bus casually. Initialization order has affected USB enumeration.
- Treat LCD, MAX3421E, W5500, and microSD-related SPI ownership as hardware-sensitive.
- Power off the stack before changing modules or DIP switches.

Current product Sender initialization order:

1. Initialize LAN/W5500.
2. Initialize USB Host/MAX3421E.

USB-first diagnostics did not reach USB RUNNING, while LAN-first diagnostics did reach RUNNING. LAN-first did not make DualSense stable; it detached later. Do not confuse successful initialization with controller stability, and do not change this order during HORI product integration without explicit evidence.

## Fixed LAN and UART protocol

The current protocol is frozen unless the user explicitly authorizes a protocol revision.

- Fixed frame size: 32 bytes.
- Magic: bytes 0-1 are ASCII `C`, `R`.
- Protocol version: 1.
- Message types: CONTROL and STATUS.
- Sequence number: big-endian.
- Uptime: big-endian.
- Payload: 20 bytes.
- CRC: CRC-16/CCITT-FALSE in bytes 30-31.
- Sender CONTROL cadence: 10 ms nominal, 100 Hz (user-confirmed development target 2026-09-06; physical qualification pending).
- Receiver STATUS cadence: 10 ms nominal, 100 Hz; 20 ms is retained only as an explicit comparison build option.
- Input/peer timeout: 100 ms.
- Encode and decode fields byte-by-byte.
- Do not use packed structs, compiler-dependent layout, native-endian casts, or implicit padding.
- Do not change UDP port `50001` without explicit approval.
- UART transmits the same 32-byte frame with no ASCII conversion and no CR/LF terminator.
- Adopted 2026-09-06: Receiver owns the UART CONTROL sequence and uptime, independently of LAN CONTROL and STATUS. UART runs every 10 ms, with invalid neutral at startup, invalid input and source timeout. This is the same binary layout, not byte-identical LAN forwarding. See `docs/uart-mega-contract.md` for rearm and backpressure semantics.

Any protocol change must update both endpoints, the reference implementation, documentation, and compatibility tests in the same change.

## Safety invariants

These rules are mandatory.

- Invalid, stale, unsupported, or disconnected controller input must produce a neutral CONTROL state.
- Controller loss must not leave a stale button, stick, trigger, or D-pad value active.
- Peer timeout must be visible in diagnostics and UI.
- Do not hide a root cause with automatic `Usb.Init()`, MAX3421E reset, `ESP.restart()`, watchdog reset, or periodic reboot unless the user explicitly requests a recovery design after root-cause work is complete.
- Do not weaken timeout, CRC, sequence, or controller-validity checks merely to make a test pass.
- Unsupported controller profiles must be reported as unsupported and kept neutral.
- Do not send experimental output reports, rumble, LED, adaptive-trigger, macro, or turbo commands unless the test specifically requires them.

## Controller support policy

Product-supported:

- None.
- A controller becomes product-supported only after its product Sender profile, USB mapping, LAN integration, fault handling, and durability gates pass.

USB-validated development baseline:

- HORI PAD TURBO `0F0D/0202` in `Switch 2` hardware mode.
- The legacy parser is validated by USB-only tests.
- The product LAN Sender profile is implemented as a candidate. Only valid 8-byte HORI input becomes active; product USB-only mapping, LAN/fault/durability gates remain required.

Suspended on the current stack:

- Sony DualSense `054C/0CE6`.
- DualSense A and B repeatedly reached USB RUNNING and then transitioned to detached state on the current CoreS3 SE + MAX3421E + USB Host Shield Library stack.
- Failures reproduced with generic HID handling and PS5USB, with and without the default initial LED output report.
- Do not claim DualSense support or add automatic recovery as a substitute for stability.

Pending candidate:

- OULEKE PS4-compatible wired controller, Amazon ASIN `B0FL6VS3JF`.
- Do not add a product mapping before the physical device is inspected.
- First record VID/PID, USB interfaces, HID report descriptor, report length, report ID, neutral values, axes, buttons, trigger behavior, macro/turbo state, and reconnect behavior.
- Require multi-unit validation before treating a retail product name as a stable hardware specification.

Rejected topology:

- UGREEN powered hub, ASIN `B09DCK46PM`, is not a valid power-isolation solution for this project.
- Windows enumerated DualSense through it, but CoreS3/MAX3421E/UHS could not enumerate even the HORI control device and `Usb.Task()` stopped returning.
- Do not use that hub result to infer DualSense power behavior.

## Required HORI implementation order

1. Inspect the HORI report parser in `M5Stack-SwitchController2CoREWirelessSender.ino`.
2. Add a controller-profile abstraction to the product Sender.
3. Select the HORI profile for VID/PID `0F0D/0202`.
4. Keep unsupported profiles neutral.
5. Validate HORI mapping in USB-only operation.
6. Only then begin LAN integration testing.
7. Validate controller and LAN fault/recovery behavior.
8. Complete the durability gate.

## Work boundaries

Before editing:

1. Run and record:
   - `git status -sb`
   - `git diff --stat`
   - `git diff --check`
   - `git rev-parse HEAD`
2. Inspect existing local modifications and preserve them.
3. Identify whether the task is product implementation, diagnostics, documentation, or hardware validation.
4. State which physical operations require the user.

Without explicit authorization, do not:

- Commit, push, pull, merge, rebase, stash, reset, clean, switch branches, or create PRs/issues.
- Discard or rewrite unrelated local changes.
- Upload firmware to an unverified COM port.
- Change the stack, DIP switches, controller, LAN cable, powered hub, or power wiring.
- Run a destructive filesystem or global package-management command.

Prefer small, reviewable changes. Keep diagnostics isolated from product firmware.

## Build and upload discipline

- Build Receiver and Sender separately.
- Use clean build directories when validating protocol or library changes.
- Verify the expected COM port and exact PnP instance before every upload.
- Upload Receiver first, then Sender, unless a diagnostic procedure explicitly says otherwise.
- Save binary hashes and serial-log hashes for root-cause and release evidence.
- A BuildOnly pass is not an integration pass.
- A USB state of RUNNING is not sufficient by itself; the target controller must be ready and reports must increase.

## Validation ladder

Use the staged gates in `docs/ai/validation-gates.md`.

Minimum progression:

1. Static checks and clean builds.
2. Implement and USB-only validate the product controller profile.
3. Verify upload identity.
4. Run 60-second protocol and HID screening.
5. Confirm manual input mapping and UI behavior.
6. Run a 10-minute integrated test.
7. Test controller and LAN disconnect/reconnect behavior.
8. Run the 60-minute durability test.

Do not skip a failed gate by increasing the test duration or adding recovery logic.

## Reporting requirements

Every implementation or diagnostic report must distinguish:

- Proven facts.
- Inferences.
- Unmeasured electrical hypotheses.
- Invalid or incomplete comparisons.
- Physical operations not performed.

Include:

- Current branch and HEAD.
- Changed files.
- Build commands and versions.
- Hardware configuration.
- Controller VID/PID and profile.
- Duration and acceptance criteria.
- Counters for HID, CONTROL, STATUS, CRC, sequence gaps, timeouts, link state, and resets.
- `git diff --check` result.
- Final `git status -sb`.
- Confirmation that no commit/push/PR was performed when that restriction applies.

Never describe an unenumerated downstream USB device as a passing powered-hub test.

## Documentation maintenance

- Keep the root `README.md` focused on human setup and supported behavior.
- Keep canonical AI instructions in this file.
- Keep tool adapters short and non-conflicting.
- Update `docs/ai/controller-compatibility.md` when a controller or USB topology is accepted, suspended, or rejected.
- Update `docs/ai/hardware-baseline.md` when pins, modules, power topology, or validated library versions change.
- Update `docs/ai/protocol-and-safety.md` only with an explicitly approved protocol or safety change.
- Preserve exact identifiers such as VID/PID, GPIO, port, frame size, timeout, and hashes.
