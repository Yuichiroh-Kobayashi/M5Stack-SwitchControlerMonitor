@AGENTS.md

# Antigravity 2.0 / Gemini adapter

- Treat `AGENTS.md` as the canonical repository instruction.
- Use project-local context only; do not replace repository rules with global defaults.
- Do not start parallel agents, new worktrees, scheduled tasks, or broad `/goal` execution for hardware-facing tasks unless the user explicitly requests it.
- For implementation plans and artifacts, separate software-only work from user-performed physical gates.
- Stop at controller, stack, DIP-switch, powered-hub, cable, or COM-port changes and request the user action.
- Do not treat agent completion as hardware validation. Preserve serial logs, binary hashes, and exact acceptance results.
- Before proposing physical LAN integration, verify that the selected controller profile exists in the product Sender.
