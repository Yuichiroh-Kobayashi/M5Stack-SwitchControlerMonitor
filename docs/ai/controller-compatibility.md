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
- The current product LAN Sender does not yet parse the HORI report layout. It still selects only DualSense `054C/0CE6` and assumes DualSense report IDs and offsets.
- Connecting HORI to the current product Sender leaves `inputValid` false and CONTROL neutral.
- `M5Stack-SwitchController2CoREWirelessSender.ino` is the validated parser reference; its legacy transport is not the product LAN protocol.

Required next steps:

1. Port the HORI profile into the product Sender.
2. Select it by VID/PID `0F0D/0202`.
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
