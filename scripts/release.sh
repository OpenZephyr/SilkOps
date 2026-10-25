#!/usr/bin/env bash
# Release: on tag silkops-harness--vX.Y.Z, confirm both manifests agree with the tag, build the
# tarball the ci-cd factory pins, and upload it (plus its sha256, the rendered runbook and the
# release notes) to this project's generic package registry as
# silkops-harness/X.Y.Z/silkops-harness-X.Y.Z.tar.gz (plan KTD10), then create (or on 409 update)
# the GitLab Release for the tag with the notes as its description and links to the package
# files. The package and tag names keep the `silkops-harness` prefix on purpose: the image
# factory in ci-cd pins them. CI_JOB_TOKEN travels in a curl config on stdin, never on argv.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../ops/lib/prelude.sh
. ops/lib/prelude.sh   # xtrace refusal + redaction; the token never touches argv
# shellcheck source=../scripts/lib/release-notes.sh
. scripts/lib/release-notes.sh
tag="${CI_COMMIT_TAG:?run on a silkops-harness--vX.Y.Z tag}"
[[ "$tag" =~ ^silkops-harness--v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "$EX_USAGE" usage "tag $tag is not silkops-harness--vX.Y.Z"
version="${tag#silkops-harness--v}"
manifest_version="$(jq -r .version .claude-plugin/plugin.json)"
market_version="$(jq -r '.plugins[0].version' .claude-plugin/marketplace.json)"
[ "$version" = "$manifest_version" ] || fail "$EX_REFUSED" refused "tag $tag != plugin.json version $manifest_version"
[ "$version" = "$market_version" ] || fail "$EX_REFUSED" refused "tag $tag != marketplace.json version $market_version"
mkdir -p dist
name="silkops-harness-${version}.tar.gz"
runbook="silkops-harness-${version}-runbook.md"
notes="silkops-harness-${version}-notes.md"
# Reproducible archive of the tagged tree; the factory extracts with --strip-components=1.
git archive --format=tar.gz --prefix="silkops-harness-${version}/" -o "dist/${name}" "$tag"
( cd dist && sha256sum "$name" > "${name}.sha256" )
cat "dist/${name}.sha256" >&2
# The runbook is rendered from the core facts at release time, never committed (KTD5).
python3 ops/render-runbook.py >/dev/null && cp references/runbook.md "dist/${runbook}"
prev="$(release_prev_tag "$version")"
release_notes "$prev" "$tag" >"dist/${notes}"
err "notes since ${prev:-the beginning}: dist/${notes}"
api="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}"
base="${api}/packages/generic/silkops-harness/${version}"
for f in "$name" "${name}.sha256" "$runbook" "$notes"; do
  # JOB-TOKEN header via a curl config on stdin (`-K -`): never in the URL, never on argv.
  printf 'header = "JOB-TOKEN: %s"\n' "${CI_JOB_TOKEN}" | curl -fsS -K - --upload-file "dist/${f}" "${base}/${f}" >/dev/null
  err "uploaded ${base}/${f}"
done
# The GitLab Release: POST, or PUT when the tag already has one (409). Assets link to the package
# files (an update cannot change links; the package upload above already refreshed the files).
jq -n --arg v "$version" --arg t "$tag" --rawfile d "dist/${notes}" --arg b "$base" --arg n "$name" --arg r "$runbook" --arg no "$notes" '{
  name: ("SilkOps " + $v), tag_name: $t, description: $d,
  assets: {links: [
    {name: $n, url: ($b + "/" + $n), link_type: "package"},
    {name: ($n + ".sha256"), url: ($b + "/" + $n + ".sha256"), link_type: "other"},
    {name: $r, url: ($b + "/" + $r), link_type: "other"}]}}' >dist/release-body.json
code="$(printf 'header = "JOB-TOKEN: %s"\n' "${CI_JOB_TOKEN}" | curl -sS -K - -o dist/release.out -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' --data-binary @dist/release-body.json "${api}/releases")"
action=created
if [ "$code" = 409 ]; then
  action=updated
  jq '{name, description}' dist/release-body.json >dist/release-update.json
  code="$(printf 'header = "JOB-TOKEN: %s"\n' "${CI_JOB_TOKEN}" | curl -sS -K - -o dist/release.out -w '%{http_code}' \
    -X PUT -H 'Content-Type: application/json' --data-binary @dist/release-update.json "${api}/releases/$(urlenc "$tag")")"
fi
case "$code" in 2*) ;; *) fail "$EX_OTHER" release_failed "GitLab release $action failed: HTTP $code $(redact <dist/release.out | tr '\n' ' ' | cut -c1-300)" ;; esac
err "release $action: SilkOps $version ($tag)"
result "$(jq -cn --arg v "$version" --arg t "$tag" --arg p "$prev" --arg a "$action" --arg b "$base" --arg n "$name" --arg no "$notes" --arg u "$(jq -r '._links.self // empty' dist/release.out 2>/dev/null)" \
  '{version: $v, tag: $t, previous_tag: (if $p == "" then null else $p end), release: $a, package: $b, asset: $n, notes_file: ("dist/" + $no), url: (if $u == "" then null else $u end)}')"
