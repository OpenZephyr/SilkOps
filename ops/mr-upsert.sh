#!/usr/bin/env bash
# mr-upsert.sh — open or re-sync the merge request for a branch (plan U4). Never merges.
#
# Usage: mr-upsert.sh --project <group/project> --source <branch> --target <branch>
#          --title <t> --description-file <f> [--draft] [--dry-run]
#          [--marker-unit <U-ID> --plan <basename> --run <id>]
#
# Finds the open MR for --source; updates only the marker-managed region of its
# description (text outside is byte-identical), or creates the MR via the API.
# Reports iid, web_url, action created|updated|unchanged and the head pipeline id.
# Session identity (the operator authors the MR), never the settings token. A failed MR
# listing aborts (exit 1 lookup_failed): nothing is created without a successful lookup.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
# shellcheck source=lib/token.sh
. "$(dirname "$0")/lib/token.sh"
# shellcheck source=lib/glab.sh
. "$(dirname "$0")/lib/glab.sh"
# shellcheck source=lib/provider.sh
. "$(dirname "$0")/lib/provider.sh"

usage() { fail "$EX_USAGE" usage "usage: mr-upsert.sh --project <group/project> --source <branch> --target <branch> --title <t> --description-file <f> [--draft] [--dry-run] [--marker-unit <U-ID> --plan <basename> --run <id>]${1:+ — $1}"; }

PROJECT=""; SRC=""; TGT=""; TITLE=""; DESC_FILE=""; DRAFT=false; DRY=false
UNIT="mr"; PLAN="-"; RUN="$(date -u +%Y%m%dT%H%M%SZ)"
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --source) [ $# -ge 2 ] || usage; SRC="$2"; shift 2 ;;
    --target) [ $# -ge 2 ] || usage; TGT="$2"; shift 2 ;;
    --title) [ $# -ge 2 ] || usage; TITLE="$2"; shift 2 ;;
    --description-file) [ $# -ge 2 ] || usage; DESC_FILE="$2"; shift 2 ;;
    --marker-unit) [ $# -ge 2 ] || usage; UNIT="$2"; shift 2 ;;
    --plan) [ $# -ge 2 ] || usage; PLAN="$2"; shift 2 ;;
    --run) [ $# -ge 2 ] || usage; RUN="$2"; shift 2 ;;
    --draft) DRAFT=true; shift ;;
    --dry-run) DRY=true; shift ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
require_project "$PROJECT"
if ! { [ -n "$SRC" ] && [ -n "$TGT" ]; }; then usage "--source and --target are required"; fi
[ -n "$TITLE" ] || usage "--title is required"
if ! { [ -n "$DESC_FILE" ] && [ -f "$DESC_FILE" ]; }; then usage "--description-file must name a readable file"; fi
require_ci_token   # top level, so the exit-3 JSON and message reach the real streams (the wrappers re-check)

MARKER="$(silkops_marker "$PLAN" "$UNIT" "$RUN")"; MARKER="${MARKER%$'\n'}"
BODY="$(cat "$DESC_FILE")"
# SILKOPS_MARKER=off: identity is the source branch only, the description is the body
# verbatim, and a re-sync replaces the whole description (KTD3); the result says so.
if marker_enabled; then MARKER_ON=true; else MARKER_ON=false; fi
if [ "$DRAFT" = true ]; then case "$TITLE" in "Draft: "*) ;; *) TITLE="Draft: $TITLE" ;; esac; fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/silkops-mr.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# A failed listing must never read as "no open MR" — that is how a branch gets two MRs.
p_mr_find_by_branch "$PROJECT" "$SRC" 10 >"$TMP/open.json" 2>"$TMP/lookup.err" \
  || fail "$EX_OTHER" lookup_failed "could not list the open MRs for $SRC in $PROJECT; refusing to write without a successful lookup: $(redact <"$TMP/lookup.err" | tr '\n' ' ')"
FOUND="$(jq -c --arg t "$TGT" '([.[] | select(.target_branch == $t)] | first) // (first // null)' "$TMP/open.json")"

# siblings <iid> — other open MRs on the same target that touch a file this MR touches (#41):
# a later merge can silently drop the older MR's hunks, so both are named up front. Best effort:
# a failed listing yields [] and never blocks the upsert.
siblings() {
  local mine others out='[]' o oid opaths
  mine="$(p_mr_diffs "$PROJECT" "$1" 2>/dev/null | jq -c '[.[] | .new_path, .old_path] | unique' 2>/dev/null || echo '[]')"
  [ "$mine" != '[]' ] || { printf '[]'; return; }
  others="$(p_mr_list_open "$PROJECT" "$TGT" 2>/dev/null | jq -c --argjson me "$1" '[.[] | select(.iid != $me) | {iid, web_url, source_branch}]' 2>/dev/null || echo '[]')"
  for oid in $(printf '%s' "$others" | jq -r '.[].iid'); do
    opaths="$(p_mr_diffs "$PROJECT" "$oid" 2>/dev/null | jq -c '[.[] | .new_path, .old_path] | unique' 2>/dev/null || echo '[]')"
    o="$(jq -cn --argjson m "$mine" --argjson p "$opaths" '$m - ($m - $p) | sort')"
    [ "$o" = '[]' ] || out="$(jq -cn --argjson a "$out" --argjson others "$others" --argjson oid "$oid" --argjson f "$o" '$a + [($others[] | select(.iid == $oid)) + {shared_files: $f}]')"
  done
  printf '%s' "$out"
}

