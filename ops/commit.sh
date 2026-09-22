#!/usr/bin/env bash
# commit.sh — commit named paths with a message checked against the repo's own style (v0.2 U5, #43).
#
# Usage: commit.sh --message-file <f> [--path <p>]... [--trailers none|repo]
#
# Refuses the default branch and a detached HEAD (exit 7). Stages ONLY the named paths and
# commits only them; with no --path, commits what is already staged (nothing staged → usage).
# The subject is at most 72 characters; a `type(scope):` prefix is refused when the last 20
# subjects carry none and required when at least half do. `--trailers none` (the default,
# also SILKOPS_TRAILERS) strips Co-Authored-By / Signed-off-by / Generated-by style trailers
# and "Generated with" lines; `repo` keeps the message as written. Never pushes.
# Result: {sha, subject, files[], trailers_removed, branch, trailers}. Exit 0 · 2 usage · 7 refused/style · 1 other.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"

usage() { fail "$EX_USAGE" usage "usage: commit.sh --message-file <f> [--path <p>]... [--trailers none|repo]${1:+ — $1}"; }
MSG_FILE=""; PATHS=(); TRAILERS="${SILKOPS_TRAILERS:-none}"
while [ $# -gt 0 ]; do
  case "$1" in
    --message-file) [ $# -ge 2 ] || usage; MSG_FILE="$2"; shift 2 ;;
    --path) [ $# -ge 2 ] || usage; PATHS+=("$2"); shift 2 ;;
    --trailers) [ $# -ge 2 ] || usage; TRAILERS="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
if ! { [ -n "$MSG_FILE" ] && [ -f "$MSG_FILE" ]; }; then usage "--message-file must name a readable file"; fi
case "$TRAILERS" in none|repo) ;; *) usage "--trailers must be none or repo" ;; esac
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "$EX_NOT_FOUND" not_found "not inside a git checkout"

BRANCH="$(git branch --show-current)"
[ -n "$BRANCH" ] || fail "$EX_REFUSED" refused "detached HEAD: check out a feature branch first"
DEFAULT="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"
if [ -z "$DEFAULT" ]; then for b in main master; do git show-ref -q --verify "refs/heads/$b" && DEFAULT="$b" && break; done; fi
[ "$BRANCH" != "$DEFAULT" ] || fail "$EX_REFUSED" refused "on the default branch ($BRANCH); this script commits feature branches only"
if [ "${#PATHS[@]}" -eq 0 ] && [ -z "$(git diff --cached --name-only)" ]; then usage "nothing is staged and no --path was named"; fi

# --- message: style from the history, trailers by policy ---------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/silkops-commit.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
SUBJECT="$(head -1 "$MSG_FILE")"
[ "${#SUBJECT}" -le 72 ] || fail "$EX_REFUSED" style "subject is ${#SUBJECT} characters; keep it at 72 or fewer"
PREFIX_RE='^[a-z]+(\([^)]*\))?!?: '
hist=0; pre=0
while IFS= read -r line; do
  hist=$((hist + 1)); [[ "$line" =~ $PREFIX_RE ]] && pre=$((pre + 1))
done < <(git log -20 --format=%s 2>/dev/null)
if [[ "$SUBJECT" =~ $PREFIX_RE ]]; then
  [ "$pre" -gt 0 ] || fail "$EX_REFUSED" style "the last $hist subjects carry no type(scope): prefix; write \"$SUBJECT\" without one"
elif [ "$hist" -gt 0 ] && [ $((pre * 2)) -ge "$hist" ]; then
  fail "$EX_REFUSED" style "$pre of the last $hist subjects use a type(scope): prefix; add one"
fi
REMOVED=0
if [ "$TRAILERS" = none ]; then
  TR_RE='^(Co-[Aa]uthored-[Bb]y|Signed-off-by|Generated-by|Generated-with|Assisted-by|Reviewed-by):|Generated with \[|^🤖'
  REMOVED="$(grep -cE "$TR_RE" "$MSG_FILE" || true)"
  # drop the trailer lines, then any blank lines left at the end
  grep -vE "$TR_RE" "$MSG_FILE" | awk '{l[NR]=$0} END{n=NR; while (n > 0 && l[n] ~ /^[[:space:]]*$/) n--; for (i = 1; i <= n; i++) print l[i]}' >"$TMP/msg"
else
  cp "$MSG_FILE" "$TMP/msg"
fi

# --- stage by name, commit only that -------------------------------------------
if [ "${#PATHS[@]}" -gt 0 ]; then
  git add -- "${PATHS[@]}"
  git commit -q -F "$TMP/msg" -- "${PATHS[@]}" 2>"$TMP/err" || fail "$EX_OTHER" commit_failed "git commit failed: $(redact <"$TMP/err" | tr '\n' ' ')"
else
  git commit -q -F "$TMP/msg" 2>"$TMP/err" || fail "$EX_OTHER" commit_failed "git commit failed: $(redact <"$TMP/err" | tr '\n' ' ')"
fi
FILES="$(git show --name-only --format= HEAD | jq -Rc . | jq -sc 'map(select(. != ""))')"
result "$(jq -cn --arg sha "$(git rev-parse HEAD)" --arg s "$SUBJECT" --argjson f "$FILES" --argjson r "$REMOVED" --arg b "$BRANCH" --arg t "$TRAILERS" \
  '{sha: $sha, subject: $s, files: $f, trailers_removed: $r, branch: $b, trailers: $t}')"
