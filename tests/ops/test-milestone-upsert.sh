#!/usr/bin/env bash
# shellcheck disable=SC2034  # SCRIPT, STUB_DIR, SCRATCH, PROJECT are read by lib/harness.sh functions
# Tier 1 tests for ops/milestone-upsert.sh against the glab stub (no network).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/ops/lib/harness.sh"
SCRIPT="$ROOT/ops/milestone-upsert.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-milestone-upsert.XXXXXX")"
DESC="$SCRATCH/desc.md"; printf 'new milestone body\n' >"$DESC"
OLDDESC="$SCRATCH/old.md"; printf 'old milestone body\n' >"$OLDDESC"
ARGS=(--title "Harness v0.1" --plan plan.md --run r2)
OPEN='<!-- silkops:managed -->'; CLOSE='<!-- /silkops:managed -->'

run_case m1 milestone -- "${ARGS[@]}"
if [ "$(rc_of m1)" = 2 ] && err_of m1 | grep -- '--project' >/dev/null && [ "$(calls_of m1)" = 0 ]; then
  pass "M1 missing --project exits 2 before any glab call"
else fail "M1" "rc=$(rc_of m1) calls=$(calls_of m1)"; fi

run_case m1b milestone -- --project "$PROJECT" --title t
if [ "$(rc_of m1b)" = 2 ] && [ "$(calls_of m1b)" = 0 ]; then pass "M1b missing --plan/--run exits 2"; else fail "M1b" "rc=$(rc_of m1b)"; fi

# M2: not found -> created via --input; description = marker + managed region wrapping the file
run_case m2 milestone -- --project "$PROJECT" "${ARGS[@]}" --description-file "$DESC"
if [ "$(rc_of m2)" = 0 ] && out_of m2 | jq -e '.ok == true and .action == "created" and .id == 80 and .iid == 6 and .title == "Harness v0.1" and (.web_url | endswith("/milestones/6"))' >/dev/null \
  && [ "$(writes_of m2)" = 1 ] && log_of m2 | grep -E -- '-X POST .*/milestones .*input=present' >/dev/null \
  && log_of m2 | grep -E -- '-X GET .*/milestones\?search=Harness%20v0\.1' >/dev/null \
  && body_of m2 1 | jq -e --arg o "$OPEN" --arg c "$CLOSE" '.body.title == "Harness v0.1"
      and (.body.description | rtrimstr("\n")) == ("<!-- silkops: v='"$PLUGIN_V"' plan=plan.md unit=milestone run=r2 -->\n" + $o + "\nnew milestone body\n" + $c)' >/dev/null \
  && ! log_of m2 | grep 'token=set' >/dev/null; then
  pass "M2 not found -> one POST with marker (unit=milestone) + managed region, exact-title search, session identity"
else fail "M2" "rc=$(rc_of m2) out=$(out_of m2) body=$(body_of m2 1 2>/dev/null) log=$(log_of m2 | tr '\n' ';')"; fi

# M2b: marker only when no description file is given
run_case m2b milestone -- --project "$PROJECT" "${ARGS[@]}"
if [ "$(rc_of m2b)" = 0 ] && out_of m2b | jq -e '.action == "created"' >/dev/null \
  && body_of m2b 1 | jq -e '.body.description | startswith("<!-- silkops: v='"$PLUGIN_V"' plan=plan.md unit=milestone run=r2 -->\n")' >/dev/null; then
  pass "M2b no --description-file -> description is the marker + empty managed region"
else fail "M2b" "rc=$(rc_of m2b) body=$(body_of m2b 1 2>/dev/null)"; fi

# M3: found (title matched exactly among two search hits) -> only the managed region changes
run_case m3 milestone-found -- --project "$PROJECT" "${ARGS[@]}" --description-file "$DESC"
if [ "$(rc_of m3)" = 0 ] && out_of m3 | jq -e '.ok == true and .action == "updated" and .id == 77 and .iid == 3' >/dev/null && [ "$(writes_of m3)" = 1 ] \
  && log_of m3 | grep -E -- '-X PUT .*/milestones/77 .*input=present' >/dev/null && ! log_of m3 | grep -E -- '/milestones/78' >/dev/null \
  && body_of m3 1 | jq -e --arg o "$OPEN" --arg c "$CLOSE" '.body.description == ("<!-- silkops: v='"$PLUGIN_V"' plan=plan.md unit=milestone run=r2 -->\n" + $o + "\nnew milestone body\n" + $c + "\n\nHuman notes below.\n") and (.body | has("title") | not)' >/dev/null; then
  pass "M3 found by exact title (not the look-alike) -> PUT with the managed region replaced, run refreshed, human text intact"
