#!/usr/bin/env bash
# schedule.sh — pipeline schedules with cron frequency guard (plan U4).
#
# Usage: schedule.sh --project <group/project> list
#        schedule.sh --project <group/project> validate --cron "<expr>" [--allow-frequent]
#        schedule.sh --project <group/project> create --description <d> --cron "<expr>" --ref <branch>
#                    [--timezone <tz>] [--allow-frequent] [--dry-run]
#                    [--var-file K=<path>]... [--var-env K]...
#        schedule.sh --project <group/project> update --id <schedule id>
#                    [--cron "<expr>"] [--ref <branch>] [--description <d>] [--timezone <tz>]
#                    [--active true|false] [--allow-frequent] [--dry-run]
#
# A cron that fires more than once per day (any minute or hour field that is not a
# single fixed number) is refused with exit 7 `cron_too_frequent` unless --allow-frequent.
# `list` reports owner and next_run_at under the session identity; `create` and `update`
# write via api_settings (settings token). --dry-run shows current + proposed and writes nothing.
# `update` reads the schedule first and aborts (exit 1 `lookup_failed`) on any read failure
# that is not a 404 — a failed read is never "absent"; a 404 is exit 5 `not_found`. It sends
# only the fields that actually differ, names them in `changed`, and writes nothing when none
# do (`action: unchanged`). A schedule owned by another user is flagged (`owner_differs: true`)
# and updated, not refused: that write needs Maintainer and does not transfer ownership.
# Schedule variables are CI/CD variables: their values arrive by file (`--var-file K=<path>`,
# one trailing newline dropped) or environment (`--var-env K` reads SILKOPS_SCHEDULE_VAR_<K>);
# `--var K=V` is refused (exit 2) because argv lands in shell history and transcripts. The
# result reports variable keys only.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
# shellcheck source=lib/token.sh
. "$(dirname "$0")/lib/token.sh"
# shellcheck source=lib/glab.sh
. "$(dirname "$0")/lib/glab.sh"
# shellcheck source=lib/provider.sh
. "$(dirname "$0")/lib/provider.sh"

usage() { fail "$EX_USAGE" usage "usage: schedule.sh --project <group/project> (list | validate --cron <expr> | create --description <d> --cron <expr> --ref <branch> [--timezone <tz>] [--var-file K=<path>]... [--var-env K]... | update --id <schedule id> [--cron <expr>] [--ref <branch>] [--description <d>] [--timezone <tz>] [--active true|false]) [--allow-frequent] [--dry-run]${1:+ — $1}"; }

# VAR_SPECS entries: "file<TAB>K<TAB>path" or "env<TAB>K"; values are never held in argv.
# TZ_GIVEN separates "--timezone UTC" from the create-time default, so `update` can tell
# which fields the operator actually asked to change.
PROJECT=""; CMD=""; DESC=""; CRON=""; REF=""; TZ_NAME="UTC"; TZ_GIVEN=false; ALLOW=false; DRY=false; VAR_SPECS=()
WDIR="$PWD"; TARGET_WF=""
SID=""; ACTIVE=""
var_key_ok() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || usage "variable key must match [A-Za-z_][A-Za-z0-9_]* (got: $1)"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --description) [ $# -ge 2 ] || usage; DESC="$2"; shift 2 ;;
    --cron) [ $# -ge 2 ] || usage; CRON="$2"; shift 2 ;;
    --ref) [ $# -ge 2 ] || usage; REF="$2"; shift 2 ;;
    --timezone) [ $# -ge 2 ] || usage; TZ_NAME="$2"; TZ_GIVEN=true; shift 2 ;;
    --id) [ $# -ge 2 ] || usage; SID="$2"; shift 2 ;;
    --active) [ $# -ge 2 ] || usage; ACTIVE="$2"; shift 2 ;;
    --var|--var=*) fail "$EX_USAGE" usage "--var is refused: variable values never go on argv (shell history, transcripts). Put the value in a file and pass --var-file K=<path>, or export SILKOPS_SCHEDULE_VAR_<K> and pass --var-env K." ;;
    --var-file) [ $# -ge 2 ] || usage; [[ "$2" == *=* ]] || usage "--var-file needs K=<path>"; var_key_ok "${2%%=*}"; VAR_SPECS+=("file"$'\t'"${2%%=*}"$'\t'"${2#*=}"); shift 2 ;;
    --var-env) [ $# -ge 2 ] || usage; var_key_ok "$2"; VAR_SPECS+=("env"$'\t'"$2"); shift 2 ;;
    --allow-frequent) ALLOW=true; shift ;;
    --dir) [ $# -ge 2 ] || usage; WDIR="$2"; shift 2 ;;            # Actions hosts: the checkout holding the workflow files
    --workflow) [ $# -ge 2 ] || usage; TARGET_WF="$2"; shift 2 ;;   # Actions hosts: the workflow the schedule should run
    --dry-run) DRY=true; shift ;;
    list|create|validate|update) [ -z "$CMD" ] || usage "one subcommand only"; CMD="$1"; shift ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
