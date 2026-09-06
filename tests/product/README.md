# Product host tests and candidate builds

Issues: [HORI #8](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/8), [build #13](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/13), [physical owner #7](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/7).

## Host

Run `python tests/product/run_host_tests.py` with an installed C++11-capable `g++` (or set `CXX`). GitHub Actions runs the same command on Ubuntu24.04. The test compiles the actual product header and CoreProtocol.cpp, executes input/freshness/identity and wire vectors, then runs the Python protocol reference. It does not use a simulated reimplementation of the parser and has no USB/network activity. Target build and physical qualification remain separate.

## Clean target build

Use `tools/product_build.ps1 -ConfigFile <workspace-isolated-cli.json> -LibraryRoot <workspace-isolated-libraries>` in PowerShell. It builds Receiver, Sender and Sender USB-only separately, in that order, into a fresh directory under build-temp. It copies the entire src tree, validates pinned libraries and CoreS3 UHS pins, and records source/library/binary/log hashes and exact compiler arguments. No upload or package-install command is present.

The CLI config must explicitly set directories.data, directories.downloads and directories.user to existing workspace directories. Copy the already installed core/tools into the isolated data directory before use; do not point this config to global Arduino15. Required core is m5stack:esp32 3.3.7. Required libraries are M5Unified0.2.19, M5GFX0.2.26, M5-Ethernet4.0.0 and UHS1.7.0 with the existing CoreS3 patch. This script is a verifier/builder, not an installer. Preserve existing diagnostic freezes and use a new evidence root for a retry.

## HORI report authority and limitation

Source mapping: legacy `M5Stack-SwitchController2CoREWirelessSender.ino`. Captured neutral report: `00 00 0F 80 80 80 80 00`, length8. Public-safe evidence name: `wirelesssender-mode-0-order-0-raw-1-nolanmodule-horipad-wirelesssender-fixed-horiscreening1-20260728-211615-serial.log`; SHA-256 `F454BD049E81507BAA286118960DCC121C0860BAEC98B0C7C12E234E937AFB07`. The raw file remains in local evidence and is not required for the portable host vectors.

The first byte is buttons, not a report-ID prefix. The candidate rejects the callback's hasReportId=true form, but UHS1.7.0 does not automatically derive that flag from the report descriptor (`hidcomposite.h` records this limitation). Do not claim complete descriptor verification from that flag. USB-only physical intake must confirm the actual descriptor and report shape on the candidate. Hat0..7 is directional and0x0F is neutral; other low-nibble values are rejected. Reserved bits and byte7 are ignored, not assigned invented functions.

Digital ZL/ZR become trigger0/255 while preserving their button bits. The caller must use input validity/effective state; the stored last decoded value is not authorization to transmit stale controls. Disconnect/identity change and malformed reports invalidate immediately. Freshness is100ms with unsigned wrap-safe subtraction.

`SENDER_USB_ONLY=1` skips W5500 initialization and all CONTROL/STATUS traffic, holds W5500 in reset, initializes shared SPI once and exercises the product parser/UI. Product mode keeps LAN-before-USB initialization. This is not permission to change wiring or upload; freeze exact COM/PnP and candidate first.

Older DG-D tests under tests/usb-lan-gate-dg-d intentionally need local frozen evidence. They are not substituted for portable product tests.
