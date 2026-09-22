## Implementation Units

**Target repos:** `silkops-harness` (new; all paths below are relative to it unless prefixed `ci-cd/`) and `ci-cd` (one catalog entry, one docs change).

### Unit Index

| U-ID | Title | Files touched | Depends on |
|---|---|---|---|
| U1 | Capture live fixtures | `tests/fixtures/traces/*`, `tests/fixtures/api/*` | — |
| U2 | Plugin scaffold and repo | `.claude-plugin/*`, `skills/`, `ops/`, `facts/`, `CLAUDE.md` | — |
| U3 | Core primitives | `ops/lib/*`, `ops/token-check.sh` | U2 |
| U4 | Gap-filler operations | `ops/*.sh`, `ops/*.py`, `tests/ops/*` | U1, U3 |
| U5 | Tracker skills | `skills/milestone-from-plan/`, `skills/file-residuals/` | U4 |
| U6 | Pipeline skills | `skills/ship-mr/`, `skills/watch-pipeline/`, `skills/trace-timing/` | U4 |
| U7 | Settings skills | `skills/consumer-onboarding/`, `skills/registry-ops/` | U4 |
| U8 | Runbook, facts, pre-steps | `facts/environment.json`, `references/runbook.md`, `docs/tokens.md`, `ci-cd/CLAUDE.md` | U4 |
| U9 | Harness image and catalog entry | `ci-cd/images/harness/*`, `ci-cd/README.md`, `ci/examples/gitlab.yml` | U4 |
| U10 | Evals and CI wiring | `evals/*`, `.gitlab-ci.yml`, `ci/examples/*` | U5–U9 |

### U1. Capture live fixtures

