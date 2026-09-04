---
name: registry-ops
description: Zero-copy retag, digest compare, and tag listing against the GitLab container registry through its v2 API; refuses to overwrite an existing tag. Use when the user says "retag the image", "do these tags point at the same digest", "list the tags for", or needs an immutable tag added to a published image.
argument-hint: "<retag|digest|tags> <image> [<tag> [<new-tag>]] [--project <group/project>]"
---

# registry-ops

Zero-copy retag, digest compare, and tag listing on the GitLab container registry. Reads use
the session identity through `glab api`; only `retag` speaks the registry v2 API, and it is a
settings write — the settings token is injected for that call alone.

## Inputs

- `--project <group/project>` — the project that owns the registry (explicit, always).
- `<image>` — repository path below the project (`godot`, `sec-tools`, …).
- Tags as needed by the verb.

## Procedure

- **tags** — `${CLAUDE_PLUGIN_ROOT}/ops/registry.sh --project P tags <image>` → tag list
  with digests. Registry listing lags a fresh push by a few seconds (facts file:
  `registry-listing-lag`); if a just-pushed tag is missing, wait and re-run once.
- **digest** — `ops/registry.sh --project P digest <image> <tag>` → the manifest digest.
  To compare two tags, run it twice and compare; equal digests mean one image, two names.
- **retag** — first `ops/token-check.sh --project P --for settings` (needs Maintainer;
  exit 4 tells you who to ask). Then `ops/registry.sh --project P retag <image> <tag>
  <new-tag> --dry-run` and show the operator: source digest, target tag, whether the target
  exists. On confirmation run without `--dry-run`. The script refuses (exit 7) an existing
  target — tags are immutable; never delete-and-retag to get around it. It verifies both
  digests are equal after the PUT and reports zero blob uploads.

## Guardrails

- `SILKOPS_SETTINGS_TOKEN` is read from the environment by the script; never paste it, never
  put it in a URL or argv.
- Never retag onto an existing tag; never delete a tag from this skill.
- Report the JSON result's `source_digest`/`target_digest` verbatim so the operator can paste
  them into the record.
