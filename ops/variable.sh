#!/usr/bin/env bash
# variable.sh — project CI/CD variables; values never on argv, never printed (plan U4).
#
# Usage: variable.sh --project <group/project> list
#        variable.sh --project <group/project> set --key K (--value-file <f> | env SILKOPS_VAR_VALUE)
#                    [--masked | --unmasked] [--protected | --unprotected]
#                    [--allow-unmask] [--allow-unprotect] [--dry-run]
#
# `list` prints keys and flags with every `value` stripped. `set` takes the value from a
# file or SILKOPS_VAR_VALUE only — a `--value` argument is refused (exit 2) because argv
# lands in shell history and session transcripts. The masked/protected flags are tri-state:
# unset inherits the existing variable's flags on update (a rotation never silently demotes
# a masked or protected variable) and means false on create. Lowering masked or protected
# on an existing variable is refused (exit 7 unmask_refused / unprotect_refused) unless
# --allow-unmask / --allow-unprotect is passed. Masked values are checked here before any
# write (>= 8 chars, single line, charset [A-Za-z0-9+/=@:.~-]) and the violated constraint
# is named. The body travels to glab as `--input <file>` (never a -f field). Create or
# update (PUT when the key exists). Writes via api_settings.
# Exit: 0 ok · 2 usage/constraint · 3 token missing · 7 unmask/unprotect refused · 1 other.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
# shellcheck source=lib/token.sh
. "$(dirname "$0")/lib/token.sh"
# shellcheck source=lib/glab.sh
. "$(dirname "$0")/lib/glab.sh"
# shellcheck source=lib/provider.sh
. "$(dirname "$0")/lib/provider.sh"

usage() { fail "$EX_USAGE" usage "usage: variable.sh --project <group/project> (list | set --key K (--value-file <f> | env SILKOPS_VAR_VALUE) [--masked|--unmasked] [--protected|--unprotected] [--allow-unmask] [--allow-unprotect]) [--dry-run]${1:+ — $1}"; }

# MASKED/PROTECTED: "" = not given (inherit on update, false on create), else true|false.
PROJECT=""; CMD=""; KEY=""; VALUE_FILE=""; MASKED=""; PROTECTED=""; ALLOW_UNMASK=false; ALLOW_UNPROTECT=false; DRY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --key) [ $# -ge 2 ] || usage; KEY="$2"; shift 2 ;;
    --value-file) [ $# -ge 2 ] || usage; VALUE_FILE="$2"; shift 2 ;;
    --value|--value=*) fail "$EX_USAGE" usage "--value is refused: variable values never go on argv (shell history, transcripts). Put the value in a file and pass --value-file, or export SILKOPS_VAR_VALUE." ;;
    --masked) MASKED=true; shift ;;
    --unmasked) MASKED=false; shift ;;
    --protected) PROTECTED=true; shift ;;
    --unprotected) PROTECTED=false; shift ;;
    --allow-unmask) ALLOW_UNMASK=true; shift ;;
    --allow-unprotect) ALLOW_UNPROTECT=true; shift ;;
    --dry-run) DRY=true; shift ;;
    list|set) [ -z "$CMD" ] || usage "one subcommand only"; CMD="$1"; shift ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
require_project "$PROJECT"
p_gitlab_only "variable.sh"
[ -n "$CMD" ] || usage "subcommand required: list | set"
# `list` reads under the session identity (glab_ro): in CI that needs SILKOPS_CI_TOKEN — check
# at top level so the exit-3 JSON and message reach the real streams. `set` uses the settings
# token only.
[ "$CMD" != list ] || require_ci_token
ENC="$(urlenc "$PROJECT")"

if [ "$CMD" = list ]; then
  V="$(api_get "projects/$ENC/variables?per_page=100" 2>/dev/null)" || fail "$EX_NOT_FOUND" not_found "could not list variables of $PROJECT (Maintainer needed)"
  result "$(printf '%s' "$V" | jq -c --arg p "$PROJECT" '{project: $p, variables: map(del(.value))}')"
  exit 0
fi

