#!/bin/bash
# Shared test helpers + offline stubs. Sourced by tests/test_*.sh.
# No `set -e`: assertions must keep running after a failure.
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh" from a test_*.sh
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck disable=SC2034  # DIR is consumed by the test_*.sh files that source this lib
DIR="$(cd "$LIB_DIR/.." &>/dev/null && pwd)" # repo root; tests invoke "$DIR/shai-*"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
FAILED=0

assert_eq() {
  if [ "$1" = "$2" ]; then
    echo -e "  ${GREEN}✓${NC} $3"
  else
    echo -e "  ${RED}✗${NC} $3 (got '$1', want '$2')"
    FAILED=1
  fi
}

assert_contains() {
  if [[ "$1" == *"$2"* ]]; then
    echo -e "  ${GREEN}✓${NC} $3"
  else
    echo -e "  ${RED}✗${NC} $3"
    echo "    expected substring: $2"
    echo "    got: $1"
    FAILED=1
  fi
}

assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then
    echo -e "  ${GREEN}✓${NC} $3"
  else
    echo -e "  ${RED}✗${NC} $3"
    echo "    unexpected substring: $2"
    echo "    got: $1"
    FAILED=1
  fi
}

# assert_exit <expected_code> <description> -- <command...>
assert_exit() {
  local expected="$1" desc="$2"
  shift 2
  [ "${1:-}" = "--" ] && shift
  "$@" >/dev/null 2>&1
  assert_eq "$?" "$expected" "$desc"
}

# assert_fails <expected_code> <stderr_fragment> <description> -- <command...>: assert the
# exit code AND that stderr contains the fragment as a literal string, not a glob pattern
# (stderr captured, stdout dropped).
assert_fails() {
  local expected="$1" frag="$2" desc="$3"
  shift 3
  [ "${1:-}" = "--" ] && shift
  if [ -z "$frag" ]; then
    echo -e "  ${RED}✗${NC} $desc (usage error: empty stderr fragment)"
    FAILED=1
    return 1
  fi
  local err rc
  err=$("$@" 2>&1 >/dev/null) # capture stderr only: dup before the stdout redirect
  rc=$?
  assert_eq "$rc" "$expected" "$desc (exit)"
  assert_contains "$err" "$frag" "$desc (stderr)"
}

# assert_fails_exact <expected_code> <expected_stderr> <description> -- <command...>: like
# assert_fails, but the captured stderr must EQUAL <expected_stderr> (trailing newlines
# stripped by the command substitution), not merely contain it — an extra or duplicated
# stderr line goes red. For single-line error contracts whose exact text is part of the
# API (#386's verdict→message mapping): a contains-match cannot see a reword or an arm swap
# that also emits a stray line.
assert_fails_exact() {
  local expected="$1" want="$2" desc="$3"
  shift 3
  [ "${1:-}" = "--" ] && shift
  if [ -z "$want" ]; then
    echo -e "  ${RED}✗${NC} $desc (usage error: empty expected stderr)"
    FAILED=1
    return 1
  fi
  local err rc
  err=$("$@" 2>&1 >/dev/null) # capture stderr only: dup before the stdout redirect
  rc=$?
  assert_eq "$rc" "$expected" "$desc (exit)"
  assert_eq "$err" "$want" "$desc (stderr)"
}

# assert_row_count <output> <expected> <description>: assert the table in <output> has exactly
# <expected> data rows, excluding the header line. Blank output (empty or whitespace-only)
# counts as 0 rows.
assert_row_count() {
  local out="$1" expected="$2" desc="$3"
  local n
  n=$(printf '%s\n' "$out" | grep -c .)
  [ "$n" -gt 0 ] && n=$((n - 1)) # drop the header line
  assert_eq "$n" "$expected" "$desc"
}

_CLEANUP_DIRS=()
_cleanup() {
  local d
  for d in "${_CLEANUP_DIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
}
trap _cleanup EXIT

# make_stub_bin: temp dir prepended to PATH, auto-cleaned. Sets $STUB.
make_stub_bin() {
  STUB="$(mktemp -d)"
  _CLEANUP_DIRS+=("$STUB")
  export PATH="$STUB:$PATH"
}

