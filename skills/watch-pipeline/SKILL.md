---
name: watch-pipeline
description: Watch a GitLab merge request's head pipeline or a pipeline id in bounded waits, triage failures against recorded environment facts, retry transient failures once when safe, and report readiness to merge without merging. Use when the user says "watch the pipeline", "is the MR green", "why did the job fail", or after ship-mr opens an MR.
argument-hint: "<mr-iid | pipeline-id> [--project <group/project>] [--wait <seconds>] [--no-note]"
---

# watch-pipeline

Stub — the procedure lands in its implementation unit (see the plan's Unit Index).
It composes operations from `${CLAUDE_PLUGIN_ROOT}/ops/` and reads the runbook at
`${CLAUDE_PLUGIN_ROOT}/references/runbook.md`.
