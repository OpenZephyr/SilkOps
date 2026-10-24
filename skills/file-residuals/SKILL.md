---
name: file-residuals
description: File accepted code-review residual findings as issues on the host (GitLab, GitHub or Gitea), deduplicated by run and finding, and post proof notes that close them. Use when the user says "file the residuals", "open issues for the leftover findings", or asks to record review findings as issues.
argument-hint: "<review-result-path> --findings <n,n,...> [--milestone <title>] [--project <group/project>]"
---

# file-residuals

Result: one JSON report from `silkops milestone-sync --issues <set.json>`:
`issues[] {unit, iid, action, identity}`. Identity is the marker `plan=adhoc-<result basename>
unit=residual-<key>` (or, with markers off, the unit label; on GitHub without push access a
`silkops-id:` footer), so a rerun yields `unchanged`, never a duplicate. No settings writes;
a closed issue is never edited.

## Steps

1. Read the review result; for each accepted finding number take title, file:line, summary,
   suggested fix. Key = `<review run id or result basename>-<n>`.
2. Write `{"plan": "adhoc-<basename>", "milestone": <title or null>, "issues": [{"unit":
   "residual-<key>", "title", "body", "labels": ["residual"]}]}` to a scratch file; body =
   summary, location, fix, `Source: <path>`. Write the location as `{{link:<path>:<a>-<b>}}`:
   milestone-sync turns it into a permalink pinned at HEAD (`--sha` pins another commit).
   Run `silkops milestone-sync --project P --issues <f> --run <id>` (`--dry-run` first on someone
   else's repo: it shows the exact text). `--milestone` only when the operator can create one
   (push access); otherwise file without and say so.
3. Proof, when the operator names the fix: `silkops note --project P --issue <iid> --body-file
   <proof> --marker-unit residual-<key> --plan adhoc-<basename> --run <id> --dedupe-key
   proof-<sha>`, then `silkops issue-close --project P --iid <iid>` (exit 7 = already closed: note
   only, no reopen).
4. Report finding → iid → action, and `labels_applied: false` when the host dropped labels.

## Guardrails

- Before filing, run `verify-findings`: take only its `pass_through[]`, body text carries the
  corrected claim and its evidence pointers, not the review's original wording.
- The milestone is the caller's; never invent one. Keys are identity; titles may change.
- No run id in the result: key on basename plus git SHA and say so.
- No raw `glab`/`gh` calls here; a missing operation belongs in `ops/`, not in this skill.
