# Issue body template (managed region)

`issue-upsert.sh` wraps the body file in the marker and the managed region. Render exactly
this inside the body file; nothing else (a human may add text below the region later, and a
re-sync must leave it byte-identical).

```
**Goal.** <unit goal, one paragraph>

**Requirements.** <R-IDs, comma-separated, or "—">

**Files.**
- `<path>` (create|modify — <one-line purpose>)

**Verification.** <the unit's verification line>

**Depends on.** <#iid list once linked, or "—">
```

Rules: repo-relative paths only; no absolute paths; no implementation code; keep the unit's
own wording (the plan is the authority, the issue is a mirror).
