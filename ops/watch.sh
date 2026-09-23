#!/usr/bin/env bash
# watch.sh — bounded-wait watch of an MR head pipeline or a pipeline id (plan U6, KTD6).
#
# Usage: watch.sh --project <group/project> (--mr <iid> [--pipeline <id>] | --pipeline <id>)
#          [--wait <seconds, default 300>] [--interval <seconds, default 20>]
#          [--retry] [--note] [--plan <basename>] [--run <id>]
#
# Resolves the MR's head pipeline (the checkpoint id) — or, with --mr AND --pipeline, watches
# that pipeline id while reading superseded/detailed_merge_status from the MR (the resume
# form) — then polls `pipelines/:id` + every page of `pipelines/:id/jobs?include_retried=true`
# until the pipeline is terminal (success, failed, canceled, skipped, manual) or the wait
# budget ends. Emits ONE JSON report: status, terminal, ready (success AND
# detailed_merge_status == mergeable when an MR is known; == success for a bare pipeline),
# superseded (the MR's head pipeline moved on), jobs, status transitions, errors (a jobs
# listing that failed on some poll: the previous snapshot is kept, never "zero jobs"; on the
# first poll it is fatal, exit 1 jobs_fetch_failed), and for a failed pipeline the per-job
# triage: `trace.py root-cause` lines + `classify-failure.py` verdict, the job's `web_url` and
# `first_failure` (the first pytest `FAILED ` line, else null), every trace line
# passed through `redact`.
#   --retry  POST jobs/:id/retry once per job per watch, only when the failure is
#            transient AND retry_safe AND the job has not been retried before
#            (same-named jobs in the include_retried list) AND the pipeline is not
#            superseded; then keeps watching the same pipeline id. With a bare --pipeline
#            the MR is resolved from the pipeline (GitLab's MR ref `refs/…-requests/<iid>/head`,
#            else merge_requests?source_branch=<ref>&state=opened); without MR context the retry
#            is refused (retry_skipped, no_mr_context) — the report is still produced.
#   --note   (with --mr) posts a marker-tagged triage note per failed job via note.sh,
#            deduplicated by `triage-<pipeline id>-<job name>`. The header carries the job URL,
#            the step (the fact's, else the job name) and, for a pytest job, the first `FAILED `
#            line. Root-cause lines sit in a fence longer than any backtick run they contain and
#            are indented, and the first-failure line sits in an inline code span longer than any
#            backtick run inside it, so a trace line can neither close the fence nor read as a
#            GitLab quick action.
# The wait budget is counted in poll intervals (poll at 0, interval, 2*interval, …
# while the next poll still fits), so a run is deterministic; SILKOPS_WATCH_SLEEP
# overrides the seconds actually slept between polls (tests set 0).
#
# Exit: 0 on a terminal report — even failed, the caller judges — and 0 with
# still_running:true when the budget ends; 6 when --retry was asked and a transient
# failure is retry-unsafe (the full report is still emitted); 5 MR/pipeline not found
# or the MR has no head pipeline; 2 usage.
# This script never merges: no merge endpoint, no merge verb. Session identity
# (or the CI token in CI); never the settings token.
set -euo pipefail
# shellcheck source=lib/prelude.sh
. "$(dirname "$0")/lib/prelude.sh"
# shellcheck source=lib/token.sh
. "$(dirname "$0")/lib/token.sh"
# shellcheck source=lib/glab.sh
. "$(dirname "$0")/lib/glab.sh"
# shellcheck source=lib/provider.sh
. "$(dirname "$0")/lib/provider.sh"

usage() { fail "$EX_USAGE" usage "usage: watch.sh --project <group/project> (--mr <iid> [--pipeline <id>] | --pipeline <id>) [--wait <s>] [--interval <s>] [--retry] [--note] [--plan <basename>] [--run <id>]${1:+ — $1}"; }

