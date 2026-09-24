# Providers: what each verb means on each host

The scripts call verbs (`ops/lib/providers/<name>.sh`), never endpoints. The provider is read off
the origin remote (`github.com` → github, else gitlab) or set with `SILKOPS_PROVIDER`. Every
result carries `provider`. The JSON keeps the GitLab names as keys and adds the host-native alias
where one exists, so nothing downstream breaks and nothing is renamed.

| concept | gitlab | github | gitea (experimental) |
|---|---|---|---|
| change | merge request, `iid` | pull request, `iid` = `number` | pull request, `iid` = `index` |
| CI unit | pipeline from `.gitlab-ci.yml`, one per commit | workflow run from `.github/workflows/*.yml`, one per workflow per commit: `runs[]` | Actions run from `.gitea/workflows/*.yml` |
| job, job trace | pipeline job, `jobs/:id/trace` | run job, `actions/jobs/:id/logs` | run job, `actions/jobs/:id/logs` |
| retry | retry one job | rerun the failed job of the run (`rerun: true`, same id, new attempt) | rerun |
| ready to merge | `detailed_merge_status` + approvals | `mergeable_state` (clean → mergeable, behind → need_rebase, dirty → conflict, blocked → blocked_status, draft) + `reviewDecision` | `mergeable` + reviews |
| triage note | MR note | PR issue comment | PR comment |
| plan container | milestone | milestone (repo milestones by number; Projects v2 is GraphQL-only and out of scope) | milestone |
| dependency link | issue link `blocks` (`relates_to` when the tier refuses) | none in REST: `fallback: managed_region` and a `Blocked by #n` line | issue dependencies API |
| schedule | pipeline schedule (settings API) | `on: schedule` in a workflow file: a change to ship, never a settings write (U4) | same as github |
| CI variable / secret | project variable, masked and protected | Actions variable / secret via `gh variable set` / `gh secret set` on stdin (U4) | Actions variable / secret API |
| registry | GitLab registry v2 | GHCR v2 (U4) | Gitea registry v2 |
| job-token allow-list | project setting | not a concept: `not_applicable` (U4) | not a concept |
| protected branch (read) | `protected_branches` | branch protection / rulesets (U4; until then the read verb reports null) | branch protections |
| identity | glab session, `SILKOPS_CI_TOKEN` in CI | `gh` login or `GH_TOKEN` | `GITEA_TOKEN` |

## Status values

Runs and jobs report the harness's status words on every host: `running`, `success`, `failed`,
`canceled`, `skipped`, `manual`. GitHub conclusions map as `failure`/`timed_out`/`startup_failure`
→ `failed`, `cancelled`/`stale` → `canceled`, `action_required` → `manual`, `neutral` → `success`.

## Fallbacks and refusals, by name

- `fallback: managed_region` (`issue-link`, github): the host has no blocking links; the caller
  records the `depends_on_line` in the target issue's managed region.
- `fallback: relates_to` (`issue-link`, gitlab): the tier refuses `blocks`; a `relates_to` link is made.
- `not_applicable` (`allowlist`, github and gitea): no job-token allow-list exists; exit 0, nothing to do.
- `p_gitlab_only` (`schedule`, `variable`, `allowlist`, `registry`): GitLab-only until their
  provider mapping lands in v0.3 U4; exit 2 with the reason on any other provider.
- `experimental: true` (gitea): every result until a live run clears it.

## Adding a provider

Copy `ops/lib/providers/gitlab.sh`, keep the verb names and result shapes, add a stub under
`tests/fixtures/<name>-stub/` with scenario `routes.tsv` files, and mirror the GitLab suites.
Never add a merge, a protected-branch write, or a token in argv.
