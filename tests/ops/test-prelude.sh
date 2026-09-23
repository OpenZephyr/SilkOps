#!/usr/bin/env bash
# Tier 1 tests for ops/lib/prelude.sh, ops/lib/token.sh, ops/lib/glab.sh.
# Offline: `glab` is a stub on PATH (tests/fixtures/glab-stub) that logs argv.
# Each test prints PASS/FAIL; exits nonzero if any test fails.
# shellcheck disable=SC2016  # snippets are sourced by a child bash; $VARS expand there on purpose
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PRELUDE="$ROOT/ops/lib/prelude.sh"
TOKEN_LIB="$ROOT/ops/lib/token.sh"
GLAB_LIB="$ROOT/ops/lib/glab.sh"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-prelude.XXXXXX")"
PASS=0; FAIL=0

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }
# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

export PATH="$STUB_DIR:$PATH"
export GLAB_STUB_SCENARIO="$STUB_DIR/maintainer"
# Sanity: the stub, not a real glab, is first on PATH; tests touch no network.
[ "$(command -v glab)" = "$STUB_DIR/glab" ] || { echo "glab stub is not first on PATH" >&2; exit 1; }

# run_snippet <name> <env KEY=VAL ...> -- <bash source>: runs the snippet in a
# fresh bash with the libs available; captures out/err/rc under $SCRATCH/<name>.
run_snippet() {
  local name="$1"; shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  local d="$SCRATCH/$name"; mkdir -p "$d"
  export GLAB_STUB_LOG="$d/glab.log"; : >"$GLAB_STUB_LOG"
  env "${envs[@]}" PRELUDE="$PRELUDE" TOKEN_LIB="$TOKEN_LIB" GLAB_LIB="$GLAB_LIB" \
    bash -c "$1" >"$d/out.log" 2>"$d/err.log"
  echo $? >"$d/rc"
}
rc_of()  { cat "$SCRATCH/$1/rc"; }
out_of() { cat "$SCRATCH/$1/out.log"; }
err_of() { cat "$SCRATCH/$1/err.log"; }
glab_calls() { wc -l <"$SCRATCH/$1/glab.log" | tr -d ' '; }

# --- T1 (AE6): CI=true, SILKOPS_CI_TOKEN unset -> exit 3 naming the variable, zero glab calls
run_snippet t1 CI=true -- 'unset SILKOPS_CI_TOKEN; . "$PRELUDE"; . "$TOKEN_LIB"; . "$GLAB_LIB"; glab_ro api user'
if [ "$(rc_of t1)" = 3 ] && err_of t1 | grep SILKOPS_CI_TOKEN >/dev/null \
  && [ "$(glab_calls t1)" = 0 ] \
  && out_of t1 | jq -e '.ok == false and .error != null and .message != null' >/dev/null; then
  pass "T1 require_ci_token exits 3 naming SILKOPS_CI_TOKEN before any glab call"
else
  fail "T1" "rc=$(rc_of t1) calls=$(glab_calls t1) err=$(err_of t1 | tail -1) out=$(out_of t1)"
fi

# --- T2: CI=true, SILKOPS_CI_TOKEN set -> exported as GITLAB_TOKEN for glab (stub logs token=set)
run_snippet t2 CI=true SILKOPS_CI_TOKEN=glpat-CITOKEN00000000000000 -- '. "$PRELUDE"; . "$TOKEN_LIB"; . "$GLAB_LIB"; glab_ro api user'
if [ "$(rc_of t2)" = 0 ] && grep 'token=set' "$SCRATCH/t2/glab.log" >/dev/null \
  && ! grep 'glpat-' "$SCRATCH/t2/glab.log" >/dev/null; then
  pass "T2 CI token is routed to glab via GITLAB_TOKEN, never argv"
else
  fail "T2" "rc=$(rc_of t2) log=$(cat "$SCRATCH/t2/glab.log")"
fi

