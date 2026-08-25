#!/bin/bash
# test_loop.sh — unit tests for shai-loop
# Covers: shai-loop — single-shot prompt, tool dispatch loop, error handling, span advancement, quiet mode, stdout output
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "shai-loop"

make_stub_bin
write_gh_stub

# --- single-shot prompt (no tools): session log gets user + assistant ---
printf '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"hello back"},"finish_reason":"stop"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' |
  write_curl_stub 200

TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP")
mkdir -p "$TMP/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"You are shai."}}' >"$TMP/sessions/test.jsonl"
: >"$TMP/sessions/test.latest.json"

OUT=$(printf 'hello' | SHAI_HOME="$TMP" SHAI_SESSION_ID=test "$DIR/shai-loop" 2>/dev/null)
RC=$?
HIST=$(cat "$TMP/sessions/test.jsonl")
assert_eq "$RC" "0" "loop: exit 0 on successful turn"
assert_contains "$HIST" '"source":"user"' "loop: session log has user event"
assert_contains "$HIST" '"source":"assistant"' "loop: session log has assistant event"
assert_contains "$OUT" '"source":"assistant"' "loop: stdout emits final assistant event"
assert_contains "$OUT" 'hello back' "loop: stdout has assistant text"

# --- tool dispatch round-trip ---
TMP2="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP2")
mkdir -p "$TMP2/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"You are shai."}}' >"$TMP2/sessions/test.jsonl"
: >"$TMP2/sessions/test.latest.json"

CSTUB="$(mktemp -d)"
_CLEANUP_DIRS+=("$CSTUB")
write_roundtrip_curl_stub "$CSTUB"
OUT2=$(printf 'list the dir' | PATH="$CSTUB:$PATH" SHAI_HOME="$TMP2" SHAI_SESSION_ID=test "$DIR/shai-loop" --tools 2>/dev/null)
H2=$(cat "$TMP2/sessions/test.jsonl")
assert_contains "$H2" '"tool_calls"' "loop: tool round-trip records tool_calls"
assert_contains "$H2" '"type":"tool_result"' "loop: tool round-trip records tool_result"
assert_contains "$OUT2" 'done' "loop: stdout has final assistant text after tool loop"
unset SHAI_ROUND_COUNT

# --- error event handling: eval error doesn't crash ---
TMP3="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP3")
mkdir -p "$TMP3/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"You are shai."}}' >"$TMP3/sessions/test.jsonl"
: >"$TMP3/sessions/test.latest.json"

printf '{"type":"error","error":{"type":"overloaded_error","message":"overloaded"}}' |
  write_curl_stub 529

OUT3=$(printf 'hi' | SHAI_HOME="$TMP3" SHAI_SESSION_ID=test "$DIR/shai-loop" 2>/dev/null)
RC3=$?
assert_eq "$RC3" "0" "loop: exit 0 even on eval error (loop-safe)"
assert_contains "$OUT3" '"type":"error"' "loop: stdout emits the error event"
H3=$(cat "$TMP3/sessions/test.jsonl")
ASST_COUNT=$(printf '%s\n' "$H3" | jq -s '[.[] | select(.source=="assistant")] | length')
assert_eq "$ASST_COUNT" "0" "loop: error turn does not commit assistant events to session log"

# --- span advancement across dispatch iterations ---
TMP4="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP4")
mkdir -p "$TMP4/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"You are shai."}}' >"$TMP4/sessions/test.jsonl"
: >"$TMP4/sessions/test.latest.json"

CSTUB2="$(mktemp -d)"
_CLEANUP_DIRS+=("$CSTUB2")
write_roundtrip_curl_stub "$CSTUB2"
printf 'list dir' | PATH="$CSTUB2:$PATH" SHAI_HOME="$TMP4" SHAI_SESSION_ID=test "$DIR/shai-loop" --tools >/dev/null 2>&1
H4=$(cat "$TMP4/sessions/test.jsonl")
TR_SPAN=$(printf '%s\n' "$H4" | jq -r 'select(.type=="tool_result") | .meta.span_id')
assert_eq "$TR_SPAN" "span_1" "loop: tool_result shares span_1 with its tool_use"
LAST_SPAN=$(printf '%s\n' "$H4" | jq -rs '[.[] | select(.type=="message" and .source=="assistant")] | .[-1] | .meta.span_id')
assert_eq "$LAST_SPAN" "span_2" "loop: re-eval advances to span_2"
unset SHAI_ROUND_COUNT

