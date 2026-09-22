#!/usr/bin/env bash
# inbox.sh — what people filed on the public GitHub mirror, read-only (v0.2 U6, KD3).
#
# Usage: inbox.sh --repo <owner/name> [--limit <n>]
#
# One JSON object: {repo, issues[] {number, title, author, labels, updated_at, url},
# prs[] {number, title, author, head, sha, draft, updated_at, url}}. Uses `gh api` GET only;
# GH_TOKEN comes from the environment (a public repo needs none beyond gh's own login).
# A PR is pulled into GitLab by fetching its branch and shipping it with ship-mr; an issue
# worth working is filed on GitLab with issue-upsert carrying its URL. Nothing is written here.
# Exit: 0 ok · 2 usage · 3 gh missing · 1 gh failed.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
usage() { fail "$EX_USAGE" usage "usage: inbox.sh --repo <owner/name> [--limit <n>]${1:+ — $1}"; }
REPO=""; LIMIT=50
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || usage "--repo needs a value"; REPO="$2"; shift 2 ;;
    --limit) [ $# -ge 2 ] || usage; LIMIT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
[[ "$REPO" =~ ^[^/]+/[^/]+$ ]] || usage "--repo must be owner/name"
[[ "$LIMIT" =~ ^[1-9][0-9]*$ ]] || usage "--limit must be a positive number"
command -v gh >/dev/null 2>&1 || fail "$EX_NO_TOKEN" no_gh "gh is not installed; the GitHub inbox needs it"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/silkops-inbox.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
gh api -X GET "repos/$REPO/issues?state=open&per_page=$LIMIT" >"$TMP/issues.json" 2>"$TMP/err" \
  || fail "$EX_OTHER" gh_failed "gh could not list issues of $REPO: $(redact <"$TMP/err" | tr '\n' ' ')"
gh api -X GET "repos/$REPO/pulls?state=open&per_page=$LIMIT" >"$TMP/pulls.json" 2>"$TMP/err" \
  || fail "$EX_OTHER" gh_failed "gh could not list pull requests of $REPO: $(redact <"$TMP/err" | tr '\n' ' ')"
result "$(jq -cn --arg r "$REPO" --slurpfile i "$TMP/issues.json" --slurpfile p "$TMP/pulls.json" '
  {repo: $r,
   issues: [$i[0][] | select(.pull_request == null) | {number, title, author: .user.login, labels: [.labels[].name], updated_at, url: .html_url}],
   prs: [$p[0][] | {number, title, author: .user.login, head: .head.ref, sha: .head.sha, draft: (.draft // false), updated_at, url: .html_url}]}')"
