#!/usr/bin/env bash
# shellcheck disable=SC2034
# Tier 1 tests for ops/watch.sh with SILKOPS_PROVIDER=github (v0.3 U3, KTD3): a PR's workflow
# runs are found by head sha, jobs and logs come from Actions, a rerun is the retry.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
GH="$ROOT/tests/fixtures/gh-stub"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/ops/lib/harness.sh"
SCRIPT="$ROOT/ops/watch.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-watch-gh.XXXXXX")"
PROJECT="example/silkops-harness"
COMMON=(--project "$PROJECT" --plan plan.md --run r1)

run_case w1 "$GH/run-green" SILKOPS_PROVIDER=github SILKOPS_WATCH_SLEEP=0 -- "${COMMON[@]}" --mr 7 --wait 0
if [ "$(rc_of w1)" = 0 ] && out_of w1 | jq -e '.ok == true and .provider == "github" and .pipeline_id == 501 and .status == "success" and .terminal == true and .ready == true
      and (.runs | length) == 1 and .runs[0].name == "ci" and (.jobs | length) == 2 and .failed == [] and .expected_duration_s == 540 and .approvals.approved == true' >/dev/null \
  && ! log_of w1 | grep -q 'glab'; then
  pass "GW1 github: PR head sha -> its workflow run watched to ready; runs[] and jobs from Actions; no glab call"
else fail "GW1" "rc=$(rc_of w1) out=$(out_of w1 | head -c 900) err=$(err_of w1 | tail -2)"; fi

run_case w2 "$GH/run-failed" SILKOPS_PROVIDER=github SILKOPS_WATCH_SLEEP=0 -- "${COMMON[@]}" --mr 7 --wait 0 --note
if [ "$(rc_of w2)" = 0 ] && out_of w2 | jq -e '.status == "failed" and .ready == false and (.failed | length) == 1 and .failed[0].name == "build-sec-tools"
      and .failed[0].classification.fact == "docker-hub-502" and .failed[0].classification.retry_safe == true and (.notes | length) == 1' >/dev/null \
  && log_of w2 | grep -E -- 'actions/jobs/9101/logs' >/dev/null && log_of w2 | grep -E -- '-X POST .*issues/7/comments' >/dev/null; then
  pass "GW2 github: failed job's log fetched and classified (docker-hub-502, retry-safe); triage comment posted on the PR"
else fail "GW2" "rc=$(rc_of w2) out=$(out_of w2 | head -c 900) log=$(log_of w2 | tr '\n' ';' | head -c 500)"; fi

run_case w3 "$GH/run-failed" SILKOPS_PROVIDER=github SILKOPS_WATCH_SLEEP=0 -- "${COMMON[@]}" --mr 7 --wait 0 --retry
if out_of w3 | jq -e '.retried == [9101]' >/dev/null && log_of w3 | grep -E -- '-X POST .*actions/jobs/9101/rerun' >/dev/null; then
  pass "GW3 github: --retry reruns the failed job once through Actions"
else fail "GW3" "rc=$(rc_of w3) out=$(out_of w3 | jq -c '{retried, retry_log, retry_skipped, retry_unsafe}' 2>/dev/null) log=$(log_of w3 | grep -c rerun)"; fi

echo "test-watch-github: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
