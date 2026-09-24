#!/usr/bin/env bash
# token-check.sh — pre-flight: who am I, what can I do on <project> (plan U3, KTD3).
#
# Usage: token-check.sh --project <group/project> [--for settings|ci|session] [--expect-role <Role>]
#
# v0.2 U11 (#27, #35): SILKOPS_OPERATOR (a username) is resolved to a real user and reported as
# operator {username, id, exists}; a name that does not exist is reported, so a session never
# writes a dead @mention. SILKOPS_OPERATOR_GROUP is reported with in_operator_group (the
# project's namespace is that group or below it) — the disclosure default for markers and
# trailers. --expect-role exits 4 when the identity's role is below it.
#
#   session (default)  the operator's own glab identity. Additionally reports
#                      can_merge_protected / can_push_protected — informational
#                      only (KTD3: token-check reports merge rights, never refuses).
#   settings           SILKOPS_SETTINGS_TOKEN; fails 4 unless role >= Maintainer (40).
#   ci                 SILKOPS_CI_TOKEN (the identity CI jobs run under).
#
# Result (stdout, one JSON object): identity {id, username, name, bot}, token
# {scopes, expires_at, active} or null when the self endpoint is unavailable,
# project {id, path, default_branch}, access_level + role, and for the session
# identity the protected-branch booleans (null when the endpoint is forbidden).
# Exit: 0 ok · 2 usage · 3 token missing · 4 role · 5 project not found · 1 other.
# The token never appears in output, argv, or URLs.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
# shellcheck source=lib/token.sh
. "$(dirname "$0")/lib/token.sh"
# shellcheck source=lib/glab.sh
. "$(dirname "$0")/lib/glab.sh"
# shellcheck source=lib/provider.sh
. "$(dirname "$0")/lib/provider.sh"

usage() { fail "$EX_USAGE" usage "usage: token-check.sh --project <group/project> [--for settings|ci|session] [--expect-role <Role>]${1:+ — $1}"; }

PROJECT=""; FOR="session"; EXPECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --for) [ $# -ge 2 ] || usage "--for needs a value"; FOR="$2"; shift 2 ;;
    --for=*) FOR="${1#--for=}"; shift ;;
    --expect-role) [ $# -ge 2 ] || usage "--expect-role needs a value"; EXPECT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
require_project "$PROJECT"
case "$FOR" in settings|ci|session) ;; *) usage "--for must be settings, ci or session (got: $FOR)" ;; esac
# --for session reads through glab_ro, which needs the CI token in CI: check at top level so the
# exit-3 JSON and message reach the real streams (the other identities carry their own check).
[ "$FOR" != session ] || require_ci_token

# api <path> — GET under the identity being checked. Token presence is checked
# by the wrapper (exit 3) before glab is ever spawned.
api() { p_raw "$FOR" "$1"; }   # the provider's identity probe under the chosen token
export _GH_PROJECT="$PROJECT"
# api_opt <path> — like api, but an HTTP error (404/403) yields "null" and
# exit 0. stderr is dropped: the wrapper already redacts it, and a missing
# optional endpoint is not worth a warning line.
api_opt() { api "$1" 2>/dev/null || echo null; }

role_level() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    owner) echo 50 ;; maintainer) echo 40 ;; developer) echo 30 ;; reporter) echo 20 ;;
    planner) echo 15 ;; guest) echo 10 ;; *) echo "" ;;
  esac
}
role_name() {
  case "$1" in
    50) echo Owner ;; 40) echo Maintainer ;; 30) echo Developer ;; 20) echo Reporter ;;
    15) echo Planner ;; 10) echo Guest ;; 5) echo "Minimal Access" ;; 0|null|"") echo none ;;
    *) echo "level-$1" ;;
  esac
}

EXPECT_LEVEL=""; if [ -n "$EXPECT" ]; then EXPECT_LEVEL="$(role_level "$EXPECT")"; [ -n "$EXPECT_LEVEL" ] || usage "--expect-role must be Owner, Maintainer, Developer, Reporter, Planner or Guest"; fi
# The token-presence check inside the wrapper fires on this first call.
IDENTITY="$(p_identity_as "$FOR")" || fail "$EX_NO_TOKEN" no_identity "could not resolve the ${FOR} identity (glab api user failed); is a token configured?"
USER_ID="$(printf '%s' "$IDENTITY" | jq -r '.id')"
if [ -z "$USER_ID" ] || [ "$USER_ID" = null ]; then fail "$EX_OTHER" bad_identity "glab api user returned no id"; fi

