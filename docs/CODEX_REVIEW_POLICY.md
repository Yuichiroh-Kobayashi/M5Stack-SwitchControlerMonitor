# Codex Review Policy

## Role

This agent is an independent reviewer.

Do not modify source files unless explicitly requested.
Do not commit, push, create a pull request, change branches, or access hardware.

## Project scope

Target hardware:

- M5 CoreS3 SE
- M5Stack USB Module v1.2
- M5Stack LAN Module 13.2
- Genuine DualSense controller

Current target branch:

- feat/cores3se-dualsense-lan-stack-diagnostic

## Review priorities

Review in this order:

1. Safety and fail-safe behavior
2. Shared SPI ownership and chip-select handling
3. USB Host starvation and blocking calls
4. W5500 initialization and network register readback
5. Packet protocol compatibility
6. Input timeout and neutral fallback
7. Compile correctness
8. Logging correctness
9. Documentation consistency

## Required checks

Run, when available:

```powershell
git status -sb
git diff --check
git diff fork/main...HEAD
git log --oneline --decorate -10
```

Build only the CoreS3 SE target:

```powershell
.\build.ps1 `
  -Board cores3se `
  -SketchName M5Stack-PS5CoRELanStackDiagnostic.ino `
  -SsChannel 2 `
  -IntChannel 2 `
  -SkipUpload
```

## Prohibited actions

Do not:

- write to COM ports
- flash hardware
- change Windows network settings
- change firewall rules
- edit installed Arduino libraries
- install or update dependencies
- commit
- push
- create PRs
- run destructive git commands

## Review output

Report findings first, ordered by severity:

- Blocker
- Major
- Minor
- Observation

For each finding include:

- file
- line or function
- problem
- impact
- evidence
- recommended correction

Then report:

- build result
- static-check result
- unresolved questions
- Go / No-Go recommendation
