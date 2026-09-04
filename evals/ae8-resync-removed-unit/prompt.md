---
name: "ae8-resync-removed-unit"
tags: ["AE8", "tracker"]
runs: 1
max_turns: 20
timeout_seconds: 600
env:
  GITLAB_TOKEN: "${SILKOPS_EVAL_TOKEN}"
  SILKOPS_SETTINGS_TOKEN: "${SILKOPS_EVAL_SETTINGS_TOKEN}"
---

The milestone `eval AE8` on the eval project was created from `fixtures/factory-plan.md`. The plan has since lost unit U8; use `fixtures/factory-plan-minus-u8.md`. Re-sync the milestone with the milestone-from-plan skill and report which issue was closed and the note it received.

Target project for every write: `void-realm-solutions/silkops-harness-eval` (pass it as `--project` explicitly). Finish with one line `RESULT: <the final JSON result of the operation>`.
