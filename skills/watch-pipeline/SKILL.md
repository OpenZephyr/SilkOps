---
name: watch-pipeline
description: Watch a GitLab merge request's head pipeline or a pipeline id in bounded waits, triage failures against recorded environment facts, retry transient failures once when safe, and report readiness to merge without merging. Use when the user says "watch the pipeline", "is the MR green", "why did the job fail", or after ship-mr opens an MR.
argument-hint: "<mr-iid | pipeline-id> [--project <group/project>] [--wait <seconds>] [--no-note]"
---

# watch-pipeline

Watch one pipeline to a verdict: ready, failed (with a triage), terminal-but-not-ready, or
still running with a resume hint. The loop is `${CLAUDE_PLUGIN_ROOT}/ops/watch.sh`; this skill
resolves the target, reads its JSON, and decides what to do with the verdict. **It never
merges** — "ready" is where it stops and a human takes over. Facts behind each classification
live in `${CLAUDE_PLUGIN_ROOT}/facts/environment.json`; the runbook
(`${CLAUDE_PLUGIN_ROOT}/references/runbook.md`) explains them in prose.

## Inputs

- `--project <group/project>` — always explicit. Derive it from `glab repo view` or the git
  remote, then state it in every `watch.sh` call; never let a script infer it from the cwd.
- Target: an MR iid (`!7` or `7`), a pipeline id (`--pipeline 501`, or a bare number you were
  told is a pipeline), or a GitLab URL — `.../-/merge_requests/<iid>` → `--mr <iid>`,
  `.../-/pipelines/<id>` → `--pipeline <id>`. The URL's `group/project` becomes `--project`.
- `--wait <seconds>` — one bounded wait per invocation (default 300; keep it under the
  session's own tool timeout). `--no-note` disables the triage note (default on for MRs).

## Procedure

1. **Resolve and run one bounded wait.**
   `${CLAUDE_PLUGIN_ROOT}/ops/watch.sh --project P --mr <iid> --wait 300 --interval 20 --note
   --plan <plan basename> --run <run-id>` (or `--pipeline <id>`; `--note` needs `--mr`).
   Do not pass `--retry` on the first call: read the classification first.
2. **Read the JSON.** Keys that drive the decision: `status`, `terminal`, `ready`,
   `detailed_merge_status`, `superseded`, `still_running`, `changes`, `failed[]`
   (`classification` + `root_cause` + `web_url` + `first_failure`), `retried`, `retry_skipped`, `retry_unsafe`, `notes`,
   `resume_hint`. Exit codes: 0 report (terminal or still running), 6 retry refused as unsafe,
   5 not found / no head pipeline yet (the MR was just pushed — wait a moment and re-run).
3. **Act on the verdict.**
   - **`still_running: true`** — report the `changes` since the last poll (job → status) and
     loop: run Step 1 again. Across sessions, resume with the `resume_hint` verbatim
     (`watch.sh --project P --mr <iid> --pipeline <id>`): the pipeline id is the checkpoint,
     the `--mr` keeps the superseded guard and merge status on the resumed watch, no local
     state is needed. Never drop `--mr` from the hint; a bare `--pipeline` with `--retry`
     resolves the MR from the pipeline and refuses the retry (`no_mr_context`) when it cannot.
   - **`errors[]` non-empty** — a jobs listing failed on the named poll; the report carries the
     previous poll's job snapshot, not an empty one. Say so; do not read `failed: []` as green.
   - **`ready: true`** — say exactly: "ready, not merging — a human merges", with the MR URL,
     the pipeline id and `detailed_merge_status: mergeable`. Stop. Do not call anything else.
   - **terminal, `status: success`, `ready: false`** — report `detailed_merge_status` verbatim and
     what it means (`need_rebase` → rebase and re-push; `draft_status` → un-draft;
     `discussions_not_resolved` → threads to resolve; `not_approved` → approval outstanding;
     `ci_still_running` → a newer pipeline is running, watch that one). Stop.
   - **`status: failed`** — for each entry in `failed[]` present: job name and id, its `web_url`,
     the classification (`fact`, `class`, `transient`, `retry_safe`, `reason`, `step` — the job
     name when no fact matched), `first_failure` when non-null (the first pytest `FAILED ` line)
     and the
     `root_cause` lines (already redacted — paste them, never the raw trace), plus the fact's
     `explanation` from the facts file. Then decide about a retry (Step 4). When `--note` was on,
     the triage note is already on the MR (`notes[]`, deduplicated per pipeline and job).
   - **`status: canceled | skipped | manual`** — terminal, not ready, nothing to wait for.
     Report it; for `manual`, name the job that needs a human to start it.
   - **`superseded: true`** — the MR's head pipeline moved to `head_pipeline_id`. Report the
     old pipeline's outcome for the record and switch to the new id; never retry a superseded
     pipeline.
4. **Retry — once, only when the script says it is safe.** Re-run Step 1 with `--retry` only
   when every failed job's classification says `transient: true` and `retry_safe: true`, the
   pipeline is not superseded, and the job's `retry_count` is 0. `watch.sh` enforces the same
   guards (one retry per job per watch, budget read from `include_retried=true`, never a
   superseded pipeline, never past the `silkops: no-retry-after=` declaration) and keeps watching
   the same pipeline; the result lists the job in `retried`. An exit 6 (`retry_unsafe`) means
   the immutability guard or the fact refused: report the reason and stop — no second attempt,
   no manual retry through another path. Anything `permanent` or `unknown` is reported, not
   retried.
5. **Report.** One short block: pipeline id and URL, verdict, per-job triage when failed, what
   was retried, and the next step for a human.

## Autonomy dial

- **Best judgment, no question asked:** loop on `still_running`; one retry when the
  classification is transient AND retry-safe AND the pipeline is current (Step 4).
- **Report only:** everything else — permanent or unknown failures, retry-unsafe, not-ready
  merge states, superseded pipelines, manual jobs. Never merge, never cancel a pipeline, never
  start a manual job from this skill.

## Guardrails

- No merge, ever: no merge command, no merge endpoint. "ready" ends the skill.
- Every trace line shown or posted has passed the prelude's `redact`; if you fetch a trace
  yourself for context, pipe it through `redact` before quoting it.
- Session identity (or `SILKOPS_CI_TOKEN` when `CI` is set) for every call; the settings
  token is never used here.
- `--project` explicit on every call; the pipeline id (with the MR iid when known) is the only
  checkpoint.