require_project "$PROJECT"
[ -n "$CMD" ] || usage "subcommand required: list | validate | create | update"
# list, create and update read through glab_ro, which needs SILKOPS_CI_TOKEN in CI: check at top level
# so the exit-3 JSON and message reach the real streams (validate is offline).
[ "$CMD" = validate ] || [ "$SILKOPS_PROVIDER" != gitlab ] || require_ci_token
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

if [ "$SILKOPS_PROVIDER" != gitlab ]; then
  # Actions hosts (github, gitea): a schedule is `on: schedule` in a workflow file, a change to
  # ship with the commit and ship-mr skills, never a settings write (docs/providers.md).
  WF_DIR=".github/workflows"; [ "$SILKOPS_PROVIDER" = gitea ] && WF_DIR=".gitea/workflows"
  [ ${#VAR_SPECS[@]} -eq 0 ] || usage "schedule variables are repository variables on this host: use variable.sh"
  case "$CMD" in
    list)
      L='[]'
      for f in "$WDIR/$WF_DIR"/*.yml "$WDIR/$WF_DIR"/*.yaml; do
        [ -f "$f" ] || continue
        while IFS= read -r c; do L="$(printf '%s' "$L" | jq -c --arg id "$f" --arg c "$c" --arg d "$(sed -n 's/^name:[[:space:]]*//p' "$f" | head -1)" '. + [{id: $id, description: $d, cron: $c, ref: null, active: true, owner: null}]')"; done \
          < <(grep -E "^[[:space:]]*-[[:space:]]*cron:" "$f" | sed -E "s/^[^:]*:[[:space:]]*['\"]?//; s/['\"]?[[:space:]]*$//")
      done
      result "$(jq -cn --arg p "$PROJECT" --argjson s "$L" '{project: $p, schedules: $s, source: "workflow files"}')" ;;
    validate)
      [ -n "$CRON" ] || usage "validate needs --cron"; validate
      result "$(jq -cn --arg c "$CRON" --argjson f "$FREQUENT" '{cron: $c, frequent: $f, fires_at_most_daily: ($f | not)}')" ;;
    create)
      if [ -z "$DESC" ] || [ -z "$CRON" ] || [ -z "$REF" ]; then usage "create needs --description, --cron and --ref"; fi
      validate
      SLUG="$(printf '%s' "$DESC" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g')"
      OUT="$WDIR/$WF_DIR/silkops-$SLUG.yml"
      if [ -n "$TARGET_WF" ]; then JOB="  run:\n    uses: ./$WF_DIR/$TARGET_WF\n    secrets: inherit"
      else JOB="  run:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo \"scheduled: $DESC\"  # replace with the job this schedule should run"; fi
      BODY="$(printf '# %s — written by silkops schedule; the schedule lives here, not in a setting\nname: %s\non:\n  schedule:\n    - cron: '"'"'%s'"'"'\n  workflow_dispatch: {}\njobs:\n%b\n' "$DESC" "$DESC" "$CRON" "$JOB")"
      if [ "$DRY" = true ]; then result "$(jq -cn --arg p "$OUT" --arg b "$BODY" --argjson f "$FREQUENT" '{dry_run: true, action: "file_written", path: $p, proposed: $b, frequent: $f}')"; exit 0; fi
      [ ! -e "$OUT" ] || fail "$EX_REFUSED" exists "$OUT already exists; use update --id $OUT --cron …"
      mkdir -p "$(dirname "$OUT")"; printf '%s\n' "$BODY" >"$OUT"
      result "$(jq -cn --arg p "$OUT" --arg r "$REF" --argjson f "$FREQUENT" '{action: "file_written", path: $p, ref: $r, frequent: $f, next: "commit the file and ship it as a change (commit, ship-mr); the schedule is live once merged"}')" ;;
    update)
      if [ -z "$SID" ] || [ ! -f "$SID" ]; then fail "$EX_NOT_FOUND" not_found "--id must be the workflow file path on this host"; fi
      [ -n "$CRON" ] || usage "update on this host changes --cron only"
      validate
      if [ "$DRY" = true ]; then result "$(jq -cn --arg p "$SID" --arg c "$CRON" '{dry_run: true, action: "file_updated", path: $p, proposed: {cron: $c}}')"; exit 0; fi
      sed -i.bak -E "s|^([[:space:]]*-[[:space:]]*cron:).*|\1 '$CRON'|" "$SID" && rm -f "$SID.bak"
      result "$(jq -cn --arg p "$SID" --arg c "$CRON" '{action: "file_updated", path: $p, cron: $c, next: "commit and ship the change"}')" ;;
    *) usage "unknown subcommand: $CMD" ;;
  esac
  exit 0
