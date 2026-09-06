# CoRE GitHub Issue workflow

Adapted as guidance from the user's VAMeter-Edu GitHub Issue Management Policy Rev.2 (2026-08-23), not a transfer of that document's product-specific instructions. AGENTS.md and explicit user authorization remain authoritative. CoRE changes belong to this repository, not the VAMeter/D2B repositories named in the reference.

- Create Issues for durable defects, features, decisions and validation obligations. Put individual Gates and attempts in checklists/evidence, not separate Issues.
- Use exactly one `type:*`, one or more `area:*`, and exactly one `state:*` while open. Use priority only for ordering. Remove state labels on closure.
- Record purpose, exact baseline, FACT/HYP/VALUE, scope/non-goals, testable acceptance, validation levels, safety/resources, withdrawal conditions, dependencies, evidence name/hash and final claim boundary.
- Ready requires known ownership, resolved scope/dependencies, verified source authority, testable acceptance, and identified physical operations. Hardware qualification belongs to an open validation owner.
- Distinguish SOURCE_REVIEWED, HOST_TESTED, TARGET_BUILD_PASS and physical qualification. A build does not qualify a controller.
- Close only after accepted changes are merged and required checks pass, or a documented not-planned decision. A software-only child may transfer physical validation to an explicitly linked open owner. The integration parent remains open until its physical and documentation criteria pass.
- Publish relative artifact names and hashes in Issues. Keep raw device logs, credentials and machine-specific capture inventories outside Git. Do not overwrite failed evidence generations.
- Do not merge, release or flash merely to close an Issue. Record exact candidate and device identity before any separately authorized upload; preserve hardware safety rules and report final device state.

The user's 2026-09-06 request authorizes committing/pushing relevant current work, creating development Issues, and progressing implementation/nonphysical validation. It does not request a release, merge to main, or a firmware upload to an unverified device.
