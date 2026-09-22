---
name: milestone-from-plan
description: Turn an implementation-ready plan's units into a GitLab milestone with one dependency-linked issue per unit, or re-sync an existing milestone after the plan changed. Use when the user says "create the milestone for this plan", "file issues from the plan", "sync the milestone", or hands over a plan path and asks for GitLab issues.
argument-hint: "<plan-path> [--project <group/project>] [--milestone <title>]"
---

# milestone-from-plan

Turn an implementation-ready plan into a GitLab milestone with one issue per implementation
unit, dependency-linked, marker-identified, and re-syncable. Every write goes through
`${CLAUDE_PLUGIN_ROOT}/ops/`; this skill performs no settings writes and never edits a
closed issue.

The issue body shape is `references/issue-body.md`; `milestone-sync.sh` renders it.

## Inputs

- `<plan-path>` — a plan with `### U<N>.` units (`artifact_readiness: implementation-ready`).
- `--project <group/project>` — always explicit. Derive it from `glab repo view` or the git
  remote, then state it in every call; never let a script infer it from the cwd.
- `--milestone <title>` — defaults to the plan's `title:` frontmatter.

## Procedure

1. **One call.** `${CLAUDE_PLUGIN_ROOT}/ops/milestone-sync.sh --project P --plan <plan-path>
   --run <run-id> [--milestone <title>] --dry-run` first: read the report (milestone action,
   unit → iid → action, links), then run it again without `--dry-run`. It parses the units,
   upserts the milestone and every issue, links every `depends_on` edge as `blocks`, and returns
   one JSON report. Never loop over units in the session; the script owns the loop.
2. **Read the report.** `milestone.action`, `issues[] {unit, iid, action, blocked_by}`,
   `links[] {source_iid, target_iid, link_type, existing, fallback}`. A `fallback: relates_to`
   means the project has no blocking links; say so. A closed milestone or issue exits 7: stop
   and ask, never create a look-alike.
3. **Re-sync.** Run the same call after the plan changes: only managed regions change, human
   text survives, an unchanged plan performs zero writes. A unit that disappeared from the
   plan: post a note with `ops/note.sh` naming the plan's git SHA and close the issue with
   `glab issue close <iid> -R P` if open; never reopen.
4. **Report** the milestone URL and the unit → iid → action table from the JSON, nothing more.

## Guardrails

- Identity is by marker, then label `u<N>`; never by title.
- Closed issues are never edited (`issue-upsert.sh` exits 7; do not work around it).
- Every object this skill writes carries the marker; that is what `scripts/audit-milestone.sh`
  checks.
- No raw `glab api` calls in this skill; every read or write is one of the `ops/` scripts named
  here (`plan-units.py`, `milestone-upsert.sh`, `issue-upsert.sh`, `issue-link.sh`, `note.sh`).
  If you need another operation, it belongs in `ops/`, not in this skill.
