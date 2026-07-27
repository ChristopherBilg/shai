#!/bin/bash
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

finish
