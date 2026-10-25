#!/usr/bin/env bash
# Tier 1 tests for the release tooling: scripts/bump.sh, scripts/tag.sh, scripts/lib/release-notes.sh,
# scripts/release.sh and scripts/github-release.sh. Offline: a scratch git repo with two fake tags
# stands in for the real history; gh and curl are never reached (dry runs and refusals only).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUMP="$ROOT/scripts/bump.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-release.XXXXXX")"
PASS=0; FAIL=0
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }
# shellcheck disable=SC2329
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
export PATH="$ROOT/tests/fixtures/gh-stub:$PATH"   # a real gh must never be reached

# A repo with two releases behind it and three commits since, two of them closing issues.
G="$SCRATCH/repo"; mkdir -p "$G/.claude-plugin"
g() { git -C "$G" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
manifests() {
  printf '{\n  "name": "silkops",\n  "version": "%s",\n  "skills": "./skills"\n}\n' "$1" >"$G/.claude-plugin/plugin.json"
  printf '{\n  "name": "silkops",\n  "plugins": [\n    {\n      "name": "silkops",\n      "source": "./",\n      "version": "%s"\n    }\n  ]\n}\n' "$1" >"$G/.claude-plugin/marketplace.json"
}
g init -q -b main >/dev/null
# bump.sh commits with the repo's own identity; CI has no global one, so the scratch repo gets one (R4).
g config user.name t; g config user.email t@t
manifests 0.1.0; g add -A; g commit -qm "release: 0.1.0"; g tag silkops-harness--v0.1.0
echo a >"$G/a"; g add -A; g commit -qm "feat(a): the first thing" -m "Closes #9"
manifests 0.2.0; g add -A; g commit -qm "release: 0.2.0"; g tag silkops-harness--v0.2.0
echo b >"$G/b"; g add -A; g commit -qm "feat(watch): the second thing" -m "Body text." -m "Closes #2, #1"
echo c >"$G/c"; g add -A; g commit -qm "fix(notes): a repair" -m "Closes #2 (again)"
echo d >"$G/d"; g add -A; g commit -qm "chore: tidy"
g switch -qc release/0.3.0
run() { local n="$1"; shift; mkdir -p "$SCRATCH/$n"; (cd "$G" && env -u GH_TOKEN -u CI bash "$BUMP" "$@") >"$SCRATCH/$n/out" 2>"$SCRATCH/$n/err"; echo $? >"$SCRATCH/$n/rc"; }
out_of() { cat "$SCRATCH/$1/out"; }; rc_of() { cat "$SCRATCH/$1/rc"; }; err_of() { cat "$SCRATCH/$1/err"; }

# R1: dry run — plan for both manifests, notes with #1/#2 (deduplicated, sorted) and grouped subjects, nothing committed
run r1 0.3.0 --dry-run
notes="$G/dist/notes-0.3.0.md"
if [ "$(rc_of r1)" = 0 ] && out_of r1 | jq -e '.ok == true and .dry_run == true and .version == "0.3.0" and .previous_tag == "silkops-harness--v0.2.0"
      and .tag == "silkops-harness--v0.3.0" and .commit == null and .issues_closed == [1, 2] and .notes_file == "dist/notes-0.3.0.md"
      and .would_change[".claude-plugin/plugin.json"] == {from: "0.2.0", to: "0.3.0"}
      and .would_change[".claude-plugin/marketplace.json"] == {from: "0.2.0", to: "0.3.0"} and (.next | test("dry-run"))' >/dev/null \
  && [ "$(jq -r .version "$G/.claude-plugin/plugin.json")" = 0.2.0 ] && [ "$(g log --oneline | wc -l | tr -d ' ')" = 6 ] \
  && [ -f "$notes" ] && grep -c '^- #' "$notes" | grep -x 2 >/dev/null \
  && grep -x -- '- #1 — feat(watch): the second thing' "$notes" >/dev/null && grep -x -- '- #2 — feat(watch): the second thing' "$notes" >/dev/null \
  && ! grep -- '#9' "$notes" >/dev/null && grep -x '### feat' "$notes" >/dev/null && grep -x '### fix' "$notes" >/dev/null && grep -x '### other' "$notes" >/dev/null \
  && ! grep -x '### docs' "$notes" >/dev/null && grep -x -- '- chore: tidy' "$notes" >/dev/null && ! grep 'release: 0.2.0' "$notes" >/dev/null \
  && err_of r1 | grep '^## Closes' >/dev/null; then
  pass "R1 bump --dry-run plans both manifests, lists #1 and #2 once each with the closing subject, groups feat/fix/other since the last tag, commits nothing"
else fail "R1" "rc=$(rc_of r1) out=$(out_of r1) notes=$(cat "$notes" 2>&1 | tr '\n' '|')"; fi

# R2: a dirty tree is refused (exit 7) without --dry-run; the manifests are untouched
echo dirty >"$G/a"
run r2 0.3.0
g checkout -q -- a
if [ "$(rc_of r2)" = 7 ] && out_of r2 | jq -e '.ok == false and .error == "dirty_tree"' >/dev/null && [ "$(jq -r .version "$G/.claude-plugin/plugin.json")" = 0.2.0 ]; then
  pass "R2 bump refuses a dirty tree (exit 7)"
else fail "R2" "rc=$(rc_of r2) out=$(out_of r2)"; fi

# R3: the default branch is refused; a bad version and a missing one exit 2
g switch -q main; run r3 0.3.0; g switch -q release/0.3.0
run r3b 1.2; run r3c
if [ "$(rc_of r3)" = 7 ] && out_of r3 | jq -e '.error == "default_branch"' >/dev/null && [ "$(rc_of r3b)" = 2 ] && [ "$(rc_of r3c)" = 2 ]; then
  pass "R3 bump refuses the default branch (exit 7); non-semver or missing version exits 2"
else fail "R3" "rc=$(rc_of r3)/$(rc_of r3b)/$(rc_of r3c) out=$(out_of r3)"; fi

# R4: the real bump sets both versions with 2-space indentation and commits `release: X.Y.Z` on the branch, pushing nothing
run r4 0.3.0
if [ "$(rc_of r4)" = 0 ] && out_of r4 | jq -e '.ok == true and .version == "0.3.0" and .previous_tag == "silkops-harness--v0.2.0" and .issues_closed == [1, 2]
      and (.commit | test("^[0-9a-f]{40}$")) and .branch == "release/0.3.0" and (.next | test("scripts/tag.sh"))' >/dev/null \
  && [ "$(out_of r4 | jq -r .commit)" = "$(g rev-parse HEAD)" ] && [ "$(g log -1 --format=%s)" = "release: 0.3.0" ] \
  && [ "$(jq -r .version "$G/.claude-plugin/plugin.json")" = 0.3.0 ] && [ "$(jq -r '.plugins[0].version' "$G/.claude-plugin/marketplace.json")" = 0.3.0 ] \
  && grep -x '  "version": "0.3.0",' "$G/.claude-plugin/plugin.json" >/dev/null && grep -x '      "version": "0.3.0"' "$G/.claude-plugin/marketplace.json" >/dev/null \
  && [ -z "$(g status --porcelain --untracked-files=no)" ] && [ "$(g diff HEAD~1 --name-only | sort | tr '\n' ' ')" = ".claude-plugin/marketplace.json .claude-plugin/plugin.json " ] \
  && ! g tag | grep -x silkops-harness--v0.3.0 >/dev/null; then
  pass "R4 bump sets both manifests (2-space indent) and commits release: 0.3.0 on the release branch; no tag, clean tree"
else fail "R4" "rc=$(rc_of r4) out=$(out_of r4) err=$(err_of r4 | head -3 | tr '\n' '|') diff=$(g diff HEAD~1 --name-only | tr '\n' ' ')"; fi

# R5: the first release has no previous tag; the whole history is the range
F="$SCRATCH/first"; mkdir -p "$F/.claude-plugin"
f() { git -C "$F" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
f init -q -b main >/dev/null; cp "$G/.claude-plugin/"*.json "$F/.claude-plugin/"; f add -A; f commit -qm "docs: start" -m "Closes #4"
mkdir -p "$SCRATCH/r5"; (cd "$F" && env -u GH_TOKEN bash "$BUMP" 0.1.0 --dry-run) >"$SCRATCH/r5/out" 2>"$SCRATCH/r5/err"; echo $? >"$SCRATCH/r5/rc"
if [ "$(rc_of r5)" = 0 ] && out_of r5 | jq -e '.previous_tag == null and .issues_closed == [4]' >/dev/null && grep -x 'First release.' "$F/dist/notes-0.1.0.md" >/dev/null; then
  pass "R5 without a previous tag the notes cover the whole history and previous_tag is null"
else fail "R5" "rc=$(rc_of r5) out=$(out_of r5) err=$(err_of r5 | head -3 | tr '\n' '|')"; fi

# R6: this repo's manifests agree with each other and are semver
pv="$(jq -r .version "$ROOT/.claude-plugin/plugin.json")"; mv="$(jq -r '.plugins[0].version' "$ROOT/.claude-plugin/marketplace.json")"
if [ "$pv" = "$mv" ] && [[ "$pv" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  pass "R6 plugin.json ($pv) and marketplace.json ($mv) agree and are X.Y.Z"
else fail "R6" "plugin.json=$pv marketplace.json=$mv"; fi

# R7: release.sh refuses (exit 7) when the tag disagrees with marketplace.json, before any git or network step
C="$SCRATCH/copy"; mkdir -p "$C"
cp -R "$ROOT/scripts" "$ROOT/ops" "$ROOT/.claude-plugin" "$C/"
jq '.plugins[0].version = "9.9.9"' "$ROOT/.claude-plugin/marketplace.json" >"$C/.claude-plugin/marketplace.json"
mkdir -p "$SCRATCH/r7"
(cd "$C" && env -u GH_TOKEN CI_COMMIT_TAG="silkops-harness--v${pv}" CI_API_V4_URL=http://127.0.0.1:9 CI_PROJECT_ID=1 CI_JOB_TOKEN=x bash scripts/release.sh) >"$SCRATCH/r7/out" 2>"$SCRATCH/r7/err"; echo $? >"$SCRATCH/r7/rc"
(cd "$C" && env -u GH_TOKEN CI_COMMIT_TAG="silkops-harness--v0.0.1" CI_API_V4_URL=http://127.0.0.1:9 CI_PROJECT_ID=1 CI_JOB_TOKEN=x bash scripts/release.sh) >"$SCRATCH/r7/out2" 2>"$SCRATCH/r7/err2"; echo $? >"$SCRATCH/r7/rc2"
if [ "$(rc_of r7)" = 7 ] && out_of r7 | jq -e '.ok == false and .error == "refused" and (.message | test("marketplace.json version 9.9.9"))' >/dev/null && [ ! -d "$C/dist" ] \
  && [ "$(cat "$SCRATCH/r7/rc2")" = 7 ] && jq -e '.message | test("plugin.json")' "$SCRATCH/r7/out2" >/dev/null; then
  pass "R7 release.sh refuses a tag that disagrees with marketplace.json or plugin.json (exit 7) before building anything"
else fail "R7" "rc=$(rc_of r7)/$(cat "$SCRATCH/r7/rc2") out=$(out_of r7) err=$(err_of r7 | tr '\n' '|')"; fi

# R8: github-release.sh --dry-run is a JSON plan: title SilkOps X.Y.Z, notes file, create command; --update adds the edit command
mkdir -p "$SCRATCH/r8"
(cd "$ROOT" && env -u GH_TOKEN bash scripts/github-release.sh --repo OpenZephyr/SilkOps --tag "silkops-harness--v${pv}" --dry-run) >"$SCRATCH/r8/out" 2>"$SCRATCH/r8/err"; echo $? >"$SCRATCH/r8/rc"
(cd "$ROOT" && env -u GH_TOKEN bash scripts/github-release.sh --repo OpenZephyr/SilkOps --tag "silkops-harness--v${pv}" --dry-run --update) >"$SCRATCH/r8/out2" 2>/dev/null; echo $? >"$SCRATCH/r8/rc2"
(cd "$ROOT" && env -u GH_TOKEN bash scripts/github-release.sh --repo OpenZephyr/SilkOps --tag "v1" --dry-run) >/dev/null 2>&1; echo $? >"$SCRATCH/r8/rc3"
if [ "$(rc_of r8)" = 0 ] && out_of r8 | jq -e --arg v "$pv" '.ok == true and .dry_run == true and .repo == "OpenZephyr/SilkOps" and .version == $v and .tag == ("silkops-harness--v" + $v)
      and .title == ("SilkOps " + $v) and .asset == ("dist/silkops-harness-" + $v + ".tar.gz") and .notes_file == ("dist/notes-" + $v + ".md") and .update == false and .update_command == null
      and (.command | test("^gh release create silkops-harness--v")) and (.command | test("--title \"SilkOps " + $v + "\"")) and (.command | test("--notes-file dist/notes-"))' >/dev/null \
  && [ "$(cat "$SCRATCH/r8/rc2")" = 0 ] && jq -e '.update == true and (.update_command | test("^gh release edit "))' "$SCRATCH/r8/out2" >/dev/null \
  && [ "$(cat "$SCRATCH/r8/rc3")" = 2 ]; then
  pass "R8 github-release.sh --dry-run prints the plan (title, notes file, create command; edit command with --update); a bad tag exits 2"
else fail "R8" "rc=$(rc_of r8)/$(cat "$SCRATCH/r8/rc2")/$(cat "$SCRATCH/r8/rc3") out=$(out_of r8) out2=$(cat "$SCRATCH/r8/out2")"; fi

# R9: tag.sh — refused off main, when behind the remote, or when the tag exists; cuts and pushes an annotated tag at the remote's head
TAGSH="$ROOT/scripts/tag.sh"; T="$SCRATCH/tagrepo"; R="$SCRATCH/tagremote.git"
git init -q --bare "$R"; git -C "$R" symbolic-ref HEAD refs/heads/main
git clone -q "$R" "$T" 2>/dev/null; t() { git -C "$T" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
t checkout -q -b main; mkdir -p "$T/.claude-plugin"
printf '{\n  "name": "silkops",\n  "version": "0.3.0"\n}\n' >"$T/.claude-plugin/plugin.json"
printf '{\n  "plugins": [\n    {\n      "name": "silkops",\n      "version": "0.3.0"\n    }\n  ]\n}\n' >"$T/.claude-plugin/marketplace.json"
t add -A; t commit -qm "release: 0.3.0"; t push -q -u origin main 2>/dev/null; t remote set-head origin -a >/dev/null 2>&1
trun() { local n="$1"; shift; mkdir -p "$SCRATCH/$n"; (cd "$T" && bash "$TAGSH" "$@") >"$SCRATCH/$n/out" 2>"$SCRATCH/$n/err"; echo $? >"$SCRATCH/$n/rc"; }
t checkout -q -b release/0.3.0; trun r9a; t checkout -q main                                   # off main
trun r9b --dry-run; dry_tags="$(t tag)"                                                          # plan only: no tag yet
t commit -q --allow-empty -m "local only"; trun r9c; t reset -q --hard origin/main               # ahead of the remote
trun r9d                                                                                         # the real tag
trun r9e                                                                                         # again: exists
if [ "$(rc_of r9a)" = 7 ] && out_of r9a | jq -e '.error == "not_default_branch"' >/dev/null \
  && [ "$(rc_of r9b)" = 0 ] && out_of r9b | jq -e '.dry_run == true and .tag == "silkops-harness--v0.3.0" and .pushed == false' >/dev/null && [ -z "$dry_tags" ] \
  && [ "$(rc_of r9c)" = 7 ] && out_of r9c | jq -e '.error == "behind_remote"' >/dev/null \
  && [ "$(rc_of r9d)" = 0 ] && out_of r9d | jq -e '.ok == true and .version == "0.3.0" and .tag == "silkops-harness--v0.3.0" and .pushed == true' >/dev/null \
  && [ "$(t cat-file -t silkops-harness--v0.3.0)" = tag ] && [ "$(t tag -l --format='%(contents:subject)' silkops-harness--v0.3.0)" = "SilkOps 0.3.0" ] \
  && git -C "$R" rev-parse -q --verify refs/tags/silkops-harness--v0.3.0 >/dev/null && [ "$(out_of r9d | jq -r .commit)" = "$(t rev-parse HEAD)" ] \
  && [ "$(rc_of r9e)" = 7 ] && out_of r9e | jq -e '.error == "tag_exists"' >/dev/null; then
  pass "R9 tag.sh refuses a non-default branch, a HEAD ahead of the remote and an existing tag (exit 7); cuts annotated SilkOps 0.3.0 and pushes only the tag"
else fail "R9" "rc=$(rc_of r9a)/$(rc_of r9b)/$(rc_of r9c)/$(rc_of r9d)/$(rc_of r9e) d=$(out_of r9d) e=$(err_of r9d | tr '\n' '|') c=$(out_of r9c)"; fi

echo "test-release: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
