---
title: Delivery plan
type: feat
---
# Delivery plan

Two milestones, five units, one cross-milestone dependency (M2-01 on M1-02).

## M1 · Foundations

### M1-01 Repo scaffold
- **Scope:** lay out the directories and the build entry point.
- **Acceptance:** `make build` runs on a clean clone.
- **Depends on:** none · **Labels:** `build`, `infra`

### M1-02 Settings loader
- **Scope:** read `settings.json` with defaults.
- **Acceptance:**
  - missing file → defaults
  - malformed file → exit 2
- **Depends on:** M1-01 **Labels:** `core`

### M1-03: Logging
- **Scope:** one structured log line per request.
- **Acceptance:** lines parse as JSON.
- **Depends on:** M1-01

## M2: Delivery

### M2-01 Packaging
- **Scope:** build the installer for every target.
- **Acceptance:** an installer per OS in `dist/`.
- **Depends on:** M1-02, M1-03 · **Labels:** `release`

### M2-02 Release notes
- **Scope:** generate the notes from the merged MRs.
- **Acceptance:** `CHANGELOG.md` has a section for the tag.
- **Depends on:** M2-01
- **Labels:** `docs`
