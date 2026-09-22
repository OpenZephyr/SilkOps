#!/usr/bin/env bash
# note.sh — post a marker-tagged note on an issue or MR (plan U4, KTD5).
#
# Usage: note.sh --project <group/project> (--issue <iid> | --mr <iid>) --body-file <f>
#                --marker-unit <U-ID> --plan <basename> --run <id> [--dedupe-key <k>] [--dry-run]
#
# The note body is marker + optional `<!-- silkops:key=<k> -->` + the file verbatim.
# With --dedupe-key, a note already carrying the same plan/unit marker and key yields
# ok + existing:true and nothing is posted; a failed note listing aborts (exit 1 lookup_failed)
# rather than posting a possible duplicate. Session identity, never the settings token.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
# shellcheck source=lib/token.sh
. "$(dirname "$0")/lib/token.sh"
# shellcheck source=lib/glab.sh
. "$(dirname "$0")/lib/glab.sh"

usage() { fail "$EX_USAGE" usage "usage: note.sh --project <group/project> (--issue <iid> | --mr <iid>) --body-file <f> --marker-unit <U-ID> --plan <basename> --run <id> [--dedupe-key <k>] [--dry-run]${1:+ — $1}"; }

PROJECT=""; ISSUE=""; MR=""; BODY_FILE=""; UNIT=""; PLAN=""; RUN=""; KEY=""; DRY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --issue) [ $# -ge 2 ] || usage; ISSUE="$2"; shift 2 ;;
    --mr) [ $# -ge 2 ] || usage; MR="$2"; shift 2 ;;
    --body-file) [ $# -ge 2 ] || usage; BODY_FILE="$2"; shift 2 ;;
    --marker-unit) [ $# -ge 2 ] || usage; UNIT="$2"; shift 2 ;;
    --plan) [ $# -ge 2 ] || usage; PLAN="$2"; shift 2 ;;
    --run) [ $# -ge 2 ] || usage; RUN="$2"; shift 2 ;;
    --dedupe-key) [ $# -ge 2 ] || usage; KEY="$2"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
require_project "$PROJECT"
if [ -n "$ISSUE" ] && [ -n "$MR" ]; then usage "pass exactly one of --issue or --mr"; fi
[ -n "$ISSUE$MR" ] || usage "pass exactly one of --issue or --mr"
[[ "$ISSUE$MR" =~ ^[0-9]+$ ]] || usage "--issue/--mr must be an iid"
if ! { [ -n "$UNIT" ] && [ -n "$PLAN" ] && [ -n "$RUN" ]; }; then usage "--marker-unit, --plan and --run are required"; fi
if ! { [ -n "$BODY_FILE" ] && [ -f "$BODY_FILE" ]; }; then usage "--body-file must name a readable file"; fi
require_ci_token   # top level, so the exit-3 JSON and message reach the real streams (the wrappers re-check)

ENC="$(urlenc "$PROJECT")"
if [ -n "$ISSUE" ]; then NOTEABLE=issue; IID="$ISSUE"; NPATH="projects/$ENC/issues/$IID/notes"
else NOTEABLE=merge_request; IID="$MR"; NPATH="projects/$ENC/merge_requests/$IID/notes"; fi
# SILKOPS_MARKER=off (KTD3): no marker line; a --dedupe-key becomes a neutral key comment.
if marker_enabled; then
  MARKER_ON=true; MARKER="$(silkops_marker "$PLAN" "$UNIT" "$RUN")"$'\n'   # $(...) strips the marker's newline
  KEYLINE=""; [ -n "$KEY" ] && KEYLINE="<!-- silkops:key=$KEY -->"$'\n'
else
  MARKER_ON=false; MARKER=""
  KEYLINE=""; [ -n "$KEY" ] && KEYLINE="<!-- note-key=$KEY -->"$'\n'
fi
# The body stays a JSON object end to end: $(...) would strip the file's final newline.
NOTE_JSON="$(jq -Rsc --arg pre "$MARKER$KEYLINE" '{body: ($pre + .)}' <"$BODY_FILE")"
IDENT="$(jq -cn --arg n "$NOTEABLE" --argjson iid "$IID" --argjson m "$MARKER_ON" '{noteable: $n, iid: $iid, marker: $m}')"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/silkops-note.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

if [ -n "$KEY" ]; then
  # The listing is what the no-duplicate promise rests on: a failed GET aborts, it is never
  # read as "no notes yet". Without --dedupe-key no listing is made at all.
  api_get "$NPATH?per_page=100" >"$TMP/notes.json" 2>"$TMP/lookup.err" \
    || fail "$EX_OTHER" lookup_failed "could not list the notes of $NOTEABLE $IID for dedupe key '$KEY'; refusing to write without a successful lookup: $(redact <"$TMP/lookup.err" | tr '\n' ' ')" "$IDENT"
  if [ "$MARKER_ON" = true ]; then
    EXISTING="$(jq -c --arg p "$PLAN" --arg u "$UNIT" --arg k "<!-- silkops:key=$KEY -->" \
      '[.[] | select((.body // "") | contains("<!-- silkops:") and contains("plan=\($p) unit=\($u) run=") and contains($k))] | first // null' "$TMP/notes.json")"
  else
    EXISTING="$(jq -c --arg k "${KEYLINE%$'\n'}" '[.[] | select((.body // "") | contains($k))] | first // null' "$TMP/notes.json")"
  fi
  if [ "$EXISTING" != null ]; then
    result "$(jq -cn --argjson i "$IDENT" --argjson e "$EXISTING" --arg k "$KEY" '$i + {existing: true, id: $e.id, dedupe_key: $k}')"
    exit 0
  fi
fi
if [ "$DRY" = true ]; then
  result "$(jq -cn --argjson i "$IDENT" --argjson n "$NOTE_JSON" '$i + {dry_run: true, existing: false, proposed: $n}')"
  exit 0
fi
printf '%s\n' "$NOTE_JSON" >"$TMP/body.json"
RESP="$(glab_ro api -X POST "$NPATH" --input "$TMP/body.json")" || fail "$EX_OTHER" note_failed "could not post the note on $NOTEABLE $IID" "$IDENT"
result "$(jq -cn --argjson i "$IDENT" --argjson r "$RESP" --arg k "$KEY" '$i + {existing: false, id: $r.id} + (if $k != "" then {dedupe_key: $k} else {} end)')"
