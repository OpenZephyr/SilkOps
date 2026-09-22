#!/usr/bin/env bash
# Tier 1 tests for ops/inbox.sh and scripts/github-release.sh (v0.2 U6, KD3): read-only GitHub
# inbox over a gh stub; the release script's dry run shows the gh command without running it.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB="$ROOT/tests/fixtures/gh-stub"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-inbox.XXXXXX")"
PASS=0; FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }
# shellcheck disable=SC2329
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
export PATH="$STUB:$PATH" GH_STUB_DIR="$STUB"
run() { local n="$1"; shift; mkdir -p "$SCRATCH/$n"; GH_STUB_LOG="$SCRATCH/$n/gh.log" bash "$@" >"$SCRATCH/$n/out" 2>"$SCRATCH/$n/err"; echo $? >"$SCRATCH/$n/rc"; }
out_of() { cat "$SCRATCH/$1/out"; }; rc_of() { cat "$SCRATCH/$1/rc"; }; log_of() { cat "$SCRATCH/$1/gh.log" 2>/dev/null; }

run i1 "$ROOT/ops/inbox.sh" --repo example/silkops-harness
if [ "$(rc_of i1)" = 0 ] && out_of i1 | jq -e '.ok == true and .repo == "example/silkops-harness"
      and (.issues | length) == 1 and .issues[0].number == 5 and .issues[0].author == "someone" and .issues[0].labels == ["help wanted"]
      and (.prs | length) == 1 and .prs[0].number == 6 and .prs[0].head == "bot/bump" and .prs[0].draft == false' >/dev/null \
  && ! log_of i1 | grep -E -- '-X (POST|PUT|PATCH|DELETE)' >/dev/null; then
  pass "I1 inbox lists open issues (PRs filtered out of the issues list) and open PRs, read-only"
else fail "I1" "rc=$(rc_of i1) out=$(out_of i1) log=$(log_of i1 | tr '\n' ';')"; fi

run i2 "$ROOT/ops/inbox.sh"
if [ "$(rc_of i2)" = 2 ] && [ -z "$(log_of i2)" ]; then pass "I2 missing --repo exits 2 before any gh call"; else fail "I2" "rc=$(rc_of i2)"; fi

run r1 "$ROOT/scripts/github-release.sh" --repo example/silkops-harness --tag silkops-harness--v0.2.0 --dry-run
if [ "$(rc_of r1)" = 0 ] && out_of r1 | jq -e '.ok == true and .dry_run == true and .tag == "silkops-harness--v0.2.0" and .version == "0.2.0"
      and (.asset | endswith("silkops-harness-0.2.0.tar.gz")) and (.command | contains("gh release create silkops-harness--v0.2.0"))' >/dev/null \
  && [ -z "$(log_of r1)" ]; then
  pass "R1 github-release dry run names the tag, version, asset and gh command; runs nothing"
else fail "R1" "rc=$(rc_of r1) out=$(out_of r1) log=$(log_of r1)"; fi

run r2 "$ROOT/scripts/github-release.sh" --repo example/silkops-harness --tag v9 --dry-run
if [ "$(rc_of r2)" = 2 ]; then pass "R2 a tag that is not silkops-harness--vX.Y.Z exits 2"; else fail "R2" "rc=$(rc_of r2) out=$(out_of r2)"; fi

echo "test-inbox: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
