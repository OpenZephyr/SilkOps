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

run_in a1 --project "$PROJECT" --mr 7 --sibling 8
if [ "$(rc_of a1)" = 0 ] && out_of a1 | jq -e '.ok == true and .merged == true and .default_branch == "main" and .branch_deleted == "feat/x"
      and .closes_issues == [{"iid":12,"state":"closed"},{"iid":13,"state":"opened"}] and .issues_still_open == [13]
      and .sibling.iid == 8 and .sibling.checked == 2 and .sibling.missing == ["kept line here"]
      and .default_branch_pipeline.id == 777 and (.resume_hint | contains("--pipeline 777"))' >/dev/null \
  && [ "$(git -C "$L" branch --show-current)" = main ] && ! git -C "$L" show-ref -q refs/heads/feat/x \
  && [ "$(git -C "$L" rev-parse HEAD)" = "$(git -C "$O" rev-parse HEAD)" ] && [ "$(writes_of a1)" = 0 ]; then
  pass "A1 merged MR: main fast-forwarded, feat/x deleted, closed/open issues listed, sibling line missing named, main pipeline handed back"
else fail "A1" "rc=$(rc_of a1) out=$(out_of a1 | head -c 900) err=$(err_of a1 | tail -3) br=$(git -C "$L" branch --show-current)"; fi

run_in a2 --project "$PROJECT" --mr 8
if [ "$(rc_of a2)" = 0 ] && out_of a2 | jq -e '.branch_deleted == null and .sibling == null' >/dev/null; then
  pass "A2 a merged MR whose branch is not local: nothing to delete, no sibling check, still ok"
else fail "A2" "rc=$(rc_of a2) out=$(out_of a2 | head -c 400)"; fi

echo "test-after-merge: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
