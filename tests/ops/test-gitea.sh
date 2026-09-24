#!/usr/bin/env bash
# shellcheck disable=SC2034
# Tier 1 (v0.3 U5): the Gitea provider on fixtures, flagged experimental: PR upsert and a watch
# to ready, over the same verbs, with the token as a curl config on stdin.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
GT="$ROOT/tests/fixtures/gitea-stub"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/ops/lib/harness.sh"
export PATH="$GT:$PATH"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-gitea.XXXXXX")"
PROJECT="example/silkops-harness"
ENV=(SILKOPS_PROVIDER=gitea SILKOPS_GITEA_URL=https://gitea.test GITEA_TOKEN=gta_STUBTOKEN0000)
gt_log() { cat "$SCRATCH/$1/gitea.log" 2>/dev/null; }
run_gt() { local n="$1" sc="$2"; shift 2; run_case "$n" "$sc" "${ENV[@]}" GITEA_STUB_SCENARIO="$sc" GITEA_STUB_LOG="$SCRATCH/$n/gitea.log" GITEA_STUB_BODY_DIR="$SCRATCH/$n/bodies" -- "$@"; }
DESC="$SCRATCH/desc.md"; printf 'new mr body\n' >"$DESC"

SCRIPT="$ROOT/ops/mr-upsert.sh"
run_gt g1 "$GT/pr-none" --project "$PROJECT" --source feat/u4 --target main --title "U4 gap fillers" --description-file "$DESC" --marker-unit U4 --plan plan.md --run r2
if [ "$(rc_of g1)" = 0 ] && out_of g1 | jq -e '.ok == true and .provider == "gitea" and .experimental == true and .action == "created" and .iid == 8 and .number == 8' >/dev/null \
  && gt_log g1 | grep -E '^curl: POST repos/example/silkops-harness/pulls auth=token' >/dev/null \
  && body_of g1 1 | jq -e '.body.head == "feat/u4" and .body.base == "main" and (.body.body | contains("new mr body"))' >/dev/null \
  && ! grep -rq gta_STUBTOKEN "$SCRATCH/g1"; then
  pass "T1 gitea: PR created through the verb seam; result flagged experimental; token never on argv or in logs"
else fail "T1" "rc=$(rc_of g1) out=$(out_of g1) log=$(gt_log g1 | tr '\n' ';') err=$(err_of g1 | tail -2)"; fi

run_gt g2 "$GT/pr-open" --project "$PROJECT" --source feat/u4 --target main --title "U4 gap fillers" --description-file "$DESC" --marker-unit U4 --plan plan.md --run r2
if [ "$(rc_of g2)" = 0 ] && out_of g2 | jq -e '.action == "updated" and .iid == 7' >/dev/null && gt_log g2 | grep -E '^curl: PATCH repos/example/silkops-harness/pulls/7' >/dev/null; then
  pass "T2 gitea: open PR found by head branch among open pulls and re-synced"
else fail "T2" "rc=$(rc_of g2) out=$(out_of g2) log=$(gt_log g2 | tr '\n' ';')"; fi

SCRIPT="$ROOT/ops/watch.sh"
run_gt w1 "$GT/run-green" --project "$PROJECT" --plan plan.md --run r1 --mr 7 --wait 0
if [ "$(rc_of w1)" = 0 ] && out_of w1 | jq -e '.provider == "gitea" and .experimental == true and .pipeline_id == 501 and .status == "success" and .ready == true and (.runs | length) == 1 and .approvals.approved == true' >/dev/null; then
  pass "T3 gitea: a PR's Actions run is found by head sha and watched to ready; approval from the reviews"
else fail "T3" "rc=$(rc_of w1) out=$(out_of w1 | head -c 700) err=$(err_of w1 | tail -2)"; fi

echo "test-gitea: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
