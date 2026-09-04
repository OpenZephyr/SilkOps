#!/usr/bin/env bash
# shellcheck disable=SC2034  # SCRIPT, STUB_DIR, SCRATCH, PROJECT are read by lib/harness.sh functions
# Tier 1 tests for ops/variable.sh against the glab stub (no network). Values never leak.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/ops/lib/harness.sh"
SCRIPT="$ROOT/ops/variable.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-variable.XXXXXX")"
TOK=SILKOPS_SETTINGS_TOKEN=glpat-MAINTTOKEN0000000000
SECRET='Sup3rSecretValue=='
VF="$SCRATCH/value.txt"; printf '%s\n' "$SECRET" >"$VF"
leaked() { grep -F "$2" "$SCRATCH/$1/glab.log" "$SCRATCH/$1/out.log" "$SCRATCH/$1/err.log" 2>/dev/null; }

run_case v1 variable $TOK -- list
if [ "$(rc_of v1)" = 2 ] && err_of v1 | grep -- '--project' >/dev/null && [ "$(calls_of v1)" = 0 ]; then
  pass "V1 missing --project exits 2 before any glab call"
else fail "V1" "rc=$(rc_of v1) calls=$(calls_of v1)"; fi

run_case v2 variable -- --project "$PROJECT" list
if [ "$(rc_of v2)" = 0 ] && out_of v2 | jq -e '.ok == true and (.variables | length) == 2 and (.variables | map(has("value")) | any | not) and .variables[0].key == "EXISTING" and .variables[0].masked == true' >/dev/null \
  && ! out_of v2 | grep -F 's3cr3t' >/dev/null && ! err_of v2 | grep -F 's3cr3t' >/dev/null && ! log_of v2 | grep 'token=set' >/dev/null; then
  pass "V2 list prints keys and flags, never a value; session identity"
else fail "V2" "rc=$(rc_of v2) out=$(out_of v2)"; fi

run_case v3 variable $TOK -- --project "$PROJECT" set --key FOO --value x
if [ "$(rc_of v3)" = 2 ] && err_of v3 | grep -i 'argv' >/dev/null && [ "$(calls_of v3)" = 0 ] && out_of v3 | jq -e '.ok == false' >/dev/null; then
  pass "V3 set --value exits 2 (values never go on argv) before any glab call"
else fail "V3" "rc=$(rc_of v3) err=$(err_of v3 | tail -1) calls=$(calls_of v3)"; fi

SHORT="$SCRATCH/short.txt"; printf 'abc\n' >"$SHORT"
run_case v4 variable $TOK -- --project "$PROJECT" set --key FOO --value-file "$SHORT" --masked
if [ "$(rc_of v4)" = 2 ] && out_of v4 | jq -e '.ok == false and .error == "masked_constraint" and .constraint == "masked_min_length"' >/dev/null && [ "$(writes_of v4)" = 0 ] && ! leaked v4 abc >/dev/null; then
  pass "V4 short masked value -> constraint named (masked_min_length), zero writes, value not echoed"
else fail "V4" "rc=$(rc_of v4) out=$(out_of v4)"; fi
ML="$SCRATCH/ml.txt"; printf 'line-one-long\nline-two\n' >"$ML"
run_case v4b variable $TOK -- --project "$PROJECT" set --key FOO --value-file "$ML" --masked
BAD="$SCRATCH/bad.txt"; printf 'has spaces in it\n' >"$BAD"
run_case v4c variable $TOK -- --project "$PROJECT" set --key FOO --value-file "$BAD" --masked
if out_of v4b | jq -e '.constraint == "masked_single_line"' >/dev/null && out_of v4c | jq -e '.constraint == "masked_charset"' >/dev/null && [ "$(writes_of v4b)$(writes_of v4c)" = 00 ]; then
  pass "V4b/c multi-line and bad-charset masked values name masked_single_line / masked_charset"
else fail "V4bc" "b=$(out_of v4b) c=$(out_of v4c)"; fi

run_case v5 variable $TOK -- --project "$PROJECT" set --key NEWKEY --value-file "$VF" --masked
if [ "$(rc_of v5)" = 0 ] && out_of v5 | jq -e '.ok == true and .action == "created" and .key == "NEWKEY" and .masked == true and (has("value") | not)' >/dev/null \
  && [ "$(writes_of v5)" = 1 ] && log_of v5 | grep -E -- '-X POST .*/variables .*token=set input=present' >/dev/null \
  && body_of v5 1 | jq -e --arg v "$SECRET" '.body.key == "NEWKEY" and .body.value == $v and .body.masked == true' >/dev/null \
  && ! leaked v5 "$SECRET" >/dev/null && ! leaked v5 'glpat-' >/dev/null; then
  pass "V5 valid masked set: POST via --input under the settings token; value absent from log, stdout, stderr"
else fail "V5" "rc=$(rc_of v5) out=$(out_of v5) log=$(log_of v5 | tr '\n' ';') leak=$(leaked v5 "$SECRET" | head -1)"; fi

run_case v6 variable $TOK -- --project "$PROJECT" set --key EXISTING --value-file "$VF" --masked --protected
if [ "$(rc_of v6)" = 0 ] && out_of v6 | jq -e '.ok == true and .action == "updated" and .protected == true' >/dev/null \
  && log_of v6 | grep -E -- '-X PUT .*/variables/EXISTING.*token=set input=present' >/dev/null && ! leaked v6 "$SECRET" >/dev/null && ! leaked v6 s3cr3t >/dev/null; then
  pass "V6 existing key -> PUT under the settings token; neither the new nor the old value leaks"
