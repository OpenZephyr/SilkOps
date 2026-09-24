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
| schedule | pipeline schedule (settings API) | `on: schedule` in a workflow file written by `schedule.sh create` (`action: file_written`): a change to ship, never a settings write | same as github, under `.gitea/workflows` |
| CI variable / secret | project variable, masked and protected | masked → Actions secret (`gh secret set`, value on stdin), plain → Actions variable; `protected` is `not_applicable` | Actions variable / secret API |
| registry | GitLab registry v2 (tags and digests via the GitLab API) | GHCR v2: `ghcr.io/<owner>/<image>`, token exchange with `GH_TOKEN` | Gitea registry v2 |
| job-token allow-list | project setting | not a concept: `not_applicable`, exit 0, nothing written | not a concept |
| protected branch (read) | `protected_branches` | default-branch protection, summarised as `protection {required_reviews, required_checks, enforce_admins}` | branch protections |
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
- `p_gitlab_only`: the guard the settings scripts wore before their mappings landed (v0.3 U4); kept
  in `ops/lib/provider.sh` for a future provider that lacks a mapping.
- `experimental: true` (gitea): every result until a live run clears it.

## Adding a provider

Copy `ops/lib/providers/gitlab.sh`, keep the verb names and result shapes, add a stub under
`tests/fixtures/<name>-stub/` with scenario `routes.tsv` files, and mirror the GitLab suites.
Never add a merge, a protected-branch write, or a token in argv.
