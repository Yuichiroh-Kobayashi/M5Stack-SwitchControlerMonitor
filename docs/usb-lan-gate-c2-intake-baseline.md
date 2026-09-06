# Gate C2 Intake Baseline

This document records the actual, measured repository state at Gate C2
intake time. Values below were captured directly by read-only git commands
during this task and supersede any status text quoted inside the C2 task
prompt itself.

Capture timestamp (task-local): 2026-08-19.

## Current branch

```text
feat/cores3se-dualsense-lan-stack-diagnostic
```

## HEAD

```text
f915b1c9a33693a2010a1d9527b23743707cfa5d
```

(matches the C2 task prompt's stated HEAD baseline; re-confirmed by
`git rev-parse HEAD`, not assumed from the prompt.)

## git status -sb

```text
## feat/cores3se-dualsense-lan-stack-diagnostic...origin/feat/cores3se-dualsense-lan-stack-diagnostic
 M M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino
 M tools/usb_lan_isolation_test.ps1
?? .agents/
?? docs/Datasheet/
?? docs/Schematic/
?? docs/handoffs/usb-lan-antigravity/
?? docs/usb-lan-fixed10-gates-c1-c4.md
?? docs/usb-lan-gate-c1-planned-physical-trials.md
?? docs/usb-lan-phy-link-timing-and-mode-comparison.md
?? docs/usb-lan-power-test-plan.md
?? docs/usb-lan-scope-measurement-plan.md
?? tools/usb_lan_diagnostic_build_matrix.ps1
?? tools/usb_lan_gate_c1_runner.ps1
?? tools/usb_lan_gate_peer.py
```

Note: this listing was captured before this task's own P0/implementation
writes. Files this task creates (this document, the C1 archive errata, the
C2 contract, and later the C2 implementation files) will appear as
additional untracked entries once created; that is expected and is not a
baseline drift.

## git status --porcelain=v1 -uall (expanded untracked)

```text
 M M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino
 M tools/usb_lan_isolation_test.ps1
?? .agents/rules/usb-lan-investigation.md
?? docs/Datasheet/MAX3421E_en.pdf
?? docs/Datasheet/TP4057.pdf
?? docs/Datasheet/W5500_datasheet_v1.1.0_en.pdf
?? docs/Datasheet/esp32-s3_technical_reference_manual_en.pdf
?? docs/Schematic/SCH_USBHost_V1.2.pdf
?? docs/Schematic/Sch_M5GO3.pdf
?? docs/Schematic/Sch_M5_CoreS3_SE_v1.0.pdf
?? docs/Schematic/Sch_Module13.2_LAN.pdf
?? docs/handoffs/usb-lan-antigravity/00_README.md
?? docs/handoffs/usb-lan-antigravity/01_project_context.md
?? docs/handoffs/usb-lan-antigravity/02_hardware_and_constraints.md
?? docs/handoffs/usb-lan-antigravity/03_confirmed_evidence.md
?? docs/handoffs/usb-lan-antigravity/04_hypotheses_and_unknowns.md
?? docs/handoffs/usb-lan-antigravity/05_next_test_gates.md
?? docs/handoffs/usb-lan-antigravity/06_git_and_safety_rules.md
?? docs/handoffs/usb-lan-antigravity/07_evidence_manifest.csv
?? docs/handoffs/usb-lan-antigravity/08_working_tree.patch
?? docs/handoffs/usb-lan-antigravity/09_environment_snapshot.txt
?? docs/usb-lan-fixed10-gates-c1-c4.md
?? docs/usb-lan-gate-c1-planned-physical-trials.md
?? docs/usb-lan-phy-link-timing-and-mode-comparison.md
?? docs/usb-lan-power-test-plan.md
?? docs/usb-lan-scope-measurement-plan.md
?? tools/usb_lan_diagnostic_build_matrix.ps1
?? tools/usb_lan_gate_c1_runner.ps1
?? tools/usb_lan_gate_peer.py
```

## Tracked diff (git diff --stat)

```text
 M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino | 1211 +++++++++++++++++++++++++-
 tools/usb_lan_isolation_test.ps1             |   93 +-
 2 files changed, 1261 insertions(+), 43 deletions(-)
```

`git diff --check`: no output, exit code 0 (only benign CRLF/LF
line-ending-conversion warnings on stderr; no whitespace-conflict markers).

`git diff --binary`: 1609 lines, textual (no binary hunks); not reproduced
verbatim here as it is fully recoverable from the working tree via
`git diff --binary` against `HEAD` at any time and is not itself an
identity/authority value.

## Relevant untracked files for C2

The following untracked files are the ones the C2 canonical contract and
implementation plan directly depend on (already present, already reviewed
under C1):