# --- set --------------------------------------------------------------------
[[ "$KEY" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || usage "--key must match [A-Za-z_][A-Za-z0-9_]*"
require_settings_token "required to change variables on $PROJECT"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/silkops-variable.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
# The value becomes a JSON document on disk (0700 dir) and never a shell word passed
# to a child process: read via jq's stdin or env, checked and shaped by jq.
if [ -n "$VALUE_FILE" ]; then
  [ -f "$VALUE_FILE" ] || usage "--value-file not found: $VALUE_FILE"
  jq -Rs 'rtrimstr("\n")' <"$VALUE_FILE" >"$TMP/value.json"   # one trailing newline dropped (editors add it)
elif [ -n "${SILKOPS_VAR_VALUE:-}" ]; then
  jq -n 'env.SILKOPS_VAR_VALUE' >"$TMP/value.json"
else
  usage "set needs --value-file <f> or SILKOPS_VAR_VALUE in the environment"
fi
unset SILKOPS_VAR_VALUE
[ "$(jq -r 'length' "$TMP/value.json")" -gt 0 ] || usage "the value is empty"

# Existence check under the settings token (the session account may lack Maintainer);
# the returned value is stripped before it is held anywhere. Only a 404 means absent.
VPATH="projects/$ENC/variables/$KEY"
if RAW="$(glab_settings api -X GET "$VPATH" 2>"$TMP/get.err")"; then
  CUR="$(printf '%s' "$RAW" | jq -c 'del(.value)')"; unset RAW; ACTION=updated
elif grep '404' "$TMP/get.err" >/dev/null; then
  CUR=null; ACTION=created
else
  fail "$EX_OTHER" lookup_failed "could not check whether $KEY exists on $PROJECT: $(cat "$TMP/get.err")" "$(jq -cn --arg k "$KEY" '{key: $k}')"
fi
# Flags not given inherit from the existing variable (rotating a masked+protected secret
# without re-passing the flags must not demote it); on create they default to false.
CUR_MASKED="$(printf '%s' "$CUR" | jq -r '.masked // false')"
CUR_PROTECTED="$(printf '%s' "$CUR" | jq -r '.protected // false')"
[ -n "$MASKED" ] || MASKED="$CUR_MASKED"
[ -n "$PROTECTED" ] || PROTECTED="$CUR_PROTECTED"
FLAGS="$(jq -cn --arg k "$KEY" --argjson m "$MASKED" --argjson p "$PROTECTED" '{key: $k, masked: $m, protected: $p}')"
if [ "$CUR_MASKED" = true ] && [ "$MASKED" = false ] && [ "$ALLOW_UNMASK" = false ]; then
  fail "$EX_REFUSED" unmask_refused "$KEY is masked on $PROJECT and this write would unmask it (the value would print in job logs); pass --allow-unmask to do that deliberately" \
    "$(jq -cn --arg k "$KEY" --argjson cur "$CUR" --argjson f "$FLAGS" '{key: $k, current: $cur, proposed: $f}')"
fi
if [ "$CUR_PROTECTED" = true ] && [ "$PROTECTED" = false ] && [ "$ALLOW_UNPROTECT" = false ]; then
  fail "$EX_REFUSED" unprotect_refused "$KEY is protected on $PROJECT and this write would unprotect it (unprotected branches could read it); pass --allow-unprotect to do that deliberately" \
    "$(jq -cn --arg k "$KEY" --argjson cur "$CUR" --argjson f "$FLAGS" '{key: $k, current: $cur, proposed: $f}')"
fi
if [ "$MASKED" = true ]; then
  C="$(jq -r 'if length < 8 then "masked_min_length" elif test("\n") then "masked_single_line" elif (test("^[A-Za-z0-9+/=@:.~-]+$") | not) then "masked_charset" else "" end' "$TMP/value.json")"
  [ -z "$C" ] || fail "$EX_USAGE" masked_constraint "value violates the masked-variable constraint '$C' (>= 8 chars, single line, charset [A-Za-z0-9+/=@:.~-])" \
    "$(jq -cn --arg k "$KEY" --arg c "$C" '{key: $k, constraint: $c}')"
fi
if [ "$DRY" = true ]; then
  result "$(jq -cn --arg proj "$PROJECT" --arg a "$ACTION" --argjson cur "$CUR" --argjson f "$FLAGS" \
    '{project: $proj, dry_run: true, action: $a, key: $f.key, current: $cur, proposed: $f,
      flags: {current: (if $cur == null then null else {masked: $cur.masked, protected: $cur.protected} end), proposed: {masked: $f.masked, protected: $f.protected}}}')"
  exit 0
fi
jq -c --argjson f "$FLAGS" '$f + {value: .}' "$TMP/value.json" >"$TMP/body.json"
if [ "$ACTION" = created ]; then
  RESP="$(api_settings POST "projects/$ENC/variables" --input "$TMP/body.json")" || fail "$EX_OTHER" write_failed "could not create variable $KEY on $PROJECT" "$FLAGS"
else
  RESP="$(api_settings PUT "$VPATH" --input "$TMP/body.json")" || fail "$EX_OTHER" write_failed "could not update variable $KEY on $PROJECT" "$FLAGS"
fi
result "$(printf '%s' "$RESP" | jq -c --arg a "$ACTION" --argjson cur "$CUR" '{action: $a, key, masked, protected, variable_type, environment_scope, prior: $cur}')"
