#!/usr/bin/env bash
# conventions.sh — write the neutral conventions block into a consumer checkout (v0.2 U4, KD4).
#
# Usage: conventions.sh --dir <checkout> [--snippet <file>]
#
# AGENTS.md gets references/agents-md-snippet.md appended once (a block whose heading is
# already present is left alone); CLAUDE.md is created as the one-line `@AGENTS.md` import
# when absent, and kept untouched when it has content of its own. Names no plugin.
# Result: {agents_md: created|appended|unchanged, claude_md: created|unchanged|kept}.
# Exit codes: 0 ok · 2 usage · 5 directory or snippet missing · 1 other.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"

DIR=""; SNIPPET="$SILKOPS_ROOT/references/agents-md-snippet.md"
usage() { fail "$EX_USAGE" usage "usage: conventions.sh --dir <checkout> [--snippet <file>]${1:+ — $1}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || usage "--dir needs a value"; DIR="$2"; shift 2 ;;
    --snippet) [ $# -ge 2 ] || usage; SNIPPET="$2"; shift 2 ;;
    *) usage "unknown argument: $1" ;;
  esac
done
[ -n "$DIR" ] || usage "--dir is required"
[ -d "$DIR" ] || fail "$EX_NOT_FOUND" not_found "directory not found: $DIR"
[ -f "$SNIPPET" ] || fail "$EX_NOT_FOUND" not_found "snippet not found: $SNIPPET"

heading="$(grep -m1 '^## ' "$SNIPPET")"
agents="$DIR/AGENTS.md"; claude="$DIR/CLAUDE.md"
if [ ! -f "$agents" ]; then
  cat "$SNIPPET" >"$agents"; a=created
elif grep -Fx -- "$heading" "$agents" >/dev/null; then
  a=unchanged
else
  { printf '\n'; cat "$SNIPPET"; } >>"$agents"; a=appended
fi
if [ ! -f "$claude" ]; then
  printf '@AGENTS.md\n' >"$claude"; c=created
elif [ "$(tr -d '[:space:]' <"$claude")" = "@AGENTS.md" ]; then
  c=unchanged
else
  c=kept; err "CLAUDE.md has its own content and was kept; move it into AGENTS.md and leave @AGENTS.md"
fi
result "$(jq -cn --arg a "$a" --arg c "$c" --arg agents "$agents" --arg claude "$claude" \
  '{agents_md: $a, claude_md: $c, files: [$agents, $claude]}')"
