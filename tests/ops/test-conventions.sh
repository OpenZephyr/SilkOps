#!/usr/bin/env bash
# Tier 1 tests for ops/conventions.sh (v0.2 U4): the neutral AGENTS.md block and the one-line
# CLAUDE.md import, written idempotently into a consumer checkout. Offline, no glab.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/ops/conventions.sh"
SNIPPET="$ROOT/references/agents-md-snippet.md"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-conv.XXXXXX")"
PASS=0; FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }
# shellcheck disable=SC2329
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
run() { local d="$SCRATCH/$1"; shift; mkdir -p "$d"; bash "$SCRIPT" "$@" >"$d/out" 2>"$d/err"; echo $? >"$d/rc"; }
out_of() { cat "$SCRATCH/$1/out"; }
rc_of() { cat "$SCRATCH/$1/rc"; }

# C1: the snippet is neutral — no plugin, vendor or organisation name, at most five bullets
if [ -f "$SNIPPET" ] && ! grep -Eiq 'silkops|claude|anthropic|void-realm|glab' "$SNIPPET" \
  && [ "$(grep -c '^- ' "$SNIPPET")" -le 5 ] && [ "$(grep -c '^- ' "$SNIPPET")" -ge 3 ]; then
  pass "C1 agents-md-snippet.md is neutral (no plugin/vendor/org name) and three to five bullets"
else fail "C1" "missing, named something, or wrong bullet count: $(grep -c '^- ' "$SNIPPET" 2>/dev/null)"; fi

# C2: empty checkout -> AGENTS.md created with the block, CLAUDE.md is exactly the import
mkdir -p "$SCRATCH/c2/repo"; run c2 --dir "$SCRATCH/c2/repo"
if [ "$(rc_of c2)" = 0 ] && out_of c2 | jq -e '.ok == true and .agents_md == "created" and .claude_md == "created"' >/dev/null \
  && [ "$(cat "$SCRATCH/c2/repo/CLAUDE.md")" = "@AGENTS.md" ] \
  && grep -F -- "$(grep '^- ' "$SNIPPET" | head -1)" "$SCRATCH/c2/repo/AGENTS.md" >/dev/null; then
  pass "C2 empty checkout: AGENTS.md carries the block, CLAUDE.md is exactly @AGENTS.md"
else fail "C2" "rc=$(rc_of c2) out=$(out_of c2) err=$(cat "$SCRATCH/c2/err")"; fi

# C3: second run changes nothing
cp "$SCRATCH/c2/repo/AGENTS.md" "$SCRATCH/c2/agents.before"; run c3 --dir "$SCRATCH/c2/repo"
if [ "$(rc_of c3)" = 0 ] && out_of c3 | jq -e '.agents_md == "unchanged" and .claude_md == "unchanged"' >/dev/null \
  && cmp -s "$SCRATCH/c2/agents.before" "$SCRATCH/c2/repo/AGENTS.md"; then
  pass "C3 rerun is a no-op: both files byte-identical, both reported unchanged"
else fail "C3" "rc=$(rc_of c3) out=$(out_of c3)"; fi

# C4: existing AGENTS.md text survives above the block; a CLAUDE.md with its own content is kept, not replaced
mkdir -p "$SCRATCH/c4/repo"; printf '# my repo\n\nHouse rules here.\n' >"$SCRATCH/c4/repo/AGENTS.md"; printf '# old claude notes\n' >"$SCRATCH/c4/repo/CLAUDE.md"
run c4 --dir "$SCRATCH/c4/repo"
if [ "$(rc_of c4)" = 0 ] && out_of c4 | jq -e '.agents_md == "appended" and .claude_md == "kept"' >/dev/null \
  && head -1 "$SCRATCH/c4/repo/AGENTS.md" | grep -x '# my repo' >/dev/null \
  && grep -F 'House rules here.' "$SCRATCH/c4/repo/AGENTS.md" >/dev/null \
  && [ "$(cat "$SCRATCH/c4/repo/CLAUDE.md")" = "# old claude notes" ]; then
  pass "C4 existing AGENTS.md text kept above the block; a CLAUDE.md with content is kept and reported"
else fail "C4" "rc=$(rc_of c4) out=$(out_of c4) agents=$(head -3 "$SCRATCH/c4/repo/AGENTS.md")"; fi

# C5: usage without --dir, missing dir -> 2 / 5
run c5 ; run c5b --dir "$SCRATCH/nope"
if [ "$(rc_of c5)" = 2 ] && [ "$(rc_of c5b)" = 5 ] && out_of c5b | jq -e '.ok == false' >/dev/null; then
  pass "C5 exit 2 without --dir, exit 5 on a missing directory"
else fail "C5" "rc=$(rc_of c5)/$(rc_of c5b)"; fi

echo "test-conventions: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
