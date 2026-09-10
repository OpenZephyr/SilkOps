#!/usr/bin/env bash
# shellcheck disable=SC2034  # SCRIPT, STUB_DIR, SCRATCH, PROJECT are read by lib/harness.sh functions
# Tier 1 tests for ops/schedule.sh against the glab stub (no network).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/ops/lib/harness.sh"
SCRIPT="$ROOT/ops/schedule.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-schedule.XXXXXX")"
TOK=SILKOPS_SETTINGS_TOKEN=glpat-MAINTTOKEN0000000000

run_case s1 schedule $TOK -- list
if [ "$(rc_of s1)" = 2 ] && err_of s1 | grep -- '--project' >/dev/null && [ "$(calls_of s1)" = 0 ]; then
  pass "S1 missing --project exits 2 before any glab call"
else fail "S1" "rc=$(rc_of s1) calls=$(calls_of s1)"; fi

run_case s2a schedule -- --project "$PROJECT" validate --cron '* 22 * * *'
run_case s2b schedule -- --project "$PROJECT" validate --cron '0 22 * * *'
run_case s2c schedule -- --project "$PROJECT" validate --cron '*/15 * * * *'
run_case s2d schedule -- --project "$PROJECT" validate --cron '*/15 * * * *' --allow-frequent
run_case s2e schedule -- --project "$PROJECT" validate --cron '0 6,18 * * *'
run_case s2f schedule -- --project "$PROJECT" validate --cron '0 22 * *'
if [ "$(rc_of s2a)" = 7 ] && out_of s2a | jq -e '.ok == false and .error == "cron_too_frequent"' >/dev/null \
  && [ "$(rc_of s2b)" = 0 ] && out_of s2b | jq -e '.ok == true and .cron == "0 22 * * *"' >/dev/null \
  && [ "$(rc_of s2c)" = 7 ] && out_of s2c | jq -e '.error == "cron_too_frequent"' >/dev/null \
  && [ "$(rc_of s2d)" = 0 ] && out_of s2d | jq -e '.ok == true and .frequent == true' >/dev/null \
  && [ "$(rc_of s2e)" = 7 ] && [ "$(rc_of s2f)" = 2 ] \
  && [ "$(calls_of s2a)$(calls_of s2b)$(calls_of s2c)" = 000 ]; then
  pass "S2 validate: '* 22 * * *' and '*/15 * * * *' and '0 6,18 * * *' refused (7 cron_too_frequent); '0 22 * * *' ok; --allow-frequent ok; 4 fields -> 2; offline"
else fail "S2" "a=$(rc_of s2a) b=$(rc_of s2b) c=$(rc_of s2c) d=$(rc_of s2d) e=$(rc_of s2e) f=$(rc_of s2f) out_a=$(out_of s2a) out_d=$(out_of s2d)"; fi

run_case s3 schedule $TOK -- --project "$PROJECT" create --description weekly --cron '*/15 * * * *' --ref main
if [ "$(rc_of s3)" = 7 ] && out_of s3 | jq -e '.error == "cron_too_frequent"' >/dev/null && [ "$(writes_of s3)" = 0 ]; then
  pass "S3 create with a too-frequent cron exits 7 before any write"
else fail "S3" "rc=$(rc_of s3) writes=$(writes_of s3)"; fi

# S4: `--var K=V` is refused (values never go on argv) before any glab call
run_case s4 schedule $TOK -- --project "$PROJECT" create --description weekly --cron '0 6 * * 1' --ref main --timezone UTC --var FOO=bar
if [ "$(rc_of s4)" = 2 ] && out_of s4 | jq -e '.ok == false and .error == "usage"' >/dev/null && err_of s4 | grep -i 'argv' >/dev/null && [ "$(calls_of s4)" = 0 ]; then
  pass "S4 create --var K=V exits 2 (values never go on argv) before any glab call"
else fail "S4" "rc=$(rc_of s4) err=$(err_of s4 | tail -1) calls=$(calls_of s4)"; fi

