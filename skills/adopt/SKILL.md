---
name: adopt
description: Connect a repository to SilkOps without an image factory: check the session token's role, add the conventions block, record the operator, then commit, ship the first merge request and watch it. Use when the user says "adopt silkops", "use silkops here", "connect this repo", or "set up silkops" on a repo that pulls no factory image.
argument-hint: "<group/project> [--operator <username>]"
---

# adopt

Result: the role found, the conventions result (`written` or `unchanged`), the operator
recorded, the MR URL and the watch verdict, one line each. No settings write, no factory step;
for a repo that pulls a factory image use `consumer-onboarding` instead.

## Steps

1. `silkops doctor` names the host CLI and the token in the environment. Exit 3 stops: ask for
   `SILKOPS_CI_TOKEN` (or `GH_TOKEN`, `GITEA_TOKEN`); never read it from a file or chat.
2. `silkops token-check --project <P> --expect-role Developer`. Exit 4 stops with the role needed.
3. On a new branch: `silkops conventions --dir <checkout>` adds the `AGENTS.md` block (and the
   one-line `CLAUDE.md` / `GEMINI.md` imports). `unchanged` means the repo already has it.
4. Operator: with `--operator`, write `operator_username` into `.silkops/facts.json` (create the
   file with `{}` first if absent); without it, ask once and skip on no answer.
5. `commit` skill on the changed paths, then `ship-mr`, then `watch-pipeline`. The MR is the
   verification: a green pipeline and a `ready` verdict. Never merge.
6. Report the five lines above and the human step: merge the MR.

## Guardrails

- Every write names `--project`; nothing is inferred from the cwd remote.
- Outside the operator's group, run with `SILKOPS_MARKER=off` unless the owner opts in.
- Nothing is added to the repo beyond `.silkops/facts.json` and the conventions block.
