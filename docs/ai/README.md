# AI reference index

`AGENTS.md` is the canonical instruction file. The files in this directory provide stable project facts and validation references without duplicating the full instruction set.

- `hardware-baseline.md`: validated hardware, pins, library baseline, and topology constraints.
- `protocol-and-safety.md`: fixed LAN/UART frame and fail-safe invariants.
- `controller-compatibility.md`: accepted, suspended, rejected, and pending controller/topology results.
- `validation-gates.md`: staged build and real-hardware acceptance gates.

Update these references when evidence changes. Do not use them to override `AGENTS.md`.

Current implementation warning: HORI is the USB-validated development baseline, but the product LAN Sender still contains DualSense-specific parsing. See `controller-compatibility.md` before proposing controller or LAN integration work.
