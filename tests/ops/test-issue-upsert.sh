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
      and (.body.description | startswith("<!-- silkops: v='"$PLUGIN_V"' plan=plan.md unit=U4 run=r2 -->\n" + $o + "\nnew body line\n" + $c)) and (.body.description | rtrimstr("\n") | endswith($c))' >/dev/null \
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

# U8: the marker search fails (500) -> exit 1 lookup_failed, never falls through to create
run_case u8 upsert-lookup-500 -- --project "$PROJECT" "${ARGS[@]}"
if [ "$(rc_of u8)" = 1 ] && out_of u8 | jq -e '.ok == false and .error == "lookup_failed"' >/dev/null && [ "$(writes_of u8)" = 0 ] \
  && err_of u8 | grep -i 'refusing to write' >/dev/null && ! grep -F 'glpat-stubsecret' "$SCRATCH/u8/out.log" "$SCRATCH/u8/err.log" >/dev/null; then
  pass "U8 lookup 500 -> exit 1 lookup_failed, zero writes, stub token redacted"
else fail "U8" "rc=$(rc_of u8) out=$(out_of u8) writes=$(writes_of u8) err=$(err_of u8 | tail -1)"; fi

# U9: in CI without SILKOPS_CI_TOKEN the exit-3 failure is visible (JSON + message), no glab call
run_case u9 upsert-open CI=true -- --project "$PROJECT" "${ARGS[@]}"
if [ "$(rc_of u9)" = 3 ] && out_of u9 | jq -e '.ok == false and .error == "no_token"' >/dev/null && err_of u9 | grep SILKOPS_CI_TOKEN >/dev/null && [ "$(calls_of u9)" = 0 ]; then
  pass "U9 CI without SILKOPS_CI_TOKEN -> exit 3 with JSON no_token on stdout and the variable named on stderr, zero glab calls"
else fail "U9" "rc=$(rc_of u9) out=$(out_of u9) err=$(err_of u9 | tail -1) calls=$(calls_of u9)"; fi

# U10: label fallback — u4 issues of another plan (#20) and a human (#21): only #21 is adopted
run_case u10 upsert-foreign-plan -- --project "$PROJECT" "${ARGS[@]}"
if [ "$(rc_of u10)" = 0 ] && out_of u10 | jq -e '.ok == true and .action == "updated" and .iid == 21' >/dev/null && [ "$(writes_of u10)" = 1 ] \
  && log_of u10 | grep -E -- '-X PUT .*/issues/21 ' >/dev/null && ! log_of u10 | grep -E -- '/issues/20( |$)' >/dev/null \
  && body_of u10 1 | jq -e '.body.description | contains("plan=plan.md unit=U4 run=r2") and contains("new body line") and (contains("other plan") | not)' >/dev/null; then
  pass "U10 label fallback skips the other plan's u4 issue (#20 untouched) and adopts the marker-less one (#21)"
else fail "U10" "rc=$(rc_of u10) out=$(out_of u10) log=$(log_of u10 | tr '\n' ';')"; fi

# U10b: with --milestone, a marker-less u4 issue on another milestone is not a candidate either
run_case u10b upsert-foreign-plan -- --project "$PROJECT" "${ARGS[@]}" --milestone 78
if [ "$(rc_of u10b)" = 0 ] && out_of u10b | jq -e '.action == "created"' >/dev/null && [ "$(writes_of u10b)" = 1 ] && log_of u10b | grep -E -- '-X POST .*/issues ' >/dev/null; then
  pass "U10b --milestone restricts the fallback: #21 (milestone 77) is not adopted for milestone 78 -> created"
else fail "U10b" "rc=$(rc_of u10b) out=$(out_of u10b) log=$(log_of u10b | tr '\n' ';')"; fi

# U11: two eligible label candidates -> exit 7 ambiguous_identity, zero writes
run_case u11 upsert-label-ambiguous -- --project "$PROJECT" "${ARGS[@]}"
if [ "$(rc_of u11)" = 7 ] && out_of u11 | jq -e '.ok == false and .error == "ambiguous_identity" and (.candidates | map(.iid)) == [21, 22]' >/dev/null && [ "$(writes_of u11)" = 0 ]; then
  pass "U11 two marker-less u4 issues -> exit 7 ambiguous_identity listing iids 21, 22; zero writes"
else fail "U11" "rc=$(rc_of u11) out=$(out_of u11) writes=$(writes_of u11)"; fi

# U12: an issue merely quoting the marker mid-line is not the unit's issue
run_case u12 upsert-marker-quoted -- --project "$PROJECT" "${ARGS[@]}"
if [ "$(rc_of u12)" = 0 ] && out_of u12 | jq -e '.action == "created"' >/dev/null && ! log_of u12 | grep -E -- '/issues/30' >/dev/null && [ "$(writes_of u12)" = 1 ]; then
  pass "U12 marker quoted mid-line in #30 is not matched -> created, #30 untouched"
