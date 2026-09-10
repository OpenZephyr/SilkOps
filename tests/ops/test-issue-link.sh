#!/usr/bin/env bash
# shellcheck disable=SC2034  # SCRIPT, STUB_DIR, SCRATCH, PROJECT are read by lib/harness.sh functions
# Tier 1 tests for ops/issue-link.sh against the glab stub (no network).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/ops/lib/harness.sh"
SCRIPT="$ROOT/ops/issue-link.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-issue-link.XXXXXX")"

run_case l1 link-ok -- --source 10 --target 11
if [ "$(rc_of l1)" = 2 ] && err_of l1 | grep -- '--project' >/dev/null && [ "$(calls_of l1)" = 0 ] && out_of l1 | jq -e '.ok == false' >/dev/null; then
  pass "L1 missing --project exits 2 before any glab call"
else fail "L1" "rc=$(rc_of l1) calls=$(calls_of l1) err=$(err_of l1 | tail -1)"; fi

run_case l2 link-blocks-403 -- --project "$PROJECT" --source 10 --target 11 --type blocks
if [ "$(rc_of l2)" = 0 ] && out_of l2 | jq -e '.ok == true and .fallback == "relates_to" and .link_type == "relates_to" and .existing == false' >/dev/null \
  && log_of l2 | grep -E -- '-X POST .*link_type=blocks' >/dev/null && log_of l2 | grep -E -- '-X POST .*link_type=relates_to' >/dev/null \
  && ! log_of l2 | grep 'token=set' >/dev/null; then
  pass "L2 blocks rejected (403) -> relates_to fallback reported, session identity only"
else fail "L2" "rc=$(rc_of l2) out=$(out_of l2) log=$(log_of l2 | tr '\n' ';')"; fi

run_case l3 link-existing -- --project "$PROJECT" --source 10 --target 11 --type relates_to
if [ "$(rc_of l3)" = 0 ] && out_of l3 | jq -e '.ok == true and .existing == true and .link_type == "relates_to"' >/dev/null && [ "$(writes_of l3)" = 0 ]; then
  pass "L3 existing link -> existing:true with zero writes"
else fail "L3" "rc=$(rc_of l3) out=$(out_of l3) writes=$(writes_of l3)"; fi

run_case l4 link-ok -- --project "$PROJECT" --source 10 --target 11 --type blocks
if [ "$(rc_of l4)" = 0 ] && out_of l4 | jq -e '.ok == true and .link_type == "blocks" and .fallback == null and .existing == false' >/dev/null && [ "$(writes_of l4)" = 1 ]; then
  pass "L4 blocks accepted -> one POST, no fallback"
else fail "L4" "rc=$(rc_of l4) out=$(out_of l4)"; fi

run_case l5 link-ok -- --project "$PROJECT" --source 10 --target 11 --dry-run
if [ "$(rc_of l5)" = 0 ] && out_of l5 | jq -e '.ok == true and .dry_run == true and .proposed.link_type == "relates_to" and (.current | type) == "array"' >/dev/null && [ "$(writes_of l5)" = 0 ]; then
  pass "L5 dry-run shows current links and proposed link, writes nothing"
else fail "L5" "rc=$(rc_of l5) out=$(out_of l5) writes=$(writes_of l5)"; fi

run_case l6 link-ok -- --project "$PROJECT" --source 10 --target 11 --type bogus
if [ "$(rc_of l6)" = 2 ] && [ "$(calls_of l6)" = 0 ]; then pass "L6 bad --type exits 2"; else fail "L6" "rc=$(rc_of l6)"; fi

echo "test-issue-link: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
