#!/usr/bin/env bash
# prelude.sh — shared prelude for every ops/ script (plan U3, KTD4).
#
# Sourced, never executed. Provides:
#   set -euo pipefail, a refusal of shell tracing (set -x would print tokens),
#   exit-code constants, `err`, `result`, `fail`, `redact`, `require_project`,
#   `silkops_marker`, `urlenc`, and the provider seam (SILKOPS_PROVIDER=gitlab).
#
# Contract: exactly one JSON object on stdout, human text on stderr, fixed exit
# codes (CLAUDE.md). Tokens come from the environment only and are never
# printed, never placed in argv, never embedded in URLs.
set -euo pipefail

# --- tracing refusal ---------------------------------------------------------
# `bash -x` / `set -x` echoes every expanded command line — including any
# GITLAB_TOKEN=… prefix — to stderr. Refuse before anything else runs.
case "$-" in
  *x*) echo "silkops: shell tracing refused (xtrace is enabled; tokens would be echoed)" >&2; exit 1 ;;
esac
case ":${SHELLOPTS:-}:" in
  *:xtrace:*) echo "silkops: shell tracing refused (SHELLOPTS contains xtrace)" >&2; exit 1 ;;
esac

# --- exit codes (KTD4) -------------------------------------------------------
# shellcheck disable=SC2034  # consumed by sourcing scripts
{
  EX_OK=0; EX_OTHER=1; EX_USAGE=2; EX_NO_TOKEN=3; EX_ROLE=4
  EX_NOT_FOUND=5; EX_RETRY_UNSAFE=6; EX_REFUSED=7
}

SILKOPS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SILKOPS_SCRIPT="$(basename "${0:-silkops}")"

# err <msg…> — human text on stderr, prefixed with the script name.
err() { echo "${SILKOPS_SCRIPT%.sh}: $*" >&2; }

# redact — stdin→stdout filter masking every token shape we know about. Applied
# to every wrapped command's stderr and to any text a script returns or posts.
# sed -E only (no -i flag on BSD sed): case-insensitivity is spelled out.
redact() {
  local a='[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]'
  local p='[Pp][Rr][Ii][Vv][Aa][Tt][Ee]-[Tt][Oo][Kk][Ee][Nn]'
  local j='[Jj][Oo][Bb]-[Tt][Oo][Kk][Ee][Nn]'
  local b='[Bb][Ee][Aa][Rr][Ee][Rr]'
  # Header values: mask the value and, when present, the scheme word before it
  # (Bearer/Basic/…) — two tokens, so `Authorization: Basic <cred>` loses the cred.
  local tok="[^[:space:]\"',;]+"
  sed -E \
    -e "s/(${a}|${p}|${j}):[[:space:]]*${tok}([[:space:]]+${tok})?/\1: <REDACTED>/g" \
    -e "s/${b}[[:space:]]+eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/Bearer <REDACTED>/g" \
    -e 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/<REDACTED>/g' \
    -e 's/gl(pat|cbt|dt|rt)-[A-Za-z0-9_-]+/<REDACTED>/g' \
    -e 's/oauth2:[^@[:space:]]+@/oauth2:<REDACTED>@/g'
}

# result <json> — emit exactly one JSON object on stdout. `ok:true` is added
# unless the object already carries `ok`. Invalid or non-object input is a
# programming error: nothing reaches stdout and the script exits 1.
result() {
  local out
  if ! out="$(printf '%s' "${1:-}" | jq -ce 'if type == "object" then {ok: true} + . else error("result is not a JSON object") end' 2>/dev/null)"; then
    err "internal: result() was given invalid JSON"
    exit "$EX_OTHER"
  fi
  printf '%s\n' "$out" | redact
}

# fail <code> <error-name> <message> [extra-json] — failure result on stdout,
# message on stderr, exit with <code>.
fail() {
  local code="$1" name="$2" msg="$3" extra="${4:-{\}}"
  err "$msg"
  jq -cn --arg e "$name" --arg m "$msg" --argjson x "$extra" \
    '{ok: false, error: $e, message: $m} + $x' | redact
  exit "$code"
}

# require_project [value] — every write takes an explicit --project (KTD9).
# Checks $1 when given, else $PROJECT (scripts parse --project into it).
require_project() {
  local v="${1-${PROJECT:-}}"
  [ -n "$v" ] || fail "$EX_USAGE" usage "--project <group/project> is required (never inferred from the cwd remote)"
}

# urlenc <string> — percent-encode a path component (group/project → group%2Fproject).
urlenc() { jq -rn --arg s "$1" '$s | @uri'; }

# silkops_marker <plan-basename> <unit> <run-id> — provenance comment carried by
# every harness-written object.
silkops_marker() {
  local v
  v="$(jq -r .version "$SILKOPS_ROOT/.claude-plugin/plugin.json")"
  printf '<!-- silkops: v=%s plan=%s unit=%s run=%s -->\n' "$v" "$1" "$2" "$3"
}

# --- provider seam -----------------------------------------------------------
# GitLab.com is the default host and gitlab the only provider. Anything else is
# a reservation for later, not a promise: fail usage rather than guess.
SILKOPS_PROVIDER="${SILKOPS_PROVIDER:-gitlab}"
[ "$SILKOPS_PROVIDER" = gitlab ] || fail "$EX_USAGE" usage "provider not implemented: $SILKOPS_PROVIDER (only gitlab)"
export GITLAB_HOST="${GITLAB_HOST:-gitlab.com}"
