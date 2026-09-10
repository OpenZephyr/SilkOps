#!/usr/bin/env bash
# allowlist.sh — CI/CD job-token allow-list of a factory project (plan U4, KTD9 phase A).
#
# Usage: allowlist.sh --project <factory> get
#        allowlist.sh --project <factory> add --consumer <group/project> [--group] [--dry-run]
#
# Reads (`get`, the pre-flight listing) run under the session identity; the POST runs
# under SILKOPS_SETTINGS_TOKEN via api_settings. A consumer that resolves to a GROUP is
# refused (exit 2) unless --group is passed explicitly — group allow-listing widens the
# scope to every project under it, so it is never inferred. Idempotent: an entry already
# present yields ok + existing:true and no write. --dry-run shows current + proposed.
# Exit: 0 ok · 2 usage · 3 token missing · 5 consumer not found · 1 other.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
# shellcheck source=lib/token.sh
. "$(dirname "$0")/lib/token.sh"
# shellcheck source=lib/glab.sh
. "$(dirname "$0")/lib/glab.sh"

usage() { fail "$EX_USAGE" usage "usage: allowlist.sh --project <factory> (get | add --consumer <group/project> [--group]) [--dry-run]${1:+ — $1}"; }

PROJECT=""; CMD=""; CONSUMER=""; GROUP=false; DRY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --consumer) [ $# -ge 2 ] || usage "--consumer needs a value"; CONSUMER="$2"; shift 2 ;;
    --group) GROUP=true; shift ;;
    --dry-run) DRY=true; shift ;;
    get|add) [ -z "$CMD" ] || usage "one subcommand only"; CMD="$1"; shift ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
require_project "$PROJECT"
[ -n "$CMD" ] || usage "subcommand required: get | add"
require_ci_token   # top level, so the exit-3 JSON and message reach the real streams (the wrappers re-check)

ENC="$(urlenc "$PROJECT")"
LIST_P="projects/$ENC/job_token_scope/allowlist"
LIST_G="projects/$ENC/job_token_scope/groups_allowlist"

current() {
  local p g
  p="$(api_get "$LIST_P?per_page=100" 2>/dev/null)" || fail "$EX_NOT_FOUND" not_found "could not read the job-token allow-list of $PROJECT (project missing, or Maintainer needed)"
  g="$(api_get "$LIST_G?per_page=100" 2>/dev/null || echo '[]')"
  jq -cn --argjson p "$p" --argjson g "$g" \
    '{projects: ($p | map({id, path: .path_with_namespace, web_url})), groups: ($g | map({id, path: .full_path, web_url}))}'
}

if [ "$CMD" = get ]; then
  result "$(jq -cn --arg proj "$PROJECT" --argjson c "$(current)" '{project: $proj} + $c')"
  exit 0
fi

# --- add --------------------------------------------------------------------
[ -n "$CONSUMER" ] || usage "add needs --consumer <group/project>"
if [ "$DRY" = false ]; then
  require_settings_token "required to change the allow-list of $PROJECT"
fi
CENC="$(urlenc "$CONSUMER")"
if [ "$GROUP" = true ]; then
  G="$(api_get "groups/$CENC" 2>/dev/null)" || fail "$EX_NOT_FOUND" not_found "group not found or not visible: $CONSUMER"
  TID="$(printf '%s' "$G" | jq -r '.id')"; KIND=group; FIELD=target_group_id; WPATH="$LIST_G"; LISTKEY=groups
else
  if P="$(api_get "projects/$CENC" 2>/dev/null)"; then
    TID="$(printf '%s' "$P" | jq -r '.id')"; KIND=project; FIELD=target_project_id; WPATH="$LIST_P"; LISTKEY=projects
  elif api_get "groups/$CENC" >/dev/null 2>&1; then
    fail "$EX_USAGE" usage "$CONSUMER is a group, not a project; allow-listing a whole group requires the explicit --group flag"
  else
    fail "$EX_NOT_FOUND" not_found "consumer project not found or not visible: $CONSUMER"
  fi
fi
CUR="$(current)"
PROPOSED="$(jq -cn --arg k "$KIND" --arg f "$FIELD" --argjson id "$TID" --arg c "$CONSUMER" '{kind: $k, consumer: $c} + {($f): $id}')"
BASE="$(jq -cn --arg proj "$PROJECT" --arg k "$KIND" --arg c "$CONSUMER" --argjson cur "$CUR" '{project: $proj, kind: $k, consumer: $c, current: $cur}')"
if printf '%s' "$CUR" | jq -e --arg key "$LISTKEY" --argjson id "$TID" '.[$key] | any(.id == $id)' >/dev/null; then
  result "$(jq -cn --argjson b "$BASE" --argjson p "$PROPOSED" '$b + {existing: true, entry: $p}')"
  exit 0
fi
if [ "$DRY" = true ]; then
  result "$(jq -cn --argjson b "$BASE" --argjson p "$PROPOSED" '$b + {dry_run: true, existing: false, proposed: $p}')"
  exit 0
fi
RESP="$(api_settings POST "$WPATH" -f "$FIELD=$TID")" || fail "$EX_OTHER" allowlist_failed "could not add $CONSUMER to the allow-list of $PROJECT" "$BASE"
result "$(jq -cn --argjson b "$BASE" --argjson r "$RESP" --argjson p "$PROPOSED" '$b + {existing: false, added: ($p + $r)}')"
