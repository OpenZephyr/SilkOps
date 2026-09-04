#!/usr/bin/env bash
# Tier 1 tests for ops/mr-upsert.sh against the glab stub (no network). Never merges.
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
SCRIPT="$ROOT/ops/mr-upsert.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-mr-upsert.XXXXXX")"
DESC="$SCRATCH/desc.md"; printf 'new mr body\n' >"$DESC"
ARGS=(--source feat/u4 --target main --title "U4 gap fillers" --description-file "$DESC" --marker-unit U4 --plan plan.md --run r2)

run_case m1 mr-none -- "${ARGS[@]}"
if [ "$(rc_of m1)" = 2 ] && err_of m1 | grep -- '--project' >/dev/null && [ "$(calls_of m1)" = 0 ]; then
  pass "M1 missing --project exits 2 before any glab call"
else fail "M1" "rc=$(rc_of m1) calls=$(calls_of m1)"; fi

run_case m2 mr-none -- --project "$PROJECT" "${ARGS[@]}" --draft
if [ "$(rc_of m2)" = 0 ] && out_of m2 | jq -e '.ok == true and .action == "created" and .iid == 7 and .head_pipeline_id == 501 and (.web_url | endswith("/merge_requests/7"))' >/dev/null \
  && [ "$(writes_of m2)" = 1 ] && log_of m2 | grep -E -- '-X POST .*/merge_requests .*input=present' >/dev/null \
  && body_of m2 1 | jq -e '.body.source_branch == "feat/u4" and .body.target_branch == "main" and .body.title == "Draft: U4 gap fillers"
      and (.body.description | startswith("<!-- silkops: v=0.1.0 plan=plan.md unit=U4 run=r2 -->\n<!-- silkops:managed -->\nnew mr body\n<!-- /silkops:managed -->"))' >/dev/null \
  && ! log_of m2 | grep 'token=set' >/dev/null; then
  pass "M2 no open MR -> created (Draft: prefix, marker + managed region), head pipeline reported"
else fail "M2" "rc=$(rc_of m2) out=$(out_of m2) body=$(body_of m2 1 2>/dev/null) log=$(log_of m2 | tr '\n' ';')"; fi

run_case m3 mr-open -- --project "$PROJECT" "${ARGS[@]}"
if [ "$(rc_of m3)" = 0 ] && out_of m3 | jq -e '.ok == true and .action == "updated" and .iid == 7' >/dev/null && [ "$(writes_of m3)" = 1 ] \
  && log_of m3 | grep -E -- '-X PUT .*/merge_requests/7 .*input=present' >/dev/null \
  && body_of m3 1 | jq -e '.body.description == "<!-- silkops: v=0.1.0 plan=plan.md unit=U4 run=r2 -->\n<!-- silkops:managed -->\nnew mr body\n<!-- /silkops:managed -->\n\nReviewer notes.\n"' >/dev/null \
  && ! log_of m3 | grep -E '/merge( |$)|/merge\?' >/dev/null; then
  pass "M3 open MR for the branch -> description region updated, text outside kept, never merged"
else fail "M3" "rc=$(rc_of m3) out=$(out_of m3) body=$(body_of m3 1 2>/dev/null)"; fi

run_case m4 mr-open -- --project "$PROJECT" "${ARGS[@]}" --dry-run
if [ "$(rc_of m4)" = 0 ] && out_of m4 | jq -e '.ok == true and .dry_run == true and .action == "updated" and (.proposed.description | contains("new mr body"))' >/dev/null && [ "$(writes_of m4)" = 0 ]; then
  pass "M4 dry-run shows current vs proposed, writes nothing"
else fail "M4" "rc=$(rc_of m4) out=$(out_of m4) writes=$(writes_of m4)"; fi

run_case m5 mr-open -- --project "$PROJECT" --source feat/u4 --target main --title t
if [ "$(rc_of m5)" = 2 ] && [ "$(calls_of m5)" = 0 ]; then pass "M5 missing --description-file exits 2"; else fail "M5" "rc=$(rc_of m5)"; fi

echo "test-mr-upsert: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
