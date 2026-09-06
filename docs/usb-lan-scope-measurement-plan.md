# USB-LAN shared-SPI scope measurement plan

## Scope and evidence status

This plan supports the CoreS3 SE + USB Module v1.2 + LAN Module 13.2
diagnostic stack. It does not authorize physical probing, LAN external power,
or dual-source power. The electrical-net findings below are schematic facts;
the connector orientation and physical accessibility must still be verified on
the actual module before a probe is attached.

Sources reviewed:

- `docs/Schematic/SCH_USBHost_V1.2.pdf`, page 1
- `docs/Schematic/Sch_M5_CoreS3_SE_v1.0.pdf`
- `docs/Schematic/Sch_Module13.2_LAN.pdf`
- `docs/Schematic/Sch_M5GO3.pdf`

## USB Module side headers

The USB Host v1.2 schematic has two eight-pin headers:

| Header | Pins 1-5 | Pin 6 | Pin 7 | Pin 8 | Schematic role |
| --- | --- | --- | --- | --- | --- |
| P1 | MAX3421E `GPIN0..4` | GND | +3.3V | VBUS | input-side GPIO header |
| P2 | MAX3421E `GPOUT0..4` | GND | +3.3V | VBUS | output-side GPIO header |

The `VBUS` net at the headers is the same named net used by USB Type-A J1
pin 1 and M-Bus J2 pin 28. The `+3.3V` net supplies MAX3421E VCC/VL. Pin 6
is GND. Therefore the side labels `0..4` are MAX3421E GPIN/GPOUT signals,
not ESP32 GPIO numbers.

The schematic establishes P1 versus P2 electrically, but it does not by
itself establish which externally visible side is P1, nor the observer-facing
silkscreen direction and pin order. Those physical orientation details are
UNKNOWN until the assembled module is inspected against pin 1 markings.

Do not connect the USB side-header `0..4` directly as an ESP32 scope marker.
Using a MAX3421E GPOUT as a marker would add SPI register transactions and can
perturb this root-cause experiment, so it is prohibited for the present test.

## Measurement points

| Channel | Probe point | Reference | Interpretation |
| --- | --- | --- | --- |
| CH1 | USB Module side-header `5V`/VBUS | side-header `G` | shared 5V / USB VBUS proxy |
| CH2 | USB Module side-header `3V3` | side-header `G` | MAX3421E 3.3V rail proxy |

Before connecting a probe, use continuity/voltage measurements with power off
or under an approved safe procedure to confirm the physical header pin against
the schematic. Scope ground may be connected only to the verified `G` pin.

## Measurement limitations

- These header points are upstream proxies; they do not fully observe a local
  droop at the USB Type-A contact after connector and trace resistance.
- USB D+ and D- are outside this measurement.
- 5V and 3.3V waveforms alone cannot completely distinguish conducted power
  droop from EMI or signal-integrity effects.
- Connecting an earth-referenced scope changes the stack ground reference and
  may alter the observed phenomenon. Record the scope model and isolation.

## Initial oscilloscope setup

- 10:1 probes.
- DC coupling.
- Start with the 20 MHz bandwidth limit enabled.
- Use short ground springs, not long ground leads.
- Use single acquisition with 30-50% pre-trigger history.
- Start with a falling-edge trigger on CH1.
- Derive the exact trigger level from the measured idle 5V value and noise;
  do not assume a fixed threshold before measuring the unit.

Correlate the capture with the firmware `RESET_RELEASE_MICROS` and
`RESET_RELEASE_TO_DETACH_US` records. No dedicated digital marker is currently
implemented.

## ESP32 scope-marker review

The occupied pins include USB CS/INT (GPIO1/14), LAN CS/RESET/INT
(GPIO13/0/10), shared SPI (GPIO35/36/37), display/SD, I2C, audio, and Bottom3
resources. The reviewed schematics do not identify one physically accessible
CoreS3 SE pin that is guaranteed free across this complete stack. Candidate
M-Bus pins require a separate pin-ownership and accessibility review.

Result: no marker GPIO is selected and no marker code is enabled. If a later
review establishes a safe pin, the proposed compile-time default is
`USB_LAN_SCOPE_MARKER_GPIO=-1`, so marker activity remains disabled unless a
specific reviewed build overrides it.

## PMIC telemetry review

M5Unified 0.2.19 exposes `M5.Power.getVBUSVoltage()`,
`getBatteryVoltage()`, `getBatteryCurrent()`, and `isCharging()`. Its AXP2101
implementation also exposes `isVBUS()` and register-backed VBUS/battery voltage
reads. On ESP32-S3/CoreS3, however, `Power_Class::getBatteryCurrent()` returns
zero rather than a measured AXP2101 charge/discharge current; the underlying
AXP2101 charge/discharge-current methods also return zero.

| Quantity | Classification | Limitation |
| --- | --- | --- |
| VBUS voltage | API available | low-rate PMIC ADC; not a transient capture |
| battery voltage | API available | low-rate PMIC ADC |
| VBUS present | register/API available via AXP2101 `isVBUS()` | public through the AXP2101 member, not a generic `Power_Class` boolean |
| charge state | API available | state classification, not current magnitude |
| battery charge/discharge current | not available as a measurement on CoreS3 in this version | generic API returns zero |
| system/APS voltage | underlying method exists but returns zero | not available as a measurement |

No PMIC telemetry is added to the timing-critical runtime. A future diagnostic
may take only pre-action and post-detach snapshots after separately validating
the semantics. PMIC telemetry is not a substitute for an oscilloscope because
its sampling and bandwidth cannot capture fast droop or EMI.

## Safety constraints

- Keep LAN external power disconnected.
- Keep dual-source power prohibited: `DUAL_SOURCE_POWER=UNVERIFIED` and
  `DUAL_SOURCE_TEST=PROHIBITED`.
- Connect scope ground only to verified GND.
- Confirm whether the bench scope input ground is protective-earth referenced.
- Stop on unexpected heating, reset loops, probe slip, or voltage outside the
  module's established operating range.
- Do not probe D+/D- in this phase.
