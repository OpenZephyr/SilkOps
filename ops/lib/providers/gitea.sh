#!/usr/bin/env bash
# providers/gitea.sh — the verb set over Gitea's API v1 through curl (v0.3 U5). EXPERIMENTAL:
# fixture-verified only; every result carries `experimental: true` until a live run clears it.
# Same verbs and shapes as providers/github.sh (Gitea's API mirrors GitHub's for these). The token
# reaches curl as a config on stdin (`-K -`), never argv, never a URL. GITEA_TOKEN and
# SILKOPS_GITEA_URL (else https://<origin remote host>) come from the environment.
export SILKOPS_EXPERIMENTAL=true
_gt_url() {
  if [ -n "${SILKOPS_GITEA_URL:-}" ]; then printf '%s' "${SILKOPS_GITEA_URL%/}"; return; fi
  local r; r="$(git remote get-url origin 2>/dev/null || true)"
  case "$r" in
    https://*) r="${r#https://}"; printf 'https://%s' "${r%%/*}" ;;
    *@*:*) r="${r#*@}"; printf 'https://%s' "${r%%:*}" ;;
    *) fail "$EX_USAGE" usage "SILKOPS_GITEA_URL is not set and the origin remote does not name a host" ;;
  esac
}
# _gt <method> <path> [body-file] — JSON in and out; prints the body, returns 1 on a non-2xx.
_gt() {
  [ -n "${GITEA_TOKEN:-}" ] || fail "$EX_NO_TOKEN" no_token "GITEA_TOKEN is not set (required for every Gitea call)"
  local m="$1" p="$2" body="${3:-}" tmp code
  tmp="$(mktemp)"
  code="$(curl -sS -K - -o "$tmp" -w '%{http_code}' -X "$m" -H "Content-Type: application/json" ${body:+--data-binary "@$body"} "$(_gt_url)/api/v1/$p" <<<"header = \"Authorization: token ${GITEA_TOKEN}\"")" || { rm -f "$tmp"; return 1; }
  cat "$tmp"; rm -f "$tmp"
  case "$code" in 2*) return 0 ;; *) echo "gitea: HTTP $code ($m $p)" >&2; return 1 ;; esac
}
_gt_get() { _gt GET "$1"; }
_repo() { printf 'repos/%s' "$1"; }
_owner() { printf '%s' "${1%%/*}"; }
_pr_norm='{iid: .number, number: .number, provider: "gitea", web_url: .html_url, title, description: (.body // ""),
  state: (if .merged then "merged" elif .state == "open" then "opened" else "closed" end),
  source_branch: .head.ref, target_branch: .base.ref, sha: .head.sha, merge_commit_sha: (.merge_commit_sha // null), draft: false, head_pipeline: null,
  detailed_merge_status: (if .merged then "merged" elif .mergeable == false then "conflict" elif .state == "open" then "mergeable" else "not_open" end)}'
_run_status='(if .status != "completed" then "running" else ({success: "success", failure: "failed", cancelled: "canceled", skipped: "skipped"}[.conclusion // "failure"] // "failed") end)'
_run_norm='{id, run_id: .id, provider: "gitea", name, status: '"$_run_status"', ref: (.head_branch // null), sha: .head_sha, web_url: .html_url,
  started_at: (.run_started_at // null), updated_at, attempt: (.run_attempt // 1),
  duration: (if .run_started_at and .updated_at then ((.updated_at | fromdateiso8601) - (.run_started_at | fromdateiso8601)) else null end)}'
