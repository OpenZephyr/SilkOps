---
name: file-residuals
description: File accepted code-review residual findings as GitLab issues on a milestone, deduplicated by run and finding, and post proof notes that close them. Use when the user says "file the residuals", "open issues for the leftover findings", or asks to record review findings as GitLab issues.
argument-hint: "<review-result-path> --findings <n,n,...> --milestone <title> [--project <group/project>]"
---

# file-residuals

File accepted code-review residuals as GitLab issues on a milestone, deduplicated by review
run and finding number, and post proof notes that close them when the fix lands. No settings
writes; never edits a closed issue.

## Inputs

- `<review-result-path>` — the `ce-code-review` result (markdown or `mode:agent` JSON).
- `--findings <n,n,...>` — the finding numbers the operator accepted as residual work.
- `--milestone <title>` — the milestone to attach to (must exist; this skill does not create one).
- `--project <group/project>` — explicit, always.

## Procedure

1. **Read the review result.** Extract for each accepted number: title, file:line, summary,
   suggested fix. The dedupe key is `<review run id or result basename>-<n>`.
2. **One call for the whole set.** Write `{"plan": "adhoc-<result basename>", "milestone":
   "<title>", "issues": [{"unit": "residual-<key>", "title", "body", "labels": ["residual"]}]}`
   to a scratch file and run `${CLAUDE_PLUGIN_ROOT}/ops/milestone-sync.sh --project P --issues
   <file> --run <run-id>`. Body: finding summary, location, suggested fix, "Source: <path>". The
   report lists finding → iid → action; a second run yields `unchanged`, never a duplicate.
3. **Proof notes.** When the operator says a residual is fixed (MR or commit named):
   `ops/note.sh --project P --issue <iid> --body-file <proof> --marker-unit residual-<key>
   --plan <b> --run <run-id> --dedupe-key proof-<sha>`; then close the issue with
   `glab issue close <iid> -R P` only if it is open. If it is already closed, the note is
   posted and nothing else changes (no reopen, no edit).
4. **Report** finding → issue iid → action.

## Guardrails

- The tracker is the milestone the caller names; do not invent one.
- The marker is the identity. Titles may be edited by humans; keys may not.
- If the review result has no run id, use its basename plus git SHA as the key prefix and say so.
