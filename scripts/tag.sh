#!/usr/bin/env bash
# tag.sh — cut the release tag on the default branch after the bump MR merged.
#
# Usage: tag.sh [--dry-run]
#
# The tag is `silkops-harness--vX.Y.Z` with X.Y.Z read from .claude-plugin/plugin.json: that prefix is
# what the CI release rules, scripts/release.sh and the image factory in ci-cd match, and it is not
# what `claude plugin tag` produces since the plugin id became `silkops` (it would cut `silkops--v…`,
# which releases nothing). Refuses (exit 7) a branch other than the default one, a tree that is not
# at the remote's head, a dirty tree, a marketplace.json that disagrees with plugin.json, and a tag
# that already exists locally or on the remote. Creates an annotated tag "SilkOps X.Y.Z" and pushes
# only that ref. --dry-run prints the plan and changes nothing.
# One JSON object on stdout: {version, tag, commit, remote, pushed, next}.
set -euo pipefail
# shellcheck source=../ops/lib/prelude.sh
. "$(cd "$(dirname "$0")/.." && pwd)/ops/lib/prelude.sh"
usage() { fail "$EX_USAGE" usage "usage: tag.sh [--dry-run]${1:+ — $1}"; }
DRY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=true; shift ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
top="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "$EX_USAGE" usage "the cwd is not inside a git repository"
cd "$top"
PLUGIN=.claude-plugin/plugin.json; MARKET=.claude-plugin/marketplace.json
if ! { [ -f "$PLUGIN" ] && [ -f "$MARKET" ]; }; then fail "$EX_NOT_FOUND" not_found "no $PLUGIN / $MARKET under $top"; fi
version="$(jq -r .version "$PLUGIN")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$EX_OTHER" bad_version "$PLUGIN version is not X.Y.Z (got $version)"
[ "$(jq -r '.plugins[0].version' "$MARKET")" = "$version" ] || fail "$EX_REFUSED" manifests_disagree "$MARKET does not say $version; run scripts/bump.sh first"
tag="silkops-harness--v${version}"
remote="${SILKOPS_TAG_REMOTE:-origin}"
branch="$(git rev-parse --abbrev-ref HEAD)"
default_branch="$(git symbolic-ref -q --short "refs/remotes/$remote/HEAD" 2>/dev/null || true)"; default_branch="${default_branch#"$remote"/}"; default_branch="${default_branch:-main}"
[ "$branch" = "$default_branch" ] || fail "$EX_REFUSED" not_default_branch "on $branch: the tag is cut on $default_branch after the bump MR merged"
[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "$EX_REFUSED" dirty_tree "the working tree is dirty"
sha="$(git rev-parse HEAD)"
if git rev-parse -q --verify "refs/remotes/$remote/$default_branch" >/dev/null; then
  [ "$sha" = "$(git rev-parse "refs/remotes/$remote/$default_branch")" ] || fail "$EX_REFUSED" behind_remote "HEAD is not $remote/$default_branch; fetch and fast-forward first"
fi
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "$EX_REFUSED" tag_exists "tag $tag already exists locally"
if [ "$DRY" = false ] && git ls-remote --exit-code --tags "$remote" "refs/tags/$tag" >/dev/null 2>&1; then
  fail "$EX_REFUSED" tag_exists "tag $tag already exists on $remote"
fi
err "tag $tag at ${sha:0:12} on $default_branch$([ "$DRY" = true ] && echo " [dry run]")"
if [ "$DRY" = true ]; then
  result "$(jq -cn --arg v "$version" --arg t "$tag" --arg c "$sha" --arg r "$remote" \
    '{dry_run: true, version: $v, tag: $t, commit: $c, remote: $r, pushed: false, next: "tag.sh (without --dry-run) cuts and pushes the tag"}')"
  exit 0
fi
git tag -a "$tag" "$sha" -m "SilkOps $version"
git push "$remote" "refs/tags/$tag" >&2
result "$(jq -cn --arg v "$version" --arg t "$tag" --arg c "$sha" --arg r "$remote" \
  '{version: $v, tag: $t, commit: $c, remote: $r, pushed: true, next: "CI on the tag publishes the GitLab package and release (and the GitHub release when GH_TOKEN is set; else scripts/github-release.sh)"}')"
