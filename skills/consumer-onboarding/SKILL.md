---
name: consumer-onboarding
description: Onboard a GitLab project onto the silkOps image factory: pre-flight tokens and roles, allow-list the consumer on the factory, pin an image tag plus the harness CLAUDE.md snippet in one MR, watch it pull, then set schedules and variables with a confirmation per settings write. Use when the user says "onboard this repo", "let this project pull the image", "connect this repo to the factory", or "set up the consumer".
argument-hint: "<consumer group/project> <image:tag> [--factory <group/project>] [--group]"
---

# consumer-onboarding

Onboard a GitLab project onto the silkOps image factory in two phases across two projects,
with a confirmation before every settings write. Phase A acts on the factory; Phase B acts on
the consumer. The settings token is injected only around settings writes; everything else
runs as the operator.

**Read `references/preflight.md` before Step 1.**

## Inputs

- `<consumer group/project>` and `<image:tag>` (an immutable `<version>-r<N>` tag).
- `--factory <group/project>` — defaults to `void-realm-solutions/ci-cd`.
- `--group` — only when the operator explicitly wants the whole group allow-listed
  (KD2: per project by default; group scope needs a stated yes).

## Procedure

1. **Pre-flight** (read-only): `${CLAUDE_PLUGIN_ROOT}/ops/token-check.sh --project <factory>
   --for settings` and `… --project <consumer> --for settings`; `ops/schedule.sh --project
   <consumer> list`; check whether the consumer's `CLAUDE.md` already carries the harness
   snippet (`references/claude-md-snippet.md` at the plugin root); confirm the factory image
   tag exists (`ops/registry.sh --project <factory> digest <image> <tag>`). Report the checklist
   from `references/preflight.md`. Stop on exit 4 and name the role needed.
2. **Phase A — allow-list on the factory.** `ops/allowlist.sh --project <factory> add
   --consumer <consumer> [--group] --dry-run` → show current entries and the proposed one.
   Ask the operator to confirm. Then run without `--dry-run`. `existing: true` means nothing
   to do.
3. **Phase B — pin plus snippet in one MR on the consumer.** On a new branch in a checkout of
   the consumer: set the image reference to `registry.gitlab.com/<factory>/<image>:<tag>`
   in its CI (the `FACTORY_IMAGE_ROOT` pattern from ci-cd's task files); create or append
   `CLAUDE.md` with the snippet (skip lines already present — no duplicates); commit; then
   invoke `ship-mr` for that branch and `watch-pipeline` for the MR. The pull succeeding in
   that pipeline is the verification; `pull access denied` within seconds means Phase A did
   not land (facts file: `pull-access-denied`).
4. **Schedules and variables on the consumer** (each one: dry-run, show, confirm, apply):
   `ops/schedule.sh --project <consumer> create --description … --cron "0 22 * * *" --ref
   main --timezone <tz>` (the script refuses sub-daily crons unless `--allow-frequent`; do
   not add that flag without the operator asking); `ops/variable.sh --project <consumer> set
   --key <K> --value-file <path> --masked --protected` — tell the operator to place the value
   in a file, never to paste it into the session.
5. **Report**: allow-list entry, MR URL and pipeline state, schedules created (owner,
   next run), variables created (keys only).

## Guardrails

- One confirmation per settings write; show current vs proposed before asking.
- Group-scoped allow-listing only with `--group` and an explicit operator yes.
- Values never enter argv or the transcript; `variable.sh` refuses `--value`.
- Do not create the settings token or edit protected branches from this skill — those are
  the by-hand pre-steps in `docs/tokens.md`.
