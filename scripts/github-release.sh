#!/usr/bin/env bash
# github-release.sh — publish a tagged release on the public GitHub mirror (v0.2 U6, R8).
#
# Usage: github-release.sh --repo <owner/name> --tag silkops-harness--vX.Y.Z [--update] [--dry-run]
#
# Builds the same reproducible tarball CI publishes to GitLab (git archive of the tag) and
# creates the GitHub Release "SilkOps X.Y.Z" with it, its sha256 and the notes the GitLab
# release carries (scripts/lib/release-notes.sh, with the install line on top). Run by CI's
# github-release job when GH_TOKEN is set, else by the operator after the GitLab release job is
# green; the tag must already be on main (mirrored to GitHub). --update edits the title and notes
# of a release that already exists instead of failing, so past releases can be normalized.
# GH_TOKEN from the environment only. --dry-run prints the plan as JSON and runs nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../ops/lib/prelude.sh
. ops/lib/prelude.sh
# shellcheck source=../scripts/lib/release-notes.sh
. scripts/lib/release-notes.sh
usage() { fail "$EX_USAGE" usage "usage: github-release.sh --repo <owner/name> --tag silkops-harness--vX.Y.Z [--update] [--dry-run]${1:+ — $1}"; }
REPO=""; TAG=""; DRY=false; UPDATE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --tag) [ $# -ge 2 ] || usage; TAG="$2"; shift 2 ;;
    --update) UPDATE=true; shift ;;
    --dry-run) DRY=true; shift ;;
    *) usage "unknown argument: $1" ;;
  esac
done
[[ "$REPO" =~ ^[^/]+/[^/]+$ ]] || usage "--repo must be owner/name"
[[ "$TAG" =~ ^silkops-harness--v[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage "--tag must be silkops-harness--vX.Y.Z"
version="${TAG#silkops-harness--v}"
name="silkops-harness-${version}.tar.gz"
notes="dist/notes-${version}.md"
create_cmd="gh release create $TAG dist/$name dist/$name.sha256 --repo $REPO --title \"SilkOps $version\" --notes-file $notes"
edit_cmd="gh release edit $TAG --repo $REPO --title \"SilkOps $version\" --notes-file $notes"
if [ "$DRY" = true ]; then
  result "$(jq -cn --arg t "$TAG" --arg v "$version" --arg a "dist/$name" --arg n "$notes" --arg c "$create_cmd" --arg e "$edit_cmd" --arg r "$REPO" --argjson u "$UPDATE" \
    '{dry_run: true, repo: $r, tag: $t, version: $v, asset: $a, notes_file: $n, title: ("SilkOps " + $v), update: $u, command: $c, update_command: (if $u then $e else null end)}')"
  exit 0
fi
command -v gh >/dev/null 2>&1 || fail "$EX_NO_TOKEN" no_gh "gh is not installed"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "$EX_NOT_FOUND" not_found "tag $TAG is not in this checkout"
manifest="$(jq -r .version .claude-plugin/plugin.json)"
[ "$version" = "$manifest" ] || fail "$EX_REFUSED" refused "tag $TAG != plugin.json version $manifest"
mkdir -p dist
prev="$(release_prev_tag "$version")"
{
  # shellcheck disable=SC2016  # the backticks are markdown
  printf 'SilkOps %s. Install: `bin/silkops install-agent <agent>` from the unpacked tree, or `claude plugin marketplace add OpenZephyr/SilkOps`.\n\n' "$version"
  release_notes "$prev" "$TAG"
} >"$notes"
if [ "$UPDATE" = true ] && gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release edit "$TAG" --repo "$REPO" --title "SilkOps $version" --notes-file "$notes" >"dist/release.out" 2>&1 \
    || fail "$EX_OTHER" release_failed "gh release edit failed: $(redact <dist/release.out | tr '\n' ' ')"
  result "$(jq -cn --arg t "$TAG" --arg v "$version" --arg n "$notes" --arg r "$REPO" --arg u "$(tr -d '\n' <dist/release.out)" '{repo: $r, tag: $t, version: $v, action: "updated", notes_file: $n, url: $u}')"
  exit 0
fi
git archive --format=tar.gz --prefix="silkops-harness-${version}/" -o "dist/${name}" "$TAG"
if command -v sha256sum >/dev/null 2>&1; then ( cd dist && sha256sum "$name" > "${name}.sha256" ); else ( cd dist && shasum -a 256 "$name" > "${name}.sha256" ); fi
gh release create "$TAG" "dist/$name" "dist/$name.sha256" --repo "$REPO" --title "SilkOps $version" --notes-file "$notes" >"dist/release.out" 2>&1 \
  || fail "$EX_OTHER" release_failed "gh release create failed: $(redact <dist/release.out | tr '\n' ' ')"
result "$(jq -cn --arg t "$TAG" --arg v "$version" --arg a "dist/$name" --arg n "$notes" --arg r "$REPO" --arg u "$(tr -d '\n' <dist/release.out)" '{repo: $r, tag: $t, version: $v, action: "created", asset: $a, notes_file: $n, url: $u}')"
