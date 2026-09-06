# CoRE LAN development targets

User-confirmed 2026-09-06. These are development acceptance targets, not claims of installed firmware or physical qualification. The current source candidate defaults to 10ms communication and 40ms numeric snapshots. Physical qualification is pending. Explicit20ms/legacy-UI build options preserve comparison conditions.

| Item | Target |
|---|---|
| CONTROL / STATUS | Both 10ms nominal (100Hz), absolute deadlines, no catch-up bursts |
| Ethernet | M5-Ethernet 4.0.0; normal and TX SPI both 8MHz; isolated dependencies |
| USB | Separate comparison of 26MHz baseline and 8MHz candidate |
| LCD | Numeric dirty fields at 40ms (25Hz); small RGB565 field transfers distributed between communication work |
| LCD budget assumption | Up to 24 fields of 48x8 pixels, 40MHz LCD: 3.6864ms pixel transfer per 40ms, 9.216% average; CPU/commands/waits require measurement |
| Deadline priority | Safety and communication before display; obsolete display work coalesced rather than queued |
| Unchanged contract | 32-byte v1 CR binary, CRC-16/CCITT-FALSE, big-endian, UDP50001, input/peer timeout100ms, Port C115200 8N1 |
| Controller | HORI PAD TURBO 0F0D/0202, Switch 2; no product-supported controller until all gates pass |

Develop from the current product source. Implement the HORI profile and pass USB-only mapping before product LAN integration. Do not change PHY mode or reset strategy as part of clock reduction. Receiver invalid/stale UART output needs a separate safety correction; the proposed ASCII adapter is not adopted.

Track durable outcomes in the [Issue index](development-issues.md). Integration #7 owns physical mapping, 60-second screening, 10-minute integration, disconnect/reconnect and 60-minute durability. Implementation children may have a nonphysical boundary, but are not closed before accepted changes and evidence meet their acceptance criteria.

## Timing acceptance to freeze before physical integration

Record both endpoints' actual packet timestamps, deadline lateness and skipped periods, maximum USB service gap, maximum Usb.Task duration, maximum LCD unit duration, UART output timing and all protocol/error counters. Nominal 100Hz alone does not establish jitter or loss acceptance. The integration Issue must freeze tolerances and measurement resolution before testing; until then physical readiness is incomplete.

The earlier [200ms LCD study](low-spi-numeric-lcd-development-plan-20260906.md) is historical planning. Its 200ms start value is superseded by this 40ms target using small field-image transfers. Its warnings about font area and long unbroken transfers still apply.
