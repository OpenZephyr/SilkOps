#!/usr/bin/env bash
# Tier 1 tests for scripts/gate-overlay-only.sh (v0.2 U3, KTD2): the private overlay branch may
# only add files under overlay/; any other difference to the base is refused. Offline: a scratch
# git repo stands in for the real one.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/gate-overlay-only.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-gate.XXXXXX")"
PASS=0; FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }
# shellcheck disable=SC2329
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
G="$SCRATCH/repo"; mkdir -p "$G"
g() { git -C "$G" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
g init -q -b main >/dev/null; mkdir -p "$G/ops"; echo core >"$G/ops/a.sh"; g add -A; g commit -qm base
g switch -qc clean; mkdir -p "$G/overlay/facts.d"; echo '{"facts":[]}' >"$G/overlay/facts.d/void.json"; g add -A; g commit -qm overlay
g switch -qc dirty main; echo changed >"$G/ops/a.sh"; mkdir -p "$G/overlay"; echo x >"$G/overlay/r.md"; g add -A; g commit -qm touch-core
run() { local n="$1"; shift; mkdir -p "$SCRATCH/$n"; (cd "$G" && bash "$SCRIPT" "$@") >"$SCRATCH/$n/out" 2>"$SCRATCH/$n/err"; echo $? >"$SCRATCH/$n/rc"; }
out_of() { cat "$SCRATCH/$1/out"; }; rc_of() { cat "$SCRATCH/$1/rc"; }

g switch -q clean; run g1 --base main
if [ "$(rc_of g1)" = 0 ] && out_of g1 | jq -e '.ok == true and .outside_overlay == [] and .base == "main"' >/dev/null; then
  pass "G1 a branch that only adds overlay/ files passes"
else fail "G1" "rc=$(rc_of g1) out=$(out_of g1) err=$(cat "$SCRATCH/g1/err")"; fi

g switch -q dirty; run g2 --base main
if [ "$(rc_of g2)" = 7 ] && out_of g2 | jq -e '.ok == false and .error == "refused" and .outside_overlay == ["ops/a.sh"]' >/dev/null; then
  pass "G2 a branch touching a core path is refused (exit 7) and names the path"
else fail "G2" "rc=$(rc_of g2) out=$(out_of g2) err=$(cat "$SCRATCH/g2/err")"; fi

run g3 --base nope; run g4 --bogus
if [ "$(rc_of g3)" = 5 ] && [ "$(rc_of g4)" = 2 ]; then
  pass "G3 unknown base exits 5; unknown argument exits 2"
else fail "G3" "rc=$(rc_of g3)/$(rc_of g4)"; fi

echo "test-gate-overlay: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
