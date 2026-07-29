#!/bin/bash
# test_shai.sh — integration tests for shai
# Covers: shai — REPL wiring, the dispatch re-eval loop round-trip, and -q/--quiet dispatch markers
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai (integration)"

# --- ported from tests/tests.sh:217-255 (seeds system, logs user/assistant, tool
#     round-trip drives the dispatch loop to completion, final line w/o newline) ---
make_stub_bin
write_gh_stub
printf '%s' '{"type":"message","content":[{"type":"text","text":"stub reply"}],"stop_reason":"end_turn"}' |
  write_curl_stub 200

SHAI_TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP")
printf 'summarize PR 1\nexit\n' | SHAI_HOME="$SHAI_TMP" "$DIR/shai" >/dev/null 2>&1
HIST_CONTENT=$(cat "$SHAI_TMP/history.jsonl" 2>/dev/null || echo "")
assert_contains "$HIST_CONTENT" '"source":"system"' "shai: seeds system prompt"
assert_contains "$HIST_CONTENT" '"source":"user"' "shai: logs user event"
assert_contains "$HIST_CONTENT" '"source":"assistant"' "shai: logs assistant event"

# integration: a tool-calling round-trip must drive the dispatch loop to completion.
# Stateful across two curl calls (tool_use, then end_turn) via a counter file, so this
# stub stays bespoke/inline rather than using write_curl_stub.
SHAI_TMP2="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP2")
CSTUB="$(mktemp -d)"
_CLEANUP_DIRS+=("$CSTUB")
export SHAI_ROUND_COUNT="$CSTUB/count"
echo 0 >"$SHAI_ROUND_COUNT"
printf '#!/bin/bash\ncat > /dev/null\nn=$(cat "$SHAI_ROUND_COUNT"); echo $((n + 1)) > "$SHAI_ROUND_COUNT"\nif [ "$n" = "0" ]; then\n  cat <<JSON\n{"type":"message","content":[{"type":"tool_use","id":"tu1","name":"list_directory","input":{"path":"."}}],"stop_reason":"tool_use"}\nJSON\nelse\n  cat <<JSON\n{"type":"message","content":[{"type":"text","text":"done summarizing"}],"stop_reason":"end_turn"}\nJSON\nfi\necho "200"\n' >"$CSTUB/curl"
chmod +x "$CSTUB/curl"
printf 'list the dir\nexit\n' | PATH="$CSTUB:$PATH" SHAI_HOME="$SHAI_TMP2" "$DIR/shai" >/dev/null 2>&1
H2=$(cat "$SHAI_TMP2/history.jsonl" 2>/dev/null || echo "")
assert_contains "$H2" '"type":"tool_use"' "shai: tool round-trip records tool_use"
assert_contains "$H2" '"type":"tool_result"' "shai: tool round-trip records tool_result"
assert_contains "$H2" 'done summarizing' "shai: loop re-evaluates after tool and finishes"
unset SHAI_ROUND_COUNT

# integration: a final prompt with NO trailing newline (piped) must still be processed
SHAI_TMP3="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP3")
printf 'hi there' | SHAI_HOME="$SHAI_TMP3" "$DIR/shai" >/dev/null 2>&1
H3=$(cat "$SHAI_TMP3/history.jsonl" 2>/dev/null || echo "")
assert_contains "$H3" '"text":"hi there"' "shai: processes final line without trailing newline"

# new: `exit` ends the loop cleanly with a goodbye and without erroring
make_stub_bin
write_gh_stub
printf '#!/bin/bash\ncat > /dev/null\ncat <<JSON\n{"type":"message","content":[{"type":"text","text":"hi there"}],"stop_reason":"end_turn"}\nJSON\necho "200"\n' >"$STUB/curl"
chmod +x "$STUB/curl"

SHAI_TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP")
QUITOUT=$(printf 'exit\n' | SHAI_HOME="$SHAI_TMP" "$DIR/shai" 2>&1)
assert_contains "$QUITOUT" "Goodbye." "shai: exit prints goodbye and ends the loop"

