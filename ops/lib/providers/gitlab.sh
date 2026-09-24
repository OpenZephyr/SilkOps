#!/usr/bin/env bash
# providers/gitlab.sh — the verb set over GitLab's REST API through glab (v0.3 U2).
# Every verb prints the API's JSON (or the raw body for logs) and returns glab's status, so
# call sites keep their own error handling and stderr redirections. <P> is group/project.
# Bodies arrive by file (--input), never argv. Nothing here merges or touches protected branches.
_enc() { urlenc "$1"; }
# --- project, users, roles -----------------------------------------------------
p_project_get()      { api_get "projects/$(_enc "$1")"; }
p_group_get()        { api_get "groups/$(_enc "$1")"; }
p_user_me()          { api_get user; }
p_user_lookup()      { api_get "users?username=$(_enc "$1")"; }
p_member_level()     { api_get "projects/$(_enc "$1")/members/all/$2"; }
p_protection_read()  { api_get "projects/$1/protected_branches"; }            # $1 = numeric project id
# p_raw <identity> <path> — token-check's identity probe: the same path under a chosen token.
p_raw() { case "$1" in settings) glab_settings api -X GET "$2" ;; ci) with_ci_token glab api -X GET "$2" ;; *) api_get "$2" ;; esac; }
# --- merge requests -------------------------------------------------------------
p_mr_find_by_branch() { api_get "projects/$(_enc "$1")/merge_requests?source_branch=$(_enc "$2")&state=opened&per_page=${3:-10}"; }
p_mr_get()           { api_get "projects/$(_enc "$1")/merge_requests/$2"; }
p_mr_create()        { glab_ro api -X POST "projects/$(_enc "$1")/merge_requests" --input "$2"; }
p_mr_update()        { glab_ro api -X PUT "projects/$(_enc "$1")/merge_requests/$2" --input "$3"; }
p_mr_list_open()     { api_get "projects/$(_enc "$1")/merge_requests?state=opened&target_branch=$(_enc "$2")&per_page=20"; }
p_mr_diffs()         { api_get "projects/$(_enc "$1")/merge_requests/$2/diffs?per_page=100"; }
p_mr_approvals()     { api_get "projects/$(_enc "$1")/merge_requests/$2/approvals"; }
p_mr_closes_issues() { api_get "projects/$(_enc "$1")/merge_requests/$2/closes_issues?per_page=100"; }
# --- notes: <kind> is issue | merge_request --------------------------------------------
_notes_path() { case "$2" in issue) echo "projects/$(_enc "$1")/issues/$3/notes" ;; *) echo "projects/$(_enc "$1")/merge_requests/$3/notes" ;; esac; }
p_note_list()        { api_get "$(_notes_path "$1" "$2" "$3")?per_page=100"; }
p_note_post()        { glab_ro api -X POST "$(_notes_path "$1" "$2" "$3")" --input "$4"; }
# --- CI: a run is a pipeline here ----------------------------------------------------
p_run_get()          { api_get "projects/$(_enc "$1")/pipelines/$2"; }
p_run_jobs()         { api_get "projects/$(_enc "$1")/pipelines/$2/jobs?include_retried=true&per_page=$3&page=$4"; }
p_run_last_success() { api_get "projects/$(_enc "$1")/pipelines?ref=$(_enc "$2")&status=success&per_page=1"; }
p_run_for_ref_sha()  { api_get "projects/$(_enc "$1")/pipelines?ref=$(_enc "$2")&sha=$3&per_page=1"; }
p_job_log()          { glab_ro api -X GET "projects/$(_enc "$1")/jobs/$2/trace"; }
p_job_retry()        { glab_ro api -X POST "projects/$(_enc "$1")/jobs/$2/retry"; }
# --- issues, links, milestones --------------------------------------------------------
p_issue_search_description() { api_get "projects/$(_enc "$1")/issues?search=$(_enc "$2")&in=description&state=all&scope=all&per_page=100"; }
p_issue_list_by_label()      { api_get "projects/$(_enc "$1")/issues?labels=$(_enc "$2")&state=all&scope=all&per_page=100"; }
p_issue_create()     { glab_ro api -X POST "projects/$(_enc "$1")/issues" --input "$2"; }
p_issue_update()     { glab_ro api -X PUT "projects/$(_enc "$1")/issues/$2" --input "$3"; }
p_has_issue_links()  { return 0; }
p_issue_links()      { api_get "projects/$(_enc "$1")/issues/$2/links"; }
# p_issue_link_post <P> <source iid> <target project id> <target iid> <type>
p_issue_link_post()  { glab_ro api -X POST "projects/$(_enc "$1")/issues/$2/links" -f "target_project_id=$3" -f "target_issue_iid=$4" -f "link_type=$5"; }
p_milestone_search() { api_get "projects/$(_enc "$1")/milestones?search=$(_enc "$2")&state=all&per_page=100"; }
p_milestone_by_title() { api_get "projects/$(_enc "$1")/milestones?title=$(_enc "$2")&include_parent_milestones=true"; }
p_milestone_create() { glab_ro api -X POST "projects/$(_enc "$1")/milestones" --input "$2"; }
p_milestone_update() { glab_ro api -X PUT "projects/$(_enc "$1")/milestones/$2" --input "$3"; }
