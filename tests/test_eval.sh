#!/bin/bash
# test_eval.sh — unit tests for shai-eval
# Covers: shai-eval — payload build, error-event invariants, dry-run, health-check, retry state machine (stderr progress lines), arg guards
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-eval"

DEFAULT_MODEL=$(sed -n 's/^MODEL="${SHAI_MODEL:-\(.*\)}"/\1/p' "$DIR/shai-eval")
DEFAULT_MAX_TOKENS=$(sed -n 's/^MAX_TOKENS="${SHAI_MAX_TOKENS:-\(.*\)}"/\1/p' "$DIR/shai-eval")
DEFAULT_EVAL_TIMEOUT=$(sed -n 's/^EVAL_TIMEOUT="${SHAI_EVAL_TIMEOUT:-\(.*\)}"/\1/p' "$DIR/shai-eval")
[ -n "$DEFAULT_MODEL" ] || {
  echo "FATAL: could not extract DEFAULT_MODEL from shai-eval" >&2
  exit 1
}
[ -n "$DEFAULT_MAX_TOKENS" ] || {
  echo "FATAL: could not extract DEFAULT_MAX_TOKENS from shai-eval" >&2
  exit 1
}
[ -n "$DEFAULT_EVAL_TIMEOUT" ] || {
  echo "FATAL: could not extract DEFAULT_EVAL_TIMEOUT from shai-eval" >&2
  exit 1
}

# isolate SHAI_HOME so the always-on request dump never writes to a real ~/.shai
SHAI_HOME_TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_HOME_TMP")
export SHAI_HOME="$SHAI_HOME_TMP"

# --- ported from tests/tests.sh:87-154: dry-run payload shape (no curl involved) ---
TOOLS_TMP=$(mktemp)
_CLEANUP_DIRS+=("$TOOLS_TMP")
"$DIR/shai-tools" >"$TOOLS_TMP"
DRY=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | env -u SHAI_MODEL "$DIR/shai-eval" --dry-run --tools-file "$TOOLS_TMP")
assert_contains "$DRY" "\"model\":\"$DEFAULT_MODEL\"" "eval: default model"
assert_contains "$DRY" "\"max_tokens\":$DEFAULT_MAX_TOKENS" "eval: default max_tokens"
assert_contains "$DRY" '"gh"' "eval: tools included with --tools-file"
assert_contains "$DRY" '"thinking":{"type":"enabled"}' "eval: thinking enabled in payload"
assert_contains "$DRY" '"reasoning_effort":"max"' "eval: reasoning_effort max in payload"

NOTOOLS=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval" --dry-run)
assert_eq "$(printf '%s' "$NOTOOLS" | jq 'has("tools")')" "false" "eval: no tools without --tools-file"

# --- stubbed 200 assistant event (curl-using tests start here) ---
make_stub_bin

write_curl_stub 200 <<'STUB'
{"id":"msg_test123","choices":[{"message":{"role":"assistant","content":"stub reply"},"finish_reason":"stop"}],"model":"test-model-20260801","usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150}}
STUB
EV=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval" 2>"$STUB/.eval_stderr")
assert_contains "$EV" '"source":"assistant"' "eval: assistant event (stubbed curl)"
assert_contains "$EV" '"finish_reason":"stop"' "eval: finish_reason parsed"
assert_contains "$EV" 'stub reply' "eval: content passed through"
# absence assertion, mutation-checked (#356): emitting a progress printf on the
# 200-success path makes this red — a first-attempt success must be silent on stderr.
# Byte-exact via wc -c: "$(cat ...)" command substitution strips trailing newlines,
# so a newline-only stderr emission would falsely compare equal to "".
assert_eq "$(wc -c <"$STUB/.eval_stderr")" "0" "eval: first-attempt success emits no retry progress on stderr"

env -u DEEPSEEK_API_KEY "$DIR/shai-eval" --health-check 2>/dev/null
assert_eq "$?" "1" "eval: health-check fails without key"

"$DIR/shai-eval" --health-check
assert_eq "$?" "0" "eval: health-check ok with key"

# --- error-path coverage: reuse the stub curl with different bodies/codes ---
printf '%s' '{"error":{"message":"overloaded"}}' | write_curl_stub 529
EVERR=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | SHAI_EVAL_RETRIES=0 "$DIR/shai-eval")
assert_contains "$EVERR" '"type":"error"' "eval: non-200 JSON body → error event"
assert_contains "$EVERR" 'overloaded' "eval: error message extracted"

