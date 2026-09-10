# silkOps operating runbook

The loop for building a silkOps milestone on GitLab with zero ad-hoc glue. Every GitLab-side
step is a skill from this plugin; every skill composes scripts from `ops/`. If a step below
needs a `glab api` or `curl` call that no script provides, the fix is a new script in `ops/`,
not an inline call.

## The loop

| Step | Skill / tool | Leaves behind on GitLab |
|---|---|---|
| Brainstorm → plan | `ce-brainstorm`, `ce-plan` (compound-engineering) | nothing; the plan is a file in the repo |
| Plan → tracker | `milestone-from-plan` | milestone, one marker-tagged issue per unit, `blocks` links |
| Build | `ce-work` | commits on a feature branch (never the default branch) |
| Ship | `ship-mr` (declared as the repo's shipping process in `CLAUDE.md`) | an MR whose description mirrors the plan's units, `Closes #n` |
| Watch and triage | `watch-pipeline` | a triage note per failed job; at most one retry per job when safe |
| Evidence | `trace-timing` | numbers for the MR description or the record |
| Review | `ce-code-review`, then `file-residuals` | residual issues on the milestone, proof notes on close |
| Merge | **a human** | — the harness never merges |
| Registry | `registry-ops` | an additional immutable tag pointing at an existing digest |
| New consumer | `consumer-onboarding` | allow-list entry, pin MR with the `CLAUDE.md` snippet, schedules, variables |

## Autonomy dial (per write)

| Write | Dial | Who decides |
|---|---|---|
| Issue, MR, note (session identity) | best-judgment | the skill, reported afterwards |
| Retry of a transient failure before the no-retry declaration | best-judgment | `watch-pipeline`, once per job |
| Retry after the declaration, or on a superseded pipeline | never | — |
| Allow-list, schedule, variable, retag (settings token) | always-human | the operator confirms a shown diff, one write at a time |
| Merge, push to a protected branch, protected-branch rule | never from a session | the operator, in the GitLab UI |

## Identities and tokens

- **Session identity**: the operator's own `glab` login. MRs, issues, and notes are authored
  by the person driving. Because that account can merge, never-merge is a property of the
  skills and the verification gate, not of GitLab — see `docs/tokens.md`.
- **Settings token** (`SILKOPS_SETTINGS_TOKEN`, Maintainer, per project): injected only
  around settings writes by `with_settings_token`. Ambient in the session environment by
  accepted decision; short expiry, per-project scope.
- **CI token** (`SILKOPS_CI_TOKEN`, Developer, `api`): exported before any `glab` call when
  `CI` is set, so `glab` never auto-logs-in with `CI_JOB_TOKEN`. Missing → exit 3 before any
  network call.

## By-hand pre-steps (in order, before the first settings token exists)

1. Switch `main`'s protection on the factory from the Maintainers role to explicit principals
   (push: the records bot; merge: the operator). The harness never performs this write.
2. Create the settings token (Maintainer, `api`, expiry ≤ 90 days) and store it as the exported
   `SILKOPS_SETTINGS_TOKEN` in the operator's shell profile.
3. Create the CI token (Developer, `api`) and set it as a masked, protected CI variable
   `SILKOPS_CI_TOKEN` on each project whose jobs run the harness image.
4. Fix the factory schedule cron to `0 22 * * *` (it is `* 22 * * *` today and fires several
   times an hour; `schedule.sh validate` refuses that shape).
5. On the `silkops-harness` project, allow-list `ci-cd` under job token permissions so the
   factory can fetch the release asset.
6. On `void-nance`, enable Settings -> Merge requests -> "Pipelines must succeed" so the
   `fixtures` job blocks the merge button (GitLab has no per-job required check; see fact
   `fixture-gate-red-is-advisory-without-project-setting`).
7. On `void-nance`, create `SHARADAR_API_KEY` (from https://sharadar.com/account) under Settings ->
   CI/CD -> Variables as a masked AND protected variable; the key is never written into
   `.gitlab-ci.yml` (see fact `pit-credential-withheld-on-unprotected-ref`). Add `SHARADAR_PLAN=paid`
   only once a paid plan is bought (see fact `sharadar-free-plan-or-unrecognised-key`).

## Watching a pipeline: what the states mean

- `ready: true` — head pipeline succeeded and `detailed_merge_status` is `mergeable`. Stop.
  Tell the operator. Do not merge.
- `still_running` — the wait budget ended; resume with `watch.sh --pipeline <id>` in this or
  a later session; no local state is needed.
- `superseded` — a newer push replaced the head pipeline; never retry the old one.
- `failed` with `transient` + `retry_safe` — one retry, then keep watching the same pipeline.
- `failed` with `retry_safe: false` — a step past the job's `silkops: no-retry-after=`
  declaration failed (for the factory: the tag is live). Report; a human decides.
- `manual`, `canceled`, `skipped` — terminal, not ready, nothing to wait for.

## Environment facts

Every fact below is matched by `classify-failure.py` and explained here from the same file.
Add a fact in `facts/environment.json`; then run `ops/render-runbook.py`.

<!-- facts:begin (generated by ops/render-runbook.py — edit facts/environment.json, not this block) -->

| Fact | Class | Retry safe | Bites at | Recorded in |
|---|---|---|---|---|
| `sharadar-key-sent-to-nasdaq-data-link` | permanent | no | pit-integration (PointInTimeAdapter._request) | `void-nance docs/research/point-in-time-provider-assessment.md amendment 2026-09-10` |
| `sharadar-free-plan-or-unrecognised-key` | permanent | no | pit-integration (PointInTimeAdapter plan probe) | `void-nance src/falsifier/data/pointintime.py:655` |
| `sharadar-rate-limited` | transient | yes | pit-integration (PointInTimeAdapter._request) | `void-nance src/falsifier/data/pointintime.py _http_error 429 branch` |
| `dind-service-dns` | permanent | no | factory-tests (dind daemon reaching the registry service) | `.gitlab-ci.yml:41-46` |
| `docker-hub-502` | transient | yes | scan-image (scanner image pull from Docker Hub) | `scripts/ci/scan-image.sh:48-56` |
| `grep-q-sigpipe-under-pipefail` | permanent | no | factory-tests (T4 tag check after push) | `tests/test-build-image.sh:159-160` |
| `pull-access-denied` | permanent | no | image pull at consumer job start (job-token allow-list) | `docs/image-catalog.md:84-88` |
| `manifest-inspect-network-error` | transient | yes | build-image (tag existence probe) | `scripts/ci/build-image.sh:89-107` |
| `tag-already-exists` | permanent | no | build-image (publish refusal, AE3) | `scripts/ci/build-image.sh:97-104` |
| `bind-mount-outside-builds` | permanent | no | factory-tests (docker run -v from the job container) | `.gitlab-ci.yml:53-54` |
| `git-identity-missing` | permanent | no | commit-records (git commit in CI) | `tests/test-commit-records.sh:4-7` |
| `cross-project-variable-expansion` | permanent | no | image resolution in a consumer pipeline (cross-project include) | `tasks/terraform-scanners/.terraform-scan.yml:13-16` |
| `ipv6-service-alias` | permanent | no | factory-tests (resolving the dind daemon alias for the registry URL) | `tests/test-build-image.sh:45-47` |
| `registry-listing-lag` | transient | yes | factory-tests (tag check immediately after push) | `tests/test-build-image.sh:159-162` |
| `misfiring-cron-every-minute` | permanent | no | schedule (pipeline_schedules cron) | `tests/fixtures/api/schedule-misfiring.json` |
| `job-token-fetch-denied` | permanent | no | build-harness (release-asset fetch before docker build) or any consumer pull | `tasks/image-factory/.image-factory.yml:129` |
| `pit-credential-withheld-on-unprotected-ref` | permanent | no | pit-integration (PointInTimeAdapter construction) | `void-nance src/falsifier/data/pointintime.py:431` |
| `fixture-gate-red-is-advisory-without-project-setting` | permanent | no | fixtures (fixture acceptance suite) | `void-nance .gitlab-ci.yml fixtures job` |

### `sharadar-key-sent-to-nasdaq-data-link`

void-nance: HTTP 429 with quandl_error QELx06 ("account temporarily disabled") from data.nasdaq.com is what Nasdaq Data Link answers to a key it never issued. Sharadar left Nasdaq Data Link and serves data directly from https://api.sharadar.com/v1.0; a sharadar.com key must never be sent to data.nasdaq.com (Sharadar's own guide says so). Seen live on the first pit-integration run (pipeline 2837688162) before the adapter was ported. This signature today means an old adapter or base URL is in use; fix the code, do not retry and do not contact Nasdaq.

Signature: `Nasdaq Data Link returned HTTP 429|QELx06|your account has temporarily been disabled`

### `sharadar-free-plan-or-unrecognised-key`

void-nance: api.sharadar.com serves an unrecognised key the free sample with HTTP 200 (no 401), and answers anything outside the sample (delisted names, deep history, sp500 added/removed events, the `daily` table on a Prices plan) with 403 {"error":"Exceeds free tier"}. The adapter probes a delisted name before its first data request and refuses with ProviderError code free_tier, so a free plan and a wrong key look the same and neither can produce confirmed data (KTD9). In pit-integration the paid tests skip on this unless the CI variable SHARADAR_PLAN=paid is set, which turns the skip into a failure; set it when the subscription is bought (Bundle Full History for market-cap tiers, or Prices Full History for S&P 500 only). Permanent: retrying changes nothing; check the key and the plan at https://sharadar.com/account.

Signature: `SHARADAR_API_KEY is on the free plan or is unrecognised|Exceeds free tier`

### `sharadar-rate-limited`

void-nance: api.sharadar.com publishes its budget in x-ratelimit-limit/remaining/reset headers (5000 per window observed) and expects one request at a time per key; the adapter serialises requests behind a lock and a local 5-calls/second limiter, so a 429 in CI means the key is shared with something else or the job was parallelised. pit-integration runs on a single worker (no xdist) for that reason. Transient: safe to retry after the reset time named in the error message, once.

Signature: `Sharadar returned HTTP 429|code=rate_limited`

### `dind-service-dns`

SaaS runners: services cannot resolve each other, so the dind daemon cannot look up the `registry` service on the SaaS resolver (169.254.169.254:53). A configuration error, not a flake: the guard suite runs its throwaway registry ON the dind daemon (host network) and pushes to the daemon's own IP over plain HTTP, with --insecure-registry for the private ranges.

Signature: `dial tcp: lookup \S+ on 169\.254\.169\.254:53: no such host`

### `docker-hub-502`

Docker Hub flakes (seen live: 502 on the manifest fetch of aquasec/trivy) must not fail a job whose build already succeeded; scan-image.sh pulls the scanner with bounded retries (three attempts). A job retry is safe as long as nothing was pushed before the failure.

Signature: `(registry-1\.docker\.io|docker\.io).*(502 Bad Gateway|unexpected HTTP status: 502)`

### `grep-q-sigpipe-under-pipefail`

`grep -q` exits on its first match and SIGPIPEs the `jq` that feeds it; under `set -o pipefail` the pipeline then reports failure once a repo lists two tags, so the tag check read false although the tag was there. Read the full listing (`grep >/dev/null`) or use `jq -e`; never `grep -q` on piped JSON (fix: ci-cd 2dba7c3).

Signature: `tag_seen=false|grep -q .*SIGPIPE`

### `pull-access-denied`

The factory registry inherits the project's private visibility: a consumer's job pulls a factory image only if ci-cd lists that project — or its group — under Settings → CI/CD → Job token permissions (Authorized groups and projects). The failure is fast and unambiguous, within seconds of job start. Allow-list the group once rather than each consumer; retrying changes nothing.

Signature: `pull access denied.*requested access to the resource is denied`

### `manifest-inspect-network-error`

`docker manifest inspect` exits 1 both for "no such tag" and for real errors; only a stderr message proving the tag is absent (no such manifest / manifest unknown / MANIFEST_UNKNOWN / NAME_UNKNOWN) may fall through — a network or auth failure is never read as "tag absent" (KTD2). The probe runs before any build or push, so a retry is safe.

Signature: `registry query for \S+ failed \(cannot verify tag absence\)`

### `tag-already-exists`

Tags are immutable: a publish onto an existing tag is refused before building. Bump the release suffix (-rN) instead of retrying; a dry run (MR build) on the same day still builds without pushing.

Signature: `already exists in the registry .*tags are immutable`

### `bind-mount-outside-builds`

In dind CI, bind-mounted paths must live under /builds (shared with the daemon); a scratch dir in the job container's own /tmp does not exist on the daemon, so `-v` fails or mounts an empty path. FACTORY_TEST_TMPDIR points under $CI_PROJECT_DIR for this reason; locally the system tmpdir is fine.

Signature: `invalid mount config for type "bind"|bind source path does not exist|Mounts denied`

### `git-identity-missing`

CI runners have no git identity; every commit made in a job needs one. commit-records.sh sets its own via `-c user.name=silkops-factory -c user.email=factory@silkops.invalid -c commit.gpgsign=false`; the test harness exports GIT_AUTHOR_* and GIT_COMMITTER_* for its seed commits.

Signature: `Please tell me who you are|Author identity unknown|empty ident name`

### `cross-project-variable-expansion`

Cross-project includes expand variables in the CONSUMER pipeline, so `$CI_REGISTRY_IMAGE` resolves to the consumer's own (empty) registry and the factory image path comes out wrong. The factory registry must be named explicitly (FACTORY_IMAGE_ROOT: registry.gitlab.com/void-realm-solutions/ci-cd); fix the include, do not retry.

Signature: `manifest for \S+ not found: manifest unknown|repository \S+ not found|invalid reference format`

### `ipv6-service-alias`

The service alias also resolves to a ULA IPv6 address the registry does not listen on, and bare v6 literals break host:port URLs. Resolve IPv4 only: `getent ahostsv4 <alias> | awk '{print $1}' | head -1`.

Signature: `dial tcp \[[0-9a-f:]+\]:\d+: connect: (connection refused|network is unreachable)|too many colons in address`

### `registry-listing-lag`

The registry's tag listing can lag the push by a moment, so a check that lists tags right after `docker push` can miss the new tag. Poll briefly before calling it absent (the suite retries five times, one second apart). Note: `tag_seen=false` on its own was the grep -q/pipefail bug, matched by grep-q-sigpipe-under-pipefail.

Signature: `tag listing (can )?lag|pushed tag \S+ not (yet )?listed`

### `misfiring-cron-every-minute`

`* 22 * * *` fires every minute of hour 22 (sixty pipelines) instead of once — `0 22 * * *` is the daily form. The silkops-factory-records schedule shipped with the misfiring cron and produced hundreds of failed main pipelines every ~25s during 22:xx local. schedule.sh refuses a cron firing more than once per day unless --allow-frequent.

Signature: `^\* \d{1,2} \* \* \*$|cron[^\n]*\* 22 \* \* \*`

### `job-token-fetch-denied`

A cross-project fetch with CI_JOB_TOKEN (package registry asset, repository archive, registry pull) answered 404/403: the target project has not allow-listed this project under Settings > CI/CD > Job token permissions. GitLab hides the resource rather than naming the denial, so a missing allow-list looks like a missing file. A configuration pre-step, not a flake: allow-list the fetching project on the TARGET project (Maintainer there), then re-run.

Signature: `curl: \(22\) The requested URL returned error: 40[34]`

### `pit-credential-withheld-on-unprotected-ref`

void-nance: the Sharadar credential SHARADAR_API_KEY (issued at https://sharadar.com/account) is never written into .gitlab-ci.yml. It must be created under Settings -> CI/CD -> Variables as a *masked* AND *protected* variable (plan KTD9), so GitLab withholds it from pipelines on unprotected branches and redacts it from job logs; the `pit-integration` job runs only on protected refs for that reason. This signature on a protected ref means the variable is missing or not marked protected; on an unprotected ref it means the job's `rules:` were loosened. A configuration error, never a flake, and the adapter never falls back to free data.

Signature: `SHARADAR_API_KEY is not set: the point-in-time adapter`

### `fixture-gate-red-is-advisory-without-project-setting`

void-nance: the `fixtures` job (U8, R19/R22) never carries `allow_failure`, but GitLab has no per-job required check -- merge blocking is a PROJECT SETTING. The operator must enable Settings -> Merge requests -> "Pipelines must succeed"; until that is on, a red fixture suite is advisory and the merge button stays green. A fixture failure itself is deterministic (offline snapshot, pinned python:3.9 + requirements-ci.txt): a moved tolerance band or a snapshot refresh must land in the same MR as CHECKSUMS.sha256 / MANIFEST.json. Retrying changes nothing.

Signature: `FAILED tests/test_fixture_\S+`

<!-- facts:end -->
