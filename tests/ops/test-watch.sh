#!/usr/bin/env bash
# Tier 1 tests for ops/watch.sh against the glab stub (no network, no real sleeping).
# The stop condition comes first: a green MR pipeline ends "ready" with NO merge call.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STUB_DIR="$ROOT/tests/fixtures/glab-stub"
PASS=0; FAIL=0
PROJECT="void-realm-solutions/silkops-harness-eval"
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }
# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
SCRIPT="$ROOT/ops/watch.sh"
SCRATCH="$(mktemp -d "${SILKOPS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/silkops-watch.XXXXXX")"

# Phased stub: the real stub is stateless, so a wrapper first on PATH selects the
# scenario dir from GLAB_STUB_PHASES (colon-separated) by counting `GET
# projects/*/pipelines/<id>` polls (or GLAB_STUB_PHASE_MATCH, a glob over "METHOD path")
# — poll n is served from phase n (the last phase repeats). Every other call (MR, jobs,
# trace, retry, notes) uses the current phase.
mkdir -p "$SCRATCH/bin"
cat >"$SCRATCH/bin/glab" <<EOF
#!/usr/bin/env bash
set -uo pipefail
real="$STUB_DIR/glab"
if [ -n "\${GLAB_STUB_PHASES:-}" ]; then
  IFS=: read -r -a phases <<<"\$GLAB_STUB_PHASES"
  f="\$GLAB_STUB_PHASE_FILE"; n="\$(cat "\$f" 2>/dev/null || echo 0)"
  method=GET; path=""; rest=("\${@:2}")
  for ((i = 0; i < \${#rest[@]}; i++)); do case "\${rest[\$i]}" in -X) method="\${rest[\$((i + 1))]}"; i=\$((i + 1)) ;; --input) i=\$((i + 1)) ;; -*) ;; *) path="\${rest[\$i]}" ;; esac; done
  match="\${GLAB_STUB_PHASE_MATCH:-GET projects/*/pipelines/[0-9]*}"
  # shellcheck disable=SC2254  # the glob is the point
  case "\$method \$path" in *"/jobs"*) ;; \$match) n=\$((n + 1)); echo "\$n" >"\$f" ;; esac
  [ "\$n" -ge 1 ] || n=1
  [ "\$n" -le "\${#phases[@]}" ] || n="\${#phases[@]}"
  export GLAB_STUB_SCENARIO="\${phases[\$((n - 1))]}"
fi
exec "\$real" "\$@"
EOF
chmod +x "$SCRATCH/bin/glab"
export PATH="$SCRATCH/bin:$STUB_DIR:$PATH"
[ "$(command -v glab)" = "$SCRATCH/bin/glab" ] || { echo "glab stub wrapper is not first on PATH" >&2; exit 1; }

# run_case <name> <scenario[:scenario…]> <env KEY=VAL ...> -- <args...>
run_case() {
  local name="$1" scenarios="$2"; shift 2
  local phases="" s
  IFS=: read -r -a parts <<<"$scenarios"
  for s in "${parts[@]}"; do
    case "$s" in /*) ;; *) s="$STUB_DIR/$s" ;; esac
    phases="${phases:+$phases:}$s"
  done
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  local d="$SCRATCH/$name"; mkdir -p "$d"
  env -u GITLAB_TOKEN -u SILKOPS_SETTINGS_TOKEN -u SILKOPS_CI_TOKEN -u CI \
    GLAB_STUB_SCENARIO="${parts[0]}" GLAB_STUB_PHASES="$phases" GLAB_STUB_PHASE_FILE="$d/phase" \
    GLAB_STUB_LOG="$d/glab.log" GLAB_STUB_BODY_DIR="$d/bodies" SILKOPS_WATCH_SLEEP=0 "${envs[@]}" \
    bash "$SCRIPT" "$@" >"$d/out.log" 2>"$d/err.log"
  echo $? >"$d/rc"
}
rc_of()  { cat "$SCRATCH/$1/rc"; }
out_of() { cat "$SCRATCH/$1/out.log"; }
err_of() { cat "$SCRATCH/$1/err.log"; }
log_of() { cat "$SCRATCH/$1/glab.log" 2>/dev/null; }
calls_of() { log_of "$1" | wc -l | tr -d ' '; }
writes_of() { log_of "$1" | grep -cE -- '-X (POST|PUT|DELETE)'; }
retries_of() { log_of "$1" | grep -cE -- '-X POST .*/jobs/[0-9]+/retry'; }
notes_posted() { log_of "$1" | grep -cE -- '-X POST .*/merge_requests/7/notes'; }
merge_calls() { log_of "$1" | grep -cE -- 'mr merge|/merge([^_a-zA-Z]|$)'; }
body_of() { cat "$SCRATCH/$1/bodies/$2.json"; }
COMMON=(--project "$PROJECT" --plan plan.md --run r1)

# --- AE3: the stop condition ---------------------------------------------------
run_case w1 watch-green -- "${COMMON[@]}" --mr 7 --wait 60
if [ "$(rc_of w1)" = 0 ] && out_of w1 | jq -e '.ok == true and .pipeline_id == 501 and .status == "success" and .terminal == true
      and .ready == true and .detailed_merge_status == "mergeable" and .superseded == false and .still_running == false
      and (.jobs | length) == 3 and .failed == [] and .retried == []' >/dev/null \
  && [ "$(merge_calls w1)" = 0 ] && [ "$(writes_of w1)" = 0 ] && ! log_of w1 | grep 'token=set' >/dev/null; then
  pass "W1 (AE3) green MR pipeline -> ready:true, mergeable reported, zero writes, no merge call ever"
else fail "W1" "rc=$(rc_of w1) out=$(out_of w1) log=$(log_of w1 | tr '\n' ';')"; fi

run_case w1b watch-green -- "${COMMON[@]}" --pipeline 501 --wait 0
if [ "$(rc_of w1b)" = 0 ] && out_of w1b | jq -e '.ok == true and .ready == true and .terminal == true and .detailed_merge_status == null and .superseded == false' >/dev/null \
  && ! log_of w1b | grep merge_requests >/dev/null; then
  pass "W1b bare --pipeline: ready == success, no MR lookup"
else fail "W1b" "rc=$(rc_of w1b) out=$(out_of w1b)"; fi

run_case w17 watch-green -- "${COMMON[@]}" --mr 7 --wait 0 --sha a1b2c3d4e5f60718293a4b5c6d7e8f9012345678
if [ "$(rc_of w17)" = 0 ] && [ "$(out_of w17 | jq -r .ready)" = true ]; then
  pass "W17 --sha matching the head pipeline's commit -> watches it normally (ready:true)"
else fail "W17" "rc=$(rc_of w17) out=$(out_of w17)"; fi
run_case w17c watch-green -- "${COMMON[@]}" --mr 7 --wait 0 --sha a1b2c3d
if [ "$(rc_of w17c)" = 0 ] && [ "$(out_of w17c | jq -r .ready)" = true ] && [ "$(out_of w17c | jq -r .still_running)" = false ]; then
  pass "W17c (#26) an abbreviated --sha that prefixes the head pipeline's commit matches"
else fail "W17c" "rc=$(rc_of w17c) out=$(out_of w17c | head -c 400)"; fi

run_case w17b watch-green -- "${COMMON[@]}" --mr 7 --wait 0 --sha deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
if [ "$(rc_of w17b)" = 0 ] && [ "$(out_of w17b | jq -r .still_running)" = true ] && [ "$(out_of w17b | jq -r .waiting_for_sha)" = deadbeefdeadbeefdeadbeefdeadbeefdeadbeef ] && [ "$(out_of w17b | jq -r .resume_hint)" != null ]; then
  pass "W17b --sha not yet the head pipeline's commit, budget spent -> still_running with waiting_for_sha and a resume hint, no retry"
else fail "W17b" "rc=$(rc_of w17b) out=$(out_of w17b)"; fi

# --- usage / resolution ---------------------------------------------------------
run_case w2 watch-green -- --mr 7
if [ "$(rc_of w2)" = 2 ] && err_of w2 | grep -- '--project' >/dev/null && [ "$(calls_of w2)" = 0 ]; then
  pass "W2 missing --project exits 2 before any glab call"
else fail "W2" "rc=$(rc_of w2) calls=$(calls_of w2)"; fi

# --mr with --pipeline is the resume form: that pipeline id, the MR's merge status and superseded guard
run_case w2b watch-green -- "${COMMON[@]}" --mr 7 --pipeline 501 --wait 0
if [ "$(rc_of w2b)" = 0 ] && out_of w2b | jq -e '.ok == true and .pipeline_id == 501 and .mr_iid == 7 and .ready == true and .detailed_merge_status == "mergeable" and .superseded == false
      and .resume_hint == "watch.sh --project void-realm-solutions/silkops-harness-eval --mr 7 --pipeline 501"' >/dev/null; then
  pass "W2b --mr and --pipeline together -> watches the given pipeline with the MR's context"
else fail "W2b" "rc=$(rc_of w2b) out=$(out_of w2b)"; fi
run_case w2c watch-green -- "${COMMON[@]}" --mr x
if [ "$(rc_of w2c)" = 2 ] && [ "$(calls_of w2c)" = 0 ]; then pass "W2c non-numeric --mr exits 2"; else fail "W2c" "rc=$(rc_of w2c)"; fi

# v0.2 U10 (#30): right after mr-upsert the MR has no head pipeline yet; wait it out inside the budget
run_case w3 watch-no-pipeline -- "${COMMON[@]}" --mr 7 --wait 0
if [ "$(rc_of w3)" = 0 ] && out_of w3 | jq -e '.ok == true and .still_running == true and .waiting_for == "head_pipeline" and .ready == false
      and .resume_hint == "watch.sh --project void-realm-solutions/silkops-harness-eval --mr 7"' >/dev/null && [ "$(writes_of w3)" = 0 ]; then
  pass "W3 (#30) no head pipeline and the budget spent -> still_running with waiting_for: head_pipeline and an MR resume hint, exit 0"
else fail "W3" "rc=$(rc_of w3) out=$(out_of w3)"; fi
run_case w3b watch-no-pipeline:watch-green GLAB_STUB_PHASE_MATCH="GET projects/*/merge_requests/7" -- "${COMMON[@]}" --mr 7 --wait 40 --interval 20
if [ "$(rc_of w3b)" = 0 ] && out_of w3b | jq -e '.ready == true and .pipeline_id == 501' >/dev/null; then
  pass "W3b (#30) the head pipeline appears on the second MR read -> watched to ready inside one call"
else fail "W3b" "rc=$(rc_of w3b) out=$(out_of w3b | head -c 600)"; fi

# --- AE2: transient before the marker -> one retry, then green -----------------------
run_case w4 watch-failed-transient:watch-after-retry -- "${COMMON[@]}" --mr 7 --retry --wait 60 --interval 20
if [ "$(rc_of w4)" = 0 ] && out_of w4 | jq -e '.ok == true and .status == "success" and .ready == true and .retried == [9001]
      and .retry_log[0].name == "build-sec-tools" and .retry_log[0].new_id == 9002
      and (.jobs[] | select(.name == "build-sec-tools") | .id == 9002 and .retry_count == 1)
      and (.changes | map(select(.name == "build-sec-tools" and .from == "failed" and .to == "success")) | length) == 1
      and (.triage[0].classification.transient == true and .triage[0].classification.retry_safe == true and .triage[0].classification.fact == "docker-hub-502")' >/dev/null \
  && [ "$(retries_of w4)" = 1 ] && log_of w4 | grep -E -- '-X POST .*/jobs/9001/retry' >/dev/null \
  && log_of w4 | grep -E -- 'jobs\?include_retried=true' >/dev/null && [ "$(merge_calls w4)" = 0 ]; then
  pass "W4 (AE2) docker-hub-502 with --retry -> exactly one POST retry, kept watching, success with the job listed in retried"
else fail "W4" "rc=$(rc_of w4) out=$(out_of w4) log=$(log_of w4 | tr '\n' ';')"; fi

run_case w4b watch-failed-transient -- "${COMMON[@]}" --mr 7 --wait 0
if [ "$(rc_of w4b)" = 0 ] && out_of w4b | jq -e '.ok == true and .status == "failed" and .terminal == true and .ready == false
      and .failed[0].name == "build-sec-tools" and .failed[0].id == 9001 and .failed[0].classification.transient == true
      and (.failed[0].root_cause | length) > 0 and (.failed[0].root_cause | any(contains("502 Bad Gateway")))
      and .retried == [] and .still_running == false' >/dev/null \
  && [ "$(writes_of w4b)" = 0 ]; then
  pass "W4b failed without --retry -> terminal report with classification + root cause, exit 0, no writes"
else fail "W4b" "rc=$(rc_of w4b) out=$(out_of w4b)"; fi

# --- AE7: transient after the point of no return -> no retry, exit 6 ------------------
run_case w5 watch-failed-after-push -- "${COMMON[@]}" --mr 7 --retry --wait 0
if [ "$(rc_of w5)" = 6 ] && out_of w5 | jq -e '.ok == false and .error == "retry_unsafe" and .status == "failed" and .terminal == true
      and .failed[0].classification.transient == true and .failed[0].classification.retry_safe == false
      and .retried == [] and (.retry_unsafe[0].reason | contains("no-retry-after") and contains("immutability guard"))
      and (.message | contains("build-sec-tools"))' >/dev/null \
  && [ "$(retries_of w5)" = 0 ] && [ "$(merge_calls w5)" = 0 ]; then
  pass "W5 (AE7) 502 after the build-image: pushing marker with --retry -> no retry POST, exit 6, reason names the guard, full report"
else fail "W5" "rc=$(rc_of w5) out=$(out_of w5) log=$(log_of w5 | tr '\n' ';')"; fi

# --- superseded pipeline: never retried ---------------------------------------------
# The head pipeline moves from 501 to 502 between the resolving MR read and the refresh.
run_case w6 watch-failed-transient:watch-superseded GLAB_STUB_PHASE_MATCH='GET */merge_requests/7' -- "${COMMON[@]}" --mr 7 --retry --wait 0
if [ "$(rc_of w6)" = 0 ] && out_of w6 | jq -e '.ok == true and .superseded == true and .status == "failed" and .retried == []
      and .head_pipeline_id == 502 and (.retry_skipped[0].reason | contains("superseded"))' >/dev/null \
  && [ "$(retries_of w6)" = 0 ]; then
  pass "W6 superseded pipeline (head moved to 502) -> superseded:true, transient+safe job still not retried"
else fail "W6" "rc=$(rc_of w6) out=$(out_of w6) log=$(log_of w6 | tr '\n' ';')"; fi

# --- retry budget: a job already retried once is not retried again -------------------
run_case w6b watch-note-existing -- "${COMMON[@]}" --mr 7 --retry --wait 0
if [ "$(rc_of w6b)" = 0 ] && out_of w6b | jq -e '.retried == [] and (.jobs[] | select(.name == "build-sec-tools") | .retry_count == 1)
      and (.retry_skipped[0].reason | contains("budget"))' >/dev/null && [ "$(retries_of w6b)" = 0 ]; then
  pass "W6b retry budget spent (two same-named jobs via include_retried) -> no second retry"
else fail "W6b" "rc=$(rc_of w6b) out=$(out_of w6b)"; fi

# --- manual / canceled: terminal, not waited on -------------------------------------
run_case w7 watch-manual -- "${COMMON[@]}" --mr 7 --wait 300 --interval 20
if [ "$(rc_of w7)" = 0 ] && out_of w7 | jq -e '.status == "manual" and .terminal == true and .ready == false and .still_running == false and .polls == 1' >/dev/null; then
  pass "W7 manual -> terminal, ready:false, a single poll"
else fail "W7" "rc=$(rc_of w7) out=$(out_of w7)"; fi
run_case w7b watch-canceled -- "${COMMON[@]}" --mr 7 --wait 300 --interval 20
if [ "$(rc_of w7b)" = 0 ] && out_of w7b | jq -e '.status == "canceled" and .terminal == true and .ready == false and .polls == 1' >/dev/null; then
  pass "W7b canceled -> terminal, ready:false, a single poll"
else fail "W7b" "rc=$(rc_of w7b) out=$(out_of w7b)"; fi

# --- wait budget exhausted -----------------------------------------------------------
run_case w8 watch-running -- "${COMMON[@]}" --mr 7 --wait 40 --interval 20
if [ "$(rc_of w8)" = 0 ] && out_of w8 | jq -e '.ok == true and .status == "running" and .terminal == false and .ready == false and .still_running == true
      and .polls == 3 and .waited_s == 40 and .errors == [] and .resume_hint == "watch.sh --project void-realm-solutions/silkops-harness-eval --mr 7 --pipeline 501"' >/dev/null \
  && [ "$(writes_of w8)" = 0 ] && err_of w8 | grep -- 'resume with: watch.sh --project void-realm-solutions/silkops-harness-eval --mr 7 --pipeline 501' >/dev/null; then
  pass "W8 running past the wait budget -> still_running:true, resume hint carries --mr and --pipeline, exit 0"
else fail "W8" "rc=$(rc_of w8) out=$(out_of w8)"; fi
# v0.2 U10 (#31): a still-running report states how long this ref's last green run took and when to come back
if out_of w8 | jq -e '.expected_duration_s == 540 and (.resume_after_s | type) == "number" and .resume_after_s >= 20 and .resume_after_s <= 540' >/dev/null; then
  pass "W8b (#31) expected_duration_s from the ref's last successful pipeline, resume_after_s bounded by it"
else fail "W8b" "out=$(out_of w8 | jq -c '{expected_duration_s, resume_after_s}')"; fi
if out_of w1 | jq -e '.expected_duration_s == null or (.expected_duration_s | type) == "number"' >/dev/null && out_of w1 | jq -e '.approvals.approved == true and .not_ready_reason == null' >/dev/null; then
  pass "W1b (#38) the green MR carries the approval state and no not_ready_reason"
else fail "W1b" "out=$(out_of w1 | jq -c '{expected_duration_s, approvals, not_ready_reason}')"; fi

# --- resume by pipeline id reaches the same terminal report --------------------------
run_case w9 watch-running:watch-running:watch-green -- "${COMMON[@]}" --pipeline 501 --wait 300 --interval 20
if [ "$(rc_of w9)" = 0 ] && out_of w9 | jq -e '.status == "success" and .terminal == true and .ready == true and .polls == 3
      and (.changes | map(select(.name == "build-sec-tools" and .from == "running" and .to == "success")) | length) == 1
      and (.changes | map(select(.name == "factory-tests" and .from == "created" and .to == "success")) | length) == 1' >/dev/null; then
  pass "W9 resume by --pipeline: running, running, success -> same terminal report, transitions listed"
else fail "W9" "rc=$(rc_of w9) out=$(out_of w9)"; fi
G_MR="$(out_of w1 | jq -c '{pipeline_id, status, terminal, ready, jobs: (.jobs | map({name, status, id}))}')"
G_PIPE="$(out_of w9 | jq -c '{pipeline_id, status, terminal, ready, jobs: (.jobs | map({name, status, id}))}')"
if [ "$G_MR" = "$G_PIPE" ]; then pass "W9b --mr and --pipeline agree on the terminal report core"; else fail "W9b" "mr=$G_MR pipe=$G_PIPE"; fi

# --- terminal but not ready ----------------------------------------------------------
run_case w10 watch-notready -- "${COMMON[@]}" --mr 7 --wait 0
if [ "$(rc_of w10)" = 0 ] && out_of w10 | jq -e '.status == "success" and .terminal == true and .ready == false and .detailed_merge_status == "need_rebase"' >/dev/null; then
  pass "W10 success but need_rebase -> terminal, ready:false, detailed_merge_status reported"
else fail "W10" "rc=$(rc_of w10) out=$(out_of w10)"; fi
# v0.2 U10 (#38): not ready is explained, and the review policy is part of the verdict
if out_of w10 | jq -e '.ready == false and (.not_ready_reason | test("rebase")) and .approvals.approvals_left == 1 and .approvals.approved == false' >/dev/null; then
  pass "W10b (#38) need_rebase -> not_ready_reason says rebase; approvals_left reported"
else fail "W10b" "out=$(out_of w10 | jq -c '{detailed_merge_status, not_ready_reason, approvals}')"; fi

# --- --note: one triage note, deduplicated on the second run -------------------------
run_case w11 watch-failed-transient -- "${COMMON[@]}" --mr 7 --note --wait 0
if [ "$(rc_of w11)" = 0 ] && [ "$(notes_posted w11)" = 1 ] && out_of w11 | jq -e '.notes[0].existing == false and .notes[0].dedupe_key == "triage-501-build-sec-tools"' >/dev/null \
  && body_of w11 1 | jq -e '.path | endswith("/merge_requests/7/notes")' >/dev/null \
  && body_of w11 1 | jq -e '.body.body | contains("<!-- silkops:key=triage-501-build-sec-tools -->") and contains("docker-hub-502") and contains("502 Bad Gateway") and contains("plan=plan.md unit=U6 run=r1")' >/dev/null \
  && [ "$(retries_of w11)" = 0 ]; then
  pass "W11 --note posts one marker-tagged triage note (classification + root cause), no retry without --retry"
else fail "W11" "rc=$(rc_of w11) out=$(out_of w11) log=$(log_of w11 | tr '\n' ';') body=$(body_of w11 1 2>/dev/null)"; fi

run_case w11b watch-note-existing -- "${COMMON[@]}" --mr 7 --note --wait 0
if [ "$(rc_of w11b)" = 0 ] && [ "$(notes_posted w11b)" = 0 ] && out_of w11b | jq -e '.notes[0].existing == true and .notes[0].id == 901' >/dev/null; then
  pass "W11b second run with the triage note already present -> no duplicate note"
else fail "W11b" "rc=$(rc_of w11b) out=$(out_of w11b) log=$(log_of w11b | tr '\n' ';')"; fi

# --- redaction: oauth2 credential in a root-cause line ---------------------------------
run_case w12 watch-oauth -- "${COMMON[@]}" --mr 7 --note --wait 0
if [ "$(rc_of w12)" = 0 ] && out_of w12 | jq -e '(.failed[0].root_cause | any(contains("oauth2:<REDACTED>@")))' >/dev/null \
  && ! out_of w12 | grep 'glpat-fake' >/dev/null && ! grep -r 'glpat-fake' "$SCRATCH/w12/bodies" >/dev/null \
  && body_of w12 1 | jq -e '.body.body | contains("oauth2:<REDACTED>@")' >/dev/null \
  && ! err_of w12 | grep 'glpat-fake' >/dev/null; then
  pass "W12 oauth2:<cred>@ in a root-cause line is redacted in the result, the note body, and stderr"
else fail "W12" "rc=$(rc_of w12) out=$(out_of w12) body=$(body_of w12 1 2>/dev/null)"; fi

# --- review #9: a trace cannot close the note's fence or start a line with a quick action ---
run_case w13 watch-fence -- "${COMMON[@]}" --mr 7 --note --wait 0
W13_BODY="$(body_of w13 1 2>/dev/null | jq -r '.body.body' 2>/dev/null)"
if [ "$(rc_of w13)" = 0 ] && [ "$(notes_posted w13)" = 1 ] && [ -n "$W13_BODY" ] \
  && out_of w13 | jq -e '(.failed[0].root_cause | index("```") != null) and (.failed[0].root_cause | index("/approve") != null)' >/dev/null \
  && ! printf '%s\n' "$W13_BODY" | grep -E '^/' >/dev/null \
  && [ "$(printf '%s\n' "$W13_BODY" | grep -cE '^````$')" = 2 ] \
  && printf '%s\n' "$W13_BODY" | grep -xF '  ```' >/dev/null && printf '%s\n' "$W13_BODY" | grep -xF '  /approve' >/dev/null \
  && printf '%s\n' "$W13_BODY" | awk '/^````$/{n++; next} n==1 && /^\/|^```$/{bad=1} END{exit bad}'; then
  pass "W13 trace with a \`\`\` line and quick-action lines -> note fence is longer (````), every root-cause line indented, no line starts with /"
else fail "W13" "rc=$(rc_of w13) notes=$(notes_posted w13) body=$(printf '%s' "$W13_BODY" | head -c 900)"; fi

# --- review #10: jobs listing paginated; a failed listing is an error, never "zero jobs" ----------
PAGED="$SCRATCH/watch-paged"; mkdir -p "$PAGED"
cp "$STUB_DIR/watch-common/pipeline-success.json" "$PAGED/pipeline.json"
jq -c '[range(1; 101) | {id: (8000 + .), name: ("job-" + (. | tostring)), stage: "build", status: "success", failure_reason: null, web_url: ("https://gitlab.com/x/-/jobs/" + (8000 + . | tostring))}]' -n >"$PAGED/jobs-p1.json"
jq -c '[range(101; 104) | {id: (8000 + .), name: ("job-" + (. | tostring)), stage: "build", status: "success", failure_reason: null, web_url: ("https://gitlab.com/x/-/jobs/" + (8000 + . | tostring))}]' -n >"$PAGED/jobs-p2.json"
printf 'GET\tprojects/*/pipelines/501\tpipeline.json\nGET\tprojects/*/pipelines/501/jobs*\tjobs-p2.json\t200\t*&page=2*\nGET\tprojects/*/pipelines/501/jobs*\tjobs-p1.json\n' >"$PAGED/routes.tsv"
run_case w14 "$PAGED" -- "${COMMON[@]}" --pipeline 501 --wait 0
if [ "$(rc_of w14)" = 0 ] && out_of w14 | jq -e '.ok == true and .status == "success" and (.jobs | length) == 103 and (.jobs | map(.name) | index("job-103") != null) and (.jobs | map(.name) | index("job-1") != null) and .errors == []' >/dev/null \
  && [ "$(log_of w14 | grep -cE -- '/jobs\?include_retried=true&per_page=100&page=1')" = 1 ] && [ "$(log_of w14 | grep -cE -- '&page=2')" = 1 ] && [ "$(log_of w14 | grep -cE -- '&page=3')" = 0 ]; then
  pass "W14 103 jobs across two pages -> every job in the report, exactly pages 1 and 2 fetched"
else fail "W14" "rc=$(rc_of w14) n=$(out_of w14 | jq '.jobs | length') log=$(log_of w14 | tr '\n' ';')"; fi

# poll 1 running (jobs ok), poll 2 failed with the jobs GET returning 500, budget spent
run_case w15 watch-running:watch-jobs-500 -- "${COMMON[@]}" --mr 7 --retry --wait 20 --interval 20
if [ "$(rc_of w15)" = 0 ] && out_of w15 | jq -e '.ok == true and .status == "failed" and .terminal == true and .polls == 2
      and (.errors | length) == 1 and .errors[0].poll == 2 and .errors[0].what == "jobs" and (.errors[0].message | contains("500"))
      and (.jobs | length) == 3 and (.jobs | map(.status) | index("running") != null) and .retried == []' >/dev/null \
  && [ "$(retries_of w15)" = 0 ] && ! out_of w15 | grep 'glpat-stubsecret' >/dev/null && ! err_of w15 | grep 'glpat-stubsecret' >/dev/null; then
  pass "W15 jobs GET 500 mid-watch -> errors entry for that poll, previous snapshot kept (not zero jobs), no retry POST, stub token redacted"
else fail "W15" "rc=$(rc_of w15) out=$(out_of w15) log=$(log_of w15 | tr '\n' ';')"; fi

run_case w15b watch-jobs-500 -- "${COMMON[@]}" --mr 7 --wait 0
if [ "$(rc_of w15b)" = 1 ] && out_of w15b | jq -e '.ok == false and .error == "jobs_fetch_failed" and .pipeline_id == 501 and .errors[0].what == "jobs"' >/dev/null && [ "$(writes_of w15b)" = 0 ]; then
  pass "W15b jobs GET 500 on the first poll -> exit 1 jobs_fetch_failed, zero writes"
else fail "W15b" "rc=$(rc_of w15b) out=$(out_of w15b)"; fi

# --- review #18: resuming by --pipeline keeps the superseded guard ------------------------------
# the head moved to 502 while the watch was away; a resume by pipeline id with --retry must not POST
run_case w16 watch-superseded -- "${COMMON[@]}" --pipeline 501 --retry --wait 0
if [ "$(rc_of w16)" = 0 ] && out_of w16 | jq -e '.ok == true and .mr_iid == 7 and .superseded == true and .head_pipeline_id == 502 and .status == "failed"
      and .failed[0].classification.transient == true and .failed[0].classification.retry_safe == true and .retried == []
      and (.retry_skipped[0].reason | contains("superseded"))' >/dev/null && [ "$(retries_of w16)" = 0 ]; then
  pass "W16 resume with --pipeline after the head moved, --retry -> MR resolved from the pipeline ref, superseded, no retry POST"
else fail "W16" "rc=$(rc_of w16) out=$(out_of w16) log=$(log_of w16 | tr '\n' ';')"; fi

run_case w16b watch-branch-nomr -- "${COMMON[@]}" --pipeline 501 --retry --wait 0
if [ "$(rc_of w16b)" = 0 ] && out_of w16b | jq -e '.ok == true and .mr_iid == null and .status == "failed" and .retried == []
      and (.retry_skipped[0].reason | startswith("no_mr_context"))' >/dev/null && [ "$(retries_of w16b)" = 0 ] \
  && log_of w16b | grep -E -- 'merge_requests\?source_branch=feat%2Fu6' >/dev/null; then
  pass "W16b bare --pipeline on a branch pipeline without an open MR, --retry -> retry refused (no_mr_context), report still produced"
else fail "W16b" "rc=$(rc_of w16b) out=$(out_of w16b) log=$(log_of w16b | tr '\n' ';')"; fi

# --- issue #22: triage-note readability (step fallback, job URL, first FAILED line) ------
JOB_URL="https://gitlab.com/void-realm-solutions/silkops-harness-eval/-/jobs/9001"

# 1 + 2 + 3: no fact matched -> step falls back to the job name; the job URL and the first
# pytest `FAILED` line are in the note and in the JSON.
run_case w18 watch-pytest -- "${COMMON[@]}" --mr 7 --note --wait 0
W18_BODY="$(body_of w18 1 2>/dev/null | jq -r '.body.body' 2>/dev/null)"
if [ "$(rc_of w18)" = 0 ] && [ "$(notes_posted w18)" = 1 ] && [ -n "$W18_BODY" ] \
  && out_of w18 | jq -e '.failed[0].classification.fact == null and .failed[0].classification.class == "unknown"
      and .failed[0].web_url == "'"$JOB_URL"'"
      and .failed[0].first_failure == "FAILED tests/test_network_guard.py::test_yfinance_offline - AssertionError: assert 0 == 1"
      and (.triage[0].web_url == .failed[0].web_url) and (.triage[0].first_failure == .failed[0].first_failure)' >/dev/null \
  && printf '%s\n' "$W18_BODY" | grep -xF -- '- step: build-sec-tools' >/dev/null \
  && ! printf '%s\n' "$W18_BODY" | grep -F -- 'step: n/a' >/dev/null \
  && printf '%s\n' "$W18_BODY" | grep -F -- "$JOB_URL" >/dev/null \
  && printf '%s\n' "$W18_BODY" | grep -F -- 'first failure:' >/dev/null \
  && printf '%s\n' "$W18_BODY" | grep -F -- 'FAILED tests/test_network_guard.py::test_yfinance_offline' >/dev/null \
  && ! printf '%s\n' "$W18_BODY" | grep -F -- 'FAILED tests/test_second.py' | grep -F 'first failure' >/dev/null \
  && printf '%s\n' "$W18_BODY" | awk '/first failure:/{ff=NR} /^Root cause/{rc=NR} END{exit !(ff && rc && ff < rc)}'; then
  pass "W18 (#22) unmatched fact -> step is the job name, note+JSON carry web_url, first_failure is the FIRST pytest FAILED line above the root cause"
else fail "W18" "rc=$(rc_of w18) out=$(out_of w18) body=$(printf '%s' "$W18_BODY" | head -c 1200)"; fi

# a matched fact keeps the fact's own step; a trace without `FAILED ` lines has no first failure
run_case w18b watch-failed-transient -- "${COMMON[@]}" --mr 7 --note --wait 0
W18B_BODY="$(body_of w18b 1 2>/dev/null | jq -r '.body.body' 2>/dev/null)"
if [ "$(rc_of w18b)" = 0 ] && [ -n "$W18B_BODY" ] \
  && out_of w18b | jq -e '.failed[0].classification.fact == "docker-hub-502" and .failed[0].first_failure == null
      and .failed[0].web_url == "'"$JOB_URL"'"' >/dev/null \
  && printf '%s\n' "$W18B_BODY" | grep -xF -- '- step: scan-image (scanner image pull from Docker Hub)' >/dev/null \
  && ! printf '%s\n' "$W18B_BODY" | grep -F -- 'first failure:' >/dev/null \
  && printf '%s\n' "$W18B_BODY" | grep -F -- "$JOB_URL" >/dev/null; then
  pass "W18b (#22) matched fact keeps its own step; no \`FAILED \` line -> no first-failure field, first_failure null, URL still present"
else fail "W18b" "rc=$(rc_of w18b) out=$(out_of w18b) body=$(printf '%s' "$W18B_BODY" | head -c 1200)"; fi

# the first FAILED line is untrusted: credentials in it are redacted in the JSON, note and stderr
run_case w19 watch-pytest-dirty -- "${COMMON[@]}" --mr 7 --note --wait 0
if [ "$(rc_of w19)" = 0 ] && out_of w19 | jq -e '(.failed[0].first_failure | contains("oauth2:<REDACTED>@")) and (.failed[0].first_failure | contains("glpat-") | not)' >/dev/null \
  && ! out_of w19 | grep -F 'glpat-fake' >/dev/null && ! out_of w19 | grep -F 'glpat-anotherFAKE' >/dev/null \
  && ! grep -rF 'glpat-' "$SCRATCH/w19/bodies" >/dev/null && ! err_of w19 | grep -F 'glpat-fake' >/dev/null \
  && body_of w19 1 | jq -e '.body.body | contains("oauth2:<REDACTED>@")' >/dev/null; then
  pass "W19 (#22) credentials inside the first FAILED line are redacted in the JSON, the note body and stderr"
else fail "W19" "rc=$(rc_of w19) out=$(out_of w19) body=$(body_of w19 1 2>/dev/null | head -c 900)"; fi

# a FAILED line with an absolute path and a backtick fence must not escape the fence or act as a quick action
run_case w20 watch-pytest-hostile -- "${COMMON[@]}" --mr 7 --note --wait 0
W20_BODY="$(body_of w20 1 2>/dev/null | jq -r '.body.body' 2>/dev/null)"
if [ "$(rc_of w20)" = 0 ] && [ "$(notes_posted w20)" = 1 ] && [ -n "$W20_BODY" ] \
  && out_of w20 | jq -e '.failed[0].first_failure == "FAILED /srv/build/tests/test_x.py::test_y - AssertionError: ``` /approve now"' >/dev/null \
  && printf '%s\n' "$W20_BODY" | grep -F -- 'first failure:' >/dev/null \
  && ! printf '%s\n' "$W20_BODY" | grep -E '^/' >/dev/null \
  && [ "$(printf '%s\n' "$W20_BODY" | grep -cE '^````$')" = 2 ] \
  && printf '%s\n' "$W20_BODY" | awk '/^````$/{n++; next} n==1 && /^\/|^```$/{bad=1} END{exit bad}'; then
  pass "W20 (#22) a FAILED line starting with a path and carrying \`\`\` stays inert: no line starts with /, the root-cause fence is still exactly two ```` lines"
else fail "W20" "rc=$(rc_of w20) body=$(printf '%s' "$W20_BODY" | head -c 1200)"; fi

# --- lint gate: no merge verb anywhere in the skills or the watcher ------------------
HITS="$(grep -rnE 'mr merge|/merge([^_a-zA-Z]|$)|protected_branches' "$ROOT/skills" "$ROOT/ops/watch.sh" 2>/dev/null)"
if [ -z "$HITS" ]; then pass "L1 no merge verb / merge endpoint / protected_branches in skills/ or ops/watch.sh"
else fail "L1" "$HITS"; fi
OPS_HITS="$(grep -rnE 'mr merge|/merge([^_a-zA-Z]|$)|protected_branches' "$ROOT/ops" | grep -v '^[^:]*token-check.sh:' || true)"
if [ -z "$OPS_HITS" ]; then pass "L2 the only ops/ mention of protected_branches is token-check.sh's informational read"
else fail "L2" "$OPS_HITS"; fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -x -P SCRIPTDIR "$ROOT/ops/watch.sh" >"$SCRATCH/shellcheck.log" 2>&1; then pass "L3 shellcheck clean: ops/watch.sh"
  else fail "L3" "$(cat "$SCRATCH/shellcheck.log")"; fi
fi

# --- U1 (v0.2): an overlay fact overlapping a core pattern wins, and the JSON names every facts file
mkdir -p "$SCRATCH/ov"
cat >"$SCRATCH/ov/hub.json" <<'EOF'
{"schema_version":"1","facts":[{"id":"overlay-hub-outage","pattern":"502 Bad Gateway","explanation":"overlay says: hub is down for the day","class":"permanent","retry_safe":false,"step":"scan-image","source":"overlay"}]}
EOF
run_case w30 watch-failed-transient SILKOPS_FACTS_OVERLAY="$SCRATCH/ov" -- "${COMMON[@]}" --mr 7 --wait 0
if [ "$(rc_of w30)" = 0 ] && out_of w30 | jq -e '.failed[0].classification.fact == "overlay-hub-outage"
      and .failed[0].classification.retry_safe == false
      and .failed[0].classification.facts_files == ["hub.json", "environment.json"]' >/dev/null \
  && [ "$(retries_of w30)" = 0 ]; then
  pass "W30 (U1) overlay fact wins over the core docker-hub-502 pattern; no retry; facts_files lists overlay then core"
else fail "W30" "rc=$(rc_of w30) out=$(out_of w30 | head -c 1500) err=$(err_of w30 | tail -3)"; fi

echo "test-watch: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
