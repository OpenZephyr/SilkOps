---
name: "ae6-ci-token-missing"
tags: ["AE6", "ci"]
runs: 1
max_turns: 20
timeout_seconds: 600
allowed_tools: ["Bash", "Read", "Skill", "Glob", "Grep"]
env:
  GITLAB_TOKEN: "${SILKOPS_EVAL_TOKEN}"
  SILKOPS_SETTINGS_TOKEN: "${SILKOPS_EVAL_SETTINGS_TOKEN}"
---

Simulate a CI job: run `env CI=true SILKOPS_CI_TOKEN= bash ops/token-check.sh --project void-realm-solutions/silkops-harness-eval --for ci` from the plugin root and report the exit code and the JSON error. Then explain in one sentence what a job on the harness image must set.

Target project for every write: `void-realm-solutions/silkops-harness-eval` (pass it as `--project` explicitly). Finish with one line `RESULT: <the final JSON result of the operation>`.