PROJECT=""; MR=""; PIPE=""; WAIT=300; INTERVAL=20; RETRY=false; NOTE=false; SHA=""
PLAN="-"; RUN="$(date -u +%Y%m%dT%H%M%SZ)"; ROOT_LINES=15
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage "--project needs a value"; PROJECT="$2"; shift 2 ;;
    --project=*) PROJECT="${1#--project=}"; shift ;;
    --mr) [ $# -ge 2 ] || usage; MR="$2"; shift 2 ;;
    --pipeline) [ $# -ge 2 ] || usage; PIPE="$2"; shift 2 ;;
    --wait) [ $# -ge 2 ] || usage; WAIT="$2"; shift 2 ;;
    --sha) [ $# -ge 2 ] || usage; SHA="$2"; shift 2 ;;   # wait until the MR head pipeline is for this commit (right after a push)
    --interval) [ $# -ge 2 ] || usage; INTERVAL="$2"; shift 2 ;;
    --plan) [ $# -ge 2 ] || usage; PLAN="$2"; shift 2 ;;
    --run) [ $# -ge 2 ] || usage; RUN="$2"; shift 2 ;;
    --retry) RETRY=true; shift ;;
    --note) NOTE=true; shift ;;
    -h|--help) usage ;;
    *) usage "unknown argument: $1" ;;
  esac
done
require_project "$PROJECT"
[ -n "$MR$PIPE" ] || usage "pass --mr <iid>, --pipeline <id>, or both (--mr with --pipeline watches that pipeline with the MR's context)"
[ -z "$MR" ] || [[ "$MR" =~ ^[0-9]+$ ]] || usage "--mr must be a number"
[ -z "$PIPE" ] || [[ "$PIPE" =~ ^[0-9]+$ ]] || usage "--pipeline must be a number"
[[ "$WAIT" =~ ^[0-9]+$ ]] || usage "--wait must be a number of seconds"
[ -z "$SHA" ] || [[ "$SHA" =~ ^[0-9a-f]{7,40}$ ]] || usage "--sha must be 7 to 40 hex characters"
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || usage "--interval must be a positive number of seconds"
if [ "$NOTE" = true ] && [ -z "$MR" ]; then usage "--note needs --mr (notes are posted on the merge request)"; fi
require_ci_token   # top level, so the exit-3 JSON and message reach the real streams (the wrappers re-check)

OPS="$SILKOPS_ROOT/ops"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/silkops-watch.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
SLEEP_S="${SILKOPS_WATCH_SLEEP:-$INTERVAL}"

# --- resolve the checkpoint --------------------------------------------------
MRJ=null; DMS=null; HEAD_ID=null; MR_URL=null
fetch_mr() { p_mr_get "$PROJECT" "$MR"; }
read_mr() {  # sets DMS, HEAD_ID, MR_URL from $MRJ
  DMS="$(printf '%s' "$MRJ" | jq -c '.detailed_merge_status // null')"
  HEAD_ID="$(printf '%s' "$MRJ" | jq -c '.head_pipeline.id // null')"
  MR_URL="$(printf '%s' "$MRJ" | jq -c '.web_url // null')"
}
if [ -n "$MR" ]; then
  MRJ="$(fetch_mr)" || fail "$EX_NOT_FOUND" not_found "merge request !$MR not found in $PROJECT"
  read_mr
  if [ -n "$PIPE" ]; then
    PIPE_ID="$PIPE"   # resume form: this pipeline, with the MR's superseded / merge status
  else
    # Right after a push the MR still reports the PREVIOUS head pipeline for a while; with
    # --sha, wait (within the budget) until head_pipeline.sha is the pushed commit.
    if [ -n "$SHA" ]; then
      waited=0
      # prefix match: git prints abbreviated shas, GitLab reports the full one (#26)
      while [[ "$(printf '%s' "$MRJ" | jq -r '.head_pipeline.sha // ""')" != "$SHA"* ]]; do
        if [ "$waited" -ge "$WAIT" ]; then
          result "$(jq -cn --argjson iid "$MR" --arg sha "$SHA" --argjson head "$HEAD_ID" --arg hint "watch.sh --project $PROJECT --mr $MR --sha $SHA" \
            '{mr_iid: $iid, still_running: true, waiting_for_sha: $sha, head_pipeline_id: $head, terminal: false, ready: false, resume_hint: $hint}')"
          exit 0
        fi
        err "MR !$MR head pipeline is not yet for $SHA; waiting ${INTERVAL}s"
        sleep "${SILKOPS_WATCH_SLEEP:-$INTERVAL}"; waited=$((waited + INTERVAL))
        MRJ="$(fetch_mr)" || fail "$EX_NOT_FOUND" not_found "merge request !$MR disappeared while waiting for $SHA"
        read_mr
      done
    fi
    # Right after mr-upsert creates the MR, GitLab has not created the pipeline yet (#30):
    # wait for one inside the budget instead of failing; the budget spent is a resumable report.
    waited=0
    while [ "$HEAD_ID" = null ]; do
      if [ "$waited" -ge "$WAIT" ]; then
        result "$(jq -cn --argjson iid "$MR" --argjson u "$MR_URL" --arg hint "watch.sh --project $PROJECT --mr $MR${SHA:+ --sha $SHA}" \
          '{mr_iid: $iid, mr_web_url: $u, still_running: true, waiting_for: "head_pipeline", head_pipeline_id: null, terminal: false, ready: false, resume_hint: $hint}')"
        exit 0
      fi
      err "MR !$MR has no head pipeline yet; waiting ${INTERVAL}s"
      sleep "${SILKOPS_WATCH_SLEEP:-$INTERVAL}"; waited=$((waited + INTERVAL))
      MRJ="$(fetch_mr)" || fail "$EX_NOT_FOUND" not_found "merge request !$MR disappeared while waiting for its head pipeline"
      read_mr
    done
    PIPE_ID="$HEAD_ID"
  fi
