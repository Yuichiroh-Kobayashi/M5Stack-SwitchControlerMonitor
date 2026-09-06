# Controller and USB topology compatibility

## Status definitions

- **Product-supported**: implemented in the product Sender and passed USB mapping, LAN integration, fault, and durability gates.
- **USB-validated development baseline**: stable in USB-only legacy or diagnostic firmware, but not necessarily implemented in the product Sender.
- **Pending**: physical characterization not complete.
- **Suspended**: known unstable on the current hardware/software stack.
- **Rejected topology**: unsuitable as a dependency for the current stack.

## Product-supported

None.

## USB-validated development baseline

### HORI PAD TURBO

- VID/PID: `0F0D/0202`.
- Required hardware mode: `Switch 2`.
- CoreS3 SE + USB Module + Bottom3, LAN removed:
  - WirelessSender screening: 60 seconds x 3, pass.
  - WirelessSender long run: 600 seconds, pass.
  - HIDUniversal isolation diagnostic: 600 seconds, pass.
- Total validated USB-only runtime exceeded 22 minutes with no detach.
- The product LAN Sender now selects the HORI candidate in `src/controller_profile/ControllerProfile.h`; suspended DualSense remains unsupported.
- The candidate accepts exactly 8 bytes without a report-ID prefix; captured hat `0x0F` maps to protocol center `8`. Invalid reports clear the input session immediately. Product USB-only mapping and all integration gates remain unvalidated.
- `M5Stack-SwitchController2CoREWirelessSender.ino` is the validated parser reference; its legacy transport is not the product LAN protocol.
- 2026-09-06 product USB-only screening passed a complete64-second window; passive intake then passed67 seconds after descriptor acquisition on the operator-reported CoreS3 SE + USB Module + LAN Module + BAT Bottom stack, with W5500 held in reset. Both observed200 HID reports/s without reported drop/stall/rejection. These are separate trials, not additional legacy-runtime or integrated-durability evidence.
- [Passive intake evidence](../validation/product-usb-intake-20260906.md) records interface0 HID,116-byte report descriptor SHA-256 `99B0E143128C21E3066F1DE6A124DCC314B0D6578DAFBA1DFF292972ACBE1F0D`, no report-ID item, and64-bit input report. Observed raw neutral is `00 00 0F 80 80 80 80 00`.
- The descriptor additionally declares Button15 at byte2 bit7. Its physical control/function is unknown and remains unmapped. Do not assign it to turbo, macro, or another product function without physical evidence. Operator could not manipulate the controller, so button/direction mapping, ranges, trigger operation, turbo/macro state, screen readability, reconnect and LAN gates remain pending.

Required next steps:

1. Review the implemented HORI profile and its host vectors (Issue #8).
2. Verify VID/PID `0F0D/0202` selection on the actual product candidate.
3. Validate report ID and report length before parsing.
4. Confirm neutral values and every required mapping in USB-only operation.
5. Begin LAN integration only after the product profile passes.

## Suspended

### Sony DualSense

- VID/PID: `054C/0CE6`.
- Multiple controller units reproduced `USB_STATE_RUNNING (0x90) -> DETACHED_WAIT_FOR_DEVICE (0x12)`.
- Reproduced with LAN absent, LCD absent, and isolated USB diagnostics.
- Reproduced with generic HID handling.
- Reproduced with PS5USB NO_OUTPUT.
- Reproduced with PS5USB default initial output behavior.
- MAX3421E revision triple reads remained stable.
- No unintended ESP reset, panic, or WDT was observed.

Engineering decision:

- Do not advertise or depend on DualSense support on the current CoreS3 SE + MAX3421E + USB Host Shield Library 1.7.0 stack.
- Keep any future DualSense investigation separate from the HORI product baseline.

## Pending

### OULEKE PS4-compatible wired controller

- Procurement identifier: Amazon ASIN `B0FL6VS3JF`.
- Physical unit not yet characterized.

Required first-pass evidence:

1. Windows PnP inventory and VID/PID.
2. Composite/interface inventory.
3. HID report descriptor and stable hash.
4. Report ID, report length, report frequency.
5. Buttons, D-pad, sticks, triggers, neutral values, and axis direction.
6. Macro, turbo, and rear-button behavior.
7. USB-only 60-second screening x 3.
8. USB-only 600-second run.
9. Disconnect, neutralization, and reconnect behavior.
10. Multi-unit consistency before product approval.

Do not identify this controller by retail name alone in firmware. Use a validated profile signature.

## Rejected topology

### UGREEN powered USB hub

- Procurement identifier: Amazon ASIN `B09DCK46PM`.
- Windows successfully enumerated DualSense through the hub.
- CoreS3/MAX3421E/UHS failed to enumerate the HORI control device behind the same hub.
- USB state reached RUNNING, then a subsequent `Usb.Task()` stopped returning.
- The topology cannot be used to compare direct and externally powered DualSense behavior.

Do not add this hub as a product workaround.
