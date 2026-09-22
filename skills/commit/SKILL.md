---
name: commit
description: Commit named files on a feature branch with a message in the repo's own style and no attribution trailers unless the repo asks for them. Use when the user says "commit this", "commit these files", "save my work as a commit", or before ship-mr needs a commit.
argument-hint: "<paths...> [--trailers none|repo]"
---

# commit

Result: one JSON line `{sha, subject, files[], trailers_removed, branch, trailers}` from
`${CLAUDE_PLUGIN_ROOT}/ops/commit.sh`. Refused (exit 7) on the default branch, on a detached
HEAD, or when the subject breaks the repo's style. Never pushes.

## Steps

1. `git branch --show-current` and `git status --porcelain`: name the paths that belong to this
   change; everything else stays out (never `-A`, never `.`).
2. Write the message to a scratch file: subject at most 72 characters, imperative, in the style
   of `git log -20 --format=%s` (a `type(scope):` prefix only if that history uses one), then a
   short body saying why. No trailers of any kind in the file.
3. Trailers policy: `--trailers repo` only when the repo's `AGENTS.md` asks for attribution
   lines and the project is in the operator's own group (`token-check.sh` reports the group).
   Otherwise the default `none` strips any that slipped in.
4. `ops/commit.sh --message-file <f> --path <p> [--path <p>]... [--trailers none|repo]`.
   One commit per reviewable step; two commits when a reviewer may want to drop one.
5. Report the sha and subject. Hand off to `ship-mr` when the branch is ready.

## Guardrails

- Only the named paths are staged and committed; pre-staged files are not swept in.
- A style refusal is fixed by rewriting the message, never by `--no-verify` or `git commit` by hand.
- `SILKOPS_TRAILERS=repo` in the environment changes the default for a whole session.
