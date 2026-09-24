#!/usr/bin/env bash
# shellcheck disable=SC2034
# Tier 1 (v0.3 U4): the settings scripts on GitHub. Variables and secrets go through gh with the
# value on stdin; a schedule is a workflow file to ship; the allow-list is not a concept; the
# registry is GHCR over the same v2 API; branch protection is read for token-check.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
GH="$ROOT/tests/fixtures/gh-stub"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/ops/lib/harness.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-settings-gh.XXXXXX")"
CURL_DIR="$ROOT/tests/fixtures/curl-stub"; export PATH="$CURL_DIR:$PATH"
PROJECT="example/silkops-harness"
P=(--project "$PROJECT")
VAL="$SCRATCH/value.txt"; printf 'S3cretValue+long/enough\n' >"$VAL"

SCRIPT="$ROOT/ops/variable.sh"
run_case v1 "$GH/settings" SILKOPS_PROVIDER=github -- "${P[@]}" list
if [ "$(rc_of v1)" = 0 ] && out_of v1 | jq -e '.provider == "github" and (.variables | length) == 2
      and (.variables[] | select(.key == "NPM_TOKEN") | .masked == true and .kind == "secret")
      and (.variables[] | select(.key == "DEPLOY_ENV") | .masked == false and .kind == "variable")' >/dev/null \
  && ! out_of v1 | grep -q staging; then
  pass "GV1 github: list merges Actions variables and secret names as masked entries, values stripped"
else fail "GV1" "rc=$(rc_of v1) out=$(out_of v1)"; fi

run_case v2 "$GH/settings" SILKOPS_PROVIDER=github -- "${P[@]}" set --key NEW_SECRET --value-file "$VAL" --masked
if [ "$(rc_of v2)" = 0 ] && out_of v2 | jq -e '.action == "created" and .key == "NEW_SECRET" and .masked == true and .kind == "secret" and .protected_not_applicable == true' >/dev/null \
  && log_of v2 | grep -E -- 'argv: secret set NEW_SECRET --repo example/silkops-harness' >/dev/null \
  && ! log_of v2 | grep -q 'S3cretValue'; then
  pass "GV2 github: a masked value becomes an Actions secret via gh secret set, value on stdin never on argv; protected is reported not applicable"
else fail "GV2" "rc=$(rc_of v2) out=$(out_of v2) log=$(log_of v2 | tr '\n' ';')"; fi

run_case v3 "$GH/settings" SILKOPS_PROVIDER=github -- "${P[@]}" set --key NPM_TOKEN --value-file "$VAL" --unmasked
if [ "$(rc_of v3)" = 7 ] && out_of v3 | jq -e '.error == "unmask_refused"' >/dev/null && ! log_of v3 | grep -q 'variable set'; then
  pass "GV3 github: turning an existing secret into a plain variable is refused (exit 7) without --allow-unmask"
else fail "GV3" "rc=$(rc_of v3) out=$(out_of v3)"; fi

run_case v4 "$GH/settings" SILKOPS_PROVIDER=github -- "${P[@]}" set --key DEPLOY_ENV --value-file "$VAL"
if [ "$(rc_of v4)" = 0 ] && out_of v4 | jq -e '.action == "updated" and .kind == "variable" and .masked == false' >/dev/null \
  && log_of v4 | grep -E -- 'argv: variable set DEPLOY_ENV --repo example/silkops-harness' >/dev/null; then
  pass "GV4 github: an existing plain variable is updated via gh variable set"
else fail "GV4" "rc=$(rc_of v4) out=$(out_of v4) log=$(log_of v4 | tr '\n' ';')"; fi

SCRIPT="$ROOT/ops/schedule.sh"
mkdir -p "$SCRATCH/repo/.github/workflows"; printf 'name: ci\non: [push]\njobs: {}\n' >"$SCRATCH/repo/.github/workflows/ci.yml"
run_case s1 "$GH/settings" SILKOPS_PROVIDER=github -- "${P[@]}" create --description "nightly fixtures" --cron "0 22 * * *" --ref main --dir "$SCRATCH/repo" --workflow ci.yml
if [ "$(rc_of s1)" = 0 ] && out_of s1 | jq -e '.action == "file_written" and (.path | endswith(".github/workflows/silkops-nightly-fixtures.yml")) and .frequent == false and (.next | test("ship"))' >/dev/null \
  && grep -q "cron: '0 22 \* \* \*'" "$SCRATCH/repo/.github/workflows/silkops-nightly-fixtures.yml" && grep -q 'workflow_dispatch' "$SCRATCH/repo/.github/workflows/silkops-nightly-fixtures.yml" \
  && grep -q 'uses: ./.github/workflows/ci.yml' "$SCRATCH/repo/.github/workflows/silkops-nightly-fixtures.yml" && [ "$(writes_of s1)" = 0 ]; then
  pass "GS1 github: create writes a workflow file with on.schedule + workflow_dispatch calling the target workflow; no settings write"
