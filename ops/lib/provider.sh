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

# dead_mentions <text> — the @handles in <text> the provider does not know, as a JSON array
# (#84, shared by issue-upsert and issue-edit). A lookup that fails counts as unknown. Never
# fails: the caller warns and reports `dead_mentions[]`, it does not refuse. Emails (x@y) and
# @group/path mentions are skipped.
dead_mentions() {
  local h out='[]' found
  for h in $(printf '%s\n' "$1" | grep -oE '(^|[^A-Za-z0-9_./-])@[A-Za-z0-9][A-Za-z0-9_.-]*[A-Za-z0-9_]' | sed -E 's/^[^@]*@//' | sort -u); do
    found="$(p_user_lookup "$h" 2>/dev/null | jq -r --arg u "$h" '[.[]? | select(.username == $u)] | length' 2>/dev/null || echo 0)"
    [ "${found:-0}" -gt 0 ] 2>/dev/null || out="$(jq -cn --argjson a "$out" --arg h "$h" '$a + [$h]')"
  done
  printf '%s\n' "$out"
}
