#!/usr/bin/env bash
# milestone-sync.sh — one call files or re-syncs a whole issue set (v0.2 U9; #24, #34, #36).
#
# Usage: milestone-sync.sh --project <group/project> --run <id>
#          (--plan <plan.md> | --issues <set.json>) [--milestone <title>] [--dry-run]
#
# --plan: units from plan-units.py (the fact layers' `plan` key may set the shape, #78). A
#   unified plan is one milestone, the plan's `title:` (or --milestone); a milestones plan
#   (`## M<n> · <title>`) is one milestone per heading, each unit filed under its own, with
#   cross-milestone `depends_on` edges linked like any other. Each unit becomes
#   "<id> — <title>" with the issue-body template; `depends_on` → blocks links.
# --issues: {"plan": "adhoc-<slug>", "milestone": <title|null>, "issues": [{unit, title, body,
#   labels[], assignee, due_date, blocked_by[unit...]}]}: the marker namespace for sets with no
#   plan; bodies verbatim; blocked_by resolved to real iids after the upsert pass.
# Bodies may carry `{{link:<path>}}`, `{{link:<path>:<a>}}` or `{{link:<path>:<a>-<b>}}` (#90):
#   expand-links.py turns each into the host's permalink pinned at --sha (default: HEAD of the
#   cwd; outside a git repo there is no sha, so placeholders stay verbatim and stderr says so).
#   The project URL is --project-url, else SILKOPS_PROJECT_URL, else the provider's known host.
# Composes milestone-upsert.sh, issue-upsert.sh and issue-link.sh; never merges, never edits a
# closed issue (those scripts refuse). One JSON report: {milestone, milestones[], issues[], links[]}
# (`milestone` is the single one, null when the plan declares several).
# --dry-run (#88): each issue entry carries `proposed {title, labels[], description, milestone}`,
#   the exact untruncated text an outward filing would send; --show is the same plus a readable
#   preview of every issue (title, labels, body) on stderr.
# Exit: 0 ok · 2 usage · 5 plan/set not found · 7 refused by a sub-script · 1 other.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
OPS="$(cd "$(dirname "$0")" && pwd)"

