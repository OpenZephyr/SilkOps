#!/usr/bin/env bash
# release-notes.sh — release notes from git history, shared by scripts/bump.sh, scripts/release.sh
# and scripts/github-release.sh. Sourced, never executed; git runs against the cwd's repository.
#
#   release_prev_tag <version>        the highest silkops-harness--v* tag below <version>, or ""
#   release_range <prev-tag> <end>    "<prev>..<end>", or "<end>" when there is no previous tag
#   release_closed_issues <range>     "<n>\t<subject>" per issue closed in the range, sorted by n,
#                                     one line per issue (the oldest commit that closed it wins,
#                                     non-merge commits before merge commits)
#   release_notes <prev-tag> <end>    the markdown: a Closes section, then the non-merge subjects
#                                     grouped by conventional type (feat, fix, docs, other)
#
# Only bash, git, awk and sort; nothing on argv is ever a token.

release_prev_tag() {
  local v="$1"
  git tag --list 'silkops-harness--v*' \
    | sed -n 's/^silkops-harness--v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' \
    | awk -F. -v v="$v" '
        BEGIN { split(v, t, ".") }
        ($1 < t[1]+0) || ($1 == t[1]+0 && $2 < t[2]+0) || ($1 == t[1]+0 && $2 == t[2]+0 && $3 < t[3]+0) { print }' \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 | sed 's/^/silkops-harness--v/'
}

release_range() {
  if [ -n "$1" ]; then printf '%s..%s\n' "$1" "$2"; else printf '%s\n' "$2"; fi
}

# Records are separated by \036; the first line of each is the subject, the rest the body.
_release_log_records() { git log "$@" --format='%x1e%s%n%b'; }

release_closed_issues() {
  local range="$1"
  { _release_log_records --reverse --no-merges "$range"; _release_log_records --reverse --merges "$range"; } \
    | awk -v RS="$(printf '\036')" '
        {
          n = split($0, L, "\n"); subj = L[1]
          if (subj == "") next
          for (i = 2; i <= n; i++) {
            line = L[i]
            if (tolower(line) !~ /^closes[ :]/) continue
            while (match(line, /#[0-9]+/)) {
              num = substr(line, RSTART + 1, RLENGTH - 1) + 0
              if (!(num in seen)) { seen[num] = 1; printf "%d\t%s\n", num, subj }
              line = substr(line, RSTART + RLENGTH)
            }
          }
        }' \
    | sort -t "$(printf '\t')" -k1,1n
}

release_notes() {
  local prev="$1" end="$2" range closed
  range="$(release_range "$prev" "$end")"
  closed="$(release_closed_issues "$range")"
  if [ -n "$prev" ]; then
    printf 'Changes since %s.\n\n' "$prev"
  else
    printf 'First release.\n\n'
  fi
  printf '## Closes\n\n'
  if [ -n "$closed" ]; then
    printf '%s\n' "$closed" | awk -F '\t' '{ printf "- #%s — %s\n", $1, $2 }'
  else
    printf -- '- none\n'
  fi
  printf '\n## Changes\n'
  git log --no-merges --format='%s' "$range" | awk '
    function group(s) {
      if (s ~ /^feat(\([^)]*\))?!?:/) return "feat"
      if (s ~ /^fix(\([^)]*\))?!?:/)  return "fix"
      if (s ~ /^docs(\([^)]*\))?!?:/) return "docs"
      return "other"
    }
    { g = group($0); if (!(g in count)) order[++k] = g; count[g]++; lines[g] = lines[g] "- " $0 "\n" }
    END {
      split("feat fix docs other", want, " ")
      for (i = 1; i <= 4; i++) { g = want[i]; if (g in count) printf "\n### %s\n\n%s", g, lines[g] }
      if (k == 0) printf "\n- none\n"
    }'
}