printf '%s' '<html>502 Bad Gateway</html>' | write_curl_stub 502
EVHTML=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | SHAI_EVAL_RETRIES=0 "$DIR/shai-eval")
assert_contains "$EVHTML" '"type":"error"' "eval: non-200 non-JSON body → error event (no crash)"
assert_contains "$EVHTML" 'HTTP 502' "eval: non-JSON error falls back to HTTP code"

printf '%s' '{"error":{"message":"bad-200-body"}}' | write_curl_stub 200
EV200=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval")
assert_contains "$EV200" '"type":"error"' "eval: 200 body with error → error event"

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

# new: --tools-file with no value → controlled exit 2. Last of shai-eval's "requires a
# value" guards without a test; matters because shai-loop forwards --tools-file through,
# so a rejected forwarded value must fail cleanly rather than crash the pipeline.
TFNOVAL=$("$DIR/shai-eval" --tools-file </dev/null 2>&1)
RC=$?
assert_eq "$RC" "2" "eval: --tools-file without value exits 2"
assert_contains "$TFNOVAL" "error: --tools-file requires a path" "eval: --tools-file without value → clear message"

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

# --- SHAI_MAX_TOKENS env var (#271) ---
DRYENV=$(echo '{"messages":[{"role":"user","content":"hi"}]}' |
  SHAI_MAX_TOKENS=64000 "$DIR/shai-eval" --dry-run)
assert_contains "$DRYENV" '"max_tokens":64000' "eval: SHAI_MAX_TOKENS env var overrides default in payload"

# env var is overridden by --max-tokens CLI flag
DRYBOTH=$(echo '{"messages":[{"role":"user","content":"hi"}]}' |
  SHAI_MAX_TOKENS=64000 "$DIR/shai-eval" --dry-run --max-tokens 99)
assert_contains "$DRYBOTH" '"max_tokens":99' "eval: --max-tokens CLI flag wins over SHAI_MAX_TOKENS env var"

# default is 384000
DRYDEFAULT=$(echo '{"messages":[{"role":"user","content":"hi"}]}' |
  env -u SHAI_MAX_TOKENS "$DIR/shai-eval" --dry-run)
assert_contains "$DRYDEFAULT" '"max_tokens":384000' "eval: default max_tokens is 384000"

# SHAI_MAX_TOKENS non-integer → controlled exit 2 with a clear message, not a jq crash
# (a bad value would otherwise abort shai-eval mid-payload-build and take shai-loop's
# pipeline down with it under pipefail)
MTENVBAD=$(echo '{"messages":[{"role":"user","content":"hi"}]}' | SHAI_MAX_TOKENS=abc "$DIR/shai-eval" --dry-run 2>&1)
RC=$?
assert_eq "$RC" "2" "eval: SHAI_MAX_TOKENS non-integer exits 2"
assert_contains "$MTENVBAD" "SHAI_MAX_TOKENS" "eval: SHAI_MAX_TOKENS non-integer → clear message"

# validation runs on the final value: a valid --max-tokens flag overrides a bad env var
DRYRESCUE=$(echo '{"messages":[{"role":"user","content":"hi"}]}' |
  SHAI_MAX_TOKENS=abc "$DIR/shai-eval" --dry-run --max-tokens 99)
RC=$?
assert_eq "$RC" "0" "eval: --max-tokens flag rescues a bad SHAI_MAX_TOKENS env var"
assert_contains "$DRYRESCUE" '"max_tokens":99' "eval: rescued payload uses the flag value"

