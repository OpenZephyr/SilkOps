#!/usr/bin/env bash
# issue-upsert.sh — create or re-sync a plan-unit issue, idempotent by marker (plan U4, KTD5).
#
# Usage: issue-upsert.sh --project <group/project> --marker-unit <U-ID> --plan <basename>
#          --run <id> --title <t> --body-file <f> [--milestone <title|id>] [--labels a,b] [--dry-run]
#
# Identity: the marker `<!-- silkops: v=… plan=<basename> unit=<U-ID> run=… -->` in the
# description, then the label `u<N>`; never the title. A closed issue is never edited
# (exit 7). An open one has ONLY its managed region replaced (text outside is byte-
# identical) and the marker's run= refreshed; an identical region means zero writes.
# Not found → created with body = marker + managed region wrapping the body file.
# Session identity (the operator authors the issue), never the settings token.
# Exit: 0 ok · 2 usage · 5 milestone not found · 7 closed issue · 1 other.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
# shellcheck source=lib/token.sh
. "$(dirname "$0")/lib/token.sh"
# shellcheck source=lib/glab.sh
. "$(dirname "$0")/lib/glab.sh"

usage() { fail "$EX_USAGE" usage "usage: issue-upsert.sh --project <group/project> --marker-unit <U-ID> --plan <basename> --run <id> --title <t> --body-file <f> [--milestone <title|id>] [--labels a,b] [--dry-run]${1:+ — $1}"; }