# --- quiet mode: dispatch markers suppressed, but reply text still shown ---
TMP5="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP5")
mkdir -p "$TMP5/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"You are shai."}}' >"$TMP5/sessions/test.jsonl"
: >"$TMP5/sessions/test.latest.json"

CSTUB3="$(mktemp -d)"
_CLEANUP_DIRS+=("$CSTUB3")
write_roundtrip_curl_stub "$CSTUB3"
QERR=$(printf 'list the dir' | PATH="$CSTUB3:$PATH" SHAI_HOME="$TMP5" SHAI_SESSION_ID=test "$DIR/shai-loop" --tools --quiet 2>&1 >/dev/null)
unset SHAI_ROUND_COUNT
assert_eq "$(grep -c '⏺' <<<"$QERR" || true)" "0" "loop: --quiet suppresses dispatch markers"
assert_contains "$QERR" "done" "loop: --quiet still shows reply text on stderr"

# --- missing SHAI_SESSION_ID exits 1 ---
printf 'hi' | env -u SHAI_SESSION_ID "$DIR/shai-loop" >/dev/null 2>&1
assert_eq "$?" "1" "loop: exit 1 when SHAI_SESSION_ID is not set"

# --- run log created ---
TMP6="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP6")
mkdir -p "$TMP6/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"You are shai."}}' >"$TMP6/sessions/test.jsonl"
: >"$TMP6/sessions/test.latest.json"

printf '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' |
  write_curl_stub 200

printf 'test' | SHAI_HOME="$TMP6" SHAI_SESSION_ID=test "$DIR/shai-loop" >/dev/null 2>&1
RUN_COUNT=$(find "$TMP6/runs" -name 'events.jsonl' 2>/dev/null | wc -l)
assert_eq "$RUN_COUNT" "1" "loop: run log created in runs/<run_id>/events.jsonl"

# --- mints own SHAI_RUN_ID when not inherited ---
MINTED_RUN=$(jq -r 'select(.type=="message" and .source=="user") | .meta.run_id' "$TMP6/sessions/test.jsonl")
assert_eq "$(printf '%s' "$MINTED_RUN" | grep -cE '^run_[0-9]{8}T[0-9]{6}_[0-9a-f]{8}$')" "1" \
  "loop: mints own run_id with expected format"

# --- graceful degradation when run dir unwritable ---
TMP7="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP7")
mkdir -p "$TMP7/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"You are shai."}}' >"$TMP7/sessions/test.jsonl"
: >"$TMP7/sessions/test.latest.json"
printf 'blocked' >"$TMP7/runs"

printf '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"degraded ok"},"finish_reason":"stop"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' |
  write_curl_stub 200

OUT7=$(printf 'hi' | SHAI_HOME="$TMP7" SHAI_SESSION_ID=test "$DIR/shai-loop" 2>/dev/null)
RC7=$?
assert_eq "$RC7" "0" "loop: exit 0 when runs/ is unwritable"
assert_contains "$OUT7" 'degraded ok' "loop: still produces output when runs/ is unwritable"
H7=$(cat "$TMP7/sessions/test.jsonl")
assert_contains "$H7" '"source":"assistant"' "loop: session log has events even when runs/ is unwritable"

# --- never-before-used session: sessions dir/file don't exist yet ---
TMP8="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP8")
# deliberately no `mkdir -p "$TMP8/sessions"` and no pre-seeded .jsonl/.latest.json —
# this is the never-before-used-session path

printf '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"fresh session ok"},"finish_reason":"stop"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' |
  write_curl_stub 200

OUT8=$(printf 'hi' | SHAI_HOME="$TMP8" SHAI_SESSION_ID=neversession "$DIR/shai-loop" 2>/dev/null)
RC8=$?
assert_eq "$RC8" "0" "loop: exit 0 for a never-before-used session (no pre-created sessions dir)"
assert_contains "$OUT8" 'fresh session ok' "loop: produces output for a never-before-used session"
assert_eq "$(test -f "$TMP8/sessions/neversession.jsonl" && echo yes)" "yes" \
  "loop: creates the session log file for a never-before-used session"
H8=$(cat "$TMP8/sessions/neversession.jsonl")
assert_contains "$H8" '"source":"user"' "loop: never-before-used session log gets the user event"
assert_contains "$H8" '"source":"assistant"' "loop: never-before-used session log gets the assistant event"

# --- SHAI_SESSION_ID path-traversal validation ---
TMP9="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP9")