# new: empty stdin → exit 0, no output
EEMPTY=$(printf '' | "$DIR/shai-eval")
RC=$?
assert_eq "$EEMPTY" "" "eval: empty stdin → no output"
assert_eq "$RC" "0" "eval: empty stdin → exit 0"

# new: curl hard-failure (non-zero exit) → error event, loop-safe
make_stub_bin
printf '#!/bin/bash\ncat > /dev/null\nexit 7\n' >"$STUB/curl"
chmod +x "$STUB/curl"
EVCURLFAIL=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | SHAI_EVAL_RETRIES=0 "$DIR/shai-eval")
assert_contains "$EVCURLFAIL" '"type":"error"' "eval: curl hard-failure → error event"
assert_contains "$EVCURLFAIL" 'request failed (curl)' "eval: curl-failure message"

# --dry-run writes no dump (fresh home)
DRYHOME="$(mktemp -d)"
_CLEANUP_DIRS+=("$DRYHOME")
echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | SHAI_HOME="$DRYHOME" "$DIR/shai-eval" --dry-run >/dev/null
assert_eq "$(find "$DRYHOME/runs" -name '*-request.json' 2>/dev/null | wc -l | tr -d ' ')" "0" "eval: --dry-run writes no debug dump"

# --health-check writes no dump (fresh home)
HCHOME="$(mktemp -d)"
_CLEANUP_DIRS+=("$HCHOME")
SHAI_HOME="$HCHOME" "$DIR/shai-eval" --health-check
assert_eq "$(find "$HCHOME/runs" -name '*-request.json' 2>/dev/null | wc -l | tr -d ' ')" "0" "eval: --health-check writes no debug dump"

# an unwritable SHAI_HOME must not break the call (best-effort dump)
make_stub_bin
printf '%s' '{"id":"msg_uw","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}' | write_curl_stub 200
UNWRITABLE="$(mktemp)" # a regular file — mkdir -p over it fails
_CLEANUP_DIRS+=("$UNWRITABLE")
EVUW=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | SHAI_HOME="$UNWRITABLE" "$DIR/shai-eval")
RC=$?
assert_contains "$EVUW" '"source":"assistant"' "eval: unwritable SHAI_HOME still returns assistant event"
assert_eq "$RC" "0" "eval: unwritable SHAI_HOME still exits 0"

# --- per-span request dumps ---------------------------------------------------
EVH="$(mktemp -d)"
_CLEANUP_DIRS+=("$EVH")
write_curl_stub 200 <<'JSON'
{"id":"msg_dump","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
JSON

echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' |
  SHAI_HOME="$EVH" SHAI_RUN_ID=run_dump SHAI_SPAN_ID=span_7 "$DIR/shai-eval" >/dev/null
assert_eq "$([ -f "$EVH/runs/run_dump/span_7-request.json" ] && echo yes)" "yes" \
  "eval: per-span request dump written"
assert_eq "$(jq -r '.messages[0].content' "$EVH/runs/run_dump/span_7-request.json")" "hi" \
  "eval: per-span dump holds the finalized payload"
# span unset → span_0 fallback, so it can never collide with a real span_1
EVH2="$(mktemp -d)"
_CLEANUP_DIRS+=("$EVH2")
echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' |
  env -u SHAI_SPAN_ID SHAI_HOME="$EVH2" SHAI_RUN_ID=run_nospan "$DIR/shai-eval" >/dev/null
assert_eq "$([ -f "$EVH2/runs/run_nospan/span_0-request.json" ] && echo yes)" "yes" \
  "eval: unset span falls back to span_0"

# no run id → no runs/ dir at all (hand-run pipelines are unaffected)
EVH3="$(mktemp -d)"
_CLEANUP_DIRS+=("$EVH3")
echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' |
  env -u SHAI_RUN_ID -u SHAI_SPAN_ID SHAI_HOME="$EVH3" "$DIR/shai-eval" >/dev/null
assert_eq "$([ -d "$EVH3/runs" ] && echo yes || echo no)" "no" \
  "eval: no run id → no runs/ directory created"

# the dump is best-effort: an unwritable runs path must not fail the call
EVH4="$(mktemp -d)"
_CLEANUP_DIRS+=("$EVH4")
printf 'not a directory' >"$EVH4/runs"
OUT4=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' |
  SHAI_HOME="$EVH4" SHAI_RUN_ID=run_blocked SHAI_SPAN_ID=span_1 "$DIR/shai-eval")
