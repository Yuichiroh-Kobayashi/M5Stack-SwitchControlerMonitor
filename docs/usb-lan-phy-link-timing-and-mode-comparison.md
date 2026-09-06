# USB-LAN PHY link timing and mode comparison

## 1. Purpose

This diagnostic separates W5500 PHY link-state timing from MAX3421E USB-host behavior on the shared CoreS3 SE SPI bus. It does not change the product Sender, controller parser, protocol, M5-Ethernet, or USB Host Shield Library.

## 2. Known results

- Mode 8 with the LAN cable disconnected passed 60 seconds.
- Mode 8 with the LAN cable connected detached in three trials. RESET marker to detach was approximately 1.532 to 1.898 seconds (mean approximately 1.699 seconds).
- Mode 12 released W5500 RESET after HORI USB had been RUNNING for 1,000 ms and detached 1,711,434 us after release.
- Mode 9 (initialize, then hold W5500 in reset) and Mode 10 (PHY Power Down) each passed the previously executed 60-second trial.

These are time correlations and controlled observations, not proof of an electrical root cause.

## 3. PHYCFGR profile table

| Profile | OPMD | OPMDC | Intended PHY mode |
| --- | ---: | ---: | --- |
| HardwareStrap | 0 | PMODE pins | Hardware strap configuration |
| PowerDown | 1 | 110 | PHY Power Down |
| Fixed10Half | 1 | 000 | 10BASE-T half duplex, Auto-Negotiation disabled |
| Fixed100Half | 1 | 010 | 100BASE-TX half duplex, Auto-Negotiation disabled |
| Auto100Half | 1 | 100 | 100BASE-TX half duplex, Auto-Negotiation enabled |
| AutoAll | 1 | 111 | All capabilities, Auto-Negotiation enabled |

The table is encoded once in `M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino`. Full-duplex forced modes are outside this test because the unmanaged hub remains Auto-Negotiation enabled and a duplex mismatch would confound the comparison.

## 4. Mode 13 design

`LAN_ONLY_PHY_LINK_TIMING` keeps MAX3421E CS high and W5500 RESET low while preparing the LAN SPI bus. It never calls `Usb.Init()`, `Usb.Task()`, HID parser registration, `Ethernet.begin()`, UDP, or the display runtime. It timestamps external RESET release, reads PHYCFGR every 5 ms at most, logs only changes, and records the first LNK=1 observation.

`LINK_OBSERVED=0` with valid reads is classified as `NO_LINK_OBSERVED`, not a firmware failure.

## 5. Mode 14 design

`USB_RUNNING_THEN_PHY_PROFILE` follows the Mode 11/12 control path: W5500 remains in reset while HORI reaches USB state 0x90, HID ready, VID/PID 0F0D/0202, and remains continuously valid for 1,000 ms. It then releases W5500 RESET, waits non-blockingly for the existing 50 ms release interval while continuing `Usb.Task()`, applies the selected PHY profile, and polls PHYCFGR every 10 ms at most.

Each W5500 access is one `SPI.beginTransaction(SPI_ETHERNET_SETTINGS)` / `SPI.endTransaction()` pair. LAN CS is asserted only by the existing W5100 register helper during that transaction. The single-threaded loop performs it only after `Usb.Task()` returns, so software does not overlap the two transactions.

## 6. Profile-setting sequence

For register-controlled profiles:

1. Read PHYCFGR.
2. Set OPMD=1 and the selected OPMDC value.
3. Write RST=0 to reset the internal PHY.
4. Wait 1 ms, matching the already hardware-tested Mode 10 implementation.
5. Write RST=1.
6. Read back RST, OPMD, and OPMDC and require an exact match.

HardwareStrap performs no PHYCFGR write. It verifies that RST has returned high and records the raw PMODE-derived value.

## 7. Link timing measurement

External RESET release is timestamped immediately around the GPIO0 LOW-to-HIGH action. The first PHYCFGR read latency is logged. Link timing is the unsigned microsecond difference between that release marker and the first completed read with LNK=1. Profile timing is measured from successful post-reset readback to the first LNK=1 observation.

Polling is observational but not electrically transparent: it introduces shared-SPI transactions. Poll duration, count, maximum USB service gap, and maximum USB task duration are therefore retained.

## 8. Hardware configuration

- M5 CoreS3 SE
- USB Module v1.2 (MAX3421E CS GPIO1, INT GPIO14)
- LAN Module 13.2 (W5500 CS GPIO13, RESET GPIO0, INT GPIO10)
- M5GO Bottom3 present
- HORI PAD TURBO 0F0D/0202, Switch 2, directly connected to the USB Module for Mode 14
- Buffalo LSW5-GT-8NS/BK non-PoE hub
- Cat5e unshielded cable, user-declared connected
- LAN external power not connected

`PowerSource=CoreUsb` is runner metadata. It does not prove that Core USB-C is the only active energy source while Bottom3 is physically present.

## 9. Test order

1. Mode 13 HardwareStrap, 10 seconds, three trials using one binary.
2. Mode 13 reachability: PowerDown, Fixed10Half, Fixed100Half, Auto100Half, AutoAll, 10 seconds each.
3. Mode 14: the same five profiles, 60 seconds each.
4. If Fixed10Half is `PASS_LINKED`, repeat twice at 60 seconds and once at 600 seconds. Otherwise do this only for Fixed100Half if it is `PASS_LINKED`.

Every upload requires exact COM4 PNP identity. COM3 is excluded.

## 10. Classification

