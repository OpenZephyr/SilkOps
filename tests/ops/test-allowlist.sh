#!/usr/bin/env bash
# shellcheck disable=SC2034  # SCRIPT, STUB_DIR, SCRATCH, PROJECT are read by lib/harness.sh functions
# Tier 1 tests for ops/allowlist.sh against the glab stub (no network).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/ops/lib/harness.sh"
SCRIPT="$ROOT/ops/allowlist.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-allowlist.XXXXXX")"
TOK=SILKOPS_SETTINGS_TOKEN=glpat-MAINTTOKEN0000000000

run_case a1 allowlist $TOK -- get
if [ "$(rc_of a1)" = 2 ] && err_of a1 | grep -- '--project' >/dev/null && [ "$(calls_of a1)" = 0 ]; then
  pass "A1 missing --project exits 2 before any glab call"
else fail "A1" "rc=$(rc_of a1) calls=$(calls_of a1)"; fi

run_case a2 allowlist $TOK -- --project "$PROJECT" add --consumer void-realm-solutions/consumer-x --dry-run
if [ "$(rc_of a2)" = 0 ] && [ "$(writes_of a2)" = 0 ] \
  && out_of a2 | jq -e '.ok == true and .dry_run == true and .existing == false and (.current.projects | length) == 1 and .proposed.kind == "project" and .proposed.target_project_id == 7002' >/dev/null; then
  pass "A2 dry-run shows current allow-list and the proposed entry; no POST"
else fail "A2" "rc=$(rc_of a2) out=$(out_of a2) log=$(log_of a2 | tr '\n' ';')"; fi

run_case a3 allowlist $TOK -- --project "$PROJECT" add --consumer void-realm-solutions/team
if [ "$(rc_of a3)" = 2 ] && err_of a3 | grep -- '--group' >/dev/null && out_of a3 | jq -e '.ok == false and (.message | contains("--group"))' >/dev/null && [ "$(writes_of a3)" = 0 ]; then
  pass "A3 group path without --group refused with exit 2 naming the flag"
else fail "A3" "rc=$(rc_of a3) err=$(err_of a3 | tail -1) writes=$(writes_of a3)"; fi

run_case a4 allowlist $TOK -- --project "$PROJECT" add --consumer void-realm-solutions/consumer-x
if [ "$(rc_of a4)" = 0 ] && out_of a4 | jq -e '.ok == true and .existing == false and .added.target_project_id == 7002' >/dev/null \
  && [ "$(writes_of a4)" = 1 ] && log_of a4 | grep -E -- '-X POST .*job_token_scope/allowlist.*token=set' >/dev/null \
  && ! log_of a4 | grep -E -- '-X GET .*token=set' >/dev/null && ! grep 'glpat-' "$SCRATCH/a4/glab.log" "$SCRATCH/a4/out.log" "$SCRATCH/a4/err.log" >/dev/null; then
  pass "A4 add consumer: one POST under the settings token, reads under the session identity, token never printed"
else fail "A4" "rc=$(rc_of a4) out=$(out_of a4) log=$(log_of a4 | tr '\n' ';')"; fi

run_case a5 allowlist $TOK -- --project "$PROJECT" add --consumer void-realm-solutions/consumer-old
if [ "$(rc_of a5)" = 0 ] && out_of a5 | jq -e '.ok == true and .existing == true' >/dev/null && [ "$(writes_of a5)" = 0 ]; then
  pass "A5 consumer already allow-listed -> existing:true, zero writes"
else fail "A5" "rc=$(rc_of a5) out=$(out_of a5)"; fi

run_case a6 allowlist -- --project "$PROJECT" get
if [ "$(rc_of a6)" = 0 ] && out_of a6 | jq -e '.ok == true and (.projects | length) == 1 and (.groups | length) == 1' >/dev/null && ! log_of a6 | grep 'token=set' >/dev/null; then
  pass "A6 get lists project and group entries under the session identity"
else fail "A6" "rc=$(rc_of a6) out=$(out_of a6)"; fi

run_case a7 allowlist -- --project "$PROJECT" add --consumer void-realm-solutions/consumer-x
if [ "$(rc_of a7)" = 3 ] && [ "$(writes_of a7)" = 0 ]; then
  pass "A7 add without SILKOPS_SETTINGS_TOKEN exits 3 with zero writes"
else fail "A7" "rc=$(rc_of a7) writes=$(writes_of a7)"; fi

run_case a8 allowlist $TOK -- --project "$PROJECT" add --consumer void-realm-solutions/team --group
if [ "$(rc_of a8)" = 0 ] && out_of a8 | jq -e '.ok == true and .added.target_group_id == 300 and .kind == "group"' >/dev/null \
  && log_of a8 | grep -E -- '-X POST .*groups_allowlist.*token=set' >/dev/null; then
  pass "A8 --group allow-lists a group via groups_allowlist under the settings token"
else fail "A8" "rc=$(rc_of a8) out=$(out_of a8) log=$(log_of a8 | tr '\n' ';')"; fi

echo "test-allowlist: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