# S4b: --var-file carries the value by file; it appears in the POST body and nowhere else
SVAL='Sched3dSecretValue=='
SVF="$SCRATCH/sched-var.txt"; printf '%s\n' "$SVAL" >"$SVF"
sleaked() { grep -F "$2" "$SCRATCH/$1/glab.log" "$SCRATCH/$1/out.log" "$SCRATCH/$1/err.log" 2>/dev/null; }
run_case s4b schedule $TOK -- --project "$PROJECT" create --description weekly --cron '0 6 * * 1' --ref main --timezone UTC --var-file "FOO=$SVF"
if [ "$(rc_of s4b)" = 0 ] && out_of s4b | jq -e '.ok == true and .action == "created" and .id == 32 and .owner.username == "aqua" and .next_run_at != null and .variables == [{key: "FOO"}]' >/dev/null \
  && [ "$(writes_of s4b)" = 2 ] && log_of s4b | grep -E -- '-X POST .*/pipeline_schedules .*token=set' >/dev/null \
  && log_of s4b | grep -E -- '-X POST .*/pipeline_schedules/32/variables .*token=set input=present' >/dev/null \
  && body_of s4b 1 | jq -e --arg v "$SVAL" '.body == {key: "FOO", value: $v}' >/dev/null \
  && ! sleaked s4b "$SVAL" >/dev/null && ! sleaked s4b 'glpat-' >/dev/null; then
  pass "S4b create --var-file: schedule + variable POSTs under the settings token; value only in the --input body, keys-only report"
else fail "S4b" "rc=$(rc_of s4b) out=$(out_of s4b) body=$(body_of s4b 1 2>/dev/null) log=$(log_of s4b | tr '\n' ';') leak=$(sleaked s4b "$SVAL" | head -1)"; fi

# S4c: --var-env reads SILKOPS_SCHEDULE_VAR_<K> from the environment
run_case s4c schedule $TOK "SILKOPS_SCHEDULE_VAR_FOO=$SVAL" -- --project "$PROJECT" create --description weekly --cron '0 6 * * 1' --ref main --var-env FOO
if [ "$(rc_of s4c)" = 0 ] && body_of s4c 1 | jq -e --arg v "$SVAL" '.body == {key: "FOO", value: $v}' >/dev/null && ! sleaked s4c "$SVAL" >/dev/null; then
  pass "S4c create --var-env: value from SILKOPS_SCHEDULE_VAR_FOO reaches the body and nothing else"
else fail "S4c" "rc=$(rc_of s4c) out=$(out_of s4c) err=$(err_of s4c | tail -1)"; fi

# S4d: a missing --var-file or unset --var-env fails before the schedule is created
run_case s4d schedule $TOK -- --project "$PROJECT" create --description weekly --cron '0 6 * * 1' --ref main --var-file "FOO=$SCRATCH/does-not-exist"
run_case s4e schedule $TOK -- --project "$PROJECT" create --description weekly --cron '0 6 * * 1' --ref main --var-env FOO
if [ "$(rc_of s4d)" = 2 ] && [ "$(writes_of s4d)" = 0 ] && [ "$(rc_of s4e)" = 2 ] && [ "$(writes_of s4e)" = 0 ] && err_of s4e | grep SILKOPS_SCHEDULE_VAR_FOO >/dev/null; then
  pass "S4d/e missing var file / unset var env -> exit 2 before any write"
else fail "S4de" "d=$(rc_of s4d)/$(writes_of s4d) e=$(rc_of s4e)/$(writes_of s4e)"; fi

run_case s5 schedule -- --project "$PROJECT" list
if [ "$(rc_of s5)" = 0 ] && out_of s5 | jq -e '.ok == true and .schedules[0].owner.username == "aqua" and .schedules[0].next_run_at == "2026-09-04T22:00:00.000Z" and .schedules[0].cron == "0 22 * * *"' >/dev/null \
  && ! log_of s5 | grep 'token=set' >/dev/null; then
  pass "S5 list reports owner and next_run_at under the session identity"
else fail "S5" "rc=$(rc_of s5) out=$(out_of s5)"; fi

run_case s6 schedule $TOK -- --project "$PROJECT" create --description weekly --cron '0 6 * * 1' --ref main --dry-run
if [ "$(rc_of s6)" = 0 ] && out_of s6 | jq -e '.ok == true and .dry_run == true and (.current | length) == 1 and .proposed.cron == "0 6 * * 1" and .proposed.ref == "main"' >/dev/null && [ "$(writes_of s6)" = 0 ]; then
  pass "S6 create --dry-run shows current schedules and the proposed one, writes nothing"
