# Hardware and software baseline

## Product topology

### Sender

- M5 CoreS3 SE
- M5Stack USB Module v1.2, MAX3421E
- M5Stack LAN Module 13.2, W5500
- Base M5GO Bottom3
- Wired controller
- Wired Ethernet to a switching hub

### Receiver

- M5 CoreS3 SE
- M5Stack LAN Module 13.2, W5500
- Base M5GO Bottom3
- UART Port C output to the downstream system

## CoreS3 SE pin map

| Function | GPIO |
|---|---:|
| SPI SCK | 36 |
| SPI MOSI | 37 |
| SPI MISO | 35 |
| USB MAX3421E CS | 1 |
| USB MAX3421E INT | 14 |
| LAN W5500 CS | 13 |
| LAN W5500 INT | 10 |
| LAN W5500 RESET | 0 |
| Receiver UART TX | 17 |
| Receiver UART RX | 18 |

USB Module v1.2 must use the CoreS3 CH2 setting for both SS and INT.

## Validated software baseline

| Component | Version |
|---|---:|
| M5Stack ESP32 board core | 3.3.7 |
| M5Unified | 0.2.19 |
| M5GFX | 0.2.26 |
| M5-Ethernet | 4.0.0 |
| USB Host Shield Library 2.0 | 1.7.0 plus recorded isolated CoreS3 patch |

The diagnostic environment records exact hashes for the patched USB Host Shield Library files. Do not substitute an unrecorded library copy when comparing hardware results.

## Known implementation constraints

- USB, LAN, LCD, and other peripherals share the CoreS3 SPI pins.
- W5500 static addressing with M5-Ethernet 4.0.0 requires the validated explicit setter path used by the product work.
- Current product Sender initialization order is: (1) initialize LAN/W5500, then (2) initialize USB/MAX3421E.
- USB-first diagnostics did not reach USB RUNNING. LAN-first diagnostics reached RUNNING, but DualSense later detached. Initialization success and controller stability are separate findings.
- Do not change the product order during HORI integration without explicit evidence.
- A switching hub resolved direct Ethernet link behavior between the two W5500 endpoints.
- The UGREEN powered USB hub `B09DCK46PM` is not compatible with the current CoreS3/MAX3421E/UHS downstream-HID path. It is not a valid product dependency.

## Validation scope

Validated:

- Bidirectional Ethernet protocol operation through a switching hub.
- HORI USB-only operation in legacy and diagnostic firmware.

Not yet validated:

- A HORI controller profile in the product LAN Sender.
- Full HORI USB + LAN product integration.
