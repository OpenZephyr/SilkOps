---
name: consumer-onboarding
description: Onboard a GitLab project onto the silkOps image factory: pre-flight tokens and roles, allow-list the consumer on the factory, pin an image tag plus the conventions block (AGENTS.md) in one MR, watch it pull, then set schedules and variables with a confirmation per settings write. Use when the user says "onboard this repo", "let this project pull the image", "connect this repo to the factory", or "set up the consumer".
argument-hint: "<consumer group/project> <image:tag> [--factory <group/project>] [--group]"
---

# consumer-onboarding

Result: the allow-list entry, the pin MR (URL and pipeline state), schedules created (owner, next
run) and variable keys, each from its `ops/` script's JSON. One confirmation
per settings write, shown as current vs proposed. Read `references/preflight.md` first.

## Steps

1. Pre-flight, read-only: `silkops token-check --project <factory> --for settings` and the same for
   the consumer; `silkops schedule --project <consumer> list`; `silkops registry --project <factory>
   digest <image> <tag>`; `silkops conventions --dir <scratch copy>` (`unchanged` = block present).
   Exit 4 stops with the role needed.
2. Factory: `silkops allowlist --project <factory> add --consumer <consumer> [--group] --dry-run`,
   confirm, then apply. `--group` only on an explicit yes (KD2). `existing: true` = nothing to do.
3. Consumer, one MR: on a new branch set the image to `registry.gitlab.com/<factory>/<image>:<tag>`
   (the `FACTORY_IMAGE_ROOT` pattern), run `silkops conventions --dir <checkout>`, commit with the
   `commit` skill, then `ship-mr` and `watch-pipeline`. A pull success is the verification;
   `pull access denied` within seconds means step 2 did not land (fact `pull-access-denied`).
4. Schedules and variables, each dry-run → show → confirm → apply: `silkops schedule --project
   <consumer> create --description … --cron "0 22 * * *" --ref main --timezone <tz>` (sub-daily
   crons refused unless the operator asks for `--allow-frequent`); `silkops variable --project
   <consumer> set --key K --value-file <path> --masked --protected` (value by file, never pasted).
5. Report the four items above.

## Guardrails

- Hosts: on GitHub a schedule is a workflow file to ship, a masked value is a secret, the
  allow-list is `not_applicable` (`docs/providers.md`).
- Values never enter argv or the transcript; `variable.sh` refuses `--value`.
- No token creation and no protected-branch edit here: those are the by-hand steps in `docs/tokens.md`.
