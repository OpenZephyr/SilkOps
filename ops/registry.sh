#!/usr/bin/env bash
# registry.sh — container registry operations glab has no verb for (plan U4, AE4).
#
# Usage: registry.sh --project <group/project> tags <image>
#        registry.sh --project <group/project> digest <image> <tag>
#        registry.sh --project <group/project> retag <image> <tag> <new-tag> [--dry-run]
#
# <image> is the repository path below the project (`.` for the project root repository).
# Reads (tags, digest) go through `glab api` registry endpoints under the session
# identity. `retag` alone speaks the v2 API with curl under the SETTINGS token: a JWT
# from /jwt/auth (basic auth), then manifest GET/PUT (bearer). Credentials reach curl
# only as a config on stdin (`curl -K -`), never argv, never a URL.
# Retag refuses an existing target tag (exit 7); a registry/network error on that
# existence check is exit 1, never read as "absent" (build-image.sh's guard). The
# manifest is re-PUT byte-for-byte with its original Content-Type (zero blob uploads),
# then both tags' digests are fetched and must match.
# Exit: 0 ok · 2 usage · 3 token missing · 4 registry denied · 5 not found · 7 tag exists · 1 other.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
# shellcheck source=lib/token.sh
. "$(dirname "$0")/lib/token.sh"
# shellcheck source=lib/glab.sh
. "$(dirname "$0")/lib/glab.sh"
# shellcheck source=lib/provider.sh
. "$(dirname "$0")/lib/provider.sh"

usage() { fail "$EX_USAGE" usage "usage: registry.sh --project <group/project> (tags <image> | digest <image> <tag> | retag <image> <tag> <new-tag>) [--dry-run]${1:+ — $1}"; }

PROJECT=""; DRY=false; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --dry-run) DRY=true; shift ;;
    -h|--help) usage ;;
    -*) usage "unknown argument: $1" ;;
    *) POS+=("$1"); shift ;;
  esac
done
require_project "$PROJECT"
p_gitlab_only "registry.sh"
CMD="${POS[0]:-}"; IMAGE="${POS[1]:-}"
[ -n "$IMAGE" ] || usage "<image> is required"
case "$IMAGE" in .|/) REPO="$PROJECT" ;; *) REPO="$PROJECT/${IMAGE#/}" ;; esac
require_ci_token   # top level, so the exit-3 JSON and message reach the real streams (the wrappers re-check)
ENC="$(urlenc "$PROJECT")"

