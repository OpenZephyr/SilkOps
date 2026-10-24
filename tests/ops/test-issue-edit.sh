#!/usr/bin/env bash
# shellcheck disable=SC2034  # SCRIPT, STUB_DIR, SCRATCH, PROJECT are read by lib/harness.sh functions
# Tier 1 tests for ops/issue-edit.sh (#84): assignee, due date and milestone on one issue found
# by iid; the operator from the fact layers; closed issues refused; dead @mentions warned.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/ops/lib/harness.sh"
SCRIPT="$ROOT/ops/issue-edit.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-issue-edit.XXXXXX")"

# E1: missing --project exits 2 before any call
run_case e1 edit-open -- --iid 40 --assignee aqua
if [ "$(rc_of e1)" = 2 ] && err_of e1 | grep -- '--project' >/dev/null && [ "$(calls_of e1)" = 0 ]; then
  pass "E1 missing --project exits 2 before any glab call"
else fail "E1" "rc=$(rc_of e1) calls=$(calls_of e1)"; fi

# E2: assign by username: the id is resolved, one PUT, the issue read back, changed[] names the field
run_case e2 edit-open -- --project "$PROJECT" --iid 40 --assignee aqua --due-date 2026-11-01 --milestone "Harness v0.1"
if [ "$(rc_of e2)" = 0 ] && out_of e2 | jq -e '.ok == true and .iid == 40 and .action == "updated" and .changed == ["assignee", "due_date", "milestone"]
      and (.assignees | type) == "array" and has("due_date") and has("milestone")' >/dev/null \
  && [ "$(writes_of e2)" = 1 ] && log_of e2 | grep -E -- '-X PUT .*/issues/40 .*input=present' >/dev/null \
  && log_of e2 | grep -E -- 'users\?username=aqua' >/dev/null \
  && [ "$(log_of e2 | grep -cE -- '-X GET .*/issues/40( |$)')" = 2 ] \
  && body_of e2 1 | jq -e '.body.assignee_ids == [42] and .body.due_date == "2026-11-01" and .body.milestone_id == 77 and (.body | has("description") | not)' >/dev/null; then
  pass "E2 --assignee resolves aqua to id 42; due date and milestone sent in one PUT; the issue is read back; no description write"
else fail "E2" "rc=$(rc_of e2) out=$(out_of e2) body=$(body_of e2 1 2>/dev/null) log=$(log_of e2 | tr '\n' ';')"; fi

# E3: --assign-operator reads operator_username from the cwd's .silkops/facts.json
mkdir -p "$SCRATCH/repo/.silkops"; printf '{"operator_username": "aqua", "facts": []}\n' >"$SCRATCH/repo/.silkops/facts.json"
# the operator's own shell may carry an overlay and SILKOPS_OPERATOR: isolate both
ISO=(SILKOPS_FACTS_OVERLAY="$SCRATCH/no-overlay" SILKOPS_OPERATOR=)
(cd "$SCRATCH/repo" && run_case e3 edit-open "${ISO[@]}" -- --project "$PROJECT" --iid 40 --assign-operator)
if [ "$(rc_of e3)" = 0 ] && out_of e3 | jq -e '.action == "updated" and .changed == ["assignee"]' >/dev/null \
  && body_of e3 1 | jq -e '.body == {assignee_ids: [42]}' >/dev/null; then
  pass "E3 --assign-operator takes operator_username from .silkops/facts.json and sends only the assignee"
else fail "E3" "rc=$(rc_of e3) out=$(out_of e3) body=$(body_of e3 1 2>/dev/null)"; fi

