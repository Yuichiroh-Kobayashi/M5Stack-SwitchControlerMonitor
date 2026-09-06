# Copilot instructions for the CoRE controller sender

## Precedence

- Follow the repository-root `AGENTS.md` as the canonical project guidance.
- Use this file only as a lightweight Copilot adapter.
- Do not infer that a completion is safe merely because it compiles.

## Critical constraints

- USB validation baseline: HORI PAD TURBO `0F0D/0202`, hardware mode `Switch 2`.
- HORI has a product Sender candidate; product USB-only mapping remains unvalidated. Do not begin physical LAN integration before that gate passes.
- DualSense `054C/0CE6` support is suspended on the current CoreS3 SE + MAX3421E + UHS stack.
- Do not add OULEKE mappings until the physical unit's descriptors and reports are captured.
- Preserve the 32-byte protocol, UDP port 50001, 10 ms candidate cadence (20 ms only for explicit baseline comparison), 100 ms timeout, big-endian fields, and CRC-16/CCITT-FALSE.
- Use explicit byte encoding; do not introduce packed wire structs.
- Preserve neutral fail-safe behavior for stale, invalid, disconnected, and unsupported controllers.
- Do not add automatic USB or ESP resets to hide a detach problem.

## Hardware-sensitive completions

- CoreS3 shared SPI: SCK36, MOSI37, MISO35.
- USB Module: CS1, INT14.
- LAN Module: CS13, INT10, RESET0.
- Receiver UART Port C: TX17, RX18, 115200 8N1.
- Keep inactive SPI chip-selects high and preserve established initialization order.
- Do not generate edits that change pin ownership, power behavior, DIP settings, or shared-SPI transactions unless the task explicitly requests them.

## Completion style

- Match existing Arduino/C++ and PowerShell style.
- Keep product, diagnostic, and documentation changes separated.
- Update sender, receiver, protocol reference, and docs together when changing a shared contract.
- Prefer small changes with explicit validation commands and hardware gates.
- Never generate commit, push, branch, reset, clean, stash, or upload operations unless the user explicitly requested them.
