#!/bin/bash
# test_retry_idempotent.sh — tests for buffer-then-commit and idempotent replay
# Covers: shai-repl — buffer-then-commit write path (commit_run, error guard, /dev/null fallback);
#         shai-retry --run — idempotent replay, retry_of metadata, already-committed guard
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "buffer-then-commit + idempotent replay"

new_home() {
  SHOME="$(mktemp -d)"
  _CLEANUP_DIRS+=("$SHOME")
  mkdir -p "$SHOME/sessions"
  SHIST="$SHOME/sessions/test.jsonl"
}

# --- buffer-then-commit tests ------------------------------------------------

# successful turn commits user + assistant to session log
new_home
make_stub_bin
printf '%s' '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"committed reply"},"finish_reason":"stop"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' | write_curl_stub 200
printf 'hello\nexit\n' | SHAI_HOME="$SHOME" SHAI_SESSION_ID=test "$DIR/shai-repl" >/dev/null 2>&1
H=$(cat "$SHIST" 2>/dev/null || echo "")
assert_contains "$H" '"source":"system"' "buffer-commit: system prompt seeded in session log"
assert_contains "$H" '"source":"user"' "buffer-commit: user message committed to session log"
assert_contains "$H" 'committed reply' "buffer-commit: assistant response committed to session log"

# the run log also has the turn's events
RUNID=$(jq -r 'select(.type=="message" and .source=="user") | .meta.run_id' "$SHIST")
RLOG="$SHOME/runs/$RUNID/events.jsonl"
assert_eq "$([ -f "$RLOG" ] && echo yes)" "yes" "buffer-commit: run log created"
assert_contains "$(cat "$RLOG")" '"source":"user"' "buffer-commit: user event in run log"
assert_contains "$(cat "$RLOG")" 'committed reply' "buffer-commit: assistant event in run log"

# failed turn (API error) leaves session log untouched
new_home
make_stub_bin
printf '%s' '' | write_curl_stub 500
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"sys"}}' >"$SHIST"
BEFORE=$(wc -l <"$SHIST")
printf 'hello\nexit\n' | SHAI_HOME="$SHOME" SHAI_SESSION_ID=test "$DIR/shai-repl" >/dev/null 2>&1
AFTER=$(wc -l <"$SHIST")
assert_eq "$AFTER" "$BEFORE" "buffer-commit: API error leaves session log untouched"

# the failed run's error IS in the run log (for debugging)
# shellcheck disable=SC2012  # run dirs are mint_id-shaped, no special chars
FRUNID=$(ls "$SHOME/runs/" 2>/dev/null | head -n1)
if [ -n "$FRUNID" ]; then
  FRLOG="$SHOME/runs/$FRUNID/events.jsonl"
  assert_contains "$(cat "$FRLOG" 2>/dev/null)" '"type":"error"' "buffer-commit: error event preserved in run log"
fi

# commit filter excludes error events
FHOME="$(mktemp -d)"
_CLEANUP_DIRS+=("$FHOME")
FRUN="$FHOME/run.jsonl"
FOUT="$FHOME/session.jsonl"
printf '%s\n' '{"type":"message","source":"user","payload":{"text":"hi"}}' >"$FRUN"
printf '%s\n' '{"type":"error","source":"system","payload":{"text":"transient"}}' >>"$FRUN"
printf '%s\n' '{"type":"message","source":"assistant","payload":{"content":"ok","finish_reason":"stop"}}' >>"$FRUN"
jq -c 'select(.type != "error")' "$FRUN" >"$FOUT"
assert_eq "$(wc -l <"$FOUT")" "2" "commit filter: error excluded (3 events → 2 committed)"
assert_eq "$(jq -r 'select(.type=="error") | .type' "$FOUT" | wc -l)" "0" "commit filter: no errors in output"
assert_eq "$(jq -r 'select(.type=="error") | .type' "$FRUN" | wc -l)" "1" "commit filter: error retained in run log"

# RUN_LOG=/dev/null fallback writes directly to session log
BLOCKH="$(mktemp -d)"
_CLEANUP_DIRS+=("$BLOCKH")
printf 'blocked' >"$BLOCKH/runs"
mkdir -p "$BLOCKH/sessions"
make_stub_bin
printf '%s' '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"fallback reply"},"finish_reason":"stop"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' | write_curl_stub 200
printf 'hello\nexit\n' | SHAI_HOME="$BLOCKH" SHAI_SESSION_ID=test "$DIR/shai-repl" >/dev/null 2>&1
BH=$(cat "$BLOCKH/sessions/test.jsonl" 2>/dev/null || echo "")
assert_contains "$BH" '"source":"user"' "fallback: user event written directly to session log"
assert_contains "$BH" 'fallback reply' "fallback: assistant event written directly to session log"

# --- shai-retry --run tests ---------------------------------------------------