SLASHOUT=$(printf 'hi' | SHAI_HOME="$TMP9" SHAI_SESSION_ID='foo/bar' "$DIR/shai-loop" 2>&1)
RC9=$?
assert_eq "$RC9" "1" "loop: exit 1 when SHAI_SESSION_ID contains /"
assert_contains "$SLASHOUT" "must not contain / or .." "loop: / traversal error message"

DOTDOTOUT=$(printf 'hi' | SHAI_HOME="$TMP9" SHAI_SESSION_ID='foo..bar' "$DIR/shai-loop" 2>&1)
RC10=$?
assert_eq "$RC10" "1" "loop: exit 1 when SHAI_SESSION_ID contains .."
assert_contains "$DOTDOTOUT" "must not contain / or .." "loop: .. traversal error message"

# --- --model / --max-tokens without a value: guarded, not a raw bash crash ---
MODELERR=$("$DIR/shai-loop" --model </dev/null 2>&1)
RC11=$?
assert_eq "$RC11" "2" "loop: --model without value exits 2"
assert_contains "$MODELERR" "--model requires a value" "loop: --model without value → clear message"

MTNOVAL=$("$DIR/shai-loop" --max-tokens </dev/null 2>&1)
RC12=$?
assert_eq "$RC12" "2" "loop: --max-tokens without value exits 2"
assert_contains "$MTNOVAL" "--max-tokens requires a value" "loop: --max-tokens without value → clear message"

# --- dispatch failure is terminal, not a re-eval signal (#257) ---
# The issue's repro: an install tree missing lib/read-only.sh. shai-dispatch's pre-flight
# check exits 3 ("dispatch failed"), and shai-loop must treat that as terminal — stop and emit
# an error event — instead of reading it as "a tool ran" and re-evaluating forever. Mirror the
# repo layout in a scratch dir (like test_heartbeat.sh) with the runtime scripts shai-loop
# shells out to, but deliberately no lib/ and no tools/.
TOOLCALL_JSON='{"id":"chatcmpl-tc","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"tl1","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\".\"}"}}]},"finish_reason":"tool_calls"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}'

TMPMISS="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMPMISS")
mkdir -p "$TMPMISS/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"You are shai."}}' >"$TMPMISS/sessions/test.jsonl"
: >"$TMPMISS/sessions/test.latest.json"

FAKE_INSTALL="$(mktemp -d)"
_CLEANUP_DIRS+=("$FAKE_INSTALL")
cp "$DIR/shai-loop" "$DIR/shai-dispatch" "$DIR/shai-context" "$DIR/shai-eval" \
  "$DIR/shai-read" "$DIR/shai-stamp" "$DIR/shai-print" "$FAKE_INSTALL/"
# shai-loop sources lib/failure.sh (it records api_error/dispatch_error, see #271), so the
# broken-install fixture must ship a lib/ with failure.sh — but deliberately no
# lib/read-only.sh, which is what makes shai-dispatch exit 3.
mkdir -p "$FAKE_INSTALL/lib"
cp "$DIR/lib/failure.sh" "$FAKE_INSTALL/lib/failure.sh"
chmod +x "$FAKE_INSTALL"/shai-*

printf '%s\n' "$TOOLCALL_JSON" | write_curl_stub 200

# timeout guards the assertion itself: if the fix regresses, the loop hangs and the suite
# fails fast (timeout exits 124 on a hang) instead of burning the whole CI window.
MISSOUT=$(printf 'list' | timeout 30 env PATH="$STUB:$PATH" SHAI_HOME="$TMPMISS" SHAI_SESSION_ID=test "$FAKE_INSTALL/shai-loop" 2>/dev/null)
MISSRC=$?
assert_eq "$MISSRC" "0" "loop: dispatch failure (missing lib) → loop stops, exit 0"
assert_contains "$MISSOUT" '"type":"error"' "loop: dispatch failure → error event emitted"
assert_contains "$MISSOUT" 'shai-dispatch failed (exit 3)' "loop: dispatch failure → error event names dispatch exit 3"
MISSRUNLOG=$(find "$TMPMISS/runs" -name events.jsonl 2>/dev/null | head -n1)
assert_contains "$(cat "$MISSRUNLOG" 2>/dev/null)" '"type":"error"' "loop: dispatch failure recorded in run log"

# --- re-eval loop bound (#257): a dispatch that reports exit 1 every round (a tool ran every
#     time) is capped, so even a failure that violates the exit-code contract degrades to a
#     stopped run with an error event instead of an unbounded spin. SHAI_MAX_DISPATCH_ROUNDS
#     lowers the bound so the test stays fast. ---
TMPBOUND="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMPBOUND")
mkdir -p "$TMPBOUND/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"You are shai."}}' >"$TMPBOUND/sessions/test.jsonl"
: >"$TMPBOUND/sessions/test.latest.json"

