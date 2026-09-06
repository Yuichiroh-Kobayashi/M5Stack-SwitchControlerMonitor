# USB/LAN shared-power diagnostic plan

## Scope and safety status

This document defines future power-source tests for the CoreS3 SE, USB Module
v1.2, LAN Module 13.2, and M5GO Bottom3 stack. It does not authorize a hardware
test by itself.

```text
DUAL_SOURCE_POWER=UNVERIFIED
DUAL_SOURCE_TEST=PROHIBITED
```

LAN Module external power must be treated as a possible supply for the complete
M-Bus stack. It is not an isolated W5500-only supply. Do not connect LAN external
power concurrently with CoreS3 USB-C VBUS or Bottom3 battery power until the
reverse-current behavior is supported by official documentation or measured on
an unpowered, current-limited test fixture.

## Reviewed sources

- `docs/Schematic/Sch_Module13.2_LAN.pdf`, page 1
- `docs/Schematic/Sch_M5_CoreS3_SE_v1.0.pdf`, pages 1, 2, 5, and 6
- `docs/Schematic/Sch_M5GO3.pdf`, page 1
- `docs/Schematic/SCH_USBHost_V1.2.pdf`, page 1
- `docs/Datasheet/W5500_datasheet_v1.1.0_en.pdf`, pages 10, 42, 59, and 60

The PDFs were text-extracted and their relevant pages were rendered for visual
review. Component direction and unlabelled connector polarity remain unknown
where the schematic does not state them explicitly.

## Power tree

### LAN Module 13.2 external input

The LAN schematic shows this path:

```text
PWR3.5 external connector
  -> INF+
  -> F1 PPTC-1812
  -> IN+
  -> U2 MP1584EN VIN
  -> switching stage L1 and output capacitors
  -> +5V net
  -> M5Stack_BUS pin 28 (+5V)
  -> U1 BL8075CB5TR33
  -> D3V3
  -> FB1
  -> A3V3
```

The connector region is labelled `IN12/24V`. The schematic shows D4 (`SD24`)
from the input region to ground and F1 in series with the positive input. D4 is
not shown as a series reverse-current blocker between the generated `+5V` net
and M-Bus `+5V`. No isolation device is shown between the MP1584EN output and
M-Bus pin 28.

### CoreS3 SE USB-C and M-Bus

The CoreS3 SE schematic shows USB-C `VUSB`, the AXP2101 `VBUS`, and a switched
power tree containing `BUS_5V`, `BUS_OUT`, and M-Bus pin 28. M-Bus pin 28 is
labelled `BUS_OUT`; the LAN Module names the connected pin `+5V`.

The CoreS3 power-direction diagram shows controlled paths between USB `VUSB`,
PMU `VBUS`, `BUS_OUT`, and the boost output. It does not establish that U14,
U18, or U19 blocks reverse current in every powered and unpowered state. Their
reverse-current behavior must therefore be treated as unknown.

### Bottom3 and battery

The Bottom3 schematic connects `BAT+` to M-Bus `BATTERY` pin 30 and uses TP4057
with `VIN` supplied from the board `+5V` net. M-Bus pin 28 is connected directly
to the Bottom3 `+5V` net. The schematic does not prove that an attached battery
is isolated from an externally driven M-Bus `+5V` rail under all states.

### USB Module v1.2 Type-A VBUS

The USB Module schematic connects M-Bus pin 28 to its `VBUS` net. That net
supplies the USB Type-A connector VBUS through D1 (`B5819W SL`) as drawn. The
diode provides a defined element in the Type-A VBUS branch, but it does not
isolate the LAN external supply from the rest of the M-Bus `+5V`/`BUS_OUT` net.

## Static safety findings

| Question | Finding | Basis |
| --- | --- | --- |
| Is LAN external power W5500-only? | No | Its MP1584EN output is the shared M-Bus `+5V` net. |
| Is there a series reverse blocker from LAN `+5V` to M-Bus `+5V`? | Not found | LAN schematic page 1 shows a common net. |
| Is simultaneous LAN external and USB-C power officially permitted? | Unknown | No reviewed source states this. |
| Is simultaneous LAN external and Bottom3 power officially permitted? | Unknown | No reviewed source states this. |
| Can PC serial be used without also applying USB-C VBUS? | Not with an ordinary cable | A VBUS-blocked data cable or isolated logger is required. |
| Can LAN external power energize the full stack? | Electrically possible from the shown net | Must be confirmed with current-limited measurement before use. |
| Input voltage range | The schematic net is labelled `IN12/24V` | Exact min/max ratings are not established by this label alone. |
| Connector polarity | Unknown | Connector pin numbering is shown, but no approved user-facing polarity statement was found. |

