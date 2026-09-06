# Passive product HORI USB intake — 2026-09-06

**Result: passive intake passes; physical mapping remains pending.** The operator authorized continued validation but could not manipulate the controller. This trial therefore verifies descriptor/report structure and observed neutral input. It does not qualify physical mappings or product support.

## Configuration and implementation

The current physical authority is the operator's `CoRE USB-LAN Physical Test Environment.md`: CoreS3 SE + USB Module v1.2 + LAN Module 13.2 + BAT Bottom; HORI PAD TURBO `0F0D/0202`, Switch2; no physical Receiver. Exact cable identities, stacking order and detailed power paths remain unknown. No hardware, DIP, cable, power or PC-network changes were performed by the agent. The operator approved the displayed Windows administrator dialog; that is not a physical controller operation.

Immediately before upload, COM4 matched the exact repository PnP identity. It matched again after upload. The trial NIC was192.168.50.30/24 with direct192.168.50.0/24 route, NextHop0.0.0.0 and no default gateway on that NIC. UDP50001 and checked competing serial/capture processes were absent. Exact identities and private paths are retained locally.

Branch: `feat/cores3se-dualsense-lan-stack-diagnostic`. Firmware source commit: `18f8870ca54a512ba53ba5ef463cbae13b1f6d38`. The preceding [uninstrumented USB screen](product-usb-screen-20260906.md) used a different binary and remains separate evidence.

Added `SENDER_USB_INTAKE=1` is restricted at compile time to `SENDER_USB_ONLY=1`. It records callback length/ID flag, raw report snapshots, effective decoded values, and cumulative mapped button/hat/axis observations. Once valid input is available after uptime5s, it attempts standard GET_DESCRIPTOR reads for configuration0 and its single advertised HID report descriptor. Bounds, contiguous chunks and lengths are checked. There are no new output reports, retries or recovery resets. The normal product build excludes this instrumentation. W5500 remains held in reset throughout the intake.

Changed implementation/test files in commit18f8870: `M5Stack-PS5CoRELANSender.ino`, `src/controller_profile/UsbIntake.h`, `tools/product_build.ps1`, `tests/product/run_host_tests.py`, `tests/product/stubs/usbhid.h`, `tests/product/usb_intake_test.cpp`; accompanying README and prior screen report were also published. No Receiver, wire-format or controller mapping changes were made. This follow-up adds intake evidence and updates compatibility/testing documentation.

## Build and verification

