---
name: ship-mr
description: Open or update the GitLab merge request for the current branch from the plan's units, then hand off to pipeline watching; never merges. Use when the user says "ship it", "open the MR", "push and create the merge request", or a workflow's shipping tail reaches a GitLab remote.
argument-hint: "[--plan <plan-path>] [--draft] [--target <branch>]"
---

# ship-mr

Push the current branch and open — or re-sync — its merge request, with a description
built from the plan units the branch implements, then hand the MR to `watch-pipeline`.
Every write goes through `${CLAUDE_PLUGIN_ROOT}/ops/` under the session identity (the
operator authors the MR). **This skill never merges.** It stops at "ready"; a human merges.

## Inputs

- `--project <group/project>` — always explicit. Derive it from `glab repo view` or the git
  remote (`git remote get-url origin`), then state it in every `ops/` call; never let a script
  infer it from the cwd.
- `--plan <plan-path>` — the plan whose units describe this branch (default: the plan named in
  the repo's `CLAUDE.md`, else ask). `--draft` marks the MR draft. `--target <branch>` defaults
  to the repo's default branch (`glab api projects/<urlenc> | jq -r .default_branch`).
- Issue numbers the user names ("closes #12 and #14") become `Closes #n` lines.

## Procedure

1. **Refuse the wrong starting point.** `git branch --show-current`; if it is the default branch
   (or detached HEAD), stop: this skill ships a feature branch, it never pushes the default
   branch. `git status --porcelain`; anything it lists is NOT pushed by this skill, so list it in
   the report and carry on — stop only when a listed path is one the change needs (a file the
   plan unit names, or one the branch already touches), because then the push would ship an
   incomplete change. Never `git add -A` / `git add .` here; this skill does not commit at all
   (use the commit skill first).
2. **Push.** `git push -u origin HEAD`. A rejected push (non-fast-forward) is reported, not
   forced: never `--force` from this skill.
3. **Build the description from the plan.** `python3 ${CLAUDE_PLUGIN_ROOT}/ops/plan-units.py
   <plan-path>` → units with `id`, `title`, `goal`, `files`. `git diff --name-only
   <target>...HEAD` lists the branch's files; the units whose `files` intersect that list are
   the ones this branch implements. Write the description to a temp file in the session scratch
   dir (`mktemp "${TMPDIR:-/tmp}/silkops-mr.XXXXXX"`), never inline in argv:

   ```
   ## Units
   - **U<N> — <title>**: <goal>
   ## Files
   - `path` …
   Closes #n            (one line per issue the user named)
   ```

   Keep it short; `mr-upsert.sh` adds the provenance marker and wraps the text in the managed
   region, so the reviewer's own paragraphs survive a re-sync.
4. **Re-check for an existing open MR right before create.** `glab api
   "projects/<urlenc>/merge_requests?source_branch=<urlenc branch>&state=opened"`. A result
   with the same source branch means update, never a second MR; `[]` means create. A non-zero
   exit is unknown — resolve auth first, do not guess.
5. **Upsert.** `${CLAUDE_PLUGIN_ROOT}/ops/mr-upsert.sh --project P --source <branch>
   --target <default> --title "<U-IDs — short title>" --description-file <tmp>
   --marker-unit <U-ID or "mr"> --plan <plan basename> --run <run-id> [--draft]`.
   The result carries `action` (created | updated | unchanged), `iid`, `web_url`,
   `head_pipeline_id`. Read `action` back to the user — an `updated` on a branch you thought
   was new means an MR already existed (Step 4 found it).
6. **Print the MR URL and hand off.** Invoke `watch-pipeline` with the `iid` and the same
   `--project`. `watch-pipeline` reports "ready, not merging — a human merges" or the triage;
   this skill has nothing more to do after that.

## Guardrails

- Never merge: no merge command, no merge API call, no "accept" of any kind. Ready is the
  end state.
- Never push the default branch, never force-push, never `git add -A`.
- Description by file, marker inside the managed region only; text outside it is preserved
  byte for byte by `mr-upsert.sh`.
- `--project` stated explicitly on every call; the session identity is the author (no
  settings token anywhere in this flow).