else fail "S6" "rc=$(rc_of s6) out=$(out_of s6) writes=$(writes_of s6)"; fi

run_case s7 schedule -- --project "$PROJECT" create --description weekly --cron '0 6 * * 1' --ref main
if [ "$(rc_of s7)" = 3 ] && [ "$(writes_of s7)" = 0 ]; then pass "S7 create without SILKOPS_SETTINGS_TOKEN exits 3"; else fail "S7" "rc=$(rc_of s7)"; fi

# --- update (S8-S16) --------------------------------------------------------
# S8: --cron differs from the schedule's -> PUT under the settings token, changed lists cron only
run_case s8 schedule-update $TOK -- --project "$PROJECT" update --id 31 --cron '0 22 * * *'
if [ "$(rc_of s8)" = 0 ] && out_of s8 | jq -e '.ok == true and .action == "updated" and .id == 31 and .cron == "0 22 * * *" and .changed == ["cron"] and .owner.username == "aqua" and .next_run_at != null and (has("owner_differs") | not)' >/dev/null \
  && [ "$(writes_of s8)" = 1 ] && log_of s8 | grep -E -- '-X PUT .*/pipeline_schedules/31 .*token=set input=present' >/dev/null \
  && body_of s8 1 | jq -e '.method == "PUT" and .body == {cron: "0 22 * * *"}' >/dev/null; then
  pass "S8 update --cron issues one PUT under the settings token; changed lists cron only"
else fail "S8" "rc=$(rc_of s8) out=$(out_of s8) writes=$(writes_of s8) log=$(log_of s8 | tr '\n' ';')"; fi

# S9: the same call when the cron already matches -> unchanged, zero writes
run_case s9 schedule-update $TOK -- --project "$PROJECT" update --id 33 --cron '0 22 * * *'
if [ "$(rc_of s9)" = 0 ] && out_of s9 | jq -e '.ok == true and .action == "unchanged" and .id == 33 and .changed == []' >/dev/null && [ "$(writes_of s9)" = 0 ]; then
  pass "S9 update with nothing to change reports unchanged and writes nothing"
else fail "S9" "rc=$(rc_of s9) out=$(out_of s9) writes=$(writes_of s9)"; fi

# S10: the create-time cron guard applies to update too
run_case s10a schedule-update $TOK -- --project "$PROJECT" update --id 31 --cron '* 22 * * *'
run_case s10b schedule-update $TOK -- --project "$PROJECT" update --id 31 --cron '* 22 * * *' --allow-frequent
run_case s10c schedule-update $TOK -- --project "$PROJECT" update --id 31 --cron '*/15 * * * *'
if [ "$(rc_of s10a)" = 7 ] && out_of s10a | jq -e '.ok == false and .error == "cron_too_frequent"' >/dev/null && [ "$(writes_of s10a)" = 0 ] \
  && [ "$(rc_of s10c)" = 7 ] && [ "$(writes_of s10c)" = 0 ] \
  && [ "$(rc_of s10b)" = 0 ] && out_of s10b | jq -e '.action == "updated" and .changed == ["cron"]' >/dev/null && [ "$(writes_of s10b)" = 1 ]; then
  pass "S10 update refuses a sub-daily cron (7 cron_too_frequent, no write); --allow-frequent proceeds"
else fail "S10" "a=$(rc_of s10a)/$(writes_of s10a) b=$(rc_of s10b)/$(writes_of s10b) c=$(rc_of s10c)/$(writes_of s10c) out_b=$(out_of s10b)"; fi

# S11: --id is required, and so is at least one mutable field
run_case s11a schedule-update $TOK -- --project "$PROJECT" update --cron '0 22 * * *'
run_case s11b schedule-update $TOK -- --project "$PROJECT" update --id 31
if [ "$(rc_of s11a)" = 2 ] && out_of s11a | jq -e '.error == "usage"' >/dev/null && err_of s11a | grep -- '--id' >/dev/null && [ "$(calls_of s11a)" = 0 ] \
  && [ "$(rc_of s11b)" = 2 ] && [ "$(calls_of s11b)" = 0 ] && err_of s11b | grep -- '--description' >/dev/null && err_of s11b | grep -- '--active' >/dev/null; then
  pass "S11 update without --id, and without any mutable field, exit 2 before any glab call"
