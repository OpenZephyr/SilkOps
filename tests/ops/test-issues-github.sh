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

# #91: a refused write must not be reported as success; the provider's cleanup used to mask gh's status
run_case i2 "$GH/issues-refused" SILKOPS_PROVIDER=github -- --project "$PROJECT" --marker-unit U4 --plan plan.md --run r2 --title "U4 gap fillers" --body-file "$BODY" --milestone "Harness v0.1" --labels harness,u4
if [ "$(rc_of i2)" != 0 ] && ! out_of i2 | jq -e '.ok == true' >/dev/null 2>&1 \
  && out_of i2 | jq -e '.ok == false and .error == "create_failed" and (.message | contains("403") and contains("permission to create labels"))' >/dev/null; then
  pass "GI2 github: a 403 on create exits nonzero with ok:false and the host's reason in message (#91, #86)"
else fail "GI2" "rc=$(rc_of i2) out=$(out_of i2)"; fi

# --- #86: a contributor without push access (read role) -----------------------------------------
# GR1: markers off -> no `labels` key at all, the footer line is the identity, the result says so
run_case r1 "$GH/issues-read" SILKOPS_PROVIDER=github SILKOPS_MARKER=off -- --project "$PROJECT" --marker-unit U4 --plan plan.md --run r2 --title "U4 gap fillers" --body-file "$BODY" --labels harness,u4
if [ "$(rc_of r1)" = 0 ] && out_of r1 | jq -e '.action == "created" and .iid == 14 and .identity == "body_footer" and .labels_applied == false and .marker == false' >/dev/null \
  && body_of r1 1 | jq -e '(.body | has("labels") | not) and .body.body == "unit body\n\nsilkops-id: plan.md/U4\n"' >/dev/null \
  && err_of r1 | grep -i 'labels dropped' >/dev/null && log_of r1 | grep -E 'collaborators/aqua/permission' >/dev/null; then
  pass "GR1 github read role, markers off: created without labels, 'silkops-id: plan.md/U4' footer, identity body_footer, labels_applied false, warned"
else fail "GR1" "rc=$(rc_of r1) out=$(out_of r1) body=$(body_of r1 1 2>/dev/null) err=$(err_of r1 | tail -2 | tr '\n' ';')"; fi

# GR2: the rerun finds #14 by searching bodies for the footer and updates it: zero creates, footer kept
BODY2="$SCRATCH/body2.md"; printf 'changed body\n' >"$BODY2"
run_case r2 "$GH/issues-read-found" SILKOPS_PROVIDER=github SILKOPS_MARKER=off -- --project "$PROJECT" --marker-unit U4 --plan plan.md --run r3 --title "U4 gap fillers" --body-file "$BODY2" --labels harness,u4
if [ "$(rc_of r2)" = 0 ] && out_of r2 | jq -e '.action == "updated" and .iid == 14 and .identity == "body_footer" and .labels_applied == false' >/dev/null \
  && [ "$(log_of r2 | grep -cE -- '-X POST ')" = 0 ] && log_of r2 | grep -F 'search/issues' >/dev/null && log_of r2 | grep -E -- '-X PATCH .*/issues/14' >/dev/null \
  && body_of r2 1 | jq -e '.body.body == "changed body\n\nsilkops-id: plan.md/U4\n" and (.body | has("labels") | not)' >/dev/null; then
  pass "GR2 github read role rerun: #14 found by body search for the footer, updated with the footer kept, zero creates, no labels"
else fail "GR2" "rc=$(rc_of r2) out=$(out_of r2) body=$(body_of r2 1 2>/dev/null) log=$(log_of r2 | tr '\n' ';' | head -c 500)"; fi

# GR3: markers on, read role: the marker comment is the identity; labels still dropped, no footer
run_case r3 "$GH/issues-read" SILKOPS_PROVIDER=github -- --project "$PROJECT" --marker-unit U4 --plan plan.md --run r2 --title "U4 gap fillers" --body-file "$BODY" --labels harness,u4
if [ "$(rc_of r3)" = 0 ] && out_of r3 | jq -e '.action == "created" and .identity == "marker" and .labels_applied == false and .marker == true' >/dev/null \
  && body_of r3 1 | jq -e '(.body | has("labels") | not) and (.body.body | startswith("<!-- silkops: v=")) and (.body.body | contains("silkops-id:") | not)' >/dev/null; then
  pass "GR3 github read role, markers on: labels dropped, identity stays the marker comment, no footer"
else fail "GR3" "rc=$(rc_of r3) out=$(out_of r3) body=$(body_of r3 1 2>/dev/null)"; fi

# --- #87: issue-close on GitHub: comment, then PATCH state closed ---------------------------------
SCRIPT="$ROOT/ops/issue-close.sh"
NOTE="$SCRATCH/proof.md"; printf 'Fixed in abc1234.\n' >"$NOTE"
run_case c1 "$GH/issues" SILKOPS_PROVIDER=github -- --project "$PROJECT" --iid 13 --note-file "$NOTE"
if [ "$(rc_of c1)" = 0 ] && out_of c1 | jq -e '.ok == true and .provider == "github" and .iid == 13 and .action == "closed" and .state == "closed" and .note_id == 803' >/dev/null \
  && log_of c1 | grep -E -- '-X POST .*/issues/13/comments' >/dev/null && log_of c1 | grep -E -- '-X PATCH .*/issues/13( |$)' >/dev/null \
  && body_of c1 2 | jq -e '.body == {state: "closed"}' >/dev/null; then
  pass "GC1 github: issue-close posts the comment, then PATCH state closed; state and note_id reported"
else fail "GC1" "rc=$(rc_of c1) out=$(out_of c1) log=$(log_of c1 | tr '\n' ';' | head -c 500) b2=$(body_of c1 2 2>/dev/null)"; fi

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
