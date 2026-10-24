#!/usr/bin/env bash
# link.sh — a permalink to a file and line range, pinned at a commit (#90).
#
# Usage: link.sh --project <group/project> --path <file> [--line a[-b]] [--sha <ref>]
#          [--project-url <url>] [--no-check]
#
# The URL is the host's own blob view at the resolved sha, so it keeps pointing at the same
# lines after the branch moves on:
#   gitlab  <web_url>/-/blob/<sha>/<path>#L<a>-<b>       (one line: #L<a>)
#   github  <web_url>/blob/<sha>/<path>#L<a>-L<b>
#   gitea   <web_url>/src/commit/<sha>/<path>#L<a>-L<b>
# --sha defaults to HEAD of the cwd; a ref is resolved with `git rev-parse`. The project URL is
# --project-url, else SILKOPS_PROJECT_URL, else `p_project_get` when the provider's token is in
# the environment, else the provider's known host (no network). Read-only; no token is needed.
# Result: {url, sha, path, line, project_url, checked}.
# Exit: 0 ok · 2 usage (bad --line, no project URL) · 5 sha unresolvable or path absent at the sha · 1 other.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/prelude.sh"
# shellcheck source=lib/token.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/token.sh"
# shellcheck source=lib/glab.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/glab.sh"
# shellcheck source=lib/provider.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/provider.sh"

usage() { fail "$EX_USAGE" usage "usage: link.sh --project <group/project> --path <file> [--line a[-b]] [--sha <ref>] [--project-url <url>] [--no-check]${1:+ — $1}"; }
PROJECT=""; FPATH=""; LINE=""; SHA=""; URL=""; CHECK=true
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --path) [ $# -ge 2 ] || usage; FPATH="$2"; shift 2 ;;
    --line) [ $# -ge 2 ] || usage; LINE="$2"; shift 2 ;;
    --sha) [ $# -ge 2 ] || usage; SHA="$2"; shift 2 ;;
    --project-url) [ $# -ge 2 ] || usage; URL="$2"; shift 2 ;;
    --no-check) CHECK=false; shift ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
require_project "$PROJECT"
[ -n "$FPATH" ] || usage "--path is required"
FPATH="${FPATH#./}"; FPATH="${FPATH%/}"
case "$FPATH" in /*|*/../*|../*|*/..) usage "--path must be relative to the repository root" ;; esac

# --- line range: a or a-b, 1-based, a <= b; "a-a" collapses to "a" ----------------------------
A=""; B=""
if [ -n "$LINE" ]; then
  [[ "$LINE" =~ ^([0-9]+)(-([0-9]+))?$ ]] || usage "--line must be <a> or <a>-<b> (got '$LINE')"
  A="${BASH_REMATCH[1]}"; B="${BASH_REMATCH[3]:-}"
  [ "$A" -ge 1 ] || usage "--line starts at 1"
  if [ -n "$B" ]; then
    [ "$B" -ge "$A" ] || usage "--line range end ($B) is before its start ($A)"
    [ "$B" != "$A" ] || B=""
  fi
  LINE="$A${B:+-$B}"
fi

# --- sha: a ref resolved in the cwd; a bare hex sha is accepted outside a repo with --no-check --
REF="${SHA:-HEAD}"
if RESOLVED="$(git rev-parse --verify --quiet "${REF}^{commit}" 2>/dev/null)"; then
  SHA="$RESOLVED"
elif [ "$CHECK" = false ] && [[ "$REF" =~ ^[0-9a-f]{7,64}$ ]]; then
  SHA="$REF"; err "note: '$REF' is not resolvable here; taken as a sha, unchecked"
else
  fail "$EX_NOT_FOUND" not_found "cannot resolve '$REF' to a commit in $PWD (pass --sha, or run inside the repository)"
fi
if [ "$CHECK" = true ]; then
  git cat-file -e "$SHA:$FPATH" 2>/dev/null \
    || fail "$EX_NOT_FOUND" not_found "no file '$FPATH' at $SHA (pass --no-check to link anyway)" "$(jq -cn --arg s "$SHA" --arg p "$FPATH" '{sha: $s, path: $p}')"
fi

# --- project URL: explicit, else the host's answer under a token, else the known host -----------
token_present() {
  case "$SILKOPS_PROVIDER" in
    gitlab) [ -n "${SILKOPS_CI_TOKEN:-}" ] || [ -n "${GITLAB_TOKEN:-}" ] ;;
    github) [ -n "${GH_TOKEN:-}" ] ;;
    gitea)  [ -n "${GITEA_TOKEN:-}" ] ;;
    *) false ;;
  esac
}
SOURCE=explicit
if [ -z "$URL" ] && [ -n "${SILKOPS_PROJECT_URL:-}" ]; then URL="${SILKOPS_PROJECT_URL%/}"; SOURCE="env"; fi
if [ -z "$URL" ] && token_present; then
  if URL="$(p_project_get "$PROJECT" 2>/dev/null | jq -er '.web_url // empty' 2>/dev/null)" && [ -n "$URL" ]; then SOURCE=host
  else err "note: the host did not answer for $PROJECT; building the URL from its known host"; URL=""; fi
fi
if [ -z "$URL" ]; then
  URL="$(project_url_default "$PROJECT")"; SOURCE=default
  [ -n "$URL" ] || usage "no project URL known for $SILKOPS_PROVIDER; pass --project-url or set SILKOPS_PROJECT_URL"
fi
URL="${URL%/}"

# --- the permalink ---------------------------------------------------------------------------------
ENC_PATH="$(jq -rn --arg p "$FPATH" '$p | split("/") | map(@uri) | join("/")')"
case "$SILKOPS_PROVIDER" in
  gitlab) LINK="$URL/-/blob/$SHA/$ENC_PATH"; FRAG="${A:+#L$A${B:+-$B}}" ;;
  github) LINK="$URL/blob/$SHA/$ENC_PATH"; FRAG="${A:+#L$A${B:+-L$B}}" ;;
  gitea)  LINK="$URL/src/commit/$SHA/$ENC_PATH"; FRAG="${A:+#L$A${B:+-L$B}}" ;;
  *) fail "$EX_USAGE" usage "no permalink format for provider $SILKOPS_PROVIDER" ;;
esac
result "$(jq -cn --arg u "$LINK$FRAG" --arg s "$SHA" --arg p "$FPATH" --arg l "$LINE" --arg pu "$URL" --arg src "$SOURCE" --argjson c "$CHECK" \
  '{url: $u, sha: $s, path: $p, line: (if $l == "" then null else $l end), project_url: $pu, project_url_source: $src, checked: $c}')"