else fail "S11" "a=$(rc_of s11a)/$(calls_of s11a) b=$(rc_of s11b)/$(calls_of s11b) err_b=$(err_of s11b | tail -1)"; fi

# S12: a lookup that fails for any reason but 404 aborts (never "absent")
run_case s12 schedule-lookup-500 $TOK -- --project "$PROJECT" update --id 31 --cron '0 22 * * *'
if [ "$(rc_of s12)" = 1 ] && out_of s12 | jq -e '.ok == false and .error == "lookup_failed"' >/dev/null && [ "$(writes_of s12)" = 0 ] \
  && ! out_of s12 | grep 'glpat-' >/dev/null && ! err_of s12 | grep 'glpat-' >/dev/null; then
  pass "S12 update with a 500 on the lookup exits 1 lookup_failed, writes nothing, stderr redacted"
else fail "S12" "rc=$(rc_of s12) out=$(out_of s12) writes=$(writes_of s12)"; fi

# S13: 404 is the one answer that means absent
run_case s13 schedule-lookup-404 $TOK -- --project "$PROJECT" update --id 31 --cron '0 22 * * *'
if [ "$(rc_of s13)" = 5 ] && out_of s13 | jq -e '.ok == false and .error == "not_found"' >/dev/null && [ "$(writes_of s13)" = 0 ]; then
  pass "S13 update of a schedule that does not exist exits 5 not_found, writes nothing"
else fail "S13" "rc=$(rc_of s13) out=$(out_of s13) writes=$(writes_of s13)"; fi

# S14: --dry-run reports current vs proposed and writes nothing
run_case s14 schedule-update $TOK -- --project "$PROJECT" update --id 31 --cron '0 22 * * *' --description nightly-utc --dry-run
if [ "$(rc_of s14)" = 0 ] && out_of s14 | jq -e '.ok == true and .dry_run == true and .action == "updated" and .current.cron == "0 5 * * *" and .current.description == "nightly" and .proposed.cron == "0 22 * * *" and .proposed.description == "nightly-utc" and (.changed | sort) == ["cron", "description"]' >/dev/null \
  && [ "$(writes_of s14)" = 0 ]; then
  pass "S14 update --dry-run reports current vs proposed and writes nothing"
else fail "S14" "rc=$(rc_of s14) out=$(out_of s14) writes=$(writes_of s14)"; fi

# S15: another user's schedule is flagged, not refused
run_case s15 schedule-update $TOK -- --project "$PROJECT" update --id 34 --cron '0 22 * * *'
if [ "$(rc_of s15)" = 0 ] && out_of s15 | jq -e '.action == "updated" and .owner_differs == true and .owner.username == "silkops-factory-records"' >/dev/null \
  && [ "$(writes_of s15)" = 1 ] && err_of s15 | grep -i 'maintainer' >/dev/null && err_of s15 | grep -i 'ownership' >/dev/null; then
  pass "S15 update of another user's schedule reports owner_differs, notices the Maintainer/ownership caveat, and still writes"
else fail "S15" "rc=$(rc_of s15) out=$(out_of s15) writes=$(writes_of s15) err=$(err_of s15 | tr '\n' ';')"; fi

# S16: --ref, --timezone and --active are mutable too, and the body carries only what differs
run_case s16 schedule-update $TOK -- --project "$PROJECT" update --id 31 --ref main --timezone Europe/Amsterdam --active false
if [ "$(rc_of s16)" = 0 ] && out_of s16 | jq -e '.action == "updated" and (.changed | sort) == ["active", "cron_timezone"]' >/dev/null \
  && body_of s16 1 | jq -e '.body == {cron_timezone: "Europe/Amsterdam", active: false}' >/dev/null; then
  pass "S16 update sends only the fields that differ (--ref main already matches)"
else fail "S16" "rc=$(rc_of s16) out=$(out_of s16) body=$(body_of s16 1 2>/dev/null)"; fi

echo "test-schedule: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
