# USB-LAN investigation workspace rule

Before work, read:

- @AGENTS.md
- @docs/ai/investigation-status.md
- The contract and exact source/build/raw/manifest for the gate being reviewed.

The usb-lan-antigravity handoff is historical evidence. Its next-C1 instruction is superseded by the current status document. Preserve its archived evidence and safety identifiers when consulting that generation.

Validate the Git branch, HEAD, status, and `git diff --check` before acting. Stop on mismatch, missing evidence, simultaneous edits, or unexplained files. Never discard existing changes.

Raw serial logs are authoritative. Verify the manifest path, size, and SHA-256 before using a classification. Keep FACT, HYP, and UNKNOWN separate. Do not infer missing metadata, physical states, electrical measurements, or causation.

Never use COM3. Do not upload to any device without explicit approval for the current gate. Before each approved upload, resolve the Sender using the exact PNPDeviceID in the safety rules; a COM number alone is not identity.

Git operations require user authorization under AGENTS.md. The 2026-09-06 follow-up explicitly authorizes committing/pushing current relevant source/docs/tests to origin, creating Issues, and implementing/verifying feasible development work. It does not authorize merge/rebase/reset/clean/stash, releases or physical changes. Do not change modules, DIP switches, controller, cables, hub ports, Bottom3, power wiring, LAN external power, or dual-source power without explicit approval.

Do not change Product Sender, Receiver, protocol, UI, or HORI mapping merely because a diagnostic mode passed. Fixed10Half is a diagnostic workaround candidate, not an adopted product setting. Its UDP traffic, bidirectional 50 Hz load, reconnect behavior, multi-unit behavior, and product durability are not yet validated.

The evidence supports involvement of 100 Mbps PHY operation or a nearby state transition. It does not establish whether the electrical root cause is power behavior, EMI, or another coupling path. Do not state that 100BASE-TX, voltage droop, or EMI has been proven.

Advance one gate at a time. The 2026-09-06 follow-up expands software scope to the Issue-backed targets in docs/development-targets.md. No new physical gate is authorized by this rule. Obey each gate's start, pass, fail, and immediate-stop conditions; do not extend a failed test to obtain a pass.