fi

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
    if [ -z "$DESC" ] || [ -z "$CRON" ] || [ -z "$REF" ]; then usage "create needs --description, --cron and --ref"; fi
    validate
    if [ "$DRY" = false ]; then
      require_settings_token "required to create a schedule on $PROJECT"
    fi
    # Materialise every variable body now (0700 tmp dir), so a missing file or unset env var
    # fails before the schedule itself is created; the value is read by jq from the file or
    # its environment and never becomes a shell word.
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/silkops-schedule.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
    KEYS='[]'; NVARS=0
    for spec in "${VAR_SPECS[@]+"${VAR_SPECS[@]}"}"; do
      [ -n "$spec" ] || continue
      IFS=$'\t' read -r kind k src <<<"$spec"
      NVARS=$((NVARS + 1))
      if [ "$kind" = file ]; then
        [ -f "$src" ] || usage "--var-file $k: file not found: $src"
        jq -Rs --arg k "$k" '{key: $k, value: rtrimstr("\n")}' <"$src" >"$TMP/var-$NVARS.json"
      else
        ENVNAME="SILKOPS_SCHEDULE_VAR_$k"
        [ -n "${!ENVNAME:-}" ] || usage "--var-env $k: $ENVNAME is not set in the environment"
        jq -n --arg k "$k" --arg n "$ENVNAME" '{key: $k, value: env[$n]}' >"$TMP/var-$NVARS.json"
        unset "$ENVNAME"
      fi
      [ "$(jq -r '.value | length' "$TMP/var-$NVARS.json")" -gt 0 ] || usage "variable $k: the value is empty"
      KEYS="$(printf '%s' "$KEYS" | jq -c --arg k "$k" '. + [{key: $k}]')"
    done
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
    for ((i = 1; i <= NVARS; i++)); do
      k="$(jq -r '.key' "$TMP/var-$i.json")"
      api_settings POST "projects/$ENC/pipeline_schedules/$SID/variables" --input "$TMP/var-$i.json" >/dev/null \
        || fail "$EX_OTHER" variable_failed "schedule $SID created but variable $k could not be set" "$(printf '%s' "$RESP" | jq -c '{id, description}')"
    done
    result "$(printf '%s' "$RESP" | jq -c --argjson v "$KEYS" '{action: "created", id, description, ref, cron, cron_timezone, active, next_run_at, owner: {id: .owner.id, username: .owner.username}, variables: $v}')"
    ;;
  update)
    [ -n "$SID" ] || usage "update needs --id <schedule id> (from schedule.sh list)"
    [[ "$SID" =~ ^[0-9]+$ ]] || usage "--id must be a pipeline schedule id (digits only), got: $SID"
    if [ -z "$DESC" ] && [ -z "$CRON" ] && [ -z "$REF" ] && [ "$TZ_GIVEN" = false ] && [ -z "$ACTIVE" ]; then
      usage "update needs at least one of --cron, --ref, --description, --timezone, --active"
    fi
    case "$ACTIVE" in ""|true|false) ;; *) usage "--active takes true or false, got: $ACTIVE" ;; esac
    # The cron guard is the create-time one, applied before anything is read or written.
    [ -z "$CRON" ] || validate
    if [ "$DRY" = false ]; then
      require_settings_token "required to update schedule $SID on $PROJECT"
    fi
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/silkops-schedule.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
    # Fail-closed lookup: only a 404 means the schedule is absent. Any other failure aborts
    # the run — nothing is written on the back of an unverified read.
    if ! api_get "projects/$ENC/pipeline_schedules/$SID" >"$TMP/cur.json" 2>"$TMP/lookup.err"; then
      LERR="$(redact <"$TMP/lookup.err" | tr '\n' ' ')"
      if grep '404' "$TMP/lookup.err" >/dev/null; then
        fail "$EX_NOT_FOUND" not_found "pipeline schedule $SID does not exist on $PROJECT" "$(jq -cn --arg p "$PROJECT" --argjson i "$SID" '{project: $p, id: $i}')"
      fi
      fail "$EX_OTHER" lookup_failed "could not read pipeline schedule $SID of $PROJECT; refusing to write without a successful lookup: $LERR" \
        "$(jq -cn --arg p "$PROJECT" --argjson i "$SID" '{project: $p, id: $i}')"
    fi
    CUR="$(cat "$TMP/cur.json")"
    # Proposed = the given fields only; PATCH is the diff against current, so an unchanged
    # field is never sent and a run with no diff writes nothing at all.
    PROPOSED="$(jq -cn --arg d "$DESC" --arg c "$CRON" --arg r "$REF" --arg tz "$TZ_NAME" --argjson tzg "$TZ_GIVEN" --arg a "$ACTIVE" \
      '(if $d != "" then {description: $d} else {} end)
       + (if $c != "" then {cron: $c} else {} end)
       + (if $r != "" then {ref: $r} else {} end)
       + (if $tzg then {cron_timezone: $tz} else {} end)
       + (if $a != "" then {active: ($a == "true")} else {} end)')"
    PATCH="$(jq -cn --argjson cur "$CUR" --argjson p "$PROPOSED" '$p | with_entries(select(.value != $cur[.key]))')"
    CHANGED="$(printf '%s' "$PATCH" | jq -c 'keys')"
    # Owner is compared against the session identity that just read the schedule. Another
    # user's schedule is flagged, never refused: the write needs Maintainer and leaves
    # ownership (and therefore the job identity the schedule runs under) where it is.
    ME="$(api_get user 2>/dev/null | jq -r '.id // empty' || true)"
    OWNER_DIFFERS="$(jq -n --argjson cur "$CUR" --arg me "${ME:-}" '($me != "" and (($cur.owner.id // null) != ($me | tonumber))) ')"
    OWNER_JSON='{}'
    if [ "$OWNER_DIFFERS" = true ]; then
      err "schedule $SID is owned by $(printf '%s' "$CUR" | jq -r '.owner.username // "another user"'), not the session identity: updating another user's schedule requires Maintainer and does not transfer ownership (it keeps running as its owner)."
      OWNER_JSON='{"owner_differs": true}'
    fi
    REPORT='{id, description, cron, cron_timezone, ref, active, next_run_at, owner: {id: .owner.id, username: .owner.username}}'
    if [ "$DRY" = true ]; then
      result "$(jq -cn --arg p "$PROJECT" --argjson cur "$CUR" --argjson prop "$PROPOSED" --argjson ch "$CHANGED" --argjson o "$OWNER_JSON" \
        "{project: \$p, dry_run: true, action: (if (\$ch | length) > 0 then \"updated\" else \"unchanged\" end), changed: \$ch,
          current: (\$cur | $REPORT), proposed: ((\$cur | $REPORT) + \$prop)} + \$o")"
      exit 0
    fi
    if [ "$CHANGED" = '[]' ]; then
      result "$(jq -cn --arg p "$PROJECT" --argjson cur "$CUR" --argjson o "$OWNER_JSON" \
        "{project: \$p, action: \"unchanged\", changed: []} + (\$cur | $REPORT) + \$o")"
      exit 0
    fi
    printf '%s' "$PATCH" >"$TMP/body.json"
    RESP="$(api_settings PUT "projects/$ENC/pipeline_schedules/$SID" --input "$TMP/body.json")" \
      || fail "$EX_OTHER" update_failed "could not update schedule $SID on $PROJECT" "$(jq -cn --arg p "$PROJECT" --argjson i "$SID" --argjson ch "$CHANGED" '{project: $p, id: $i, changed: $ch}')"
    result "$(printf '%s' "$RESP" | jq -c --arg p "$PROJECT" --argjson ch "$CHANGED" --argjson o "$OWNER_JSON" \
      "{project: \$p, action: \"updated\", changed: \$ch} + ($REPORT) + \$o")"
    ;;
esac
