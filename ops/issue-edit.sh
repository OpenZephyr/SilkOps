#!/usr/bin/env bash
# issue-edit.sh — set the assignee, due date or milestone of one existing issue (#84).
#
# Usage: issue-edit.sh --project <group/project> --iid <n>
#          [--assignee <username> | --assign-operator] [--due-date YYYY-MM-DD]
#          [--milestone <title|id>] [--dry-run]
#
# The issue is found by iid, never by marker, and read first: a closed issue is refused
# (exit 7), an unknown one is exit 5. Usernames resolve to ids through the provider
# (p_user_id_by_username; GitHub and Gitea assign by login). --assign-operator takes
# `operator_username` from the fact layers (.silkops/facts.json first), then $SILKOPS_OPERATOR.
# Only fields that differ are sent; nothing to change is zero writes. After the write the
# issue is read back and reported as stored: {iid, assignees[], due_date, milestone, changed[]}.
# @handles in the description the provider does not know are warned about and listed in
# `dead_mentions[]` (never a failure). No description write, so no marker is involved.
# Exit: 0 ok · 2 usage / no operator · 3 token missing (CI) · 5 issue, user or milestone not
#       found · 7 closed issue · 1 other (lookup or write failed).
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
# shellcheck source=lib/token.sh
. "$(dirname "$0")/lib/token.sh"
# shellcheck source=lib/glab.sh
. "$(dirname "$0")/lib/glab.sh"
# shellcheck source=lib/provider.sh
. "$(dirname "$0")/lib/provider.sh"

usage() { fail "$EX_USAGE" usage "usage: issue-edit.sh --project <group/project> --iid <n> [--assignee <username> | --assign-operator] [--due-date YYYY-MM-DD] [--milestone <title|id>] [--dry-run]${1:+ — $1}"; }