# new: a blank line is skipped — it must not create an assistant event
SHAI_TMP2="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP2")
printf '\nexit\n' | SHAI_HOME="$SHAI_TMP2" "$DIR/shai" >/dev/null 2>&1
BLANKHIST=$(cat "$SHAI_TMP2/history.jsonl" 2>/dev/null || echo "")
assert_eq "$(printf '%s\n' "$BLANKHIST" | jq -sr '[.[] | select(.source=="assistant")] | length')" "0" "shai: blank line produces no assistant event"

# new: a failed startup health-check aborts before the loop (no history file written)
SHAI_TMP3="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP3")
printf 'hello\nexit\n' | env -u ANTHROPIC_API_KEY SHAI_HOME="$SHAI_TMP3" "$DIR/shai" >/dev/null 2>&1
assert_exit 1 "shai: missing key aborts at health-check (exit 1)" -- bash -c 'printf "" | env -u ANTHROPIC_API_KEY SHAI_HOME="'"$SHAI_TMP3"'" "'"$DIR"'/shai"'
assert_eq "$(test -s "$SHAI_TMP3/history.jsonl" && echo nonempty || echo empty)" "empty" "shai: no history written when health-check fails"

# new: by default the REPL prints a "⏺ <tool>(<args>)" dispatch line for each tool call
SHAI_TMP_D="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP_D")
CSTUB_D="$(mktemp -d)"
_CLEANUP_DIRS+=("$CSTUB_D")
write_roundtrip_curl_stub "$CSTUB_D"
DISPOUT=$(printf 'list the dir\nexit\n' | PATH="$CSTUB_D:$PATH" SHAI_HOME="$SHAI_TMP_D" "$DIR/shai" 2>/dev/null)
assert_contains "$DISPOUT" "⏺ list_directory(path: .)" "shai: default REPL prints dispatch marker"
unset SHAI_ROUND_COUNT

# new: --quiet suppresses dispatch markers, but the tool round-trip is still recorded
SHAI_TMP_Q="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP_Q")
CSTUB_Q="$(mktemp -d)"
_CLEANUP_DIRS+=("$CSTUB_Q")
write_roundtrip_curl_stub "$CSTUB_Q"
QUIETOUT=$(printf 'list the dir\nexit\n' | PATH="$CSTUB_Q:$PATH" SHAI_HOME="$SHAI_TMP_Q" "$DIR/shai" --quiet 2>/dev/null)
assert_eq "$(grep -c '⏺' <<<"$QUIETOUT" || true)" "0" "shai: --quiet suppresses dispatch markers"
QHIST=$(cat "$SHAI_TMP_Q/history.jsonl" 2>/dev/null || echo "")
assert_contains "$QHIST" '"type":"tool_result"' "shai: --quiet still records the tool round-trip"
assert_contains "$QHIST" '"type":"tool_use"' "shai: --quiet still records the tool_use"
unset SHAI_ROUND_COUNT

# new: the short -q flag suppresses dispatch markers just like --quiet
SHAI_TMP_SQ="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP_SQ")
CSTUB_SQ="$(mktemp -d)"
_CLEANUP_DIRS+=("$CSTUB_SQ")
write_roundtrip_curl_stub "$CSTUB_SQ"
SQOUT=$(printf 'list the dir\nexit\n' | PATH="$CSTUB_SQ:$PATH" SHAI_HOME="$SHAI_TMP_SQ" "$DIR/shai" -q 2>/dev/null)
assert_eq "$(grep -c '⏺' <<<"$SQOUT" || true)" "0" "shai: -q suppresses dispatch markers (short form)"
unset SHAI_ROUND_COUNT

# --- envelope + trace propagation ---------------------------------------------
ENVH="$(mktemp -d)"
_CLEANUP_DIRS+=("$ENVH")
write_roundtrip_curl_stub "$STUB"
printf 'what is in this dir?\nexit\n' |
  SHAI_HOME="$ENVH" SHAI_SESSION_ID=sess_inherited "$DIR/shai" >/dev/null 2>&1
unset SHAI_ROUND_COUNT

