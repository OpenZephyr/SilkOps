---
name: "ae2-transient-retry"
tags: ["AE2", "pipeline"]
runs: 1
max_turns: 20
timeout_seconds: 600
env:
  GITLAB_TOKEN: "${SILKOPS_EVAL_TOKEN}"
  SILKOPS_SETTINGS_TOKEN: "${SILKOPS_EVAL_SETTINGS_TOKEN}"
---

Watch pipeline id `${EVAL_PIPELINE_TRANSIENT}` on the eval project with the watch-pipeline skill, allowing a retry. That pipeline has one job that failed pulling from Docker Hub with a 502. Report the classification and whether a retry happened.

Target project for every write: `void-realm-solutions/silkops-harness-eval` (pass it as `--project` explicitly). Finish with one line `RESULT: <the final JSON result of the operation>`.