# head_pipeline_of <iid> <json-or-null> — the list payload may omit head_pipeline.
head_pipeline_of() {
  local hp
  hp="$(printf '%s' "$2" | jq -c '.head_pipeline.id // null')"
  if [ "$hp" = null ]; then
    hp="$(p_mr_get "$PROJECT" "$1" 2>/dev/null | jq -c '.head_pipeline.id // null' || echo null)"
  fi
  printf '%s' "${hp:-null}"
}

if [ "$FOUND" != null ]; then
  IID="$(printf '%s' "$FOUND" | jq -r '.iid')"
  WEB="$(printf '%s' "$FOUND" | jq -r '.web_url // ""')"
  IDENT="$(jq -cn --argjson iid "$IID" --arg w "$WEB" --arg s "$SRC" --arg t "$TGT" --argjson m "$MARKER_ON" '{iid: $iid, web_url: $w, source_branch: $s, target_branch: $t, identity: "branch", marker: $m}')"
  if [ "$MARKER_ON" = true ]; then
    PLANNED="$(managed_region_plan "$FOUND" "$BODY" "$MARKER" "$RUN")"
  else
    PLANNED="$(jq -cn --argjson f "$FOUND" --arg b "$BODY"$'\n' '{had_region: false, changed: (($f.description // "") != $b), description: $b}')"
  fi
  HP="$(head_pipeline_of "$IID" "$FOUND")"
  if [ "$(printf '%s' "$PLANNED" | jq -r '.changed')" = false ]; then
    result "$(jq -cn --argjson i "$IDENT" --argjson hp "$HP" '$i + {action: "unchanged", head_pipeline_id: $hp}')"
    exit 0
  fi
  if [ "$DRY" = true ]; then
    result "$(jq -cn --argjson i "$IDENT" --argjson hp "$HP" --argjson f "$FOUND" --argjson p "$PLANNED" '$i + {dry_run: true, action: "updated", head_pipeline_id: $hp, current: {description: ($f.description // "")}, proposed: {description: $p.description}}')"
    exit 0
  fi
  printf '%s' "$PLANNED" | jq -c '{description: .description}' >"$TMP/body.json"
  RESP="$(p_mr_update "$PROJECT" "$IID" "$TMP/body.json")" || fail "$EX_OTHER" update_failed "could not update MR !$IID" "$IDENT"
  result "$(jq -cn --argjson i "$IDENT" --argjson r "$RESP" --argjson hp "$HP" --argjson f "$FOUND" --argjson sib "$(siblings "$IID")" '$i + {action: "updated", web_url: ($r.web_url // $i.web_url), head_pipeline_id: $hp, siblings: $sib, prior: {description: ($f.description // "")}} + (if $r.number then {number: $r.number} else {} end)')"
  exit 0
fi

if [ "$MARKER_ON" = true ]; then
  DESC="$(jq -rn --arg marker "$MARKER" --arg body "$BODY" '$marker + "\n<!-- silkops:managed -->\n" + $body + "\n<!-- /silkops:managed -->\n"')"
else
  DESC="$BODY"$'\n'
fi
if [ "$DRY" = true ]; then
  result "$(jq -cn --arg s "$SRC" --arg t "$TGT" --arg title "$TITLE" --arg d "$DESC" --argjson m "$MARKER_ON" '{dry_run: true, action: "created", identity: "branch", marker: $m, current: null, proposed: {source_branch: $s, target_branch: $t, title: $title, description: $d}}')"
  exit 0
fi
jq -cn --arg s "$SRC" --arg t "$TGT" --arg title "$TITLE" --arg d "$DESC" '{source_branch: $s, target_branch: $t, title: $title, description: $d}' >"$TMP/body.json"
RESP="$(p_mr_create "$PROJECT" "$TMP/body.json")" || fail "$EX_OTHER" create_failed "could not create the MR $SRC -> $TGT in $PROJECT"
IID="$(printf '%s' "$RESP" | jq -r '.iid')"
HP="$(head_pipeline_of "$IID" "$RESP")"
result "$(printf '%s' "$RESP" | jq -c --argjson hp "$HP" --argjson m "$MARKER_ON" --argjson sib "$(siblings "$IID")" '{action: "created", iid: .iid, web_url: .web_url, source_branch: .source_branch, target_branch: .target_branch, head_pipeline_id: $hp, identity: "branch", marker: $m, siblings: $sib} + (if .number then {number} else {} end)')"
