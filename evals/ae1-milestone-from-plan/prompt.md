---
name: "ae1-milestone-from-plan"
tags: ["AE1", "tracker"]
runs: 1
max_turns: 20
timeout_seconds: 600
env:
  GITLAB_TOKEN: "${SILKOPS_EVAL_TOKEN}"
  SILKOPS_SETTINGS_TOKEN: "${SILKOPS_EVAL_SETTINGS_TOKEN}"
---

Create the GitLab milestone for the plan at `fixtures/factory-plan.md` (a copy of the ci-cd image-factory plan with eight units) on the eval project, using the milestone-from-plan skill. Title the milestone `eval AE1 <today's date>`. Report the unit -> issue table and confirm issue U1 blocks issue U2.

Target project for every write: `void-realm-solutions/silkops-harness-eval` (pass it as `--project` explicitly). Finish with one line `RESULT: <the final JSON result of the operation>`.
