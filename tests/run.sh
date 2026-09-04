#!/usr/bin/env bash
# Tier 1 entry point: every tests/ops/test-*.sh plus python unittest discovery
# over tests/ops/test_*.py. Offline; exits nonzero on any failure.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUITES=0; FAILED=0; FAILED_NAMES=""

for t in "$ROOT"/tests/ops/test-*.sh; do
  [ -e "$t" ] || continue
  SUITES=$((SUITES + 1))
  echo "=== $(basename "$t")"
  if ! bash "$t"; then FAILED=$((FAILED + 1)); FAILED_NAMES="$FAILED_NAMES $(basename "$t")"; fi
done

if ls "$ROOT"/tests/ops/test_*.py >/dev/null 2>&1; then
  SUITES=$((SUITES + 1))
  echo "=== python unittest (tests/ops/test_*.py)"
  if ! (cd "$ROOT" && python3 -m unittest discover -s tests/ops -p 'test_*.py'); then
    FAILED=$((FAILED + 1)); FAILED_NAMES="$FAILED_NAMES python-unittest"
  fi
fi

echo "tests/run.sh: $SUITES suites, $FAILED failed${FAILED_NAMES:+ (${FAILED_NAMES# })}"
[ "$FAILED" = 0 ]