# --- T3: redaction, one fixture line per shape
T3_OK=1; T3_MSG=""
while IFS=$'\t' read -r shape line secret; do
  [ -n "$shape" ] || continue
  got="$(printf '%s\n' "$line" | bash -c '. "$1"; redact' _ "$PRELUDE" 2>/dev/null)"
  case "$got" in
    *"$secret"*) T3_OK=0; T3_MSG="$T3_MSG [$shape leaked: $got]" ;;
    *"<REDACTED>"*) : ;;
    *) T3_OK=0; T3_MSG="$T3_MSG [$shape no marker: $got]" ;;
  esac
done <"$ROOT/tests/fixtures/redaction/cases.tsv"
if [ "$T3_OK" = 1 ]; then
  pass "T3 redact masks every token shape (glpat/glcbt/gldt/glrt, oauth2@, headers, JWT, Bearer JWT)"
else
  fail "T3" "$T3_MSG"
fi

# --- T4: a line without secrets passes through byte-identical
CLEAN="$ROOT/tests/fixtures/redaction/clean.txt"
# shellcheck disable=SC2094  # $CLEAN is only read (twice), never written
if bash -c '. "$1"; redact' _ "$PRELUDE" <"$CLEAN" 2>/dev/null | cmp -s - "$CLEAN"; then
  pass "T4 redact leaves a secret-free line byte-identical"
else
  fail "T4" "output differed: $(bash -c '. "$1"; redact' _ "$PRELUDE" <"$CLEAN" 2>&1)"
fi

# --- T5: with_settings_token scopes GITLAB_TOKEN to the wrapped command only
run_snippet t5 SILKOPS_SETTINGS_TOKEN=glpat-SETTINGS000000000000 -- '
  unset GITLAB_TOKEN
  . "$PRELUDE"; . "$TOKEN_LIB"
  with_settings_token sh -c "echo inner=\${GITLAB_TOKEN:+set}"
  echo "after=${GITLAB_TOKEN:-unset}"'
if [ "$(rc_of t5)" = 0 ] && grep -x 'inner=set' "$SCRATCH/t5/out.log" >/dev/null \
  && grep -x 'after=unset' "$SCRATCH/t5/out.log" >/dev/null; then
  pass "T5 with_settings_token sets GITLAB_TOKEN for the command only; caller env unchanged"
else
  fail "T5" "rc=$(rc_of t5) out=$(out_of t5 | tr '\n' ' ') err=$(err_of t5 | tail -1)"
fi

# --- T5b: a pre-existing caller GITLAB_TOKEN is restored after the call
run_snippet t5b SILKOPS_SETTINGS_TOKEN=glpat-SETTINGS000000000000 GITLAB_TOKEN=caller-value -- '
  . "$PRELUDE"; . "$TOKEN_LIB"
  with_settings_token sh -c "echo inner=\$GITLAB_TOKEN"
  echo "after=$GITLAB_TOKEN"'
if grep -x 'inner=glpat-SETTINGS000000000000' "$SCRATCH/t5b/out.log" >/dev/null \
  && grep -x 'after=caller-value' "$SCRATCH/t5b/out.log" >/dev/null; then
  pass "T5b with_settings_token restores the caller's prior GITLAB_TOKEN"
else
  fail "T5b" "out=$(out_of t5b | tr '\n' ' ')"
fi

# --- T6: SILKOPS_SETTINGS_TOKEN empty -> exit 3, no glab call
run_snippet t6 SILKOPS_SETTINGS_TOKEN= -- '. "$PRELUDE"; . "$TOKEN_LIB"; . "$GLAB_LIB"; glab_settings api user'
if [ "$(rc_of t6)" = 3 ] && err_of t6 | grep SILKOPS_SETTINGS_TOKEN >/dev/null \
  && [ "$(glab_calls t6)" = 0 ] && out_of t6 | jq -e '.ok == false' >/dev/null; then
  pass "T6 empty SILKOPS_SETTINGS_TOKEN exits 3 with no glab call"
else
  fail "T6" "rc=$(rc_of t6) calls=$(glab_calls t6) err=$(err_of t6 | tail -1)"
fi

# --- T7: wrapped command stderr is redacted
run_snippet t7 SILKOPS_SETTINGS_TOKEN=glpat-SETTINGS000000000000 -- '
  . "$PRELUDE"; . "$TOKEN_LIB"
  with_settings_token sh -c "echo \"leak PRIVATE-TOKEN: \$GITLAB_TOKEN and glpat-other111111111111\" >&2"'