TOKEN_INFO="$(api_opt personal_access_tokens/self)"

ENC="$(urlenc "$PROJECT")"
PROJ="$(p_project_get_as "$FOR" "$PROJECT" 2>/dev/null)" || fail "$EX_NOT_FOUND" not_found "project not found or not visible to this identity: $PROJECT" \
  "$(jq -n --arg p "$PROJECT" '{project: $p}')"
PROJECT_ID="$(printf '%s' "$PROJ" | jq -r '.id')"

MEMBER="$(p_member_level_as "$FOR" "$PROJECT" "$USER_ID" 2>/dev/null || echo null)"
LEVEL="$(printf '%s' "$MEMBER" | jq -r '.access_level // 0')"
ROLE="$(role_name "$LEVEL")"

CAN_MERGE=null; CAN_PUSH=null
if [ "$FOR" = session ]; then
  # Informational only (KTD3): the session account may hold merge rights on main;
  # the never-merge property is enforced by skill text and the verification gate.
  PB="$(p_protection_read_as "$FOR" "$PROJECT_ID" 2>/dev/null || echo null)"
  if [ "$PB" != null ]; then
    # An access entry grants the user when it names them, or when it is a role
    # level (>0) at or below the user's own level. 0 = "No one".
    CAN_MERGE="$(printf '%s' "$PB" | jq -c --argjson uid "$USER_ID" --argjson lvl "$LEVEL" \
      '[.[] | .merge_access_levels // [] | .[] | (.user_id == $uid) or ((.access_level // 0) > 0 and (.access_level // 0) <= $lvl)] | any')"
    CAN_PUSH="$(printf '%s' "$PB" | jq -c --argjson uid "$USER_ID" --argjson lvl "$LEVEL" \
      '[.[] | .push_access_levels // [] | .[] | (.user_id == $uid) or ((.access_level // 0) > 0 and (.access_level // 0) <= $lvl)] | any')"
  fi
fi

# --- operator (#35) and group (#27, KTD4) -----------------------------------------------
OPERATOR=null
if [ -n "${SILKOPS_OPERATOR:-}" ]; then
  OU="$(api_opt "users?username=$(urlenc "$SILKOPS_OPERATOR")")"
  OPERATOR="$(printf '%s' "$OU" | jq -c --arg u "$SILKOPS_OPERATOR" '(if type == "array" then [.[] | select(.username == $u)] | first else null end) as $m
    | {username: $u, id: ($m.id // null), exists: ($m != null)}')"
fi
OGROUP="${SILKOPS_OPERATOR_GROUP:-}"
IN_GROUP=null
if [ -n "$OGROUP" ]; then
  case "$(printf '%s' "$PROJ" | jq -r '.path_with_namespace')" in "$OGROUP"/*) IN_GROUP=true ;; *) IN_GROUP=false ;; esac
fi

REPORT="$(jq -n \
  --argjson operator "$OPERATOR" --arg ogroup "$OGROUP" --argjson in_group "$IN_GROUP" \
  --argjson protection "$(printf '%s' "${PB:-null}" | p_protection_summary)" \
  --arg for "$FOR" --arg role "$ROLE" --argjson level "$LEVEL" \
  --argjson identity "$IDENTITY" --argjson token "$TOKEN_INFO" --argjson proj "$PROJ" \
  --argjson can_merge "$CAN_MERGE" --argjson can_push "$CAN_PUSH" \
  '{for: $for,
    identity: {id: $identity.id, username: $identity.username, name: $identity.name, bot: ($identity.bot // false)},
    token: (if $token == null then null else {scopes: $token.scopes, expires_at: $token.expires_at, active: $token.active} end),
    project: {id: $proj.id, path: $proj.path_with_namespace, default_branch: $proj.default_branch},
    access_level: $level, role: $role,
    can_merge_protected: $can_merge, can_push_protected: $can_push, protection: $protection,
    operator: $operator, operator_group: (if $ogroup == "" then null else $ogroup end), in_operator_group: $in_group}')"
if [ -n "$EXPECT_LEVEL" ] && [ "$LEVEL" -lt "$EXPECT_LEVEL" ]; then
  fail "$EX_ROLE" insufficient_role "needs $EXPECT on $PROJECT (identity is $ROLE)" "$REPORT"
fi

if [ "$FOR" = settings ] && [ "$LEVEL" -lt 40 ]; then
  fail "$EX_ROLE" insufficient_role "needs Maintainer on $PROJECT (settings identity is $ROLE)" "$REPORT"
fi
result "$REPORT"
