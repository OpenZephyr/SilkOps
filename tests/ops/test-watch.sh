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

# --- usage / resolution ---------------------------------------------------------
run_case w2 watch-green -- --mr 7
if [ "$(rc_of w2)" = 2 ] && err_of w2 | grep -- '--project' >/dev/null && [ "$(calls_of w2)" = 0 ]; then
  pass "W2 missing --project exits 2 before any glab call"
else fail "W2" "rc=$(rc_of w2) calls=$(calls_of w2)"; fi

run_case w2b watch-green -- "${COMMON[@]}" --mr 7 --pipeline 501
if [ "$(rc_of w2b)" = 2 ] && [ "$(calls_of w2b)" = 0 ]; then pass "W2b --mr and --pipeline together exits 2"; else fail "W2b" "rc=$(rc_of w2b)"; fi

run_case w3 watch-no-pipeline -- "${COMMON[@]}" --mr 7
if [ "$(rc_of w3)" = 5 ] && out_of w3 | jq -e '.ok == false and .error == "no_head_pipeline"' >/dev/null; then
  pass "W3 MR without a head pipeline exits 5"
else fail "W3" "rc=$(rc_of w3) out=$(out_of w3)"; fi

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
      and .polls == 3 and .waited_s == 40 and .resume_hint == "watch.sh --project void-realm-solutions/silkops-harness-eval --pipeline 501"' >/dev/null \
  && [ "$(writes_of w8)" = 0 ]; then
  pass "W8 running past the wait budget -> still_running:true, resume hint by pipeline id, exit 0"
else fail "W8" "rc=$(rc_of w8) out=$(out_of w8)"; fi

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

echo "test-watch: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
