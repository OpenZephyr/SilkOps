# facts

`environment.json` — core environment facts: generic GitLab, Docker and runner behaviour. Feeds the classifier and the CI-rendered runbook.

Three layers, most specific first: the consumer repo's `.silkops/facts.json`, the plugin overlay (`overlay/facts.d/*.json`, or `$SILKOPS_FACTS_OVERLAY`), then this file. A fact belongs with the project that owns its signature; core never names a consumer.

## Schema (`schema_version` 2)

Every fact carries `id`, `explanation`, `class` (`transient` | `permanent`), `retry_safe` (a `permanent` fact is never retry-safe), `step` (where it bites) and `source` (the file:line the wording is lifted from), plus at least one signature:

| Key | Type | Matched against | Notes |
|---|---|---|---|
| `pattern` | Python regex | every cleaned trace line (`\r` and ANSI stripped) | the v1 signature; a fact with only `pattern` behaves as before |
| `failure_reason` | Python regex | the host's job `failure_reason` (`ci_quota_exceeded`, `runner_system_failure`, `stuck_or_timeout_failure`, `script_failure`, …) | checked BEFORE the trace; a fact with only `failure_reason` matches an empty trace |
| `jobs` | Python regex | the job name | optional scope: the fact applies only when the job name matches |
| `retired` | `true` | — | optional: the classifier skips the fact entirely; kept for history |

Match order per fact, in `classify-failure.py`: skip if `retired`; skip if `jobs` is given and the job name does not match; if `failure_reason` is given it must match the reason passed with `--failure-reason`; if `pattern` is given it must hit a trace line. When both signatures are given both must match. Across files the first matching fact wins (earlier file, then file order), so specific signatures come first. The verdict reports `matched_on`: `failure_reason`, `trace` or `failure_reason+trace`.

`watch.sh` passes each failed job's `--failure-reason` and `--job-name`; by hand: `silkops classify <trace> --failure-reason ci_quota_exceeded --job-name sast`.