if ! grep 'glpat-' "$SCRATCH/t7/err.log" >/dev/null && grep '<REDACTED>' "$SCRATCH/t7/err.log" >/dev/null; then
  pass "T7 with_settings_token redacts the wrapped command's stderr"
else
  fail "T7" "err=$(err_of t7)"
fi

# --- T8: shell tracing refused (bash -x, and set -x before sourcing)
run_snippet t8a -- 'true' # placeholder dir
( bash -x "$PRELUDE" ) >"$SCRATCH/t8a/out.log" 2>"$SCRATCH/t8a/err.log"; echo $? >"$SCRATCH/t8a/rc"
run_snippet t8b -- 'set -x; . "$PRELUDE"; echo reached'
if [ "$(rc_of t8a)" != 0 ] && err_of t8a | grep -i 'trac' >/dev/null \
  && [ "$(rc_of t8b)" != 0 ] && err_of t8b | grep -i 'trac' >/dev/null \
  && ! grep -x reached "$SCRATCH/t8b/out.log" >/dev/null; then
  pass "T8 prelude refuses shell tracing (bash -x and set -x) with a named error"
else
  fail "T8" "rc_a=$(rc_of t8a) rc_b=$(rc_of t8b) err_b=$(err_of t8b | tail -1)"
fi

# --- T9: result contract — success has ok:true; fail has ok:false+error+message and the code
run_snippet t9a -- '. "$PRELUDE"; result "$(jq -n "{id: 1, web_url: \"https://gitlab.com/x\"}")"'
run_snippet t9b -- '. "$PRELUDE"; fail "$EX_REFUSED" protected_write "refusing to push main" "$(jq -n "{branch: \"main\"}")"'
run_snippet t9c -- '. "$PRELUDE"; result "not json at all"'
if [ "$(rc_of t9a)" = 0 ] && [ "$(out_of t9a | wc -l | tr -d ' ')" = 1 ] \
  && out_of t9a | jq -e '.ok == true and .id == 1' >/dev/null \
  && [ "$(rc_of t9b)" = 7 ] \
  && out_of t9b | jq -e '.ok == false and .error == "protected_write" and .message == "refusing to push main" and .branch == "main"' >/dev/null \
  && err_of t9b | grep 'refusing to push main' >/dev/null \
  && [ "$(rc_of t9c)" != 0 ] && [ -z "$(out_of t9c)" ]; then
  pass "T9 result/fail honour the JSON contract (ok, error, message, exit code); invalid JSON is rejected"
else
  fail "T9" "a: rc=$(rc_of t9a) out=$(out_of t9a) | b: rc=$(rc_of t9b) out=$(out_of t9b) | c: rc=$(rc_of t9c) out=$(out_of t9c)"
fi

# --- T10: exit-code constants match the contract
run_snippet t10 -- '. "$PRELUDE"; echo "$EX_OK $EX_OTHER $EX_USAGE $EX_NO_TOKEN $EX_ROLE $EX_NOT_FOUND $EX_RETRY_UNSAFE $EX_REFUSED"'
if [ "$(out_of t10)" = "0 1 2 3 4 5 6 7" ]; then
  pass "T10 exit-code constants are 0/1/2/3/4/5/6/7 per contract"
else
  fail "T10" "got '$(out_of t10)'"
fi

# --- T11: a provider with no verb file -> exit 2 "provider not implemented" when the seam loads
run_snippet t11 SILKOPS_PROVIDER=bitbucket -- '. "$PRELUDE"; . "$TOKEN_LIB"; . "$GLAB_LIB"; . "$(dirname "$PRELUDE")/provider.sh"; echo reached'
if [ "$(rc_of t11)" = 2 ] && err_of t11 | grep 'provider not implemented' >/dev/null \
  && ! grep -x reached "$SCRATCH/t11/out.log" >/dev/null \
  && out_of t11 | jq -e '.ok == false' >/dev/null; then
  pass "T11 SILKOPS_PROVIDER=bitbucket fails usage (2) at the provider seam: provider not implemented"