_job_norm='{id, name, provider: "gitea", status: '"$_run_status"', stage: null, web_url: .html_url, allow_failure: false, retry_count: ((.run_attempt // 1) - 1), started_at, finished_at: .completed_at, failure_reason: null}'
_issue_norm='{iid: .number, number: .number, id: .id, provider: "gitea", web_url: .html_url, title, description: (.body // ""),
  state: (if .state == "open" then "opened" else "closed" end), labels: [.labels[]?.name], milestone: (if .milestone then {id: .milestone.id, title: .milestone.title} else null end),
  assignees: [.assignees[]? | {id, username: .login}], due_date: (.due_date // null)}'
_ms_norm='{id, iid: .id, provider: "gitea", title, description: (.description // ""), state: (if .state == "open" then "active" else "closed" end), web_url: null, due_date: (.due_on // null), start_date: null}'
# --- project, users, roles -----------------------------------------------------
p_project_get() { _gt_get "$(_repo "$1")" | jq -c '{id, path_with_namespace: .full_name, default_branch, web_url: .html_url, owner: .owner.login, provider: "gitea"}'; }
p_group_get()   { _gt_get "orgs/$1" | jq -c '{id, path: .username}'; }
p_user_me()     { _gt_get user | jq -c '{id, username: .login, name: (.full_name // .login), bot: false}'; }
p_user_lookup() { _gt_get "users/$1" 2>/dev/null | jq -c '[{id, username: .login}]' || echo '[]'; }
p_member_level() { _gt_get "$(_repo "$1")/collaborators/$2/permission" 2>/dev/null | jq -c '{access_level: ({owner: 50, admin: 50, write: 30, read: 10}[.permission] // 0), role_name: .permission}' || echo '{"access_level":0}'; }
p_protection_read() { _gt_get "$(_repo "$1")/branch_protections" 2>/dev/null | jq -c '[.[] | {name: .branch_name, push_access_levels: [{access_level: 40}], merge_access_levels: [{access_level: 40}], required_reviews: (.required_approvals // 0), required_checks: (.status_check_contexts // []), enforce_admins: (.enable_push_whitelist // false)}]'; }
p_protection_summary() { jq -c '.[0] | {required_reviews, required_checks, enforce_admins}' 2>/dev/null || echo null; }
p_identity_as()        { p_user_me; }
p_project_get_as()     { p_project_get "$2"; }
p_member_level_as()    { local login; login="$(p_user_me | jq -r .username)"; p_member_level "$2" "$login"; }
p_protection_read_as() { p_protection_read "$_GH_PROJECT"; }
p_raw() { _gt_get "$2"; }
# --- pull requests as merge requests ---------------------------------------------------
p_mr_find_by_branch() { _gt_get "$(_repo "$1")/pulls?state=open&limit=50" | jq -c --arg b "$2" "[.[] | select(.head.ref == \$b) | $_pr_norm]"; }
p_mr_get()      { _gt_get "$(_repo "$1")/pulls/$2" | jq -c "$_pr_norm"; }
p_mr_create()   { local b; b="$(mktemp)"; jq -c '{title, body: .description, head: .source_branch, base: .target_branch}' "$2" >"$b"; _gt POST "$(_repo "$1")/pulls" "$b" | jq -c "$_pr_norm"; rm -f "$b"; }
p_mr_update()   { local b; b="$(mktemp)"; jq -c '({body: .description} + (if .title then {title} else {} end))' "$3" >"$b"; _gt PATCH "$(_repo "$1")/pulls/$2" "$b" | jq -c "$_pr_norm"; rm -f "$b"; }
p_mr_list_open() { _gt_get "$(_repo "$1")/pulls?state=open&limit=50" | jq -c --arg t "$2" "[.[] | select(.base.ref == \$t) | $_pr_norm]"; }
p_mr_diffs()    { _gt_get "$(_repo "$1")/pulls/$2/files?limit=100" | jq -c '[.[] | {new_path: .filename, old_path: (.previous_filename // .filename), diff: (.patch // "")}]'; }
p_mr_approvals() { _gt_get "$(_repo "$1")/pulls/$2/reviews" | jq -c '[.[] | .state] as $s | {review_decision: (if ($s | index("REQUEST_CHANGES")) then "CHANGES_REQUESTED" elif ($s | index("APPROVED")) then "APPROVED" else null end)} | . + {approved: (.review_decision != "CHANGES_REQUESTED"), approvals_left: (if .review_decision == "CHANGES_REQUESTED" then 1 else 0 end), approvals_required: 0}'; }
p_mr_closes_issues() { echo '[]'; }   # Gitea closes by keyword; no listing endpoint used here
# --- comments as notes --------------------------------------------------------------------
p_note_list() { _gt_get "$(_repo "$1")/issues/$3/comments" | jq -c '[.[] | {id, body, author: {username: .user.login}}]'; }
p_note_post() { _gt POST "$(_repo "$1")/issues/$3/comments" "$4" | jq -c '{id, body, web_url: .html_url}'; }
# --- Actions runs as pipelines --------------------------------------------------------
p_run_get()   { _gt_get "$(_repo "$1")/actions/runs/$2" | jq -c "$_run_norm"; }
p_run_jobs()  { _gt_get "$(_repo "$1")/actions/runs/$2/jobs?limit=$3&page=$4" | jq -c "[.jobs[] | $_job_norm]"; }
p_run_last_success() { _gt_get "$(_repo "$1")/actions/runs?branch=$(urlenc "$2")&status=success&limit=1" | jq -c "[.workflow_runs[] | $_run_norm]"; }
p_run_for_ref_sha()  { _gt_get "$(_repo "$1")/actions/runs?head_sha=$3&limit=20" | jq -c "[.workflow_runs[] | $_run_norm]"; }
p_job_log()   { _gt_get "$(_repo "$1")/actions/jobs/$2/logs"; }
p_job_retry() { _gt POST "$(_repo "$1")/actions/jobs/$2/rerun" >/dev/null && jq -cn --argjson id "$2" '{id: $id, rerun: true}'; }
# --- issues, dependencies, milestones ------------------------------------------------------
p_issue_search_description() { _gt_get "$(_repo "$1")/issues?type=issues&state=all&q=$(urlenc "$2")&limit=100" | jq -c "[.[] | $_issue_norm]"; }
p_issue_list_by_label()      { _gt_get "$(_repo "$1")/issues?type=issues&state=all&labels=$(urlenc "$2")&limit=100" | jq -c "[.[] | $_issue_norm]"; }
_label_ids() {  # names (comma list) → ids, creating missing labels
  local names="$1" ids='[]' all n id b
  all="$(_gt_get "$(_repo "$2")/labels?limit=100")"
  for n in $(printf '%s' "$names" | tr ',' ' '); do
    id="$(printf '%s' "$all" | jq -r --arg n "$n" '[.[] | select(.name == $n)] | first | .id // empty')"
    if [ -z "$id" ]; then b="$(mktemp)"; jq -cn --arg n "$n" '{name: $n, color: "#5c7cfa"}' >"$b"; id="$(_gt POST "$(_repo "$2")/labels" "$b" | jq -r .id)"; rm -f "$b"; fi
    ids="$(jq -cn --argjson a "$ids" --argjson i "$id" '$a + [$i]')"
  done
  printf '%s' "$ids"
}
_issue_body() {  # GitLab-shaped file → Gitea fields (labels by id, assignees by login from ids)
  local ids='null' names; names="$(jq -r '(.labels // .add_labels // "")' "$2")"
  [ -z "$names" ] || ids="$(_label_ids "$names" "$1")"
  jq -c --argjson ids "$ids" '{title, body: .description} + (if $ids != null then {labels: $ids} else {} end) + (if .milestone_id then {milestone: .milestone_id} else {} end) + (if .due_date then {due_date: (.due_date + "T00:00:00Z")} else {} end) | with_entries(select(.value != null))' "$2"
}
p_issue_create() { local b; b="$(mktemp)"; _issue_body "$1" "$2" >"$b"; _gt POST "$(_repo "$1")/issues" "$b" | jq -c "$_issue_norm"; rm -f "$b"; }
p_issue_update() { local b; b="$(mktemp)"; _issue_body "$1" "$3" >"$b"; _gt PATCH "$(_repo "$1")/issues/$2" "$b" | jq -c "$_issue_norm"; rm -f "$b"; }
p_has_issue_links() { return 0; }
p_issue_links()     { _gt_get "$(_repo "$1")/issues/$2/dependencies" | jq -c --arg p "$1" '[.[] | {iid: .number, project_id: .repository.id, link_type: "blocks"}]'; }
# p_issue_link_post <P> <source iid> <target project id> <target iid> <type> — "source blocks target": the target depends on the source
p_issue_link_post() { local b; b="$(mktemp)"; jq -cn --arg o "$(_owner "$1")" --arg r "${1#*/}" --argjson i "$2" '{owner: $o, repo: $r, index: $i}' >"$b"; _gt POST "$(_repo "$1")/issues/$4/dependencies" "$b" | jq -c '{link_type: "blocks", source_iid: '"$2"', target_iid: '"$4"'}'; rm -f "$b"; }
p_milestone_search() { _gt_get "$(_repo "$1")/milestones?state=all&limit=100" | jq -c --arg t "$2" "[.[] | select(.title | ascii_downcase | contains(\$t | ascii_downcase)) | $_ms_norm]"; }
p_milestone_by_title() { p_milestone_search "$1" "$2" | jq -c --arg t "$2" '[.[] | select(.title == $t)]'; }
p_milestone_create() { local b; b="$(mktemp)"; jq -c '{title, description} + (if .due_date then {due_on: (.due_date + "T00:00:00Z")} else {} end)' "$2" >"$b"; _gt POST "$(_repo "$1")/milestones" "$b" | jq -c "$_ms_norm"; rm -f "$b"; }
p_milestone_update() { local b; b="$(mktemp)"; jq -c '{description} + (if .title then {title} else {} end) + (if .due_date then {due_on: (.due_date + "T00:00:00Z")} else {} end)' "$3" >"$b"; _gt PATCH "$(_repo "$1")/milestones/$2" "$b" | jq -c "$_ms_norm"; rm -f "$b"; }
# --- Actions variables and secrets, registry ---------------------------------------------------
p_variable_list() {
  local v s
  v="$(_gt_get "$(_repo "$1")/actions/variables?limit=100" | jq -c '[.[] | {key: .name, masked: false, protected: false, kind: "variable"}]')"
  s="$(_gt_get "$(_repo "$1")/actions/secrets?limit=100" | jq -c '[.[] | {key: .name, masked: true, protected: false, kind: "secret"}]')"
  jq -cn --argjson v "$v" --argjson s "$s" '$v + $s'
}
p_variable_set() {
  local b; b="$(mktemp)"
  if [ "$3" = true ]; then jq -Rs '{data: .}' <"$4" >"$b"; _gt PUT "$(_repo "$1")/actions/secrets/$2" "$b" >/dev/null
  else jq -Rs '{value: .}' <"$4" >"$b"; _gt POST "$(_repo "$1")/actions/variables/$2" "$b" >/dev/null 2>&1 || _gt PUT "$(_repo "$1")/actions/variables/$2" "$b" >/dev/null; fi
  rm -f "$b"
}
p_has_secrets() { return 0; }
p_registry_host()      { local u; u="$(_gt_url)"; echo "${SILKOPS_REGISTRY_HOST:-${u#https://}}"; }
p_registry_repo()      { case "$2" in .|/) echo "$1" ;; *) echo "$(_owner "$1")/${2#/}" ;; esac; }
p_registry_token_url() { echo "https://$(p_registry_host)/v2/token?scope=repository:$1:$2"; }
p_registry_basic()     { echo "user = \"$(_owner "$1"):${GITEA_TOKEN:-}\""; }
p_registry_reads_api() { return 1; }
