# Tokens: creation, scope, storage, rotation, leak posture

Three identities touch GitLab on the harness's behalf. Only two are tokens the harness reads.

| Identity | Where | Role / scopes | Used for |
|---|---|---|---|
| Operator's own account | `glab auth login` on the workstation | whatever the operator has | issues, MRs, notes, reads — everything that is not a settings write |
| Settings token `SILKOPS_SETTINGS_TOKEN` | **group** access token on `void-realm-solutions` (bot user id `42306934`), exported in the operator's shell | group access token, **Maintainer**, `api`, expiry ≤ 90 days — valid on every project in the group, including projects created later | allow-list, schedules, variables, registry retag |
| CI token `SILKOPS_CI_TOKEN` | **group** access token on `void-realm-solutions`, stored as a masked + protected CI variable on each project running the harness image | group access token, **Developer** (the lowest role that can open MRs), `api` — likewise group-wide | the operations scripts inside CI jobs |

Both tokens are group access tokens on `void-realm-solutions`. That is a deliberate
deviation from KD2 (per project by default, group only on the operator's explicit
confirmation); the operator created them that way and confirmed it. Everything below that
says "the project" now reads "every project in the group" — see *Blast radius*.

The factory's own `FACTORY_RECORDS_TOKEN` (`write_repository`, records commit-back) is
unrelated and is never borrowed.

## Creation (by hand, Settings → Access tokens on the group)

1. Before any settings token exists, move `main`'s protection from the Maintainers role to
   explicit principals — push: the records bot; merge: the operator. Otherwise the token's
   bot user is on the merge/push list by construction (plan R15). The harness never edits
   protected-branch rules; `ops/` scripts refuse the endpoint and the CI gate greps for it.

   **Satisfied on `ci-cd`.** `main` there now names explicit principals only: push =
   `silkops-factory-records` (id `41938268`), merge = `Dominic` (id `9820378`). No role
   entries remain on either list, and the settings-token bot (id `42306934`) is on neither —
   so on `ci-cd` the settings token cannot push or merge `main`.

   **Not satisfied group-wide.** The precondition is per project, and the token is not:
   other projects in `void-realm-solutions` may still protect `main` by role (Maintainers),
   and on those the settings token *can* push or merge `main` because its bot holds
   Maintainer through the group. That is the remaining exposure; it closes one project at a
   time, by naming explicit principals there too.
2. Create the settings token on the group; name it `silkops-settings`; note the bot username
   the group creates for it. Export it: `export SILKOPS_SETTINGS_TOKEN=…` in the shell profile.
3. Create the CI token on the group; name it `silkops-ci`; store it as a masked, protected
   variable on each project that runs the harness image (`ops/variable.sh … --masked
   --protected` from an operator session, value from a file). Never paste a token into a
   Claude Code session.

## Storage — the accepted exposure

`SILKOPS_SETTINGS_TOKEN` is a plain exported environment variable, so any command a session
runs can read it, including one steered by hostile text in a trace or issue. This was
weighed against an on-demand keychain lookup and per-write prompting and accepted
(plan Risks): mitigations are short expiry and the scripts' refusal to merge, push protected
branches, or touch protected-branch rules. Per-project scope was the third mitigation and is
no longer in force — both tokens are group-scoped on the operator's confirmation (KD2), so
short expiry and the script-level refusals carry the whole weight.

### Blast radius

A group access token is not a project secret. A leak of `SILKOPS_SETTINGS_TOKEN` is a
compromise of **every project in `void-realm-solutions`, present and future** — a project
added to the group tomorrow is in range of a token leaked today, with no further action by
anyone. The same holds for `SILKOPS_CI_TOKEN` at Developer. Concretely, one leaked settings
token can read and rewrite CI/CD variables, schedules, job-token allow-lists and registry
tags across the whole group, and on any project whose `main` is still protected by role it
can also push and merge there. Sizing an incident by "which project was the token on" no
longer works; the unit is the group.

## Rotation

Rotate with the token rotation endpoint — for these two the **group** one (`glab api -X POST
groups/:id/access_tokens/:token_id/rotate`; the `projects/:id/…` form is for a project token
and no longer applies) — never revoke-and-recreate: schedules the
harness created belong to the token's bot user and deactivate if that user disappears.
Update the exported variable (settings) or the CI variable (CI) after rotating.

## Leak posture

A leaked settings token is a group compromise, and every step below runs **once per project
in `void-realm-solutions`**, not once: revoke the token at the group, then rotate every CI
variable it could read and re-verify `main`'s protected-branch principals and the job-token
allow-list on each project — a Maintainer token can rewrite both, so a leak is not only a
variable leak. Give the projects whose `main` is still role-protected priority: the token
could have pushed or merged there, so their `main` history needs checking too. A leaked CI
token (Developer) can open MRs and file issues anywhere in the group: revoke, rotate, audit
recent MRs and issues for unmarked objects across every project.

## Pre-flight

`ops/token-check.sh --project <p> --for settings|ci|session` reports identity, role,
scopes, expiry, and (for the session) whether the identity can merge or push protected
branches. Skills run it before any settings write and stop on exit 4 (needs Maintainer) or
exit 3 (no token). In CI, `require_ci_token` fails before any network call when
`SILKOPS_CI_TOKEN` is missing.
