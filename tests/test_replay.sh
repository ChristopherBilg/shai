#!/bin/bash
# test_replay.sh — unit tests for the shared replay classifier in lib/replay.sh
# Covers: classify_replay — every verdict (no-log, no-session-id, unsafe-session-id,
#         committed via run_id and via retry_of, no-user-message, replayable), the extracted
#         REPLAY_SESSION / USER_TEXT values, and check-order pinning
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=lib/replay.sh
source "$DIR/lib/replay.sh"

echo "lib/replay.sh: classify_replay"

# classify_replay resolves its state dir at call time ($STATE_DIR wins, else $SHAI_HOME),
# so a leaked STATE_DIR or RUNS_DIR from the runner would redirect every fixture below to
# the wrong tree. Neutralize both before any call.
unset STATE_DIR RUNS_DIR

# write_run_log <home> <run_id>: write runs/<run_id>/events.jsonl from stdin.
write_run_log() {
  local home="$1" rid="$2"
  mkdir -p "$home/runs/$rid"
  cat >"$home/runs/$rid/events.jsonl"
}

# write_session_log <home> <session_id>: write sessions/<session_id>.jsonl from stdin.
write_session_log() {
  local home="$1" sid="$2"
  mkdir -p "$home/sessions"
  cat >"$home/sessions/$sid.jsonl"
}

# classify <home> <run_id>: classify_replay against the fixture home; echoes the verdict
# it left in REPLAY_VERDICT. (The function itself prints nothing — the payloads are
# caller-scope variables, so every call below is direct, never in a command substitution.)
classify() {
  SHAI_HOME="$1" classify_replay "$2"
  printf '%s' "$REPLAY_VERDICT"
}

# --- precondition 1: no-log ---------------------------------------------------
NOH=$(mktemp -d)
_CLEANUP_DIRS+=("$NOH")
assert_eq "$(classify "$NOH" run_missing)" "no-log" "classify: missing run log → no-log"

write_run_log "$NOH" run_empty </dev/null
assert_eq "$(classify "$NOH" run_empty)" "no-log" "classify: empty run log → no-log"

# --- precondition 2: no-session-id ---------------------------------------------
RLH=$(mktemp -d)
_CLEANUP_DIRS+=("$RLH")
write_run_log "$RLH" run_nometa <<'JSON'
{"type":"message","source":"user","payload":{"text":"hi"}}
{"type":"error","source":"system","payload":{"text":"boom"}}
JSON
assert_eq "$(classify "$RLH" run_nometa)" "no-session-id" "classify: no meta lines → no-session-id"

write_run_log "$RLH" run_nullsid <<'JSON'
{"type":"message","source":"user","payload":{"text":"hi"},"meta":{"run_id":"run_nullsid","session_id":null}}
JSON
assert_eq "$(classify "$RLH" run_nullsid)" "no-session-id" "classify: meta without session_id → no-session-id"

# --- precondition 3: unsafe-session-id ----------------------------------------
# Path-traversal guard branches, driven directly — the platform can't be provoked into a
# session id with / or .. through the real pipeline, so these are unit tests by design
# (CLAUDE.md: guard branches get unit tests, not integration tests).
write_run_log "$RLH" run_slash <<'JSON'
{"type":"message","source":"user","payload":{"text":"hi"},"meta":{"run_id":"run_slash","session_id":"../etc/passwd"}}
JSON
assert_eq "$(classify "$RLH" run_slash)" "unsafe-session-id" "classify: session_id with / → unsafe-session-id"

write_run_log "$RLH" run_dotdot <<'JSON'
{"type":"message","source":"user","payload":{"text":"hi"},"meta":{"run_id":"run_dotdot","session_id":"a..b"}}
JSON
assert_eq "$(classify "$RLH" run_dotdot)" "unsafe-session-id" "classify: session_id with .. → unsafe-session-id"

# --- precondition 4: committed --------------------------------------------------
CH=$(mktemp -d)
_CLEANUP_DIRS+=("$CH")
write_run_log "$CH" run_rid <<'JSON'
{"type":"message","source":"user","payload":{"text":"done"},"meta":{"run_id":"run_rid","session_id":"sess"}}
JSON
write_session_log "$CH" sess <<'JSON'
{"type":"message","source":"system","payload":{"text":"sys"}}
{"type":"message","source":"user","payload":{"text":"done"},"meta":{"run_id":"run_rid","session_id":"sess"}}
JSON
assert_eq "$(classify "$CH" run_rid)" "committed" "classify: session log carries meta.run_id → committed"

