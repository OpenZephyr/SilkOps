#!/usr/bin/env bash
# Tier 1 (v0.2 U8, R10): every skill loads cheaply and opens with its result shape.
# A SKILL.md is at most 2500 bytes and the first line after the frontmatter title names the
# result (the word "Result" in its first paragraph), so a session knows the shape before the steps.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }
LIMIT=2500
for f in "$ROOT"/skills/*/SKILL.md; do
  name="$(basename "$(dirname "$f")")"
  size="$(wc -c <"$f" | tr -d ' ')"
  # first paragraph after the frontmatter and the H1
  first="$(awk 'BEGIN{fm=0} /^---$/{fm++; next} fm<2{next} /^# /{next} /^[[:space:]]*$/{if (p) exit; next} {p=p $0 " "} END{print p}' "$f")"
  if [ "$size" -le "$LIMIT" ] && printf '%s' "$first" | grep -q 'Result' && ! grep -q 'CLAUDE_PLUGIN_ROOT' "$f"; then
    pass "S-$name ${size}B, opens with its result shape, no agent-specific path"
  else fail "S-$name" "size=${size}B (limit $LIMIT); plugin var: $(grep -c CLAUDE_PLUGIN_ROOT "$f"); first paragraph: ${first:0:90}"; fi
done
echo "test-skill-size: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