usage() { fail "$EX_USAGE" usage "usage: milestone-sync.sh --project <group/project> --run <id> (--plan <plan.md> | --issues <set.json>) [--milestone <title>] [--sha <ref>] [--project-url <url>] [--dry-run | --show]${1:+ — $1}"; }
PROJECT=""; RUN=""; PLAN_PATH=""; SET_PATH=""; MILESTONE=""; DRY=false; SHA=""; PROJECT_URL=""; SHOW=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --run) [ $# -ge 2 ] || usage; RUN="$2"; shift 2 ;;
    --plan) [ $# -ge 2 ] || usage; PLAN_PATH="$2"; shift 2 ;;
    --issues) [ $# -ge 2 ] || usage; SET_PATH="$2"; shift 2 ;;
    --milestone) [ $# -ge 2 ] || usage; MILESTONE="$2"; shift 2 ;;
    --sha) [ $# -ge 2 ] || usage; SHA="$2"; shift 2 ;;
    --project-url) [ $# -ge 2 ] || usage; PROJECT_URL="$2"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    --show) DRY=true; SHOW=true; shift ;;   # a dry run plus a readable preview per issue on stderr (#88)
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

# --- pinned links (#90): the sha every {{link:…}} is pinned at, and the project URL -----------------
# An explicit --sha that does not resolve is a usage error; the default is HEAD when the cwd is a
# repo, else no expansion at all (placeholders stay verbatim, one stderr note).
if [ -n "$SHA" ]; then
  SHA="$(git rev-parse --verify --quiet "${SHA}^{commit}" 2>/dev/null)" || usage "--sha does not resolve to a commit here"
elif ! SHA="$(git rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null)"; then
  SHA=""; err "note: not inside a git repository and no --sha; {{link:…}} placeholders are left verbatim"
fi
[ -n "$PROJECT_URL" ] || PROJECT_URL="$(project_url_default "$PROJECT")"
# expand_links <body-file> — in place; a no-op without a sha, a project URL or a placeholder
expand_links() {
  [ -n "$SHA" ] && [ -n "$PROJECT_URL" ] && grep -F '{{link:' "$1" >/dev/null || return 0
  python3 "$OPS/expand-links.py" --project-url "$PROJECT_URL" --provider "$SILKOPS_PROVIDER" --sha "$SHA" <"$1" >"$1.x" \
    || fail "$EX_OTHER" expand_failed "expand-links.py failed on $(basename "$1")"
  mv "$1.x" "$1"
}

# --- the set: {plan, milestone, issues[{unit,title,body,labels,assignee,due_date,blocked_by}]} ---
if [ -n "$PLAN_PATH" ]; then
  [ -f "$PLAN_PATH" ] || fail "$EX_NOT_FOUND" not_found "plan not found: $PLAN_PATH"
  # the fact layers may declare the repo's own plan shape (`plan` key, #78); plan-units.py reads them
  FACTS_ARGS=(); while IFS= read -r f; do FACTS_ARGS+=(--facts "$f"); done < <(facts_paths)
  UNITS="$(python3 "$OPS/plan-units.py" "$PLAN_PATH" "${FACTS_ARGS[@]}")" || fail "$EX_OTHER" plan_unparsed "plan-units.py could not parse $PLAN_PATH"
  [ "$(printf '%s' "$UNITS" | jq -r '.count')" -gt 0 ] || fail "$EX_NOT_FOUND" no_units "no unit headings (### U<N>. or ### M<n>-<nn>) in $PLAN_PATH"
  MULTI=false; [ "$(printf '%s' "$UNITS" | jq -r '.milestones | length')" = 0 ] || MULTI=true
  if [ "$MULTI" = true ]; then
    # one milestone per `## M<n>` heading; each unit is filed under its own
    [ -z "$MILESTONE" ] || usage "the plan declares its milestones (## M<n>); --milestone applies to single-milestone plans"
    TITLE=""
  else
    TITLE="${MILESTONE:-$(sed -n 's/^title:[[:space:]]*//p' "$PLAN_PATH" | head -1)}"
    [ -n "$TITLE" ] || usage "the plan has no title: frontmatter; pass --milestone"
  fi
  SET="$(printf '%s' "$UNITS" | jq -c --arg t "$TITLE" '{plan: .plan, milestone: (if $t == "" then null else $t end),
      milestones: [.milestones[] | {id, title}], issues: [.units[] | {
      unit: .id, title: (.id + " — " + .title), labels: ((.labels // []) + ["silkops"]), assignee: null, due_date: null, blocked_by: .depends_on,
      milestone: (if $t != "" then $t else .milestone end), milestone_id: (.milestone_id // null),
      body: ("**Goal.** " + .goal + "\n\n**Requirements.** " + (if (.requirements|length) > 0 then (.requirements|join(", ")) else "—" end)
             + "\n\n**Files.**\n" + ([.files[] | "- `" + . + "`"] | join("\n"))
             + (if (.acceptance // "") != "" then "\n\n**Acceptance.** " + .acceptance else "\n\n**Verification.** " + .verification end)
             + "\n\n**Depends on.** " + (if (.depends_on|length) > 0 then (.depends_on|join(", ")) else "—" end) + "\n")}]}')"
else
  [ -f "$SET_PATH" ] || fail "$EX_NOT_FOUND" not_found "issue set not found: $SET_PATH"
  SET="$(jq -c 'if (.plan|type) == "string" and (.issues|type) == "array" then . else error("set needs plan and issues[]") end' "$SET_PATH" 2>/dev/null)" \
    || fail "$EX_USAGE" usage "--issues must be a JSON object with plan (string) and issues (array)"
  [ -z "$MILESTONE" ] || SET="$(printf '%s' "$SET" | jq -c --arg t "$MILESTONE" '.milestone = $t')"
  SET="$(printf '%s' "$SET" | jq -c '.milestones = (if .milestone then [{id: "milestone", title: .milestone}] else [] end) | .issues |= map(.milestone = .milestone // null)')"
  SET="$(printf '%s' "$SET" | jq -c '.milestone as $t | .issues |= map(if .milestone == null then .milestone = $t else . end)')"
fi
PLAN="$(printf '%s' "$SET" | jq -r '.plan')"
N="$(printf '%s' "$SET" | jq -r '.issues | length')"

# --- milestones: one upsert per distinct title (one for a unified plan, one per ## M<n>) -----
# MS_MAP: title -> the title to pass to issue-upsert ("" when the milestone is only proposed in a
# dry run: it does not exist yet, so the issue dry runs cannot resolve it by title, #68).
MS_LIST="$(printf '%s' "$SET" | jq -c '[.milestones[], (.issues[] | select(.milestone != null) | {id: (.milestone_id // "milestone"), title: .milestone})]
  | reduce .[] as $m ([]; if any(.[]; .title == $m.title) then . else . + [$m] end)')"   # plan order, not sorted
MSS='[]'; MS_MAP='{}'
for ((k = 0; k < $(printf '%s' "$MS_LIST" | jq -r length); k++)); do
  mid="$(printf '%s' "$MS_LIST" | jq -r ".[$k].id")"; mtitle="$(printf '%s' "$MS_LIST" | jq -r ".[$k].title")"
  # shellcheck disable=SC2016  # the backticks are markdown, not a command
  printf 'Milestone for `%s`. One issue per unit; identity by marker.\n' "$PLAN" >"$TMP/ms.md"
  MS="$(bash "$OPS/milestone-upsert.sh" --project "$PROJECT" --title "$mtitle" --plan "$PLAN" --run "$RUN" --marker-unit "$mid" --description-file "$TMP/ms.md" "${DRYARG[@]}")" \
    || { rc=$?; err "milestone-upsert failed for '$mtitle'"; printf '%s\n' "$MS"; exit "$rc"; }
  MS="$(printf '%s' "$MS" | jq -c --arg t "$mtitle" --arg id "$mid" '{title: $t, iid, id, action, web_url} + (if .dry_run == true and .action == "created" then {proposed: true} else {} end) + (if $id != "milestone" then {plan_id: $id} else {} end)')"
  MSS="$(jq -cn --argjson a "$MSS" --argjson m "$MS" '$a + [$m]')"
  pass_title="$mtitle"; [ "$(printf '%s' "$MS" | jq -r '.proposed // false')" != true ] || pass_title=""
  MS_MAP="$(printf '%s' "$MS_MAP" | jq -c --arg t "$mtitle" --arg p "$pass_title" '. + {($t): $p}')"
done
# `milestone` keeps its single-milestone shape (null when the plan declares several)
MS="$(printf '%s' "$MSS" | jq -c 'if length == 1 then .[0] else null end')"

# --- issues: one upsert each, collecting unit -> iid ----------------------------------
ISSUES='[]'; MAP='{}'
for ((i = 0; i < N; i++)); do
  IS="$(printf '%s' "$SET" | jq -c ".issues[$i]")"
  unit="$(printf '%s' "$IS" | jq -r '.unit')"; ulabel="$(printf '%s' "$unit" | tr '[:upper:]' '[:lower:]')"
  printf '%s' "$IS" | jq -r '.body' >"$TMP/body-$i.md"; expand_links "$TMP/body-$i.md"
  labels="$(printf '%s' "$IS" | jq -r --arg u "$ulabel" '((.labels // []) + [$u]) | unique | join(",")')"
  args=(--project "$PROJECT" --marker-unit "$unit" --plan "$PLAN" --run "$RUN" --title "$(printf '%s' "$IS" | jq -r '.title')" --body-file "$TMP/body-$i.md" --labels "$labels")
  ims="$(printf '%s' "$IS" | jq -r '.milestone // ""')"; [ -z "$ims" ] || ims="$(printf '%s' "$MS_MAP" | jq -r --arg t "$ims" '.[$t] // ""')"
  [ -z "$ims" ] || args+=(--milestone "$ims")
  a="$(printf '%s' "$IS" | jq -r '.assignee // ""')"; [ -z "$a" ] || args+=(--assignee "$a")
  d="$(printf '%s' "$IS" | jq -r '.due_date // ""')"; [ -z "$d" ] || args+=(--due-date "$d")
  R="$(bash "$OPS/issue-upsert.sh" "${args[@]}" "${DRYARG[@]}")" || { rc=$?; err "issue-upsert failed for $unit"; printf '%s\n' "$R"; exit "$rc"; }
  iid="$(printf '%s' "$R" | jq -c '.iid // null')"
  MAP="$(printf '%s' "$MAP" | jq -c --arg u "$unit" --argjson iid "$iid" '. + {($u): $iid}')"
  # the review surface before an outward filing (#88): the exact text, never truncated. An
  # update's dry run proposes only the description, so title and labels come from the set.
  PROPOSED="$(printf '%s' "$R" | jq -c --argjson is "$IS" --arg l "$labels" 'if .proposed then {title: (.proposed.title // $is.title),
    labels: ((.proposed.labels // $l) | split(",") | map(select(. != ""))), description: .proposed.description, milestone: ($is.milestone // null)} else null end')"
  if [ "$SHOW" = true ] && [ "$PROPOSED" != null ]; then
    { printf -- '--- %s  [%s]\nlabels: %s\n\n' "$(printf '%s' "$PROPOSED" | jq -r '.title')" "$(printf '%s' "$R" | jq -r '.action')" \
        "$(printf '%s' "$PROPOSED" | jq -r '.labels | join(", ")')"; printf '%s' "$PROPOSED" | jq -r '.description'; } >&2
  fi
  ISSUES="$(jq -cn --argjson a "$ISSUES" --arg u "$unit" --argjson r "$R" --argjson is "$IS" --argjson p "$PROPOSED" --argjson d "$DRY" \
    '$a + [{unit: $u, iid: ($r.iid // null), action: $r.action, web_url: ($r.web_url // null), milestone: ($is.milestone // null), assignee: ($r.assignee // $is.assignee // null), due_date: ($r.due_date // $is.due_date // null), blocked_by_units: ($is.blocked_by // [])}
           + (if $d then {proposed: $p} else {} end)]')"
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
result "$(jq -cn --arg p "$PLAN" --argjson ms "$MS" --argjson mss "$MSS" --argjson is "$ISSUES" --argjson ln "$LINKS" --argjson d "$DRY" '{plan: $p, milestone: $ms, milestones: $mss, issues: $is, links: $ln, dry_run: $d}')"
