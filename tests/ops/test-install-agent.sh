#!/usr/bin/env bash
# Tier 1 (v0.3 U7): `silkops install-agent <name|all> [--scope user|repo] [--dry-run]` links the
# skills, the entry command and the conventions import where each agent looks. Scratch HOME.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/bin/silkops"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-adapt.XXXXXX")"
PASS=0; FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }
# shellcheck disable=SC2329
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
H="$SCRATCH/home"; mkdir -p "$H"
run() { local n="$1"; shift; mkdir -p "$SCRATCH/$n"; HOME="$H" bash "$BIN" install-agent "$@" >"$SCRATCH/$n/out" 2>"$SCRATCH/$n/err"; echo $? >"$SCRATCH/$n/rc"; }
out_of() { cat "$SCRATCH/$1/out"; }; rc_of() { cat "$SCRATCH/$1/rc"; }
NSKILLS="$(find "$ROOT/skills" -name SKILL.md | wc -l | tr -d ' ')"

run a1 codex --dry-run
if [ "$(rc_of a1)" = 0 ] && out_of a1 | jq -e --arg h "$H" --argjson n "$NSKILLS" '.ok == true and .dry_run == true and .agent == "codex" and .scope == "user"
      and (.skills_dir | startswith($h + "/.agents/skills")) and (.skills | length) == $n and (.bin | startswith($h + "/.local/bin/silkops")) and .conventions == "AGENTS.md"' >/dev/null \
  && [ ! -e "$H/.agents" ]; then
  pass "A1 codex dry run names ~/.agents/skills, the bin link and AGENTS.md; writes nothing"
else fail "A1" "rc=$(rc_of a1) out=$(out_of a1) err=$(cat "$SCRATCH/a1/err")"; fi

run a2 all --dry-run
if [ "$(rc_of a2)" = 0 ] && out_of a2 | jq -e '(.agents | length) == 5 and ([.agents[].agent] | sort) == ["claude-code","codex","cursor","gemini-cli","opencode"]
      and (.agents[] | select(.agent == "opencode") | .skills_dir | endswith("/.config/opencode/skills"))
      and (.agents[] | select(.agent == "cursor") | .skills_dir | endswith("/.cursor/skills"))
      and (.agents[] | select(.agent == "gemini-cli") | .conventions == "GEMINI.md imports AGENTS.md")
      and (.agents[] | select(.agent == "claude-code") | .skills_dir | endswith("/.claude/skills"))' >/dev/null; then
  pass "A2 'all' lists the five adapters with each agent's own discovery path"
else fail "A2" "rc=$(rc_of a2) out=$(out_of a2 | head -c 800)"; fi

run a3 opencode
if [ "$(rc_of a3)" = 0 ] && out_of a3 | jq -e '.dry_run == false and .linked == true' >/dev/null \
  && [ -L "$H/.config/opencode/skills/watch-pipeline" ] && [ "$(readlink "$H/.config/opencode/skills/watch-pipeline")" = "$ROOT/skills/watch-pipeline" ] \
  && [ "$(find "$H/.config/opencode/skills" -maxdepth 1 -type l | wc -l | tr -d ' ')" = "$NSKILLS" ] \
  && [ -L "$H/.local/bin/silkops" ] && [ -x "$H/.local/bin/silkops" ]; then
  pass "A3 opencode install links every skill directory and the entry command into the scratch HOME"
else fail "A3" "rc=$(rc_of a3) out=$(out_of a3) ls=$(ls -la "$H/.config/opencode/skills" 2>&1 | head -3)"; fi

run a4 opencode
if [ "$(rc_of a4)" = 0 ] && out_of a4 | jq -e '.linked == true and .unchanged == true' >/dev/null; then
  pass "A4 a second install is a no-op (links already right)"
else fail "A4" "rc=$(rc_of a4) out=$(out_of a4)"; fi

mkdir -p "$SCRATCH/repo"; ( cd "$SCRATCH/repo" && git init -q ); run a5 gemini-cli --scope repo --dir "$SCRATCH/repo"
if [ "$(rc_of a5)" = 0 ] && [ -L "$SCRATCH/repo/.gemini/skills/commit" ] && grep -qx '@AGENTS.md' "$SCRATCH/repo/GEMINI.md" && [ -f "$SCRATCH/repo/AGENTS.md" ]; then
  pass "A5 gemini-cli repo scope links .gemini/skills and writes GEMINI.md importing AGENTS.md (created from the neutral block)"
else fail "A5" "rc=$(rc_of a5) out=$(out_of a5) gem=$(cat "$SCRATCH/repo/GEMINI.md" 2>&1)"; fi

run a6 vim
if [ "$(rc_of a6)" = 2 ]; then pass "A6 unknown agent exits 2"; else fail "A6" "rc=$(rc_of a6)"; fi

echo "test-install-agent: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
