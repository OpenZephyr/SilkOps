#!/usr/bin/env bash
# Release: on tag silkops-harness--vX.Y.Z, confirm plugin.json agrees, build the tarball the
# ci-cd factory pins, and upload it (plus its sha256) to this project's generic package
# registry as silkops-harness/X.Y.Z/silkops-harness-X.Y.Z.tar.gz (plan KTD10).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../ops/lib/prelude.sh
. ops/lib/prelude.sh   # xtrace refusal + redaction; the token never touches argv
tag="${CI_COMMIT_TAG:?run on a silkops-harness--vX.Y.Z tag}"
version="${tag#silkops-harness--v}"
manifest_version="$(jq -r .version .claude-plugin/plugin.json)"
[ "$version" = "$manifest_version" ] || { echo "tag $tag != plugin.json version $manifest_version" >&2; exit 1; }
mkdir -p dist
name="silkops-harness-${version}.tar.gz"
# Reproducible archive of the tagged tree; the factory extracts with --strip-components=1.
git archive --format=tar.gz --prefix="silkops-harness-${version}/" -o "dist/${name}" "$tag"
( cd dist && sha256sum "$name" > "${name}.sha256" )
cat "dist/${name}.sha256"
# The runbook is rendered from the core facts at release time, never committed (KTD5).
python3 ops/render-runbook.py >/dev/null && cp references/runbook.md "dist/silkops-harness-${version}-runbook.md"
base="${CI_API_V4_URL}/projects/${CI_PROJECT_ID}/packages/generic/silkops-harness/${version}"
for f in "$name" "${name}.sha256" "silkops-harness-${version}-runbook.md"; do
  # JOB-TOKEN header via a curl config on stdin (`-K -`): never in the URL, never on argv.
  printf 'header = "JOB-TOKEN: %s"\n' "${CI_JOB_TOKEN}" | curl -fsS -K - --upload-file "dist/${f}" "${base}/${f}" >/dev/null
  echo "uploaded ${base}/${f}"
done
