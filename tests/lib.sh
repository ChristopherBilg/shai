#!/bin/bash
# Shared test helpers + offline stubs. Sourced by tests/test_*.sh.
# No `set -e`: assertions must keep running after a failure.
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

# finish: print summary and exit non-zero if any assertion failed.
finish() {
  if [ "$FAILED" -eq 0 ]; then echo -e "  ${GREEN}PASS${NC}"; else echo -e "  ${RED}FAIL${NC}"; fi
  exit "$FAILED"
}

export ANTHROPIC_API_KEY="test-key"
