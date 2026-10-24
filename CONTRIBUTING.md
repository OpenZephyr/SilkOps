# Contributing

- `bash tests/run.sh` runs tier 1: offline, fixture-driven, gates every change. CI also runs
  shellcheck on `ops/`, `ops/lib/` and `bin/silkops`.
- `AGENTS.md` holds the conventions every agent and contributor follows; `.claude/CLAUDE.md` and
  `GEMINI.md` only import it.
- Source of truth is GitLab (`void-realm-solutions/silkops-harness`). GitHub
  (`OpenZephyr/SilkOps`) is a main-only mirror. `silkops inbox --repo OpenZephyr/SilkOps` lists
  what people file there; a GitHub pull request is fetched as a branch and shipped through
  GitLab, closing on GitHub via `Closes #n`.
- Release: bump `.claude-plugin/plugin.json`, tag `silkops-harness--vX.Y.Z` on main (CI publishes
  the asset to GitLab), then `scripts/github-release.sh --repo OpenZephyr/SilkOps --tag <tag>`.
- Diagrams are Excalidraw scenes; see `docs/diagrams/README.md`.
