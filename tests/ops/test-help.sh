#!/usr/bin/env bash
# Tier 1 (#74): every ops/*.sh answers --help with its usage line — exit 2 (the prelude's `usage`
# is a usage failure) or 0 — and never with "unknown argument". Offline, no tokens, no glab.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }
for s in "$ROOT"/ops/*.sh; do
  name="$(basename "$s" .sh)"
  out="$(env -u CI -u GITLAB_TOKEN -u GITLAB_HOST -u SILKOPS_CI_TOKEN -u SILKOPS_SETTINGS_TOKEN bash "$s" --help 2>&1)"; rc=$?
  if { [ "$rc" = 0 ] || [ "$rc" = 2 ]; } && ! printf '%s' "$out" | grep -F 'unknown argument' >/dev/null \
    && printf '%s' "$out" | grep -F 'usage' >/dev/null; then
    pass "H-$name --help answers the usage line (exit $rc)"
  else fail "H-$name" "rc=$rc out=$(printf '%s' "$out" | head -c 300)"; fi
done
echo "test-help: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