else
  fail "T11" "rc=$(rc_of t11) err=$(err_of t11 | tail -1)"
fi

# --- T12: require_project fails usage when no --project was supplied
run_snippet t12a -- '. "$PRELUDE"; PROJECT=""; require_project; echo reached'
run_snippet t12b -- '. "$PRELUDE"; PROJECT="g/p"; require_project; echo reached'
if [ "$(rc_of t12a)" = 2 ] && err_of t12a | grep -- '--project' >/dev/null \
  && [ "$(rc_of t12b)" = 0 ] && grep -x reached "$SCRATCH/t12b/out.log" >/dev/null; then
  pass "T12 require_project enforces an explicit --project"
else
  fail "T12" "a rc=$(rc_of t12a) err=$(err_of t12a | tail -1); b rc=$(rc_of t12b)"
fi

# --- T13: silkops_marker carries plugin version, plan, unit, run
VERSION="$(jq -r .version "$ROOT/.claude-plugin/plugin.json")"
run_snippet t13 -- '. "$PRELUDE"; silkops_marker 2026-09-02-2334-feat-silkops-harness-plan.md U3 run-abc'
if [ "$(out_of t13)" = "<!-- silkops: v=$VERSION plan=2026-09-02-2334-feat-silkops-harness-plan.md unit=U3 run=run-abc -->" ]; then
  pass "T13 silkops_marker renders the provenance comment"
else
  fail "T13" "got '$(out_of t13)'"
fi

# --- T14 (lint): no `grep -q` on piped output anywhere in ops/
if ! grep -rnE '\|[[:space:]]*grep[[:space:]]+(-[A-Za-z]*q|[^|]*[[:space:]]-q)' "$ROOT/ops" >/dev/null; then
  pass "T14 no 'grep -q' on piped output in ops/"
else
  fail "T14" "$(grep -rnE '\|[[:space:]]*grep[[:space:]]+(-[A-Za-z]*q|[^|]*[[:space:]]-q)' "$ROOT/ops")"
fi

# --- T15: shellcheck on ops/*.sh and ops/lib/*.sh (skipped if not installed)
# --- T16 (U1 v0.2): facts_paths lists repo, overlay (sorted), core — earlier wins downstream
mkdir -p "$SCRATCH/t16/repo/.silkops" "$SCRATCH/t16/ov"
T16="$(cd "$SCRATCH/t16" && pwd)"   # normalised: $TMPDIR may end in a slash
echo '{"facts":[]}' >"$T16/repo/.silkops/facts.json"
echo '{"facts":[]}' >"$T16/ov/b.json"; echo '{"facts":[]}' >"$T16/ov/a.json"
run_snippet t16 SILKOPS_FACTS_OVERLAY="$T16/ov" -- 'cd "'"$T16"'/repo"; . "$PRELUDE"; facts_paths'
run_snippet t16b SILKOPS_FACTS_OVERLAY="$T16/none" -- 'cd "'"$T16"'"; . "$PRELUDE"; facts_paths'
if [ "$(rc_of t16)" = 0 ] \
  && [ "$(out_of t16)" = "$(printf '%s\n%s\n%s\n%s' "$T16/repo/.silkops/facts.json" "$T16/ov/a.json" "$T16/ov/b.json" "$ROOT/facts/environment.json")" ] \
  && [ "$(out_of t16b)" = "$ROOT/facts/environment.json" ]; then
  pass "T16 facts_paths: repo .silkops/facts.json, overlay *.json sorted, core; core alone when nothing else exists"
else fail "T16" "rc=$(rc_of t16) out=$(out_of t16) out_b=$(out_of t16b) err=$(err_of t16)"; fi

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x --source-path=SCRIPTDIR "$ROOT"/ops/*.sh "$ROOT"/ops/lib/*.sh >"$SCRATCH/shellcheck.log" 2>&1; then
    pass "T15 shellcheck clean on ops/*.sh and ops/lib/*.sh"
  else
    fail "T15" "$(head -20 "$SCRATCH/shellcheck.log")"
  fi
else
  echo "SKIP T15 shellcheck not installed"
fi

echo "test-prelude: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
