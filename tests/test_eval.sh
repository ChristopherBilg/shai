#!/bin/bash
# test_eval.sh — unit tests for shai-eval
# Covers: shai-eval — payload build, error-event invariants, dry-run, health-check
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-eval"

# --- ported from tests/tests.sh:87-154: dry-run payload shape (no curl involved) ---
DRY=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval" --dry-run --tools)
assert_contains "$DRY" '"model":"claude-opus-4-8"' "eval: default model"
assert_contains "$DRY" '"max_tokens":16000' "eval: default max_tokens"
assert_contains "$DRY" '"gh_pr_view"' "eval: tools.json included with --tools"

NOTOOLS=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval" --dry-run)
assert_eq "$(printf '%s' "$NOTOOLS" | jq 'has("tools")')" "false" "eval: no tools without --tools"

NOSYS=$(echo '{"system":"","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval" --dry-run)
assert_eq "$(printf '%s' "$NOSYS" | jq 'has("system")')" "false" "eval: empty system omitted from payload"

WITHSYS=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval" --dry-run)
assert_eq "$(printf '%s' "$WITHSYS" | jq -r '.system')" "S" "eval: non-empty system included"

# --- stubbed 200 assistant event (curl-using tests start here) ---
make_stub_bin

printf '%s' '{"type":"message","content":[{"type":"text","text":"stub reply"}],"stop_reason":"end_turn"}' |
  write_curl_stub 200
EV=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval")
assert_contains "$EV" '"source":"assistant"' "eval: assistant event (stubbed curl)"
assert_contains "$EV" '"stop_reason":"end_turn"' "eval: stop_reason parsed"
assert_contains "$EV" 'stub reply' "eval: content passed through"

env -u ANTHROPIC_API_KEY "$DIR/shai-eval" --health-check 2>/dev/null
assert_eq "$?" "1" "eval: health-check fails without key"

"$DIR/shai-eval" --health-check
assert_eq "$?" "0" "eval: health-check ok with key"

# --- error-path coverage: reuse the stub curl with different bodies/codes ---
printf '%s' '{"type":"error","error":{"message":"overloaded"}}' | write_curl_stub 529
EVERR=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval")
assert_contains "$EVERR" '"type":"error"' "eval: non-200 JSON body → error event"
assert_contains "$EVERR" 'overloaded' "eval: error message extracted"

printf '%s' '<html>502 Bad Gateway</html>' | write_curl_stub 502
EVHTML=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval")
assert_contains "$EVHTML" '"type":"error"' "eval: non-200 non-JSON body → error event (no crash)"
assert_contains "$EVHTML" 'HTTP 502' "eval: non-JSON error falls back to HTTP code"

printf '%s' '{"type":"error","error":{"message":"bad-200-body"}}' | write_curl_stub 200
EV200=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval")
assert_contains "$EV200" '"type":"error"' "eval: 200 body with type=error → error event"

printf '%s' 'totally not json' | write_curl_stub 200
EV200BAD=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval")
assert_contains "$EV200BAD" '"type":"error"' "eval: 200 non-JSON body → error event (no crash)"

printf '%s' '{"foo":"bar"}' | write_curl_stub 200
EV200SHAPE=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval")
assert_contains "$EV200SHAPE" '"type":"error"' "eval: 200 unexpected shape → error event (not fake success)"

# new: --model / --max-tokens overrides land in the payload
DRYOVR=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' |
  "$DIR/shai-eval" --dry-run --model claude-haiku-test --max-tokens 42)
assert_contains "$DRYOVR" '"model":"claude-haiku-test"' "eval: --model override in payload"
assert_contains "$DRYOVR" '"max_tokens":42' "eval: --max-tokens override in payload"

# new: unknown option → exit 2
assert_exit 2 "eval: unknown option exits 2" -- "$DIR/shai-eval" --bogus

# new: value-taking options validate their argument (controlled exit 2, not a set -u/jq crash)
MODELERR=$("$DIR/shai-eval" --model </dev/null 2>&1)
RC=$?
assert_eq "$RC" "2" "eval: --model without value exits 2"
assert_contains "$MODELERR" "--model requires a value" "eval: --model without value → clear message"

MTNOVAL=$("$DIR/shai-eval" --max-tokens </dev/null 2>&1)
RC=$?
assert_eq "$RC" "2" "eval: --max-tokens without value exits 2"
assert_contains "$MTNOVAL" "--max-tokens requires a value" "eval: --max-tokens without value → clear message"

MTBAD=$(echo '{"messages":[]}' | "$DIR/shai-eval" --dry-run --max-tokens abc 2>&1)
RC=$?
assert_eq "$RC" "2" "eval: --max-tokens non-integer exits 2"
assert_contains "$MTBAD" "--max-tokens must be a positive integer" "eval: --max-tokens non-integer → clear message"

# new: empty stdin → exit 0, no output
EEMPTY=$(printf '' | "$DIR/shai-eval")
RC=$?
assert_eq "$EEMPTY" "" "eval: empty stdin → no output"
assert_eq "$RC" "0" "eval: empty stdin → exit 0"

# new: curl hard-failure (non-zero exit) → error event, loop-safe
make_stub_bin
printf '#!/bin/bash\ncat > /dev/null\nexit 7\n' >"$STUB/curl"
chmod +x "$STUB/curl"
EVCURLFAIL=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval")
assert_contains "$EVCURLFAIL" '"type":"error"' "eval: curl hard-failure → error event"
assert_contains "$EVCURLFAIL" 'request failed (curl)' "eval: curl-failure message"

finish
