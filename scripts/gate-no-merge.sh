#!/usr/bin/env bash
# Verification Contract gate: no merge verb and no protected-branch write in skills/ or ops/.
# The read in ops/token-check.sh (informational can_merge/can_push) is the single sanctioned
# protected_branches reference; anything else fails the gate.
set -euo pipefail
cd "$(dirname "$0")/.."
hits="$(grep -rnE 'mr merge|/merge([^_a-zA-Z]|$)|protected_branches' skills ops | grep -v '^ops/token-check.sh:.*protected_branches' || true)"
if [ -n "$hits" ]; then
  echo "gate-no-merge: forbidden references:" >&2
  echo "$hits" >&2
  exit 1
fi
echo "gate-no-merge: clean"
