---
name: "cross-repo-discovery"
tags: ["cross-repo"]
runs: 1
max_turns: 6
timeout_seconds: 180
allowed_tools: ["Skill", "Read"]
env:
  GITLAB_TOKEN: "${SILKOPS_EVAL_TOKEN}"
  SILKOPS_SETTINGS_TOKEN: "${SILKOPS_EVAL_SETTINGS_TOKEN}"
---

You are in a checkout of a repository that is NOT the harness (this sandbox). Without reading the plugin's source tree first, name the seven silkops-harness skills available to you and which one you would use to (a) open a merge request, (b) find where a slow job spends its time, (c) let another project pull a factory image.

Target project for every write: `void-realm-solutions/silkops-harness-eval` (pass it as `--project` explicitly). Finish with one line `RESULT: <the final JSON result of the operation>`.
