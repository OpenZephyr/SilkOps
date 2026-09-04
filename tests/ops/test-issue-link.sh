#!/usr/bin/env bash
# Tier 1 tests for ops/issue-link.sh against the glab stub (no network).
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
