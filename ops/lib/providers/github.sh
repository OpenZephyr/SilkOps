#!/usr/bin/env bash
# providers/github.sh — the verb set over GitHub's REST/GraphQL API through gh (v0.3 U3).
# Same verbs and result shapes as providers/gitlab.sh: a pull request is reported as a merge
# request (iid = number, plus `number`), a workflow run as a pipeline (id, plus `run_id`), a
# comment as a note. GH_TOKEN comes from the environment (gh's own login otherwise); bodies
# by file, never argv. Nothing here merges or touches branch protection.
# Where GitHub has no concept the verb says so: issue links → none (issue-link falls back).
_gh() { { gh "$@" 2>&1 1>&3 | redact 1>&2; } 3>&1; }
_gh_get() { _gh api -X GET "$1"; }
_gh_json() { _gh api -X "$1" "$2" --input "$3"; }          # body from file
_repo() { printf 'repos/%s' "$1"; }
# --- normalisers (GitHub → the harness's GitLab-shaped keys) ------------------------
_pr_norm='{iid: .number, number: .number, provider: "github", web_url: .html_url, title, description: (.body // ""),
  state: (if .merged_at then "merged" elif .state == "open" then "opened" else "closed" end),
  source_branch: .head.ref, target_branch: .base.ref, sha: .head.sha, merge_commit_sha: (.merge_commit_sha // null),
  draft: (.draft // false), head_pipeline: null,
  detailed_merge_status: (if .merged_at then "merged" elif .draft then "draft_status" else ({clean: "mergeable", unstable: "ci_must_pass", dirty: "conflict", behind: "need_rebase", blocked: "blocked_status", draft: "draft_status", unknown: "checking"}[.mergeable_state // "unknown"] // "checking") end)}'
_run_status='(if .status != "completed" then "running" else ({success: "success", failure: "failed", cancelled: "canceled", skipped: "skipped", action_required: "manual", timed_out: "failed", neutral: "success", stale: "canceled", startup_failure: "failed"}[.conclusion // "failure"] // "failed") end)'
_run_norm='{id, run_id: .id, provider: "github", name, status: '"$_run_status"', ref: (.head_branch // null), sha: .head_sha, web_url: .html_url,
  created_at, started_at: (.run_started_at // null), updated_at, attempt: (.run_attempt // 1),
  duration: (if .run_started_at and .updated_at then ((.updated_at | fromdateiso8601) - (.run_started_at | fromdateiso8601)) else null end)}'
_job_norm='{id, name, provider: "github", status: '"$_run_status"', stage: (.workflow_name // null), web_url: .html_url, allow_failure: false,
  retry_count: ((.run_attempt // 1) - 1), started_at, finished_at: .completed_at, created_at, ref: (.head_branch // null), failure_reason: null}'
_issue_norm='{iid: .number, number: .number, id: .id, provider: "github", web_url: .html_url, title, description: (.body // ""),
  state: (if .state == "open" then "opened" else "closed" end), labels: [.labels[]?.name], milestone: (if .milestone then {id: .milestone.number, title: .milestone.title} else null end),
  assignees: [.assignees[]? | {id, username: .login}], due_date: null}'
_ms_norm='{id: .number, iid: .number, provider: "github", title, description: (.description // ""), state: (if .state == "open" then "active" else "closed" end), web_url: .html_url, due_date: (.due_on // null), start_date: null}'
# --- project, users, roles -----------------------------------------------------
p_project_get() { _gh_get "$(_repo "$1")" | jq -c '{id, path_with_namespace: .full_name, default_branch, web_url: .html_url, owner: .owner.login, provider: "github"}'; }
p_group_get()   { _gh_get "orgs/$1" | jq -c '{id, path: .login, web_url: .html_url}'; }
p_user_me()     { _gh_get user | jq -c '{id, username: .login, name: (.name // .login), bot: (.type == "Bot")}' | tee "${TMPDIR:-/tmp}/.silkops-gh-me.$$" ; }
p_user_lookup() { _gh_get "users/$1" 2>/dev/null | jq -c '[{id, username: .login}]' || echo '[]'; }
# GitHub needs a login for the permission call; the identity was fetched by p_user_me in this process.
p_member_level() {
  local login; login="$(jq -r .username "${TMPDIR:-/tmp}/.silkops-gh-me.$$" 2>/dev/null || true)"; rm -f "${TMPDIR:-/tmp}/.silkops-gh-me.$$"
  [ -n "$login" ] || return 1
  _gh_get "$(_repo "$1")/collaborators/$login/permission" | jq -c '{access_level: ({admin: 50, maintain: 40, write: 30, triage: 20, read: 10}[.role_name // .permission] // 0), role_name: (.role_name // .permission)}'
}
# branch protection of the default branch, in GitLab's shape (one entry, levels from the rules)
p_protection_read() {
  local def; def="$(_gh_get "$(_repo "$1")" | jq -r '.default_branch')"
  _gh_get "$(_repo "$1")/branches/$def/protection" 2>/dev/null | jq -c --arg b "$def" '[{name: $b,
    push_access_levels: [{access_level: (if .restrictions then 50 else 30 end)}],
    merge_access_levels: [{access_level: (if .required_pull_request_reviews then 40 else 30 end)}],
    required_reviews: (.required_pull_request_reviews.required_approving_review_count // 0),
    required_checks: [.required_status_checks.contexts[]?], enforce_admins: (.enforce_admins.enabled // false)}]'
}
p_protection_summary() { jq -c '.[0] | {required_reviews, required_checks, enforce_admins}' 2>/dev/null || echo null; }
p_identity_as()        { p_user_me; }
p_project_get_as()     { p_project_get "$2"; }
p_member_level_as()    { p_member_level "$2" "$3"; }
p_protection_read_as() { p_protection_read "$_GH_PROJECT"; }
p_raw() { _gh_get "$2"; }
# --- Actions variables and secrets (variable.sh) ------------------------------------------
# list: variables plain, secrets as masked entries with no value anywhere
p_variable_list() {
  local v s
  v="$(_gh_get "$(_repo "$1")/actions/variables?per_page=100" | jq -c '[.variables[] | {key: .name, masked: false, protected: false, kind: "variable", created_at}]')"
  s="$(_gh_get "$(_repo "$1")/actions/secrets?per_page=100" | jq -c '[.secrets[] | {key: .name, masked: true, protected: false, kind: "secret", created_at}]')"
  jq -cn --argjson v "$v" --argjson s "$s" '$v + $s'
}
# p_variable_set <P> <key> <masked:true|false> <value-file> — gh does the encryption; the value is on stdin
p_variable_set() {
  if [ "$3" = true ]; then _gh secret set "$2" --repo "$1" <"$4"; else _gh variable set "$2" --repo "$1" <"$4"; fi
}
p_has_secrets() { return 0; }
# --- registry hooks: GHCR over the same v2 API -----------------------------------------------
p_registry_host()      { echo "${SILKOPS_REGISTRY_HOST:-ghcr.io}"; }
p_registry_repo()      { case "$2" in .|/) echo "$1" ;; *) echo "$(_owner "$1")/${2#/}" ;; esac; }
p_registry_token_url() { echo "https://$(p_registry_host)/token?scope=repository:$1:$2"; }
p_registry_basic()     { local t; t="${GH_TOKEN:-$(gh auth token 2>/dev/null || true)}"; echo "user = \"$(_owner "$1"):${t}\""; }
p_registry_reads_api() { return 1; }
# --- pull requests as merge requests ---------------------------------------------------
_owner() { printf '%s' "${1%%/*}"; }
p_mr_find_by_branch() { _gh_get "$(_repo "$1")/pulls?head=$(_owner "$1"):$(urlenc "$2")&state=open&per_page=${3:-10}" | jq -c "[.[] | $_pr_norm]"; }
p_mr_get()      { _gh_get "$(_repo "$1")/pulls/$2" | jq -c "$_pr_norm"; }
p_mr_create()   { local b; b="$(mktemp)"; jq -c '{title, body: .description, head: .source_branch, base: .target_branch, draft: (.draft // false)}' "$2" >"$b"; _gh_json POST "$(_repo "$1")/pulls" "$b" | jq -c "$_pr_norm"; rm -f "$b"; }
p_mr_update()   { local b; b="$(mktemp)"; jq -c '({body: .description} + (if .title then {title} else {} end))' "$3" >"$b"; _gh_json PATCH "$(_repo "$1")/pulls/$2" "$b" | jq -c "$_pr_norm"; rm -f "$b"; }
p_mr_list_open() { _gh_get "$(_repo "$1")/pulls?state=open&base=$(urlenc "$2")&per_page=20" | jq -c "[.[] | $_pr_norm]"; }
p_mr_diffs()    { _gh_get "$(_repo "$1")/pulls/$2/files?per_page=100" | jq -c '[.[] | {new_path: .filename, old_path: (.previous_filename // .filename), diff: (.patch // "")}]'; }
# shellcheck disable=SC2016  # GraphQL variables ($o, $r, $n) are for the API, not the shell
p_mr_approvals() {
  local q='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewDecision}}}'
  _gh api graphql -f query="$q" -f o="$(_owner "$1")" -f r="${1#*/}" -F n="$2" | jq -c '.data.repository.pullRequest.reviewDecision as $d
    | {review_decision: $d, approved: ($d == "APPROVED" or $d == null), approvals_left: (if $d == "REVIEW_REQUIRED" or $d == "CHANGES_REQUESTED" then 1 else 0 end), approvals_required: (if $d == null then 0 else 1 end)}'
}
# shellcheck disable=SC2016
p_mr_closes_issues() {
  local q='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){closingIssuesReferences(first:50){nodes{number state}}}}}'
  _gh api graphql -f query="$q" -f o="$(_owner "$1")" -f r="${1#*/}" -F n="$2" | jq -c '[.data.repository.pullRequest.closingIssuesReferences.nodes[] | {iid: .number, state: (if .state == "CLOSED" then "closed" else "opened" end)}]'
}
# --- comments as notes --------------------------------------------------------------------
p_note_list() { _gh_get "$(_repo "$1")/issues/$3/comments?per_page=100" | jq -c '[.[] | {id, body, author: {username: .user.login}}]'; }
p_note_post() { _gh_json POST "$(_repo "$1")/issues/$3/comments" "$4" | jq -c '{id, body, web_url: .html_url}'; }
# --- workflow runs as pipelines --------------------------------------------------------
p_run_get()   { _gh_get "$(_repo "$1")/actions/runs/$2" | jq -c "$_run_norm"; }
p_run_jobs()  { _gh_get "$(_repo "$1")/actions/runs/$2/jobs?per_page=$3&page=$4" | jq -c "[.jobs[] | $_job_norm]"; }
p_run_last_success() { _gh_get "$(_repo "$1")/actions/runs?branch=$(urlenc "$2")&status=success&per_page=1" | jq -c "[.workflow_runs[] | $_run_norm]"; }
p_run_for_ref_sha()  { _gh_get "$(_repo "$1")/actions/runs?head_sha=$3&per_page=20" | jq -c "[.workflow_runs[] | $_run_norm]"; }
p_job_log()   { _gh api -X GET "$(_repo "$1")/actions/jobs/$2/logs"; }
p_job_retry() { _gh api -X POST "$(_repo "$1")/actions/jobs/$2/rerun" >/dev/null && jq -cn --argjson id "$2" '{id: $id, rerun: true}'; }
# --- issues, links (none), milestones ------------------------------------------------------
p_issue_search_description() { _gh_get "search/issues?q=$(urlenc "repo:$1 in:body \"$2\"")&per_page=100" | jq -c "[.items[] | select(.pull_request == null) | $_issue_norm]"; }
p_issue_list_by_label()      { _gh_get "$(_repo "$1")/issues?labels=$(urlenc "$2")&state=all&per_page=100" | jq -c "[.[] | select(.pull_request == null) | $_issue_norm]"; }
_issue_body() {  # GitLab-shaped body file → GitHub fields; assignee ids become logins via users/:id
  jq -c '{title, body: .description} + (if .labels then {labels: (.labels | split(",") | map(select(. != "")))} else {} end)
    + (if .add_labels then {labels: (.add_labels | split(",") | map(select(. != "")))} else {} end)
    + (if .milestone_id then {milestone: .milestone_id} else {} end) + (if .assignee_ids then {assignee_ids} else {} end) | with_entries(select(.value != null))' "$1"
}
_resolve_assignees() {  # {assignee_ids:[id]} → {assignees:[login]}
  local ids logins='[]' id login
  ids="$(jq -c '.assignee_ids // []' "$1")"
  for id in $(printf '%s' "$ids" | jq -r '.[]'); do login="$(_gh_get "user/$id" 2>/dev/null | jq -r '.login // empty' || true)"; [ -z "$login" ] || logins="$(jq -cn --argjson a "$logins" --arg l "$login" '$a + [$l]')"; done
  jq -c --argjson l "$logins" 'del(.assignee_ids) + (if ($l | length) > 0 then {assignees: $l} else {} end)' "$1"
}
p_issue_create() { local b; b="$(mktemp)"; _issue_body "$2" >"$b.1"; _resolve_assignees "$b.1" >"$b"; _gh_json POST "$(_repo "$1")/issues" "$b" | jq -c "$_issue_norm"; rm -f "$b" "$b.1"; }
p_issue_update() {
  local b cur; b="$(mktemp)"; _issue_body "$3" >"$b.1"; _resolve_assignees "$b.1" >"$b.2"
  # add_labels is additive: union with the labels the issue already has
  if jq -e '.add_labels' "$3" >/dev/null; then cur="$(_gh_get "$(_repo "$1")/issues/$2" | jq -c '[.labels[]?.name]')"; jq -c --argjson c "$cur" '.labels = (($c + (.labels // [])) | unique)' "$b.2" >"$b"; else cp "$b.2" "$b"; fi
  _gh_json PATCH "$(_repo "$1")/issues/$2" "$b" | jq -c "$_issue_norm"; rm -f "$b" "$b.1" "$b.2"
}
p_has_issue_links() { return 1; }
p_issue_links()     { echo '[]'; }
p_issue_link_post() { echo "gh: HTTP 400 GitHub has no issue links (blocked-by) in REST; issue-link records the dependency in the managed region instead" >&2; return 1; }
p_milestone_search() { _gh_get "$(_repo "$1")/milestones?state=all&per_page=100" | jq -c --arg t "$2" "[.[] | select(.title | ascii_downcase | contains(\$t | ascii_downcase)) | $_ms_norm]"; }
p_milestone_by_title() { p_milestone_search "$1" "$2" | jq -c --arg t "$2" '[.[] | select(.title == $t)]'; }
p_milestone_create() { local b; b="$(mktemp)"; jq -c '{title, description} + (if .due_date then {due_on: (.due_date + "T00:00:00Z")} else {} end)' "$2" >"$b"; _gh_json POST "$(_repo "$1")/milestones" "$b" | jq -c "$_ms_norm"; rm -f "$b"; }
p_milestone_update() { local b; b="$(mktemp)"; jq -c '{description} + (if .title then {title} else {} end) + (if .due_date then {due_on: (.due_date + "T00:00:00Z")} else {} end)' "$3" >"$b"; _gh_json PATCH "$(_repo "$1")/milestones/$2" "$b" | jq -c "$_ms_norm"; rm -f "$b"; }
