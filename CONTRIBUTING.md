# Contributing

- `bash tests/run.sh` runs tier 1: offline, fixture-driven, gates every change. CI also runs
  shellcheck on `ops/`, `ops/lib/`, `bin/silkops` and `scripts/`.
- `AGENTS.md` holds the conventions every agent and contributor follows; `.claude/CLAUDE.md` and
  `GEMINI.md` only import it.
- Source of truth is GitLab (`void-realm-solutions/silkops-harness`). GitHub
  (`OpenZephyr/SilkOps`) is a main-only mirror. `silkops inbox --repo OpenZephyr/SilkOps` lists
  what people file there; a GitHub pull request is fetched as a branch and shipped through
  GitLab, closing on GitHub via `Closes #n`.
- Release, in order:
  1. On a release branch, `scripts/bump.sh X.Y.Z` (try `--dry-run` first): sets the version in
     `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`, writes `dist/notes-X.Y.Z.md`
     from the commits since the previous `silkops-harness--v*` tag (the issues their `Closes #n`
     lines close, then the subjects grouped by type) and commits `release: X.Y.Z`. It refuses a
     dirty tree or the default branch and never pushes.
  2. Ship the branch as an MR; merge it.
  3. On main, at the merge commit: `scripts/tag.sh` (try `--dry-run` first) creates the annotated
     tag `silkops-harness--vX.Y.Z` from the manifests' version and pushes only that ref. The tag
     format is pinned by the image factory in `ci-cd`; do not change it, and do not use
     `claude plugin tag`: since the plugin id is `silkops` it cuts `silkops--vX.Y.Z`, which no
     release rule matches.
  4. CI on the tag: the `release` job publishes the tarball, its sha256, the runbook and the notes
     to the generic package registry and creates the GitLab Release (updates it on 409). The
     `github-release` job runs only when a masked `GH_TOKEN` CI variable exists and publishes the
     same release on `OpenZephyr/SilkOps`; otherwise run
     `scripts/github-release.sh --repo OpenZephyr/SilkOps --tag <tag>` by hand once the mirror has
     the tag. `--update` rewrites the title and notes of a release that already exists;
     `--dry-run` prints the plan.
- Diagrams are Excalidraw scenes; see `docs/diagrams/README.md`.