printf '%s\n' "$TOOLCALL_JSON" | write_curl_stub 200

BOUT=$(printf 'loop' | timeout 60 env SHAI_MAX_DISPATCH_ROUNDS=3 PATH="$STUB:$PATH" SHAI_HOME="$TMPBOUND" SHAI_SESSION_ID=test "$DIR/shai-loop" 2>/dev/null)
BRC=$?
assert_eq "$BRC" "0" "loop: dispatch loop bound → loop stops, exit 0"
assert_contains "$BOUT" '"type":"error"' "loop: dispatch loop bound → error event emitted"
assert_contains "$BOUT" 're-eval loop exceeded 3 dispatch rounds' "loop: dispatch loop bound → error names the bound"

# --- finish_reason "length" with no content/tool_calls: truncation error (#271) ---
# When the model exhausts max_tokens on reasoning alone, it returns finish_reason "length"
# with no visible output. shai-loop must detect this and emit an error event instead of
# treating it as a successful (empty) completion.
TMPTRUNC="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMPTRUNC")
mkdir -p "$TMPTRUNC/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"You are shai."}}' >"$TMPTRUNC/sessions/test.jsonl"
: >"$TMPTRUNC/sessions/test.latest.json"

printf '{"id":"chatcmpl-trunc","choices":[{"message":{"role":"assistant","content":null},"finish_reason":"length"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":100,"completion_tokens":16000,"total_tokens":16100}}' |
  write_curl_stub 200

TRUNCOUT=$(printf 'implement this complex feature' | SHAI_HOME="$TMPTRUNC" SHAI_SESSION_ID=test "$DIR/shai-loop" 2>/dev/null)
TRUNCRC=$?
assert_eq "$TRUNCRC" "0" "loop: truncation → exit 0 (errors are events, not crashes)"
assert_contains "$TRUNCOUT" '"type":"error"' "loop: truncation → error event emitted"
assert_contains "$TRUNCOUT" 'truncat' "loop: truncation → error message mentions truncation"
TRUNCHIST=$(cat "$TMPTRUNC/sessions/test.jsonl")
TRUNC_ASST=$(printf '%s\n' "$TRUNCHIST" | jq -s '[.[] | select(.source=="assistant")] | length')
assert_eq "$TRUNC_ASST" "0" "loop: truncation does not commit assistant events to session log"

# --- finish_reason "length" WITH tool_calls: NOT a truncation (tools parsed successfully) ---
# If the model hit the token limit but still produced parseable tool_calls, let dispatch
# proceed normally — the response was usable.
TMPTRUNC2="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMPTRUNC2")
mkdir -p "$TMPTRUNC2/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"You are shai."}}' >"$TMPTRUNC2/sessions/test.jsonl"
: >"$TMPTRUNC2/sessions/test.latest.json"

CSTUBTR="$(mktemp -d)"
_CLEANUP_DIRS+=("$CSTUBTR")
export SHAI_ROUND_COUNT="$CSTUBTR/count"
echo 0 >"$SHAI_ROUND_COUNT"
cat >"$CSTUBTR/curl" <<'STUBEOF'
#!/bin/bash
cat > /dev/null
n=$(cat "$SHAI_ROUND_COUNT"); echo $((n + 1)) > "$SHAI_ROUND_COUNT"
if [ "$n" = "0" ]; then
  cat <<'JSON'
{"id":"chatcmpl-tc","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"tu1","type":"function","function":{"name":"list_directory","arguments":"{\"path\":\".\"}"}}]},"finish_reason":"length"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":10,"completion_tokens":16000,"total_tokens":16010}}
JSON
else
  cat <<'JSON'
{"id":"chatcmpl-ok","choices":[{"message":{"role":"assistant","content":"done after length"},"finish_reason":"stop"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
JSON
fi
echo "200"
STUBEOF
chmod +x "$CSTUBTR/curl"

TRUNCOUT2=$(printf 'do something' | PATH="$CSTUBTR:$PATH" SHAI_HOME="$TMPTRUNC2" SHAI_SESSION_ID=test "$DIR/shai-loop" --tools 2>/dev/null)
unset SHAI_ROUND_COUNT
assert_contains "$TRUNCOUT2" 'done after length' "loop: finish_reason length WITH tool_calls → dispatch proceeds normally"

finish
