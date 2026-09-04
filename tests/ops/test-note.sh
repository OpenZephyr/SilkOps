#!/usr/bin/env bash
# Tier 1 tests for ops/note.sh against the glab stub (no network).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
PASS=0; FAIL=0
PROJECT="void-realm-solutions/silkops-harness-eval"
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }
# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
export PATH="$STUB_DIR:$PATH"
[ "$(command -v glab)" = "$STUB_DIR/glab" ] || { echo "glab stub is not first on PATH" >&2; exit 1; }
# run_case <name> <scenario> <env KEY=VAL ...> -- <args...>   (scenario: stub dir name or absolute path)
run_case() {
  local name="$1" scenario="$2"; shift 2
  case "$scenario" in /*) ;; *) scenario="$STUB_DIR/$scenario" ;; esac
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  local d="$SCRATCH/$name"; mkdir -p "$d"
  env -u GITLAB_TOKEN -u SILKOPS_SETTINGS_TOKEN -u SILKOPS_CI_TOKEN -u CI -u SILKOPS_VAR_VALUE \
    GLAB_STUB_SCENARIO="$scenario" GLAB_STUB_LOG="$d/glab.log" GLAB_STUB_BODY_DIR="$d/bodies" \
    CURL_STUB_STATE="$d/state" CURL_STUB_LOG="$d/curl.log" "${envs[@]}" \
    bash "$SCRIPT" "$@" >"$d/out.log" 2>"$d/err.log"
  echo $? >"$d/rc"
}
rc_of()  { cat "$SCRATCH/$1/rc"; }
out_of() { cat "$SCRATCH/$1/out.log"; }
err_of() { cat "$SCRATCH/$1/err.log"; }
log_of() { cat "$SCRATCH/$1/glab.log" 2>/dev/null; }
calls_of() { log_of "$1" | wc -l | tr -d ' '; }
writes_of() { log_of "$1" | grep -cE -- '-X (POST|PUT|DELETE)'; }
body_of() { cat "$SCRATCH/$1/bodies/$2.json"; }
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

echo "test-note: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
