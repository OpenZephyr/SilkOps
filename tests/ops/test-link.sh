#!/usr/bin/env bash
# Tier 1 tests for ops/link.sh (#90): a permalink to a file and line range pinned at a sha, in the
# host's own format. Offline: a scratch git repo with one committed file, --project-url given, no
# tokens, so no provider call is ever made.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/ops/link.sh"
BIN="$ROOT/bin/silkops"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-link.XXXXXX")"
PASS=0; FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }
# shellcheck disable=SC2329
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT

# the repo: one file with two commits, a tag on the first, no origin remote
REPO="$SCRATCH/repo"; mkdir -p "$REPO/ops"
G=(git -C "$REPO" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false)
"${G[@]}" init -q -b main "$REPO" >/dev/null 2>&1 || "${G[@]}" init -q "$REPO"
printf 'one\ntwo\nthree\n' >"$REPO/ops/a file.sh"; printf 'x\n' >"$REPO/README.md"
"${G[@]}" add -A; "${G[@]}" commit -q -m first; "${G[@]}" tag v1
SHA1="$("${G[@]}" rev-parse HEAD)"
printf 'four\n' >>"$REPO/ops/a file.sh"; printf 'y\n' >"$REPO/later.md"
"${G[@]}" add -A; "${G[@]}" commit -q -m second
SHA2="$("${G[@]}" rev-parse HEAD)"

# run <name> <provider> <args…> — from inside the repo, no tokens in the environment
run() {
  local n="$1" prov="$2"; shift 2; mkdir -p "$SCRATCH/$n"
  (cd "$REPO" && env -u SILKOPS_CI_TOKEN -u SILKOPS_SETTINGS_TOKEN -u GITLAB_TOKEN -u GH_TOKEN -u GITEA_TOKEN -u CI -u SILKOPS_PROJECT_URL \
    SILKOPS_PROVIDER="$prov" bash "$SCRIPT" "$@") >"$SCRATCH/$n/out" 2>"$SCRATCH/$n/err"; echo $? >"$SCRATCH/$n/rc"
}
out_of() { cat "$SCRATCH/$1/out"; }; rc_of() { cat "$SCRATCH/$1/rc"; }; err_of() { cat "$SCRATCH/$1/err"; }
P=g/p; U=https://host.example/g/p

# L1: GitLab range, single line, whole file; the path's space is percent-encoded
run l1 gitlab --project $P --path 'ops/a file.sh' --line 2-3 --project-url "$U/"
run l1b gitlab --project $P --path 'ops/a file.sh' --line 2 --project-url "$U"
run l1c gitlab --project $P --path README.md --project-url "$U"
if [ "$(rc_of l1)" = 0 ] && out_of l1 | jq -e --arg u "$U/-/blob/$SHA2/ops/a%20file.sh#L2-3" --arg s "$SHA2" '.ok == true and .provider == "gitlab" and .url == $u and .sha == $s and .path == "ops/a file.sh" and .line == "2-3" and .checked == true' >/dev/null \
  && out_of l1b | jq -e --arg u "$U/-/blob/$SHA2/ops/a%20file.sh#L2" '.url == $u and .line == "2"' >/dev/null \
  && out_of l1c | jq -e --arg u "$U/-/blob/$SHA2/README.md" '.url == $u and .line == null' >/dev/null; then
  pass "L1 gitlab: <url>/-/blob/<sha>/<path>#L2-3, #L2 for one line, no fragment without --line; HEAD by default"
else fail "L1" "rc=$(rc_of l1) out=$(out_of l1) $(out_of l1b) $(out_of l1c) err=$(err_of l1)"; fi

# L2: GitHub and Gitea formats
run l2 github --project o/r --path README.md --line 1-2 --project-url https://github.com/o/r
run l2b github --project o/r --path README.md --line 1 --project-url https://github.com/o/r
run l2c gitea --project o/r --path README.md --line 1-2 --project-url https://gitea.example/o/r
run l2d gitea --project o/r --path README.md --line 1 --project-url https://gitea.example/o/r
if out_of l2 | jq -e --arg u "https://github.com/o/r/blob/$SHA2/README.md#L1-L2" '.provider == "github" and .url == $u' >/dev/null \
  && out_of l2b | jq -e --arg u "https://github.com/o/r/blob/$SHA2/README.md#L1" '.url == $u' >/dev/null \
  && out_of l2c | jq -e --arg u "https://gitea.example/o/r/src/commit/$SHA2/README.md#L1-L2" '.provider == "gitea" and .experimental == true and .url == $u' >/dev/null \
  && out_of l2d | jq -e --arg u "https://gitea.example/o/r/src/commit/$SHA2/README.md#L1" '.url == $u' >/dev/null; then
  pass "L2 github blob/<sha>#L1-L2 and gitea src/commit/<sha>#L1-L2 (L1 alone for one line)"
else fail "L2" "$(out_of l2) $(out_of l2b) $(out_of l2c) $(out_of l2d)"; fi

