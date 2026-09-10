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
2. **Upsert one issue per finding.**
   `${CLAUDE_PLUGIN_ROOT}/ops/issue-upsert.sh --project P --marker-unit residual-<key>
   --plan <result basename> --run <run-id> --title "<finding title>" --body-file <f>
   --milestone <title> --labels residual,silkops`.
   Body (inside the managed region): finding summary, location, suggested fix, "Source:
   <review result path>". A second run with the same key yields `action: unchanged` or an
   existing issue — report "already filed as #n"; never create a duplicate.
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
