---
name: after-merge
description: Housekeeping after a human merged a GitLab merge request: sync and prune the branch, confirm the linked issues closed, check an older sibling MR's lines survived, and watch the default-branch pipeline. Use when the user says "merged", "it's merged, clean up", "after the merge", or right after ship-mr's MR was merged.
argument-hint: "<mr-iid> [--project <group/project>] [--sibling <mr-iid>]"
---

# after-merge

Result: one JSON line from `${CLAUDE_PLUGIN_ROOT}/ops/after-merge.sh` with `merged`,
`branch_deleted`, `closes_issues[] {iid, state}`, `issues_still_open[]`, `sibling {checked,
missing[]}`, `default_branch_pipeline` and a `resume_hint` for `watch-pipeline`. Never merges;
exit 7 when the MR is not merged yet.

## Steps

1. `--project` explicit. `ops/after-merge.sh --project P --mr <iid> [--sibling <older iid>]`
   from the checkout: fetch, default branch fast-forwarded, merged local branch deleted, refs
   pruned. A non-fast-forward default branch is refused and left untouched.
2. `issues_still_open` non-empty: the MR named them but GitLab did not close them (no `Closes`
   keyword, or a different project); say which, do not close them from here.
3. `sibling.missing` non-empty: the conflict resolution kept only one side; name the lines and
   the older MR, and stop for a human. Pass `--sibling` whenever `ship-mr` reported `siblings[]`.
4. `resume_hint` present: hand it to `watch-pipeline` so the default-branch pipeline is watched
   to its verdict.
5. Report: branch state, issues, sibling verdict, pipeline.

## Guardrails

- No merge, no issue close, no force; `--ff-only` and `branch -d` only.
- Session identity; `--project` explicit on every call.
