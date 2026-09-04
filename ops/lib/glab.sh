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

glab_ro() {
  require_ci_token
  { glab "$@" 2>&1 1>&3 | redact 1>&2; } 3>&1
}

glab_settings() { with_settings_token glab "$@"; }

api_get() { glab_ro api -X GET "$1"; }

api_settings() {
  local method="$1" path="$2"; shift 2
  glab_settings api -X "$method" "$path" "$@"
}
