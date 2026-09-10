#!/usr/bin/env bash
# Verification Contract gate: no merge verb, no merge endpoint, no protected-branch write, and no
# push to a protected branch anywhere in skills/, ops/, or references/. The read in
# ops/token-check.sh (informational can_merge/can_push) is the single sanctioned
# protected_branches reference; anything else fails the gate.
# `--self-test` feeds known evasions through the pattern and expects each to be caught.
set -euo pipefail
cd "$(dirname "$0")/.."
PATTERN='mr (merge|accept)|/merge([^_a-zA-Z]|$)|mergeRequestAccept|mergeRequestSetAutoMerge|merge_when_pipeline_succeeds|git push [^;|&]*(main|master|:refs/heads/)|protected_branches|branchRule'
ALLOW='^ops/token-check\.sh:.*protected_branches'
if [ "${1:-}" = "--self-test" ]; then
  fails=0
  while IFS= read -r line; do
    if ! printf '%s\n' "$line" | grep -qE "$PATTERN"; then echo "self-test: NOT caught: $line" >&2; fails=$((fails + 1)); fi
  done <<'EOF'
glab mr merge 12
glab mr accept 12
glab api -X PUT projects/1/merge_requests/12/merge
mutation { mergeRequestAccept(input: {}) }
mergeRequestSetAutoMerge
git push origin HEAD:main
git push origin feature:refs/heads/main
glab api -X POST projects/1/protected_branches
EOF
  # and a legitimate read must not trip it
  if printf '%s\n' 'glab api projects/1/merge_requests/12' | grep -qE "$PATTERN"; then echo "self-test: false positive on merge_requests read" >&2; fails=$((fails + 1)); fi
  [ "$fails" -eq 0 ] && echo "gate-no-merge self-test: ok" || exit 1
  exit 0
fi
hits="$(grep -rnE "$PATTERN" skills ops references | grep -vE "$ALLOW" || true)"
if [ -n "$hits" ]; then
  echo "gate-no-merge: forbidden references:" >&2
  echo "$hits" >&2
  exit 1
fi
echo "gate-no-merge: clean"