```text
docs/usb-lan-fixed10-gates-c1-c4.md
docs/usb-lan-gate-c1-planned-physical-trials.md
docs/handoffs/usb-lan-antigravity/05_next_test_gates.md
tools/usb_lan_diagnostic_build_matrix.ps1
tools/usb_lan_gate_c1_runner.ps1
tools/usb_lan_gate_peer.py
```

All other untracked paths (`.agents/`, `docs/Datasheet/`, `docs/Schematic/`,
the remaining `docs/handoffs/usb-lan-antigravity/*` files,
`docs/usb-lan-phy-link-timing-and-mode-comparison.md`,
`docs/usb-lan-power-test-plan.md`, `docs/usb-lan-scope-measurement-plan.md`)
are pre-existing local work unrelated to this task and are left untouched.

## C1 accepted identity (re-verified, not transcribed from prompt)

All values below were independently recomputed with
`Get-FileHash -Algorithm SHA256` against the actual files on disk during
this task's read-only inspection phase, and cross-checked against
`build-temp\usb-lan-isolation\freeze\C1-final-20260818-005403-666bf93b\source\C1-reviewed-source-manifest.csv`.

```text
C1 accepted diagnostic source:
path=M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino (repository root, working tree)
size=68507
sha256=65529BC8A41374FD113FBB844D20432C030B5FBAF051C5EBAB9624C8F060FABB

C1 runner v3:
path=tools\usb_lan_gate_c1_runner.ps1
size=50138
sha256=5B24705265AA3B2D3830B2446F4BF75CCBACC4389C5605F475A968BA4F93E6B6

C1 peer:
path=tools\usb_lan_gate_peer.py
size=19422
sha256=2D1CFD91DD68DAF9F2A25D0F80962315CBB0648A4AD517B3279AEAF491E8663A

C1 build matrix baseline:
path=tools\usb_lan_diagnostic_build_matrix.ps1
size=16456
sha256=0B0890F0CBDE640574115C1D40E1E52179EB3AA23CD449F323F3E1E1D13A6BEF

C1 reviewed manifest:
path=build-temp\usb-lan-isolation\freeze\C1-final-20260818-005403-666bf93b\source\C1-reviewed-source-manifest.csv
size=6219
sha256=C0E32905974BADFB63CCC3EA2296A73BAC1DDE8076427B0F92E0B1BCB8FCAAC0

C1 final ZIP (repository-local source):
path=build-temp\usb-lan-isolation\freeze\C1-final-20260818-005403-666bf93b.zip
size=4482569
sha256=41071B6A948768E179C76627A4132C311888491A0DF0510B9533A6CBBEFC12E2

External archive copy (P0-1):
path=C:\Users\yu-ichirou\Documents\CoRE-Evidence-Archive\gate-c1\C1-final-20260818-005403-666bf93b.zip
size=4482569
sha256=41071B6A948768E179C76627A4132C311888491A0DF0510B9533A6CBBEFC12E2
```

All six values above match the values stated in the C2 task's "Gate C1 final
authority" section exactly (size and SHA-256, both for source files and the
external copy). No mismatch was found.

Important note on the diagnostic source: the working-tree copy of
`M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino` currently matches the C1
accepted hash exactly, even though `git status` reports it as modified
relative to `HEAD` (`f915b1c9...`). This confirms the C1 acceptance
authority is the **working tree at C1 freeze time**, not `HEAD` — consistent
with this baseline document's instruction not to treat HEAD alone as C1
accepted source authority. Any future edit to this file for C2 (Mode 16)
will diverge the working tree from this frozen hash; that divergence is
expected and is tracked via the C2 source diff authority below.

## C2 source diff authority

```text
BASE:
C1 final freeze accepted source, specifically:
build-temp\usb-lan-isolation\freeze\C1-final-20260818-005403-666bf93b\source\reviewed-files\diagnostic_source\M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino
(sha256=65529BC8A41374FD113FBB844D20432C030B5FBAF051C5EBAB9624C8F060FABB, byte-identical to
the pre-C2 working tree copy verified above)

TARGET:
future C2 working source, specifically:
M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino
(repository root, working tree, after Mode 16 / C2 implementation)
```

Future source review must run the equivalent of:

```text
git diff --no-index -- \
  "build-temp\usb-lan-isolation\freeze\C1-final-20260818-005403-666bf93b\source\reviewed-files\diagnostic_source\M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino" \
  "M5Stack-PS5CoREUsbLanIsolationDiagnostic.ino"
```

to isolate exactly what C2/Mode 16 added relative to the C1 accepted
baseline, independent of any other unrelated local working-tree changes
that may exist outside this file.

No commit was created by this task. This document is evidence/authority
only.

## Marker

```text
P0_3_C2_BASELINE_AUTHORITY_RESOLVED=PASS
```
