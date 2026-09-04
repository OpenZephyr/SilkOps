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
# Session identity (the operator authors the MR), never the settings token.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
# shellcheck source=lib/token.sh
. "$(dirname "$0")/lib/token.sh"
# shellcheck source=lib/glab.sh
. "$(dirname "$0")/lib/glab.sh"

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
require_project
[ -n "$SRC" ] && [ -n "$TGT" ] || usage "--source and --target are required"
[ -n "$TITLE" ] || usage "--title is required"
[ -n "$DESC_FILE" ] && [ -f "$DESC_FILE" ] || usage "--description-file must name a readable file"

ENC="$(urlenc "$PROJECT")"
MARKER="$(silkops_marker "$PLAN" "$UNIT" "$RUN")"; MARKER="${MARKER%$'\n'}"
BODY="$(cat "$DESC_FILE")"
if [ "$DRAFT" = true ]; then case "$TITLE" in "Draft: "*) ;; *) TITLE="Draft: $TITLE" ;; esac; fi
TMP="$(mktemp -d "${TMPDIR:-/tmp}/silkops-mr.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

FOUND="$(api_get "projects/$ENC/merge_requests?source_branch=$(urlenc "$SRC")&state=opened&per_page=10" 2>/dev/null || echo '[]')"
FOUND="$(printf '%s' "$FOUND" | jq -c --arg t "$TGT" '([.[] | select(.target_branch == $t)] | first) // (first // null)')"

# head_pipeline_of <iid> <json-or-null> — the list payload may omit head_pipeline.
head_pipeline_of() {
  local hp
  hp="$(printf '%s' "$2" | jq -c '.head_pipeline.id // null')"
  if [ "$hp" = null ]; then
    hp="$(api_get "projects/$ENC/merge_requests/$1" 2>/dev/null | jq -c '.head_pipeline.id // null' || echo null)"
  fi
  printf '%s' "${hp:-null}"
}

if [ "$FOUND" != null ]; then
  IID="$(printf '%s' "$FOUND" | jq -r '.iid')"
  WEB="$(printf '%s' "$FOUND" | jq -r '.web_url // ""')"
  IDENT="$(jq -cn --argjson iid "$IID" --arg w "$WEB" --arg s "$SRC" --arg t "$TGT" '{iid: $iid, web_url: $w, source_branch: $s, target_branch: $t}')"
  PLANNED="$(printf '%s' "$FOUND" | jq -c --arg body "$BODY" --arg marker "$MARKER" --arg run "$RUN" '(.description // "") as $d |
    "<!-- silkops:managed -->" as $open | "<!-- /silkops:managed -->" as $close
    | ("\n" + $body + "\n") as $inner
    | if ($d | contains($open)) and ($d | contains($close)) then
        ($d | split($open)) as $a | ($a[1:] | join($open) | split($close)) as $b
        | {changed: ($b[0] != $inner),
           description: (($a[0] | sub("(?<m><!-- silkops: v=[^ ]+ plan=[^ ]+ unit=[^ ]+ run=)[^ ]+ -->"; "\(.m)\($run) -->"))
                         + $open + $inner + $close + ($b[1:] | join($close)))}
      else
        {changed: true,
         description: ($d + (if ($d == "" or ($d | endswith("\n"))) then "" else "\n" end) + $marker + "\n" + $open + $inner + $close + "\n")}
      end')"
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
  RESP="$(glab_ro api -X PUT "projects/$ENC/merge_requests/$IID" --input "$TMP/body.json")" || fail "$EX_OTHER" update_failed "could not update MR !$IID" "$IDENT"
  result "$(jq -cn --argjson i "$IDENT" --argjson r "$RESP" --argjson hp "$HP" --argjson f "$FOUND" '$i + {action: "updated", web_url: ($r.web_url // $i.web_url), head_pipeline_id: $hp, prior: {description: ($f.description // "")}}')"
  exit 0
fi

DESC="$(jq -rn --arg marker "$MARKER" --arg body "$BODY" '$marker + "\n<!-- silkops:managed -->\n" + $body + "\n<!-- /silkops:managed -->\n"')"
if [ "$DRY" = true ]; then
  result "$(jq -cn --arg s "$SRC" --arg t "$TGT" --arg title "$TITLE" --arg d "$DESC" '{dry_run: true, action: "created", current: null, proposed: {source_branch: $s, target_branch: $t, title: $title, description: $d}}')"
  exit 0
fi
jq -cn --arg s "$SRC" --arg t "$TGT" --arg title "$TITLE" --arg d "$DESC" '{source_branch: $s, target_branch: $t, title: $title, description: $d}' >"$TMP/body.json"
RESP="$(glab_ro api -X POST "projects/$ENC/merge_requests" --input "$TMP/body.json")" || fail "$EX_OTHER" create_failed "could not create the MR $SRC -> $TGT in $PROJECT"
IID="$(printf '%s' "$RESP" | jq -r '.iid')"
HP="$(head_pipeline_of "$IID" "$RESP")"
result "$(printf '%s' "$RESP" | jq -c --argjson hp "$HP" '{action: "created", iid: .iid, web_url: .web_url, source_branch: .source_branch, target_branch: .target_branch, head_pipeline_id: $hp}')"
