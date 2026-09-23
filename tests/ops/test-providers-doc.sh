#!/usr/bin/env bash
# Tier 1 (v0.3 U6): every fallback and refusal name the providers use has a row in docs/providers.md,
# and every provider file is named there.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOC="$ROOT/docs/providers.md"
PASS=0; FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }
[ -f "$DOC" ] && pass "P0 docs/providers.md exists" || fail "P0" "missing"
for name in managed_region relates_to not_applicable p_gitlab_only "experimental: true"; do
  if grep -rq -- "$name" "$ROOT/ops"; then
    if grep -q -- "$name" "$DOC"; then pass "P1 '$name' used by the code has a row in the concept map"; else fail "P1 $name" "used in ops/ but not documented"; fi
  fi
done
for f in "$ROOT"/ops/lib/providers/*.sh; do
  n="$(basename "$f" .sh)"
  if grep -q "| $n\b\|$n" "$DOC"; then pass "P2 provider '$n' is in the concept map"; else fail "P2 $n" "not in docs/providers.md"; fi
done
echo "test-providers-doc: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
