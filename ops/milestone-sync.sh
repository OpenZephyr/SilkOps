#!/usr/bin/env bash
# milestone-sync.sh — one call files or re-syncs a whole issue set (v0.2 U9; #24, #34, #36).
#
# Usage: milestone-sync.sh --project <group/project> --run <id>
#          (--plan <plan.md> | --issues <set.json>) [--milestone <title>] [--dry-run]
#
# --plan: units from plan-units.py; the milestone is the plan's `title:` (or --milestone);
#   each unit becomes "U<N> — <title>" with the issue-body template; `depends_on` → blocks links.
# --issues: {"plan": "adhoc-<slug>", "milestone": <title|null>, "issues": [{unit, title, body,
#   labels[], assignee, due_date, blocked_by[unit...]}]}: the marker namespace for sets with no
#   plan; bodies verbatim; blocked_by resolved to real iids after the upsert pass.
# Composes milestone-upsert.sh, issue-upsert.sh and issue-link.sh; never merges, never edits a
# closed issue (those scripts refuse). One JSON report: {milestone, issues[], links[]}.
# Exit: 0 ok · 2 usage · 5 plan/set not found · 7 refused by a sub-script · 1 other.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
OPS="$(cd "$(dirname "$0")" && pwd)"

usage() { fail "$EX_USAGE" usage "usage: milestone-sync.sh --project <group/project> --run <id> (--plan <plan.md> | --issues <set.json>) [--milestone <title>] [--dry-run]${1:+ — $1}"; }
PROJECT=""; RUN=""; PLAN_PATH=""; SET_PATH=""; MILESTONE=""; DRY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --run) [ $# -ge 2 ] || usage; RUN="$2"; shift 2 ;;
    --plan) [ $# -ge 2 ] || usage; PLAN_PATH="$2"; shift 2 ;;
    --issues) [ $# -ge 2 ] || usage; SET_PATH="$2"; shift 2 ;;
    --milestone) [ $# -ge 2 ] || usage; MILESTONE="$2"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
require_project "$PROJECT"
[ -n "$RUN" ] || usage "--run is required"
if [ -n "$PLAN_PATH" ] && [ -n "$SET_PATH" ]; then usage "pass exactly one of --plan or --issues"; fi
[ -n "$PLAN_PATH$SET_PATH" ] || usage "pass exactly one of --plan or --issues"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/silkops-msync.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
DRYARG=(); [ "$DRY" = false ] || DRYARG=(--dry-run)

# --- the set: {plan, milestone, issues[{unit,title,body,labels,assignee,due_date,blocked_by}]} ---
if [ -n "$PLAN_PATH" ]; then
  [ -f "$PLAN_PATH" ] || fail "$EX_NOT_FOUND" not_found "plan not found: $PLAN_PATH"
  UNITS="$(python3 "$OPS/plan-units.py" "$PLAN_PATH")" || fail "$EX_OTHER" plan_unparsed "plan-units.py could not parse $PLAN_PATH"
  [ "$(printf '%s' "$UNITS" | jq -r '.count')" -gt 0 ] || fail "$EX_NOT_FOUND" no_units "no ### U<N>. units in $PLAN_PATH"
  TITLE="${MILESTONE:-$(sed -n 's/^title:[[:space:]]*//p' "$PLAN_PATH" | head -1)}"
  [ -n "$TITLE" ] || usage "the plan has no title: frontmatter; pass --milestone"
  SET="$(printf '%s' "$UNITS" | jq -c --arg t "$TITLE" '{plan: .plan, milestone: $t, issues: [.units[] | {
      unit: .id, title: (.id + " — " + .title), labels: ["silkops"], assignee: null, due_date: null, blocked_by: .depends_on,
      body: ("**Goal.** " + .goal + "\n\n**Requirements.** " + (if (.requirements|length) > 0 then (.requirements|join(", ")) else "—" end)
             + "\n\n**Files.**\n" + ([.files[] | "- `" + . + "`"] | join("\n"))
             + "\n\n**Verification.** " + .verification
             + "\n\n**Depends on.** " + (if (.depends_on|length) > 0 then (.depends_on|join(", ")) else "—" end) + "\n")}]}')"
else
  [ -f "$SET_PATH" ] || fail "$EX_NOT_FOUND" not_found "issue set not found: $SET_PATH"
  SET="$(jq -c 'if (.plan|type) == "string" and (.issues|type) == "array" then . else error("set needs plan and issues[]") end' "$SET_PATH" 2>/dev/null)" \
    || fail "$EX_USAGE" usage "--issues must be a JSON object with plan (string) and issues (array)"
  [ -z "$MILESTONE" ] || SET="$(printf '%s' "$SET" | jq -c --arg t "$MILESTONE" '.milestone = $t')"
fi
PLAN="$(printf '%s' "$SET" | jq -r '.plan')"
MS_TITLE="$(printf '%s' "$SET" | jq -r '.milestone // ""')"
N="$(printf '%s' "$SET" | jq -r '.issues | length')"

