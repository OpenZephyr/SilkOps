---
name: milestone-from-plan
description: Turn an implementation-ready plan's units into a GitLab milestone with one dependency-linked issue per unit, or re-sync an existing milestone after the plan changed. Use when the user says "create the milestone for this plan", "file issues from the plan", "sync the milestone", or hands over a plan path and asks for GitLab issues.
argument-hint: "<plan-path> [--project <group/project>] [--milestone <title>]"
---

# milestone-from-plan

Result: one JSON report from `${CLAUDE_PLUGIN_ROOT}/ops/milestone-sync.sh --plan <path>`:
`milestone {title, iid, action}`, `issues[] {unit, iid, action, blocked_by}`, `links[]`. Identity
is the marker, then the `u<N>` label, never the title. Closed issues are never edited (exit 7).

## Steps

1. `ops/milestone-sync.sh --project P --plan <path> --run <id> [--milestone <title>] --dry-run`:
   read milestone action, unit → iid → action, links. Then the same call without `--dry-run`.
   The script parses the units, upserts the milestone (title from the plan's `title:`) and every
   issue, links every `depends_on` edge as `blocks`. Never loop over units in the session.
2. `fallback: relates_to` on a link means the project has no blocking links; say so. Exit 7
   (closed milestone or issue, ambiguous identity): stop and ask; never create a look-alike.
3. Re-sync after the plan changed: the same call. Only managed regions change, human text
   survives, an unchanged plan is zero writes. A unit that left the plan: `ops/note.sh` naming
   the plan's git SHA, then `glab issue close <iid> -R P` if open; never reopen.
4. Report the milestone URL and the unit → iid → action table from the JSON.

## Guardrails

- Every object carries the marker (`scripts/audit-milestone.sh` checks it).
- No raw `glab api` calls here; a missing operation belongs in `ops/`, not in this skill.
