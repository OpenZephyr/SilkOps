#!/usr/bin/env bash
# token.sh — per-operation token routing (plan U3, KTD3). Requires prelude.sh.
#
#   in_ci                  true when $CI is non-empty (GitLab, GitHub Actions, Woodpecker)
#   require_ci_token       in CI: export GITLAB_TOKEN from SILKOPS_CI_TOKEN before any glab
#                          call, or fail 3 — so glab never auto-logs-in with CI_JOB_TOKEN
#   with_settings_token …  run one command with GITLAB_TOKEN=SILKOPS_SETTINGS_TOKEN, and
#                          only that command; stderr passes through `redact`
#   with_ci_token …        same shape for SILKOPS_CI_TOKEN (used by token-check --for ci)
#
# SILKOPS_SETTINGS_TOKEN is a plain exported variable by decision (accepted exposure);
# there is no keychain lookup here.

in_ci() { [ -n "${CI:-}" ]; }

require_ci_token() {
  in_ci || return 0
  [ -n "${SILKOPS_CI_TOKEN:-}" ] \
    || fail "$EX_NO_TOKEN" no_token "SILKOPS_CI_TOKEN is not set (required when CI is non-empty; refusing before any network call)"
  export GITLAB_TOKEN="$SILKOPS_CI_TOKEN"
}

# _with_token <token> <cmd…> — the token reaches the command through its
# environment only: never argv, never a URL. The assignment prefix scopes it to
# that one process, so the caller's GITLAB_TOKEN (set or unset) is untouched.
# stderr goes through redact synchronously (a pipe, not a process substitution,
# so nothing arrives after we return); stdout is passed straight through on fd 3.
# With pipefail the pipeline's status is the command's (redact/sed exits 0).
_with_token() {
  local tok="$1"; shift
  { GITLAB_TOKEN="$tok" "$@" 2>&1 1>&3 | redact 1>&2; } 3>&1
}

with_settings_token() {
  [ -n "${SILKOPS_SETTINGS_TOKEN:-}" ] \
    || fail "$EX_NO_TOKEN" no_token "SILKOPS_SETTINGS_TOKEN is not set (required for settings-changing operations)"
  _with_token "$SILKOPS_SETTINGS_TOKEN" "$@"
}

with_ci_token() {
  [ -n "${SILKOPS_CI_TOKEN:-}" ] \
    || fail "$EX_NO_TOKEN" no_token "SILKOPS_CI_TOKEN is not set (required for the CI identity)"
  _with_token "$SILKOPS_CI_TOKEN" "$@"
}