# --- milestone ------------------------------------------------------------------
MS=null
if [ -n "$MS_TITLE" ]; then
  # shellcheck disable=SC2016  # the backticks are markdown, not a command
  printf 'Milestone for `%s`. One issue per unit; identity by marker.\n' "$PLAN" >"$TMP/ms.md"
  MS="$(bash "$OPS/milestone-upsert.sh" --project "$PROJECT" --title "$MS_TITLE" --plan "$PLAN" --run "$RUN" --description-file "$TMP/ms.md" "${DRYARG[@]}")" \
    || { rc=$?; err "milestone-upsert failed for '$MS_TITLE'"; printf '%s\n' "$MS"; exit "$rc"; }
  MS="$(printf '%s' "$MS" | jq -c --arg t "$MS_TITLE" '{title: $t, iid, id, action, web_url}')"
fi

# --- issues: one upsert each, collecting unit -> iid ----------------------------------
ISSUES='[]'; MAP='{}'
for ((i = 0; i < N; i++)); do
  IS="$(printf '%s' "$SET" | jq -c ".issues[$i]")"
  unit="$(printf '%s' "$IS" | jq -r '.unit')"; ulabel="$(printf '%s' "$unit" | tr '[:upper:]' '[:lower:]')"
  printf '%s' "$IS" | jq -r '.body' >"$TMP/body-$i.md"
  labels="$(printf '%s' "$IS" | jq -r --arg u "$ulabel" '((.labels // []) + [$u]) | unique | join(",")')"
  args=(--project "$PROJECT" --marker-unit "$unit" --plan "$PLAN" --run "$RUN" --title "$(printf '%s' "$IS" | jq -r '.title')" --body-file "$TMP/body-$i.md" --labels "$labels")
  [ -z "$MS_TITLE" ] || args+=(--milestone "$MS_TITLE")
  a="$(printf '%s' "$IS" | jq -r '.assignee // ""')"; [ -z "$a" ] || args+=(--assignee "$a")
  d="$(printf '%s' "$IS" | jq -r '.due_date // ""')"; [ -z "$d" ] || args+=(--due-date "$d")
  R="$(bash "$OPS/issue-upsert.sh" "${args[@]}" "${DRYARG[@]}")" || { rc=$?; err "issue-upsert failed for $unit"; printf '%s\n' "$R"; exit "$rc"; }
  iid="$(printf '%s' "$R" | jq -c '.iid // null')"
  MAP="$(printf '%s' "$MAP" | jq -c --arg u "$unit" --argjson iid "$iid" '. + {($u): $iid}')"
  ISSUES="$(jq -cn --argjson a "$ISSUES" --arg u "$unit" --argjson r "$R" --argjson is "$IS" \
    '$a + [{unit: $u, iid: ($r.iid // null), action: $r.action, web_url: ($r.web_url // null), assignee: ($r.assignee // $is.assignee // null), due_date: ($r.due_date // $is.due_date // null), blocked_by_units: ($is.blocked_by // [])}]')"
done

# --- links: every blocked_by edge, resolved to iids (second pass) ----------------------------
LINKS='[]'
for ((i = 0; i < N; i++)); do
  tgt_unit="$(printf '%s' "$ISSUES" | jq -r ".[$i].unit")"; tgt="$(printf '%s' "$MAP" | jq -c --arg u "$tgt_unit" '.[$u] // null')"
  for dep in $(printf '%s' "$ISSUES" | jq -r ".[$i].blocked_by_units[]"); do
    src="$(printf '%s' "$MAP" | jq -c --arg u "$dep" '.[$u] // null')"
    if [ "$src" = null ] || [ "$tgt" = null ]; then
      LINKS="$(jq -cn --argjson a "$LINKS" --arg s "$dep" --arg t "$tgt_unit" '$a + [{source_unit: $s, target_unit: $t, skipped: "no iid (dry run or unknown unit)"}]')"; continue
    fi
    L="$(bash "$OPS/issue-link.sh" --project "$PROJECT" --source "$src" --target "$tgt" --type blocks "${DRYARG[@]}")" || { rc=$?; err "issue-link failed: $dep -> $tgt_unit"; printf '%s\n' "$L"; exit "$rc"; }
    LINKS="$(jq -cn --argjson a "$LINKS" --argjson l "$L" --arg s "$dep" --arg t "$tgt_unit" '$a + [{source_unit: $s, target_unit: $t, source_iid: $l.source_iid, target_iid: $l.target_iid, link_type: ($l.link_type // $l.requested_type), existing: ($l.existing // false), fallback: ($l.fallback // null)}]')"
  done
done
ISSUES="$(printf '%s' "$ISSUES" | jq -c --argjson m "$MAP" '[.[] | .blocked_by = [.blocked_by_units[] | $m[.] // empty] | del(.blocked_by_units)]')"
result "$(jq -cn --arg p "$PLAN" --argjson ms "$MS" --argjson is "$ISSUES" --argjson ln "$LINKS" --argjson d "$DRY" '{plan: $p, milestone: $ms, issues: $is, links: $ln, dry_run: $d}')"