| Classification | Meaning |
| --- | --- |
| PASS_LINKED | Profile readback valid, link observed, USB passed |
| FAIL_LINKED | Profile readback valid, link observed, USB detached |
| PASS_NO_LINK | Profile readback valid, no link observed, USB passed; active-link safety not established |
| FAIL_BEFORE_LINK | USB detached before observed link-up |
| CONFIG_FAIL | Profile readback mismatch or invalid PHYCFGR read |
| BLOCKED | Build, identity, upload, runtime, or evidence gate blocked |

## 11. Results

| Profile | Mode 13 readback | Link | Link time | Mode 14 USB | Detach time | Classification |
| --- | --- | --- | ---: | --- | ---: | --- |
| HardwareStrap | OK (`BF`) | 100 Full, 3/3 | 1,489,993 / 1,559,993 / 2,169,993 us | Not Run (Mode 12 is the equivalent USB path) | Not Run | Measurement complete |
| PowerDown | OK (`F0`, OPMDC `110`) | No | Not observed | PASS, 60 s | None | PASS_NO_LINK |
| Fixed10Half | OK (`C1`, OPMDC `000`) | 10 Half | 1,040,994 us | PASS, 60 s x3 and 600 s x1 | None | PASS_LINKED |
| Fixed100Half | OK (`D3`, OPMDC `010`) | 100 Half | 820,993 us | FAIL | 1,028,066 us after RESET; link not yet observed | FAIL_BEFORE_LINK |
| Auto100Half | OK (`E3`, OPMDC `100`) | 100 Half | 1,520,993 us | FAIL | 1,734,254 us after RESET; 14,502 us after link | FAIL_LINKED |
| AutoAll | OK (`FF`, OPMDC `111`) | 100 Full | 1,520,993 us | FAIL | 1,762,730 us after RESET; 42,975 us after link | FAIL_LINKED |

All Mode 13 reads completed with `PHYCFGR_READ_ERROR=0`. Mode 14 profile readback was valid in every trial. The Fixed10Half 60-second trials each produced 11,865 HID reports with no ready drop, register mismatch, panic, watchdog, brownout, or runtime reset. Its 600-second trial produced 119,865 reports with the same zero-error result.

## 12. RESET to link-up comparison

HardwareStrap RESET-to-link observations were 1,489,993, 1,559,993, and 2,169,993 us: minimum 1,489,993 us, maximum 2,169,993 us, arithmetic mean 1,739,993 us, and range 680,000 us. This overlaps the known Mode 8 RESET-to-detach range of approximately 1.532 to 1.898 seconds and is close to the Mode 12 RESET-to-detach value of 1,711,434 us. The overlap establishes a strong timing correlation in this physical setup, not causation.

## 13. Link-up to detach comparison

Auto100Half detached 14,502 us after observed link-up. AutoAll detached 42,975 us after observed link-up. Fixed100Half detached before a link-up observation and is therefore `FAIL_BEFORE_LINK`, not linked failure. PowerDown passed without link. Fixed10Half linked and remained stable for all three 60-second trials and the 600-second trial.

## 14. FACT

- PHYCFGR bit meanings and the six profiles above follow the repository W5500 datasheet copy.
- The isolated M5-Ethernet 4.0.0 W5100 helper exposes one-byte PHYCFGR read/write and handles W5500 common-register framing and CS assertion.
- Mode 10 already exercised the same OPMD/OPMDC and internal RST 0-to-1 sequence successfully for Power Down.
- HardwareStrap linked at 100 Mbps Full in all three trials; RESET-to-link ranged from 1,489,993 to 2,169,993 us.
- Fixed10Half was the only active profile to pass the complete repeated USB gate: 60 seconds three times and 600 seconds once.
- Fixed100Half detached before observed link, while both Auto profiles detached shortly after observed link.
- No Mode 14 detach trial reported a MAX register mismatch before fail-fast completion.

## 15. HYP

- If link-up clusters near the known detach window, link establishment or a preceding Auto-Negotiation/PHY transition becomes a higher-priority hypothesis.
- A Fixed10Half versus Fixed100Half difference would increase the priority of speed-dependent PHY power or EMI hypotheses.
- Fixed profiles passing while Auto profiles fail would increase the priority of Auto-Negotiation state transitions.
- The Fixed10Half/Fixed100Half difference increases the priority of speed-dependent PHY power, signal activity, or coupling hypotheses.
- The Auto100Half and AutoAll link-to-detach intervals increase the priority of link completion or a nearby PHY state transition as a trigger condition.

None of these timing comparisons alone establishes causation.

## 16. UNKNOWN

- Exact rail droop and transient current at RESET release and link-up.
- Conducted or radiated coupling into MAX3421E, USB VBUS, D+/D-, INT, or shared SPI.
- Link partner internal timing beyond the W5500 status observation.
- Whether PHYCFGR polling measurably perturbs the failure timing.
- Whether Fixed100Half would have linked after the observed detach if USB processing had continued.
- Whether Fixed10Half remains stable while carrying real Ethernet traffic; these diagnostics perform no Ethernet payload traffic.
- Whether the result generalizes to another hub, cable, module, controller unit, or power topology.

## 17. Product workaround candidates

Fixed10Half is now a provisional software-workaround candidate because it was `PASS_LINKED` in three 60-second trials and one 600-second trial. It is not approved for the product Sender: actual Ethernet traffic, protocol timing, UI/controller behavior, reconnection, multi-unit validation, and electrical measurement remain untested. Mode 10 PowerDown cannot carry product traffic and is not a product solution. No product Sender change is made by this diagnostic.

## 18. Oscilloscope handoff

Correlate GPIO0 RESET release, PHY link LED or a safe link proxy, USB Module 5V-G, and USB Module 3V3-G with the serial timestamps. Start with the safety and grounding limits in `docs/usb-lan-scope-measurement-plan.md`. Do not add LAN external power or dual-source power. Probe USB D+/D- only with appropriate differential equipment in a separately approved test.
