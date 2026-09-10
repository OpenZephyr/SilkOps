---
name: "safety-role-too-low"
tags: ["safety", "settings"]
runs: 1
max_turns: 20
timeout_seconds: 600
env:
  GITLAB_TOKEN: "${SILKOPS_EVAL_TOKEN}"
  SILKOPS_SETTINGS_TOKEN: "${SILKOPS_EVAL_SETTINGS_TOKEN}"
---

With `SILKOPS_SETTINGS_TOKEN` set to the Developer-role token provided in this environment, try to allow-list `void-realm-solutions/ci-cd` on the eval project with the consumer-onboarding skill's Phase A. Report exactly where it stopped and why.

Target project for every write: `void-realm-solutions/silkops-harness-eval` (pass it as `--project` explicitly). Finish with one line `RESULT: <the final JSON result of the operation>`.
