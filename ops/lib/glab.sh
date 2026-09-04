#!/usr/bin/env bash
# glab.sh — thin wrappers over glab (plan U3). Requires prelude.sh and token.sh.
#
#   glab_ro <args…>                    read path under the session identity (or the CI
#                                      token in CI); stderr redacted
#   glab_settings <args…>              = with_settings_token glab <args…>
#   api_get <path>                     glab api GET, read identity
#   api_settings <method> <path> [-f k=v …]  glab api under the settings token
#
# Never echo argv; never build URLs containing tokens. Paths are API paths
# relative to /api/v4 (encode ids with `urlenc`).

# _glab_args <args…> — echo the argv glab should get. `glab api --input <file>` sends the
# body with no Content-Type, and GitLab answers HTTP 415 for JSON bodies without one
# (found live on the first mr-upsert of this repo), so a JSON header rides along with
# every --input. Printed NUL-separated so arguments with spaces survive.
_glab_args() {
  local a has_input=false
  for a in "$@"; do [ "$a" = "--input" ] && has_input=true; done
  if $has_input && [ "${1:-}" = "api" ]; then
    printf '%s\0' "api" -H "Content-Type: application/json"; shift
  fi
  printf '%s\0' "$@"
}

glab_ro() {
  require_ci_token
  local -a argv=()
  while IFS= read -r -d '' a; do argv+=("$a"); done < <(_glab_args "$@")
  { glab "${argv[@]}" 2>&1 1>&3 | redact 1>&2; } 3>&1
}

glab_settings() {
  local -a argv=()
  while IFS= read -r -d '' a; do argv+=("$a"); done < <(_glab_args "$@")
  with_settings_token glab "${argv[@]}"
}

api_get() { glab_ro api -X GET "$1"; }

api_settings() {
  local method="$1" path="$2"; shift 2
  glab_settings api -X "$method" "$path" "$@"
}
