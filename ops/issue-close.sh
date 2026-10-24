#!/usr/bin/env bash
# issue-close.sh — close one issue on the host, optionally after a proof note (#87).
#
# Usage: issue-close.sh --project <group/project> --iid <n> [--note-file <f>] [--dry-run]
#
# Provider-neutral: the note goes through the provider's note verb, the close through
# p_issue_close (GitLab `state_event: close`, GitHub and Gitea `state: closed`). The issue is
# read first: unknown → exit 5; already closed → exit 7 (never a reopen, never a second close).
# The note is posted verbatim; the marker-tagged, deduplicated proof note is `silkops note`.
# A note that fails leaves the issue open. Session identity, never the settings token.
# Result: {iid, web_url, action: closed, prior_state, state, note_id}.
# Exit: 0 ok · 2 usage · 3 token missing (CI) · 5 issue not found · 7 already closed · 1 other.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
# shellcheck source=lib/token.sh
. "$(dirname "$0")/lib/token.sh"
# shellcheck source=lib/glab.sh
. "$(dirname "$0")/lib/glab.sh"
# shellcheck source=lib/provider.sh
. "$(dirname "$0")/lib/provider.sh"

usage() { fail "$EX_USAGE" usage "usage: issue-close.sh --project <group/project> --iid <n> [--note-file <f>] [--dry-run]${1:+ — $1}"; }

PROJECT=""; IID=""; NOTE_FILE=""; DRY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --iid) [ $# -ge 2 ] || usage; IID="$2"; shift 2 ;;
    --note-file) [ $# -ge 2 ] || usage; NOTE_FILE="$2"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
require_project "$PROJECT"
[[ "$IID" =~ ^[0-9]+$ ]] || usage "--iid must be a number"
if [ -n "$NOTE_FILE" ] && [ ! -f "$NOTE_FILE" ]; then usage "--note-file must name a readable file"; fi
require_ci_token   # top level, so the exit-3 JSON and message reach the real streams
TMP="$(mktemp -d "${TMPDIR:-/tmp}/silkops-iclose.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# --- the issue, by iid: nothing is written without a successful read -------------------------
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
[ "$STATE" != closed ] || fail "$EX_REFUSED" already_closed "issue #$IID is already closed; the harness never reopens an issue or closes it twice" "$IDENT"

NOTE_JSON=null
[ -z "$NOTE_FILE" ] || NOTE_JSON="$(jq -Rsc '{body: .}' <"$NOTE_FILE")"
if [ "$DRY" = true ]; then
  result "$(jq -cn --argjson i "$IDENT" --arg s "$STATE" --argjson n "$NOTE_JSON" '$i + {dry_run: true, action: "closed", current: {state: $s}, proposed: {state: "closed", note: $n}}')"
  exit 0
fi

# --- the note first (its failure leaves the issue open), then the close ----------------------
NOTE_ID=null
if [ "$NOTE_JSON" != null ]; then
  printf '%s\n' "$NOTE_JSON" >"$TMP/note.json"
  NOTE="$(p_note_post "$PROJECT" issue "$IID" "$TMP/note.json")" || fail "$EX_OTHER" note_failed "could not post the note on issue #$IID; the issue stays open" "$IDENT"
  NOTE_ID="$(printf '%s' "$NOTE" | jq -c '.id // null')"
fi
RESP="$(p_issue_close "$PROJECT" "$IID" 2>"$TMP/close.err")" \
  || fail "$EX_OTHER" close_failed "could not close issue #$IID: $(redact <"$TMP/close.err" | tr '\n' ' ' | sed 's/ *$//')" "$(jq -cn --argjson i "$IDENT" --argjson n "$NOTE_ID" '$i + {note_id: $n}')"
result "$(jq -cn --argjson i "$IDENT" --argjson r "$RESP" --arg s "$STATE" --argjson n "$NOTE_ID" \
  '$i + {action: "closed", prior_state: $s, state: ($r.state // "closed"), note_id: $n, web_url: ($r.web_url // $i.web_url)}')"
