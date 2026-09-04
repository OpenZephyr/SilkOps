#!/usr/bin/env bash
# Tier 1 tests for ops/registry.sh: glab stub for reads, curl stub (refuses tokens on argv) for retag.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
PASS=0; FAIL=0
PROJECT="void-realm-solutions/silkops-harness-eval"
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }
# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
export PATH="$STUB_DIR:$PATH"
[ "$(command -v glab)" = "$STUB_DIR/glab" ] || { echo "glab stub is not first on PATH" >&2; exit 1; }
# run_case <name> <scenario> <env KEY=VAL ...> -- <args...>   (scenario: stub dir name or absolute path)
run_case() {
  local name="$1" scenario="$2"; shift 2
  case "$scenario" in /*) ;; *) scenario="$STUB_DIR/$scenario" ;; esac
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  local d="$SCRATCH/$name"; mkdir -p "$d"
  env -u GITLAB_TOKEN -u SILKOPS_SETTINGS_TOKEN -u SILKOPS_CI_TOKEN -u CI -u SILKOPS_VAR_VALUE \
    GLAB_STUB_SCENARIO="$scenario" GLAB_STUB_LOG="$d/glab.log" GLAB_STUB_BODY_DIR="$d/bodies" \
    CURL_STUB_STATE="$d/state" CURL_STUB_LOG="$d/curl.log" "${envs[@]}" \
    bash "$SCRIPT" "$@" >"$d/out.log" 2>"$d/err.log"
  echo $? >"$d/rc"
}
rc_of()  { cat "$SCRATCH/$1/rc"; }
out_of() { cat "$SCRATCH/$1/out.log"; }
err_of() { cat "$SCRATCH/$1/err.log"; }
log_of() { cat "$SCRATCH/$1/glab.log" 2>/dev/null; }
calls_of() { log_of "$1" | wc -l | tr -d ' '; }
writes_of() { log_of "$1" | grep -cE -- '-X (POST|PUT|DELETE)'; }
body_of() { cat "$SCRATCH/$1/bodies/$2.json"; }
SCRIPT="$ROOT/ops/registry.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-registry.XXXXXX")"
CURL_DIR="$ROOT/tests/fixtures/curl-stub"
export PATH="$CURL_DIR:$PATH"
[ "$(command -v curl)" = "$CURL_DIR/curl" ] || { echo "curl stub is not first on PATH" >&2; exit 1; }
TOK=SILKOPS_SETTINGS_TOKEN=glpat-MAINTTOKEN0000000000
curl_of() { cat "$SCRATCH/$1/curl.log" 2>/dev/null; }
# every case starts from a fresh copy of the canned registry (tags v1, v2)
seed() { mkdir -p "$SCRATCH/$1"; cp -R "$ROOT/tests/fixtures/registry" "$SCRATCH/$1/state"; }
mtype() { cat "$SCRATCH/$1/state/manifests/$2.json.type"; }

seed r1; run_case r1 registry $TOK -- retag harness v2 v3
if [ "$(rc_of r1)" = 2 ] && err_of r1 | grep -- '--project' >/dev/null && [ "$(calls_of r1)" = 0 ] && [ -z "$(curl_of r1)" ]; then
  pass "R1 missing --project exits 2 before any glab or curl call"
else fail "R1" "rc=$(rc_of r1) glab=$(calls_of r1) curl=$(curl_of r1 | wc -l)"; fi

seed r2; run_case r2 registry $TOK -- --project "$PROJECT" retag harness v2 v3
if [ "$(rc_of r2)" = 0 ] && out_of r2 | jq -e '.ok == true and .action == "retagged" and .source_digest == .target_digest and (.source_digest | startswith("sha256:")) and .content_type == "application/vnd.oci.image.index.v1+json"' >/dev/null \
  && [ -f "$SCRATCH/r2/state/manifests/v3.json" ] && [ "$(mtype r2 v3)" = "$(mtype r2 v2)" ] \
  && ! curl_of r2 | grep '/blobs/' >/dev/null && curl_of r2 | grep -E '^curl: PUT .*/manifests/v3 auth=bearer .*ctype=application/vnd.oci.image.index.v1\+json' >/dev/null \
  && curl_of r2 | grep -E '^curl: GET https://gitlab.com/jwt/auth\?service=container_registry&scope=repository:void-realm-solutions/silkops-harness-eval/harness:pull,push auth=basic' >/dev/null \
  && cmp -s "$SCRATCH/r2/state/manifests/v2.json" "$SCRATCH/r2/state/manifests/v3.json"; then
  pass "R2 retag onto a fresh tag: digests equal, zero blob uploads, PUT content-type == GET content-type"
else fail "R2" "rc=$(rc_of r2) out=$(out_of r2) err=$(err_of r2 | tail -1) curl=$(curl_of r2 | tr '\n' ';')"; fi

seed r3; run_case r3 registry $TOK -- --project "$PROJECT" retag harness v2 v1
if [ "$(rc_of r3)" = 7 ] && out_of r3 | jq -e '.ok == false and .error == "tag_exists"' >/dev/null && ! curl_of r3 | grep '^curl: PUT' >/dev/null; then
  pass "R3 retag onto an existing tag exits 7 and never PUTs"
else fail "R3" "rc=$(rc_of r3) out=$(out_of r3) curl=$(curl_of r3 | tr '\n' ';')"; fi

seed r4; run_case r4 registry $TOK 'CURL_STUB_FAIL_URL_GLOB=*/manifests/v3' -- --project "$PROJECT" retag harness v2 v3
if [ "$(rc_of r4)" = 1 ] && out_of r4 | jq -e '.ok == false and .error == "registry_error"' >/dev/null && ! curl_of r4 | grep '^curl: PUT' >/dev/null && ! [ -f "$SCRATCH/r4/state/manifests/v3.json" ]; then
  pass "R4 network error on the existence check exits 1, never read as absent, nothing written"
else fail "R4" "rc=$(rc_of r4) out=$(out_of r4) curl=$(curl_of r4 | tr '\n' ';')"; fi

seed r5; run_case r5 registry -- --project "$PROJECT" retag harness v2 v3
if [ "$(rc_of r5)" = 3 ] && [ -z "$(curl_of r5)" ]; then
  pass "R5 retag without SILKOPS_SETTINGS_TOKEN exits 3 before any curl call"
else fail "R5" "rc=$(rc_of r5) curl=$(curl_of r5 | wc -l)"; fi

seed r6; run_case r6 registry -- --project "$PROJECT" tags harness
if [ "$(rc_of r6)" = 0 ] && out_of r6 | jq -e '.ok == true and .repository_id == 55 and (.tags | map(.name)) == ["v1","v2"]' >/dev/null && ! log_of r6 | grep 'token=set' >/dev/null && [ -z "$(curl_of r6)" ]; then
  pass "R6 tags lists via glab under the session identity, no curl"
else fail "R6" "rc=$(rc_of r6) out=$(out_of r6) log=$(log_of r6 | tr '\n' ';')"; fi

seed r7; run_case r7 registry -- --project "$PROJECT" digest harness v2
if [ "$(rc_of r7)" = 0 ] && out_of r7 | jq -e '.ok == true and .digest == "sha256:3333333333333333333333333333333333333333333333333333333333333333" and .tag == "v2"' >/dev/null; then
  pass "R7 digest resolves a tag via glab"
else fail "R7" "rc=$(rc_of r7) out=$(out_of r7)"; fi
seed r7b; run_case r7b registry -- --project "$PROJECT" digest harness nope
if [ "$(rc_of r7b)" = 5 ]; then pass "R7b digest of a missing tag exits 5"; else fail "R7b" "rc=$(rc_of r7b) out=$(out_of r7b)"; fi

if [ -n "$(curl_of r2)" ] && ! grep -E 'glpat-|eyJ|Authorization|Bearer' "$SCRATCH/r2/curl.log" "$SCRATCH/r2/glab.log" "$SCRATCH/r2/out.log" "$SCRATCH/r2/err.log" >/dev/null 2>&1 \
  && ! grep -E 'glpat-|eyJ' "$SCRATCH/r3/err.log" "$SCRATCH/r4/err.log" >/dev/null; then
  pass "R8 curl argv, logs, stdout and stderr never carry a token, JWT or Authorization header"
else fail "R8" "$(grep -E 'glpat-|eyJ|Authorization|Bearer' "$SCRATCH"/r2/*.log | head -3)"; fi

seed r9; run_case r9 registry $TOK -- --project "$PROJECT" retag harness v2 v3 --dry-run
if [ "$(rc_of r9)" = 0 ] && out_of r9 | jq -e '.ok == true and .dry_run == true and .current.target == null and (.current.source.digest | startswith("sha256:")) and .proposed.tag == "v3"' >/dev/null \
  && ! curl_of r9 | grep '^curl: PUT' >/dev/null && ! [ -f "$SCRATCH/r9/state/manifests/v3.json" ]; then
  pass "R9 retag --dry-run shows current source/target and proposed tag, writes nothing"
else fail "R9" "rc=$(rc_of r9) out=$(out_of r9) curl=$(curl_of r9 | tr '\n' ';')"; fi

seed r10; run_case r10 registry $TOK -- --project "$PROJECT" retag harness v9 v3
if [ "$(rc_of r10)" = 5 ] && ! curl_of r10 | grep '^curl: PUT' >/dev/null; then pass "R10 retag from a missing source tag exits 5"; else fail "R10" "rc=$(rc_of r10) out=$(out_of r10)"; fi

echo "test-registry: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
