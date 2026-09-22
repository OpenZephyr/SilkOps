#!/usr/bin/env bash
# shellcheck disable=SC2034  # SCRIPT, STUB_DIR, SCRATCH, PROJECT are read by lib/harness.sh functions
# Tier 1 tests for ops/milestone-sync.sh (v0.2 U9, #24 #34 #36): one call parses, upserts the
# milestone and every issue, links every edge, and returns one report. Offline, glab stub.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/ops/lib/harness.sh"
SCRIPT="$ROOT/ops/milestone-sync.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-msync.XXXXXX")"
PLAN="$ROOT/tests/fixtures/plans/sync-two.md"

# S1: a plan -> milestone from its title, one issue per unit, one link per edge, one report
run_case s1 sync-two -- --project "$PROJECT" --plan "$PLAN" --run r9
if [ "$(rc_of s1)" = 0 ] && out_of s1 | jq -e '.ok == true and .milestone.title == "Harness v0.1" and .milestone.action == "updated"
      and (.issues | length) == 2 and .issues[0].unit == "U1" and .issues[0].iid == 21 and .issues[0].action == "updated"
      and .issues[1].unit == "U2" and .issues[1].iid == 22 and .issues[1].blocked_by == [21]
      and (.links | length) == 1 and .links[0].source_iid == 21 and .links[0].target_iid == 22 and .links[0].link_type == "blocks"' >/dev/null \
  && [ "$(writes_of s1)" = 4 ] && [ "$(log_of s1 | grep -cE -- '-X PUT .*/issues/2[12] ')" = 2 ] \
  && body_of s1 2 | jq -e '.body.description | contains("**Goal.** do the first thing.") and contains("**Depends on.** —")' >/dev/null; then
  pass "S1 plan -> milestone updated, U1 #21 and U2 #22 re-synced, U1 blocks U2 linked, one JSON report, four writes"
else fail "S1" "rc=$(rc_of s1) out=$(out_of s1 | head -c 800) writes=$(writes_of s1) log=$(log_of s1 | grep -E 'X (PUT|POST)' | tr '\n' ';')"; fi

# S2: --dry-run writes nothing and still reports the plan
run_case s2 sync-two -- --project "$PROJECT" --plan "$PLAN" --run r9 --dry-run
if [ "$(rc_of s2)" = 0 ] && out_of s2 | jq -e '.dry_run == true and (.issues | length) == 2' >/dev/null && [ "$(writes_of s2)" = 0 ]; then
  pass "S2 dry-run: zero writes, the plan is still reported"
else fail "S2" "rc=$(rc_of s2) out=$(out_of s2 | head -c 400) writes=$(writes_of s2)"; fi

# S3: an ad-hoc set (no plan): assignee, due date, blocked_by by unit name, marker namespace adhoc-<slug>
cat >"$SCRATCH/adhoc.json" <<'JSON'
{"plan": "adhoc-x", "milestone": "Harness v0.1",
 "issues": [
  {"unit": "A1", "title": "First ad-hoc", "body": "body one\n", "labels": ["roadmap"], "assignee": "aqua", "due_date": "2026-10-01", "blocked_by": ["A2"]},
  {"unit": "A2", "title": "Second ad-hoc", "body": "body two\n", "labels": ["roadmap"]}
 ]}
JSON
run_case s3 sync-two -- --project "$PROJECT" --issues "$SCRATCH/adhoc.json" --run r9
if [ "$(rc_of s3)" = 0 ] && out_of s3 | jq -e '.issues[0].unit == "A1" and .issues[0].iid == 31 and .issues[0].assignee == "aqua" and .issues[0].due_date == "2026-10-01"
      and .issues[0].blocked_by == [32] and .links[0].source_iid == 32 and .links[0].target_iid == 31' >/dev/null \
  && log_of s3 | grep -E -- 'users\?username=aqua' >/dev/null \
  && body_of s3 2 | jq -e '.body.assignee_ids == [42] and .body.due_date == "2026-10-01" and (.body.description | contains("body one")) and (.body.add_labels | contains("roadmap"))' >/dev/null; then
  pass "S3 ad-hoc set: assignee resolved to an id, due date set, blocked_by resolved by unit name, plan=adhoc-x marker"
else fail "S3" "rc=$(rc_of s3) out=$(out_of s3 | head -c 800) body2=$(body_of s3 2 2>/dev/null | head -c 400)"; fi

# S4: usage — neither --plan nor --issues, or both
run_case s4 sync-two -- --project "$PROJECT" --run r9
run_case s4b sync-two -- --project "$PROJECT" --run r9 --plan "$PLAN" --issues "$SCRATCH/adhoc.json"
if [ "$(rc_of s4)" = 2 ] && [ "$(rc_of s4b)" = 2 ] && [ "$(calls_of s4)" = 0 ]; then
  pass "S4 exactly one of --plan / --issues, else exit 2 before any call"
else fail "S4" "rc=$(rc_of s4)/$(rc_of s4b)"; fi

echo "test-milestone-sync: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
