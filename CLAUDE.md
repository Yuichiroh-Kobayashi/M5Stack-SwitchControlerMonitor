@AGENTS.md

# Claude Code adapter

- Treat `AGENTS.md` as the canonical repository instruction.
- Start with a written plan for any task that touches product firmware, protocol, SPI ownership, USB host behavior, controller mapping, or hardware validation.
- Keep diagnostics separate from product code and explain which result would falsify each hypothesis.
- Do not use broad autonomous cleanup, refactoring, or dependency upgrades in a hardware-debugging task.
- Do not perform Git writes, firmware uploads, or physical-device assumptions without explicit user authorization.
- Report unverified hardware behavior as unverified; a build or static analysis result is not an implementation pass.
- Do not confuse a USB-only controller baseline with completed product Sender support.
