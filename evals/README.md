# Tier 2 evals (`claude plugin eval`)

Additive and non-gating while `claude plugin eval` is early-access. Every case targets the
throwaway project `void-realm-solutions/silkops-harness-eval` (id 86083568), never `ci-cd` or a
consumer. One case per acceptance example (AE1-AE8) plus safety and cross-repo cases.

Run from the plugin root with `SILKOPS_EVAL_TOKEN` (Developer on the eval project; the session
identity) and `SILKOPS_EVAL_SETTINGS_TOKEN` (Maintainer on the eval project) exported:

    claude plugin eval . --ablation with-without --allow-tools Bash

Results land in `evals/results/` and are committed after each run.

Known unknowns to verify on the first run (the eval runner has no public docs yet):
- whether case `env:` values need an `EVAL_` prefix to reach the run (if so, rename and export
  `GITLAB_TOKEN` from a scaffold script);
- whether `${VAR}` expansion works in `env:` values;
- the ids for AE2/AE3/AE7 (`EVAL_PIPELINE_TRANSIENT`, `EVAL_MR_GREEN`, `EVAL_PIPELINE_AFTER_PUSH`)
  must exist on the eval project first: a small `.gitlab-ci.yml` there with one green job, one
  that curls a 502 endpoint, and one that echoes the no-retry declaration then fails gives
  stable targets; `tiny:1.0.0-r1` must be pushed to its registry for AE4/AE5.

Graders cannot run shell commands, so state is verified by asking the agent to end with
`RESULT: <json>` from the harness's own read primitives and matching that line (regex), plus
`llm` graders over the trace for the never-merge and no-settings-write properties.
