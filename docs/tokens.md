# Tokens: creation, scope, storage, rotation, leak posture

Three identities touch GitLab on the harness's behalf. Only two are tokens the harness reads.

| Identity | Where | Role / scopes | Used for |
|---|---|---|---|
| Operator's own account | `glab auth login` on the workstation | whatever the operator has | issues, MRs, notes, reads — everything that is not a settings write |
| Settings token `SILKOPS_SETTINGS_TOKEN` | exported in the operator's shell | project access token, **Maintainer**, `api`, expiry ≤ 90 days, one per project by default | allow-list, schedules, variables, registry retag |
| CI token `SILKOPS_CI_TOKEN` | masked + protected CI variable on each project running the harness image | project access token, **Developer** (the lowest role that can open MRs), `api` | the operations scripts inside CI jobs |

The factory's own `FACTORY_RECORDS_TOKEN` (`write_repository`, records commit-back) is
unrelated and is never borrowed.

## Creation (by hand, Settings → Access tokens on the project)

1. Before any settings token exists, move `main`'s protection from the Maintainers role to
   explicit principals — push: the records bot; merge: the operator. Otherwise the token's
   bot user is on the merge/push list by construction (plan R15). The harness never edits
   protected-branch rules; `ops/` scripts refuse the endpoint and the CI gate greps for it.
2. Create the settings token; name it `silkops-settings`; note the bot username the project
   creates for it. Export it: `export SILKOPS_SETTINGS_TOKEN=…` in the shell profile.
3. Create the CI token; name it `silkops-ci`; store it as a masked, protected variable on the
   project (`ops/variable.sh … --masked --protected` from an operator session, value from a
   file). Never paste a token into a Claude Code session.

## Storage — the accepted exposure

`SILKOPS_SETTINGS_TOKEN` is a plain exported environment variable, so any command a session
runs can read it, including one steered by hostile text in a trace or issue. This was
weighed against an on-demand keychain lookup and per-write prompting and accepted
(plan Risks): mitigations are short expiry, per-project scope, and the scripts' refusal to
merge, push protected branches, or touch protected-branch rules. Group-scoped tokens only
when the operator explicitly asks (KD2).

## Rotation

Rotate with the token rotation endpoint (`glab api -X POST
projects/:id/access_tokens/:token_id/rotate`), never revoke-and-recreate: schedules the
harness created belong to the token's bot user and deactivate if that user disappears.
Update the exported variable (settings) or the CI variable (CI) after rotating.

## Leak posture

A leaked settings token is a project compromise: revoke it, rotate every CI variable it could
read, then re-verify `main`'s protected-branch principals and the job-token allow-list — a
Maintainer token can rewrite both, so a leak is not only a variable leak. A leaked CI token
(Developer) can open MRs and file issues: revoke, rotate, audit recent MRs and issues for
unmarked objects.

## Pre-flight

`ops/token-check.sh --project <p> --for settings|ci|session` reports identity, role,
scopes, expiry, and (for the session) whether the identity can merge or push protected
branches. Skills run it before any settings write and stop on exit 4 (needs Maintainer) or
exit 3 (no token). In CI, `require_ci_token` fails before any network call when
`SILKOPS_CI_TOKEN` is missing.
