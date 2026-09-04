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

**Read `references/issue-body.md` before Step 3.**

## Inputs

- `<plan-path>` — a plan with `### U<N>.` units (`artifact_readiness: implementation-ready`).
- `--project <group/project>` — always explicit. Derive it from `glab repo view` or the git
  remote, then state it in every call; never let a script infer it from the cwd.
- `--milestone <title>` — defaults to the plan's `title:` frontmatter.

## Procedure

1. **Parse the plan.** `python3 ${CLAUDE_PLUGIN_ROOT}/ops/plan-units.py <plan-path>` → units
   with `id`, `title`, `goal`, `requirements`, `depends_on`, `files`, `verification`. Stop with
   the parser's message if it reports zero units or warnings about the Unit Index.
2. **Find or create the milestone.** `glab api projects/<urlenc>/milestones?search=<title>`;
   match on exact title, else create with `glab api -X POST projects/<urlenc>/milestones
   -f title=… -f description=@<file>` where the description carries the marker
   (`${CLAUDE_PLUGIN_ROOT}/ops/lib/prelude.sh` → `silkops_marker <plan-basename> milestone <run-id>`).
   The run id is a short timestamp-based id you generate once per invocation.
3. **Upsert one issue per unit** (dependency order is irrelevant here):
   `ops/issue-upsert.sh --project P --marker-unit U<N> --plan <basename> --run <run-id>
   --title "U<N> — <unit title>" --body-file <rendered body> --milestone <title> --labels u<N>,silkops`.
   Body per `references/issue-body.md`: goal, requirements, files, verification, all inside the
   managed region. Collect `iid` per unit from each result; `action` tells you
   created/updated/unchanged.
4. **Link dependencies (second pass).** For each `depends_on` edge, `ops/issue-link.sh
   --project P --source <dep iid> --target <unit iid> --type blocks`. When the result carries
   `fallback: relates_to`, append its `depends_on_line` inside the managed region of the
   dependent issue and re-run the upsert for that unit (one extra write, idempotent).
5. **Re-sync semantics.** On a later run against a changed plan: units still present are
   upserted (only the managed region changes; human text outside it survives); a unit that
   disappeared → if its issue is open, post a note via `ops/note.sh` naming the plan file's
   git SHA and close it (`glab issue close <iid> -R P`); if it is already closed, post the
   note only. Never reopen. A run with no plan changes performs zero writes and says so.
6. **Report** a table: unit → issue iid → action → blocked-by. Name the milestone URL.

## Guardrails

- Identity is by marker, then label `u<N>`; never by title.
- Closed issues are never edited (`issue-upsert.sh` exits 7; do not work around it).
- Every object this skill writes carries the marker; that is what `scripts/audit-milestone.sh`
  checks.
- No `glab api` calls outside the ones named here; if you need another operation, it belongs
  in `ops/`, not in this skill.
