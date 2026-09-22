---
name: file-residuals
description: File accepted code-review residual findings as GitLab issues on a milestone, deduplicated by run and finding, and post proof notes that close them. Use when the user says "file the residuals", "open issues for the leftover findings", or asks to record review findings as GitLab issues.
argument-hint: "<review-result-path> --findings <n,n,...> --milestone <title> [--project <group/project>]"
---

# file-residuals

Result: one JSON report from `${CLAUDE_PLUGIN_ROOT}/ops/milestone-sync.sh --issues <set.json>`:
`issues[] {unit, iid, action}`. Identity is the marker `plan=adhoc-<result basename>
unit=residual-<key>`, so a rerun yields `unchanged`, never a duplicate. No settings writes;
a closed issue is never edited.

## Steps

1. Read the review result; for each accepted finding number take title, file:line, summary,
   suggested fix. Key = `<review run id or result basename>-<n>`.
2. Write `{"plan": "adhoc-<basename>", "milestone": "<title>", "issues": [{"unit":
   "residual-<key>", "title", "body", "labels": ["residual"]}]}` to a scratch file; body =
   summary, location, fix, `Source: <path>`. Run `ops/milestone-sync.sh --project P --issues <f>
   --run <id>`. The milestone must already exist.
3. Proof, when the operator names the fix: `ops/note.sh --project P --issue <iid> --body-file
   <proof> --marker-unit residual-<key> --plan adhoc-<basename> --run <id> --dedupe-key
   proof-<sha>`, then `glab issue close <iid> -R P` only if open. Closed: note only, no reopen.
4. Report finding → iid → action.

## Guardrails

- The milestone is the caller's; never invent one. Keys are identity; titles may change.
- No run id in the result: key on basename plus git SHA and say so.
