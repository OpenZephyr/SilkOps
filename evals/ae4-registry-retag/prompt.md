---
name: "ae4-registry-retag"
tags: ["AE4", "registry", "settings"]
runs: 1
max_turns: 20
timeout_seconds: 600
env:
  GITLAB_TOKEN: "${SILKOPS_EVAL_TOKEN}"
  SILKOPS_SETTINGS_TOKEN: "${SILKOPS_EVAL_SETTINGS_TOKEN}"
---

On the eval project's container registry, image `tiny`, tag `1.0.0-r1` exists. Using the registry-ops skill, add the tag `1.0.0-eval-${EVAL_RUN_ID}` pointing at the same digest (zero-copy), then show that both tags resolve to one digest. Then attempt to retag onto the existing tag `1.0.0-r1` and report what the tool does.

Target project for every write: `void-realm-solutions/silkops-harness-eval` (pass it as `--project` explicitly). Finish with one line `RESULT: <the final JSON result of the operation>`.
