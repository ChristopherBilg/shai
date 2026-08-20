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

# assert_exit <expected_code> <description> -- <command...>
assert_exit() {
  local expected="$1" desc="$2"
  shift 2
  [ "${1:-}" = "--" ] && shift
  "$@" >/dev/null 2>&1
  assert_eq "$?" "$expected" "$desc"
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
{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"tu1","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\".\"}"}}]},"finish_reason":"tool_calls"}],"model":"deepseek-v4-pro","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
JSON
else
  cat <<'JSON'
{"id":"chatcmpl-test2","choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}],"model":"deepseek-v4-pro","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
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

export DEEPSEEK_API_KEY="test-key"
