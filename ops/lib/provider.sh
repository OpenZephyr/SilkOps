#!/usr/bin/env bash
# provider.sh — the host seam (v0.3 U2, KD2). Sourced after prelude.sh (and, for GitLab,
# glab.sh). Loads ops/lib/providers/$SILKOPS_PROVIDER.sh, which implements the verb set the
# scripts call (p_mr_get, p_run_jobs, p_note_post, …). Scripts never name an endpoint.
#
# Detection (prelude): SILKOPS_PROVIDER wins; else the origin remote's host: github.com →
# github; anything else → gitlab (self-hosted GitLab included). Gitea needs SILKOPS_PROVIDER.
# p_gitlab_only <what> — a settings verb that has no mapping yet on this provider (U4 decides).
_pf="$SILKOPS_ROOT/ops/lib/providers/$SILKOPS_PROVIDER.sh"
[ -f "$_pf" ] || fail "$EX_USAGE" usage "provider not implemented: $SILKOPS_PROVIDER (have: $(find "$SILKOPS_ROOT/ops/lib/providers" -name '*.sh' -exec basename {} .sh \; | tr '\n' ' '))"
# shellcheck disable=SC1090,SC1091  # which provider file loads is decided at run time
. "$_pf"
p_gitlab_only() { [ "$SILKOPS_PROVIDER" = gitlab ] || fail "$EX_USAGE" usage "$1 is GitLab-only until its $SILKOPS_PROVIDER mapping lands (v0.3 U4)"; }
