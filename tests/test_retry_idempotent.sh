#!/bin/bash
# test_retry_idempotent.sh — tests for buffer-then-commit and idempotent replay
# Covers: shai-repl — buffer-then-commit write path (commit_run, error guard, /dev/null fallback);
#         shai-retry --run — idempotent replay, retry_of metadata, already-committed guard,
#         and the verbatim error messages + exit codes of every --run failure path
#         (#386's verdict→message contract; issue #407 pins them here)
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
printf '%s' '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"committed reply"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' | write_curl_stub 200
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
printf '%s' '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"fallback reply"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' | write_curl_stub 200
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
printf '%s' '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"replayed answer"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' | write_curl_stub 200
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
RC=$?
AFTER=$(wc -l <"$SHIST")
# The whole line, run id included: #386's contract made the message text part of the API,
# so a reword or an arm swap (e.g. the no-user-message text) must go red, not pass on an
# "already committed" substring.
assert_eq "$OUT" "run run_done already committed" "replay: already-committed run detected"
assert_eq "$RC" "0" "replay: already-committed run exits 0"
assert_eq "$AFTER" "$BEFORE" "replay: already-committed run appends nothing"

# --- shai-retry --run failure paths: verbatim messages + exit codes -----------------
# Every case below pins the exact stderr shai-retry prints AND the exit code. #386 moved
# these verdicts into lib/replay.sh's case mapping with the hard requirement that messages
# and exit codes stay verbatim; before #407 only the exit code (missing log) and an
# "already committed" substring were covered, so an arm swap or reword was a false green.
# assert_fails_exact compares the WHOLE captured stderr for equality, so an extra or
# duplicated line goes red too — a reword or arm swap cannot pass on a substring here.
# Fixtures are pure $SHAI_HOME filesystem state — no stubs needed, since every failure
# path exits before the health-check / model call.

# usage error: --run without a run_id is rejected before any state is read
new_home
assert_fails_exact 1 'error: --run requires a run_id' "replay: --run without a run_id" \
  -- env SHAI_HOME="$SHOME" "$DIR/shai-retry" --run

# the --run id guard (shai-retry's own check, ahead of lib/replay.sh's mapping) is also
# part of the user-visible surface: the offending id is named in the message
assert_fails_exact 1 'error: run_id must not contain / or .. (got "run/evil")' "replay: run_id with /" \
  -- env SHAI_HOME="$SHOME" "$DIR/shai-retry" --run run/evil
assert_fails_exact 1 'error: run_id must not contain / or .. (got "a..b")' "replay: run_id with .." \
  -- env SHAI_HOME="$SHOME" "$DIR/shai-retry" --run a..b

# missing run log: pin the message that names the log, not just "exit 1"
new_home
assert_fails_exact 1 "error: run log not found: $SHOME/runs/nonexistent_run/events.jsonl" \
  "replay: missing run log" -- env SHAI_HOME="$SHOME" "$DIR/shai-retry" --run nonexistent_run

# an empty run log hits the same precondition and message
mkdir -p "$SHOME/runs/run_empty"
: >"$SHOME/runs/run_empty/events.jsonl"
assert_fails_exact 1 "error: run log not found: $SHOME/runs/run_empty/events.jsonl" \
  "replay: empty run log" -- env SHAI_HOME="$SHOME" "$DIR/shai-retry" --run run_empty

# run log with no meta.session_id line
new_home
mkdir -p "$SHOME/runs/run_nosid"
printf '%s\n' '{"type":"message","source":"user","payload":{"text":"hi"}}' \
  >"$SHOME/runs/run_nosid/events.jsonl"
assert_fails_exact 1 'error: run log has no session_id metadata' "replay: run log without session_id" \
  -- env SHAI_HOME="$SHOME" "$DIR/shai-retry" --run run_nosid

# run log whose session_id contains / or ..: the offending id is named in the message
new_home
mkdir -p "$SHOME/runs/run_slash"
printf '%s\n' '{"type":"message","source":"user","payload":{"text":"hi"},"meta":{"run_id":"run_slash","session_id":"../etc/passwd"}}' \
  >"$SHOME/runs/run_slash/events.jsonl"
assert_fails_exact 1 'error: session_id in run log must not contain / or .. (got "../etc/passwd")' \
  "replay: session_id with /" -- env SHAI_HOME="$SHOME" "$DIR/shai-retry" --run run_slash

mkdir -p "$SHOME/runs/run_dotdot"
printf '%s\n' '{"type":"message","source":"user","payload":{"text":"hi"},"meta":{"run_id":"run_dotdot","session_id":"a..b"}}' \
  >"$SHOME/runs/run_dotdot/events.jsonl"
assert_fails_exact 1 'error: session_id in run log must not contain / or .. (got "a..b")' \
  "replay: session_id with .." -- env SHAI_HOME="$SHOME" "$DIR/shai-retry" --run run_dotdot

# run log with no non-null user payload.text: no user message at all...
new_home
mkdir -p "$SHOME/runs/run_nomsg"
printf '%s\n' '{"type":"error","source":"system","payload":{"text":"boom"},"meta":{"run_id":"run_nomsg","session_id":"sess"}}' \
  >"$SHOME/runs/run_nomsg/events.jsonl"
assert_fails_exact 1 'error: no user message found in run log' "replay: no user message" \
  -- env SHAI_HOME="$SHOME" "$DIR/shai-retry" --run run_nomsg

# ...or a user message whose payload.text is null (both read as "no text")
new_home
mkdir -p "$SHOME/runs/run_nulltext"
printf '%s\n' '{"type":"message","source":"user","payload":{"text":null},"meta":{"run_id":"run_nulltext","session_id":"sess"}}' \
  >"$SHOME/runs/run_nulltext/events.jsonl"
assert_fails_exact 1 'error: no user message found in run log' "replay: null user text" \
  -- env SHAI_HOME="$SHOME" "$DIR/shai-retry" --run run_nulltext

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
printf '%s' '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"doubled"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' | write_curl_stub 200
SHAI_HOME="$SHOME" "$DIR/shai-retry" --run run_double >/dev/null 2>&1
AFTER_FIRST=$(wc -l <"$SHIST")
OUT2=$(SHAI_HOME="$SHOME" "$DIR/shai-retry" --run run_double 2>&1)
AFTER_SECOND=$(wc -l <"$SHIST")
assert_contains "$OUT2" "already committed" "replay: double --run is idempotent"
assert_eq "$AFTER_SECOND" "$AFTER_FIRST" "replay: second --run appends nothing"

finish
