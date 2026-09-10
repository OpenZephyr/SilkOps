#!/usr/bin/env bash
# shellcheck disable=SC2034  # SCRIPT, STUB_DIR, SCRATCH, PROJECT are read by lib/harness.sh functions
# Tier 1 tests for ops/note.sh against the glab stub (no network).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/ops/lib/harness.sh"
SCRIPT="$ROOT/ops/note.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-note.XXXXXX")"
NB="$SCRATCH/note.md"; printf 'Verification passed.\n' >"$NB"
ARGS=(--body-file "$NB" --marker-unit U4 --plan plan.md --run r2)

run_case n1 note -- --issue 12 "${ARGS[@]}"
if [ "$(rc_of n1)" = 2 ] && err_of n1 | grep -- '--project' >/dev/null && [ "$(calls_of n1)" = 0 ]; then
  pass "N1 missing --project exits 2 before any glab call"
else fail "N1" "rc=$(rc_of n1) calls=$(calls_of n1)"; fi

run_case n2 note -- --project "$PROJECT" --issue 12 "${ARGS[@]}" --dedupe-key verify-1
if [ "$(rc_of n2)" = 0 ] && out_of n2 | jq -e '.ok == true and .existing == true and .id == 801' >/dev/null && [ "$(writes_of n2)" = 0 ]; then
  pass "N2 dedupe key already posted -> existing:true, zero writes"
else fail "N2" "rc=$(rc_of n2) out=$(out_of n2) writes=$(writes_of n2)"; fi

run_case n3 note -- --project "$PROJECT" --issue 12 "${ARGS[@]}" --dedupe-key verify-2
if [ "$(rc_of n3)" = 0 ] && out_of n3 | jq -e '.ok == true and .existing == false and .id == 803' >/dev/null && [ "$(writes_of n3)" = 1 ] \
  && log_of n3 | grep -E -- '-X POST .*/issues/12/notes .*input=present' >/dev/null \
  && body_of n3 1 | jq -e '.body.body | startswith("<!-- silkops: v=0.1.0 plan=plan.md unit=U4 run=r2 -->\n<!-- silkops:key=verify-2 -->\n") and endswith("Verification passed.\n")' >/dev/null \
  && ! log_of n3 | grep 'token=set' >/dev/null; then
  pass "N3 new dedupe key -> one POST carrying marker + key + body, session identity"
else fail "N3" "rc=$(rc_of n3) out=$(out_of n3) body=$(body_of n3 1 2>/dev/null)"; fi

run_case n4 note -- --project "$PROJECT" --mr 7 "${ARGS[@]}"
if [ "$(rc_of n4)" = 0 ] && log_of n4 | grep -E -- '-X POST .*/merge_requests/7/notes' >/dev/null && ! log_of n4 | grep -E -- '-X GET' >/dev/null; then
  pass "N4 --mr posts to the merge request notes endpoint (no dedupe -> no list call)"
else fail "N4" "rc=$(rc_of n4) log=$(log_of n4 | tr '\n' ';')"; fi

run_case n5 note -- --project "$PROJECT" --issue 12 "${ARGS[@]}" --dry-run
if [ "$(rc_of n5)" = 0 ] && out_of n5 | jq -e '.ok == true and .dry_run == true and (.proposed.body | contains("Verification passed."))' >/dev/null && [ "$(writes_of n5)" = 0 ]; then
  pass "N5 dry-run shows the proposed note and writes nothing"
else fail "N5" "rc=$(rc_of n5) out=$(out_of n5)"; fi

run_case n6 note -- --project "$PROJECT" --issue 12 --mr 7 "${ARGS[@]}"
if [ "$(rc_of n6)" = 2 ] && [ "$(calls_of n6)" = 0 ]; then pass "N6 both --issue and --mr exits 2"; else fail "N6" "rc=$(rc_of n6)"; fi

run_case n7 note-lookup-500 -- --project "$PROJECT" --issue 12 "${ARGS[@]}" --dedupe-key verify-2
if [ "$(rc_of n7)" = 1 ] && out_of n7 | jq -e '.ok == false and .error == "lookup_failed" and .iid == 12' >/dev/null && [ "$(writes_of n7)" = 0 ] && ! grep -F 'glpat-stubsecret' "$SCRATCH/n7/out.log" "$SCRATCH/n7/err.log" >/dev/null; then
  pass "N7 dedupe listing 500 -> exit 1 lookup_failed, nothing posted, stub token redacted"
else fail "N7" "rc=$(rc_of n7) out=$(out_of n7) writes=$(writes_of n7)"; fi

run_case n8 note CI=true -- --project "$PROJECT" --issue 12 "${ARGS[@]}"
if [ "$(rc_of n8)" = 3 ] && out_of n8 | jq -e '.error == "no_token"' >/dev/null && err_of n8 | grep SILKOPS_CI_TOKEN >/dev/null && [ "$(calls_of n8)" = 0 ]; then
  pass "N8 CI without SILKOPS_CI_TOKEN -> visible exit 3 (JSON + message), zero glab calls"
else fail "N8" "rc=$(rc_of n8) out=$(out_of n8) err=$(err_of n8 | tail -1)"; fi

echo "test-note: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