# L3: --sha as a tag and as a short sha resolve; a path that does not exist at that sha is exit 5
run l3 gitlab --project $P --path README.md --line 1 --sha v1 --project-url "$U"
run l3b gitlab --project $P --path README.md --sha "${SHA2:0:8}" --project-url "$U"
run l3c gitlab --project $P --path later.md --sha v1 --project-url "$U"
run l3d gitlab --project $P --path later.md --sha v1 --project-url "$U" --no-check
run l3e gitlab --project $P --path nope.md --project-url "$U"
if [ "$(rc_of l3)" = 0 ] && out_of l3 | jq -e --arg s "$SHA1" --arg u "$U/-/blob/$SHA1/README.md#L1" '.sha == $s and .url == $u' >/dev/null \
  && out_of l3b | jq -e --arg s "$SHA2" '.sha == $s' >/dev/null \
  && [ "$(rc_of l3c)" = 5 ] && out_of l3c | jq -e '.ok == false and .error == "not_found" and .path == "later.md"' >/dev/null \
  && [ "$(rc_of l3d)" = 0 ] && out_of l3d | jq -e '.checked == false and (.url | endswith("/later.md"))' >/dev/null \
  && [ "$(rc_of l3e)" = 5 ]; then
  pass "L3 --sha tag and short sha resolve to the full sha; a path absent at the sha is exit 5 unless --no-check"
else fail "L3" "rc=$(rc_of l3)/$(rc_of l3b)/$(rc_of l3c)/$(rc_of l3d)/$(rc_of l3e) out=$(out_of l3) $(out_of l3c)"; fi

# L4: bad --line shapes are exit 2; an unresolvable --sha is exit 5; usage without --project/--path is 2
for bad in 0 3-2 a 1- -2 "1-2-3"; do run "l4-$bad" gitlab --project $P --path README.md --line "$bad" --project-url "$U"; done
run l4s gitlab --project $P --path README.md --sha nosuchref --project-url "$U"
run l4p gitlab --path README.md --project-url "$U"
run l4q gitlab --project $P --project-url "$U"
ok=true; for bad in 0 3-2 a 1- -2 "1-2-3"; do [ "$(rc_of "l4-$bad")" = 2 ] || ok=false; done
if [ "$ok" = true ] && out_of l4-3-2 | jq -e '.error == "usage"' >/dev/null && [ "$(rc_of l4s)" = 5 ] && [ "$(rc_of l4p)" = 2 ] && [ "$(rc_of l4q)" = 2 ]; then
  pass "L4 --line 0, 3-2, a, 1-, -2, 1-2-3 are exit 2; unknown --sha is 5; missing --project or --path is 2"
else fail "L4" "rcs: $(for bad in 0 3-2 a 1- -2 "1-2-3"; do rc_of "l4-$bad"; done | tr '\n' ' ') sha=$(rc_of l4s) p=$(rc_of l4p) q=$(rc_of l4q)"; fi

# L5: no token, no --project-url: the URL comes from the provider's known host, no network;
#     SILKOPS_PROJECT_URL is honoured; a range a-a collapses to a
run l5 gitlab --project $P --path README.md
mkdir -p "$SCRATCH/l5b"; (cd "$REPO" && env -u SILKOPS_CI_TOKEN -u GH_TOKEN -u CI SILKOPS_PROVIDER=github SILKOPS_PROJECT_URL=https://ghe.example/o/r bash "$SCRIPT" --project o/r --path README.md --line 2-2) >"$SCRATCH/l5b/out" 2>"$SCRATCH/l5b/err"; echo $? >"$SCRATCH/l5b/rc"
mkdir -p "$SCRATCH/l5c"; (cd "$REPO" && env -u SILKOPS_CI_TOKEN -u CI SILKOPS_PROVIDER=gitlab GITLAB_HOST=https://gl.example bash "$SCRIPT" --project $P --path README.md) >"$SCRATCH/l5c/out" 2>"$SCRATCH/l5c/err"; echo $? >"$SCRATCH/l5c/rc"
if [ "$(rc_of l5)" = 0 ] && out_of l5 | jq -e --arg u "https://gitlab.com/g/p/-/blob/$SHA2/README.md" '.url == $u and .project_url_source == "default"' >/dev/null \
  && [ "$(rc_of l5b)" = 0 ] && out_of l5b | jq -e --arg u "https://ghe.example/o/r/blob/$SHA2/README.md#L2" '.url == $u and .line == "2" and .project_url_source == "env"' >/dev/null \
  && [ "$(rc_of l5c)" = 0 ] && out_of l5c | jq -e '.project_url == "https://gl.example/g/p"' >/dev/null; then
  pass "L5 without a token the URL is built from the known host (gitlab.com, GITLAB_HOST, SILKOPS_PROJECT_URL); 2-2 collapses to 2"
else fail "L5" "rc=$(rc_of l5)/$(rc_of l5b)/$(rc_of l5c) out=$(out_of l5) $(out_of l5b) $(out_of l5c) err=$(err_of l5)"; fi

# L6: the verb is reachable through bin/silkops
mkdir -p "$SCRATCH/l6"; (cd "$REPO" && env -u SILKOPS_CI_TOKEN -u CI SILKOPS_PROVIDER=gitlab bash "$BIN" link --project $P --path README.md --line 1 --project-url "$U") >"$SCRATCH/l6/out" 2>"$SCRATCH/l6/err"; echo $? >"$SCRATCH/l6/rc"
if [ "$(rc_of l6)" = 0 ] && out_of l6 | jq -e --arg u "$U/-/blob/$SHA2/README.md#L1" '.url == $u' >/dev/null && bash "$BIN" --help | grep -x '  link' >/dev/null; then
  pass "L6 'silkops link' dispatches to ops/link.sh and --help lists the verb"
else fail "L6" "rc=$(rc_of l6) out=$(out_of l6) err=$(err_of l6)"; fi

echo "test-link: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
