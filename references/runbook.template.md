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
7. On `void-nance`, create `NASDAQ_DATA_LINK_API_KEY` under Settings -> CI/CD -> Variables as a
   masked AND protected variable; the key is never written into `.gitlab-ci.yml` (see fact
   `pit-credential-withheld-on-unprotected-ref`).

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

{{FACTS}}
