#!/usr/bin/env bash
# prelude.sh — shared prelude for every ops/ script (plan U3, KTD4).
#
# Sourced, never executed. Provides:
#   set -euo pipefail, a refusal of shell tracing (set -x would print tokens),
#   exit-code constants, `err`, `result`, `fail`, `redact`, `require_project`,
#   `silkops_marker`, `facts_paths`, `urlenc`, and the provider seam (SILKOPS_PROVIDER=gitlab).
#
# Contract: exactly one JSON object on stdout, human text on stderr, fixed exit
# codes (AGENTS.md). Tokens come from the environment only and are never
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
  # (Bearer/Basic/…) — two tokens, so `Authorization: Basic <cred>` loses the cred. The header
  # name may be quoted and the value may open with a quote (JSON / JS-style dumps:
  # `"Authorization": "Basic …"`, `Authorization: 'Bearer …'`); the closing quote stays.
  # Excludes backslash so a JSON-encoded quote (\") after a value survives redaction intact.
  local tok="[^[:space:]\"',;\\\\]+"
  sed -E \
    -e "s/((${a}|${p}|${j})[\"']?:[[:space:]]*[\"']?)${tok}([[:space:]]+${tok})?/\1<REDACTED>/g" \
    -e "s/${b}[[:space:]]+eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/Bearer <REDACTED>/g" \
    -e 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/<REDACTED>/g' \
    -e 's/gl(pat|cbt|dt|rt)-[A-Za-z0-9_-]+/<REDACTED>/g' \
    -e 's/oauth2:[^@[:space:]]+@/oauth2:<REDACTED>@/g'
}

# managed_region_plan <object-json> <body> <marker> <run> — plan the KTD5 description
# update for an issue or MR: only the text between the managed-region markers changes and
# the marker's run= is refreshed; without a region (object written by a human, found by
# label) the marker + region are appended. Prints {had_region, changed, description}.
managed_region_plan() {
  printf '%s' "$1" | jq -c --arg body "$2" --arg marker "$3" --arg run "$4" '(.description // "") as $d |
    "<!-- silkops:managed -->" as $open | "<!-- /silkops:managed -->" as $close
    | ("\n" + $body + "\n") as $inner
    | if ($d | contains($open)) and ($d | contains($close)) then
        ($d | split($open)) as $a | ($a[1:] | join($open) | split($close)) as $b
        | {had_region: true, changed: ($b[0] != $inner),
           description: (($a[0] | sub("(?<m><!-- silkops: v=[^ ]+ plan=[^ ]+ unit=[^ ]+ run=)[^ ]+ -->"; "\(.m)\($run) -->"))
                         + $open + $inner + $close + ($b[1:] | join($close)))}
      else
        {had_region: false, changed: true,
         description: ($d + (if ($d == "" or ($d | endswith("\n"))) then "" else "\n" end) + $marker + "\n" + $open + $inner + $close + "\n")}
      end'
}

# result <json> — emit exactly one JSON object on stdout. `ok:true` is added
# unless the object already carries `ok`. Invalid or non-object input is a
# programming error: nothing reaches stdout and the script exits 1.
result() {
  local out
  if ! out="$(printf '%s' "${1:-}" | jq -ce --arg p "${SILKOPS_PROVIDER:-gitlab}" --argjson x "${SILKOPS_EXPERIMENTAL:-false}" 'if type == "object" then {ok: true, provider: $p} + (if $x then {experimental: true} else {} end) + . else error("result is not a JSON object") end' 2>/dev/null)"; then
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

# marker_enabled — provenance markers are on unless SILKOPS_MARKER=off (v0.2 KD6, #39):
# the operator decides disclosure; off is the default for projects outside the operator's
# group. Write scripts then fall back to branch / label / key identity and say so.
marker_enabled() { [ "${SILKOPS_MARKER:-on}" != off ]; }

# facts_paths — the fact layers, one path per line, most specific first: the consumer
# repo's .silkops/facts.json (cwd), then $SILKOPS_FACTS_OVERLAY/*.json (default
# <plugin>/overlay/facts.d, sorted), then the plugin core. classify-failure.py takes
# them as repeated --facts and an earlier file wins on an overlapping pattern.
facts_paths() {
  local ov="${SILKOPS_FACTS_OVERLAY:-$SILKOPS_ROOT/overlay/facts.d}" f
  [ -f "$PWD/.silkops/facts.json" ] && echo "$PWD/.silkops/facts.json"
  if [ -d "$ov" ]; then
    for f in "$ov"/*.json; do [ -f "$f" ] && echo "$f"; done
  fi
  echo "$SILKOPS_ROOT/facts/environment.json"
}

# --- provider seam -----------------------------------------------------------
# The provider is SILKOPS_PROVIDER, else read off the origin remote (github.com → github,
# anything else → gitlab). ops/lib/provider.sh loads the verb set for it (v0.3 U2).
if [ -z "${SILKOPS_PROVIDER:-}" ]; then
  case "$(git remote get-url origin 2>/dev/null || true)" in
    *github.com*) SILKOPS_PROVIDER=github ;;
    *gitlab*) SILKOPS_PROVIDER=gitlab ;;
    *) if [ -n "${GITEA_TOKEN:-}" ]; then SILKOPS_PROVIDER=gitea; else SILKOPS_PROVIDER=gitlab; fi ;;
  esac
fi
export SILKOPS_PROVIDER
export GITLAB_HOST="${GITLAB_HOST:-gitlab.com}"
