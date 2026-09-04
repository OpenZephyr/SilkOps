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

run_case s4 schedule $TOK -- --project "$PROJECT" create --description weekly --cron '0 6 * * 1' --ref main --timezone UTC --var FOO=bar
if [ "$(rc_of s4)" = 0 ] && out_of s4 | jq -e '.ok == true and .action == "created" and .id == 32 and .owner.username == "aqua" and .next_run_at != null and (.variables | length) == 1' >/dev/null \
  && [ "$(writes_of s4)" = 2 ] && log_of s4 | grep -E -- '-X POST .*/pipeline_schedules .*token=set' >/dev/null \
  && log_of s4 | grep -E -- '-X POST .*/pipeline_schedules/32/variables .*token=set' >/dev/null \
  && ! grep 'glpat-' "$SCRATCH/s4/glab.log" "$SCRATCH/s4/out.log" "$SCRATCH/s4/err.log" >/dev/null; then
  pass "S4 create: schedule + variable POSTs under the settings token; owner and next_run_at reported"
else fail "S4" "rc=$(rc_of s4) out=$(out_of s4) log=$(log_of s4 | tr '\n' ';')"; fi

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

echo "test-schedule: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
