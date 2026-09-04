#!/usr/bin/env bash
# schedule.sh — pipeline schedules with cron frequency guard (plan U4).
#
# Usage: schedule.sh --project <group/project> list
#        schedule.sh --project <group/project> validate --cron "<expr>" [--allow-frequent]
#        schedule.sh --project <group/project> create --description <d> --cron "<expr>" --ref <branch>
#                    [--timezone <tz>] [--allow-frequent] [--var K=V]... [--dry-run]
#
# A cron that fires more than once per day (any minute or hour field that is not a
# single fixed number) is refused with exit 7 `cron_too_frequent` unless --allow-frequent.
# `list` reports owner and next_run_at under the session identity; `create` writes
# via api_settings (settings token). --dry-run shows current schedules + the proposed one.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
# shellcheck source=lib/token.sh
. "$(dirname "$0")/lib/token.sh"
# shellcheck source=lib/glab.sh
. "$(dirname "$0")/lib/glab.sh"

usage() { fail "$EX_USAGE" usage "usage: schedule.sh --project <group/project> (list | validate --cron <expr> | create --description <d> --cron <expr> --ref <branch> [--timezone <tz>] [--var K=V]...) [--allow-frequent] [--dry-run]${1:+ — $1}"; }

PROJECT=""; CMD=""; DESC=""; CRON=""; REF=""; TZ_NAME="UTC"; ALLOW=false; DRY=false; VARS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --description) [ $# -ge 2 ] || usage; DESC="$2"; shift 2 ;;
    --cron) [ $# -ge 2 ] || usage; CRON="$2"; shift 2 ;;
    --ref) [ $# -ge 2 ] || usage; REF="$2"; shift 2 ;;
    --timezone) [ $# -ge 2 ] || usage; TZ_NAME="$2"; shift 2 ;;
    --var) [ $# -ge 2 ] || usage; [[ "$2" == *=* ]] || usage "--var needs K=V"; VARS+=("$2"); shift 2 ;;
    --allow-frequent) ALLOW=true; shift ;;
    --dry-run) DRY=true; shift ;;
    list|create|validate) [ -z "$CMD" ] || usage "one subcommand only"; CMD="$1"; shift ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
require_project
[ -n "$CMD" ] || usage "subcommand required: list | validate | create"
ENC="$(urlenc "$PROJECT")"

# cron_check <expr> — prints "frequent" or "daily"; usage failure on a malformed expression.
cron_check() {
  local f; read -r -a f <<<"$1"
  [ ${#f[@]} -eq 5 ] || fail "$EX_USAGE" usage "cron must have 5 fields (minute hour day month weekday), got ${#f[@]}: $1"
  local frequent=false
  if [[ "${f[0]}" =~ ^[0-9]+$ ]]; then [ "${f[0]}" -le 59 ] || fail "$EX_USAGE" usage "cron minute out of range: ${f[0]}"; else frequent=true; fi
  if [[ "${f[1]}" =~ ^[0-9]+$ ]]; then [ "${f[1]}" -le 23 ] || fail "$EX_USAGE" usage "cron hour out of range: ${f[1]}"; else frequent=true; fi
  if [ "$frequent" = true ]; then echo frequent; else echo daily; fi
}
validate() {
  local kind; kind="$(cron_check "$CRON")"
  if [ "$kind" = frequent ] && [ "$ALLOW" = false ]; then
    fail "$EX_REFUSED" cron_too_frequent "cron '$CRON' fires more than once per day; pass --allow-frequent to accept that deliberately" \
      "$(jq -cn --arg c "$CRON" '{cron: $c, frequent: true}')"
  fi
  [ "$kind" = frequent ] && FREQUENT=true || FREQUENT=false
}
summarize='map({id, description, ref, cron, cron_timezone, active, next_run_at, owner: {id: .owner.id, username: .owner.username}})'

case "$CMD" in
  list)
    S="$(api_get "projects/$ENC/pipeline_schedules?per_page=100" 2>/dev/null)" || fail "$EX_NOT_FOUND" not_found "could not list pipeline schedules of $PROJECT"
    result "$(printf '%s' "$S" | jq -c --arg p "$PROJECT" "{project: \$p, schedules: $summarize}")"
    ;;
  validate)
    [ -n "$CRON" ] || usage "validate needs --cron"
    validate
    result "$(jq -cn --arg c "$CRON" --argjson f "$FREQUENT" '{cron: $c, frequent: $f, fires_at_most_daily: ($f | not)}')"
    ;;
  create)
    [ -n "$DESC" ] && [ -n "$CRON" ] && [ -n "$REF" ] || usage "create needs --description, --cron and --ref"
    validate
    if [ "$DRY" = false ]; then
      [ -n "${SILKOPS_SETTINGS_TOKEN:-}" ] || fail "$EX_NO_TOKEN" no_token "SILKOPS_SETTINGS_TOKEN is not set (required to create a schedule on $PROJECT)"
    fi
    KEYS="$(printf '%s\n' "${VARS[@]+"${VARS[@]}"}" | jq -Rc '[select(. != "") | {key: split("=")[0]}]' | jq -sc 'add // []')"
    PROPOSED="$(jq -cn --arg d "$DESC" --arg c "$CRON" --arg r "$REF" --arg tz "$TZ_NAME" --argjson v "$KEYS" --argjson f "$FREQUENT" \
      '{description: $d, cron: $c, ref: $r, cron_timezone: $tz, active: true, frequent: $f, variables: $v}')"
    CUR="$(api_get "projects/$ENC/pipeline_schedules?per_page=100" 2>/dev/null || echo '[]')"
    if [ "$DRY" = true ]; then
      result "$(jq -cn --arg p "$PROJECT" --argjson cur "$CUR" --argjson prop "$PROPOSED" "{project: \$p, dry_run: true, current: (\$cur | $summarize), proposed: \$prop}")"
      exit 0
    fi
    RESP="$(api_settings POST "projects/$ENC/pipeline_schedules" -f "description=$DESC" -f "cron=$CRON" -f "ref=$REF" -f "cron_timezone=$TZ_NAME" -f "active=true")" \
      || fail "$EX_OTHER" create_failed "could not create the schedule on $PROJECT" "$PROPOSED"
    SID="$(printf '%s' "$RESP" | jq -r '.id')"
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/silkops-schedule.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
    for kv in "${VARS[@]+"${VARS[@]}"}"; do
      [ -n "$kv" ] || continue
      jq -cn --arg k "${kv%%=*}" --arg v "${kv#*=}" '{key: $k, value: $v}' >"$TMP/var.json"
      api_settings POST "projects/$ENC/pipeline_schedules/$SID/variables" --input "$TMP/var.json" >/dev/null \
        || fail "$EX_OTHER" variable_failed "schedule $SID created but variable ${kv%%=*} could not be set" "$(printf '%s' "$RESP" | jq -c '{id, description}')"
    done
    result "$(printf '%s' "$RESP" | jq -c --argjson v "$KEYS" '{action: "created", id, description, ref, cron, cron_timezone, active, next_run_at, owner: {id: .owner.id, username: .owner.username}, variables: $v}')"
    ;;
esac