# E3b: no facts, SILKOPS_OPERATOR as the fallback; E3c: neither -> exit 2 naming both
run_case e3b edit-open SILKOPS_FACTS_OVERLAY="$SCRATCH/no-overlay" SILKOPS_OPERATOR=aqua -- --project "$PROJECT" --iid 40 --assign-operator
run_case e3c edit-open "${ISO[@]}" -- --project "$PROJECT" --iid 40 --assign-operator
if [ "$(rc_of e3b)" = 0 ] && out_of e3b | jq -e '.changed == ["assignee"]' >/dev/null \
  && [ "$(rc_of e3c)" = 2 ] && out_of e3c | jq -e '.error == "no_operator"' >/dev/null && err_of e3c | grep 'operator_username' >/dev/null && err_of e3c | grep 'SILKOPS_OPERATOR' >/dev/null && [ "$(calls_of e3c)" = 0 ]; then
  pass "E3b SILKOPS_OPERATOR is the fallback; E3c with neither -> exit 2 naming the fact and the variable, zero calls"
else fail "E3" "b: rc=$(rc_of e3b) out=$(out_of e3b); c: rc=$(rc_of e3c) out=$(out_of e3c) err=$(err_of e3c | tail -1)"; fi

# E4: closed issue -> exit 7, zero writes
run_case e4 edit-closed -- --project "$PROJECT" --iid 40 --assignee aqua
if [ "$(rc_of e4)" = 7 ] && out_of e4 | jq -e '.ok == false and .error == "closed_issue" and .iid == 40' >/dev/null && [ "$(writes_of e4)" = 0 ]; then
  pass "E4 closed issue -> exit 7 closed_issue, zero writes"
else fail "E4" "rc=$(rc_of e4) out=$(out_of e4) writes=$(writes_of e4)"; fi

# E5: a dead @mention in the description is warned on stderr and listed, the edit still happens
if out_of e2 | jq -e '.dead_mentions == ["ghost"]' >/dev/null && err_of e2 | grep -E 'warning.*@ghost' >/dev/null \
  && log_of e2 | grep -E -- 'users\?username=ghost' >/dev/null && ! log_of e2 | grep -E -- 'username=example' >/dev/null; then
  pass "E5 @ghost is unknown -> warned and reported in dead_mentions[]; @aqua known; the email is not a mention"
else fail "E5" "out=$(out_of e2) err=$(err_of e2 | tr '\n' ';') log=$(log_of e2 | grep users | tr '\n' ';')"; fi

# E6: unknown assignee -> exit 5, zero writes
run_case e6 edit-open -- --project "$PROJECT" --iid 40 --assignee ghost
if [ "$(rc_of e6)" = 5 ] && out_of e6 | jq -e '.error == "not_found"' >/dev/null && [ "$(writes_of e6)" = 0 ]; then
  pass "E6 unknown username -> exit 5 not_found, zero writes"
else fail "E6" "rc=$(rc_of e6) out=$(out_of e6) writes=$(writes_of e6)"; fi

# E7: --dry-run plans the write and writes nothing; nothing to change -> usage
run_case e7 edit-open -- --project "$PROJECT" --iid 40 --assignee aqua --dry-run
run_case e7b edit-open -- --project "$PROJECT" --iid 40
if [ "$(rc_of e7)" = 0 ] && out_of e7 | jq -e '.dry_run == true and .changed == ["assignee"] and .proposed.assignee_ids == [42] and .current.assignees == []' >/dev/null && [ "$(writes_of e7)" = 0 ] \
  && [ "$(rc_of e7b)" = 2 ] && [ "$(calls_of e7b)" = 0 ]; then
  pass "E7 dry run reports current vs proposed with zero writes; no field at all is a usage error"
else fail "E7" "rc=$(rc_of e7)/$(rc_of e7b) out=$(out_of e7) writes=$(writes_of e7)"; fi

# E8: in CI without SILKOPS_CI_TOKEN -> exit 3 before any call
run_case e8 edit-open CI=true -- --project "$PROJECT" --iid 40 --assignee aqua
if [ "$(rc_of e8)" = 3 ] && out_of e8 | jq -e '.error == "no_token"' >/dev/null && [ "$(calls_of e8)" = 0 ]; then
  pass "E8 CI without SILKOPS_CI_TOKEN -> exit 3, zero calls"
else fail "E8" "rc=$(rc_of e8) out=$(out_of e8) calls=$(calls_of e8)"; fi

echo "test-issue-edit: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