else
  PIPE_ID="$PIPE"
fi

# --- state -------------------------------------------------------------------
POLLS=0; ELAPSED=0; PREV='{}'; STATUS=""; SUPERSEDED=false
CHANGES='[]'; TRIAGE='[]'; FAILED_ROUND='[]'; NOTES='[]'
RETRIED='[]'; RETRY_LOG='[]'; RETRY_SKIPPED='[]'; RETRY_UNSAFE='[]'
RETRIED_NAMES='[]'; ERRORS='[]'
JOBS='[]'; RAW_JOBS='[]'; PIPE_JSON='{}'
JOBS_KNOWN=false    # a jobs listing has succeeded at least once
JOBS_STALE=false    # this poll's listing failed; JOBS is the previous snapshot
NO_MR_CONTEXT=false; MR_RESOLVE_TRIED=false
JOBS_PER_PAGE=100; JOBS_MAX_PAGES=50
CONTEXT_READ=false; EXPECTED=null; APPROVALS=null

append() {  # append <VAR> <json> — VAR is a JSON array
  local cur="${!1}"
  printf -v "$1" '%s' "$(jq -cn --argjson a "$cur" --argjson b "$2" '$a + [$b]')"
}
has_name() { jq -en --argjson a "$1" --arg n "$2" '$a | index($n) != null' >/dev/null; }

is_terminal() {
  case "$1" in success|failed|canceled|skipped|manual) return 0 ;; *) return 1 ;; esac
}

