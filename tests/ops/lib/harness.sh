#!/usr/bin/env bash
# Shared prologue for the Tier 1 suites: counters, scratch cleanup, glab-stub-first PATH,
# run_case and its accessors. Sourced after ROOT and STUB_DIR are set; SCRIPT and SCRATCH are
# set by the suite afterwards (functions resolve them at call time).
PASS=0; FAIL=0
# shellcheck disable=SC2034  # read by the sourcing suite
PROJECT="void-realm-solutions/silkops-harness-eval"
# the marker carries the plugin version; expected strings splice it in as '"$PLUGIN_V"'
PLUGIN_V="$(jq -r .version "$ROOT/.claude-plugin/plugin.json")"
pass() { echo "PASS $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL $1: $2"; FAIL=$((FAIL + 1)); }
# shellcheck disable=SC2329  # invoked via the EXIT trap
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
export PATH="$STUB_DIR:$PATH"
[ "$(command -v glab)" = "$STUB_DIR/glab" ] || { echo "glab stub is not first on PATH" >&2; exit 1; }
# run_case <name> <scenario> <env KEY=VAL ...> -- <args...>   (scenario: stub dir name or absolute path)
run_case() {
  local name="$1" scenario="$2"; shift 2
  case "$scenario" in /*) ;; *) scenario="$STUB_DIR/$scenario" ;; esac
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  local d="$SCRATCH/$name"; mkdir -p "$d"
  env -u GITLAB_TOKEN -u SILKOPS_SETTINGS_TOKEN -u SILKOPS_CI_TOKEN -u CI -u SILKOPS_VAR_VALUE \
    GLAB_STUB_SCENARIO="$scenario" GLAB_STUB_LOG="$d/glab.log" GLAB_STUB_BODY_DIR="$d/bodies" \
    CURL_STUB_STATE="$d/state" CURL_STUB_LOG="$d/curl.log" "${envs[@]}" \
    bash "$SCRIPT" "$@" >"$d/out.log" 2>"$d/err.log"
  echo $? >"$d/rc"
}
rc_of()  { cat "$SCRATCH/$1/rc"; }
out_of() { cat "$SCRATCH/$1/out.log"; }
err_of() { cat "$SCRATCH/$1/err.log"; }
log_of() { cat "$SCRATCH/$1/glab.log" 2>/dev/null; }
calls_of() { log_of "$1" | wc -l | tr -d ' '; }
writes_of() { log_of "$1" | grep -cE -- '-X (POST|PUT|DELETE)'; }
body_of() { cat "$SCRATCH/$1/bodies/$2.json"; }
