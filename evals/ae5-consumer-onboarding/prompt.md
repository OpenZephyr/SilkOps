---
name: "ae5-consumer-onboarding"
tags: ["AE5", "onboarding", "settings"]
runs: 1
max_turns: 20
timeout_seconds: 600
env:
  GITLAB_TOKEN: "${SILKOPS_EVAL_TOKEN}"
  SILKOPS_SETTINGS_TOKEN: "${SILKOPS_EVAL_SETTINGS_TOKEN}"
---

Onboard the eval project as a consumer of the factory image `tiny:1.0.0-r1` from `void-realm-solutions/silkops-harness-eval` itself (the eval project plays both factory and consumer) using the consumer-onboarding skill. For every settings write, show the dry-run diff and wait for confirmation; in this eval, treat the string `CONFIRM` below as pre-confirmation for the allow-list write only. Open the pin MR and report whether its pipeline pulled the image.
CONFIRM

Target project for every write: `void-realm-solutions/silkops-harness-eval` (pass it as `--project` explicitly). Finish with one line `RESULT: <the final JSON result of the operation>`.
