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

# S2: --dry-run writes nothing and still reports the plan; each entry carries the exact proposed text (#88)
run_case s2 sync-two -- --project "$PROJECT" --plan "$PLAN" --run r9 --dry-run
if [ "$(rc_of s2)" = 0 ] && out_of s2 | jq -e '.dry_run == true and (.issues | length) == 2
      and .issues[0].proposed.title == "U1 — First thing" and (.issues[0].proposed.description | contains("**Goal.** do the first thing."))
      and (.issues[0].proposed.labels | index("silkops") != null and index("u1") != null) and .issues[0].proposed.milestone == "Harness v0.1"
      and (.issues[1].proposed.description | contains("do the second thing."))' >/dev/null && [ "$(writes_of s2)" = 0 ]; then
  pass "S2 dry-run: zero writes; every entry carries proposed {title, labels, description, milestone} with the unit body untruncated"
else fail "S2" "rc=$(rc_of s2) out=$(out_of s2 | head -c 600) writes=$(writes_of s2)"; fi

# S2b: --show is the same dry run plus a readable preview (title, labels, body) on stderr
run_case s2b sync-two -- --project "$PROJECT" --plan "$PLAN" --run r9 --show
if [ "$(rc_of s2b)" = 0 ] && out_of s2b | jq -e '.dry_run == true and .issues[0].proposed.title == "U1 — First thing"' >/dev/null && [ "$(writes_of s2b)" = 0 ] \
  && err_of s2b | grep -F -- '--- U1 — First thing' >/dev/null && err_of s2b | grep -E '^labels: .*u1' >/dev/null && err_of s2b | grep -F 'do the first thing.' >/dev/null; then
  pass "S2b --show: dry run plus a stderr preview naming the title, labels and body of each issue; zero writes"
else fail "S2b" "rc=$(rc_of s2b) err=$(err_of s2b | head -c 400) writes=$(writes_of s2b)"; fi

# S2c: without --dry-run the entries carry no proposed text
if out_of s1 | jq -e '.issues[0] | has("proposed") | not' >/dev/null; then pass "S2c a live sync carries no proposed text"; else fail "S2c" "$(out_of s1 | head -c 300)"; fi

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

# S5 (#68): a dry run on a plan whose milestone does not exist yet still prints the plan, zero writes
run_case s5 sync-fresh -- --project "$PROJECT" --plan "$PLAN" --run r9 --dry-run
if [ "$(rc_of s5)" = 0 ] && out_of s5 | jq -e '.dry_run == true and .milestone.action == "created" and .milestone.proposed == true and (.issues | length) == 2 and .issues[0].action == "created"' >/dev/null && [ "$(writes_of s5)" = 0 ]; then
  pass "S5 (#68) fresh plan dry run: milestone reported as proposed, issues planned without it, zero writes"
else fail "S5" "rc=$(rc_of s5) out=$(out_of s5 | head -c 500) writes=$(writes_of s5)"; fi

# S6 (#78): a multi-milestone plan (## M1, ## M2) plans two milestones, files each unit under its own,
# keeps the cross-milestone edge (M1-02 -> M2-01); nothing written in a dry run
MPLAN="$ROOT/tests/fixtures/plans/milestones-two.md"
run_case s6 sync-fresh SILKOPS_FACTS_OVERLAY="$SCRATCH/no-overlay" -- --project "$PROJECT" --plan "$MPLAN" --run r9 --dry-run
if [ "$(rc_of s6)" = 0 ] && out_of s6 | jq -e '.dry_run == true and .milestone == null and (.milestones | length) == 2
      and (.milestones | map(.title)) == ["Foundations", "Delivery"] and (.milestones | all(.action == "created" and .proposed == true))
      and (.issues | length) == 5 and .issues[0].unit == "M1-01" and .issues[0].milestone == "Foundations" and .issues[3].unit == "M2-01" and .issues[3].milestone == "Delivery"
      and ([.links[] | select(.source_unit == "M1-02" and .target_unit == "M2-01")] | length) == 1' >/dev/null \
  && [ "$(writes_of s6)" = 0 ] && [ "$(log_of s6 | grep -cE -- 'milestones\?search=')" = 2 ]; then
  pass "S6 (#78) milestones plan dry run: two milestones planned (Foundations, Delivery), five units under their own, M1-02 -> M2-01 kept, zero writes"
else fail "S6" "rc=$(rc_of s6) out=$(out_of s6 | head -c 900) writes=$(writes_of s6) log=$(log_of s6 | grep milestones | tr '\n' ';')"; fi

# S6b: --milestone on a plan that declares its own milestones is a usage error
run_case s6b sync-fresh -- --project "$PROJECT" --plan "$MPLAN" --run r9 --milestone "One" --dry-run
if [ "$(rc_of s6b)" = 2 ] && [ "$(calls_of s6b)" = 0 ]; then pass "S6b --milestone with a multi-milestone plan -> exit 2"; else fail "S6b" "rc=$(rc_of s6b)"; fi

# S7 (#90): {{link:path:a-b}} in a body becomes a permalink pinned at --sha (a ref resolves) at the
# --project-url; unknown placeholders stay verbatim; HEAD is the default sha
cat >"$SCRATCH/links.json" <<'JSON'
{"plan": "adhoc-x", "milestone": "Harness v0.1",
 "issues": [{"unit": "A1", "title": "Linked", "body": "At {{link:ops/link.sh:3-4}} and {{link:README.md}}; keep {{other}}.\n", "labels": ["roadmap"]}]}
JSON
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
run_case s7 sync-two -- --project "$PROJECT" --issues "$SCRATCH/links.json" --run r9 --sha HEAD --project-url https://gl.example/g/p
run_case s7b sync-two -- --project "$PROJECT" --issues "$SCRATCH/links.json" --run r9
if [ "$(rc_of s7)" = 0 ] && body_of s7 2 | jq -e --arg u "https://gl.example/g/p/-/blob/$HEAD_SHA/ops/link.sh#L3-4" --arg w "https://gl.example/g/p/-/blob/$HEAD_SHA/README.md" \
      '.body.description | contains("At " + $u + " and " + $w + "; keep {{other}}.")' >/dev/null \
  && [ "$(rc_of s7b)" = 0 ] && body_of s7b 2 | jq -e --arg u "https://gitlab.com/$PROJECT/-/blob/$HEAD_SHA/ops/link.sh#L3-4" '.body.description | contains($u)' >/dev/null; then
  pass "S7 (#90) {{link:…}} pinned at --sha on --project-url; HEAD and the known host by default; {{other}} verbatim"
else fail "S7" "rc=$(rc_of s7)/$(rc_of s7b) body=$(body_of s7 2 2>/dev/null | head -c 600) err=$(err_of s7 | head -3)"; fi

echo "test-milestone-sync: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
