#!/usr/bin/env bash
# issue-link.sh — link two issues (plan U4). Session identity, never the settings token.
#
# Usage: issue-link.sh --project <group/project> --source <iid> --target <iid>
#                      [--type blocks|relates_to] [--dry-run]
#
# POST projects/:id/issues/:iid/links. `blocks` is tier-gated: when the API
# rejects it (400/403) the link is created as `relates_to` and the result carries
# `fallback:"relates_to"` plus `depends_on_line` for the caller to add to the body.
# Idempotent: an existing link (listed, or 409 on create) yields ok + existing:true.
# Exit: 0 ok · 2 usage · 5 project/issue not found · 1 other.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
# shellcheck source=lib/token.sh
. "$(dirname "$0")/lib/token.sh"
# shellcheck source=lib/glab.sh
. "$(dirname "$0")/lib/glab.sh"

usage() { fail "$EX_USAGE" usage "usage: issue-link.sh --project <group/project> --source <iid> --target <iid> [--type blocks|relates_to] [--dry-run]${1:+ — $1}"; }

PROJECT=""; SOURCE=""; TARGET=""; TYPE="relates_to"; DRY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --source) [ $# -ge 2 ] || usage "--source needs a value"; SOURCE="$2"; shift 2 ;;
    --target) [ $# -ge 2 ] || usage "--target needs a value"; TARGET="$2"; shift 2 ;;
    --type) [ $# -ge 2 ] || usage "--type needs a value"; TYPE="$2"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
require_project
[[ "$SOURCE" =~ ^[0-9]+$ ]] || usage "--source must be an issue iid"
[[ "$TARGET" =~ ^[0-9]+$ ]] || usage "--target must be an issue iid"
case "$TYPE" in blocks|relates_to) ;; *) usage "--type must be blocks or relates_to (got: $TYPE)" ;; esac

ENC="$(urlenc "$PROJECT")"
PROJ="$(api_get "projects/$ENC" 2>/dev/null)" || fail "$EX_NOT_FOUND" not_found "project not found or not visible: $PROJECT"
PID="$(printf '%s' "$PROJ" | jq -r '.id')"
LINKS_PATH="projects/$ENC/issues/$SOURCE/links"
LINKS="$(api_get "$LINKS_PATH" 2>/dev/null)" || fail "$EX_NOT_FOUND" not_found "source issue #$SOURCE not found in $PROJECT"

BASE="$(jq -cn --argjson s "$SOURCE" --argjson t "$TARGET" --arg rt "$TYPE" '{source_iid: $s, target_iid: $t, requested_type: $rt}')"
EXISTING="$(printf '%s' "$LINKS" | jq -c --argjson pid "$PID" --argjson t "$TARGET" '[.[] | select(.project_id == $pid and .iid == $t)] | first // null')"
if [ "$EXISTING" != null ]; then
  result "$(jq -cn --argjson b "$BASE" --argjson e "$EXISTING" '$b + {existing: true, link_type: $e.link_type}')"
  exit 0
fi
if [ "$DRY" = true ]; then
  result "$(jq -cn --argjson b "$BASE" --argjson cur "$LINKS" '$b + {dry_run: true, current: $cur, proposed: {source_iid: $b.source_iid, target_iid: $b.target_iid, link_type: $b.requested_type}}')"
  exit 0
fi

ERRF="$(mktemp "${TMPDIR:-/tmp}/silkops-link.XXXXXX")"; trap 'rm -f "$ERRF"' EXIT
post() { glab_ro api -X POST "$LINKS_PATH" -f "target_project_id=$PID" -f "target_issue_iid=$TARGET" -f "link_type=$1" 2>"$ERRF"; }

FALLBACK=null; FINAL="$TYPE"
if ! OUT="$(post "$TYPE")"; then
  ERRTXT="$(cat "$ERRF")"
  if [ "$TYPE" = blocks ] && [[ "$ERRTXT" =~ 403|400|Forbidden|Bad\ Request ]]; then
    err "link_type=blocks rejected by the API (tier-gated); falling back to relates_to"
    OUT="$(post relates_to)" || fail "$EX_OTHER" link_failed "could not create the fallback relates_to link: $(cat "$ERRF")" "$BASE"
    FALLBACK='"relates_to"'; FINAL=relates_to
  elif [[ "$ERRTXT" =~ 409|Conflict ]]; then
    LINKS="$(api_get "$LINKS_PATH" 2>/dev/null || echo '[]')"
    EXISTING="$(printf '%s' "$LINKS" | jq -c --argjson pid "$PID" --argjson t "$TARGET" '[.[] | select(.project_id == $pid and .iid == $t)] | first // {link_type: null}')"
    result "$(jq -cn --argjson b "$BASE" --argjson e "$EXISTING" '$b + {existing: true, link_type: $e.link_type}')"
    exit 0
  else
    fail "$EX_OTHER" link_failed "could not create the link: $ERRTXT" "$BASE"
  fi
fi
result "$(jq -cn --argjson b "$BASE" --arg lt "$FINAL" --argjson fb "$FALLBACK" --argjson o "$OUT" \
  '$b + {existing: false, link_type: $lt, fallback: $fb, link: $o}
   + (if $fb != null then {depends_on_line: "Depends on #\($b.target_iid)"} else {} end)')"
