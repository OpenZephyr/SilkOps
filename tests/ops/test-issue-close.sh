#!/usr/bin/env bash
# shellcheck disable=SC2034  # SCRIPT, STUB_DIR, SCRATCH, PROJECT are read by lib/harness.sh functions
# Tier 1 tests for ops/issue-close.sh (#87): one provider-neutral close, optionally after a proof
# note; an already-closed issue is refused (7), an unknown one is 5, a dry run writes nothing.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/ops/lib/harness.sh"
SCRIPT="$ROOT/ops/issue-close.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-issue-close.XXXXXX")"
NOTE="$SCRATCH/proof.md"; printf 'Fixed in abc1234; the smoke test passes.\n' >"$NOTE"

# C1: missing --project exits 2 before any call
run_case c1 close-open -- --iid 40
if [ "$(rc_of c1)" = 2 ] && err_of c1 | grep -- '--project' >/dev/null && [ "$(calls_of c1)" = 0 ]; then
  pass "C1 missing --project exits 2 before any glab call"
else fail "C1" "rc=$(rc_of c1) calls=$(calls_of c1)"; fi

# C2: open issue + note: the note is posted first, then one PUT with state_event close; both reported
run_case c2 close-open -- --project "$PROJECT" --iid 40 --note-file "$NOTE"
if [ "$(rc_of c2)" = 0 ] && out_of c2 | jq -e '.ok == true and .iid == 40 and .action == "closed" and .prior_state == "opened" and .state == "closed" and .note_id == 803 and .provider == "gitlab"' >/dev/null \
  && [ "$(writes_of c2)" = 2 ] && log_of c2 | grep -E -- '-X POST .*/issues/40/notes .*input=present' >/dev/null \
  && log_of c2 | grep -E -- '-X PUT .*/issues/40 .*input=present' >/dev/null \
  && body_of c2 1 | jq -e '.body.body | contains("Fixed in abc1234")' >/dev/null \
  && body_of c2 2 | jq -e '.body == {state_event: "close"}' >/dev/null; then
  pass "C2 open issue: proof note posted (id 803), then state_event close in one PUT; state closed reported"
else fail "C2" "rc=$(rc_of c2) out=$(out_of c2) log=$(log_of c2 | tr '\n' ';') b2=$(body_of c2 2 2>/dev/null)"; fi

# C2b: without --note-file only the close is written
run_case c2b close-open -- --project "$PROJECT" --iid 40
if [ "$(rc_of c2b)" = 0 ] && out_of c2b | jq -e '.state == "closed" and .note_id == null' >/dev/null && [ "$(writes_of c2b)" = 1 ]; then
  pass "C2b no note file: one write, note_id null"
else fail "C2b" "rc=$(rc_of c2b) out=$(out_of c2b) writes=$(writes_of c2b)"; fi

# C3: already closed -> exit 7 already_closed, zero writes (never a reopen, never a second close)
run_case c3 close-closed -- --project "$PROJECT" --iid 40 --note-file "$NOTE"
if [ "$(rc_of c3)" = 7 ] && out_of c3 | jq -e '.ok == false and .error == "already_closed" and .iid == 40' >/dev/null && [ "$(writes_of c3)" = 0 ]; then
  pass "C3 already closed -> exit 7 already_closed, zero writes"
else fail "C3" "rc=$(rc_of c3) out=$(out_of c3) writes=$(writes_of c3)"; fi

# C4: unknown iid -> exit 5 not_found, zero writes
run_case c4 close-missing -- --project "$PROJECT" --iid 41
if [ "$(rc_of c4)" = 5 ] && out_of c4 | jq -e '.ok == false and .error == "not_found"' >/dev/null && [ "$(writes_of c4)" = 0 ] \
  && ! grep -F 'glpat-stubsecret' "$SCRATCH/c4/out.log" "$SCRATCH/c4/err.log" >/dev/null; then
  pass "C4 missing issue -> exit 5 not_found, zero writes, stub token redacted"
else fail "C4" "rc=$(rc_of c4) out=$(out_of c4) writes=$(writes_of c4)"; fi

# C5: --dry-run reads the issue, reports the proposed state and note, writes nothing
run_case c5 close-open -- --project "$PROJECT" --iid 40 --note-file "$NOTE" --dry-run
if [ "$(rc_of c5)" = 0 ] && out_of c5 | jq -e '.dry_run == true and .current.state == "opened" and .proposed.state == "closed" and (.proposed.note.body | contains("Fixed in"))' >/dev/null \
  && [ "$(writes_of c5)" = 0 ]; then
  pass "C5 dry-run: current and proposed state reported, the note text shown, zero writes"
else fail "C5" "rc=$(rc_of c5) out=$(out_of c5) writes=$(writes_of c5)"; fi

echo "test-issue-close: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