Pinned environment: Arduino CLI1.5.1, M5Stack ESP32 core3.3.7, M5Unified0.2.19, M5GFX0.2.26, M5-Ethernet4.0.0 and UHS1.7.0 with the isolated CoreS3 patch. Library settings: W5500 normal/TX8/8MHz, USB26MHz; actual electrical clocks are unmeasured. Exact selected library paths and full file hashes are retained in `library-hashes.csv` and the verbose build log.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools/product_build.ps1 -ConfigFile build-temp/product-toolchain-20260906/arduino-cli.json -LibraryRoot build-temp/product-libraries-8-8-usb26-20260906/libraries -PeriodMs 10 -NumericUi 1 -Cases sender-usb-only -UsbIntake 1 -OutputRoot build-temp/product-builds/20260906-usb-intake-01
powershell -NoProfile -ExecutionPolicy Bypass -File build-temp/product-physical-20260906-intake01/run.ps1 -Upload -DurationSeconds 75 -LogName intake
python build-temp/product-physical-20260906-intake01/analyze.py
```

The clean diagnostic target build passed: application binary573,568 bytes, reported flash use573,423 bytes and static RAM27,080 bytes. Upload used the workspace-isolated CLI config, verified COM4/FQBN `m5stack:esp32:m5stack_cores3`, and that exact binary. Flash data verification passed, followed by the normal upload RTS reset. Serial capture was1152008N1, DTR/RTS disabled. No global libraries or packages were modified.

The exact target compiler additionally accepted the generated Sender translation unit with intake disabled in product and ordinary USB-only modes. It rejected intake on LAN and invalid intake value2 through the intended static assertion. These are syntax/guard checks, not additional clean linked builds. The build script also rejected `-Cases sender -UsbIntake 1` before any build. Initial shell-wrapper mistakes in that negative check were corrected; only the final script-based result is passing evidence.

[CI run34009263887](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/actions/runs/34009263887) passed on source18f8870: controller438, runtime45, numeric display82 and USB intake68 C++ checks,633 total; protocol reference self-test and7 Python cases passed. The USB test double verifies bounded/contiguous capture, truncation, advertised lengths including >128 bytes, one-attempt behavior, standard request parameters and mapped-input aggregation. It does not simulate electrical USB behavior. Native host C++ was executed in CI because a host compiler was not available locally.

## Descriptor and input observations

Both descriptor reads returned00. Configuration descriptor:41 bytes, one HID interface0 (class3/subclass0/protocol0), interrupt endpoints OUT0x02 and IN0x81, each maximum packet64 bytes and interval5. HID descriptor advertised116 bytes; all116 report-descriptor bytes were captured contiguously.

The descriptor has no Report ID item and defines64-bit Input, Output and Feature reports. Only Input was observed; no Output or Feature report was sent. The interpretation follows [USB HID1.11 sections6.2.2 and8.1](https://www.usb.org/sites/default/files/hid1_11.pdf): field bit lengths are Report Size×Report Count; without Report ID tags there is no prefix byte.

| Input bit offset | Descriptor declaration | Product handling |
|---|---|---|
| 0–13 | Buttons1–14 | Existing14-button legacy mapping |
| 14–15 | Constant padding | Ignored |
| 16–19 | Hat, logical0–7, null-state flag | Observed0xF maps to protocol8 |
| 20–22 | Constant padding | Ignored |
| 23 | Button15 | **Unmapped; physical function unknown** |
| 24–55 | Four8-bit axes, usages0x30/31/32/35, logical0–255 | Existing LX/LY/RX/RY fields; physical directions not exercised |
| 56–63 | Constant padding | Ignored |

Button15 is byte2 bit7, not a reserved bit. No evidence identifies it as turbo, macro, or another physical control; no new mapping was added. Neutrality of the current mapped controls does not establish behavior of this unmapped bit.

Capture duration:75.0008754 seconds. The adjudicated post-descriptor interval contains68 complete records, uptime10,005–77,005ms, spanning67 seconds. Earlier acquisition/startup records are retained but excluded from timing adjudication. Every acceptance check in [the JSON record](product-usb-intake-20260906.json) passed.

| Measurement | Observed result |
|---|---:|
| HID counter across stable interval | 1,787→15,187; delta13,400 |
| HID rate | 200.0Hz |
| Cumulative accepted / rejected | 15,187 / 0 |
| Mapped non-neutral reports, cumulative | 0 |
| Raw sampled input | `00 00 0F 80 80 80 80 00` |
| Mapped button OR / hat set | 0000 / neutral8 only |
| Four axis minima and maxima | All128 |
| Sampled LT/RT | 0 / 0 |
| HID ready drops / stalls | 0 / 0 |
| Maximum sampled HID age | 1ms |
| Maximum Usb.Task / service gap / loop in stable interval | 581 / 4,161 / 4,420µs |
| Maximum LCD field time reported | 486µs |
| CONTROL TX / STATUS RX | 0 / 0, intentionally disabled |
| STATUS CRC / sequence-gap counters | 0 / 0, no network traffic |
| Peer timeout / link | 1 / UNKNOWN, expected for USB-only |
| Unexpected runtime resets observed | 0 |

`RESET=USB` identifies the boot after the authorized upload, not a reset counter. The one-time descriptor reads and extra serial logging alter timing; differences from the prior507µs LCD result cannot be attributed to an optimization. All-fields25Hz update age, readability and LAN send jitter remain unmeasured. No electrical root cause or integrated-stability improvement is established.

## Evidence and remaining work

Local trial root: `build-temp/product-physical-20260906-intake01`. It preserves the attachment, preflight/identity checks, runner, upload log, raw and timed serial, descriptor binaries, descriptor analysis, adjudication, build/source/library manifests and CI log. File hashes in the JSON were independently read back. The final archive is `build-temp/product-physical-20260906-intake01-verified.zip`; the earlier unsuffixed ZIP is superseded because its first manifest inadvertently included an in-progress stdout file. Raw physical logs did not change.

| Artifact | SHA-256 |
|---|---|
| Application binary | `BC2E442F4C07F81C520BD54566B2476668FBB054D06B4080897009501EC83BA2` |
| Build log | `A65EFF0B7EE58A2FE127E66BAE2463231158A7537C6DD7D7B1277E4ABA2B22A0` |
| Upload log | `1EEA99079D4E7329E3D9BF3C01CE8F4950EC02B716F78B659D422828569C9379` |
| Raw serial | `8556F0B427830C60A40A202EC9DFCB88A8464AE7E0CF3683E3FF68FD3427A31A` |
| Timed serial | `4EA92A65129667ABB9BC759D0E94ACFEAC38B9F955D7D38A1CB9E38725AE4E7E` |
| Configuration descriptor | `E4797CDA5D2FF080140DEF3259A0642E8D078679E507FEE1D6C709FC02C22886` |
| Report descriptor | `99B0E143128C21E3066F1DE6A124DCC314B0D6578DAFBA1DFF292972ACBE1F0D` |
| Adjudication JSON | `9417428F22E89105009A28AC5E878145C87717EE38C95E400503E854BD7092E7` |
| Verified trial ZIP | `EF2B12A349E715EADFC5C5F87DF5C99B31CBAEAB4B80A285C8419F023074E5D4` |

Remaining human operations: each button including the unidentified15th input, all D-pad directions, stick range/direction, trigger operation and return to neutral, turbo/macro state, UI inspection, and later controller/LAN disconnect/reconnect. Manual USB-only mapping is a required prerequisite to LAN integration. The PC peer remains.30 while the product binary defaults to.20; a separately identified Fixed10Half PC-peer build will be needed when that gate passes. Physical Receiver/UART and durability gates remain untested. No prior gate was bypassed or rerun under an altered label.

The device is left running the USB-only intake binary identified above. No further physical manipulation is requested while the operator is unavailable.

`git diff --check` passed before and after implementation. Initial HEAD wasc1492aa with only preserved local reference directories and the preceding USB report untracked; no unrelated changes were discarded. Source/test commit18f8870 was pushed under the earlier explicit publication authorization. This evidence follow-up is documentation only. No PR, merge, release or Issue closure was performed. Final Git status retains only the previously excluded local reference directories after publication.