# build_fake_tarball <work_dir> <version>: a fake release tarball at
# <work_dir>/shai-<version>.tar.gz containing a minimal executable shai tree —
# shai-repl, shai-doctor, shai-version, shai-supervise + lib/units.sh, a REPO file next
# to VERSION (as release.yml bakes it), and the real shai-completions with a per-version
# marker flag injected into completions.json.
# Shared by tests/test_install.sh and tests/test_update.sh so the installer and the
# updater are driven from one fixture (which is also what makes the layout-equivalence
# test practical). The marker flag makes the generated completion content
# version-specific, so tests can assert the reinstall after an upgrade/rollback came
# from the target version's tree.
build_fake_tarball() {
  local work="$1" version="${2:-v2026.01.01}"
  local staging="$work/shai-${version}"
  rm -rf "$staging"
  mkdir -p "$staging" "$staging/lib"
  printf '#!/bin/bash\necho hello\n' >"$staging/shai-repl"
  chmod +x "$staging/shai-repl"
  printf '#!/bin/bash\necho doctor\n' >"$staging/shai-doctor"
  chmod +x "$staging/shai-doctor"
  echo "$version" >"$staging/VERSION"
  # REPO is what wf_suggest_repo reads on a release install; release.yml bakes it next to
  # VERSION from github.repository. The fixture models that layout so the install/update
  # suites exercise extraction of the file real releases carry, not a pre-PR layout.
  echo "Fixture/ReleaseRepo" >"$staging/REPO"
  echo "not executable" >"$staging/README.md"
  printf '{"_comment":"example ci config","version":"1.0","repos":{}}\n' >"$staging/ci.json.example"
  cp "$DIR/shai-version" "$staging/shai-version"
  cp "$DIR/shai-supervise" "$staging/shai-supervise"
  cp "$DIR/lib/units.sh" "$staging/lib/units.sh"
  # The real completion installer + manifest: install.sh runs both installs best-effort,
  # shai-update runs them on the critical path, and the suites assert on the generated
  # files at the standard XDG locations.
  cp "$DIR/shai-completions" "$staging/shai-completions"
  jq --arg v "$version" \
    '.scripts["shai-fixture-marker"] = {
       "description": "fixture release marker",
       "flags": {("--marker-" + $v): {"description": ("fixture release " + $v)}}
     }' "$DIR/completions.json" >"$staging/completions.json"
  (cd "$work" && tar czf "shai-${version}.tar.gz" "shai-${version}")
}

# suggest_repo_of <install_dir>: the OWNER/REPO wf_suggest_repo resolves for an install
# tree. Uses a function-local DIR — bash's dynamic scoping hands it to wf_suggest_repo —
# so the suite's own DIR (the repo root) is untouched. Requires lib/workflow.sh to have
# been sourced first.
suggest_repo_of() {
  # shellcheck disable=SC2034  # DIR is read by wf_suggest_repo through dynamic scoping
  local DIR="$1"
  unset SHAI_SUGGEST_REPO
  wf_suggest_repo
}

# make_install_gh_stub <work_dir> <version>: gh stub handling auth, release download
# (parsing --dir), and release view (returning the tag) — exactly the three calls
# install.sh and shai-update make.
make_install_gh_stub() {
  local work="$1" version="${2:-v2026.01.01}"
  mkdir -p "$work/bin"
  cat >"$work/bin/gh" <<STUB
#!/bin/bash
if [ "\$1" = "auth" ]; then exit 0; fi
if [ "\$1" = "release" ] && [ "\$2" = "download" ]; then
  dir=""
  prev=""
  for i in "\$@"; do
    if [ "\$prev" = "--dir" ]; then dir="\$i"; break; fi
    prev="\$i"
  done
  cp "$work/shai-${version}.tar.gz" "\$dir/"
  exit 0
fi
if [ "\$1" = "release" ] && [ "\$2" = "view" ]; then
  printf '%s\n' "${version}"
  exit 0
fi
exit 1
STUB
  chmod +x "$work/bin/gh"
}

# write_curl_stub <http_code> -- response body read from stdin.
# Emits body then the code line, mimicking shai-eval's `-w '\n%{http_code}'`.
write_curl_stub() {
  local code="$1"
  cat >"$STUB/.curl_body"
  {
    printf '#!/bin/bash\n'
    printf 'cat > /dev/null\n' # drain -d @- so the producer never SIGPIPEs
    printf 'cat "%s/.curl_body"\n' "$STUB"
    printf 'printf "\\n"\n'
    printf 'echo "%s"\n' "$code"
  } >"$STUB/curl"
  chmod +x "$STUB/curl"
}

# write_gh_stub: gh that echoes a recognizable line including its args.
write_gh_stub() {
  {
    printf '#!/bin/bash\n'
    printf 'echo "stub gh output for: $*"\n'
  } >"$STUB/gh"
  chmod +x "$STUB/gh"
}

