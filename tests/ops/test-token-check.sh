#!/usr/bin/env bash
# Tier 1 tests for ops/token-check.sh against the glab stub (no network).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/ops/token-check.sh"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-token-check.XXXXXX")"
PASS=0; FAIL=0
PROJECT="void-realm-solutions/silkops-harness-eval"

pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }
# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

export PATH="$STUB_DIR:$PATH"
[ "$(command -v glab)" = "$STUB_DIR/glab" ] || { echo "glab stub is not first on PATH" >&2; exit 1; }

# run_check <name> <scenario> <env KEY=VAL ...> -- <args...>
run_check() {
  local name="$1" scenario="$2"; shift 2
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  local d="$SCRATCH/$name"; mkdir -p "$d"
  env -u GITLAB_TOKEN -u SILKOPS_SETTINGS_TOKEN -u SILKOPS_CI_TOKEN -u CI \
    GLAB_STUB_SCENARIO="$STUB_DIR/$scenario" GLAB_STUB_LOG="$d/glab.log" "${envs[@]}" \
    bash "$SCRIPT" "$@" >"$d/out.log" 2>"$d/err.log"
  echo $? >"$d/rc"
}
rc_of()  { cat "$SCRATCH/$1/rc"; }
out_of() { cat "$SCRATCH/$1/out.log"; }
err_of() { cat "$SCRATCH/$1/err.log"; }
log_of() { cat "$SCRATCH/$1/glab.log" 2>/dev/null; }

# --- T1: Developer (30) with --for settings -> exit 4 "needs Maintainer on <project>"
run_check t1 developer SILKOPS_SETTINGS_TOKEN=glpat-DEVTOKEN000000000000 -- --project "$PROJECT" --for settings
if [ "$(rc_of t1)" = 4 ] && err_of t1 | grep "needs Maintainer on $PROJECT" >/dev/null \
  && out_of t1 | jq -e ".ok == false and .error != null and (.message | contains(\"needs Maintainer on $PROJECT\"))" >/dev/null \
  && out_of t1 | jq -e '.role == "Developer" and .access_level == 30' >/dev/null; then
  pass "T1 Developer token for settings exits 4: needs Maintainer on <project>"
else
  fail "T1" "rc=$(rc_of t1) err=$(err_of t1 | tail -1) out=$(out_of t1)"
fi

# --- T2: Maintainer (40) with --for settings -> exit 0, ok:true, role Maintainer, scopes/expiry present
run_check t2 maintainer SILKOPS_SETTINGS_TOKEN=glpat-MAINTTOKEN0000000000 -- --project "$PROJECT" --for settings
if [ "$(rc_of t2)" = 0 ] && [ "$(out_of t2 | wc -l | tr -d ' ')" = 1 ] \
  && out_of t2 | jq -e '.ok == true and .role == "Maintainer" and .access_level == 40 and .for == "settings"' >/dev/null \
  && out_of t2 | jq -e '.identity.username == "aqua" and .identity.bot == false and .identity.id == 42' >/dev/null \
  && out_of t2 | jq -e '.token.scopes == ["api"] and .token.expires_at == "2026-12-31"' >/dev/null \
  && out_of t2 | jq -e '.project.path == "void-realm-solutions/silkops-harness-eval" and .project.id == 7001' >/dev/null; then
  pass "T2 Maintainer token for settings exits 0 with role Maintainer, identity, scopes, expiry"
else
  fail "T2" "rc=$(rc_of t2) out=$(out_of t2) err=$(err_of t2 | tail -1)"
fi

# --- T3: no token-shaped string in glab argv or in the output; settings calls carried the token via env
if ! grep 'glpat-' "$SCRATCH/t2/glab.log" >/dev/null && ! grep 'glpat-' "$SCRATCH/t2/out.log" >/dev/null \
  && ! grep 'glpat-' "$SCRATCH/t2/err.log" >/dev/null \
  && [ "$(log_of t2 | wc -l | tr -d ' ')" -gt 0 ] && ! log_of t2 | grep -v 'token=set' >/dev/null; then
  pass "T3 token never appears in argv/stdout/stderr; every settings call ran with GITLAB_TOKEN set"
else
  fail "T3" "log=$(log_of t2 | tr '\n' ';') out=$(out_of t2)"
fi

# --- T4: --for settings with SILKOPS_SETTINGS_TOKEN unset -> exit 3, zero glab calls
run_check t4 maintainer -- --project "$PROJECT" --for settings
if [ "$(rc_of t4)" = 3 ] && err_of t4 | grep SILKOPS_SETTINGS_TOKEN >/dev/null \
  && [ "$(log_of t4 | wc -l | tr -d ' ')" = 0 ] && out_of t4 | jq -e '.ok == false' >/dev/null; then
  pass "T4 missing SILKOPS_SETTINGS_TOKEN exits 3 before any glab call"
else
  fail "T4" "rc=$(rc_of t4) calls=$(log_of t4 | wc -l) err=$(err_of t4 | tail -1)"
fi

# --- T5: session identity (default --for) reports protected-branch rights informationally, never fails
run_check t5 developer -- --project "$PROJECT"
run_check t5m maintainer -- --project "$PROJECT"
if [ "$(rc_of t5)" = 0 ] && out_of t5 | jq -e '.ok == true and .for == "session" and .role == "Developer" and .can_merge_protected == false and .can_push_protected == false' >/dev/null \
  && [ "$(rc_of t5m)" = 0 ] && out_of t5m | jq -e '.ok == true and .can_merge_protected == true and .can_push_protected == false' >/dev/null \
  && ! log_of t5 | grep 'token=set' >/dev/null; then
  pass "T5 session check reports can_merge/can_push on protected branches (informational) under the default identity"
