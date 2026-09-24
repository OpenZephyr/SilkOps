# SilkOps — repo conventions

This repo is SilkOps (GitLab project `silkops-harness`; plugin id `silkops`): skills (`skills/`) that compose operations
scripts (`ops/`) over `glab`, plus the core facts they share. Plans of record:
`ci-cd/docs/plans/2026-09-02-2334-feat-silkops-harness-plan.md` (v0.1) and
`ci-cd/docs/plans/2026-09-22-1200-feat-silkops-harness-public-split-plan.md` (v0.2).
This file is read by every agent; `CLAUDE.md` only imports it.

## Output

- Verdict first, then the evidence. One JSON result per script, one line per step in a skill.
- Issue bodies: a link and at most one paragraph. Triage notes: the job, the first failing line, the fact matched.
- No generated files in consumer repos beyond `.silkops/facts.json` and the conventions block.
- Diagrams are Excalidraw scenes: the `.excalidraw` source and its `.excalidraw.svg` export (scene embedded) under `docs/diagrams/`. An agent may draft the scene JSON; the SVG export is made in Excalidraw with "Embed scene" on.

## Scripts (`ops/`)

- `bin/silkops <verb> …` is the entry command every skill uses (`silkops watch --project P --mr 7`);
  it runs the matching `ops/` script from any cwd or agent. `silkops doctor` reports the machine.
- `silkops install-agent <name|all>` links the skills where each agent looks (`adapters/<name>/README.md`).
  `GEMINI.md` and `CLAUDE.md` are one-line imports of this file.
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
- GitHub is a main-only push mirror (`void-mirror` and every other branch stay on GitLab);
  `scripts/github-release.sh` publishes the tag's asset there. `ops/inbox.sh` reads GitHub issues
  and PRs; a PR is fetched as a branch and shipped through GitLab, closing on GitHub via `Closes #n`.