# write_git_stub: git that echoes a recognizable line including its args.
write_git_stub() {
  {
    printf '#!/bin/bash\n'
    printf 'echo "stub git output for: $*"\n'
  } >"$STUB/git"
  chmod +x "$STUB/git"
}

# write_jira_stub: jira that echoes a recognizable line including its args.
write_jira_stub() {
  {
    printf '#!/bin/bash\n'
    printf 'echo "stub jira output for: $*"\n'
  } >"$STUB/jira"
  chmod +x "$STUB/jira"
}

# write_roundtrip_curl_stub <dir>: stateful curl stub for a full tool round-trip.
# First call returns a list_directory tool call, second returns a stop/text reply.
# Exports SHAI_ROUND_COUNT (the counter file); callers unset it when done.
write_roundtrip_curl_stub() {
  export SHAI_ROUND_COUNT="$1/count"
  echo 0 >"$SHAI_ROUND_COUNT"
  cat >"$1/curl" <<'STUBEOF'
#!/bin/bash
cat > /dev/null
n=$(cat "$SHAI_ROUND_COUNT"); echo $((n + 1)) > "$SHAI_ROUND_COUNT"
if [ "$n" = "0" ]; then
  cat <<'JSON'
{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"tu1","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\".\"}"}}]},"finish_reason":"tool_calls"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
JSON
else
  cat <<'JSON'
{"id":"chatcmpl-test2","choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
JSON
fi
echo "200"
STUBEOF
  chmod +x "$1/curl"
}

# finish: print summary and exit non-zero if any assertion failed.
finish() {
  if [ "$FAILED" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC}"; else echo -e "  ${RED}FAIL${NC}"; fi
  exit "$FAILED"
}

# desc: print a one-line label ahead of a group of related assertions (readability only).
desc() { printf '%s\n' "$1"; }

# Create a stamped fixture event for observability filter tests
# Usage: fixture_event <type> <source> <payload_json> [run_id] [session_id] [span_id] [api_json] [timestamp]
fixture_event() {
  local type="$1" source="$2" payload="$3"
  local run_id="${4:-run_test}" session_id="${5:-sess_test}" span_id="${6:-span_1}"
  local api="${7:-null}" ts="${8:-2026-08-11T12:00:00Z}"
  jq -nc \
    --arg t "$type" --arg s "$source" --argjson p "$payload" \
    --arg rid "$run_id" --arg sid "$session_id" --arg spid "$span_id" \
    --argjson api "$api" --arg ts "$ts" \
    '{type:$t, source:$s, payload:$p, version:"1.0",
      meta:{run_id:$rid, session_id:$sid, span_id:$spid, parent_span_id:null, timestamp:$ts}}
     + (if $api == null then {} else {api:$api} end)'
}

# Store builders — composed from fixture_event, not parallel implementations of it. Each
# one writes the on-disk shape a healthy $SHAI_HOME store has, so shai-fsck check tests
# read as "take a healthy store, break exactly this in the open, assert exactly this
# finding." Builders never stage corruption themselves: a corruption the caller wants to
# test is applied after the builder runs, with plain shell.

# fixture_mint_id <prefix>: a real-shaped <prefix>_YYYYMMDDTHHMMSS_<8 hex chars> id, the
# same shape lib/workflow.sh's mint_id produces. Real shapes matter to the consumers of
# ids, not just to humans: shai-sessions/shai-events/shai-runs parse the embedded date
# for --after/--before filename-level filtering, and shai-fsck's X1 matches store entries
# against this pattern. Prints the id.
fixture_mint_id() {
  printf '%s_%s_%s' "$1" "$(date -u +%Y%m%dT%H%M%S)" "$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
}

