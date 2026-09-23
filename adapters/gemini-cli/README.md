# Gemini CLI

Discovery: user skills in `~/.gemini/skills` (alias `~/.agents/skills`), workspace skills in `.gemini/skills` (alias `.agents/skills`); the CLI lists name and description at session start and activates a skill on demand. `silkops install-agent gemini-cli` links every skill into `~/.gemini/skills` (`--scope repo` → `.gemini/skills`) and, in repo scope, writes a `GEMINI.md` that imports `AGENTS.md`. Checked 2026-09-23 against https://geminicli.com/docs/cli/skills/.
