# silkops-harness — repo conventions

This repo is the silkOps operating harness: skills (`skills/`) that compose operations
scripts (`ops/`) over `glab`, plus the core facts they share. Plans of record:
`ci-cd/docs/plans/2026-09-02-2334-feat-silkops-harness-plan.md` (v0.1) and
`ci-cd/docs/plans/2026-09-22-1200-feat-silkops-harness-public-split-plan.md` (v0.2).
This file is read by every agent; `CLAUDE.md` only imports it.

## Output

- Verdict first, then the evidence. One JSON result per script, one line per step in a skill.
- Issue bodies: a link and at most one paragraph. Triage notes: the job, the first failing line, the fact matched.
- No generated files in consumer repos beyond `.silkops/facts.json` and the conventions block.
- Diagrams are Excalidraw scenes saved as `.excalidraw.svg`, drawn by a human. Before creating one, ask which editing path the operator wants; never write the scene JSON.

## Scripts (`ops/`)

- Bash for operations, Python 3.9 stdlib for parsers. Dependencies: `glab`, `jq`, `curl`,
  the stock interpreter. Nothing else. Structured inputs are JSON (no YAML parser exists).
- Every script sources `ops/lib/prelude.sh` (`set -euo pipefail`, no shell tracing, redaction).
- Contract: one JSON object on stdout, human text on stderr. Exit codes:
  `0` success · `2` usage · `3` token missing · `4` insufficient role · `5` not found ·
  `6` retry unsafe · `7` refused (immutability, protected write, closed issue) · `1` other.
- Every write takes an explicit `--project`; never infer the target from the cwd remote.
- Tokens come from the environment only (`SILKOPS_SETTINGS_TOKEN`, `SILKOPS_CI_TOKEN`) and
  are never printed, never placed in argv, never embedded in URLs. Settings tokens are
  injected only inside `with_settings_token`. Values for CI variables arrive by file or env.
- Never merge, never push a protected branch, never write to `protected_branches` endpoints
  (`token-check` reads them, informationally), never edit a closed issue. `set -x` is refused by the prelude.
- Harness-written objects carry `<!-- silkops: v=… plan=… unit=… run=… -->`; issue bodies wrap
  plan-derived text in `<!-- silkops:managed -->…<!-- /silkops:managed -->`. The operator decides
  disclosure: markers and trailers are off on projects outside the operator's group.
- Facts come in three layers, most specific first: the consumer repo's `.silkops/facts.json`,
  the plugin overlay, then `facts/environment.json`. Core never names a consumer.
- No `grep -q` on piped JSON (SIGPIPE under pipefail); use `grep >/dev/null` or `jq -e`.

## Tests

- Tier 1 (`tests/`): fixture-driven, offline, gates every change. Run `bash tests/run.sh`.
- Tier 2 (`evals/`): `claude plugin eval`, against the throwaway `silkops-harness-eval` project only.

## Release

- Version lives in `.claude-plugin/plugin.json`; release tag is `silkops-harness--vX.Y.Z`
  (`claude plugin tag`). The factory in `ci-cd` builds `harness:X.Y.Z-rN` from the release asset.
