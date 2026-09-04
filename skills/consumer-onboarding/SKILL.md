---
name: consumer-onboarding
description: Onboard a GitLab project onto the silkOps image factory: pre-flight tokens and roles, allow-list the consumer on the factory, pin an image tag plus the harness CLAUDE.md snippet in one MR, watch it pull, then set schedules and variables with a confirmation per settings write. Use when the user says "onboard this repo", "let this project pull the image", "connect this repo to the factory", or "set up the consumer".
argument-hint: "<consumer group/project> <image:tag> [--factory <group/project>] [--group]"
---

# consumer-onboarding

Stub — the procedure lands in its implementation unit (see the plan's Unit Index).
It composes operations from `${CLAUDE_PLUGIN_ROOT}/ops/` and reads the runbook at
`${CLAUDE_PLUGIN_ROOT}/references/runbook.md`.
