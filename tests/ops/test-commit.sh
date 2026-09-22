#!/usr/bin/env bash
# Tier 1 tests for ops/commit.sh (v0.2 U5, #43): stage by name, message by file checked against
# the repo's own history, trailers stripped unless the repo asks for them. Offline, scratch repos.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/ops/commit.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-commit.XXXXXX")"
PASS=0; FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }
# shellcheck disable=SC2329
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
# The operator's global git config (signing, hooks) must not reach the scratch repos.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
# mkrepo <dir> <prefixed:true|false> — a repo with 5 commits on main and a feature branch checked out
mkrepo() {
  local d="$1" pre="$2" i
  mkdir -p "$d"; git -C "$d" init -q -b main
  for i in 1 2 3 4 5; do
    echo "$i" >"$d/f$i"; git -C "$d" add "f$i"
    if [ "$pre" = true ]; then git -C "$d" -c user.name=t -c user.email=t@t commit -qm "feat(core): add f$i"
    else git -C "$d" -c user.name=t -c user.email=t@t commit -qm "Add f$i"; fi
  done
  git -C "$d" switch -qc feat/x
}
run() { local n="$1" d="$2"; shift 2; mkdir -p "$SCRATCH/$n"; (cd "$d" && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t bash "$SCRIPT" "$@") >"$SCRATCH/$n/out" 2>"$SCRATCH/$n/err"; echo $? >"$SCRATCH/$n/rc"; }
out_of() { cat "$SCRATCH/$1/out"; }; rc_of() { cat "$SCRATCH/$1/rc"; }; err_of() { cat "$SCRATCH/$1/err"; }
msg() { local f; f="$(mktemp "$SCRATCH/msg.XXXXXX")"; printf '%s\n' "$@" >"$f"; echo "$f"; }

# K1: default branch refused, nothing written
R="$SCRATCH/repo-k1"; mkrepo "$R" false; git -C "$R" switch -q main; echo x >"$R/new"
M="$(msg "Add new" "" "Co-Authored-By: Bot <b@b>")"
run k1 "$R" --path new --message-file "$M"
if [ "$(rc_of k1)" = 7 ] && out_of k1 | jq -e '.ok == false and .error == "refused"' >/dev/null && [ "$(git -C "$R" rev-list --count main)" = 5 ]; then
  pass "K1 on the default branch -> exit 7, no commit"
else fail "K1" "rc=$(rc_of k1) out=$(out_of k1)"; fi

# K2: stage by name only, trailers stripped by default, JSON reports what happened
R="$SCRATCH/repo-k2"; mkrepo "$R" false; echo x >"$R/new"; echo dirty >"$R/f1"
M="$(msg "Add new" "" "Body line." "" "Co-Authored-By: Bot <b@b>" "Signed-off-by: x")"
run k2 "$R" --path new --message-file "$M"
if [ "$(rc_of k2)" = 0 ] && out_of k2 | jq -e '.ok == true and .subject == "Add new" and .files == ["new"] and .trailers_removed == 2 and .branch == "feat/x" and (.sha | length) >= 7' >/dev/null \
  && [ "$(git -C "$R" log -1 --format=%B | grep -c 'Co-Authored-By\|Signed-off-by')" = 0 ] \
  && git -C "$R" log -1 --format=%B | grep -x 'Body line.' >/dev/null \
  && [ "$(git -C "$R" status --porcelain)" = " M f1" ]; then
  pass "K2 stages only the named path (f1 stays dirty), strips two trailers, reports sha/subject/files"
else fail "K2" "rc=$(rc_of k2) out=$(out_of k2) err=$(err_of k2) log=$(git -C "$R" log -1 --format=%B) st=$(git -C "$R" status --porcelain)"; fi

# K3: --trailers repo keeps them
R="$SCRATCH/repo-k3"; mkrepo "$R" false; echo x >"$R/new"
M="$(msg "Add new" "" "Co-Authored-By: Bot <b@b>")"
run k3 "$R" --path new --message-file "$M" --trailers repo
if [ "$(rc_of k3)" = 0 ] && out_of k3 | jq -e '.trailers_removed == 0' >/dev/null && git -C "$R" log -1 --format=%B | grep -F 'Co-Authored-By: Bot' >/dev/null; then
  pass "K3 --trailers repo keeps the trailer"
else fail "K3" "rc=$(rc_of k3) out=$(out_of k3)"; fi

# K4: style follows the history — prefix refused on an unprefixed history, required on a prefixed one
R="$SCRATCH/repo-k4"; mkrepo "$R" false; echo x >"$R/new"; M="$(msg "feat: add new")"
run k4 "$R" --path new --message-file "$M"
R2="$SCRATCH/repo-k4b"; mkrepo "$R2" true; echo x >"$R2/new"; M2="$(msg "Add new")"
run k4b "$R2" --path new --message-file "$M2"
if [ "$(rc_of k4)" = 7 ] && out_of k4 | jq -e '.error == "style"' >/dev/null && [ "$(rc_of k4b)" = 7 ] && out_of k4b | jq -e '.error == "style"' >/dev/null \
  && [ "$(git -C "$R" rev-list --count HEAD)" = 5 ] && [ "$(git -C "$R2" rev-list --count HEAD)" = 5 ]; then
  pass "K4 a type(scope): prefix is refused where the history has none and required where it does"
else fail "K4" "rc=$(rc_of k4)/$(rc_of k4b) out=$(out_of k4) / $(out_of k4b)"; fi

# K5: long subject refused; no path and nothing staged -> usage
R="$SCRATCH/repo-k5"; mkrepo "$R" false; echo x >"$R/new"
M="$(msg "$(printf 'A%.0s' $(seq 1 80))")"; run k5 "$R" --path new --message-file "$M"
M2="$(msg "Add new")"; run k5b "$R" --message-file "$M2"
if [ "$(rc_of k5)" = 7 ] && out_of k5 | jq -e '.error == "style"' >/dev/null && [ "$(rc_of k5b)" = 2 ]; then
  pass "K5 subject over 72 chars -> exit 7 style; nothing named and nothing staged -> exit 2"
else fail "K5" "rc=$(rc_of k5)/$(rc_of k5b) out=$(out_of k5) / $(out_of k5b)"; fi

echo "test-commit: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