# fixture_session [session_id] [event...]: build a healthy session store from the given
# stamped events (compact JSON lines, as produced by fixture_event). The events are
# written one per line to $SHAI_HOME/sessions/<session_id>.jsonl, with each event's
# meta.session_id rewritten to the session id — so the store satisfies fsck S3 by
# construction even when the events were stamped with placeholder ids, and the issue's
# flagship one-liner `fixture_session sess_a "$(fixture_event ...)"` yields a healthy
# session rather than a subtly broken one. The last event is mirrored verbatim to
# $SHAI_HOME/sessions/<session_id>.latest.json, so .latest.json is always JSON-equal to
# the log's tail — exactly fsck S5's predicate. Other envelope fields (meta.run_id,
# span ids) are left as stamped: stage an S3 violation, or any other corruption, by
# mutating the log in the open after the builder runs. An omitted session_id is minted
# in the real sess_<ts>_<hex> shape. With no events both files are created empty — not
# the pair wf_init leaves (one system-prompt event plus an empty .latest.json, the
# stillborn pair #388 describes); pass at least one event for the healthy-by-default
# guarantee. Prints the resolved session_id.
fixture_session() {
  local session_id="${1:-}" events=("${@:2}") dir log latest last="" ev
  [ -n "$session_id" ] || session_id="$(fixture_mint_id sess)"
  dir="$SHAI_HOME/sessions"
  log="$dir/$session_id.jsonl"
  latest="$dir/$session_id.latest.json"
  mkdir -p "$dir"
  : >"$log"
  : >"$latest"
  for ev in "${events[@]+"${events[@]}"}"; do
    last="$(printf '%s\n' "$ev" | jq -c --arg sid "$session_id" '.meta.session_id = $sid')" || return 1
    printf '%s\n' "$last" >>"$log"
  done
  if [ -n "$last" ]; then
    printf '%s\n' "$last" >"$latest"
  fi
  printf '%s\n' "$session_id"
}

# fixture_run [run_id] [session_id] [event...]: build $SHAI_HOME/runs/<run_id>/events.jsonl
# from the given stamped events, one per line, with each event's meta.run_id rewritten to
# the run id and meta.session_id to the session id — fsck R2 (run_id equals the directory
# name) holds by construction, and the session_id declares which session the run's events
# belong to (fsck R6 checks that they appear in some session log; build that log with
# fixture_session and the same events). Span ids are left as stamped, since span structure
# is the caller's to set. Both ids default to minted real-shaped values (run_<ts>_<hex> /
# sess_<ts>_<hex>); with no events the log is created empty, mirroring the touch-if-missing
# idiom shai-loop uses. Prints the resolved run_id.
fixture_run() {
  local run_id="${1:-}" session_id="${2:-}" events=("${@:3}") dir log ev
  [ -n "$run_id" ] || run_id="$(fixture_mint_id run)"
  [ -n "$session_id" ] || session_id="$(fixture_mint_id sess)"
  dir="$SHAI_HOME/runs/$run_id"
  log="$dir/events.jsonl"
  mkdir -p "$dir"
  : >"$log"
  for ev in "${events[@]+"${events[@]}"}"; do
    printf '%s\n' "$ev" | jq -c --arg rid "$run_id" --arg sid "$session_id" \
      '.meta.run_id = $rid | .meta.session_id = $sid' >>"$log" || return 1
  done
  printf '%s\n' "$run_id"
}

# fixture_span_dump <run_id> <span_id> request|response [json]: write one API dump to
# $SHAI_HOME/runs/<run_id>/<span_id>-request.json (or -response.json), creating the run
# directory if needed. The json argument is written verbatim — a deliberately malformed
# value survives, so it can stage an fsck R4 corruption — and defaults to a minimal
# well-formed dump of the matching kind when omitted (the shapes shai-eval writes). The
# kind must be exactly `request` or `response` (anything else is a usage error on stderr,
# exit 1): a typo would otherwise create a third filename shape fsck's R4/R5 never look
# at. A dump only belongs to a healthy run when the run log holds an event for the same
# span (fsck R5); pair each dump with a span event built via fixture_run.
fixture_span_dump() {
  local run_id="${1:-}" span_id="${2:-}" kind="${3:-}" json="${4:-}"
  local dir file default=""
  case "$kind" in
    request)
      default='{"model":"test-model","messages":[]}'
      ;;
    response)
      default='{"message_id":"m1","model":"test-model","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},"finish_reason":"stop","latency_ms":100}'
      ;;
    *)
      printf 'fixture_span_dump: kind must be request or response (got "%s")\n' "$kind" >&2
      return 1
      ;;
  esac
  if [ -z "$run_id" ] || [ -z "$span_id" ]; then
    printf 'fixture_span_dump: run_id and span_id must be non-empty\n' >&2
    return 1
  fi
  dir="$SHAI_HOME/runs/$run_id"
  file="$dir/$span_id-$kind.json"
  mkdir -p "$dir"
  printf '%s\n' "${json:-$default}" >"$file"
}

