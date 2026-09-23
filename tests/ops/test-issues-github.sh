#!/usr/bin/env bash
# shellcheck disable=SC2034
# Tier 1 tests for issue-upsert.sh, milestone-upsert.sh, issue-link.sh and milestone-sync.sh with
# SILKOPS_PROVIDER=github (v0.3 U3): issues and milestones map, links become a managed-region line.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
GH="$ROOT/tests/fixtures/gh-stub"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/ops/lib/harness.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-issues-gh.XXXXXX")"
PROJECT="example/silkops-harness"
BODY="$SCRATCH/body.md"; printf 'unit body\n' >"$BODY"

SCRIPT="$ROOT/ops/issue-upsert.sh"
run_case i1 "$GH/issues" SILKOPS_PROVIDER=github -- --project "$PROJECT" --marker-unit U4 --plan plan.md --run r2 --title "U4 gap fillers" --body-file "$BODY" --milestone "Harness v0.1" --labels harness,u4 --assignee aqua
if [ "$(rc_of i1)" = 0 ] && out_of i1 | jq -e '.action == "created" and .iid == 13 and .provider == "github"' >/dev/null \
  && body_of i1 1 | jq -e '.body.title == "U4 gap fillers" and (.body.body | contains("unit body")) and (.body.labels | index("u4")) and .body.milestone == 3 and .body.assignees == ["aqua"]' >/dev/null; then
  pass "GI1 github: issue created with labels as a list, milestone by number, assignee by login"
else fail "GI1" "rc=$(rc_of i1) out=$(out_of i1) body=$(body_of i1 1 2>/dev/null) log=$(log_of i1 | tr '\n' ';' | head -c 400)"; fi

SCRIPT="$ROOT/ops/issue-link.sh"
run_case l1 "$GH/issues" SILKOPS_PROVIDER=github -- --project "$PROJECT" --source 10 --target 11 --type blocks
if [ "$(rc_of l1)" = 0 ] && out_of l1 | jq -e '.fallback == "managed_region" and .depends_on_line == "Blocked by #10" and .link_type == null' >/dev/null && [ "$(writes_of l1)" = 0 ]; then
  pass "GL1 github: no issue links on the host -> fallback managed_region with the Blocked-by line, zero writes"
else fail "GL1" "rc=$(rc_of l1) out=$(out_of l1)"; fi

SCRIPT="$ROOT/ops/milestone-sync.sh"
run_case s1 "$GH/issues" SILKOPS_PROVIDER=github -- --project "$PROJECT" --plan "$ROOT/tests/fixtures/plans/sync-two.md" --run r9
if [ "$(rc_of s1)" = 0 ] && out_of s1 | jq -e '.milestone.action == "updated" and (.issues | length) == 2 and .links[0].fallback == "managed_region"' >/dev/null; then
  pass "GS1 github: a plan syncs to a milestone and issues; the dependency edge is reported as the managed-region fallback"
else fail "GS1" "rc=$(rc_of s1) out=$(out_of s1 | head -c 700)"; fi

echo "test-issues-github: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