PROJECT=""; UNIT=""; PLAN=""; RUN=""; TITLE=""; BODY_FILE=""; MILESTONE=""; LABELS=""; DRY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --marker-unit) [ $# -ge 2 ] || usage; UNIT="$2"; shift 2 ;;
    --plan) [ $# -ge 2 ] || usage; PLAN="$2"; shift 2 ;;
    --run) [ $# -ge 2 ] || usage; RUN="$2"; shift 2 ;;
    --title) [ $# -ge 2 ] || usage; TITLE="$2"; shift 2 ;;
    --body-file) [ $# -ge 2 ] || usage; BODY_FILE="$2"; shift 2 ;;
    --milestone) [ $# -ge 2 ] || usage; MILESTONE="$2"; shift 2 ;;
    --labels) [ $# -ge 2 ] || usage; LABELS="$2"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
require_project
[ -n "$UNIT" ] && [ -n "$PLAN" ] && [ -n "$RUN" ] || usage "--marker-unit, --plan and --run are required"
[ -n "$TITLE" ] || usage "--title is required"
[ -n "$BODY_FILE" ] && [ -f "$BODY_FILE" ] || usage "--body-file must name a readable file"

ENC="$(urlenc "$PROJECT")"
MARKER="$(silkops_marker "$PLAN" "$UNIT" "$RUN")"; MARKER="${MARKER%$'\n'}"
BODY="$(cat "$BODY_FILE")"
ULABEL="$(printf '%s' "$UNIT" | tr '[:upper:]' '[:lower:]')"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/silkops-upsert.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# --- find: marker first, then label u<N> ------------------------------------
SEARCH="$(urlenc "plan=$PLAN unit=$UNIT")"
FOUND="$(api_get "projects/$ENC/issues?search=$SEARCH&in=description&state=all&scope=all&per_page=100" 2>/dev/null || echo '[]')"
FOUND="$(printf '%s' "$FOUND" | jq -c --arg p "$PLAN" --arg u "$UNIT" \
  '[.[] | select((.description // "") | contains("<!-- silkops:") and contains("plan=\($p) unit=\($u) run="))] | first // null')"
if [ "$FOUND" = null ]; then
  FOUND="$(api_get "projects/$ENC/issues?labels=$(urlenc "$ULABEL")&state=all&scope=all&per_page=100" 2>/dev/null || echo '[]')"
  FOUND="$(printf '%s' "$FOUND" | jq -c 'first // null')"
fi

# --- milestone → id ---------------------------------------------------------
MILESTONE_ID=null
if [ -n "$MILESTONE" ]; then
  if [[ "$MILESTONE" =~ ^[0-9]+$ ]]; then MILESTONE_ID="$MILESTONE"
  else
    MS="$(api_get "projects/$ENC/milestones?title=$(urlenc "$MILESTONE")&include_parent_milestones=true" 2>/dev/null || echo '[]')"
    MILESTONE_ID="$(printf '%s' "$MS" | jq -r --arg t "$MILESTONE" '[.[] | select(.title == $t)] | first | .id // "null"')"
    [ "$MILESTONE_ID" != null ] || fail "$EX_NOT_FOUND" not_found "milestone not found: $MILESTONE"
  fi
fi

if [ "$FOUND" != null ]; then
  IID="$(printf '%s' "$FOUND" | jq -r '.iid')"
  STATE="$(printf '%s' "$FOUND" | jq -r '.state')"
  WEB="$(printf '%s' "$FOUND" | jq -r '.web_url // ""')"
  IDENT="$(jq -cn --argjson iid "$IID" --arg w "$WEB" '{iid: $iid, web_url: $w}')"
  [ "$STATE" != closed ] || fail "$EX_REFUSED" closed_issue "issue #$IID is closed; the harness never edits or reopens a closed issue (KTD5)" "$IDENT"

  # New description: only the managed region changes; the marker's run= is refreshed.
  # Without a region (found by label, written by a human), append marker + region.
  PLANNED="$(managed_region_plan "$FOUND" "$BODY" "$MARKER" "$RUN")"
  if [ "$(printf '%s' "$PLANNED" | jq -r '.changed')" = false ]; then
    result "$(jq -cn --argjson i "$IDENT" '$i + {action: "unchanged"}')"
    exit 0
  fi
  if [ "$DRY" = true ]; then
    result "$(jq -cn --argjson i "$IDENT" --argjson f "$FOUND" --argjson p "$PLANNED" '$i + {dry_run: true, action: "updated", current: {description: ($f.description // "")}, proposed: {description: $p.description}}')"
    exit 0
  fi
  printf '%s' "$PLANNED" | jq -c --arg labels "$LABELS" --argjson ms "$MILESTONE_ID" \
    '{description: .description} + (if $labels != "" then {add_labels: $labels} else {} end) + (if $ms != null then {milestone_id: $ms} else {} end)' >"$TMP/body.json"
  RESP="$(glab_ro api -X PUT "projects/$ENC/issues/$IID" --input "$TMP/body.json")" || fail "$EX_OTHER" update_failed "could not update issue #$IID" "$IDENT"
  result "$(jq -cn --argjson i "$IDENT" --argjson r "$RESP" --argjson f "$FOUND" '$i + {action: "updated", web_url: ($r.web_url // $i.web_url), prior: {description: ($f.description // "")}}')"
  exit 0
fi

# --- create -----------------------------------------------------------------
DESC="$(jq -rn --arg marker "$MARKER" --arg body "$BODY" '$marker + "\n<!-- silkops:managed -->\n" + $body + "\n<!-- /silkops:managed -->\n"')"
ALL_LABELS="$(jq -rn --arg l "$LABELS" --arg u "$ULABEL" '($l | split(",") | map(select(. != ""))) as $a | (if ($a | index($u)) == null then $a + [$u] else $a end) | join(",")')"
if [ "$DRY" = true ]; then
  result "$(jq -cn --arg t "$TITLE" --arg d "$DESC" --arg l "$ALL_LABELS" --argjson ms "$MILESTONE_ID" '{dry_run: true, action: "created", current: null, proposed: {title: $t, description: $d, labels: $l, milestone_id: $ms}}')"
  exit 0
fi
jq -cn --arg t "$TITLE" --arg d "$DESC" --arg l "$ALL_LABELS" --argjson ms "$MILESTONE_ID" \
  '{title: $t, description: $d, labels: $l} + (if $ms != null then {milestone_id: $ms} else {} end)' >"$TMP/body.json"
RESP="$(glab_ro api -X POST "projects/$ENC/issues" --input "$TMP/body.json")" || fail "$EX_OTHER" create_failed "could not create the issue in $PROJECT"
result "$(printf '%s' "$RESP" | jq -c '{action: "created", iid: .iid, web_url: .web_url, state: .state}')"