else
  fail "T5" "dev rc=$(rc_of t5) out=$(out_of t5) | maint rc=$(rc_of t5m) out=$(out_of t5m) log=$(log_of t5 | tr '\n' ';')"
fi

# --- T6: PAT self endpoint 404 (developer scenario has none) -> token null, still ok
if out_of t5 | jq -e '.token == null' >/dev/null; then
  pass "T6 unavailable personal_access_tokens/self yields token:null"
else
  fail "T6" "out=$(out_of t5)"
fi

# --- T7: protected_branches 403 -> null (scenario without the fixture)
mkdir -p "$SCRATCH/nopb"; cp "$STUB_DIR/maintainer"/user.json "$STUB_DIR/maintainer"/project.json "$STUB_DIR/maintainer"/member.json "$SCRATCH/nopb/"
GLAB_STUB_SCENARIO="$SCRATCH/nopb" GLAB_STUB_LOG="$SCRATCH/nopb/glab.log" env -u GITLAB_TOKEN bash "$SCRIPT" --project "$PROJECT" >"$SCRATCH/nopb/out.log" 2>"$SCRATCH/nopb/err.log"; echo $? >"$SCRATCH/nopb/rc"
if [ "$(rc_of nopb)" = 0 ] && out_of nopb | jq -e '.ok == true and .can_merge_protected == null and .can_push_protected == null' >/dev/null; then
  pass "T7 protected_branches forbidden -> can_merge/can_push null, exit 0"
else
  fail "T7" "rc=$(rc_of nopb) out=$(out_of nopb) err=$(err_of nopb | tail -1)"
fi

# --- T8: usage errors -> exit 2
run_check t8a maintainer -- --for settings
run_check t8b maintainer -- --project "$PROJECT" --for bogus
if [ "$(rc_of t8a)" = 2 ] && err_of t8a | grep -- '--project' >/dev/null && out_of t8a | jq -e '.ok == false' >/dev/null \
  && [ "$(rc_of t8b)" = 2 ] && [ "$(log_of t8a | wc -l | tr -d ' ')" = 0 ]; then
  pass "T8 missing --project / bad --for exit 2 without calling glab"
else
  fail "T8" "a rc=$(rc_of t8a) err=$(err_of t8a | tail -1); b rc=$(rc_of t8b) err=$(err_of t8b | tail -1)"
fi

# --- T9: project not found -> exit 5
mkdir -p "$SCRATCH/noproj"; cp "$STUB_DIR/maintainer/user.json" "$SCRATCH/noproj/"
GLAB_STUB_SCENARIO="$SCRATCH/noproj" GLAB_STUB_LOG="$SCRATCH/noproj/glab.log" env -u GITLAB_TOKEN bash "$SCRIPT" --project "$PROJECT" >"$SCRATCH/noproj/out.log" 2>"$SCRATCH/noproj/err.log"; echo $? >"$SCRATCH/noproj/rc"
if [ "$(rc_of noproj)" = 5 ] && out_of noproj | jq -e '.ok == false and .error == "not_found"' >/dev/null \
  && ! grep 'glpat-' "$SCRATCH/noproj/err.log" >/dev/null; then
  pass "T9 unknown project exits 5 not_found (stub's token-shaped stderr redacted)"
else
  fail "T9" "rc=$(rc_of noproj) out=$(out_of noproj) err=$(err_of noproj | tail -2 | tr '\n' ' ')"
fi

# --- T10: --for ci in CI without SILKOPS_CI_TOKEN -> exit 3, no glab call
run_check t10 maintainer CI=true -- --project "$PROJECT" --for ci
if [ "$(rc_of t10)" = 3 ] && err_of t10 | grep SILKOPS_CI_TOKEN >/dev/null && [ "$(log_of t10 | wc -l | tr -d ' ')" = 0 ]; then
  pass "T10 --for ci without SILKOPS_CI_TOKEN exits 3 before any glab call"
else
  fail "T10" "rc=$(rc_of t10) err=$(err_of t10 | tail -1) calls=$(log_of t10 | wc -l)"
fi

# --- v0.2 U11 (#27, #35): operator identity and group, --expect-role
run_check t11 maintainer SILKOPS_OPERATOR=aqua SILKOPS_OPERATOR_GROUP=void-realm-solutions -- --project "$PROJECT" --expect-role Developer
if [ "$(rc_of t11)" = 0 ] && out_of t11 | jq -e '.operator.username == "aqua" and .operator.id == 42 and .operator.exists == true
      and .operator_group == "void-realm-solutions" and .in_operator_group == true' >/dev/null; then
  pass "T11 operator resolved to a real user, operator_group known, project is inside it, expected role met"
else fail "T11" "rc=$(rc_of t11) out=$(out_of t11)"; fi
run_check t11b maintainer SILKOPS_OPERATOR=ghost SILKOPS_OPERATOR_GROUP=other-group -- --project "$PROJECT" --expect-role Owner
if [ "$(rc_of t11b)" = 4 ] && out_of t11b | jq -e '.ok == false and .error == "insufficient_role" and .operator.exists == false and .in_operator_group == false' >/dev/null; then
  pass "T11b a dead operator name is reported exists:false, a project outside the group is flagged, --expect-role Owner exits 4"
else fail "T11b" "rc=$(rc_of t11b) out=$(out_of t11b)"; fi

echo "test-token-check: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
