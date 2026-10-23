#!/usr/bin/env bash
# after-merge.sh — the housekeeping after a human merged (v0.2 U11; #32, #41). Never merges.
#
# Usage: after-merge.sh --project <group/project> --mr <iid> [--sibling <iid>]
#
# Run inside the checkout. Confirms the MR is merged, fetches, checks out the default branch and
# fast-forwards it, deletes the merged local branch, prunes remote-tracking refs, lists the
# issues the MR closes with their state, and names the default-branch pipeline for the merge
# commit (with a watch.sh resume hint). --sibling <iid>: an older merged MR that touched the
# same files; every non-trivial line it added is looked for on the default branch and the
# missing ones are named (a conflict resolution that kept only one side, #41).
# (#81) The MR's last head pipeline and the default-branch pipeline for the merge commit are
# compared job by job: a job that passed on the MR but failed or was skipped on the default branch
# is a `main_only_regressions[]` entry (name, mr_status, main_status, failure_reason), and
# `main_pipeline {id, status}` names the run. Exit stays 0; the verdict line on stderr names them.
# Exit: 0 ok · 2 usage · 5 not found · 7 MR not merged · 1 other.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
# shellcheck source=lib/token.sh
. "$(dirname "$0")/lib/token.sh"
# shellcheck source=lib/glab.sh
. "$(dirname "$0")/lib/glab.sh"
# shellcheck source=lib/provider.sh
. "$(dirname "$0")/lib/provider.sh"