else fail "V6" "rc=$(rc_of v6) out=$(out_of v6) log=$(log_of v6 | tr '\n' ';')"; fi

run_case v7 variable $TOK "SILKOPS_VAR_VALUE=$SECRET" -- --project "$PROJECT" set --key NEWKEY
if [ "$(rc_of v7)" = 0 ] && body_of v7 1 | jq -e --arg v "$SECRET" '.body.value == $v and .body.masked == false' >/dev/null && ! leaked v7 "$SECRET" >/dev/null; then
  pass "V7 value from SILKOPS_VAR_VALUE env reaches the body and nothing else"
else fail "V7" "rc=$(rc_of v7) out=$(out_of v7) err=$(err_of v7 | tail -1)"; fi

run_case v8 variable -- --project "$PROJECT" set --key NEWKEY --value-file "$VF"
if [ "$(rc_of v8)" = 3 ] && [ "$(writes_of v8)" = 0 ]; then pass "V8 set without SILKOPS_SETTINGS_TOKEN exits 3"; else fail "V8" "rc=$(rc_of v8)"; fi

run_case v9 variable $TOK -- --project "$PROJECT" set --key NEWKEY
if [ "$(rc_of v9)" = 2 ] && [ "$(calls_of v9)" = 0 ]; then pass "V9 set with neither --value-file nor SILKOPS_VAR_VALUE exits 2"; else fail "V9" "rc=$(rc_of v9)"; fi

run_case v10 variable $TOK -- --project "$PROJECT" set --key NEWKEY --value-file "$VF" --masked --dry-run
if [ "$(rc_of v10)" = 0 ] && out_of v10 | jq -e '.ok == true and .dry_run == true and .action == "created" and .proposed.masked == true and (.proposed | has("value") | not)' >/dev/null && [ "$(writes_of v10)" = 0 ] && ! leaked v10 "$SECRET" >/dev/null; then
  pass "V10 dry-run shows proposed flags (never the value) and writes nothing"
else fail "V10" "rc=$(rc_of v10) out=$(out_of v10)"; fi

# V11: rotating an existing masked+protected variable with no flags must keep both flags
run_case v11 variable $TOK -- --project "$PROJECT" set --key EXISTING --value-file "$VF"
if [ "$(rc_of v11)" = 0 ] && out_of v11 | jq -e '.ok == true and .action == "updated"' >/dev/null && [ "$(writes_of v11)" = 1 ] \
  && body_of v11 1 | jq -e '.method == "PUT" and .body.key == "EXISTING" and .body.masked == true and .body.protected == true' >/dev/null && ! leaked v11 "$SECRET" >/dev/null; then
  pass "V11 set on an existing masked+protected variable without flags -> PUT body inherits masked:true protected:true"
else fail "V11" "rc=$(rc_of v11) out=$(out_of v11) body=$(body_of v11 1 2>/dev/null | jq -c 'del(.body.value)')"; fi

# V12: unmasking an existing masked variable is refused without --allow-unmask
run_case v12 variable $TOK -- --project "$PROJECT" set --key EXISTING --value-file "$VF" --unmasked
if [ "$(rc_of v12)" = 7 ] && out_of v12 | jq -e '.ok == false and .error == "unmask_refused" and .key == "EXISTING" and .proposed.masked == false and (.current | has("value") | not)' >/dev/null && [ "$(writes_of v12)" = 0 ] && ! leaked v12 s3cr3t >/dev/null; then
  pass "V12 --unmasked on a masked variable -> exit 7 unmask_refused, zero writes, no value leaked"
else fail "V12" "rc=$(rc_of v12) out=$(out_of v12) writes=$(writes_of v12)"; fi
run_case v12b variable $TOK -- --project "$PROJECT" set --key EXISTING --value-file "$VF" --unprotected
if [ "$(rc_of v12b)" = 7 ] && out_of v12b | jq -e '.error == "unprotect_refused"' >/dev/null && [ "$(writes_of v12b)" = 0 ]; then
  pass "V12b --unprotected on a protected variable -> exit 7 unprotect_refused, zero writes"
else fail "V12b" "rc=$(rc_of v12b) out=$(out_of v12b)"; fi

# V13: --allow-unmask lets the downgrade through; protected still inherited
run_case v13 variable $TOK -- --project "$PROJECT" set --key EXISTING --value-file "$VF" --unmasked --allow-unmask
if [ "$(rc_of v13)" = 0 ] && [ "$(writes_of v13)" = 1 ] && body_of v13 1 | jq -e '.body.masked == false and .body.protected == true' >/dev/null; then
  pass "V13 --unmasked --allow-unmask -> PUT masked:false with protected:true inherited"
else fail "V13" "rc=$(rc_of v13) out=$(out_of v13) body=$(body_of v13 1 2>/dev/null | jq -c 'del(.body.value)')"; fi

# V14: dry-run on an existing variable shows current vs proposed flags (inherited) and writes nothing
run_case v14 variable $TOK -- --project "$PROJECT" set --key EXISTING --value-file "$VF" --dry-run
if [ "$(rc_of v14)" = 0 ] && out_of v14 | jq -e '.dry_run == true and .action == "updated" and .flags.current == {masked: true, protected: true} and .flags.proposed == {masked: true, protected: true}' >/dev/null && [ "$(writes_of v14)" = 0 ] && ! leaked v14 s3cr3t >/dev/null; then
  pass "V14 dry-run on an existing variable reports current vs proposed flags, nothing written"
else fail "V14" "rc=$(rc_of v14) out=$(out_of v14)"; fi

echo "test-variable: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
