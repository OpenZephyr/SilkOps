#!/usr/bin/env bash
# KD3 acceptance audit: every issue and MR on a milestone must carry the harness marker, and
# the session transcript (optional) must contain no hand-written `glab api` / `curl` calls.
# Usage: audit-milestone.sh --project <group/project> --milestone <title> [--transcript <file>] [--strict]
# Result JSON: {ok, milestone, checked, unmarked:[…], transcript_hits:[…]}; --strict exits 1 when
# anything is unmarked or the transcript has hits.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../ops/lib/prelude.sh
. "$ROOT/ops/lib/prelude.sh"
# shellcheck source=../ops/lib/token.sh
. "$ROOT/ops/lib/token.sh"
# shellcheck source=../ops/lib/glab.sh
. "$ROOT/ops/lib/glab.sh"
PROJECT=""; MILESTONE=""; TRANSCRIPT=""; STRICT=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || fail "$EX_USAGE" usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --milestone) [ $# -ge 2 ] || fail "$EX_USAGE" usage "--milestone needs a value"; MILESTONE="$2"; shift 2 ;;
    --transcript) [ $# -ge 2 ] || fail "$EX_USAGE" usage "--transcript needs a value"; TRANSCRIPT="$2"; shift 2 ;;
    --strict) STRICT=true; shift ;;
    *) fail "$EX_USAGE" usage "unknown argument: $1" ;;
  esac
done
require_project "$PROJECT"
[ -n "$MILESTONE" ] || fail "$EX_USAGE" usage "--milestone <title> is required"
enc="$(urlenc "$PROJECT")"
menc="$(urlenc "$MILESTONE")"
ms="$(api_get "projects/$enc/milestones?search=$menc&per_page=100" | jq -c --arg t "$MILESTONE" '[.[] | select(.title == $t)] | .[0] // empty')"
[ -n "$ms" ] || fail "$EX_NOT_FOUND" not_found "milestone not found: $MILESTONE"
issues="$(api_get "projects/$enc/issues?milestone=$menc&state=all&per_page=100")"
mrs="$(api_get "projects/$enc/merge_requests?milestone=$menc&state=all&per_page=100")"
unmarked="$(jq -n --argjson i "$issues" --argjson m "$mrs" '
  [ ($i[] | {type:"issue", iid, title, web_url, description}),
    ($m[] | {type:"merge_request", iid, title, web_url, description}) ]
  | map(select((.description // "") | test("<!-- silkops:") | not))
  | map(del(.description))')"
checked="$(jq -n --argjson i "$issues" --argjson m "$mrs" '($i | length) + ($m | length)')"
hits='[]'
if [ -n "$TRANSCRIPT" ]; then
  [ -f "$TRANSCRIPT" ] || fail "$EX_NOT_FOUND" not_found "transcript not found: $TRANSCRIPT"
  # Hand-written glue: glab api / curl against the instance outside ops/. Lines that mention
  # ops/ scripts are the harness itself and do not count.
  # grep exits 1 on no match; a clean transcript is the success case, not a failure (pipefail).
  hits="$({ grep -nE '(^|[^/a-z])(glab api|curl )' "$TRANSCRIPT" || [ $? -eq 1 ]; } | { grep -vE 'ops/[a-z-]+\.(sh|py)' || [ $? -eq 1 ]; } | redact | jq -R -s -c 'split("\n") | map(select(length > 0))')"
fi
res="$(jq -n --argjson ms "$ms" --argjson u "$unmarked" --argjson h "$hits" --argjson c "$checked" \
  '{milestone: {id: $ms.id, title: $ms.title, web_url: $ms.web_url}, checked: $c, unmarked: $u, transcript_hits: $h,
    clean: (($u | length) == 0 and ($h | length) == 0)}')"
result "$res"
if $STRICT && [ "$(jq -r .clean <<<"$res")" != "true" ]; then exit 1; fi
