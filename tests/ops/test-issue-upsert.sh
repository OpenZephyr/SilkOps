#!/usr/bin/env bash
# shellcheck disable=SC2034  # SCRIPT, STUB_DIR, SCRATCH, PROJECT are read by lib/harness.sh functions
# Tier 1 tests for ops/issue-upsert.sh against the glab stub (no network).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/ops/lib/harness.sh"
SCRIPT="$ROOT/ops/issue-upsert.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-issue-upsert.XXXXXX")"
COMMON="$STUB_DIR/u4-common"
BODY="$SCRATCH/body.md"; printf 'new body line\n' >"$BODY"
OLDBODY="$SCRATCH/old.md"; printf 'old body line\n' >"$OLDBODY"
ARGS=(--marker-unit U4 --plan plan.md --run r2 --title "U4 gap fillers" --body-file "$BODY")
OPEN='<!-- silkops:managed -->'; CLOSE='<!-- /silkops:managed -->'
# parts: split a description into pre/inner/post around the managed region
# shellcheck disable=SC2016  # jq program: $names are jq variables
JQ_PARTS='def parts: split("<!-- silkops:managed -->") as [$pre,$rest] | ($rest | split("<!-- /silkops:managed -->")) as [$inner,$post] | {pre:$pre,inner:$inner,post:$post};'

run_case u1 upsert-open -- "${ARGS[@]}"
if [ "$(rc_of u1)" = 2 ] && err_of u1 | grep -- '--project' >/dev/null && [ "$(calls_of u1)" = 0 ]; then
  pass "U1 missing --project exits 2 before any glab call"
else fail "U1" "rc=$(rc_of u1) calls=$(calls_of u1)"; fi

run_case u2 upsert-closed -- --project "$PROJECT" "${ARGS[@]}"
if [ "$(rc_of u2)" = 7 ] && out_of u2 | jq -e '.ok == false and .error == "closed_issue" and .iid == 12' >/dev/null && [ "$(writes_of u2)" = 0 ]; then
  pass "U2 closed issue -> exit 7 refused, zero writes"
else fail "U2" "rc=$(rc_of u2) out=$(out_of u2) writes=$(writes_of u2)"; fi

run_case u3 upsert-notfound -- --project "$PROJECT" "${ARGS[@]}" --labels harness,u4 --milestone "Harness v0.1"
if [ "$(rc_of u3)" = 0 ] && out_of u3 | jq -e '.ok == true and .action == "created" and .iid == 13 and (.web_url | endswith("/issues/13"))' >/dev/null \
  && [ "$(writes_of u3)" = 1 ] && log_of u3 | grep -E -- '-X POST .*/issues .*input=present' >/dev/null \
  && body_of u3 1 | jq -e --arg o "$OPEN" --arg c "$CLOSE" '.body.title == "U4 gap fillers" and .body.milestone_id == 77 and (.body.labels | split(",") | index("u4") != null)
      and (.body.description | startswith("<!-- silkops: v=0.1.0 plan=plan.md unit=U4 run=r2 -->\n" + $o + "\nnew body line\n" + $c)) and (.body.description | rtrimstr("\n") | endswith($c))' >/dev/null \
  && ! log_of u3 | grep 'token=set' >/dev/null; then
  pass "U3 not found -> created via --input with marker + managed region and nothing else, u4 label, milestone resolved"
else fail "U3" "rc=$(rc_of u3) out=$(out_of u3) body=$(body_of u3 1 2>/dev/null) log=$(log_of u3 | tr '\n' ';')"; fi

run_case u4 upsert-open -- --project "$PROJECT" "${ARGS[@]}"
if [ "$(rc_of u4)" = 0 ] && out_of u4 | jq -e '.ok == true and .action == "updated" and .iid == 12' >/dev/null && [ "$(writes_of u4)" = 1 ] \
  && log_of u4 | grep -E -- '-X PUT .*/issues/12 .*input=present' >/dev/null \
  && jq -e --slurpfile b "$SCRATCH/u4/bodies/1.json" "$JQ_PARTS"' (.[0].description | parts) as $o | ($b[0].body.description | parts) as $n
      | $n.post == $o.post and $n.inner == "\nnew body line\n" and ($n.pre | test("run=r2 -->")) and ($n.pre | sub("run=r2 -->"; "run=r1 -->")) == $o.pre' "$COMMON/issues-open.json" >/dev/null; then
  pass "U4 open issue -> managed region replaced, marker run refreshed, text outside the region byte-identical"
else fail "U4" "rc=$(rc_of u4) out=$(out_of u4) body=$(body_of u4 1 2>/dev/null | head -c 600)"; fi

# U5: second run against the state the first run produced -> unchanged, zero writes
SECOND="$SCRATCH/upsert-second"; mkdir -p "$SECOND"; cp -R "$COMMON" "$SCRATCH/u4-common"
jq --slurpfile b "$SCRATCH/u4/bodies/1.json" '.[0].description = $b[0].body.description' "$COMMON/issues-open.json" >"$SCRATCH/u4-common/issues-open.json"
cp "$STUB_DIR/upsert-open/routes.tsv" "$SECOND/routes.tsv"
run_case u5 "$SECOND" -- --project "$PROJECT" "${ARGS[@]}"
if [ "$(rc_of u5)" = 0 ] && out_of u5 | jq -e '.ok == true and .action == "unchanged" and .iid == 12' >/dev/null && [ "$(writes_of u5)" = 0 ]; then
  pass "U5 second run with an identical body -> action unchanged, zero write calls"
else fail "U5" "rc=$(rc_of u5) out=$(out_of u5) writes=$(writes_of u5) log=$(log_of u5 | tr '\n' ';')"; fi

run_case u6 upsert-open -- --project "$PROJECT" "${ARGS[@]}" --dry-run
if [ "$(rc_of u6)" = 0 ] && out_of u6 | jq -e '.ok == true and .dry_run == true and .action == "updated" and (.current.description | type) == "string" and (.proposed.description | contains("new body line"))' >/dev/null && [ "$(writes_of u6)" = 0 ]; then
  pass "U6 dry-run reports current vs proposed description and writes nothing"
else fail "U6" "rc=$(rc_of u6) out=$(out_of u6) writes=$(writes_of u6)"; fi

run_case u7 upsert-open -- --project "$PROJECT" --marker-unit U4 --plan plan.md --run r2 --title t
if [ "$(rc_of u7)" = 2 ] && [ "$(calls_of u7)" = 0 ]; then pass "U7 missing --body-file exits 2"; else fail "U7" "rc=$(rc_of u7)"; fi

echo "test-issue-upsert: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