else fail "U12" "rc=$(rc_of u12) out=$(out_of u12) log=$(log_of u12 | tr '\n' ';')"; fi

# U13: closed #12 (listed first) and open #14 both carry the marker -> the open one is synced
run_case u13 upsert-marker-dup -- --project "$PROJECT" "${ARGS[@]}"
if [ "$(rc_of u13)" = 0 ] && out_of u13 | jq -e '.ok == true and .action == "updated" and .iid == 14' >/dev/null && log_of u13 | grep -E -- '-X PUT .*/issues/14 ' >/dev/null && [ "$(writes_of u13)" = 1 ]; then
  pass "U13 open + closed marker duplicates -> the open issue (#14) is chosen over the newer closed one"
else fail "U13" "rc=$(rc_of u13) out=$(out_of u13) log=$(log_of u13 | tr '\n' ';')"; fi

# U14: two OPEN issues carry the marker -> exit 7 ambiguous_identity, zero writes
run_case u14 upsert-marker-two-open -- --project "$PROJECT" "${ARGS[@]}"
if [ "$(rc_of u14)" = 7 ] && out_of u14 | jq -e '.error == "ambiguous_identity" and (.candidates | map(.iid)) == [12, 14]' >/dev/null && [ "$(writes_of u14)" = 0 ]; then
  pass "U14 two open marker matches -> exit 7 ambiguous_identity, zero writes"
else fail "U14" "rc=$(rc_of u14) out=$(out_of u14) writes=$(writes_of u14)"; fi

# --- v0.2 U5 (#39): SILKOPS_MARKER=off — identity by label only; --milestone re-sync refused
run_case u15 upsert-open SILKOPS_MARKER=off -- --project "$PROJECT" "${ARGS[@]}" --milestone "Harness v0.1"
if [ "$(rc_of u15)" = 7 ] && out_of u15 | jq -e '.ok == false and .error == "refused"' >/dev/null && [ "$(writes_of u15)" = 0 ]; then
  pass "U15 marker off with --milestone -> exit 7 refused (label identity is too weak for a milestone re-sync), zero writes"
else fail "U15" "rc=$(rc_of u15) out=$(out_of u15) writes=$(writes_of u15)"; fi

run_case u16 upsert-foreign-plan SILKOPS_MARKER=off -- --project "$PROJECT" "${ARGS[@]}"
if [ "$(rc_of u16)" = 0 ] && out_of u16 | jq -e '.action == "updated" and .iid == 21 and .identity == "label" and .marker == false' >/dev/null \
  && [ "$(writes_of u16)" = 1 ] && body_of u16 1 | jq -e '.body.description == "new body line\n"' >/dev/null \
  && ! log_of u16 | grep -F 'in=description' >/dev/null; then
  pass "U16 marker off: no marker search, the marker-less u4 issue (#21) is adopted and its description replaced verbatim"
else fail "U16" "rc=$(rc_of u16) out=$(out_of u16) body=$(body_of u16 1 2>/dev/null) log=$(log_of u16 | tr '\n' ';')"; fi

run_case u17 upsert-notfound SILKOPS_MARKER=off -- --project "$PROJECT" "${ARGS[@]}"
if [ "$(rc_of u17)" = 0 ] && out_of u17 | jq -e '.action == "created" and .identity == "label" and .marker == false' >/dev/null \
  && body_of u17 1 | jq -e '.body.description == "new body line\n" and (.body.labels | contains("u4"))' >/dev/null \
  && ! body_of u17 1 | jq -r '.body.description' | grep -i silkops >/dev/null; then
  pass "U17 marker off: created verbatim, u4 label carries the identity, nothing names the harness"
else fail "U17" "rc=$(rc_of u17) out=$(out_of u17) body=$(body_of u17 1 2>/dev/null)"; fi

# --- v0.2 U9 (#34): assignee and due date on create, reported as read back
run_case u18 upsert-notfound -- --project "$PROJECT" "${ARGS[@]}" --assignee aqua --due-date 2026-10-01
if [ "$(rc_of u18)" = 0 ] && out_of u18 | jq -e '.action == "created" and (.assignee == "aqua" or .assignee == null) and has("due_date")' >/dev/null \
  && log_of u18 | grep -E -- 'users\?username=aqua' >/dev/null \
  && body_of u18 1 | jq -e '.body.assignee_ids == [42] and .body.due_date == "2026-10-01"' >/dev/null; then
  pass "U18 --assignee resolves the username to an id, --due-date is sent; both are in the result"
else fail "U18" "rc=$(rc_of u18) out=$(out_of u18) body=$(body_of u18 1 2>/dev/null) log=$(log_of u18 | tr '\n' ';')"; fi

echo "test-issue-upsert: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
