# SilkOps

Skills that let a coding agent commit, ship a branch, watch its pipeline, explain a failure and
file issues from a plan, on GitLab, GitHub or Gitea, with no hand-written API glue. It never
merges. A human does.

![one loop, ending at a human](docs/diagrams/ship-watch-loop.excalidraw.svg)

## Install

**Claude Code**

```
/plugin marketplace add OpenZephyr/SilkOps
/plugin install silkops@silkops
```
then once, in a terminal, so the skills find the `silkops` command:
```
bash ~/.claude/plugins/cache/silkops/silkops/*/bin/silkops install-agent claude-code
```

**Codex, Cursor, OpenCode, Gemini CLI**

```
git clone https://github.com/OpenZephyr/SilkOps.git ~/.silkops
~/.silkops/bin/silkops install-agent all
```

Needs `jq`, `curl`, Python 3.9 and the host CLI: `glab` for GitLab, `gh` for GitHub, a
`GITEA_TOKEN` for Gitea. Tokens are read from the environment only.

## Try it

```
silkops doctor
silkops watch --project group/project --mr 42
{"ok":true,"provider":"gitlab","status":"success","ready":true, …}
```

Every verb prints one JSON object and a fixed exit code, so an agent can act on it without
guessing. In a repo, say "adopt silkops" and the agent sets the conventions block and ships the
first merge request.

## Skills

| skill | does |
|---|---|
| `adopt` | connect a repo: check the token, add the conventions block, ship the first MR |
| `commit` | commit named paths in the repo's own message style |
| `ship-mr` | push the branch, open or update its MR, hand off to the watch |
| `watch-pipeline` | bounded watch, fact-based triage, one safe retry, a ready verdict |
| `after-merge` | after a human merged: prune, confirm linked issues, watch the default branch |
| `verify-handoff` | file one issue per surface a session could not test, plus a status doc |
| `milestone-from-plan` | a plan's units become a milestone with linked issues |
| `file-residuals` | review findings as issues, deduplicated by finding |
| `trace-timing` | where the time goes in a job, ranked with numbers |
| `registry-ops` | zero-copy retag, digest compare, tag listing |
| `consumer-onboarding` | connect a project to an image factory, one confirmation per settings write |

## Scope

Never merges, never pushes a protected branch, never edits a closed issue. Tokens never enter
argv, URLs or output. `SILKOPS_MARKER=off` makes every write anonymous. Pipelines and workflow
runs are in scope; cluster CronJobs and anything behind `kubectl` are not.

## More

- Hosts, and what each concept means on each: `docs/providers.md`
- Failure facts and their three layers: `docs/facts.md`
- Tests, mirror and release: `CONTRIBUTING.md`
- Diagrams: `docs/diagrams/README.md`

MIT. Issues and pull requests are welcome on GitHub.