# --- reads via glab (session identity) ---------------------------------------
repo_record() {
  local repos
  repos="$(api_get "projects/$ENC/registry/repositories?tags=true&per_page=100" 2>/dev/null)" \
    || fail "$EX_NOT_FOUND" not_found "could not list registry repositories of $PROJECT"
  printf '%s' "$repos" | jq -ce --arg p "$REPO" '[.[] | select(.path == $p)] | first // empty' \
    || fail "$EX_NOT_FOUND" not_found "registry repository not found: $REPO"
}
case "$CMD" in
  tags)
    [ ${#POS[@]} -eq 2 ] || usage "tags takes exactly <image>"
    result "$(repo_record | jq -c '{repository_id: .id, path, location, tags: (.tags // [] | map({name, path}))}')"
    exit 0 ;;
  digest)
    [ ${#POS[@]} -eq 3 ] || usage "digest takes <image> <tag>"
    TAG="${POS[2]}"
    R="$(repo_record)"; RID="$(printf '%s' "$R" | jq -r '.id')"
    T="$(api_get "projects/$ENC/registry/repositories/$RID/tags/$(urlenc "$TAG")" 2>/dev/null)" \
      || fail "$EX_NOT_FOUND" not_found "tag not found: $REPO:$TAG" "$(jq -cn --arg r "$REPO" --arg t "$TAG" '{repository: $r, tag: $t}')"
    result "$(printf '%s' "$T" | jq -c --argjson rid "$RID" --arg r "$REPO" '{repository: $r, repository_id: $rid, tag: .name, digest, location, total_size}')"
    exit 0 ;;
  retag) [ ${#POS[@]} -eq 4 ] || usage "retag takes <image> <tag> <new-tag>" ;;
  "") usage "subcommand required: tags | digest | retag" ;;
  *) usage "unknown subcommand: $CMD" ;;
esac

# --- retag via the v2 API (settings token, curl -K -) ------------------------
TAG="${POS[2]}"; NEW="${POS[3]}"
[ "$TAG" != "$NEW" ] || usage "<tag> and <new-tag> are the same"
require_settings_token "required to write to the registry"
REGISTRY="${SILKOPS_REGISTRY_HOST:-registry.gitlab.com}"
ACCEPT='application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json'
TMP="$(mktemp -d "${TMPDIR:-/tmp}/silkops-registry.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
CTX="$(jq -cn --arg r "$REPO" --arg s "$TAG" --arg t "$NEW" '{repository: $r, source_tag: $s, target_tag: $t}')"

# rcurl <config> <out> <headers-out> <curl args…> — prints the HTTP status; the
# config (credentials) is fed on stdin, so argv holds only URL, method and public headers.
rcurl() {
  local cfg="$1" out="$2" hdr="$3"; shift 3
  curl -sS -K - -o "$out" -D "$hdr" -w '%{http_code}' "$@" <<<"$cfg"
}
hdr_value() { grep -i "^$1:" "$2" | head -n1 | sed -e 's/^[^:]*:[[:space:]]*//' -e 's/[[:space:]]*$//' | tr -d '\r'; }
sha256_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

SCOPE="pull,push"; [ "$DRY" = true ] && SCOPE="pull"
JWT_URL="https://${GITLAB_HOST}/jwt/auth?service=container_registry&scope=repository:${REPO}:${SCOPE}"
if ! CODE="$(rcurl "user = \"silkops:${SILKOPS_SETTINGS_TOKEN}\"" "$TMP/jwt.json" "$TMP/jwt.hdr" -X GET "$JWT_URL" 2>"$TMP/curl.err")"; then
  fail "$EX_OTHER" registry_error "could not reach the registry auth endpoint: $(redact <"$TMP/curl.err")" "$CTX"
fi
case "$CODE" in
  200) JWT="$(jq -r '.token // .access_token // empty' "$TMP/jwt.json")"; [ -n "$JWT" ] || fail "$EX_OTHER" registry_error "auth endpoint returned no token" "$CTX" ;;
  401|403) fail "$EX_ROLE" registry_denied "registry auth refused the settings token for $REPO (HTTP $CODE)" "$CTX" ;;
  *) fail "$EX_OTHER" registry_error "registry auth failed (HTTP $CODE)" "$CTX" ;;
esac
BEARER_CFG="header = \"Authorization: Bearer ${JWT}\""
MURL="https://${REGISTRY}/v2/${REPO}/manifests"

# manifest_get <tag> <name> — sets G_CODE; body in $TMP/<name>.json, headers in $TMP/<name>.hdr.
manifest_get() {
  if ! G_CODE="$(rcurl "$BEARER_CFG" "$TMP/$2.json" "$TMP/$2.hdr" -X GET -H "Accept: $ACCEPT" "$MURL/$1" 2>"$TMP/curl.err")"; then
    fail "$EX_OTHER" registry_error "registry request for $REPO:$1 failed (cannot verify tag state): $(redact <"$TMP/curl.err")" "$CTX"
  fi
}

# 1. the target must be absent — and only a MANIFEST_UNKNOWN 404 proves absence.
manifest_get "$NEW" target
case "$G_CODE" in
  200) fail "$EX_REFUSED" tag_exists "tag $REPO:$NEW already exists (digest $(hdr_value docker-content-digest "$TMP/target.hdr")); tags are immutable — refusing to retag" "$CTX" ;;
  404) jq -e '.errors[]? | select(.code == "MANIFEST_UNKNOWN" or .code == "NAME_UNKNOWN")' "$TMP/target.json" >/dev/null 2>&1 \
         || fail "$EX_OTHER" registry_error "404 without MANIFEST_UNKNOWN for $REPO:$NEW; cannot verify tag absence" "$CTX" ;;
  401|403) fail "$EX_ROLE" registry_denied "registry denied access to $REPO (HTTP $G_CODE)" "$CTX" ;;
  *) fail "$EX_OTHER" registry_error "registry returned HTTP $G_CODE for $REPO:$NEW; cannot verify tag absence" "$CTX" ;;
