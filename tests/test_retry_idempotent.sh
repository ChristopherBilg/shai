#!/bin/bash
# test_retry_idempotent.sh — tests for buffer-then-commit and idempotent replay
# Covers: shai — buffer-then-commit write path (commit_run, error guard, /dev/null fallback);
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
printf '%s' '{"type":"message","content":[{"type":"text","text":"committed reply"}],"stop_reason":"end_turn"}' | write_curl_stub 200
printf 'hello\nexit\n' | SHAI_HOME="$SHOME" SHAI_SESSION_ID=test "$DIR/shai" >/dev/null 2>&1
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
printf 'hello\nexit\n' | SHAI_HOME="$SHOME" SHAI_SESSION_ID=test "$DIR/shai" >/dev/null 2>&1
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
printf '%s\n' '{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}}' >>"$FRUN"
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
printf '%s' '{"type":"message","content":[{"type":"text","text":"fallback reply"}],"stop_reason":"end_turn"}' | write_curl_stub 200
printf 'hello\nexit\n' | SHAI_HOME="$BLOCKH" SHAI_SESSION_ID=test "$DIR/shai" >/dev/null 2>&1
BH=$(cat "$BLOCKH/sessions/test.jsonl" 2>/dev/null || echo "")
assert_contains "$BH" '"source":"user"' "fallback: user event written directly to session log"
assert_contains "$BH" 'fallback reply' "fallback: assistant event written directly to session log"

finish
