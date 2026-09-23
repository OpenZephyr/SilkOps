#!/usr/bin/env bash
# Tier 1 tests for bin/silkops (v0.3 U1): one entry command that dispatches every ops/ script by
# verb from any cwd, and a doctor verb that reports the machine offline.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/bin/silkops"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-bin.XXXXXX")"
PASS=0; FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }
# shellcheck disable=SC2329
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
run() { local n="$1"; shift; mkdir -p "$SCRATCH/$n"; (cd "$SCRATCH" && env -u SILKOPS_CI_TOKEN -u SILKOPS_SETTINGS_TOKEN -u GH_TOKEN -u GITEA_TOKEN -u CI bash "$BIN" "$@") >"$SCRATCH/$n/out" 2>"$SCRATCH/$n/err"; echo $? >"$SCRATCH/$n/rc"; }
out_of() { cat "$SCRATCH/$1/out"; }; rc_of() { cat "$SCRATCH/$1/rc"; }; err_of() { cat "$SCRATCH/$1/err"; }

# B1: a verb dispatches to its script with the arguments untouched (usage error proves the script ran)
run b1 watch --nope
if [ "$(rc_of b1)" = 2 ] && out_of b1 | jq -e '.ok == false and .error == "usage"' >/dev/null && err_of b1 | grep -q '^watch:'; then
  pass "B1 'silkops watch --nope' runs ops/watch.sh from another cwd and returns its usage error"
else fail "B1" "rc=$(rc_of b1) out=$(out_of b1) err=$(err_of b1 | head -2)"; fi

# B2: python verbs dispatch too
run b2 classify /nonexistent/trace.log
if [ "$(rc_of b2)" = 5 ] && out_of b2 | jq -e '.error == "not_found"' >/dev/null; then
  pass "B2 'silkops classify' runs classify-failure.py"
else fail "B2" "rc=$(rc_of b2) out=$(out_of b2)"; fi

# B3: unknown verb -> exit 2 with the verb list on stderr; help lists every verb
run b3 frobnicate; run b3h --help
if [ "$(rc_of b3)" = 2 ] && out_of b3 | jq -e '.error == "usage"' >/dev/null && err_of b3 | grep -q 'watch' \
  && [ "$(rc_of b3h)" = 0 ] && out_of b3h | grep -q 'milestone-sync' && out_of b3h | grep -q 'doctor'; then
  pass "B3 unknown verb exits 2 naming the verbs; --help lists them"
else fail "B3" "rc=$(rc_of b3)/$(rc_of b3h) err=$(err_of b3 | head -2)"; fi

# B4: doctor is offline JSON: tools found or null, token presence as booleans only, provider, root
run b4 doctor
if [ "$(rc_of b4)" = 0 ] && out_of b4 | jq -e '.ok == true and .root == "'"$ROOT"'" and (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
      and (.tools | has("glab") and has("gh") and has("jq") and has("python3") and has("git"))
      and .tokens.ci == false and .tokens.settings == false and .tokens.github == false and .tokens.gitea == false
      and (.provider | type) == "string" and (.facts_paths | length) >= 1' >/dev/null \
  && ! out_of b4 | grep -qi 'glpat\|ghp_'; then
  pass "B4 doctor reports root, version, tools, token presence (never values), provider and facts_paths"
else fail "B4" "rc=$(rc_of b4) out=$(out_of b4)"; fi

# B5: redact verb filters stdin
if printf 'Authorization: Bearer abc.def.ghi and glpat-secret123\n' | bash "$BIN" redact | grep -q 'REDACTED' \
  && ! printf 'x glpat-secret123\n' | bash "$BIN" redact | grep -q secret123; then
  pass "B5 'silkops redact' masks tokens on stdin"
else fail "B5" "$(printf 'x glpat-secret123\n' | bash "$BIN" redact 2>&1)"; fi

echo "test-silkops: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