# The retry_of half: a replay commits under a NEW run id carrying meta.retry_of, so the
# session log below has only a retry_of match — no meta.run_id line. This test is the one
# most at risk of being unfalsifiable (it asserts an absence: "no replay of an already
# retried run"), so it was mutation-checked when written: removing the
# `or .meta.retry_of? == $rid` clause from lib/replay.sh makes the committed check miss,
# the fixture's user message then satisfies precondition 5, and the verdict falls through
# to "replayable" — this assertion goes red while the run_id case above stays green.
write_run_log "$CH" run_retried <<'JSON'
{"type":"message","source":"user","payload":{"text":"again"},"meta":{"run_id":"run_retried","session_id":"sess2"}}
JSON
write_session_log "$CH" sess2 <<'JSON'
{"type":"message","source":"user","payload":{"text":"again"},"meta":{"run_id":"run_newer","session_id":"sess2","retry_of":"run_retried"}}
JSON
assert_eq "$(classify "$CH" run_retried)" "committed" "classify: session log carries only meta.retry_of → committed"

# --- precondition 5: no-user-message ---------------------------------------------
UMH=$(mktemp -d)
_CLEANUP_DIRS+=("$UMH")
write_run_log "$UMH" run_nomsg <<'JSON'
{"type":"error","source":"system","payload":{"text":"timeout"},"meta":{"run_id":"run_nomsg","session_id":"sess"}}
{"type":"message","source":"assistant","payload":{"content":"hi","finish_reason":"stop"},"meta":{"run_id":"run_nomsg","session_id":"sess"}}
JSON
assert_eq "$(classify "$UMH" run_nomsg)" "no-user-message" "classify: no user message → no-user-message"

write_run_log "$UMH" run_nulltext <<'JSON'
{"type":"message","source":"user","payload":{"text":null},"meta":{"run_id":"run_nulltext","session_id":"sess"}}
JSON
assert_eq "$(classify "$UMH" run_nulltext)" "no-user-message" "classify: user message with null text → no-user-message"

# --- replayable -------------------------------------------------------------------
RPH=$(mktemp -d)
_CLEANUP_DIRS+=("$RPH")
write_run_log "$RPH" run_ok <<'JSON'
{"type":"message","source":"user","payload":{"text":"replay me"},"meta":{"run_id":"run_ok","session_id":"sess_ok"}}
{"type":"error","source":"system","payload":{"text":"timeout"},"meta":{"run_id":"run_ok","session_id":"sess_ok"}}
JSON
assert_eq "$(classify "$RPH" run_ok)" "replayable" "classify: all preconditions hold → replayable"
# the verdict is only half the contract: shai-retry consumes the extracted values, so pin
# them too — a classifier that got the verdict right but nulled the payload would strand
# the replay. Direct call (the function prints nothing), then read the globals.
SHAI_HOME="$RPH" classify_replay run_ok
assert_eq "$REPLAY_VERDICT" "replayable" "classify: direct call → REPLAY_VERDICT replayable"
assert_eq "$REPLAY_SESSION" "sess_ok" "classify: replayable leaves REPLAY_SESSION for the caller"
assert_eq "$USER_TEXT" "replay me" "classify: replayable leaves USER_TEXT for the caller"

# a session log that exists but carries no matching event must not read as committed
write_session_log "$RPH" sess_ok <<'JSON'
{"type":"message","source":"user","payload":{"text":"other run"},"meta":{"run_id":"run_other","session_id":"sess_ok"}}
JSON
assert_eq "$(classify "$RPH" run_ok)" "replayable" "classify: session log without a matching event → replayable"

# --- check order: the first failing precondition wins -------------------------------
# a log failing both precondition 2 and 5 must report the session id first
write_run_log "$RPH" run_ord1 <<'JSON'
{"type":"message","source":"assistant","payload":{"content":"x","finish_reason":"stop"}}
JSON
assert_eq "$(classify "$RPH" run_ord1)" "no-session-id" "classify: order — no session id reported before a missing user message"

# a log failing both precondition 4 and 5 must report committed first
write_run_log "$CH" run_ord2 <<'JSON'
{"type":"error","source":"system","payload":{"text":"boom"},"meta":{"run_id":"run_ord2","session_id":"sess3"}}
JSON
write_session_log "$CH" sess3 <<'JSON'
{"type":"message","source":"user","payload":{"text":"hi"},"meta":{"run_id":"run_ord2","session_id":"sess3"}}
JSON
assert_eq "$(classify "$CH" run_ord2)" "committed" "classify: order — committed reported before a missing user message"

finish
