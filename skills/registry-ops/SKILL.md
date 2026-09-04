---
name: registry-ops
description: Zero-copy retag, digest compare, and tag listing against the GitLab container registry through its v2 API; refuses to overwrite an existing tag. Use when the user says "retag the image", "do these tags point at the same digest", "list the tags for", or needs an immutable tag added to a published image.
argument-hint: "<retag|digest|tags> <image> [<tag> [<new-tag>]] [--project <group/project>]"
---

# registry-ops

Stub — the procedure lands in its implementation unit (see the plan's Unit Index).
It composes operations from `${CLAUDE_PLUGIN_ROOT}/ops/` and reads the runbook at
`${CLAUDE_PLUGIN_ROOT}/references/runbook.md`.
