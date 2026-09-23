---
name: ship-mr
description: Open or update the GitLab merge request for the current branch from the plan's units, then hand off to pipeline watching; never merges. Use when the user says "ship it", "open the MR", "push and create the merge request", or a workflow's shipping tail reaches a GitLab remote.
argument-hint: "[--plan <plan-path>] [--draft] [--target <branch>]"
---

# ship-mr

Result: one JSON line from `silkops mr-upsert` with `action` (created|updated|unchanged),
`iid`, `web_url`, `head_pipeline_id`, `identity`, then a hand-off to `watch-pipeline`. This skill
never merges and never commits; the `commit` skill runs first.

## Steps

0. Pre-flight once: `silkops token-check --project P --expect-role Developer`; read `operator`,
   `in_operator_group` (disclosure default) and `siblings[]` later from the upsert result.
1. `git branch --show-current`: the default branch or a detached HEAD stops here. `git status
   --porcelain`: unrelated paths are listed in the report, not a stop; stop only when a listed
   path is one the change needs. Never `git add -A`.
2. `git push -u origin HEAD`. A rejected push is reported, never forced.
3. Description to a scratch file (never argv): units from `silkops plan-units <plan>` whose `files`
   intersect `git diff --name-only <target>...HEAD`; `## Units` (U-ID, title, goal), `## Files`,
   one `Closes #n` per issue the user named. Short: the marker and managed region are added by
   the script, so reviewer text outside it survives a re-sync.
4. `silkops mr-upsert --project P --source <branch> --target <default> --title "<U-IDs — title>"
   --description-file <f> --marker-unit <U-ID|mr> --plan <basename> --run <id> [--draft]`.
   It finds an open MR for the branch first; `updated` on a branch you thought new means one existed.
5. Print `web_url`, then invoke `watch-pipeline` with the `iid` and the same `--project`.

## Disclosure

- Outside the operator's group (`token-check.sh` reports it), every write runs with
  `SILKOPS_MARKER=off`: identity by branch, description verbatim, nothing names the harness.

## Guardrails

- No merge call of any kind; never push the default branch; never force-push.
- `--project` explicit on every call; session identity, never the settings token.
