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
printf '{"type":"message","content":[{"type":"text","text":"hello back"}],"stop_reason":"end_turn"}' |
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
assert_contains "$H2" '"type":"tool_use"' "loop: tool round-trip records tool_use"
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

# --- quiet mode: no stderr output ---
TMP5="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP5")
mkdir -p "$TMP5/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"You are shai."}}' >"$TMP5/sessions/test.jsonl"
: >"$TMP5/sessions/test.latest.json"

printf '{"type":"message","content":[{"type":"text","text":"quiet reply"}],"stop_reason":"end_turn"}' |
  write_curl_stub 200

QERR=$(printf 'hi' | SHAI_HOME="$TMP5" SHAI_SESSION_ID=test "$DIR/shai-loop" --quiet 2>&1 >/dev/null)
assert_eq "$QERR" "" "loop: --quiet suppresses all stderr output"

# --- missing SHAI_SESSION_ID exits 1 ---
printf 'hi' | env -u SHAI_SESSION_ID "$DIR/shai-loop" >/dev/null 2>&1
assert_eq "$?" "1" "loop: exit 1 when SHAI_SESSION_ID is not set"

# --- run log created ---
TMP6="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP6")
mkdir -p "$TMP6/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"You are shai."}}' >"$TMP6/sessions/test.jsonl"
: >"$TMP6/sessions/test.latest.json"

printf '{"type":"message","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}' |
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

printf '{"type":"message","content":[{"type":"text","text":"degraded ok"}],"stop_reason":"end_turn"}' |
  write_curl_stub 200

OUT7=$(printf 'hi' | SHAI_HOME="$TMP7" SHAI_SESSION_ID=test "$DIR/shai-loop" 2>/dev/null)
RC7=$?
assert_eq "$RC7" "0" "loop: exit 0 when runs/ is unwritable"
assert_contains "$OUT7" 'degraded ok' "loop: still produces output when runs/ is unwritable"
H7=$(cat "$TMP7/sessions/test.jsonl")
assert_contains "$H7" '"source":"assistant"' "loop: session log has events even when runs/ is unwritable"

finish
