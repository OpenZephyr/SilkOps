#!/usr/bin/env bash
# milestone-upsert.sh — find or create a plan's milestone, idempotent by exact title (plan U4, KTD5).
#
# Usage: milestone-upsert.sh --project <group/project> --title <t> --plan <basename> --run <id>
#          [--description-file <f>] [--marker-unit <unit, default milestone>] [--dry-run]
#
# Identity: the exact title among this project's milestones (`milestones?search=<title>`, then
# filtered on `.title == <t>`; titles are unique per project). A lookup that fails aborts the run:
# nothing is written without a successful search. A closed milestone is never edited (exit 7).
# The description is marker + managed region wrapping the description file (or the marker alone);
# an existing milestone has ONLY its managed region replaced and the marker's run= refreshed —
# text outside the region is byte-identical; an identical region means zero writes.
# Reports {action: created|updated|unchanged, id, iid, web_url, title}. Session identity (the
# operator owns the milestone), never the settings token.
# Exit: 0 ok · 2 usage · 3 token missing (CI) · 7 closed milestone / ambiguous title
#       1 other (lookup or write failed).
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
# shellcheck source=lib/token.sh
. "$(dirname "$0")/lib/token.sh"
# shellcheck source=lib/glab.sh
. "$(dirname "$0")/lib/glab.sh"

usage() { fail "$EX_USAGE" usage "usage: milestone-upsert.sh --project <group/project> --title <t> --plan <basename> --run <id> [--description-file <f>] [--marker-unit <unit>] [--dry-run]${1:+ — $1}"; }

PROJECT=""; TITLE=""; PLAN=""; RUN=""; UNIT="milestone"; DESC_FILE=""; DRY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --title) [ $# -ge 2 ] || usage; TITLE="$2"; shift 2 ;;
    --plan) [ $# -ge 2 ] || usage; PLAN="$2"; shift 2 ;;
    --run) [ $# -ge 2 ] || usage; RUN="$2"; shift 2 ;;
    --marker-unit) [ $# -ge 2 ] || usage; UNIT="$2"; shift 2 ;;
    --description-file) [ $# -ge 2 ] || usage; DESC_FILE="$2"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
require_project
[ -n "$TITLE" ] || usage "--title is required"
[ -n "$PLAN" ] && [ -n "$RUN" ] || usage "--plan and --run are required (the marker carries them)"
[ -n "$UNIT" ] || usage "--marker-unit must not be empty"
if [ -n "$DESC_FILE" ]; then [ -f "$DESC_FILE" ] || usage "--description-file must name a readable file"; fi
require_ci_token   # top level, so the exit-3 JSON and message reach the real streams (the wrappers re-check)

ENC="$(urlenc "$PROJECT")"
MARKER="$(silkops_marker "$PLAN" "$UNIT" "$RUN")"; MARKER="${MARKER%$'\n'}"
BODY=""; [ -n "$DESC_FILE" ] && BODY="$(cat "$DESC_FILE")"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/silkops-milestone.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

# --- find: exact title, this project only ------------------------------------
# Called at top level, never inside $(...), so the failure JSON and message reach the real
# streams. A failed search must never read as "not found" (that is how duplicates get created).
api_get "projects/$ENC/milestones?search=$(urlenc "$TITLE")&state=all&per_page=100" >"$TMP/milestones.json" 2>"$TMP/lookup.err" \
  || fail "$EX_OTHER" lookup_failed "could not search $PROJECT milestones for '$TITLE'; refusing to write without a successful lookup: $(redact <"$TMP/lookup.err" | tr '\n' ' ')"
CANDS="$(jq -c --arg t "$TITLE" 'if type == "array" then [.[] | select(.title == $t)] else [] end' "$TMP/milestones.json")"
[ "$(printf '%s' "$CANDS" | jq -r length)" -le 1 ] \
  || fail "$EX_REFUSED" ambiguous_identity "more than one milestone in $PROJECT is titled '$TITLE'; fix by hand before re-syncing" "$(printf '%s' "$CANDS" | jq -c '{candidates: map({id, iid, state, web_url})}')"
FOUND="$(printf '%s' "$CANDS" | jq -c 'first // null')"

if [ "$FOUND" != null ]; then
  IDENT="$(printf '%s' "$FOUND" | jq -c --arg t "$TITLE" '{id, iid, web_url: (.web_url // null), title: $t}')"
  [ "$(printf '%s' "$FOUND" | jq -r '.state // "active"')" != closed ] \
    || fail "$EX_REFUSED" closed_milestone "milestone '$TITLE' is closed; the harness never edits or reopens a closed milestone" "$IDENT"
  PLANNED="$(managed_region_plan "$FOUND" "$BODY" "$MARKER" "$RUN")"
  if [ "$(printf '%s' "$PLANNED" | jq -r '.changed')" = false ]; then
    result "$(jq -cn --argjson i "$IDENT" '$i + {action: "unchanged"}')"
    exit 0
  fi
  if [ "$DRY" = true ]; then
    result "$(jq -cn --argjson i "$IDENT" --argjson f "$FOUND" --argjson p "$PLANNED" '$i + {dry_run: true, action: "updated", current: {description: ($f.description // "")}, proposed: {description: $p.description}}')"
    exit 0
  fi
  printf '%s' "$PLANNED" | jq -c '{description: .description}' >"$TMP/body.json"
  MID="$(printf '%s' "$FOUND" | jq -r '.id')"
  RESP="$(glab_ro api -X PUT "projects/$ENC/milestones/$MID" --input "$TMP/body.json")" || fail "$EX_OTHER" update_failed "could not update milestone '$TITLE' (id $MID)" "$IDENT"
  result "$(jq -cn --argjson i "$IDENT" --argjson r "$RESP" --argjson f "$FOUND" '$i + {action: "updated", web_url: ($r.web_url // $i.web_url), prior: {description: ($f.description // "")}}')"
  exit 0
fi

# --- create -----------------------------------------------------------------
DESC="$(jq -rn --arg marker "$MARKER" --arg body "$BODY" '$marker + "\n<!-- silkops:managed -->\n" + $body + "\n<!-- /silkops:managed -->\n"')"
if [ "$DRY" = true ]; then
  result "$(jq -cn --arg t "$TITLE" --arg d "$DESC" '{dry_run: true, action: "created", current: null, proposed: {title: $t, description: $d}}')"
  exit 0
fi
jq -cn --arg t "$TITLE" --arg d "$DESC" '{title: $t, description: $d}' >"$TMP/body.json"
RESP="$(glab_ro api -X POST "projects/$ENC/milestones" --input "$TMP/body.json")" || fail "$EX_OTHER" create_failed "could not create milestone '$TITLE' in $PROJECT"
result "$(printf '%s' "$RESP" | jq -c '{action: "created", id: .id, iid: .iid, web_url: (.web_url // null), title: .title, state: (.state // null)}')"
