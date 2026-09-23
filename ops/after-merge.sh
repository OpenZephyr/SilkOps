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
result "$(jq -cn --argjson iid "$MR" --arg d "$DEF" --arg s "$SRC" --arg sha "$MSHA" --argjson del "$(jq -cn --arg x "$DELETED" 'if $x == "null" then null else $x end')" \
  --argjson c "$CLOSES" --argjson o "$OPEN" --argjson sib "$SIBLING" --argjson p "$PIPE" --argjson h "$(jq -cn --arg x "$HINT" 'if $x == "null" then null else $x end')" \
  '{mr_iid: $iid, merged: true, default_branch: $d, source_branch: $s, merge_commit_sha: $sha, branch_deleted: $del,
    closes_issues: $c, issues_still_open: $o, sibling: $sib, default_branch_pipeline: $p, resume_hint: $h}')"
