#!/usr/bin/env bash
# bump.sh — prepare a release: set the version in both manifests, write the release notes, commit.
#
# Usage: bump.sh X.Y.Z [--dry-run]
#
# Runs against the repository of the cwd (its toplevel). Refuses (exit 7) a dirty tree, the default
# branch (the bump travels by MR; the tag is cut on main afterwards) and a version whose tag
# already exists — all three checks are skipped by --dry-run, which changes nothing but the notes
# file under dist/. Sets `version` in .claude-plugin/plugin.json and the plugin entry in
# .claude-plugin/marketplace.json with jq (2-space indent), writes dist/notes-X.Y.Z.md from the
# history since the previous silkops-harness--v* tag (scripts/lib/release-notes.sh) and prints it
# on stderr, then commits `release: X.Y.Z` on the current branch. Never pushes. The tag is cut by
# scripts/tag.sh on main after the merge (not `claude plugin tag`, which names it `silkops--v…`).
# One JSON object on stdout: {version, previous_tag, tag, notes_file, commit, issues_closed, next}.
set -euo pipefail
# shellcheck source=../ops/lib/prelude.sh
. "$(cd "$(dirname "$0")/.." && pwd)/ops/lib/prelude.sh"
# shellcheck source=../scripts/lib/release-notes.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/release-notes.sh"
usage() { fail "$EX_USAGE" usage "usage: bump.sh X.Y.Z [--dry-run]${1:+ — $1}"; }
VERSION=""; DRY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=true; shift ;;
    -*) usage "unknown argument: $1" ;;
    *) [ -z "$VERSION" ] || usage "one version only"; VERSION="$1"; shift ;;
  esac
done
[ -n "$VERSION" ] || usage
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage "version must be X.Y.Z (got $VERSION)"
top="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "$EX_USAGE" usage "the cwd is not inside a git repository"
cd "$top"
PLUGIN=.claude-plugin/plugin.json; MARKET=.claude-plugin/marketplace.json
if ! { [ -f "$PLUGIN" ] && [ -f "$MARKET" ]; }; then fail "$EX_NOT_FOUND" not_found "no $PLUGIN / $MARKET under $top"; fi
tag="silkops-harness--v${VERSION}"
branch="$(git rev-parse --abbrev-ref HEAD)"
default_branch="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"; default_branch="${default_branch#origin/}"; default_branch="${default_branch:-main}"
if [ "$DRY" = false ]; then
  # Tracked changes only: an untracked file never enters the bump commit (dist/ is ignored anyway).
  [ -z "$(git status --porcelain --untracked-files=no)" ] || fail "$EX_REFUSED" dirty_tree "the working tree is dirty; commit or discard first"
  [ "$branch" != "$default_branch" ] || fail "$EX_REFUSED" default_branch "on $default_branch: bump on a release branch and ship it as an MR; the tag is cut on $default_branch after the merge"
  ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "$EX_REFUSED" tag_exists "tag $tag already exists"
fi
from_plugin="$(jq -r .version "$PLUGIN")"
from_market="$(jq -r '.plugins[0].version' "$MARKET")"
prev="$(release_prev_tag "$VERSION")"
err "bump $from_plugin -> $VERSION on $branch (previous tag: ${prev:-none})$([ "$DRY" = true ] && echo " [dry run]")"

mkdir -p dist
notes="dist/notes-${VERSION}.md"
release_notes "$prev" HEAD >"$notes"
issues="$(release_closed_issues "$(release_range "$prev" HEAD)" | cut -f1 | jq -Rsc 'split("\n") | map(select(length > 0) | tonumber)')"
err "notes: $notes"; cat "$notes" >&2

if [ "$DRY" = true ]; then
  next="bump.sh $VERSION (without --dry-run) on a release branch, then ship it as an MR"
  result "$(jq -cn --arg v "$VERSION" --arg fp "$from_plugin" --arg fm "$from_market" --arg p "$prev" --arg t "$tag" --arg n "$notes" --arg b "$branch" --argjson i "$issues" --arg x "$next" \
    '{dry_run: true, version: $v, previous_tag: (if $p == "" then null else $p end), tag: $t, notes_file: $n, commit: null, branch: $b,
      issues_closed: $i, would_change: {".claude-plugin/plugin.json": {from: $fp, to: $v}, ".claude-plugin/marketplace.json": {from: $fm, to: $v}}, next: $x}')"
  exit 0
fi

# jq rewrites with 2-space indentation (its default) and keeps key order; written via a temp file.
tmp="$(mktemp "${TMPDIR:-/tmp}/bump.XXXXXX")"; trap 'rm -f "$tmp"' EXIT
jq --indent 2 --arg v "$VERSION" '.version = $v' "$PLUGIN" >"$tmp" && cat "$tmp" >"$PLUGIN"
jq --indent 2 --arg v "$VERSION" '.plugins |= map(if .name == "silkops" or length == 1 then .version = $v else . end)' "$MARKET" >"$tmp" && cat "$tmp" >"$MARKET"
[ "$(jq -r '.plugins[0].version' "$MARKET")" = "$VERSION" ] || fail "$EX_OTHER" marketplace "marketplace.json: no plugin entry named silkops to bump"
git add "$PLUGIN" "$MARKET"
git -c commit.gpgsign=false commit -q -m "release: $VERSION" >/dev/null
sha="$(git rev-parse HEAD)"
err "committed release: $VERSION ($sha) on $branch; not pushed"

next="ship $branch as an MR; after the merge, on $default_branch: scripts/tag.sh"
result "$(jq -cn --arg v "$VERSION" --arg p "$prev" --arg t "$tag" --arg n "$notes" --arg c "$sha" --arg b "$branch" --argjson i "$issues" --arg x "$next" \
  '{version: $v, previous_tag: (if $p == "" then null else $p end), tag: $t, notes_file: $n, commit: $c, branch: $b, issues_closed: $i, next: $x}')"