RC4=$?
assert_eq "$RC4" "0" "eval: unwritable runs path still exits 0"
assert_eq "$(printf '%s' "$OUT4" | jq -r '.source')" "assistant" \
  "eval: unwritable runs path still emits the assistant event"

# --- response metadata: api key + response dump ------------------------------
make_stub_bin
write_curl_stub 200 <<'STUB'
{"id":"msg_test123","choices":[{"message":{"role":"assistant","content":"Hello"},"finish_reason":"stop"}],"model":"test-model-20260801","usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150}}
STUB
OUT=$(echo '{"messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval")
assert_eq "$(printf '%s' "$OUT" | jq -r '.api.message_id')" "msg_test123" "api.message_id"
assert_eq "$(printf '%s' "$OUT" | jq -r '.api.model')" "test-model-20260801" "api.model"
assert_eq "$(printf '%s' "$OUT" | jq '.api.usage.prompt_tokens')" "100" "api.usage.prompt_tokens"
assert_eq "$(printf '%s' "$OUT" | jq '.api.usage.completion_tokens')" "50" "api.usage.completion_tokens"
# Presence must be asserted on the JSON type, not with assert_contains ... "" — the empty
# needle is a tautology (any string contains the empty string), so the old check passed
# whether or not the key existed. Mutation-checked: deleting the api.latency_ms emission
# makes this assertion go red (jq yields "null" instead of "number"); the non-negative
# check below would also catch a missing key.
assert_eq "$(printf '%s' "$OUT" | jq '.api.latency_ms | type')" '"number"' "api.latency_ms is present"
# latency_ms should be a non-negative integer
LATENCY=$(printf '%s' "$OUT" | jq '.api.latency_ms')
[ "$LATENCY" -ge 0 ] 2>/dev/null || {
  printf 'FAIL: api.latency_ms not a non-negative integer: %s\n' "$LATENCY"
  FAILED=1
}

make_stub_bin
write_curl_stub 500 <<'STUB'
{"error":{"message":"overloaded"}}
STUB
OUT=$(echo '{"messages":[{"role":"user","content":"hi"}]}' | SHAI_EVAL_RETRIES=0 "$DIR/shai-eval")
assert_eq "$(printf '%s' "$OUT" | jq '.api // "absent"')" '"absent"' "api key: absent on HTTP error event"

make_stub_bin
write_curl_stub 200 <<'STUB'
{"error":{"message":"rate limited"}}
STUB
OUT=$(echo '{"messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval")
assert_eq "$(printf '%s' "$OUT" | jq '.api // "absent"')" '"absent"' "api key: absent on API-level error (HTTP 200)"

# response dump written alongside the request dump; its latency matches the event's
EVR1=$(mktemp -d)
_CLEANUP_DIRS+=("$EVR1")
make_stub_bin
write_curl_stub 200 <<'STUB'
{"id":"msg_resp","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
STUB
OUT=$(echo '{"messages":[{"role":"user","content":"hi"}]}' |
  SHAI_HOME="$EVR1" SHAI_RUN_ID=run_resp_test SHAI_SPAN_ID=span_1 "$DIR/shai-eval")
assert_eq "$([ -f "$EVR1/runs/run_resp_test/span_1-response.json" ] && echo "exists")" "exists" \
  "response dump: written alongside request dump"
assert_eq "$(jq -r '.message_id' "$EVR1/runs/run_resp_test/span_1-response.json")" "msg_resp" \
  "response dump: message_id"
assert_eq "$(jq '.usage.prompt_tokens' "$EVR1/runs/run_resp_test/span_1-response.json")" "10" \
  "response dump: usage.prompt_tokens"
assert_eq "$(jq '.latency_ms' "$EVR1/runs/run_resp_test/span_1-response.json")" \
  "$(printf '%s' "$OUT" | jq '.api.latency_ms')" "response dump: latency matches the event's api.latency_ms"

# no response dump for an HTTP-level error
EVR2=$(mktemp -d)
_CLEANUP_DIRS+=("$EVR2")
make_stub_bin
write_curl_stub 500 <<'STUB'
{"error":{"message":"fail"}}
STUB
echo '{"messages":[{"role":"user","content":"hi"}]}' |
  SHAI_EVAL_RETRIES=0 SHAI_HOME="$EVR2" SHAI_RUN_ID=run_err_resp SHAI_SPAN_ID=span_1 "$DIR/shai-eval" >/dev/null
assert_eq "$([ -f "$EVR2/runs/run_err_resp/span_1-response.json" ] && echo "exists" || echo "absent")" "absent" \
  "response dump: not written for an HTTP error event"

# no response dump for an API-level error under HTTP 200 either (guards the select() in shai-eval:
# a naive `jq ... > file` redirect would still create an empty file even when select() matches nothing)
EVR2B=$(mktemp -d)
_CLEANUP_DIRS+=("$EVR2B")
make_stub_bin
write_curl_stub 200 <<'STUB'
{"error":{"message":"rate limited"}}
STUB
echo '{"messages":[{"role":"user","content":"hi"}]}' |
  SHAI_HOME="$EVR2B" SHAI_RUN_ID=run_200err_resp SHAI_SPAN_ID=span_1 "$DIR/shai-eval" >/dev/null
assert_eq "$([ -f "$EVR2B/runs/run_200err_resp/span_1-response.json" ] && echo "exists" || echo "absent")" "absent" \
  "response dump: not written for a 200 API-level error"

# unwritable runs path: response dump is best-effort, call still succeeds
EVR3=$(mktemp -d)
_CLEANUP_DIRS+=("$EVR3")
touch "$EVR3/runs"
make_stub_bin
write_curl_stub 200 <<'STUB'
{"id":"msg_x","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
STUB
OUT=$(echo '{"messages":[{"role":"user","content":"hi"}]}' |
  SHAI_HOME="$EVR3" SHAI_RUN_ID=run_unwrite SHAI_SPAN_ID=span_1 "$DIR/shai-eval")
RC=$?
assert_eq "$(printf '%s' "$OUT" | jq -r '.source')" "assistant" \
  "response dump: unwritable runs path still emits the assistant event"
assert_eq "$RC" "0" "response dump: unwritable runs path still exits 0"

# span_id unset -> response dump falls back to span_0, same as the request dump
EVR4=$(mktemp -d)
_CLEANUP_DIRS+=("$EVR4")
make_stub_bin
write_curl_stub 200 <<'STUB'
{"id":"msg_ns","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
STUB
echo '{"messages":[{"role":"user","content":"hi"}]}' |
  env -u SHAI_SPAN_ID SHAI_HOME="$EVR4" SHAI_RUN_ID=run_nospan "$DIR/shai-eval" >/dev/null
assert_eq "$([ -f "$EVR4/runs/run_nospan/span_0-response.json" ] && echo "exists")" "exists" \
  "response dump: unset span falls back to span_0"

# --- retry-with-backoff -------------------------------------------------------
desc "retry-with-backoff"

# helper: stateful curl stub that fails N times then succeeds
# Usage: write_retry_curl_stub <fail_count> <fail_code> <success_body>
# The stub tracks call count in $STUB/.retry_count.
write_retry_curl_stub() {
  local fail_count="$1" fail_code="$2" success_body="$3"
  echo 0 >"$STUB/.retry_count"
  printf '%s' "$success_body" >"$STUB/.success_body"
  cat >"$STUB/curl" <<STUBEOF
#!/bin/bash
cat > /dev/null
n=\$(cat "$STUB/.retry_count")
echo \$((n + 1)) > "$STUB/.retry_count"
if [ "\$n" -lt "$fail_count" ]; then
  printf '{"error":{"message":"temporarily unavailable"}}\n'
  echo "$fail_code"
else
  cat "$STUB/.success_body"
  printf '\n'
  echo "200"
fi
STUBEOF
  chmod +x "$STUB/curl"
}

# retry succeeds after transient 503
make_stub_bin
write_retry_curl_stub 2 503 '{"id":"msg_retry","choices":[{"message":{"role":"assistant","content":"recovered"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}'
OUT=$(echo '{"messages":[{"role":"user","content":"hi"}]}' | SHAI_EVAL_RETRIES=2 "$DIR/shai-eval" 2>"$STUB/.eval_stderr")
RETRY_ERR=$(cat "$STUB/.eval_stderr")
assert_eq "$(printf '%s' "$OUT" | jq -r '.source')" "assistant" "retry: recovers after transient 503"
assert_contains "$OUT" "recovered" "retry: final response content correct"
CALL_COUNT=$(cat "$STUB/.retry_count")
assert_eq "$CALL_COUNT" "3" "retry: made 3 total attempts (1 initial + 2 retries)"
# retry progress is a documented contract (CLAUDE.md: "Retry attempts log to stderr"):
# one line per retry, numbered attempt N/M with M = EVAL_RETRIES + 1 and N = ATTEMPT + 2
assert_eq "$(printf '%s' "$RETRY_ERR" | grep -c '^shai-eval: retrying (attempt' | tr -d ' ')" "2" \
  "retry: exactly one stderr progress line per retry (2 retries → 2 lines)"
assert_eq "$(printf '%s' "$RETRY_ERR" | sed -n '1p')" \
  'shai-eval: retrying (attempt 2/3) after HTTP 503, backoff 1s' \
  "retry: first progress line numbers the attempt 2/3 with backoff 1s"
assert_eq "$(printf '%s' "$RETRY_ERR" | sed -n '2p')" \
  'shai-eval: retrying (attempt 3/3) after HTTP 503, backoff 2s' \
  "retry: second progress line numbers the attempt 3/3 with backoff 2s"

# retry succeeds after transient 429
make_stub_bin
write_retry_curl_stub 1 429 '{"id":"msg_429","choices":[{"message":{"role":"assistant","content":"ok429"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}'
OUT=$(echo '{"messages":[{"role":"user","content":"hi"}]}' | SHAI_EVAL_RETRIES=2 "$DIR/shai-eval" 2>"$STUB/.eval_stderr")
RETRY_ERR=$(cat "$STUB/.eval_stderr")
assert_eq "$(printf '%s' "$OUT" | jq -r '.source')" "assistant" "retry: recovers after 429"
assert_eq "$(printf '%s' "$RETRY_ERR" | grep -c '^shai-eval: retrying (attempt' | tr -d ' ')" "1" \
  "retry: 429 → exactly one stderr progress line"
assert_eq "$(printf '%s' "$RETRY_ERR" | sed -n '1p')" \
  'shai-eval: retrying (attempt 2/3) after HTTP 429, backoff 1s' \
  "retry: 429 progress line numbers the attempt 2/3"

# retry exhausted → error event (not crash)
make_stub_bin
write_retry_curl_stub 5 500 '{"id":"never","choices":[{"message":{"role":"assistant","content":"never"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}'
OUT=$(echo '{"messages":[{"role":"user","content":"hi"}]}' | SHAI_EVAL_RETRIES=2 "$DIR/shai-eval" 2>/dev/null)
RC=$?
assert_eq "$(printf '%s' "$OUT" | jq -r '.type')" "error" "retry: exhausted retries → error event"
assert_eq "$RC" "0" "retry: exhausted retries still exits 0"

# SHAI_EVAL_RETRIES=0 disables retry — first failure is final
make_stub_bin
write_retry_curl_stub 1 503 '{"id":"msg_no","choices":[{"message":{"role":"assistant","content":"nope"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}'
OUT=$(echo '{"messages":[{"role":"user","content":"hi"}]}' | SHAI_EVAL_RETRIES=0 "$DIR/shai-eval" 2>"$STUB/.eval_stderr")
assert_eq "$(printf '%s' "$OUT" | jq -r '.type')" "error" "retry: SHAI_EVAL_RETRIES=0 disables retry"
CALL_COUNT=$(cat "$STUB/.retry_count")
assert_eq "$CALL_COUNT" "1" "retry: SHAI_EVAL_RETRIES=0 makes exactly 1 attempt"
assert_eq "$(wc -c <"$STUB/.eval_stderr")" "0" \
  "retry: no progress line when retries are disabled (positive control: the 503 case above)"

# 4xx (not 429) is never retried
make_stub_bin
write_retry_curl_stub 1 401 '{"id":"msg_auth","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}'
OUT=$(echo '{"messages":[{"role":"user","content":"hi"}]}' | SHAI_EVAL_RETRIES=2 "$DIR/shai-eval" 2>"$STUB/.eval_stderr")
assert_eq "$(printf '%s' "$OUT" | jq -r '.type')" "error" "retry: 401 is not retried"
CALL_COUNT=$(cat "$STUB/.retry_count")
assert_eq "$CALL_COUNT" "1" "retry: 401 makes exactly 1 attempt"
assert_eq "$(wc -c <"$STUB/.eval_stderr")" "0" \
  "retry: no progress line for a non-retried 401 (positive control: the 429 case above)"

# curl hard-failure is retried
make_stub_bin
echo 0 >"$STUB/.retry_count"
cat >"$STUB/curl" <<'STUBEOF'
#!/bin/bash
cat > /dev/null
COUNTER_FILE="$(dirname "$0")/.retry_count"
n=$(cat "$COUNTER_FILE")
echo $((n + 1)) > "$COUNTER_FILE"
if [ "$n" -lt 1 ]; then
  exit 7
fi
cat <<'JSON'
{"id":"msg_curl_retry","choices":[{"message":{"role":"assistant","content":"curl recovered"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
JSON
echo "200"
STUBEOF
chmod +x "$STUB/curl"
OUT=$(echo '{"messages":[{"role":"user","content":"hi"}]}' | SHAI_EVAL_RETRIES=2 "$DIR/shai-eval" 2>"$STUB/.eval_stderr")
RETRY_ERR=$(cat "$STUB/.eval_stderr")
assert_eq "$(printf '%s' "$OUT" | jq -r '.source')" "assistant" "retry: curl hard-failure recovered on retry"
assert_eq "$(printf '%s' "$RETRY_ERR" | grep -c '^shai-eval: retrying (attempt' | tr -d ' ')" "1" \
  "retry: curl failure → exactly one stderr progress line"
assert_eq "$(printf '%s' "$RETRY_ERR" | sed -n '1p')" \
  'shai-eval: retrying (attempt 2/3) after curl failure, backoff 1s' \
  "retry: curl-failure variant distinguished (attempt 2/3, 'after curl failure')"

# invalid SHAI_EVAL_RETRIES → exit 2
EVERR=$(SHAI_EVAL_RETRIES=abc "$DIR/shai-eval" --dry-run <<<'{"messages":[]}' 2>&1)
RC=$?
assert_eq "$RC" "2" "retry: invalid SHAI_EVAL_RETRIES exits 2"
assert_contains "$EVERR" "SHAI_EVAL_RETRIES" "retry: invalid value → clear error message"

# oversized SHAI_EVAL_RETRIES → exit 2 (backoff arithmetic must not overflow)
EVERR=$(SHAI_EVAL_RETRIES=63 "$DIR/shai-eval" --dry-run <<<'{"messages":[]}' 2>&1)
RC=$?
assert_eq "$RC" "2" "retry: oversized SHAI_EVAL_RETRIES exits 2"
assert_contains "$EVERR" "SHAI_EVAL_RETRIES" "retry: oversized value → clear error message"

# SHAI_EVAL_RETRIES at the cap (10) is accepted
EVERR=$(SHAI_EVAL_RETRIES=10 "$DIR/shai-eval" --dry-run <<<'{"messages":[]}' 2>&1)
RC=$?
assert_eq "$RC" "0" "retry: SHAI_EVAL_RETRIES=10 at the cap is accepted"

# default retries (no env var) — a 503 should still be retried
make_stub_bin
write_retry_curl_stub 1 503 '{"id":"msg_default","choices":[{"message":{"role":"assistant","content":"default ok"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}'
OUT=$(echo '{"messages":[{"role":"user","content":"hi"}]}' | env -u SHAI_EVAL_RETRIES "$DIR/shai-eval" 2>/dev/null)
assert_eq "$(printf '%s' "$OUT" | jq -r '.source')" "assistant" "retry: default retries recovers from transient 503"

# --- SHAI_EVAL_TIMEOUT --------------------------------------------------------
desc "SHAI_EVAL_TIMEOUT"

assert_eq "$DEFAULT_EVAL_TIMEOUT" "7200" "eval: default timeout is 7200 seconds"

# env var override: curl stub captures --max-time argument
make_stub_bin
cat >"$STUB/curl" <<'STUBEOF'
#!/bin/bash
for arg; do
  if [ "$prev" = "--max-time" ]; then
    printf '%s' "$arg" > "$(dirname "$0")/.captured_max_time"
  fi
  prev="$arg"
done
cat > /dev/null
cat <<'JSON'
{"id":"msg_to","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
JSON
echo "200"
STUBEOF
chmod +x "$STUB/curl"
echo '{"messages":[{"role":"user","content":"hi"}]}' |
  SHAI_EVAL_TIMEOUT=1200 "$DIR/shai-eval" >/dev/null
assert_eq "$(cat "$STUB/.captured_max_time")" "1200" "eval: SHAI_EVAL_TIMEOUT=1200 passes --max-time 1200 to curl"

# default timeout passes to curl when env var is unset
make_stub_bin
cat >"$STUB/curl" <<'STUBEOF'
#!/bin/bash
for arg; do
  if [ "$prev" = "--max-time" ]; then
    printf '%s' "$arg" > "$(dirname "$0")/.captured_max_time"
  fi
  if [ "$prev" = "--connect-timeout" ]; then
    printf '%s' "$arg" > "$(dirname "$0")/.captured_connect_timeout"
  fi
  prev="$arg"
done
cat > /dev/null
cat <<'JSON'
{"id":"msg_tod","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}
JSON
echo "200"
STUBEOF
chmod +x "$STUB/curl"
echo '{"messages":[{"role":"user","content":"hi"}]}' |
  env -u SHAI_EVAL_TIMEOUT "$DIR/shai-eval" >/dev/null
assert_eq "$(cat "$STUB/.captured_max_time")" "7200" "eval: default passes --max-time 7200 to curl"
assert_eq "$(cat "$STUB/.captured_connect_timeout")" "30" "eval: connect phase bounded by --connect-timeout 30"

# invalid SHAI_EVAL_TIMEOUT → exit 2
TOERR=$(SHAI_EVAL_TIMEOUT=abc "$DIR/shai-eval" --dry-run <<<'{"messages":[]}' 2>&1)
RC=$?
assert_eq "$RC" "2" "eval: SHAI_EVAL_TIMEOUT non-integer exits 2"
assert_contains "$TOERR" "SHAI_EVAL_TIMEOUT" "eval: SHAI_EVAL_TIMEOUT non-integer → clear message"

# zero is rejected (must be positive)
TOERR=$(SHAI_EVAL_TIMEOUT=0 "$DIR/shai-eval" --dry-run <<<'{"messages":[]}' 2>&1)
RC=$?
assert_eq "$RC" "2" "eval: SHAI_EVAL_TIMEOUT=0 exits 2"

# leading-zero is rejected (octal ambiguity)
TOERR=$(SHAI_EVAL_TIMEOUT=0120 "$DIR/shai-eval" --dry-run <<<'{"messages":[]}' 2>&1)
RC=$?
assert_eq "$RC" "2" "eval: SHAI_EVAL_TIMEOUT with leading zero exits 2"

finish
