---
name: ship-mr
description: Open or update the GitLab merge request for the current branch from the plan's units, then hand off to pipeline watching; never merges. Use when the user says "ship it", "open the MR", "push and create the merge request", or a workflow's shipping tail reaches a GitLab remote.
argument-hint: "[--plan <plan-path>] [--draft] [--target <branch>]"
---

# ship-mr

Stub — the procedure lands in its implementation unit (see the plan's Unit Index).
It composes operations from `${CLAUDE_PLUGIN_ROOT}/ops/` and reads the runbook at
`${CLAUDE_PLUGIN_ROOT}/references/runbook.md`.
