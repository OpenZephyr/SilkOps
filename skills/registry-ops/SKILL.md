---
name: registry-ops
description: Zero-copy retag, digest compare, and tag listing against the GitLab container registry through its v2 API; refuses to overwrite an existing tag. Use when the user says "retag the image", "do these tags point at the same digest", "list the tags for", or needs an immutable tag added to a published image.
argument-hint: "<retag|digest|tags> <image> [<tag> [<new-tag>]] [--project <group/project>]"
---

# registry-ops

Result: one JSON line from `silkops registry --project P <verb> …`: `tags` (tag
list with digests), `digest` (one manifest digest), `retag` (`source_digest`, `target_digest`,
zero blob uploads). Only `retag` is a settings write; the settings token is injected for that call.

## Steps

- `tags <image>`: listing lags a fresh push by seconds (fact `registry-listing-lag`); a missing
  just-pushed tag means wait and run once more.
- `digest <image> <tag>`: to compare two tags run it twice; equal digests are one image, two names.
- `retag <image> <tag> <new-tag>`: first `silkops token-check --project P --for settings` (exit 4
  names who to ask). Then `--dry-run`, show source digest, target tag and whether it exists,
  confirm, apply. An existing target is refused (exit 7): tags are immutable, never delete-and-retag.

## Guardrails

- Hosts: GitLab registry today; GHCR and Gitea registries follow the same v2 API (v0.3 U4).
- `SILKOPS_SETTINGS_TOKEN` is read by the script from the environment; never in argv or a URL.
- Never delete a tag from this skill. Report both digests verbatim for the record.
