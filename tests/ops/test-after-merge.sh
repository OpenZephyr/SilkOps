#!/usr/bin/env bash
# shellcheck disable=SC2034  # SCRIPT, STUB_DIR, SCRATCH, PROJECT are read by lib/harness.sh functions
# Tier 1 tests for ops/after-merge.sh (v0.2 U11, #32 #41): after a human merged, sync the default
# branch, prune the branch, confirm linked issues, check a sibling MR's added lines survived,
# and hand back the default-branch pipeline. Offline: scratch repos plus the glab stub.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
# shellcheck source=lib/harness.sh
. "$ROOT/tests/ops/lib/harness.sh"
SCRIPT="$ROOT/ops/after-merge.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-after.XXXXXX")"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
g() { git -c user.name=t -c user.email=t@t "$@"; }
# origin: main with the merged content (one sibling line kept, one dropped); local: on feat/x, behind
O="$SCRATCH/origin"; L="$SCRATCH/local"
g init -q -b main "$O"; ( cd "$O" && printf '# readme\nversion 1.2.3 of the tap\nunchanged\n' >README.md && g add README.md && g commit -qm base )
g clone -q "$O" "$L"; ( cd "$L" && g switch -qc feat/x && echo x >x && g add x && g commit -qm "Add x" && g push -q origin feat/x )
( cd "$O" && g merge -q --no-ff feat/x -m "Merge feat/x" )   # a human merged upstream
run_in() { local n="$1"; shift; ( cd "$L" && run_case "$n" after-merge -- "$@" ); }
run_in_sc() { local n="$1" sc="$2"; shift 2; ( cd "$L" && run_case "$n" "$sc" -- "$@" ); }

run_in a1 --project "$PROJECT" --mr 7 --sibling 8
if [ "$(rc_of a1)" = 0 ] && out_of a1 | jq -e '.ok == true and .merged == true and .default_branch == "main" and .branch_deleted == "feat/x"
      and .closes_issues == [{"iid":12,"state":"closed"},{"iid":13,"state":"opened"}] and .issues_still_open == [13]
      and .sibling.iid == 8 and .sibling.checked == 2 and .sibling.missing == ["kept line here"]
      and .default_branch_pipeline.id == 777 and (.resume_hint | contains("--pipeline 777"))
      and .mr_pipeline_id == 501 and .main_pipeline == {"id":777,"status":"running"} and .main_only_regressions == []' >/dev/null \
  && [ "$(git -C "$L" branch --show-current)" = main ] && ! git -C "$L" show-ref -q refs/heads/feat/x \
  && [ "$(git -C "$L" rev-parse HEAD)" = "$(git -C "$O" rev-parse HEAD)" ] && [ "$(writes_of a1)" = 0 ]; then
  pass "A1 merged MR: main fast-forwarded, feat/x deleted, closed/open issues listed, sibling line missing named, main pipeline handed back"
else fail "A1" "rc=$(rc_of a1) out=$(out_of a1 | head -c 900) err=$(err_of a1 | tail -3) br=$(git -C "$L" branch --show-current)"; fi

run_in a2 --project "$PROJECT" --mr 8
if [ "$(rc_of a2)" = 0 ] && out_of a2 | jq -e '.branch_deleted == null and .sibling == null' >/dev/null; then
  pass "A2 a merged MR whose branch is not local: nothing to delete, no sibling check, still ok"
else fail "A2" "rc=$(rc_of a2) out=$(out_of a2 | head -c 400)"; fi

# (#81) build-image passed on the MR pipeline but was skipped on main; factory-tests failed there; an
# allowed failure that never ran on the MR is not a regression
( cd "$O" && printf 'more\n' >>README.md && g add README.md && g commit -qm more )   # main moved again: a fast-forward is still fine
run_in_sc a3 after-merge-regression --project "$PROJECT" --mr 7
if [ "$(rc_of a3)" = 0 ] && out_of a3 | jq -e '.ok == true and .main_pipeline.id == 777 and (.main_only_regressions | length) == 2
      and .main_only_regressions[0] == {"name":"build-image","mr_status":"success","main_status":"skipped","failure_reason":null}
      and .main_only_regressions[1].name == "factory-tests" and .main_only_regressions[1].main_status == "failed"
      and (.main_only_regressions | map(.name) | index("secret_detection")) == null' >/dev/null \
  && err_of a3 | grep -E -- 'VERDICT: 2 job\(s\) passed on MR !7 but not on main \(pipeline 777\): build-image skipped, factory-tests failed' >/dev/null \
  && [ "$(writes_of a3)" = 0 ]; then
  pass "A3 (#81) jobs green on the MR but skipped/failed on main are main_only_regressions, named in the verdict line, exit 0"
else fail "A3" "rc=$(rc_of a3) out=$(out_of a3 | jq -c '{main_pipeline, main_only_regressions}' 2>/dev/null) err=$(err_of a3 | tail -3)"; fi
if err_of a1 | grep -E -- 'VERDICT: no main-only regression' >/dev/null; then pass "A3b (#81) the clean case says so on stderr"; else fail "A3b" "err=$(err_of a1 | tail -3)"; fi

echo "test-after-merge: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
