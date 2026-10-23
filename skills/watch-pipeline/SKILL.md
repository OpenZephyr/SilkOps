---
name: watch-pipeline
description: Watch a GitLab merge request's head pipeline or a pipeline id in bounded waits, triage failures against recorded environment facts, retry transient failures once when safe, and report readiness to merge without merging. Use when the user says "watch the pipeline", "is the MR green", "why did the job fail", or after ship-mr opens an MR.
argument-hint: "<mr-iid | pipeline-id> [--project <group/project>] [--wait <seconds>] [--no-note]"
---

# watch-pipeline

Result: one JSON line from `silkops watch`: `status`, `terminal`, `ready`, `not_ready_reason`,
`expected_duration_s`/`expected_source`, `wait_s`, `resume_after_s`, `warnings[]`,
`default_branch`, `failed[]`, `retried`, `resume_hint`. Never merges.

## Steps

1. `--project` explicit. `silkops watch --project P --mr <iid> --note --plan <basename>
   --run <id>` (or `--pipeline <id>`). No `--wait`: the budget is the expected duration (ref,
   default-branch or facts history) plus a margin, capped at 540 s. No `--retry` at first.
2. Verdict, one line each:
   - `still_running`: say `waited_s` of `expected_duration_s`; run `resume_hint` verbatim with
     `--wait` = `resume_after_s` until `terminal` (also for `waiting_for: head_pipeline`);
     no shell `timeout`, no hand poll.
   - `ready`: say exactly "ready, not merging — a human merges", MR URL, pipeline id. Stop.
   - success, not ready: quote `not_ready_reason`; `still checking` resumes as above.
   - `failed`: per job in `failed[]`: name, `web_url`, `fact`/`class`/`retry_safe`/`reason`,
     `first_failure`, redacted `root_cause` lines; `--note` posted the triage.
   - `canceled|skipped|manual`: terminal, not ready; name the manual job.
   - `superseded`: report it, switch to `head_pipeline_id`; never retry it.
   - `errors[]`: a jobs listing failed; stale snapshot, not green.
   - `warnings[]` (allowed failures): quote each `message`; never blocking.
   - `default_branch`: say its `status`; not success: name `failed_jobs[]` (main is red
     before this MR). `null` = unread.
3. `--retry` once, only when every failed job is `transient` and `retry_safe`, the pipeline
   is current and `retry_count` is 0. Exit 6: the guard refused; stop.
4. Report: pipeline id, URL, verdict, warnings, default branch, triage.

## Guardrails

- No merge, cancel or manual-job call. Quoted trace lines passed `redact`. Session identity,
  never the settings token. GitHub: `runs[]`, the first is the checkpoint (`docs/providers.md`).
