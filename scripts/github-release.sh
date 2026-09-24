#!/usr/bin/env bash
# github-release.sh — publish a tagged release on the public GitHub mirror (v0.2 U6, R8).
#
# Usage: github-release.sh --repo <owner/name> --tag silkops-harness--vX.Y.Z [--dry-run]
#
# Builds the same reproducible tarball CI publishes to GitLab (git archive of the tag) and
# creates the GitHub Release with it and its sha256 via `gh release create`. Run by the operator
# after the GitLab release job is green; the tag must already be on main (mirrored to GitHub).
# GH_TOKEN from the environment only. --dry-run prints the plan as JSON and runs nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../ops/lib/prelude.sh
. ops/lib/prelude.sh
usage() { fail "$EX_USAGE" usage "usage: github-release.sh --repo <owner/name> --tag silkops-harness--vX.Y.Z [--dry-run]${1:+ — $1}"; }
REPO=""; TAG=""; DRY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --tag) [ $# -ge 2 ] || usage; TAG="$2"; shift 2 ;;
    --dry-run) DRY=true; shift ;;
    *) usage "unknown argument: $1" ;;
  esac
done
[[ "$REPO" =~ ^[^/]+/[^/]+$ ]] || usage "--repo must be owner/name"
[[ "$TAG" =~ ^silkops-harness--v[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage "--tag must be silkops-harness--vX.Y.Z"
version="${TAG#silkops-harness--v}"
name="silkops-harness-${version}.tar.gz"
cmd="gh release create $TAG dist/$name dist/$name.sha256 --repo $REPO --title \"SilkOps $version\" --notes-file dist/notes.md"
if [ "$DRY" = true ]; then
  result "$(jq -cn --arg t "$TAG" --arg v "$version" --arg a "dist/$name" --arg c "$cmd" --arg r "$REPO" '{dry_run: true, repo: $r, tag: $t, version: $v, asset: $a, command: $c}')"
  exit 0
fi
command -v gh >/dev/null 2>&1 || fail "$EX_NO_TOKEN" no_gh "gh is not installed"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "$EX_NOT_FOUND" not_found "tag $TAG is not in this checkout"
manifest="$(jq -r .version .claude-plugin/plugin.json)"
[ "$version" = "$manifest" ] || fail "$EX_REFUSED" refused "tag $TAG != plugin.json version $manifest"
mkdir -p dist
git archive --format=tar.gz --prefix="silkops-harness-${version}/" -o "dist/${name}" "$TAG"
( cd dist && shasum -a 256 "$name" > "${name}.sha256" )
printf 'SilkOps %s. Install: `bin/silkops install-agent <agent>` from the unpacked tree, or `claude plugin marketplace add OpenZephyr/SilkOps`.\n' "$version" >dist/notes.md
gh release create "$TAG" "dist/$name" "dist/$name.sha256" --repo "$REPO" --title "SilkOps $version" --notes-file dist/notes.md >"dist/release.out" 2>&1 \
  || fail "$EX_OTHER" release_failed "gh release create failed: $(redact <dist/release.out | tr '\n' ' ')"
result "$(jq -cn --arg t "$TAG" --arg v "$version" --arg a "dist/$name" --arg r "$REPO" --arg u "$(tr -d '\n' <dist/release.out)" '{repo: $r, tag: $t, version: $v, asset: $a, url: $u}')"