usage() { fail "$EX_USAGE" usage "usage: after-merge.sh --project <group/project> --mr <iid> [--sibling <iid>]${1:+ — $1}"; }
PROJECT=""; MR=""; SIB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --mr) [ $# -ge 2 ] || usage; MR="$2"; shift 2 ;;
    --sibling) [ $# -ge 2 ] || usage; SIB="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
require_project "$PROJECT"
[[ "$MR" =~ ^[0-9]+$ ]] || usage "--mr must be an iid"
[ -z "$SIB" ] || [[ "$SIB" =~ ^[0-9]+$ ]] || usage "--sibling must be an iid"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "$EX_NOT_FOUND" not_found "not inside a git checkout"
require_ci_token

MRJ="$(p_mr_get "$PROJECT" "$MR")" || fail "$EX_NOT_FOUND" not_found "merge request !$MR not found in $PROJECT"
STATE="$(printf '%s' "$MRJ" | jq -r '.state')"
[ "$STATE" = merged ] || fail "$EX_REFUSED" not_merged "merge request !$MR is $STATE, not merged; nothing to clean up (this script never merges)"
SRC="$(printf '%s' "$MRJ" | jq -r '.source_branch')"; DEF="$(printf '%s' "$MRJ" | jq -r '.target_branch')"
MSHA="$(printf '%s' "$MRJ" | jq -r '.merge_commit_sha // .sha // ""')"

# --- local sync: fetch, default branch, fast-forward only, prune, delete the merged branch ---
git fetch -q --prune origin
git switch -q "$DEF" 2>/dev/null || git switch -q -c "$DEF" "origin/$DEF"
git merge -q --ff-only "origin/$DEF" 2>/dev/null || fail "$EX_REFUSED" refused "$DEF is not a fast-forward of origin/$DEF; resolve by hand, nothing was changed"
DELETED=null
if [ "$SRC" != "$DEF" ] && git show-ref -q --verify "refs/heads/$SRC"; then
  if git branch -q -d "$SRC" 2>/dev/null; then DELETED="$SRC"; else err "local branch $SRC is not fully merged into $DEF; left in place"; fi
fi

# --- linked issues -------------------------------------------------------------------------
CLOSES="$(p_mr_closes_issues "$PROJECT" "$MR" 2>/dev/null | jq -c '[.[] | {iid, state}]' 2>/dev/null || echo '[]')"
OPEN="$(printf '%s' "$CLOSES" | jq -c '[.[] | select(.state != "closed") | .iid]')"

# --- sibling hunks (#41): each substantive added line of the older MR must still be on $DEF ---
SIBLING=null
if [ -n "$SIB" ]; then
  SJ="$(p_mr_get "$PROJECT" "$SIB")" || fail "$EX_NOT_FOUND" not_found "sibling merge request !$SIB not found"
  SD="$(p_mr_diffs "$PROJECT" "$SIB")" || fail "$EX_OTHER" lookup_failed "could not read the diffs of !$SIB"
  checked=0; missing='[]'
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    checked=$((checked + 1))
    git grep -qF -- "$line" "$DEF" -- . 2>/dev/null || missing="$(jq -cn --argjson a "$missing" --arg l "$line" '$a + [$l]')"
  done < <(printf '%s' "$SD" | jq -r '.[] | .diff // "" | split("\n")[] | select(startswith("+") and (startswith("+++") | not)) | .[1:] | select((. | gsub("[[:space:]]"; "") | length) >= 12)')
  SIBLING="$(jq -cn --argjson iid "$SIB" --arg u "$(printf '%s' "$SJ" | jq -r '.web_url // ""')" --argjson c "$checked" --argjson m "$missing" '{iid: $iid, web_url: $u, checked: $c, missing: $m}')"
fi

# --- the default-branch pipeline for the merge commit ------------------------------------------
PIPE="$(p_run_for_ref_sha "$PROJECT" "$DEF" "$MSHA" 2>/dev/null | jq -c '.[0] | {id, status, web_url}' 2>/dev/null || echo null)"
[ "$PIPE" != null ] && [ "$PIPE" != '{"id":null,"status":null,"web_url":null}' ] || PIPE=null
HINT=null; [ "$PIPE" = null ] || HINT="watch.sh --project $PROJECT --pipeline $(printf '%s' "$PIPE" | jq -r '.id')"

# --- (#81) jobs that passed on the MR but failed or were skipped on the default branch ------------
# latest_jobs <pipeline id> — {name: status, failure_reason} per job name, newest job wins (retries);
# every page of the listing, like watch.sh; '[]' when the listing fails.
latest_jobs() {
  local page=1 acc='[]' chunk n
  while :; do
    chunk="$(p_run_jobs "$PROJECT" "$1" 100 "$page" 2>/dev/null)" || { echo '[]'; return 0; }
    n="$(printf '%s' "$chunk" | jq -r 'if type == "array" then length else -1 end' 2>/dev/null)" || n=-1
    [ "$n" -ge 0 ] || { echo '[]'; return 0; }
    acc="$(jq -cn --argjson a "$acc" --argjson b "$chunk" '$a + $b')"
    if [ "$n" -lt 100 ] || [ "$page" -ge 50 ]; then break; fi
    page=$((page + 1))
  done
  printf '%s' "$acc" | jq -c 'group_by(.name) | map(sort_by(.id) | .[-1] | {name, status, failure_reason: (.failure_reason // null), allow_failure: (.allow_failure // false)})'
}
MR_PIPE_ID="$(printf '%s' "$MRJ" | jq -r '.head_pipeline.id // ""')"
HEAD_SHA="$(printf '%s' "$MRJ" | jq -r '.sha // ""')"
if [ -z "$MR_PIPE_ID" ] && [ -n "$HEAD_SHA" ]; then   # hosts without head_pipeline (GitHub): the run for the MR's head sha
  MR_PIPE_ID="$(p_run_for_ref_sha "$PROJECT" "$SRC" "$HEAD_SHA" 2>/dev/null | jq -r 'if type == "array" then (.[0].id // "") else "" end' 2>/dev/null || true)"
fi
MAIN_PIPE=null; REGRESSIONS='[]'
if [ "$PIPE" != null ]; then
  MAIN_PIPE="$(printf '%s' "$PIPE" | jq -c '{id, status}')"
  if [ -n "$MR_PIPE_ID" ]; then
    MRJOBS="$(latest_jobs "$MR_PIPE_ID")"; MAINJOBS="$(latest_jobs "$(printf '%s' "$PIPE" | jq -r .id)")"
    REGRESSIONS="$(jq -cn --argjson m "$MRJOBS" --argjson d "$MAINJOBS" '
      ($m | map({key: .name, value: .status}) | from_entries) as $mr
      | [$d[] | select((.status == "failed" or .status == "skipped") and $mr[.name] == "success")
         | {name, mr_status: "success", main_status: .status, failure_reason}]')"
  fi
fi
if [ "$REGRESSIONS" != '[]' ]; then
  err "VERDICT: $(printf '%s' "$REGRESSIONS" | jq -r 'length') job(s) passed on MR !$MR but not on $DEF (pipeline $(printf '%s' "$MAIN_PIPE" | jq -r .id)): $(printf '%s' "$REGRESSIONS" | jq -r 'map(.name + " " + .main_status) | join(", ")') — a rules: or needs: difference between the MR and the default branch"
else
  err "VERDICT: no main-only regression (MR pipeline ${MR_PIPE_ID:-unknown} vs $DEF pipeline $(printf '%s' "$MAIN_PIPE" | jq -r '.id // "unknown"'))"
fi
result "$(jq -cn --argjson iid "$MR" --arg d "$DEF" --arg s "$SRC" --arg sha "$MSHA" --argjson del "$(jq -cn --arg x "$DELETED" 'if $x == "null" then null else $x end')" \
  --argjson c "$CLOSES" --argjson o "$OPEN" --argjson sib "$SIBLING" --argjson p "$PIPE" --argjson h "$(jq -cn --arg x "$HINT" 'if $x == "null" then null else $x end')" \
  --argjson mp "$MAIN_PIPE" --argjson mrp "$(jq -cn --arg x "$MR_PIPE_ID" 'if $x == "" then null else ($x | tonumber? // $x) end')" --argjson reg "$REGRESSIONS" \
  '{mr_iid: $iid, merged: true, default_branch: $d, source_branch: $s, merge_commit_sha: $sha, branch_deleted: $del,
    closes_issues: $c, issues_still_open: $o, sibling: $sib, default_branch_pipeline: $p, resume_hint: $h,
    mr_pipeline_id: $mrp, main_pipeline: $mp, main_only_regressions: $reg}')"