- **Goal:** Preserve the real traces and API payloads the parsers and evals are built on before GitLab's retention drops them.
- **Requirements:** R5, R6, AE2, AE7
- **Dependencies:** none
- **Files:**
  - `tests/fixtures/traces/docker-hub-502.log` (create — `build-sec-tools` from MR !1's first pipeline)
  - `tests/fixtures/traces/grep-q-pipefail.log` (create — the `factory-tests` T4 failure run)
  - `tests/fixtures/traces/dind-dns.log` (create — the `lookup registry … no such host` run)
  - `tests/fixtures/traces/publish-green.log` (create — a green `build-godot` with sections and per-command timestamps)
  - `tests/fixtures/traces/publish-502-after-push.log` (create — synthesized from `publish-green.log` and `docker-hub-502.log` with the `silkops: no-retry-after=build-image: pushing` line prepended; the AE7 fixture)
  - `tests/fixtures/traces/release-build-linux-3243s.log` (create — job 16176648789)
  - `tests/fixtures/api/pipeline-jobs.json`, `mr-head-pipeline.json`, `issue-with-links.json`, `schedule-misfiring.json` (create)
- **Approach:**
  1. Pull each trace and payload read-only with `glab api`; strip nothing — the parsers must handle raw `\r` and ANSI.
  2. Redact any token-shaped string; record the source job or object id in a `SOURCES.md` beside the fixtures.
  3. Include the misfiring `* 22 * * *` schedule payload as the negative fixture for `consumer-onboarding`'s cron validation.
- **Patterns to follow:** `ci-cd/tests/fixtures/tinyimg/` — fixtures live under `tests/fixtures/<name>/` and are copied to scratch, never mutated in place.
- **Test scenarios:**
  - Test expectation: none — this unit is data capture; each fixture is exercised by U4's tests.
- **Verification:** every fixture listed exists, is non-empty, contains no token-shaped string, and `SOURCES.md` names its origin.

### U2. Plugin scaffold and repo

- **Goal:** A `silkops-harness` repository that Claude Code installs as a user-level plugin from its GitLab URL and that the factory can build an image from.
- **Requirements:** R1, R3
- **Dependencies:** none
- **Files:**
  - `.claude-plugin/plugin.json` (create — `name`, `version`, `description`, `repository`)
  - `.claude-plugin/marketplace.json` (create — `name`, `owner`, `plugins: [{name, source: "./"}]`)
  - `skills/<seven>/SKILL.md` (create — frontmatter `name`, `description` ≤1024 chars, `argument-hint`; bodies land in U5–U7)
  - `ops/`, `ops/lib/`, `facts/`, `references/`, `tests/`, `evals/` (create — empty with README stubs)
  - `CLAUDE.md` (create — repo conventions: script idiom, exit codes, no tracing, marker rules)
- **Approach:**
  1. Run `claude plugin init silkops-harness` (it scaffolds at `~/.claude/skills/silkops-harness/` and would auto-load from there), move that directory into the repo, and confirm `~/.claude/skills/` no longer contains it so no `@skills-dir` copy loads beside the marketplace install.
  2. Validate with `claude plugin validate --strict` in the repo's CI from the first commit.
  3. Install locally via `claude plugin marketplace add <gitlab ssh url>` and confirm the skills load from a consumer repo's working directory.
- **Patterns to follow:** the installed compound-engineering plugin's `.claude-plugin/*.json` and `skills/*/SKILL.md` frontmatter; a single root `ops/` directory instead of per-skill script copies, so CI has one directory to fetch (KTD2).
- **Test scenarios:**
  - `claude plugin validate --strict` passes on the repo root.
  - After `marketplace add` and install, `claude plugin details silkops-harness` lists seven skills.
  - From a checkout of `aura-brawlers`, a skill from the plugin is discoverable (R1).
- **Verification:** the plugin installs from its GitLab URL at user scope and its skills appear in a non-`ci-cd` repository.

### U3. Core primitives

- **Goal:** The shared prelude every operation builds on: result contract, exit codes, token routing, masking, and pre-flight.
- **Requirements:** R2, R11, R12, R17
- **Dependencies:** U2
- **Files:**
  - `ops/lib/prelude.sh` (create — `set -euo pipefail`, `err`, `result` JSON emitter, exit-code constants, `no_trace` guard, redaction filter)
  - `ops/lib/token.sh` (create — `with_settings_token`, `require_ci_token`, provider seam `SILKOPS_PROVIDER=gitlab`)
  - `ops/lib/glab.sh` (create — thin wrappers that route through `token.sh` and apply the redaction filter)
  - `ops/token-check.sh` (create — identity, role on target project, scopes, expiry as one JSON result)
  - `tests/ops/test-prelude.sh`, `tests/ops/test-token-check.sh` (create)
- **Approach:**
  1. Result contract per KTD4: one JSON object on stdout, human text on stderr, fixed exit codes.
  2. Token routing per KTD3: settings token injected only inside `with_settings_token`; when `CI` is non-empty, CI token exported by `require_ci_token` before the first `glab` call, failing with exit 3 when absent so `glab`'s `CI_JOB_TOKEN` auto-login never engages.
  3. Redaction: every wrapped command's stderr passes through a filter that masks token prefixes (`glpat-`, `glcbt-`, `gldt-`, `glrt-`), `oauth2:…@` URLs, `Authorization:`, `PRIVATE-TOKEN:`, and `JOB-TOKEN:` headers, and JWTs (`Bearer eyJ…` or bare `eyJ…`); `set -x` is refused by the prelude. The same filter is a callable that every script applies to any text it returns or posts.
  4. `token-check` calls the token's self endpoint and the target project's membership to report role, scopes, and expiry; exit 4 names the required role and project. For the session's default identity it additionally reports whether that principal can merge or push to the target's protected branches — informational, per KTD3.
- **Execution note:** Prove the negative paths first — a fabricated token-shaped string in stderr must come out masked, and a missing CI token must exit 3 before any network call — before wiring the happy path.
- **Patterns to follow:** `ci-cd/scripts/ci/commit-records.sh` (token from env, stderr suppression with the comment explaining why, named fatal on missing token); `ci-cd/scripts/ci/build-image.sh` `write_meta` for `jq -n` JSON assembly.
- **Test scenarios:**
  - Covers AE6. With `CI=true` and `SILKOPS_CI_TOKEN` unset, `require_ci_token` exits 3 naming the variable and no `glab` process is spawned.
  - A command whose stderr contains any listed shape — each prefix, each header, `oauth2:…@`, a JWT — produces redacted output (one fixture per shape).
  - `with_settings_token` sets `GITLAB_TOKEN` only for the wrapped command and leaves the environment unchanged afterward.
  - `token-check` against a Developer token targeting an allow-list edit exits 4 with "needs Maintainer on <project>".
  - Enabling shell tracing in a script that sources the prelude is refused with a named error.
  - Result JSON validates against the documented schema for success and each error code.
- **Verification:** all prelude and token tests pass without network; the redaction filter has a fixture-driven test for each token shape.

### U4. Gap-filler operations

- **Goal:** The scripts that exist because `glab` has no verb for the operation or the sequence must be atomic.
- **Requirements:** R2, R4, R5, R6, R7, R8, R9, R14
- **Dependencies:** U1, U3
- **Files:**
  - `ops/issue-link.sh` (create — blocks/relates_to with fallback)
  - `ops/allowlist.sh` (create — job-token allow-list get/add, plan-then-apply)
  - `ops/registry.sh` (create — retag with refuse-if-exists, digest compare, tag list; `/jwt/auth` + manifest GET/PUT with content-type preservation)
  - `ops/trace.py` (create — fetch, strip `\r`/ANSI, section parse, per-command timing, root-cause extraction)
  - `ops/classify-failure.py` (create — match trace lines against `facts/environment.json`, decide transient class and retry safety using `SILKOPS_NO_RETRY_AFTER`)
  - `ops/plan-units.py` (create — parse a unified plan's `### U<N>.` units, dependencies, goal; emit JSON)
  - `ops/issue-upsert.sh`, `ops/mr-upsert.sh`, `ops/note.sh` (create — idempotent by marker; managed region handling)
  - `ops/schedule.sh`, `ops/variable.sh` (create — plan-then-apply, cron validation, masked-variable constraints, values never echoed or listed)
  - `tests/ops/*.sh`, `tests/ops/test_trace.py`, `tests/ops/test_classify.py`, `tests/ops/test_plan_units.py` (create)
- **Approach:**
  1. Every script sources the prelude and speaks the KTD4 contract; every write takes an explicit `--project` (KTD9 — never inferred from the cwd remote).
  2. `registry.sh` mirrors `build-image.sh`'s existence guard: `manifest inspect` exit code plus stderr allow-list, network error never read as absent; refuses to retag onto an existing tag (exit 7).
  3. `issue-upsert.sh` finds by marker then label; writes only inside the managed region; never edits a closed issue (KTD5).
  4. `classify-failure.py` reads the facts file (KTD7), finds the `silkops: no-retry-after=` declaration in the trace, and judges the failure's position relative to that pattern (KTD6).
  5. `schedule.sh` refuses a cron firing more than once per day unless `--allow-frequent`; reports owner and last run.
  6. `variable.sh set` reads the value only from `--value-file <path>` or `SILKOPS_VAR_VALUE` in the environment and rejects a `--value` argument with exit 2, so values never enter argv, the Bash tool log, or the session transcript; `consumer-onboarding` tells the operator to place the value in a file rather than paste it into the session.
  7. `registry.sh` hands credentials to `curl` through a config read on stdin (`curl -K -`, generated inside `with_settings_token`), never via argv; the JWT it obtains travels the same way.
- **Execution note:** Parser-first, fixture-first — `trace.py` and `classify-failure.py` are written against U1's captured traces before any script that talks to GitLab.
- **Patterns to follow:** `ci-cd/scripts/ci/build-image.sh` (absent-vs-error probe, `for attempt in 1 2 3` bounded retry); `ci-cd/scripts/ci/render-record.py` (stdlib, `.get()` tolerance); `ci-cd/tests/test-build-image.sh` (`run_*` helper capturing out/err/rc, T5-style "no bash trace" assertion).
- **Test scenarios:**
  - Covers AE4. `registry.sh retag` onto a fresh tag yields both tags resolving to one digest with zero blob uploads; onto an existing tag exits 7.
  - Covers AE2. `classify-failure.py` on `docker-hub-502.log` returns transient, retry-safe.
  - Covers AE7. The same on a publish trace where the 502 follows the `build-image: pushing` line returns transient, retry-unsafe, naming the immutability guard.
  - `trace.py` on `release-build-linux-3243s.log` reports the `cp` step at 1132s and the export at 38s.
  - `trace.py` on a trace without per-line timestamps emits sections-only with a notice.
  - `plan-units.py` on the factory plan yields eight units with U2 depending on U1 and U8 on U5.
  - `issue-upsert.sh` run twice with the same marker updates the managed region once and leaves text outside it byte-identical.
  - `issue-upsert.sh` against a closed issue exits 7 and changes nothing.
  - `issue-link.sh` falls back to `relates_to` plus a body line when `blocks` is rejected.
  - `schedule.sh` refuses `* 22 * * *` and accepts `0 22 * * *`.
  - `variable.sh list` never outputs a value; `variable.sh set` with a value shorter than eight characters and `--masked` reports the masking constraint by name; `variable.sh set --value x` exits 2.
  - `registry.sh` spawns `curl` with no token-shaped string in its argv (asserted through a stub `curl` on `PATH`).
  - `allowlist.sh` dry-run shows current and proposed state and writes nothing.
- **Verification:** every fixture-driven test passes offline; the scripts' error paths never spawn `glab` before their pre-flight.

### U5. Tracker skills

- **Goal:** `milestone-from-plan` and `file-residuals` as procedures over U4's operations.
- **Requirements:** R4, R7, F1, AE1, AE8
- **Dependencies:** U4
- **Files:**
  - `skills/milestone-from-plan/SKILL.md` (modify from U2 stub)
  - `skills/file-residuals/SKILL.md` (modify)
  - `skills/milestone-from-plan/references/issue-body.md` (create — managed-region template)
- **Approach:**
  1. `milestone-from-plan`: parse units (`plan-units.py`), find-or-create the milestone by marker on its description, upsert one issue per unit with dependency links in a second pass, then report a table of unit → issue. On re-sync: diff units, update managed regions, close removed units' open issues with the plan SHA note, never touch closed ones (KTD5).
  2. `file-residuals`: input is the `ce-code-review` result path plus the operator's accepted finding numbers; dedupe by run id and finding number in the marker; target milestone is an argument; a proof note closes the issue only if open, else posts the note.
  3. Both skills state which token identity they will use and confirm nothing — they perform no settings writes.
- **Patterns to follow:** compound-engineering skills' `**Read `references/…` before Step N**` directive style; `argument-hint` in frontmatter.
- **Test scenarios:**
  - Covers AE1. Running against the factory plan on the eval project creates eight marked issues, issue 1 blocks issue 2.
  - Covers AE8. Removing a unit and re-syncing closes exactly that issue with a note naming the plan SHA.
  - Re-running with no plan changes performs zero writes and says so.
  - A human paragraph added below the managed region survives a re-sync.
  - Filing the same residual twice yields one issue and a "already filed as #n" result.
  - A proof note on an already-closed residual posts the note without reopening.
- **Verification:** the two skills complete F1 end to end on the eval project with every object carrying a marker.

### U6. Pipeline skills

- **Goal:** `ship-mr`, `watch-pipeline`, and `trace-timing` as the GitLab shipping tail.
- **Requirements:** R5, R6, R12, R16, F2, AE2, AE3, AE7
- **Dependencies:** U4
- **Files:**
  - `skills/ship-mr/SKILL.md`, `skills/watch-pipeline/SKILL.md`, `skills/trace-timing/SKILL.md` (modify)
  - `ops/watch.sh` (create — bounded-wait loop over `glab api` pipeline/jobs, checkpoint by id)
- **Approach:**
  1. `ship-mr` inherits `ce-commit-push-pr`'s guardrails: never `git add -A`, re-check for an existing MR on the source branch immediately before create, description from the plan's units via file, `Closes #n` for units the branch implements, marker in the body; then hands the MR iid to `watch-pipeline`.
  2. `watch-pipeline` resolves the MR head pipeline (KTD6), loops bounded waits reporting deltas, on failure runs `trace.py` + `classify-failure.py`, retries once per job when safe, passes every trace line it returns or posts through the U3 redaction filter, posts a marker-tagged triage note to the MR when `--note` (default on for MR pipelines), reports readiness or stops at the merge point (R12).
  3. `trace-timing` wraps `trace.py` and renders the sorted table with the two headline numbers (total, largest step).
- **Execution note:** Prove the stop condition first — a green pipeline must end with "ready, not merging" and no merge verb anywhere in the skill text or scripts.
- **Patterns to follow:** the factory's `Monitor`-style poll loops from the session, now with a checkpoint id; `ci-cd/scripts/ci/scan-image.sh` bounded retry.
- **Test scenarios:**
  - Covers AE3. Green MR pipeline → result `ready: true`, no merge performed, `detailed_merge_status` reported.
  - Covers AE2 / AE7 end to end on fixtures replayed through a stub: transient before the marker retries once; after the marker reports retry-unsafe.
  - A pipeline superseded by a newer push is reported as superseded and never retried.
  - `manual` and `canceled` are reported as terminal, not waited on.
  - Resuming `watch-pipeline <pipeline id>` in a fresh session reaches the same terminal report.
  - `ship-mr` on a branch with an existing MR updates its description instead of creating a second MR.
  - A fixture trace containing an `oauth2:…@` URL yields a triage note and a JSON result with the URL redacted.
- **Verification:** F2 completes on the eval project from a verified branch to a "ready" report with a triage note posted on a deliberately red run.

### U7. Settings skills

- **Goal:** `consumer-onboarding` and `registry-ops` — the only skills that perform settings-changing writes.
- **Requirements:** R8, R9, R11, F3, AE4, AE5
- **Dependencies:** U4
- **Files:**
  - `skills/consumer-onboarding/SKILL.md`, `skills/registry-ops/SKILL.md` (modify)
  - `skills/consumer-onboarding/references/preflight.md` (create — the checklist: token exists and scope, role on both projects, schedule owner and cron, protected-branch principals, whether the consumer's `CLAUDE.md` already carries the harness snippet)
- **Approach:**
  1. `consumer-onboarding` runs KTD9's two phases: pre-flight (`token-check` on both projects), Phase A allow-list on the factory with plan-then-apply confirmation, Phase B pin plus `CLAUDE.md` snippet on a branch → `ship-mr` → `watch-pipeline` on the consumer (the pull succeeding is AE5's verification), then schedule and variables on the consumer with confirmation each. Every settings write shows current vs proposed before the operator confirms (KTD3).
  2. `registry-ops` exposes retag, digest-compare, and list; retag refuses existing targets.
  3. Both skills state the token scope in play and ask before using a group-scoped token (KD2).
- **Test scenarios:**
  - Covers AE5. On the eval project as consumer: allow-list applied after confirmation, pin MR opened carrying both the tag pin and the `CLAUDE.md` snippet, its pipeline pulls the image successfully.
  - A consumer whose `CLAUDE.md` already carries the snippet gets no duplicate lines.
  - Covers AE4. Retag on the eval registry yields identical digests; retag onto an existing tag is refused.
  - With a Developer token, Phase A stops before any write with "needs Maintainer on ci-cd".
  - Declining the confirmation leaves allow-list, schedules, and variables unchanged.
  - Pre-flight reports a misfiring cron on an existing schedule and refuses to create a sub-daily one.
- **Verification:** F3 completes on the eval project with one confirmation per settings write and a recorded prior state for each.

### U8. Runbook, facts, and pre-steps

- **Goal:** The operating loop written down, the environment facts in one machine-readable file, and the by-hand pre-steps the harness must never perform on itself.
- **Requirements:** R10, R11, R15, KTD7, KTD12
- **Dependencies:** U4
- **Files:**
  - `facts/environment.json` (create — every fact from `ci-cd`'s yml and test comments: SaaS service DNS, `/builds` bind mounts, no git identity, `pipefail`+`grep -q`, IPv6 alias, registry listing lag, Docker Hub 502, `docker manifest inspect` semantics, cross-project variable expansion, `pull access denied` signature, misfiring cron)
  - `references/runbook.md` (create — loop step by step: which skill, what GitLab state it leaves; gotcha sections rendered from the facts file)
  - `docs/tokens.md` (create — creation, scopes, storage, expiry, rotate-not-recreate, leak posture; the protected-branch migration pre-step; CI variable names; the accepted exposure: `SILKOPS_SETTINGS_TOKEN` is an exported session variable readable by any command the session runs, mitigated by short expiry and per-project scope, not by isolation)
  - `references/claude-md-snippet.md` (create — the lines a repo's `CLAUDE.md` adds: runbook pointer, `ship-mr` as shipping process, `file-residuals` as tracker path)
  - `ci-cd/CLAUDE.md` (create — the snippet applied to the factory repo, so the bot milestone's shipping tail resolves to `ship-mr` from day one)
- **Approach:**
  1. Lift each fact verbatim with its `file:line` origin; the yml comments in `ci-cd` later reference the runbook step instead of restating (Deferred to Follow-Up Work).
  2. The runbook's autonomy table maps every write to the STRATEGY dial: settings = always-human, transient retry = best-judgment, merge = never from a session.
  3. Pre-steps section lists, in order: switch `main` protection to explicit principals; create the settings token; create the CI token; fix the schedule cron.
- **Test scenarios:**
  - `facts/environment.json` validates against its schema and every fact has pattern, explanation, class, and step.
  - The runbook renders from the facts file without manual edits (a generator script or a checked-in render with a CI diff check).
  - Test expectation for prose: none — reviewed by reading.
- **Verification:** `classify-failure.py` and the runbook agree on every fact because both read the same file; in a `ci-cd` checkout, `ce-work`'s shipping tail resolves to `ship-mr`.

### U9. Harness image and catalog entry

- **Goal:** The operations layer delivered as a factory-built image any CI can run.
- **Requirements:** R3, R14, KTD2, KTD10
- **Dependencies:** U4; by-hand: `ci-cd` allow-listed on the plugin project
- **Files:**
  - `ci-cd/images/harness/image.yml` (create — `HARNESS_VERSION`, `GLAB_VERSION`, checksums)
  - `ci-cd/images/harness/Dockerfile` (create — the only harness Dockerfile: `debian:bookworm-slim` via `BASE_IMAGE`, `glab` at a pinned version with checksum, `jq`, `curl`, `python3`; `COPY`s the job-fetched, checksum-verified plugin archive and puts `ops/` on `PATH`)
  - `ci-cd/tasks/image-factory/.image-factory.yml` (modify — `build-harness` job: same three-branch rules, `resource_group: factory-harness`, plus a pre-build step that fetches the archive with the job token into `images/harness/` and verifies `HARNESS_SHA256`; `.build-image`'s script gains the `silkops: no-retry-after=build-image: pushing` echo as its first line)
  - `ci-cd/README.md` (modify — the `ref: main` include example becomes a pinned-tag example)
  - `ci/examples/gitlab.yml` (create — the CI invocation shape: `image: harness:X.Y.Z-rN`, `SILKOPS_CI_TOKEN` from a masked variable, one `file-issue` call)
- **Approach:**
  1. The image is a normal catalog entry: pins in `image.yml`, checksums verified, identity hash, record, immutable `X.Y.Z-rN` tag. The only deviation is the job-side fetch (KTD10); the fetched tarball is a build input, never committed.
  2. The plugin repo's own CI validates the manifest, runs Tier 1 tests, and on a `silkops-harness--v*` tag confirms `plugin.json` version equals the tag with `claude plugin tag --dry-run` (the non-dry form creates the tag; it is the release step, not the check), then uploads `silkops-harness-X.Y.Z.tar.gz` and its `.sha256` to the project's generic package registry — the artifact KTD10 pins.
  3. Only the GitLab example ships; the image remains runnable as `container:`/`image:` elsewhere (KTD2), but examples for other CI systems need a `read_registry` deploy token and a runner to verify on, so they are follow-up work.
- **Test scenarios:**
  - `docker run harness:<tag> token-check --help` exits 0 and every `ops/*` is on `PATH`.
  - The factory's dry-run build of `images/harness` verifies `HARNESS_SHA256` in the job step and fails on a wrong checksum before `docker build` (negative test); `docker history` of the built image contains no token-shaped string.
  - Covers AE6. A GitLab job on the harness image with `SILKOPS_CI_TOKEN` files an issue on the eval project; without it, exits 3 naming the variable.
  - `claude plugin validate --strict` and the version-equals-tag check gate the plugin repo's release job.
- **Verification:** `harness:X.Y.Z-r1` exists in the registry with a committed record, built by the factory pipeline, and a CI job on it files an issue.

### U10. Evals and CI wiring

- **Goal:** Tier 2 acceptance encoded as `claude plugin eval` cases, and both tiers running in the plugin repo's CI.
- **Requirements:** R13, AE1–AE8, KTD11
- **Dependencies:** U5, U6, U7, U8, U9
- **Files:**
  - `evals/<ae-name>/case.yaml` or `prompt.md` + `graders/*.md` per acceptance example (create)
  - `evals/safety/*` (create — green pipeline never merges; settings write preceded by a confirm turn showing a diff; retry-unsafe past the marker; Developer token yields the named role error; variable listing shows no values)
  - `evals/cross-repo/*` (create — `consumer-onboarding` from a non-`ci-cd` working directory)
  - `.gitlab-ci.yml` (modify — Tier 1 on every push; Tier 2 manual while early-access; release job)
  - `scripts/audit-milestone.sh` (create — the KD3 audit: milestone objects lacking a marker, plus a transcript scan for `glab api`/`curl`)
- **Approach:**
  1. One eval per acceptance example, graders verifying GitLab state through the harness's own read primitives (reads verify writes).
  2. Evals target `silkops-harness-eval`, a throwaway project in the group, never `ci-cd` or a consumer.
  3. The audit script is what closes KD3 after the bot milestone — a query, not a reading exercise.
- **Test scenarios:**
  - Each AE eval passes with ablation showing the plugin fired.
  - Each safety eval passes; the merge-never eval fails if any skill text or script contains a merge verb or a protected-branch endpoint.
  - `audit-milestone.sh` on the factory milestone reports the by-hand objects from this session as unmarked (expected), and zero unmarked on an eval-created milestone.
- **Verification:** Tier 1 gates the plugin repo's pipeline; Tier 2 runs on demand and its results are committed under `evals/results/`.

---

