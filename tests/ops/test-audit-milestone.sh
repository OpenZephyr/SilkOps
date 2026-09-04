#!/usr/bin/env bash
# Tier 1 tests for scripts/audit-milestone.sh against the glab stub (no network).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
SCRIPT="$ROOT/scripts/audit-milestone.sh"
PASS=0; FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-audit.XXXXXX")"
# shellcheck disable=SC2329
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
export PATH="$STUB_DIR:$PATH"
run() { rm -f "$SCRATCH/log"; env -u GITLAB_TOKEN GLAB_STUB_SCENARIO="$STUB_DIR/audit" GLAB_STUB_LOG="$SCRATCH/log" bash "$SCRIPT" "$@" >"$SCRATCH/out" 2>"$SCRATCH/err"; echo $? >"$SCRATCH/rc"; }
P="void-realm-solutions/silkops-harness-eval"

run --project "$P" --milestone "Surveillance & Triage"
if [ "$(cat "$SCRATCH/rc")" = 0 ] && [ "$(jq -r '.checked' "$SCRATCH/out")" = 4 ] \
   && [ "$(jq -r '.unmarked | length' "$SCRATCH/out")" = 2 ] \
   && [ "$(jq -r '[.unmarked[].iid] | sort | join(",")' "$SCRATCH/out")" = "12,13" ] \
   && [ "$(jq -r .clean "$SCRATCH/out")" = false ]; then pass "T1 unmarked issues reported (2 of 4 objects), clean=false"; else fail "T1" "$(cat "$SCRATCH/out" "$SCRATCH/err")"; fi

run --project "$P" --milestone "Surveillance & Triage" --strict
[ "$(cat "$SCRATCH/rc")" = 1 ] && pass "T2 --strict exits 1 on unmarked objects" || fail "T2" "rc=$(cat "$SCRATCH/rc")"

printf 'ran ops/issue-upsert.sh --project x\nthen glab api projects/1/issues -X POST\nand curl -s https://gitlab.com/api/v4/x -H "PRIVATE-TOKEN: glpat-abcdefghijklmnopqrst"\n' >"$SCRATCH/t.log"
run --project "$P" --milestone "Surveillance & Triage" --transcript "$SCRATCH/t.log"
if [ "$(jq -r '.transcript_hits | length' "$SCRATCH/out")" = 2 ] && ! grep -q 'glpat-abcdef' "$SCRATCH/out"; then pass "T3 transcript glue counted (ops/ lines excluded), token redacted"; else fail "T3" "$(cat "$SCRATCH/out")"; fi

run --project "$P" --milestone "nope"
[ "$(cat "$SCRATCH/rc")" = 5 ] && pass "T4 unknown milestone exits 5" || fail "T4" "rc=$(cat "$SCRATCH/rc")"

run --milestone "x"
[ "$(cat "$SCRATCH/rc")" = 2 ] && [ ! -s "$SCRATCH/log" ] && pass "T5 missing --project exits 2 before any glab call" || fail "T5" "rc=$(cat "$SCRATCH/rc")"

echo "test-audit-milestone: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