# an inherited session id must never be re-minted
SESSIDS=$(jq -r '.meta.session_id' "$ENVH/history.jsonl" | sort -u)
assert_eq "$SESSIDS" "sess_inherited" "shai: inherited SHAI_SESSION_ID honored verbatim"

# every event carries the schema version, including the seeded system prompt
UNVERSIONED=$(jq -r 'select(has("version") | not) | .type' "$ENVH/history.jsonl" | wc -l)
assert_eq "$UNVERSIONED" "0" "shai: every event stamped with version"

# the system prompt is seeded outside any turn: session yes, run/span no
SYSRUN=$(jq -r 'select(.source=="system") | .meta.run_id' "$ENVH/history.jsonl")
assert_eq "$SYSRUN" "null" "shai: seeded system prompt has null run_id"
SYSSPAN=$(jq -r 'select(.source=="system") | .meta.span_id' "$ENVH/history.jsonl")
assert_eq "$SYSSPAN" "null" "shai: seeded system prompt has null span_id"

# one run per turn, and the turn's events share it
RUNIDS=$(jq -r 'select(.source!="system") | .meta.run_id' "$ENVH/history.jsonl" | sort -u | wc -l)
assert_eq "$RUNIDS" "1" "shai: one run_id per user turn"

# a tool_result shares the span of the tool_use that requested it (dispatch runs in the
# until CONDITION, which bash evaluates before the body advances the span)
TRSPAN=$(jq -r 'select(.type=="tool_result") | .meta.span_id' "$ENVH/history.jsonl")
assert_eq "$TRSPAN" "span_1" "shai: tool_result shares span_1 with its tool_use"

# the re-eval opens span_2 and parents to span_1 — proof the dispatch signal survived stamping
LASTSPAN=$(jq -r '[.[] | select(.type=="message" and .source=="assistant")] | .[-1] | .meta.span_id' \
  <(jq -s '.' "$ENVH/history.jsonl"))
assert_eq "$LASTSPAN" "span_2" "shai: re-eval advances to span_2 (dispatch exit-1 survived stamp)"
LASTPARENT=$(jq -r '[.[] | select(.type=="message" and .source=="assistant")] | .[-1] | .meta.parent_span_id' \
  <(jq -s '.' "$ENVH/history.jsonl"))
assert_eq "$LASTPARENT" "span_1" "shai: span_2 parents to span_1"

# the run log exists alongside an untouched global history
RUNID=$(jq -r 'select(.type=="message" and .source=="user") | .meta.run_id' "$ENVH/history.jsonl")
assert_eq "$([ -f "$ENVH/runs/$RUNID/events.jsonl" ] && echo yes)" "yes" \
  "shai: runs/<run_id>/events.jsonl created"
RUNEVENTS=$(wc -l <"$ENVH/runs/$RUNID/events.jsonl")
assert_eq "$RUNEVENTS" "4" "shai: run log holds the turn's 4 events (user, asst, tool_result, asst)"

# the envelope must never reach the API request
CTXOUT=$(cat "$ENVH/history.jsonl" | "$DIR/shai-context")
assert_eq "$(printf '%s' "$CTXOUT" | jq 'has("meta") or has("version")')" "false" \
  "shai: shai-context leaks no meta/version into the API request"

# --- an unwritable run dir must degrade, never abort the REPL ---
BLOCKH="$(mktemp -d)"
_CLEANUP_DIRS+=("$BLOCKH")
printf 'blocked' >"$BLOCKH/runs" # occupy the path so mkdir -p fails
write_roundtrip_curl_stub "$STUB"
printf 'what is in this dir?\nexit\n' | SHAI_HOME="$BLOCKH" "$DIR/shai" >/dev/null 2>&1
BLOCKRC=$?
unset SHAI_ROUND_COUNT
assert_eq "$BLOCKRC" "0" "shai: unwritable runs/ degrades, exit 0"
BLOCKEVENTS=$(jq -r 'select(.type=="message" and .source=="assistant") | .type' "$BLOCKH/history.jsonl" | wc -l)
assert_eq "$BLOCKEVENTS" "2" "shai: turn still fully recorded when runs/ is unwritable"

finish
