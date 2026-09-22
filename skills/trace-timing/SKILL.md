---
name: trace-timing
description: Section-time a GitLab job trace and rank its steps by wall-clock so the slow part is named with numbers. Use when the user says "where does the time go in this job", "time the trace", "why is this pipeline slow", or asks for before/after evidence on a job.
argument-hint: "<job-id | job-url> [--project <group/project>] [--top <n>]"
---

# trace-timing

Result: two headline numbers (total wall-clock, largest step) and one ranked table, from
`python3 ${CLAUDE_PLUGIN_ROOT}/ops/trace.py timing <trace-file> --top <n>` → `total_s`,
`largest_section`, `largest_step`, `sections[]`, `steps[]`, `has_timestamps`. Read-only.

## Steps

1. `--project` explicit (remote or the job URL). Fetch the trace to the scratch dir, never into
   the conversation: `glab api "projects/<urlenc>/jobs/<id>/trace" > $TMPDIR/trace-<id>.log`.
2. Run `trace.py timing` on the file.
3. Render: `total: 281.9 s · largest step: docker build … (162.3 s, 58 %)`, then a table
   `| # | step (trimmed ~70 chars) | duration | share |` with `share = duration_s / total_s`, then
   the sections table the same way (it tells whether time is in the script or in image pull and
   artifact upload).
4. Two jobs: render both, then a delta table keyed on step command (sections on name):
   `before`, `after`, `Δ s`, `Δ %`; headline `total before → after (Δ)`; one-sided rows as
   `new` / `gone`. Quote job and pipeline ids under it.
5. One or two sentences: which step dominates, script work or runner overhead, and the recorded
   fact when one applies (`.silkops/facts.json`, overlay, core) rather than a guess.

## Without timestamps

`has_timestamps: false` (runner < 17): `steps` is empty and `largest_step` null. Render the
sections table only, say so, invent nothing. Section epochs are still exact.

## Guardrails

- Quoted trace lines pass `redact` first (`. ${CLAUDE_PLUGIN_ROOT}/ops/lib/prelude.sh; redact < file`).
- No retry, no cancel, nothing written; `--project` explicit on every call.
