---
name: trace-timing
description: Section-time a GitLab job trace and rank its steps by wall-clock so the slow part is named with numbers. Use when the user says "where does the time go in this job", "time the trace", "why is this pipeline slow", or asks for before/after evidence on a job.
argument-hint: "<job-id | job-url> [--project <group/project>] [--top <n>]"
---

# trace-timing

Name the slow part of a job with numbers: fetch its trace, let
`${CLAUDE_PLUGIN_ROOT}/ops/trace.py timing` rank the runner sections and the echoed `$ command`
steps by duration, and render the result as a table with two headline numbers — total
wall-clock and the largest step. Read-only: no write to GitLab, session identity throughout.

## Inputs

- `--project <group/project>` — always explicit. Derive it from `glab repo view`, the git
  remote, or the job URL's path, then state it in every call; never let a script infer it.
- `<job-id | job-url>` — a job id, or `https://gitlab.com/<group/project>/-/jobs/<id>` (the
  URL gives both the project and the id). For a before/after comparison, two of them.
- `--top <n>` — rows per table (default 10; `0` = all).

## Procedure

1. **Fetch the trace to a file** in the session scratch dir — never into the conversation:
   `glab api "projects/<urlenc project>/jobs/<id>/trace" > "$TMPDIR/trace-<id>.log"`
   (session identity; in CI, `SILKOPS_CI_TOKEN` is exported first). Traces can run to hundreds
   of KB; keep them on disk.
2. **Time it.** `python3 ${CLAUDE_PLUGIN_ROOT}/ops/trace.py timing "$TMPDIR/trace-<id>.log"
   --top <n>` → `total_s`, `largest_section`, `largest_step`, `sections[]` and `steps[]`
   (each `{name|command, duration_s, …}` sorted by duration), `has_timestamps`, `step_count`.
3. **Render.** Two headline lines, then one table:

   ```
   total: 281.9 s · largest step: docker build … (162.3 s, 58 %)

   | # | step (command, trimmed to ~70 chars) | duration | share |
   |---|--------------------------------------|---------:|------:|
   | 1 | docker build … | 162.3 s | 58 % |
   ```

   `share` = `duration_s / total_s`. Below it, the sections table (`prepare_executor`,
   `get_sources`, `step_script`, `upload_artifacts_on_success`, …) the same way — the section
   table tells whether the time is in the script at all, or in image pull / artifact upload.
4. **Before/after (two jobs).** Run Steps 1–3 for both, then a delta table keyed on the step
   command (sections keyed on name): `before`, `after`, `Δ s`, `Δ %`; the headline becomes
   `total before → after (Δ)`. Steps present on one side only are listed as `new` / `gone`.
   Quote job ids and pipeline ids under the table so the evidence is traceable.
5. **Say what it means.** One or two sentences: which step dominates, whether it is the
   script's own work or runner overhead, and — when a recorded fact applies — point at
   `${CLAUDE_PLUGIN_ROOT}/facts/environment.json` / the runbook rather than guessing.

## Degradation without timestamps

Per-command timing needs the runner's per-line timestamps (GitLab SaaS, runner ≥ 17). When
`has_timestamps` is false the JSON carries `notice: "no per-line timestamps; sections only"`,
`steps` is empty and `largest_step` is null: render the sections table only, say so explicitly,
and do not invent step durations. The section epochs (`section_start:<epoch>:<name>`) are
still exact.

## Guardrails

- Trace lines quoted in the answer pass through the prelude's `redact` first
  (`. ${CLAUDE_PLUGIN_ROOT}/ops/lib/prelude.sh; redact < file`); timing tables contain
  commands, and commands can carry credentials.
- Read-only: no retry, no cancel, nothing merged or written from this skill.
- `--project` explicit on every call.
