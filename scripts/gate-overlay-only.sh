#!/usr/bin/env bash
# Overlay gate (v0.2 KTD2): the private overlay branch (void-mirror) may only ADD files under
# overlay/. Any path outside it that differs from the base is refused, so core never drifts
# on the private branch and main always merges in cleanly.
#
# Usage: gate-overlay-only.sh [--base <ref>]   (default origin/main; run inside the checkout)
# Result: {ok, base, head, outside_overlay: [paths]}. Exit 0 clean · 7 refused · 5 base unknown · 2 usage.
set -euo pipefail
# shellcheck source=../ops/lib/prelude.sh
. "$(dirname "${BASH_SOURCE[0]}")/../ops/lib/prelude.sh"
BASE="origin/main"
while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || fail "$EX_USAGE" usage "--base needs a value"; BASE="$2"; shift 2 ;;
    *) fail "$EX_USAGE" usage "usage: gate-overlay-only.sh [--base <ref>]" ;;
  esac
done
git rev-parse --verify -q "$BASE^{commit}" >/dev/null || fail "$EX_NOT_FOUND" not_found "base ref not found: $BASE"
head="$(git rev-parse --short HEAD)"
outside="$(git diff --name-only "$BASE...HEAD" -- . ':!overlay/' | jq -Rc . | jq -sc .)"
if [ "$outside" = "[]" ]; then
  result "$(jq -cn --arg b "$BASE" --arg h "$head" '{base: $b, head: $h, outside_overlay: []}')"
else
  err "paths outside overlay/ differ from $BASE: $(printf '%s' "$outside" | jq -r 'join(" ")')"
  fail "$EX_REFUSED" refused "the overlay branch may only add files under overlay/" \
    "$(jq -cn --arg b "$BASE" --arg h "$head" --argjson o "$outside" '{base: $b, head: $h, outside_overlay: $o}')"
fi