report() {  # report <extra-json> — the single JSON result
  local failed_now
  if [ "$STATUS" = failed ]; then failed_now="$FAILED_ROUND"; else failed_now='[]'; fi
  local terminal=false ready=false
  is_terminal "$STATUS" && terminal=true
  if [ "$STATUS" = success ]; then
    if [ -n "$MR" ]; then [ "$DMS" = '"mergeable"' ] && ready=true; else ready=true; fi
  fi
  # (#38) why a terminal green pipeline is still not mergeable, in one sentence
  local reason=null
  if [ "$terminal" = true ] && [ "$ready" = false ] && [ -n "$MR" ]; then
    reason="$(jq -cn --argjson d "$DMS" --argjson a "$APPROVALS" '
      ({need_rebase: "rebase onto the target branch and push again",
        draft_status: "the MR is a draft; mark it ready",
        discussions_not_resolved: "unresolved review threads",
        not_approved: "approval outstanding",
        ci_still_running: "a newer pipeline is running; watch that one",
        ci_must_pass: "the pipeline did not pass",
        conflict: "merge conflicts with the target branch",
        blocked_status: "blocked by another merge request",
        not_open: "the MR is not open",
        mergeable: null}[$d] // ("detailed_merge_status is " + ($d // "unknown")))
      | if . != null and $a != null and ($a.approvals_left // 0) > 0 then . + "; " + ($a.approvals_left | tostring) + " approval(s) outstanding" else . end')"
  fi
  # (#31) when to come back: what is left of the expected duration, never under one interval
  local resume_after=null
  if [ "$terminal" = false ]; then
    resume_after="$(jq -cn --argjson e "$EXPECTED" --argjson w "$ELAPSED" --argjson i "$INTERVAL" \
      'if $e == null then $i else ([$e - $w, $i] | max) end')"
  fi
  result "$(jq -cn \
    --argjson expected "$EXPECTED" --argjson resume_after "$resume_after" --argjson approvals "$APPROVALS" --argjson reason "$reason" \
    --arg project "$PROJECT" --argjson mr_iid "${MR:-null}" --argjson mr_url "$MR_URL" \
    --argjson pid "$PIPE_ID" --argjson pipe "$PIPE_JSON" --arg status "$STATUS" \
    --argjson terminal "$terminal" --argjson ready "$ready" --argjson dms "$DMS" \
    --argjson head "$HEAD_ID" --argjson superseded "$SUPERSEDED" \
    --argjson jobs "$JOBS" --argjson changes "$CHANGES" --argjson failed "$failed_now" \
    --argjson triage "$TRIAGE" --argjson retried "$RETRIED" --argjson retry_log "$RETRY_LOG" \
    --argjson retry_skipped "$RETRY_SKIPPED" --argjson retry_unsafe "$RETRY_UNSAFE" \
    --argjson notes "$NOTES" --argjson errors "$ERRORS" --argjson polls "$POLLS" --argjson waited "$ELAPSED" \
    --argjson wait "$WAIT" --argjson interval "$INTERVAL" --arg hint "$(resume_hint)" --argjson extra "$1" '
    {project: $project, mr_iid: $mr_iid, mr_web_url: $mr_url,
     pipeline_id: $pid, pipeline_web_url: ($pipe.web_url // null), ref: ($pipe.ref // null), sha: ($pipe.sha // null),
     status: $status, terminal: $terminal, ready: $ready, detailed_merge_status: $dms,
     head_pipeline_id: $head, superseded: $superseded,
     jobs: $jobs, changes: $changes, failed: $failed, triage: $triage,
     retried: $retried, retry_log: $retry_log, retry_skipped: $retry_skipped, retry_unsafe: $retry_unsafe,
     notes: $notes, errors: $errors, polls: $polls, waited_s: $waited, wait_s: $wait, interval_s: $interval,
     still_running: (($terminal | not)),
     expected_duration_s: $expected, resume_after_s: $resume_after,
     approvals: $approvals, not_ready_reason: $reason,
     resume_hint: $hint} + $extra')"
}
# resume_hint — the checkpoint carries the MR too, so a resumed watch keeps the superseded guard.
resume_hint() { printf 'watch.sh --project %s%s --pipeline %s' "$PROJECT" "${MR:+ --mr $MR}" "$PIPE_ID"; }

# fetch_jobs — every page of pipelines/:id/jobs?include_retried=true as one array on stdout;
# nonzero when any page fails (the caller keeps its previous snapshot; stderr in $TMP/jobs.err).
fetch_jobs() {
  local page=1 acc='[]' chunk n
  : >"$TMP/jobs.err"
  while :; do
    chunk="$(p_run_jobs "$PROJECT" "$PIPE_ID" "$JOBS_PER_PAGE" "$page" 2>>"$TMP/jobs.err")" || return 1
    n="$(printf '%s' "$chunk" | jq -r 'if type == "array" then length else -1 end' 2>/dev/null)" || n=-1
    [ "$n" -ge 0 ] || { echo "jobs page $page is not a JSON array" >>"$TMP/jobs.err"; return 1; }
    acc="$(jq -cn --argjson a "$acc" --argjson b "$chunk" '$a + $b')"
    if [ "$n" -lt "$JOBS_PER_PAGE" ] || [ "$page" -ge "$JOBS_MAX_PAGES" ]; then break; fi
    page=$((page + 1))
  done
  printf '%s' "$acc"
}

# resolve_mr_from_pipeline — a bare --pipeline with --retry needs MR context (superseded,
# detailed_merge_status) before any retry: GitLab's MR ref (`refs/…-requests/<iid>/head`) names
# the MR; a branch ref is looked up via merge_requests?source_branch=<ref>&state=opened (exactly
# one match). Without context NO_MR_CONTEXT=true and decide_retry refuses. (The grouped word in
# the regex keeps the no-merge gate's literal scan quiet: this is a ref name, not a merge.)
resolve_mr_from_pipeline() {
  local ref cands
  ref="$(printf '%s' "$PIPE_JSON" | jq -r '.ref // ""')"
  if [[ "$ref" =~ ^refs/(merge)-requests/([0-9]+)/head$ ]]; then
    MR="${BASH_REMATCH[2]}"
  elif [ -n "$ref" ]; then
    if cands="$(p_mr_find_by_branch "$PROJECT" "$ref" 100)" \
      && [ "$(printf '%s' "$cands" | jq -r 'if type == "array" then length else 0 end')" = 1 ]; then
      MR="$(printf '%s' "$cands" | jq -r '.[0].iid')"
    fi
  fi
  if [ -n "$MR" ] && MRJ="$(fetch_mr)"; then
    read_mr
    err "resolved merge request !$MR for pipeline $PIPE_ID (ref $ref); its head pipeline is $HEAD_ID"
  else
    MR=""; NO_MR_CONTEXT=true
    err "no merge request context for pipeline $PIPE_ID (ref ${ref:-unknown}): --retry is refused without it (the superseded guard needs the MR)"
  fi
}

# triage_job <job-json> — fetch the trace, root-cause + classify, redact; appends to
# TRIAGE and FAILED_ROUND.
triage_job() {
  local job="$1" name id fr wu tf rc cl lines exit_code ff
  name="$(printf '%s' "$job" | jq -r .name)"; id="$(printf '%s' "$job" | jq -r .id)"
  fr="$(printf '%s' "$job" | jq -c '.failure_reason // null')"
  wu="$(printf '%s' "$job" | jq -c '.web_url // null')"
  tf="$TMP/trace-$id.log"
  if p_job_log "$PROJECT" "$id" >"$tf" 2>"$TMP/trace-$id.err"; then
    rc="$(python3 "$OPS/trace.py" root-cause "$tf" --lines "$ROOT_LINES")" || rc='{"lines":[],"exit_code":null}'
    lines="$(printf '%s' "$rc" | jq -r '.lines[]' | redact | jq -Rc . | jq -sc .)"
    exit_code="$(printf '%s' "$rc" | jq -c '.exit_code // null')"
    # first_failure: pytest's `short test summary info` one-liner. Untrusted job output, so
    # it takes the same redaction as every root-cause line before it is returned or posted.
    if printf '%s' "$rc" | jq -e '.first_failure != null' >/dev/null; then
      ff="$(printf '%s' "$rc" | jq -r '.first_failure' | redact | jq -Rsc 'rtrimstr("\n")')"
    else
      ff=null
    fi
    local fa=(); local fp
    while IFS= read -r fp; do fa+=(--facts "$fp"); done < <(facts_paths)
    cl="$(python3 "$OPS/classify-failure.py" "$tf" "${fa[@]}" 2>/dev/null | redact \
      | jq -c '{transient, retry_safe, fact, class, reason, step, no_retry_after, marker_hit_before_failure, marker_line_no, failure_line_no, hit_count: (.hits | length), facts_files: [.facts_file | split(",")[] | split("/") | last]}')" \
      || cl='{"transient":false,"retry_safe":false,"fact":null,"class":"unknown","reason":"classify-failure.py failed on the trace"}'
  else
    err "trace of job $id ($name) could not be fetched: $(redact <"$TMP/trace-$id.err" | tr '\n' ' ')"
    lines='[]'; exit_code=null; ff=null
    cl='{"transient":false,"retry_safe":false,"fact":null,"class":"unknown","reason":"trace unavailable; an unknown failure is never retried automatically"}'
  fi
  local entry
  entry="$(jq -cn --arg n "$name" --argjson id "$id" --argjson fr "$fr" --argjson cl "$cl" --argjson rc "$lines" --argjson ec "$exit_code" --argjson pid "$PIPE_ID" \
    --argjson wu "$wu" --argjson ff "$ff" \
    '{name: $n, id: $id, pipeline_id: $pid, web_url: $wu, failure_reason: $fr, exit_code: $ec, first_failure: $ff, classification: $cl, root_cause: $rc}')"
  append TRIAGE "$entry"
  append FAILED_ROUND "$entry"
}

# decide_retry <entry-json> — POST the retry when every guard passes; records why not.
decide_retry() {
  local e="$1" name id transient safe count reason
  name="$(printf '%s' "$e" | jq -r .name)"; id="$(printf '%s' "$e" | jq -r .id)"
  transient="$(printf '%s' "$e" | jq -r '.classification.transient')"
  safe="$(printf '%s' "$e" | jq -r '.classification.retry_safe')"
  reason="$(printf '%s' "$e" | jq -r '.classification.reason')"
  count="$(printf '%s' "$JOBS" | jq -r --arg n "$name" '[.[] | select(.name == $n)][0].retry_count // 0')"
  if has_name "$RETRIED_NAMES" "$name"; then
    append RETRY_SKIPPED "$(jq -cn --arg n "$name" --argjson id "$id" '{name: $n, id: $id, reason: "already retried once in this watch"}')"
  elif [ "$transient" != true ]; then
    append RETRY_SKIPPED "$(jq -cn --arg n "$name" --argjson id "$id" --arg r "$reason" '{name: $n, id: $id, reason: ("not transient: " + $r)}')"
  elif [ "$safe" != true ]; then
    err "retry requested for $name (#$id) but unsafe: $reason"
    append RETRY_UNSAFE "$(jq -cn --arg n "$name" --argjson id "$id" --arg r "$reason" '{name: $n, id: $id, reason: $r}')"
  elif [ "$NO_MR_CONTEXT" = true ]; then
    append RETRY_SKIPPED "$(jq -cn --arg n "$name" --argjson id "$id" '{name: $n, id: $id, reason: "no_mr_context: no merge request could be resolved for this pipeline, so the superseded guard cannot run; resume with --mr <iid> --pipeline <id> or let a human retry"}')"
  elif [ "$SUPERSEDED" = true ]; then
    append RETRY_SKIPPED "$(jq -cn --arg n "$name" --argjson id "$id" --argjson h "$HEAD_ID" '{name: $n, id: $id, reason: ("pipeline superseded: the MR head pipeline is now " + ($h | tostring) + "; never retry a superseded pipeline")}')"
  elif [ "$count" -gt 0 ]; then
    append RETRY_SKIPPED "$(jq -cn --arg n "$name" --argjson id "$id" --argjson c "$count" '{name: $n, id: $id, reason: ("retry budget spent: " + (($c + 1) | tostring) + " same-named jobs already ran in this pipeline (include_retried)")}')"
  else
    local resp new_id
    if resp="$(p_job_retry "$PROJECT" "$id")"; then
      new_id="$(printf '%s' "$resp" | jq -c '.id // null')"
      err "retried $name (#$id) -> new job $new_id"
      append RETRIED "$id"
      append RETRY_LOG "$(jq -cn --arg n "$name" --argjson id "$id" --argjson nid "$new_id" --argjson at "$ELAPSED" '{name: $n, id: $id, new_id: $nid, at_s: $at}')"
      append RETRIED_NAMES "$(jq -cn --arg n "$name" '$n')"
      DID_RETRY=true
    else
      append RETRY_SKIPPED "$(jq -cn --arg n "$name" --argjson id "$id" '{name: $n, id: $id, reason: "retry POST failed"}')"
    fi
  fi
}

# post_note <entry-json> — marker-tagged triage note on the MR, deduplicated per job name.
post_note() {
  local e="$1" name id key bf out decision fence
  name="$(printf '%s' "$e" | jq -r .name)"; id="$(printf '%s' "$e" | jq -r .id)"
  key="triage-$PIPE_ID-$name"
  decision="not retried"
  if jq -en --argjson a "$RETRY_LOG" --argjson id "$id" '$a | map(.id) | index($id) != null' >/dev/null; then decision="retried once (job re-run)"; fi
  if jq -en --argjson a "$RETRY_UNSAFE" --argjson id "$id" '$a | map(.id) | index($id) != null' >/dev/null; then decision="retry refused: unsafe (see classification)"; fi
  bf="$TMP/note-$id.md"
  {
    printf '### silkOps triage — pipeline %s, job %s (#%s)\n\n' "$PIPE_ID" "$name" "$id"
    printf '%s' "$e" | jq -r '"- job: \(.web_url // "n/a")",
      "- classification: \(.classification.fact // "unknown") · class=\(.classification.class) · transient=\(.classification.transient) · retry_safe=\(.classification.retry_safe)",
      "- reason: \(.classification.reason)",
      "- step: \(.classification.step // .name)",
      "- failure_reason: \(.failure_reason // "n/a") · exit code: \(.exit_code // "n/a")"'
    printf -- '- retry decision: %s\n' "$decision"
    # first failure (pytest short summary): untrusted, and it renders outside the fence, so it
    # is wrapped in an inline code span whose backtick run is longer than any inside it — a
    # backtick or a leading `/` in the trace line can neither escape the span nor read as a
    # quick action (the bullet prefix already keeps it off column 0).
    if jq -en --argjson e "$e" '$e.first_failure != null' >/dev/null; then
      printf '%s' "$e" | jq -r '.first_failure as $f
        | ([$f | match("`+"; "g").string | length] | max // 0 | . + 1) as $n
        | ("`" * $n) as $t
        | "- first failure: " + $t + " " + $f + " " + $t'
    fi
    printf '\n'
    # The trace is untrusted: the fence is one backtick longer than any run inside it (a ``` line
    # cannot close it) and every line is indented, so none starts with `/` (a quick action).
    fence="$(printf '%s' "$e" | jq -r '[.root_cause[] | [match("`+"; "g").string | length] | max // 0] | max // 0 | (. + 1) | if . < 3 then 3 else . end | "`" * .')"
    printf 'Root cause (last %s trace lines before the failure, redacted, indented two spaces):\n\n%s\n' "$ROOT_LINES" "$fence"
    printf '%s' "$e" | jq -r '.root_cause[] | "  " + .'
    printf '%s\n' "$fence"
  } | redact >"$bf"
  if out="$(bash "$OPS/note.sh" --project "$PROJECT" --mr "$MR" --body-file "$bf" --marker-unit U6 --plan "$PLAN" --run "$RUN" --dedupe-key "$key")"; then
    append NOTES "$(printf '%s' "$out" | jq -c --arg n "$name" --argjson id "$id" '{name: $n, job_id: $id, id: .id, existing: .existing, dedupe_key: .dedupe_key}')"
  else
    err "triage note for $name (#$id) could not be posted"
    append NOTES "$(jq -cn --arg n "$name" --argjson id "$id" --arg k "$key" '{name: $n, job_id: $id, id: null, existing: false, dedupe_key: $k, error: "note_failed"}')"
  fi
}

# --- poll loop ----------------------------------------------------------------
while :; do
  POLLS=$((POLLS + 1))
  PIPE_JSON="$(p_run_get "$PROJECT" "$PIPE_ID")" || fail "$EX_NOT_FOUND" not_found "pipeline $PIPE_ID not found in $PROJECT"
  if [ "$CONTEXT_READ" = false ]; then
    CONTEXT_READ=true
    # (#31) how long this ref's last green pipeline took: the expected duration of this one.
    ref="$(printf '%s' "$PIPE_JSON" | jq -r '.ref // ""')"
    if [ -n "$ref" ]; then
      EXPECTED="$(p_run_last_success "$PROJECT" "$ref" 2>/dev/null | jq -c '.[0].duration // null' 2>/dev/null || echo null)"
    fi
    # (#38) the review policy is part of the verdict: approvals outstanding block a merge too.
    if [ -n "$MR" ]; then
      APPROVALS="$(p_mr_approvals "$PROJECT" "$MR" 2>/dev/null | jq -c '{approved: (.approved // false), approvals_left: (.approvals_left // 0), approvals_required: (.approvals_required // 0)}' 2>/dev/null || echo null)"
    fi
  fi
  STATUS="$(printf '%s' "$PIPE_JSON" | jq -r '.status // "unknown"')"
  if [ "$RETRY" = true ] && [ -z "$MR" ] && [ "$MR_RESOLVE_TRIED" != true ]; then
    MR_RESOLVE_TRIED=true; resolve_mr_from_pipeline
  fi
  if RAW="$(fetch_jobs)"; then
    RAW_JOBS="$RAW"; JOBS_KNOWN=true; JOBS_STALE=false
  else
    MSG="$(redact <"$TMP/jobs.err" | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')"
    append ERRORS "$(jq -cn --argjson p "$POLLS" --arg m "${MSG:-jobs listing failed}" '{poll: $p, what: "jobs", message: $m}')"
    if [ "$JOBS_KNOWN" != true ]; then
      fail "$EX_OTHER" jobs_fetch_failed "could not list the jobs of pipeline $PIPE_ID on the first poll; refusing to report a pipeline with no jobs: $MSG" \
        "$(jq -cn --argjson pid "$PIPE_ID" --arg st "$STATUS" --argjson e "$ERRORS" '{pipeline_id: $pid, status: $st, errors: $e}')"
    fi
    JOBS_STALE=true
    err "poll $POLLS: jobs listing failed, keeping the previous poll's snapshot ($MSG)"
  fi
  # Latest job per name; retry_count = same-named jobs minus one (KTD6: GitLab has no field).
  JOBS="$(printf '%s' "$RAW_JOBS" | jq -c 'group_by(.name) | map(sort_by(.id) | {name: .[-1].name, status: .[-1].status, id: .[-1].id,
      failure_reason: (.[-1].failure_reason // null), stage: (.[-1].stage // null), retry_count: (length - 1), web_url: (.[-1].web_url // null)})')"
  CUR="$(printf '%s' "$JOBS" | jq -c 'map({key: .name, value: .status}) | from_entries')"
  NEW="$(jq -cn --argjson p "$PREV" --argjson j "$JOBS" --argjson at "$ELAPSED" \
    '[$j[] | select(($p[.name] // null) != null and $p[.name] != .status) | {name, id, from: $p[.name], to: .status, at_s: $at}]')"
  CHANGES="$(jq -cn --argjson a "$CHANGES" --argjson b "$NEW" '$a + $b')"
  PREV="$CUR"
  if [ -n "$MR" ]; then
    if MRJ="$(fetch_mr)"; then read_mr; fi
    if [ "$HEAD_ID" != null ] && [ "$HEAD_ID" != "$PIPE_ID" ]; then SUPERSEDED=true; else SUPERSEDED=false; fi
  fi
  err "poll $POLLS (t=${ELAPSED}s): pipeline $PIPE_ID $STATUS$( [ "$SUPERSEDED" = true ] && printf ' (superseded by %s)' "$HEAD_ID")$( [ "$NEW" != '[]' ] && printf ' · changes: %s' "$(printf '%s' "$NEW" | jq -r 'map("\(.name) \(.from)->\(.to)") | join(", ")')")"

  if is_terminal "$STATUS"; then
    if [ "$JOBS_STALE" = true ] && [ $((ELAPSED + INTERVAL)) -le "$WAIT" ]; then
      # terminal, but this poll's job list is the old snapshot: look again before triaging
      err "pipeline $PIPE_ID is $STATUS but the jobs listing failed this poll; polling once more before triage"
      sleep "$SLEEP_S"; ELAPSED=$((ELAPSED + INTERVAL))
      continue
    fi
    if [ "$STATUS" = failed ]; then
      FAILED_ROUND='[]'; DID_RETRY=false
      while IFS= read -r job; do
        [ -n "$job" ] || continue
        triage_job "$job"
      done < <(printf '%s' "$JOBS" | jq -c '.[] | select(.status == "failed")')
      if [ "$RETRY" = true ] && [ "$JOBS_STALE" = true ]; then
        # never decide a retry on a stale snapshot (the budget count could be wrong)
        while IFS= read -r e; do
          [ -n "$e" ] && append RETRY_SKIPPED "$(printf '%s' "$e" | jq -c '{name, id, reason: "jobs listing failed this poll; no retry is decided on a stale job snapshot"}')"
        done < <(printf '%s' "$FAILED_ROUND" | jq -c '.[]')
      elif [ "$RETRY" = true ]; then
        while IFS= read -r e; do [ -n "$e" ] && decide_retry "$e"; done < <(printf '%s' "$FAILED_ROUND" | jq -c '.[]')
      fi
      if [ "$NOTE" = true ]; then
        while IFS= read -r e; do [ -n "$e" ] && post_note "$e"; done < <(printf '%s' "$FAILED_ROUND" | jq -c '.[]')
      fi
      if [ "$DID_RETRY" = true ]; then
        # The retried job is running again under a new id: keep watching this pipeline.
        if [ $((ELAPSED + INTERVAL)) -gt "$WAIT" ]; then
          STATUS=running
          report '{}'; exit "$EX_OK"
        fi
        sleep "$SLEEP_S"; ELAPSED=$((ELAPSED + INTERVAL))
        continue
      fi
    fi
    if [ "$RETRY" = true ] && [ "$RETRY_UNSAFE" != '[]' ]; then
      NAMES="$(printf '%s' "$RETRY_UNSAFE" | jq -r 'map("\(.name) (#\(.id))") | join(", ")')"
      MSG="retry requested but unsafe for: $NAMES — the immutability guard (silkops: no-retry-after) or the fact forbids it; a human decides"
      err "$MSG"
      report "$(jq -cn --arg m "$MSG" '{ok: false, error: "retry_unsafe", message: $m}')"
      exit "$EX_RETRY_UNSAFE"
    fi
    report '{}'
    exit "$EX_OK"
  fi

  if [ $((ELAPSED + INTERVAL)) -gt "$WAIT" ]; then
    err "wait budget of ${WAIT}s spent; pipeline $PIPE_ID still $STATUS — resume with: $(resume_hint)"
    report '{}'
    exit "$EX_OK"
  fi
  sleep "$SLEEP_S"; ELAPSED=$((ELAPSED + INTERVAL))
done