esac

# 2. the source manifest, byte-exact, with its content type and digest.
manifest_get "$TAG" source
case "$G_CODE" in
  200) ;;
  404) fail "$EX_NOT_FOUND" not_found "source tag not found: $REPO:$TAG" "$CTX" ;;
  *) fail "$EX_OTHER" registry_error "registry returned HTTP $G_CODE for $REPO:$TAG" "$CTX" ;;
esac
CTYPE="$(hdr_value content-type "$TMP/source.hdr")"
[ -n "$CTYPE" ] || CTYPE="$(jq -r '.mediaType // empty' "$TMP/source.json")"
[ -n "$CTYPE" ] || fail "$EX_OTHER" registry_error "source manifest carries no Content-Type and no mediaType" "$CTX"
SRC_DIGEST="$(hdr_value docker-content-digest "$TMP/source.hdr")"
[ -n "$SRC_DIGEST" ] || SRC_DIGEST="sha256:$(sha256_file "$TMP/source.json")"

if [ "$DRY" = true ]; then
  result "$(jq -cn --argjson c "$CTX" --arg d "$SRC_DIGEST" --arg ct "$CTYPE" --arg t "$NEW" \
    '$c + {dry_run: true, current: {source: {tag: $c.source_tag, digest: $d, content_type: $ct}, target: null}, proposed: {tag: $t, digest: $d, content_type: $ct}}')"
  exit 0
fi

# 3. PUT the same bytes under the new tag (manifest-only; every blob already exists).
if ! CODE="$(rcurl "$BEARER_CFG" "$TMP/put.json" "$TMP/put.hdr" -X PUT -H "Content-Type: $CTYPE" --data-binary "@$TMP/source.json" "$MURL/$NEW" 2>"$TMP/curl.err")"; then
  fail "$EX_OTHER" registry_error "manifest PUT for $REPO:$NEW failed: $(redact <"$TMP/curl.err")" "$CTX"
fi
case "$CODE" in
  201|200) ;;
  401|403) fail "$EX_ROLE" registry_denied "registry refused the manifest PUT for $REPO:$NEW (HTTP $CODE)" "$CTX" ;;
  *) fail "$EX_OTHER" registry_error "manifest PUT for $REPO:$NEW returned HTTP $CODE: $(tr -d '\n' <"$TMP/put.json" | head -c 300)" "$CTX" ;;
esac

# 4. verify: both tags must now resolve to one digest.
manifest_get "$TAG" v_source; [ "$G_CODE" = 200 ] || fail "$EX_OTHER" registry_error "post-write read of $REPO:$TAG returned HTTP $G_CODE" "$CTX"
manifest_get "$NEW" v_target; [ "$G_CODE" = 200 ] || fail "$EX_OTHER" registry_error "post-write read of $REPO:$NEW returned HTTP $G_CODE" "$CTX"
D1="$(hdr_value docker-content-digest "$TMP/v_source.hdr")"; [ -n "$D1" ] || D1="sha256:$(sha256_file "$TMP/v_source.json")"
D2="$(hdr_value docker-content-digest "$TMP/v_target.hdr")"; [ -n "$D2" ] || D2="sha256:$(sha256_file "$TMP/v_target.json")"
REPORT="$(jq -cn --argjson c "$CTX" --arg d1 "$D1" --arg d2 "$D2" --arg ct "$CTYPE" '$c + {source_digest: $d1, target_digest: $d2, content_type: $ct}')"
[ "$D1" = "$D2" ] || fail "$EX_OTHER" digest_mismatch "after PUT, $REPO:$TAG and $REPO:$NEW resolve to different digests" "$REPORT"
result "$(jq -cn --argjson r "$REPORT" '$r + {action: "retagged"}')"