## Required preliminary measurements

Before P1, P2, or P3 is considered:

1. With all power removed, measure continuity and diode-mode behavior between
   LAN `+5V`, Core M-Bus pin 28, USB-C VBUS, Bottom3 `BAT+`, and USB Type-A VBUS.
2. Obtain official datasheets for the CoreS3 power-path devices U14, U18, and
   U19 and verify reverse-current blocking for every relevant EN state.
3. Confirm PWR3.5 connector polarity from an official mechanical drawing or by
   continuity measurement on an unpowered module.
4. Confirm the permitted external input voltage range from an official LAN
   Module 13.2 specification, not only the schematic net label.
5. Use a current-limited bench supply and establish no-load current before a
   controller or LAN cable is connected.

## Candidate test conditions

### P0 - current Core/Bottom3-side supply, no LAN external input

- Purpose: retain the known baseline while comparing Mode 8 through Mode 10.
- Required equipment: current CoreS3 USB-C supply arrangement and normal serial
  logging path.
- Pre-measurement: record USB-C input voltage and whether Bottom3 battery is
  physically present.
- Voltage points: M-Bus pin 28, LAN `D3V3`, USB Type-A VBUS.
- Prohibited conditions: LAN external connector energized.
- Stop criteria: abnormal heating, brownout, boot loop, USB port loss, or any
  unexpected rail outside its documented range.
- USB logging: ordinary CoreS3 USB-C serial is permitted for this condition.

### P1 - LAN external input as the sole stack supply

- Purpose: determine whether changing the stack supply path changes USB
  stability without creating a second source.
- Required equipment: current-limited bench supply, verified connector and
  polarity, DMM, and a VBUS-blocked USB data path or an isolated UART logger.
- Pre-measurement: continuity/diode tests listed above; remove or electrically
  isolate Bottom3 battery; prove PC USB-C VBUS is absent before power-on.
- Voltage points: external input before and after F1, MP1584EN `+5V`, M-Bus pin
  28, Core PMU rails, LAN `D3V3`, and USB Type-A VBUS.
- Prohibited conditions: ordinary PC USB-C cable with VBUS present; Bottom3
  battery connected; unverified polarity or voltage.
- Stop criteria: reverse current into the PC/logger, current-limit operation,
  unexpected M-Bus voltage, abnormal heat, brownout, or boot loop.
- USB logging: data-only/VBUS-blocked USB-C only after continuity verification,
  otherwise an isolated UART logger.

### P2 - LAN external input plus PC USB-C

- Purpose: only a future reverse-current and power-sharing validation.
- Required equipment: not defined until device datasheets and a current-limited
  measurement fixture are approved.
- Pre-measurement: U14/U18/U19 reverse-current review and measurements on both
  sources.
- Voltage points: both source outputs, PMU VBUS, M-Bus pin 28, and return-current
  points on each cable.
- Prohibited conditions: all execution under the current evidence state.
- Stop criteria: not applicable because execution is prohibited.
- USB logging: not authorized.

```text
DUAL_SOURCE_POWER=UNVERIFIED
DUAL_SOURCE_TEST=PROHIBITED
```

### P3 - LAN external input plus Bottom3

- Purpose: only a future battery/power-sharing validation.
- Required equipment: not defined until TP4057, battery protection, and Core PMU
  interaction are reviewed and measured.
- Pre-measurement: battery removal/isolation method, charge/discharge direction,
  and M-Bus pin 30 behavior.
- Voltage points: LAN `+5V`, M-Bus pin 28, `BAT+`, M-Bus pin 30, TP4057 VIN/BAT,
  and Core PMU VBAT.
- Prohibited conditions: all execution under the current evidence state.
- Stop criteria: not applicable because execution is prohibited.
- USB logging: not authorized until a single-source data path is established.

```text
DUAL_SOURCE_POWER=UNVERIFIED
DUAL_SOURCE_TEST=PROHIBITED
```

## Approval gate

P0 is the only currently authorized power topology. P1 remains a design
candidate, not an executable procedure, until the sole-source and VBUS-isolated
logging conditions are independently reviewed. P2 and P3 remain prohibited.