# replay a failed run: creates a new run, commits to session log
new_home
make_stub_bin
mkdir -p "$SHOME/runs/run_failed"
{
  printf '%s\n' '{"type":"message","source":"user","payload":{"text":"replay me"},"version":"1.0","meta":{"run_id":"run_failed","session_id":"test","span_id":"span_1","parent_span_id":null,"timestamp":"2026-08-01T00:00:00Z"}}'
  printf '%s\n' '{"type":"error","source":"system","payload":{"text":"API timeout"},"version":"1.0","meta":{"run_id":"run_failed","session_id":"test","span_id":"span_1","parent_span_id":null,"timestamp":"2026-08-01T00:00:01Z"}}'
} >"$SHOME/runs/run_failed/events.jsonl"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"sys"}}' >"$SHIST"
printf '%s' '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"replayed answer"},"finish_reason":"stop"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' | write_curl_stub 200
SHAI_HOME="$SHOME" "$DIR/shai-retry" --run run_failed >/dev/null 2>&1
RH=$(cat "$SHIST")
assert_contains "$RH" 'replay me' "replay: user message committed to session log"
assert_contains "$RH" 'replayed answer' "replay: assistant response committed to session log"

# replay records retry_of metadata in the new run
# shellcheck disable=SC2010  # run dirs are mint_id-shaped, no special chars
NEWRUN=$(ls "$SHOME/runs" | grep -v run_failed | head -n1)
if [ -n "$NEWRUN" ]; then
  NRLOG="$SHOME/runs/$NEWRUN/events.jsonl"
  RETRY_OF=$(jq -r '.meta.retry_of // empty' "$NRLOG" | head -n1)
  assert_eq "$RETRY_OF" "run_failed" "replay: new run records retry_of in meta"
fi

# already-committed run is a no-op
new_home
make_stub_bin
mkdir -p "$SHOME/runs/run_done"
printf '%s\n' '{"type":"message","source":"user","payload":{"text":"done"},"version":"1.0","meta":{"run_id":"run_done","session_id":"test","span_id":"span_1","parent_span_id":null,"timestamp":"2026-08-01T00:00:00Z"}}' >"$SHOME/runs/run_done/events.jsonl"
{
  printf '%s\n' '{"type":"message","source":"system","payload":{"text":"sys"}}'
  printf '%s\n' '{"type":"message","source":"user","payload":{"text":"done"},"version":"1.0","meta":{"run_id":"run_done","session_id":"test","span_id":"span_1","parent_span_id":null,"timestamp":"2026-08-01T00:00:00Z"}}'
  printf '%s\n' '{"type":"message","source":"assistant","payload":{"content":"ok","finish_reason":"stop"},"version":"1.0","meta":{"run_id":"run_done","session_id":"test","span_id":"span_1","parent_span_id":null,"timestamp":"2026-08-01T00:00:01Z"}}'
} >"$SHIST"
BEFORE=$(wc -l <"$SHIST")
OUT=$(SHAI_HOME="$SHOME" "$DIR/shai-retry" --run run_done 2>&1)
AFTER=$(wc -l <"$SHIST")
assert_contains "$OUT" "already committed" "replay: already-committed run detected"
assert_eq "$AFTER" "$BEFORE" "replay: already-committed run appends nothing"

# missing run log exits with error
new_home
assert_exit 1 "replay: missing run log exits 1" -- env SHAI_HOME="$SHOME" "$DIR/shai-retry" --run nonexistent_run

# existing no-flag behavior is preserved (nothing to resume on empty history)
new_home
OUT=$(SHAI_HOME="$SHOME" SHAI_SESSION_ID=test "$DIR/shai-retry" 2>&1)
assert_contains "$OUT" "nothing to resume" "replay: no-flag mode preserved"

# double replay is idempotent: second --run on the same failed run is a no-op
new_home
make_stub_bin
mkdir -p "$SHOME/runs/run_double"
{
  printf '%s\n' '{"type":"message","source":"user","payload":{"text":"double me"},"version":"1.0","meta":{"run_id":"run_double","session_id":"test","span_id":"span_1","parent_span_id":null,"timestamp":"2026-08-01T00:00:00Z"}}'
  printf '%s\n' '{"type":"error","source":"system","payload":{"text":"timeout"},"version":"1.0","meta":{"run_id":"run_double","session_id":"test","span_id":"span_1","parent_span_id":null,"timestamp":"2026-08-01T00:00:01Z"}}'
} >"$SHOME/runs/run_double/events.jsonl"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"sys"}}' >"$SHIST"
printf '%s' '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"doubled"},"finish_reason":"stop"}],"model":"deepseek-v4-flash","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' | write_curl_stub 200
SHAI_HOME="$SHOME" "$DIR/shai-retry" --run run_double >/dev/null 2>&1
AFTER_FIRST=$(wc -l <"$SHIST")
OUT2=$(SHAI_HOME="$SHOME" "$DIR/shai-retry" --run run_double 2>&1)
AFTER_SECOND=$(wc -l <"$SHIST")
assert_contains "$OUT2" "already committed" "replay: double --run is idempotent"
assert_eq "$AFTER_SECOND" "$AFTER_FIRST" "replay: second --run appends nothing"

finish
