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
# shai-repl, shai-doctor, shai-version, shai-supervise + lib/units.sh, and the real
# shai-completions with a per-version marker flag injected into completions.json.
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

# The three required provider variables. DEEPSEEK_API_KEY stays exported until the last task
# of this migration: shai-supervise and tools/ci still read it, and dropping it early would
# turn a staged rename into 30 simultaneously red suites.
export DEEPSEEK_API_KEY="test-key"
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
