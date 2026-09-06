# CoRE product candidate validation — 2026-09-06

Source review, host tests and three clean target builds passed. **No physical qualification, firmware upload, main merge or release was performed.** Product-supported controllers remain none. UART invalid/timeout safety is still a required design/implementation task in [#9](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/9).

## Authorities

- Initial branch HEAD: `f915b1c9a33693a2010a1d9527b23743707cfa5d`.
- Saved current diagnostic/source/document/test baseline: `68619ddd254da008bbe1bf3add4823b527e55241` (45 files).
- HORI implementation: `31cdef3af6f1a2f4dc3312c86225f0187d4b39cb`.
- Final firmware source: `418d1a0d662feabb01eb0ccb6ca16fc20ce58294`; test/document tree: `12bb4cc47ecd27623b014d24e3f7f1ce54401921`. The latter does not change the firmware source.
- Branch: `feat/cores3se-dualsense-lan-stack-diagnostic`, pushed to the owner's origin fork. Upstream and main were not changed.
- [Machine-readable record](product-candidate-20260906.json), SHA-256 `497CCEF20BADBFC24EB23C21B8E66FB8E158B3A1DBD571782C8E17E012896B16`. It contains source/binary/log/library hashes, memory summaries, exact versions and changed-file inventory through the tested tree.

## Implemented software outcomes

- #8: HORI VID/PID profile, captured hat0x0F normalization, strict8-byte input shape, malformed/unsupported/disconnect/freshness neutralization, USB-only compile mode.
- #10: fresh isolated low-clock library generation with exact original hashes, normal/TX8MHz and independent USB26/8MHz choices; original library/freeze preservation.
- #11: both endpoints default to10ms, phase-preserving constant-time deadline advancement, skip and lateness accounting; explicit20ms comparator retained.
- #12:40ms numeric snapshots, changed48x8 RGB565 fields only, one field per service, communication guard, failure handling and measured-duration counters; actual durations are not measured yet.
- #13: explicit isolated CLI configuration, pinned versions, separate clean builds, source/library/bin/log evidence, portable native C++ and Python host tests in CI.

## Validation

[GitHub Actions run](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/actions/runs/34003164441) passed on `12bb4cc47ecd27623b014d24e3f7f1ce54401921`:438 controller checks,45 runtime checks,82 numeric-renderer API-double checks,7 Python library-patch tests and the unchanged protocol reference/golden vectors. The renderer double checks actual production dispatch/geometry but is not a physical timing or visual test.

Existing offline Runner suites passed: C1=48, C2=92, DG-A=138, DG-B=90, DG-C=109, DG-D=76. The DG-D fixture wrapper passed20 checks. Peer-suite counts are in the JSON; wrappers are not summed as independent coverage. PowerShell parse checks and `git diff --check` passed.

Final build generation: `20260906-100256-c5590789`. Earlier20ms/old-display/high-SPI generation: `20260906-093956-74d66726`. Both contain three successful builds; only the final generation qualifies the new timing/display source. Source manifests for every final case and all library hashes were rechecked against current files. Binary and log hashes were rechecked from disk.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/product_build.ps1 -ConfigFile build-temp/product-toolchain-20260906/arduino-cli.json -LibraryRoot build-temp/product-libraries-8-8-usb26-20260906/libraries -PeriodMs 10 -NumericUi 1
```

Compiler command arrays and exact local paths are retained in each local build generation. The public record uses relative artifact names. Core3.3.7, M5Unified0.2.19, M5GFX0.2.26, M5-Ethernet4.0.0 and isolated UHS1.7.0 were used, with Arduino CLI1.5.1. No global package/library modification was performed. The build workflow identifies inputs; bit-for-bit reproducibility across another machine/rebuild has not been proven.

| Final artifact | Binary bytes | Change vs earlier candidate | SHA-256 |
|---|---:|---:|---|
| receiver | 564,352 | +5,104 | `F587557A4AD8C1C8EF8F0D71E2DD444C233457D312499998647D864058E4CC50` |
| sender | 573,856 | +5,056 | `7BA2C2F156E4B28F0CB82A65184D61CF5D314F6D9BF9758183582A4EAC92DBFA` |
| sender-usb-only | 571,744 | +5,024 | `DB56CF9A35651A5F539147D0AD1ADB361DB5B158C8A57FF20930B8AFE1144012` |

These deltas include combined source/clock/display differences and are not an isolated performance comparison. Static RAM and flash usage are in the JSON; runtime heap/PSRAM headroom remains unmeasured. The USB8MHz library candidate is source-prepared only; final builds use USB26MHz to keep that factor separate.

## Remaining work and claim boundary

Proven facts are the source behavior, host results and compiler/artifact checks above. Low-SPI signal-quality improvement, actual100Hz jitter,25Hz display freshness, LCD call duration and electrical root cause remain unmeasured. Physical runtime for this work is0seconds; HID/CONTROL/STATUS/CRC/gap/timeout/link/reset counters are unmeasured, not a zero-failure PASS.

- [#7](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/7): freeze timing tolerances and measurement resolution; verify exact candidate/device/COM; perform USB-only mapping first, then screening,10-minute integration, faults and60-minute durability.
- [#9](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/9): choose the [UART safety contract](../uart-safety-decision.md) before implementing synthetic neutral/reconnect semantics. The known unsafe forwarding/silence behavior remains in this candidate.
- [#14](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/14): isolate clock/UI/non-null-read factors and investigate the unresolved USB/LAN instability.
- [#15](https://github.com/Yuichiroh-Kobayashi/M5Stack-SwitchController2CoREWirelessSender/issues/15): downstream compatibility decision; ASCII UART has not been adopted.

Issues remain open pending accepted-source review/merge and their remaining validation boundaries. No candidate was installed; existing device firmware was not re-read.

## Intake and publication scope

The initial broad public-push proposal was rejected by automatic approval review because it included vendor PDFs and historical handoff/environment artifacts. Those18 files were removed from the staged payload and remain locally preserved. The narrower source/docs/tests push was accepted and completed. Raw logs and frozen build directories remain local; public summaries and hashes are published instead.

An initial Arduino environment query attempted blocked global-tool initialization. Automatic review rejected repeating it outside the sandbox. The completed builds instead used copies of the existing pinned tools and workspace-only CLI data/downloads/user directories. Initial incorrect offline CLI flags were corrected; failed and corrected logs remain separate in local intake evidence. None of these failed attempts is reported as a test PASS.
