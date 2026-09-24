---
name: watch-pipeline
description: Watch a GitLab merge request's head pipeline or a pipeline id in bounded waits, triage failures against recorded environment facts, retry transient failures once when safe, and report readiness to merge without merging. Use when the user says "watch the pipeline", "is the MR green", "why did the job fail", or after ship-mr opens an MR.
argument-hint: "<mr-iid | pipeline-id> [--project <group/project>] [--wait <seconds>] [--no-note]"
---

# watch-pipeline

Result: one JSON line from `silkops watch` with `status`, `terminal`, `ready`,
`not_ready_reason`, `still_running`, `resume_after_s`, `failed[]` (classification, root_cause,
web_url, first_failure), `retried`, `resume_hint`. Never merges: "ready" is the end state.

## Steps

1. `--project` explicit (remote or URL). Target: `--mr <iid>` or `--pipeline <id>`; a URL gives both.
   `silkops watch --project P --mr <iid> --wait 300 --interval 20 --note --plan <basename> --run <id>`.
   No `--retry` on the first call.
2. Act on the verdict, one line each:
   - `still_running`: normal for a long pipeline. Say `waited_s` of `expected_duration_s`, run
     `resume_hint` verbatim with `--wait` = `resume_after_s` (under the tool timeout) until
     `terminal`. Never a shell `timeout` or a hand poll. `waiting_for: head_pipeline` = just
     pushed; resume the same way, keeping `--mr`.
   - `ready`: say exactly "ready, not merging — a human merges", MR URL, pipeline id. Stop.
   - success but not ready: quote `not_ready_reason` and the human step. Stop.
   - `failed`: per job in `failed[]`: name, `web_url`, `fact`/`class`/`retry_safe`/`reason`,
     `first_failure`, the redacted `root_cause` lines; `--note` put the triage on the MR.
   - `canceled|skipped|manual`: terminal, not ready; name the manual job to start.
   - `superseded`: report the old outcome, switch to `head_pipeline_id`; never retry it.
   - `errors[]`: a jobs listing failed; the snapshot is stale, not green.
3. Retry once (`--retry`) only when every failed job is `transient` and `retry_safe`, the
   pipeline is current and `retry_count` is 0. Exit 6: the guard refused; stop.
4. Report: pipeline id, URL, verdict, triage, retries, next human step.

## Guardrails

- No merge, cancel or manual-job call. Quoted trace lines passed `redact`.
- Session identity (`SILKOPS_CI_TOKEN` under CI); never the settings token. GitHub: a PR's
  workflow runs are `runs[]`, the first one is the checkpoint (`docs/providers.md`).