# fixture_ledger <workflow> <key>...: build a healthy ledger at
# $SHAI_HOME/ledgers/<workflow>.jsonl with one well-formed {key, ts, session_id} entry per
# key argument, each ts the current time in the ISO shape wf_mark writes. Entries
# reference one freshly minted real-shaped session, and the builder creates that session
# (a one-event message/user session with a matching .latest.json, via fixture_session) so
# the ledger is clean under fsck L3 (session_id resolves) as well as L1/L2 — a ledger
# naming a nonexistent session is exactly the state L3 reports, and a test stages it by
# deleting the backing session. Use a workflow name that exists under workflows/ to also
# keep L4 quiet. Prints the backing session id. Keys are written in argument order, as
# given: pass the same key twice to stage an L2 duplicate. The file is truncated on each
# call — build-from-scratch, like fixture_session/fixture_run, because every key arrives
# in this one call; fixture_failure appends instead because its signature carries one
# record per call.
fixture_ledger() {
  local workflow="${1:-}" keys=("${@:2}") sid dir file key session_event
  if [ -z "$workflow" ]; then
    printf 'fixture_ledger: workflow name must be non-empty\n' >&2
    return 1
  fi
  session_event="$(fixture_event message user '{"text":"ledger fixture session"}')"
  # The backing session is synthetic: null its meta.run_id so fsck R7 (a session
  # event's meta.run_id must have a run directory on disk) stays quiet by
  # construction, exactly as fixture_session's session_id rewrite keeps S3 quiet.
  session_event="$(printf '%s' "$session_event" | jq -c '.meta.run_id = null')"
  sid="$(fixture_session "" "$session_event")"
  dir="$SHAI_HOME/ledgers"
  file="$dir/$workflow.jsonl"
  mkdir -p "$dir"
  : >"$file"
  for key in "${keys[@]+"${keys[@]}"}"; do
    jq -nc --arg k "$key" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "$sid" \
      '{key: $k, ts: $ts, session_id: $sid}' >>"$file"
  done
  printf '%s\n' "$sid"
}

# fixture_failure <workflow> <category> <summary>: append one failure record to
# $SHAI_HOME/failures/<workflow>.jsonl carrying all seven documented keys — ts (now, the
# ISO shape fail_record writes), workflow, run_id, session_id, category, summary, context —
# with run_id/session_id null and context {} exactly as fail_record produces when no
# ambient trace context exists (the state fsck F4 skips, not flags). One record per call,
# appending, so several calls build one workflow's log; a truncating builder would
# silently drop the record a previous call wrote. category is written as given — pass one
# of the five documented categories for a healthy record; an unknown one is the corruption
# an F2 test stages.
fixture_failure() {
  local workflow="${1:-}" category="${2:-}" summary="${3:-}"
  local dir file
  if [ -z "$workflow" ]; then
    printf 'fixture_failure: workflow name must be non-empty\n' >&2
    return 1
  fi
  dir="$SHAI_HOME/failures"
  file="$dir/$workflow.jsonl"
  mkdir -p "$dir"
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg workflow "$workflow" --arg category "$category" --arg summary "$summary" \
    '{ts:$ts, workflow:$workflow, run_id:null, session_id:null, category:$category,
      summary:$summary, context:{}}' >>"$file"
}

export SHAI_API_KEY="test-key"
# .invalid is reserved by RFC 2606 and can never resolve, so a stub-bypass bug surfaces as a
# DNS failure rather than a real request to somebody's endpoint.
export SHAI_API_URL="https://api.test.invalid/v1/chat/completions"
export SHAI_MODEL="test-model"

# Suites must not inherit the caller's shai environment: a workflow exports
# SHAI_POLICY_OVERLAY, and an inherited overlay supersedes fixture deny rules
# (check_policy in shai-dispatch consults the overlay before the base policy), so a
# leaked overlay flips permission-gate deny assertions to allow. Neutralize the
# shai inputs that can affect assertions centrally and give each suite a fresh
# SHAI_HOME; the remaining inheritable shai inputs (e.g. SHAI_SESSION_ID,
# SHAI_WORKFLOW) are pinned per call by the suites that use them.
# XDG_DATA_HOME is not a shai input, but it belongs in the same class: it
# redirects the completion install target (shai-completions resolves
# ${XDG_DATA_HOME:-$HOME/.local/share}), so an inherited value overrides a
# fixture HOME and makes a suite write to the caller's real data directory.
# Unset it here (rather than pinning it) so suites that test the
# $HOME/.local/share fallback keep that path under test, and suites that need a
# fixture value (test_doctor.sh) or pass one per command (test_completions.sh)
# set it themselves after sourcing this file.
unset SHAI_POLICY_OVERLAY SHAI_RETRY_ACTIVE SHAI_TOOLS_DIR SHAI_SPAN_ID SHAI_RUN_ID SHAI_MAX_CONTEXT_BYTES
unset XDG_DATA_HOME
export SHAI_HOME
SHAI_HOME=$(mktemp -d)
_CLEANUP_DIRS+=("$SHAI_HOME")
