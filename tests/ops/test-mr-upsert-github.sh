#!/usr/bin/env bash
# shellcheck disable=SC2034
# Tier 1 tests for ops/mr-upsert.sh with SILKOPS_PROVIDER=github over the gh stub (v0.3 U3).
# The same script, the same JSON keys; a pull request is the change and its number is the iid.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
GH="$ROOT/tests/fixtures/gh-stub"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/ops/lib/harness.sh"
SCRIPT="$ROOT/ops/mr-upsert.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-mr-gh.XXXXXX")"
PLUGIN_V="$(jq -r .version "$ROOT/.claude-plugin/plugin.json")"
PROJECT="example/silkops-harness"
DESC="$SCRATCH/desc.md"; printf 'new mr body\n' >"$DESC"
ARGS=(--project "$PROJECT" --source feat/u4 --target main --title "U4 gap fillers" --description-file "$DESC" --marker-unit U4 --plan plan.md --run r2)

run_case g1 "$GH/pr-none" SILKOPS_PROVIDER=github -- "${ARGS[@]}"
if [ "$(rc_of g1)" = 0 ] && out_of g1 | jq -e '.ok == true and .action == "created" and .iid == 8 and .provider == "github" and .number == 8
      and (.web_url | endswith("/pull/8")) and .source_branch == "feat/u4" and .target_branch == "main"' >/dev/null \
  && log_of g1 | grep -E -- 'api -X POST .*repos/example/silkops-harness/pulls' >/dev/null \
  && body_of g1 1 | jq -e '.body.head == "feat/u4" and .body.base == "main" and .body.title == "U4 gap fillers" and (.body.body | startswith("<!-- silkops: v='"$PLUGIN_V"' plan=plan.md unit=U4 run=r2 -->"))' >/dev/null \
  && ! log_of g1 | grep -q 'glab'; then
  pass "G1 github: no open PR for the branch -> created via POST pulls with head/base/title/body; iid is the PR number; no glab call"
else fail "G1" "rc=$(rc_of g1) out=$(out_of g1) body=$(body_of g1 1 2>/dev/null) log=$(log_of g1 | tr '\n' ';' | head -c 400)"; fi

run_case g2 "$GH/pr-open" SILKOPS_PROVIDER=github -- "${ARGS[@]}"
if [ "$(rc_of g2)" = 0 ] && out_of g2 | jq -e '.action == "updated" and .iid == 7 and .provider == "github"' >/dev/null \
  && log_of g2 | grep -E -- 'api -X PATCH .*pulls/7' >/dev/null \
  && body_of g2 1 | jq -e '.body.body == "<!-- silkops: v=0.1.0 plan=plan.md unit=U4 run=r2 -->\n<!-- silkops:managed -->\nnew mr body\n<!-- /silkops:managed -->\n\nReviewer notes.\n"' >/dev/null; then
  pass "G2 github: open PR found by head branch -> managed region replaced via PATCH, reviewer text kept"
else fail "G2" "rc=$(rc_of g2) out=$(out_of g2) body=$(body_of g2 1 2>/dev/null)"; fi

echo "test-mr-upsert-github: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
