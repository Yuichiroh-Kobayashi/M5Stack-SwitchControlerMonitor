# Gate C1 Final Archive — Errata

This document records a known documentation defect inside the accepted Gate C1
final freeze archive. The accepted payload and hash evidence are unchanged.
This errata is metadata/documentation only.

## Actual generation

```text
actual generation:
C1-final-20260818-005403-666bf93b
```

## Archive identity (unchanged, re-verified)

```text
ZIP path (repository-local source):
build-temp\usb-lan-isolation\freeze\C1-final-20260818-005403-666bf93b.zip

ZIP size:
4482569

ZIP SHA-256:
41071B6A948768E179C76627A4132C311888491A0DF0510B9533A6CBBEFC12E2
```

Re-verified by direct `Get-FileHash -Algorithm SHA256` against the
repository-local ZIP on 2026-08-19: size and SHA-256 both match the values
above and the values recorded at C1 acceptance time.

## Issue

`FINAL_ACCEPTANCE.md` (inside the frozen ZIP, at the archive root) contains an
unexpanded template placeholder on its second content line:

```text
Freeze generation: $generationId
```

This literal `$generationId` token was never substituted with the actual
freeze generation id (`C1-final-20260818-005403-666bf93b`) at freeze-script
run time. All other identity fields inside `FINAL_ACCEPTANCE.md` (branch,
HEAD, runner v3 hash, active reviewed manifest hash, trial ids, firmware
hashes) are populated correctly and were independently cross-checked against
`archive-manifest.csv` and the repository-local
`C1-reviewed-source-manifest.csv` during this task's read-only inspection.

## Impact

```text
impact:
metadata/documentation only
accepted payload/hash evidence unchanged
```

The unexpanded placeholder does not affect:

- The accepted S1/T1 trial evidence (`accepted/C1-S1-...`, `accepted/C1-T1-...`).
- Any file size or SHA-256 recorded in `archive-manifest.csv` or
  `source/C1-reviewed-source-manifest.csv`.
- The `GATE_C1_COMPLETE_PASS` classification.
- The ZIP-level size/SHA-256 identity used as the C1 acceptance authority.

It only degrades the human-readability of the freeze generation id inside
`FINAL_ACCEPTANCE.md` itself. The correct generation id is recoverable from
the ZIP filename, the containing directory name inside the ZIP
(`C1-final-20260818-005403-666bf93b/`), and this errata document.

No file inside the accepted ZIP was modified to produce this errata record.
The ZIP remains byte-for-byte as originally frozen (re-verified above).

## External archive copy (P0-1)

```text
destination path:
C:\Users\yu-ichirou\Documents\CoRE-Evidence-Archive\gate-c1\C1-final-20260818-005403-666bf93b.zip

size:
4482569

SHA-256:
41071B6A948768E179C76627A4132C311888491A0DF0510B9533A6CBBEFC12E2

verification:
PASS (source and destination size and SHA-256 identical; source ZIP left unmodified)
```

## Marker

```text
P0_1_C1_EXTERNAL_ARCHIVE_COPY_VERIFIED=PASS
P0_2_C1_FINAL_ARCHIVE_ERRATA_RECORDED=PASS
```