PROJECT=""; IID=""; ASSIGNEE=""; OPERATOR=false; DUE=""; MILESTONE=""; DRY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --iid) [ $# -ge 2 ] || usage; IID="$2"; shift 2 ;;
    --assignee) [ $# -ge 2 ] || usage; ASSIGNEE="$2"; shift 2 ;;
    --assign-operator) OPERATOR=true; shift ;;
    --due-date) [ $# -ge 2 ] || usage; DUE="$2"; shift 2 ;;
    --milestone) [ $# -ge 2 ] || usage; MILESTONE="$2"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
require_project "$PROJECT"
[[ "$IID" =~ ^[0-9]+$ ]] || usage "--iid must be a number"
if [ -n "$ASSIGNEE" ] && [ "$OPERATOR" = true ]; then usage "pass --assignee or --assign-operator, not both"; fi
[ -z "$DUE" ] || [[ "$DUE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || usage "--due-date must be YYYY-MM-DD"
if [ -z "$ASSIGNEE" ] && [ "$OPERATOR" = false ] && [ -z "$DUE" ] && [ -z "$MILESTONE" ]; then
  usage "nothing to change: pass --assignee, --assign-operator, --due-date or --milestone"
fi

# --- operator: the fact layers, most specific first, then the environment -------------------
if [ "$OPERATOR" = true ]; then
  while IFS= read -r f; do
    [ -n "$ASSIGNEE" ] && break
    ASSIGNEE="$(jq -r '.operator_username // empty' "$f" 2>/dev/null || true)"
  done < <(facts_paths)
  [ -n "$ASSIGNEE" ] || ASSIGNEE="${SILKOPS_OPERATOR:-}"
  [ -n "$ASSIGNEE" ] || fail "$EX_USAGE" no_operator "--assign-operator needs operator_username in .silkops/facts.json (or a fact layer) or SILKOPS_OPERATOR in the environment; neither is set"
fi
require_ci_token   # top level, so the exit-3 JSON and message reach the real streams
TMP="$(mktemp -d "${TMPDIR:-/tmp}/silkops-iedit.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# lookup <what> <out-file> <verb> [args…] — a GET into a file, or abort: nothing is written
# without a successful read. Top level only, so the failure JSON reaches the real streams.
lookup() {
  local what="$1" out="$2"; shift 2
  "$@" >"$out" 2>"$TMP/lookup.err" \
    || fail "$EX_OTHER" lookup_failed "could not $what: $(redact <"$TMP/lookup.err" | tr '\n' ' ')"
}

# --- the issue, by iid ---------------------------------------------------------------------
if ! p_issue_get "$PROJECT" "$IID" >"$TMP/issue.json" 2>"$TMP/lookup.err"; then
  if grep -E '404|[Nn]ot [Ff]ound' "$TMP/lookup.err" >/dev/null; then
    fail "$EX_NOT_FOUND" not_found "issue #$IID not found in $PROJECT"
  fi
  fail "$EX_OTHER" lookup_failed "could not read issue #$IID: $(redact <"$TMP/lookup.err" | tr '\n' ' ')"
fi
jq -e '.iid' "$TMP/issue.json" >/dev/null 2>&1 || fail "$EX_NOT_FOUND" not_found "issue #$IID not found in $PROJECT"
STATE="$(jq -r '.state' "$TMP/issue.json")"
WEB="$(jq -r '.web_url // ""' "$TMP/issue.json")"
IDENT="$(jq -cn --argjson iid "$IID" --arg w "$WEB" '{iid: $iid, web_url: $w}')"
[ "$STATE" != closed ] || fail "$EX_REFUSED" closed_issue "issue #$IID is closed; the harness never edits or reopens a closed issue" "$IDENT"

# --- the description's @handles the host does not know (warn, never fail) -----------------
DEAD="$(dead_mentions "$(jq -r '.description // ""' "$TMP/issue.json")")"
[ "$DEAD" = '[]' ] || err "warning: issue #$IID mentions handles the host does not know: $(printf '%s' "$DEAD" | jq -r 'map("@" + .) | join(", ")')"

# --- desired fields and what differs ------------------------------------------------------
CHANGED='[]'; BODY='{}'
if [ -n "$ASSIGNEE" ]; then
  lookup "look up user '$ASSIGNEE'" "$TMP/uid" p_user_id_by_username "$ASSIGNEE"
  AID="$(tr -d '\n' <"$TMP/uid")"
  [ -n "$AID" ] || fail "$EX_NOT_FOUND" not_found "no user named $ASSIGNEE on $SILKOPS_PROVIDER; refusing to assign a dead handle"
  if ! jq -e --arg u "$ASSIGNEE" '[.assignees[]?.username] == [$u]' "$TMP/issue.json" >/dev/null; then
    CHANGED="$(printf '%s' "$CHANGED" | jq -c '. + ["assignee"]')"
    case "$AID" in *[!0-9]*) BODY="$(printf '%s' "$BODY" | jq -c --arg a "$AID" '. + {assignee_ids: [$a]}')" ;;
                   *) BODY="$(printf '%s' "$BODY" | jq -c --argjson a "$AID" '. + {assignee_ids: [$a]}')" ;; esac
  fi
fi
if [ -n "$DUE" ] && [ "$(jq -r '.due_date // ""' "$TMP/issue.json")" != "$DUE" ]; then
  CHANGED="$(printf '%s' "$CHANGED" | jq -c '. + ["due_date"]')"
  BODY="$(printf '%s' "$BODY" | jq -c --arg d "$DUE" '. + {due_date: $d}')"
fi
MILESTONE_ID=null
if [ -n "$MILESTONE" ]; then
  if [[ "$MILESTONE" =~ ^[0-9]+$ ]]; then MILESTONE_ID="$MILESTONE"
  else
    lookup "look up milestone '$MILESTONE' in $PROJECT" "$TMP/milestones.json" p_milestone_by_title "$PROJECT" "$MILESTONE"
    MILESTONE_ID="$(jq -r --arg t "$MILESTONE" '[.[] | select(.title == $t)] | first | .id // "null"' "$TMP/milestones.json")"
    [ "$MILESTONE_ID" != null ] || fail "$EX_NOT_FOUND" not_found "milestone not found: $MILESTONE"
  fi
  if [ "$(jq -r '.milestone.id // "null"' "$TMP/issue.json")" != "$MILESTONE_ID" ]; then
    CHANGED="$(printf '%s' "$CHANGED" | jq -c '. + ["milestone"]')"
    BODY="$(printf '%s' "$BODY" | jq -c --argjson m "$MILESTONE_ID" '. + {milestone_id: $m}')"
  fi
fi

# read_back <issue-json-file> — the fields as the host stores them
read_back() { jq -c '{assignees: [.assignees[]?.username], due_date: (.due_date // null), milestone: (.milestone.title // null)}' "$1"; }
if [ "$CHANGED" = '[]' ]; then
  result "$(jq -cn --argjson i "$IDENT" --argjson rb "$(read_back "$TMP/issue.json")" --argjson dm "$DEAD" '$i + {action: "unchanged", changed: []} + $rb + {dead_mentions: $dm}')"
  exit 0
fi
if [ "$DRY" = true ]; then
  result "$(jq -cn --argjson i "$IDENT" --argjson rb "$(read_back "$TMP/issue.json")" --argjson c "$CHANGED" --argjson b "$BODY" --argjson dm "$DEAD" \
    '$i + {dry_run: true, action: "updated", changed: $c, current: $rb, proposed: $b, dead_mentions: $dm}')"
  exit 0
fi
printf '%s' "$BODY" >"$TMP/body.json"
p_issue_update "$PROJECT" "$IID" "$TMP/body.json" >"$TMP/updated.json" || fail "$EX_OTHER" update_failed "could not update issue #$IID" "$IDENT"
# read back: what the host stored, not what we sent (a stale read falls back to the write's answer)
p_issue_get "$PROJECT" "$IID" >"$TMP/after.json" 2>/dev/null || cp "$TMP/updated.json" "$TMP/after.json"
result "$(jq -cn --argjson i "$IDENT" --argjson rb "$(read_back "$TMP/after.json")" --argjson c "$CHANGED" --argjson dm "$DEAD" \
  '$i + {action: "updated", changed: $c} + $rb + {dead_mentions: $dm}')"