else fail "GS1" "rc=$(rc_of s1) out=$(out_of s1) file=$(cat "$SCRATCH/repo/.github/workflows/silkops-nightly-fixtures.yml" 2>&1 | head -12)"; fi

run_case s2 "$GH/settings" SILKOPS_PROVIDER=github -- "${P[@]}" list --dir "$SCRATCH/repo"
if [ "$(rc_of s2)" = 0 ] && out_of s2 | jq -e '(.schedules | length) == 1 and .schedules[0].cron == "0 22 * * *" and (.schedules[0].id | endswith("silkops-nightly-fixtures.yml"))' >/dev/null; then
  pass "GS2 github: list reads the cron entries out of the workflow files"
else fail "GS2" "rc=$(rc_of s2) out=$(out_of s2)"; fi

run_case s3 "$GH/settings" SILKOPS_PROVIDER=github -- "${P[@]}" create --description x --cron "*/5 * * * *" --ref main --dir "$SCRATCH/repo"
if [ "$(rc_of s3)" = 7 ] && out_of s3 | jq -e '.error == "cron_too_frequent"' >/dev/null; then
  pass "GS3 github: the frequency guard still applies"
else fail "GS3" "rc=$(rc_of s3) out=$(out_of s3)"; fi

SCRIPT="$ROOT/ops/allowlist.sh"
run_case a1 "$GH/settings" SILKOPS_PROVIDER=github -- "${P[@]}" add --consumer example/other
if [ "$(rc_of a1)" = 0 ] && out_of a1 | jq -e '.not_applicable == true and .entries == []' >/dev/null && [ "$(writes_of a1)" = 0 ]; then
  pass "GA1 github: the job-token allow-list is not a concept -> ok, not_applicable, zero writes"
else fail "GA1" "rc=$(rc_of a1) out=$(out_of a1)"; fi

SCRIPT="$ROOT/ops/registry.sh"
curl_of() { cat "$SCRATCH/$1/curl.log" 2>/dev/null; }
mkdir -p "$SCRATCH/r1"; cp -R "$ROOT/tests/fixtures/registry" "$SCRATCH/r1/state"
run_case r1 "$GH/settings" SILKOPS_PROVIDER=github GH_TOKEN=ghp_STUBTOKEN000000 -- "${P[@]}" retag harness v2 v3
if [ "$(rc_of r1)" = 0 ] && out_of r1 | jq -e '.action == "retagged" and .repository == "example/harness" and .source_digest == .target_digest' >/dev/null \
  && curl_of r1 | grep -E '^curl: GET https://ghcr.io/token\?scope=repository:example/harness:pull,push auth=basic' >/dev/null \
  && curl_of r1 | grep -E '^curl: PUT https://ghcr.io/v2/example/harness/manifests/v3 auth=bearer' >/dev/null \
  && ! grep -q ghp_STUBTOKEN "$SCRATCH/r1/curl.log" "$SCRATCH/r1/out.log" "$SCRATCH/r1/err.log"; then
  pass "GR1 github: retag speaks GHCR's v2 API with the token exchange, credentials on stdin only"
else fail "GR1" "rc=$(rc_of r1) out=$(out_of r1) curl=$(curl_of r1 | tr '\n' ';')"; fi

mkdir -p "$SCRATCH/r2"; cp -R "$ROOT/tests/fixtures/registry" "$SCRATCH/r2/state"
run_case r2 "$GH/settings" SILKOPS_PROVIDER=github GH_TOKEN=ghp_STUBTOKEN000000 -- "${P[@]}" tags harness
if [ "$(rc_of r2)" = 0 ] && out_of r2 | jq -e '.repository == "example/harness" and ([.tags[].name] | sort) == ["v1","v2"]' >/dev/null; then
  pass "GR2 github: tags come from GHCR's v2 tags list"
else fail "GR2" "rc=$(rc_of r2) out=$(out_of r2) curl=$(curl_of r2 | tr '\n' ';')"; fi

SCRIPT="$ROOT/ops/token-check.sh"
run_case t1 "$GH/settings" SILKOPS_PROVIDER=github -- "${P[@]}"
if [ "$(rc_of t1)" = 0 ] && out_of t1 | jq -e '.provider == "github" and .identity.username == "aqua" and .role == "Owner" and .can_merge_protected == true and .protection.required_reviews == 1' >/dev/null; then
  pass "GT1 github: token-check reads the collaborator permission and the default branch protection"
else fail "GT1" "rc=$(rc_of t1) out=$(out_of t1) err=$(err_of t1 | tail -2)"; fi

echo "test-settings-github: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
