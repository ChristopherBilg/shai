#!/bin/bash
# test_eval.sh — unit tests for shai-eval
# Covers: shai-eval — payload build, error-event invariants, dry-run, health-check
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-eval"

DEFAULT_MODEL=$(sed -n 's/^MODEL="${SHAI_MODEL:-\(.*\)}"/\1/p' "$DIR/shai-eval")
DEFAULT_MAX_TOKENS=$(sed -n 's/^MAX_TOKENS="\(.*\)"/\1/p' "$DIR/shai-eval")

# isolate SHAI_HOME so the always-on request dump never writes to a real ~/.shai
SHAI_HOME_TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_HOME_TMP")
export SHAI_HOME="$SHAI_HOME_TMP"

# --- ported from tests/tests.sh:87-154: dry-run payload shape (no curl involved) ---
TOOLS_TMP=$(mktemp)
_CLEANUP_DIRS+=("$TOOLS_TMP")
"$DIR/shai-tools" >"$TOOLS_TMP"
DRY=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval" --dry-run --tools-file "$TOOLS_TMP")
assert_contains "$DRY" "\"model\":\"$DEFAULT_MODEL\"" "eval: default model"
assert_contains "$DRY" "\"max_tokens\":$DEFAULT_MAX_TOKENS" "eval: default max_tokens"
assert_contains "$DRY" '"gh_pr_view"' "eval: tools included with --tools-file"

NOTOOLS=$(echo '{"system":"S","messages":[{"role":"user","content":"hi"}]}' | "$DIR/shai-eval" --dry-run)
assert_eq "$(printf '%s' "$NOTOOLS" | jq 'has("tools")')" "false" "eval: no tools without --tools-file"

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
printf '%s' '{"type":"message","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}' | write_curl_stub 200
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
{"type":"message","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}
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

finish