else fail "M3" "rc=$(rc_of m3) out=$(out_of m3) body=$(body_of m3 1 2>/dev/null) log=$(log_of m3 | tr '\n' ';')"; fi

# M4: identical region -> unchanged, zero writes
run_case m4 milestone-found -- --project "$PROJECT" --title "Harness v0.1" --plan plan.md --run r1 --description-file "$OLDDESC"
if [ "$(rc_of m4)" = 0 ] && out_of m4 | jq -e '.ok == true and .action == "unchanged" and .id == 77' >/dev/null && [ "$(writes_of m4)" = 0 ]; then
  pass "M4 identical managed region -> action unchanged, zero writes"
else fail "M4" "rc=$(rc_of m4) out=$(out_of m4) writes=$(writes_of m4)"; fi

run_case m5 milestone-found -- --project "$PROJECT" "${ARGS[@]}" --description-file "$DESC" --dry-run
if [ "$(rc_of m5)" = 0 ] && out_of m5 | jq -e '.dry_run == true and .action == "updated" and (.current.description | contains("old milestone body")) and (.proposed.description | contains("new milestone body"))' >/dev/null && [ "$(writes_of m5)" = 0 ]; then
  pass "M5 dry-run shows current vs proposed and writes nothing"
else fail "M5" "rc=$(rc_of m5) out=$(out_of m5) writes=$(writes_of m5)"; fi

run_case m5b milestone -- --project "$PROJECT" "${ARGS[@]}" --dry-run
if [ "$(rc_of m5b)" = 0 ] && out_of m5b | jq -e '.dry_run == true and .action == "created" and .proposed.title == "Harness v0.1"' >/dev/null && [ "$(writes_of m5b)" = 0 ]; then
  pass "M5b dry-run on a missing milestone proposes the create and writes nothing"
else fail "M5b" "rc=$(rc_of m5b) out=$(out_of m5b)"; fi

# M6: lookup 500 -> exit 1 lookup_failed, never falls through to create, stub token redacted
run_case m6 milestone-lookup-500 -- --project "$PROJECT" "${ARGS[@]}" --description-file "$DESC"
if [ "$(rc_of m6)" = 1 ] && out_of m6 | jq -e '.ok == false and .error == "lookup_failed"' >/dev/null && [ "$(writes_of m6)" = 0 ] \
  && err_of m6 | grep -i 'refusing to write' >/dev/null && ! grep -F 'glpat-stubsecret' "$SCRATCH/m6/out.log" "$SCRATCH/m6/err.log" >/dev/null; then
  pass "M6 lookup 500 -> exit 1 lookup_failed, zero writes, stub token redacted"
else fail "M6" "rc=$(rc_of m6) out=$(out_of m6) writes=$(writes_of m6) err=$(err_of m6 | tail -1)"; fi

run_case m7 milestone-closed -- --project "$PROJECT" "${ARGS[@]}" --description-file "$DESC"
if [ "$(rc_of m7)" = 7 ] && out_of m7 | jq -e '.ok == false and .error == "closed_milestone" and .id == 79' >/dev/null && [ "$(writes_of m7)" = 0 ]; then
  pass "M7 closed milestone with the title -> exit 7 refused, zero writes"
else fail "M7" "rc=$(rc_of m7) out=$(out_of m7) writes=$(writes_of m7)"; fi

run_case m8 milestone CI=true -- --project "$PROJECT" "${ARGS[@]}"
if [ "$(rc_of m8)" = 3 ] && out_of m8 | jq -e '.ok == false and .error == "no_token"' >/dev/null && err_of m8 | grep SILKOPS_CI_TOKEN >/dev/null && [ "$(calls_of m8)" = 0 ]; then
  pass "M8 CI without SILKOPS_CI_TOKEN -> exit 3 no_token before any glab call"
else fail "M8" "rc=$(rc_of m8) out=$(out_of m8) calls=$(calls_of m8)"; fi

# --- v0.2 U9 (#34): due and start dates on create
run_case m9 milestone -- --project "$PROJECT" "${ARGS[@]}" --due-date 2026-12-31 --start-date 2026-10-01
if [ "$(rc_of m9)" = 0 ] && out_of m9 | jq -e '.action == "created" and has("due_date") and has("start_date")' >/dev/null \
  && body_of m9 1 | jq -e '.body.due_date == "2026-12-31" and .body.start_date == "2026-10-01"' >/dev/null; then
  pass "M9 --due-date and --start-date are sent on create and reported"
else fail "M9" "rc=$(rc_of m9) out=$(out_of m9) body=$(body_of m9 1 2>/dev/null)"; fi

echo "test-milestone-upsert: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
