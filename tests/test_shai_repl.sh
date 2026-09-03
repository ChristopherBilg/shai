#!/bin/bash
# test_shai_repl.sh — integration tests for shai-repl
# Covers: shai-repl — REPL wiring, the dispatch re-eval loop round-trip, -q/--quiet dispatch
#         markers, and SIGINT handling (Ctrl-C at the prompt or mid-turn never ends the session)
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-repl (integration)"

# --- ported from tests/tests.sh:217-255 (seeds system, logs user/assistant, tool
#     round-trip drives the dispatch loop to completion, final line w/o newline) ---
make_stub_bin
write_gh_stub
printf '%s' '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"stub reply"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' |
  write_curl_stub 200

SHAI_TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP")
printf 'summarize PR 1\nexit\n' | SHAI_HOME="$SHAI_TMP" SHAI_SESSION_ID=test "$DIR/shai-repl" >/dev/null 2>&1
HIST_CONTENT=$(cat "$SHAI_TMP/sessions/test.jsonl" 2>/dev/null || echo "")
assert_contains "$HIST_CONTENT" '"source":"system"' "shai-repl: seeds system prompt"
assert_contains "$HIST_CONTENT" '"source":"user"' "shai-repl: logs user event"
assert_contains "$HIST_CONTENT" '"source":"assistant"' "shai-repl: logs assistant event"

# integration: a tool-calling round-trip must drive the dispatch loop to completion.
# Stateful across two curl calls (tool_use, then end_turn) via a counter file, so this
# stub stays bespoke/inline rather than using write_curl_stub.
SHAI_TMP2="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP2")
CSTUB="$(mktemp -d)"
_CLEANUP_DIRS+=("$CSTUB")
export SHAI_ROUND_COUNT="$CSTUB/count"
echo 0 >"$SHAI_ROUND_COUNT"
printf '#!/bin/bash\ncat > /dev/null\nn=$(cat "$SHAI_ROUND_COUNT"); echo $((n + 1)) > "$SHAI_ROUND_COUNT"\nif [ "$n" = "0" ]; then\n  cat <<JSON\n{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"tu1","type":"function","function":{"name":"list_directory","arguments":"{\\\\\"path\\\\\":\\\\\".\\\\\"}"}  }]},"finish_reason":"tool_calls"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}\nJSON\nelse\n  cat <<JSON\n{"id":"chatcmpl-test2","choices":[{"message":{"role":"assistant","content":"done summarizing"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}\nJSON\nfi\necho "200"\n' >"$CSTUB/curl"
chmod +x "$CSTUB/curl"
printf 'list the dir\nexit\n' | PATH="$CSTUB:$PATH" SHAI_HOME="$SHAI_TMP2" SHAI_SESSION_ID=test "$DIR/shai-repl" >/dev/null 2>&1
H2=$(cat "$SHAI_TMP2/sessions/test.jsonl" 2>/dev/null || echo "")
assert_contains "$H2" '"tool_calls"' "shai-repl: tool round-trip records tool_calls"
assert_contains "$H2" '"type":"tool_result"' "shai-repl: tool round-trip records tool_result"
assert_contains "$H2" 'done summarizing' "shai-repl: loop re-evaluates after tool and finishes"
unset SHAI_ROUND_COUNT

# integration: a final prompt with NO trailing newline (piped) must still be processed
SHAI_TMP3="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP3")
printf 'hi there' | SHAI_HOME="$SHAI_TMP3" SHAI_SESSION_ID=test "$DIR/shai-repl" >/dev/null 2>&1
H3=$(cat "$SHAI_TMP3/sessions/test.jsonl" 2>/dev/null || echo "")
assert_contains "$H3" '"text":"hi there"' "shai-repl: processes final line without trailing newline"

# new: EOF after the final turn (no trailing newline, then end of input) prints the same
# goodbye as exit/quit — the loop must fall through to the post-loop goodbye
SHAI_TMP_EOF="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP_EOF")
make_stub_bin
write_gh_stub
printf '#!/bin/bash\ncat > /dev/null\ncat <<JSON\n{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"hi there"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}\nJSON\necho "200"\n' >"$STUB/curl"
chmod +x "$STUB/curl"
EOFGOODBYE=$(printf 'hi there' | SHAI_HOME="$SHAI_TMP_EOF" SHAI_SESSION_ID=test "$DIR/shai-repl" 2>&1)
assert_contains "$EOFGOODBYE" "Goodbye." "shai-repl: EOF after final turn prints goodbye"

# new: `exit` ends the loop cleanly with a goodbye and without erroring
make_stub_bin
write_gh_stub
printf '#!/bin/bash\ncat > /dev/null\ncat <<JSON\n{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"hi there"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}\nJSON\necho "200"\n' >"$STUB/curl"
chmod +x "$STUB/curl"

SHAI_TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP")
QUITOUT=$(printf 'exit\n' | SHAI_HOME="$SHAI_TMP" SHAI_SESSION_ID=test "$DIR/shai-repl" 2>&1)
assert_contains "$QUITOUT" "Goodbye." "shai-repl: exit prints goodbye and ends the loop"

# new: piped input must NOT print the startup banner (stdout is a pipe, not a TTY) —
# explicit regression for the `[ -t 1 ]` gate
SHAI_TMP_NB="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP_NB")
NBOUT=$(printf 'exit\n' | SHAI_HOME="$SHAI_TMP_NB" SHAI_SESSION_ID=test "$DIR/shai-repl" 2>&1)
assert_eq "$(grep -cE '^shai ' <<<"$NBOUT" || true)" "0" "shai-repl: no startup banner when stdout is not a TTY"

# new: piped input must NOT create or touch $SHAI_HOME/history — readline editing and
# history persistence are gated on `[ -t 0 ]` (stdin is a TTY), so scripted/CI input
# keeps the plain-read loop and leaves no history file behind
assert_eq "$(test -e "$SHAI_TMP_NB/history" && echo exists || echo absent)" "absent" \
  "shai-repl: no history file when stdin is piped"

# new: the startup banner DOES print when stdout is a TTY — positive test for the
# `[ -t 1 ]` gate via script(1)'s pty, covering the version/session line and the
# SHAI_MODEL segment. SHAI_MODEL is now a required variable: shai-repl's unconditional
# startup health check (shai-eval --health-check) rejects an unset SHAI_MODEL before the
# REPL ever reaches the banner, so "banner with SHAI_MODEL unset" is no longer a reachable
# state to test (unlike SHAI_API_KEY/SHAI_API_URL, whose own health-check enforcement was
# already in place and is exercised separately below). The ambient-vs-explicit contrast
# below plays the same falsifiable-pair role the old omit/append pair did: distinct model
# strings, so neither assertion can pass if the other behavior is broken.
SHAI_TMP_B="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP_B")
make_stub_bin
write_gh_stub
printf '#!/bin/bash\ncat > /dev/null\ncat <<JSON\n{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"hi there"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}\nJSON\necho "200"\n' >"$STUB/curl"
chmod +x "$STUB/curl"
BANNEROUT=$(printf 'exit\n' | script -qec "SHAI_HOME='$SHAI_TMP_B' SHAI_SESSION_ID=banner_sess '$DIR/shai-repl'" /dev/null)
assert_eq "$(grep -cE '^shai ' <<<"$BANNEROUT" || true)" "1" "shai-repl: banner prints once when stdout is a TTY"
# Split into two checks (rather than one combined "session ... type" substring): SHAI_MODEL
# is now ambient (tests/lib.sh) and mandatory, so its segment always sits between session and
# the exit hint, and a single substring spanning both sides of it would never match.
assert_contains "$BANNEROUT" " — session banner_sess" "shai-repl: banner shows the session id"
assert_contains "$BANNEROUT" " — type 'exit' to quit" "shai-repl: banner shows the exit hint"
assert_contains "$BANNEROUT" " — model test-model" "shai-repl: banner shows the ambient SHAI_MODEL"
BANNEROUT_M=$(printf 'exit\n' | script -qec "SHAI_HOME='$SHAI_TMP_B' SHAI_SESSION_ID=banner_sess SHAI_MODEL=override-model '$DIR/shai-repl'" /dev/null)
assert_contains "$BANNEROUT_M" " — model override-model" "shai-repl: banner appends — model segment when SHAI_MODEL is set"

# new: under a TTY (script(1)'s pty, like the banner tests), each accepted prompt is
# appended to $SHAI_HOME/history — one per line, plain text — and reloaded by the next
# launch, so readline history persists across REPL sessions. Blank lines and exit/quit
# must not be recorded.
SHAI_TMP_H="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP_H")
make_stub_bin
write_gh_stub
printf '#!/bin/bash\ncat > /dev/null\ncat <<JSON\n{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"hi there"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}\nJSON\necho "200"\n' >"$STUB/curl"
chmod +x "$STUB/curl"
HOUT1=$(printf 'first prompt\n\nexit\n' | script -qec "SHAI_HOME='$SHAI_TMP_H' SHAI_SESSION_ID=hist '$DIR/shai-repl'" /dev/null)
assert_contains "$HOUT1" "hi there" "shai-repl: turn still completes under a TTY with history enabled"
HIST1=$(cat "$SHAI_TMP_H/history" 2>/dev/null || echo "")
assert_contains "$HIST1" "first prompt" "shai-repl: TTY prompt recorded in \$SHAI_HOME/history"
assert_eq "$(grep -cE '^[[:space:]]*$' <<<"$HIST1" || true)" "0" "shai-repl: blank lines not recorded in history"
assert_eq "$(grep -cx 'exit' <<<"$HIST1" || true)" "0" "shai-repl: exit not recorded in history"

# a second launch under the same SHAI_HOME seeds the first session's prompts into readline
# and appends the new ones without duplicating the loaded lines
printf 'second prompt\nexit\n' | script -qec "SHAI_HOME='$SHAI_TMP_H' SHAI_SESSION_ID=hist2 '$DIR/shai-repl'" /dev/null >/dev/null 2>&1
HIST2=$(cat "$SHAI_TMP_H/history" 2>/dev/null || echo "")
assert_contains "$HIST2" "first prompt" "shai-repl: history persists across launches"
assert_contains "$HIST2" "second prompt" "shai-repl: second launch appends its prompts"
assert_eq "$(wc -l <"$SHAI_TMP_H/history")" "2" "shai-repl: history holds exactly one line per accepted prompt"

# a read-only history file must not abort the REPL — the history calls are best-effort
SHAI_TMP_RO="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP_RO")
printf 'seeded\n' >"$SHAI_TMP_RO/history"
chmod 444 "$SHAI_TMP_RO/history"
ROOUT=$(printf 'third prompt\nexit\n' | script -qec "SHAI_HOME='$SHAI_TMP_RO' SHAI_SESSION_ID=rohist '$DIR/shai-repl'" /dev/null)
RORC=$?
chmod 644 "$SHAI_TMP_RO/history"
assert_eq "$RORC" "0" "shai-repl: unwritable history file degrades, exit 0"
assert_contains "$ROOUT" "Goodbye." "shai-repl: REPL still exits cleanly with an unwritable history file"

# a single session that outlives the in-memory history list (HISTSIZE, default 500) must
# still append exactly one line per accepted prompt — bash's `history -a` append-pointer
# tracking across a list wrap is a known sharp edge, so force the wrap cheaply with a tiny
# HISTSIZE: the file must hold every seeded + accepted line exactly once, no duplicates
SHAI_TMP_W="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP_W")
make_stub_bin
write_gh_stub
printf '#!/bin/bash\ncat > /dev/null\ncat <<JSON\n{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"hi there"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}\nJSON\necho "200"\n' >"$STUB/curl"
chmod +x "$STUB/curl"
printf 'seed1\nseed2\nseed3\n' >"$SHAI_TMP_W/history"
printf 'w1\nw2\nw3\nw4\nw5\nw6\nw7\nw8\nexit\n' | script -qec "HISTSIZE=5 SHAI_HOME='$SHAI_TMP_W' SHAI_SESSION_ID=wrap '$DIR/shai-repl'" /dev/null >/dev/null 2>&1
HISTW=$(cat "$SHAI_TMP_W/history")
assert_contains "$HISTW" "seed1" "shai-repl: seeded lines survive the HISTSIZE wrap"
assert_eq "$(wc -l <<<"$HISTW")" "11" "shai-repl: one line per accepted prompt past the HISTSIZE wrap (seeded 3 + 8 prompts)"
assert_eq "$(sort <<<"$HISTW" | uniq -d | tr '\n' ' ')" "" "shai-repl: no duplicated lines when the in-session list wraps"

# new: a blank line is skipped — it must not create an assistant event
SHAI_TMP2="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP2")
printf '\nexit\n' | SHAI_HOME="$SHAI_TMP2" SHAI_SESSION_ID=test "$DIR/shai-repl" >/dev/null 2>&1
BLANKHIST=$(cat "$SHAI_TMP2/sessions/test.jsonl" 2>/dev/null || echo "")
assert_eq "$(printf '%s\n' "$BLANKHIST" | jq -sr '[.[] | select(.source=="assistant")] | length')" "0" "shai-repl: blank line produces no assistant event"

# new: a failed startup health-check aborts before the loop (no session dir created)
SHAI_TMP3="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP3")
HEALTHERR=$(printf 'hello\nexit\n' | env -u SHAI_API_KEY SHAI_HOME="$SHAI_TMP3" SHAI_SESSION_ID=test "$DIR/shai-repl" 2>&1 >/dev/null)
assert_exit 1 "shai-repl: missing key aborts at health-check (exit 1)" -- bash -c 'printf "" | env -u SHAI_API_KEY SHAI_HOME="$1" SHAI_SESSION_ID=test "$2/shai-repl"' _ "$SHAI_TMP3" "$DIR"
assert_contains "$HEALTHERR" "hint: run" "shai-repl: health-check failure prints a hint on stderr"
assert_contains "$HEALTHERR" "shai-doctor" "shai-repl: hint points at shai-doctor"
assert_eq "$(test -d "$SHAI_TMP3/sessions" && echo exists || echo absent)" "absent" "shai-repl: no session dir when health-check fails"

# new: by default the REPL prints a "⏺ <tool>(<args>)" dispatch line for each tool call
SHAI_TMP_D="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP_D")
CSTUB_D="$(mktemp -d)"
_CLEANUP_DIRS+=("$CSTUB_D")
write_roundtrip_curl_stub "$CSTUB_D"
DISPOUT=$(printf 'list the dir\nexit\n' | PATH="$CSTUB_D:$PATH" SHAI_HOME="$SHAI_TMP_D" SHAI_SESSION_ID=test "$DIR/shai-repl" 2>/dev/null)
assert_contains "$DISPOUT" "⏺ list_directory(path: .)" "shai-repl: default REPL prints dispatch marker"
unset SHAI_ROUND_COUNT

# new: --quiet suppresses dispatch markers, but the tool round-trip is still recorded
SHAI_TMP_Q="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP_Q")
CSTUB_Q="$(mktemp -d)"
_CLEANUP_DIRS+=("$CSTUB_Q")
write_roundtrip_curl_stub "$CSTUB_Q"
QUIETOUT=$(printf 'list the dir\nexit\n' | PATH="$CSTUB_Q:$PATH" SHAI_HOME="$SHAI_TMP_Q" SHAI_SESSION_ID=test "$DIR/shai-repl" --quiet 2>/dev/null)
assert_eq "$(grep -c '⏺' <<<"$QUIETOUT" || true)" "0" "shai-repl: --quiet suppresses dispatch markers"
QHIST=$(cat "$SHAI_TMP_Q/sessions/test.jsonl" 2>/dev/null || echo "")
assert_contains "$QHIST" '"type":"tool_result"' "shai-repl: --quiet still records the tool round-trip"
assert_contains "$QHIST" '"tool_calls"' "shai-repl: --quiet still records the tool_calls"
unset SHAI_ROUND_COUNT

# new: the short -q flag suppresses dispatch markers just like --quiet
SHAI_TMP_SQ="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP_SQ")
CSTUB_SQ="$(mktemp -d)"
_CLEANUP_DIRS+=("$CSTUB_SQ")
write_roundtrip_curl_stub "$CSTUB_SQ"
SQOUT=$(printf 'list the dir\nexit\n' | PATH="$CSTUB_SQ:$PATH" SHAI_HOME="$SHAI_TMP_SQ" SHAI_SESSION_ID=test "$DIR/shai-repl" -q 2>/dev/null)
assert_eq "$(grep -c '⏺' <<<"$SQOUT" || true)" "0" "shai-repl: -q suppresses dispatch markers (short form)"
unset SHAI_ROUND_COUNT

# new: a completed turn is followed by exactly one blank line before the next prompt — the
# visual boundary between turns. bash only renders the `> ` prompt when stdin is a TTY, so in
# piped output the blank line separates the reply text from the next turn's output (the spot
# where the prompt would be); the separator is absent after exit/quit (the goodbye follows).
SHAI_TMP_SEP="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_TMP_SEP")
make_stub_bin
write_gh_stub
printf '#!/bin/bash\ncat > /dev/null\ncat <<JSON\n{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"stub reply"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}\nJSON\necho "200"\n' >"$STUB/curl"
chmod +x "$STUB/curl"
SEPOUT=$(printf 'first question\nsecond question\n' | SHAI_HOME="$SHAI_TMP_SEP" SHAI_SESSION_ID=test "$DIR/shai-repl" 2>&1)
assert_contains "$SEPOUT" $'stub reply\n\nstub reply' "shai-repl: blank line separates a turn's reply from the next prompt"

# --- envelope + trace propagation ---------------------------------------------
ENVH="$(mktemp -d)"
_CLEANUP_DIRS+=("$ENVH")
write_roundtrip_curl_stub "$STUB"
printf 'what is in this dir?\nexit\n' |
  SHAI_HOME="$ENVH" SHAI_SESSION_ID=sess_inherited "$DIR/shai-repl" >/dev/null 2>&1
unset SHAI_ROUND_COUNT

# an inherited session id must never be re-minted
SESSIDS=$(jq -r '.meta.session_id' "$ENVH/sessions/sess_inherited.jsonl" | sort -u)
assert_eq "$SESSIDS" "sess_inherited" "shai-repl: inherited SHAI_SESSION_ID honored verbatim"

# every event carries the schema version, including the seeded system prompt
UNVERSIONED=$(jq -r 'select(has("version") | not) | .type' "$ENVH/sessions/sess_inherited.jsonl" | wc -l)
assert_eq "$UNVERSIONED" "0" "shai-repl: every event stamped with version"

# the system prompt is seeded outside any turn: session yes, run/span no
SYSRUN=$(jq -r 'select(.source=="system") | .meta.run_id' "$ENVH/sessions/sess_inherited.jsonl")
assert_eq "$SYSRUN" "null" "shai-repl: seeded system prompt has null run_id"
SYSSPAN=$(jq -r 'select(.source=="system") | .meta.span_id' "$ENVH/sessions/sess_inherited.jsonl")
assert_eq "$SYSSPAN" "null" "shai-repl: seeded system prompt has null span_id"

# an inherited run/span must NOT leak into the seeded system prompt
LEAKH="$(mktemp -d)"
_CLEANUP_DIRS+=("$LEAKH")
write_roundtrip_curl_stub "$STUB"
printf 'hi\nexit\n' | SHAI_HOME="$LEAKH" SHAI_SESSION_ID=test SHAI_RUN_ID=INHERITED_RUN SHAI_SPAN_ID=INHERITED_SPAN \
  SHAI_PARENT_SPAN_ID=INHERITED_PARENT "$DIR/shai-repl" >/dev/null 2>&1
unset SHAI_ROUND_COUNT
assert_eq "$(jq -r 'select(.source=="system") | .meta.run_id' "$LEAKH/sessions/test.jsonl")" "null" \
  "shai-repl: inherited SHAI_RUN_ID does not leak into the seeded system prompt"
assert_eq "$(jq -r 'select(.source=="system") | .meta.span_id' "$LEAKH/sessions/test.jsonl")" "null" \
  "shai-repl: inherited SHAI_SPAN_ID does not leak into the seeded system prompt"

# one run per turn, and the turn's events share it
RUNIDS=$(jq -r 'select(.source!="system") | .meta.run_id' "$ENVH/sessions/sess_inherited.jsonl" | sort -u | wc -l)
assert_eq "$RUNIDS" "1" "shai-repl: one run_id per user turn"

# a tool_result shares the span of the tool_use that requested it (dispatch runs in the
# until CONDITION, which bash evaluates before the body advances the span)
TRSPAN=$(jq -r 'select(.type=="tool_result") | .meta.span_id' "$ENVH/sessions/sess_inherited.jsonl")
assert_eq "$TRSPAN" "span_1" "shai-repl: tool_result shares span_1 with its tool_use"

# the re-eval opens span_2 and parents to span_1 — proof the dispatch signal survived stamping
LASTSPAN=$(jq -r '[.[] | select(.type=="message" and .source=="assistant")] | .[-1] | .meta.span_id' \
  <(jq -s '.' "$ENVH/sessions/sess_inherited.jsonl"))
assert_eq "$LASTSPAN" "span_2" "shai-repl: re-eval advances to span_2 (dispatch exit-1 survived stamp)"
LASTPARENT=$(jq -r '[.[] | select(.type=="message" and .source=="assistant")] | .[-1] | .meta.parent_span_id' \
  <(jq -s '.' "$ENVH/sessions/sess_inherited.jsonl"))
assert_eq "$LASTPARENT" "span_1" "shai-repl: span_2 parents to span_1"

# the run log exists alongside the session log
RUNID=$(jq -r 'select(.type=="message" and .source=="user") | .meta.run_id' "$ENVH/sessions/sess_inherited.jsonl")
assert_eq "$([ -f "$ENVH/runs/$RUNID/events.jsonl" ] && echo yes)" "yes" \
  "shai-repl: runs/<run_id>/events.jsonl created"
RUNEVENTS=$(wc -l <"$ENVH/runs/$RUNID/events.jsonl")
assert_eq "$RUNEVENTS" "4" "shai-repl: run log holds the turn's 4 events (user, asst, tool_result, asst)"

# the envelope must never reach the API request
CTXOUT=$(cat "$ENVH/sessions/sess_inherited.jsonl" | "$DIR/shai-context")
assert_eq "$(printf '%s' "$CTXOUT" | jq 'has("meta") or has("version")')" "false" \
  "shai-repl: shai-context leaks no meta/version into the API request"

# --- an unwritable run dir must degrade, never abort the REPL ---
BLOCKH="$(mktemp -d)"
_CLEANUP_DIRS+=("$BLOCKH")
printf 'blocked' >"$BLOCKH/runs" # occupy the path so mkdir -p fails
write_roundtrip_curl_stub "$STUB"
printf 'what is in this dir?\nexit\n' | SHAI_HOME="$BLOCKH" SHAI_SESSION_ID=test "$DIR/shai-repl" >/dev/null 2>&1
BLOCKRC=$?
unset SHAI_ROUND_COUNT
assert_eq "$BLOCKRC" "0" "shai-repl: unwritable runs/ degrades, exit 0"
BLOCKEVENTS=$(jq -r 'select(.type=="message" and .source=="assistant") | .type' "$BLOCKH/sessions/test.jsonl" | wc -l)
assert_eq "$BLOCKEVENTS" "2" "shai-repl: turn still fully recorded when runs/ is unwritable"

# --- mkdir can succeed while the leaf is still unwritable (restrictive umask) ---
UMH="$(mktemp -d)"
_CLEANUP_DIRS+=("$UMH")
mkdir -p "$UMH/runs"
mkdir -p "$UMH/sessions"
printf '%s\n' '{"type":"message","source":"system","payload":{"text":"SYS"}}' >"$UMH/sessions/test.jsonl"
: >"$UMH/sessions/test.latest.json" # pre-create writable: isolates the run-log path
write_roundtrip_curl_stub "$STUB"
(
  umask 0222
  printf 'what is in this dir?\nexit\n' | SHAI_HOME="$UMH" SHAI_SESSION_ID=test "$DIR/shai-repl" >/dev/null 2>&1
)
unset SHAI_ROUND_COUNT
UMEVENTS=$(jq -r 'select(.type=="message" and .source=="assistant") | .type' "$UMH/sessions/test.jsonl" | wc -l)
assert_eq "$UMEVENTS" "2" "shai-repl: turn survives when the run dir is created unwritable"

# --- minted id shape: sortable prefix + hex suffix (a $RANDOM scheme collides) ---
MINTH="$(mktemp -d)"
_CLEANUP_DIRS+=("$MINTH")
write_roundtrip_curl_stub "$STUB"
printf 'hi\nexit\n' | SHAI_HOME="$MINTH" "$DIR/shai-repl" >/dev/null 2>&1
unset SHAI_ROUND_COUNT
MINTF=$(ls "$MINTH/sessions/"*.jsonl)
MINTSESS=$(jq -r 'select(.source=="system") | .meta.session_id' "$MINTF")
MINTRUN=$(jq -r 'select(.type=="message" and .source=="user") | .meta.run_id' "$MINTF")
assert_eq "$(printf '%s' "$MINTSESS" | grep -cE '^sess_[0-9]{8}T[0-9]{6}_[0-9a-f]{8}$')" "1" \
  "shai-repl: minted session id keeps its sortable prefix + 8 hex chars"
assert_eq "$(printf '%s' "$MINTRUN" | grep -cE '^run_[0-9]{8}T[0-9]{6}_[0-9a-f]{8}$')" "1" \
  "shai-repl: minted run id keeps its sortable prefix + 8 hex chars"

# --- SIGINT: Ctrl-C must never end the session (see #299) --------------------
# Both cases run the REPL under setsid (its own process group) with a FIFO for stdin, so a
# `kill -INT -- -$PID` delivers SIGINT exactly like the terminal's foreground-process-group
# broadcast on ^C — including to the mid-turn shai-loop pipeline. Skipped when setsid is
# unavailable (precedent: shai-doctor treats `timeout` as conditional). Some harnesses run
# with SIGINT ignored (e.g. a background ci runner): an ignored-at-entry SIGINT can neither
# be trapped by a non-interactive bash nor killed in children, so `env --default-signal=INT`
# (coreutils >= 9.0) restores the real terminal's default disposition first — without it,
# the REPL's INT trap never installs and the tests would silently test nothing. Skipped when
# env lacks the flag.
if command -v setsid >/dev/null 2>&1 && env --default-signal=INT true >/dev/null 2>&1; then
  # wait_for <seconds> <description> -- <cmd...>: poll until cmd succeeds or times out
  wait_for() {
    local secs="$1" desc="$2"
    shift 2
    [ "${1:-}" = "--" ] && shift
    local i
    for ((i = 0; i < secs * 10; i++)); do
      if "$@" >/dev/null 2>&1; then return 0; fi
      sleep 0.1
    done
    echo "  timeout (${secs}s) waiting for: $desc" >&2
    return 1
  }

  # (a) SIGINT to the process group while a turn is in flight: the turn aborts with an
  # Interrupted. notice, the next prompt works normally, the partial turn stays in its run
  # log, and the session log is untouched by the aborted turn
  SIG_HOME="$(mktemp -d)"
  _CLEANUP_DIRS+=("$SIG_HOME")
  mkfifo "$SIG_HOME/in"
  : >"$SIG_HOME/out"
  SIG_STUB="$(mktemp -d)"
  _CLEANUP_DIRS+=("$SIG_STUB")
  echo 0 >"$SIG_STUB/count"
  # stateful curl stub: the first eval call (the turn to interrupt) blocks 30s so the turn is
  # genuinely in flight; every later call (the post-interrupt turn) replies immediately
  cat >"$SIG_STUB/curl" <<'SIGSTUB'
#!/bin/bash
cat > /dev/null
n=$(cat "$SIG_STUB_COUNT"); echo $((n + 1)) > "$SIG_STUB_COUNT"
if [ "$n" = "0" ]; then sleep 30; fi
cat <<'JSON'
{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"sig reply"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}
JSON
echo "200"
SIGSTUB
  chmod +x "$SIG_STUB/curl"

  setsid env --default-signal=INT PATH="$SIG_STUB:$PATH" SIG_STUB_COUNT="$SIG_STUB/count" \
    SHAI_HOME="$SIG_HOME" SHAI_SESSION_ID=sig "$DIR/shai-repl" \
    <"$SIG_HOME/in" >"$SIG_HOME/out" 2>&1 &
  SIG_REPL_PID=$!
  exec 9>"$SIG_HOME/in" # open the FIFO's write end so the REPL's stdin open completes

  # start the turn to interrupt (it sits in the FIFO until the REPL reaches the prompt)
  printf 'first question\n' >&9

  # the counter reaches 1 once the stub is inside its 30s sleep — the turn is in flight
  wait_for 10 "first turn in flight (curl stub entered)" -- \
    bash -c '[ "$(cat "$1/count" 2>/dev/null || echo 0)" = "1" ]' _ "$SIG_STUB"

  # SIGINT the whole process group, exactly what the terminal delivers on ^C
  kill -INT -- -"$SIG_REPL_PID" 2>/dev/null || true

  wait_for 10 "Interrupted notice" -- bash -c 'grep -q "Interrupted\." "$1/out"' _ "$SIG_HOME"

  # a subsequent prompt must work normally (a new run id is minted per turn)
  printf 'second question\nexit\n' >&9

  wait_for 15 "goodbye after mid-turn interrupt" -- bash -c 'grep -q "Goodbye\." "$1/out"' _ "$SIG_HOME"
  kill "$SIG_REPL_PID" 2>/dev/null || true
  wait "$SIG_REPL_PID" 2>/dev/null
  SIG_RC=$?
  exec 9>&-

  SIGOUT=$(cat "$SIG_HOME/out")
  assert_eq "$SIG_RC" "0" "shai-repl: exits 0 after a mid-turn Ctrl-C"
  assert_contains "$SIGOUT" "Interrupted." "shai-repl: mid-turn Ctrl-C prints the Interrupted notice"
  assert_contains "$SIGOUT" "partial turn kept in run" "shai-repl: Interrupted notice names the partial run for shai-retry --run"
  assert_contains "$SIGOUT" "sig reply" "shai-repl: prompt after mid-turn Ctrl-C processes a new turn"
  assert_contains "$SIGOUT" "Goodbye." "shai-repl: session ends with goodbye after an interrupted turn"
  SIGSESS=$(cat "$SIG_HOME/sessions/sig.jsonl")
  assert_eq "$(printf '%s\n' "$SIGSESS" | jq -sr 'length')" "3" \
    "shai-repl: session log unchanged by the interrupted turn (system seed + second turn only)"
  assert_eq "$(printf '%s\n' "$SIGSESS" | jq -r 'select(.source!="system") | .meta.run_id' | sort -u | wc -l)" "1" \
    "shai-repl: only the post-interrupt turn is committed to the session log"
  SIGRUN_IDS=$(ls "$SIG_HOME/runs")
  assert_eq "$(printf '%s\n' "$SIGRUN_IDS" | wc -l)" "2" "shai-repl: interrupted run kept alongside the next run"
  SIGCOMMITTED=$(printf '%s\n' "$SIGSESS" | jq -r 'select(.source!="system") | .meta.run_id' | sort -u)
  SIGINTERRUPTED=$(printf '%s\n' "$SIGRUN_IDS" | grep -vxF "$SIGCOMMITTED" || true)
  assert_contains "$(cat "$SIG_HOME/runs/$SIGINTERRUPTED/events.jsonl")" '"source":"user"' \
    "shai-repl: interrupted turn's events stay buffered in its run log"

  # (b) SIGINT while idle at the prompt: line cleared, REPL stays at the prompt, and the next
  # prompt processes normally — no Interrupted notice, no session end
  SIGB_HOME="$(mktemp -d)"
  _CLEANUP_DIRS+=("$SIGB_HOME")
  mkfifo "$SIGB_HOME/in"
  : >"$SIGB_HOME/out"
  SIGB_STUB="$(mktemp -d)"
  _CLEANUP_DIRS+=("$SIGB_STUB")
  printf '#!/bin/bash\ncat > /dev/null\ncat <<JSON\n{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"idle reply"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}\nJSON\necho "200"\n' >"$SIGB_STUB/curl"
  chmod +x "$SIGB_STUB/curl"

  setsid env --default-signal=INT PATH="$SIGB_STUB:$PATH" SHAI_HOME="$SIGB_HOME" SHAI_SESSION_ID=sigb \
    "$DIR/shai-repl" <"$SIGB_HOME/in" >"$SIGB_HOME/out" 2>&1 &
  SIGB_REPL_PID=$!
  exec 8>"$SIGB_HOME/in"

  # the seeded system prompt in the session log means the REPL is at (or a hair before) the
  # prompt; the extra beat lets it settle into the blocked read
  wait_for 10 "prompt reached (system seed written)" -- \
    bash -c 'jq -e "select(.source==\"system\")" "$1/sessions/sigb.jsonl" >/dev/null 2>&1' _ "$SIGB_HOME"
  sleep 0.3
  kill -INT -- -"$SIGB_REPL_PID" 2>/dev/null || true
  sleep 0.3
  printf 'idle question\nexit\n' >&8

  wait_for 15 "goodbye after at-prompt interrupt" -- bash -c 'grep -q "Goodbye\." "$1/out"' _ "$SIGB_HOME"
  kill "$SIGB_REPL_PID" 2>/dev/null || true
  wait "$SIGB_REPL_PID" 2>/dev/null
  SIGB_RC=$?
  exec 8>&-

  SIGBOUT=$(cat "$SIGB_HOME/out")
  assert_eq "$SIGB_RC" "0" "shai-repl: exits 0 after a Ctrl-C at the prompt"
  assert_contains "$SIGBOUT" "idle reply" "shai-repl: prompt after at-prompt Ctrl-C processes input normally"
  assert_contains "$SIGBOUT" "Goodbye." "shai-repl: goodbye after at-prompt Ctrl-C"
  assert_eq "$(grep -c 'Interrupted\.' <<<"$SIGBOUT" || true)" "0" \
    "shai-repl: at-prompt Ctrl-C prints no Interrupted notice"

  # (c) ^C at the prompt under a REAL TTY, where `read -e` (Readline) is active — tests
  # (a)/(b) exercise the plain-read FIFO path only. script(1)'s pty is a real terminal, so
  # \003 is the INTR character and the kernel delivers SIGINT to the REPL's process group
  # exactly as a human pressing Ctrl-C would; env --default-signal=INT restores the default
  # SIGINT disposition (see the block comment above). This locks in the #299 guarantee for
  # the interactive/readline path: the INT-trap flag, not read's status, must distinguish
  # ^C from EOF.
  TCC_HOME="$(mktemp -d)"
  _CLEANUP_DIRS+=("$TCC_HOME")
  mkfifo "$TCC_HOME/in"
  : >"$TCC_HOME/out"
  TCC_STUB="$(mktemp -d)"
  _CLEANUP_DIRS+=("$TCC_STUB")
  printf '#!/bin/bash\ncat > /dev/null\ncat <<JSON\n{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"tty alive"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}\nJSON\necho "200"\n' >"$TCC_STUB/curl"
  chmod +x "$TCC_STUB/curl"

  env --default-signal=INT PATH="$TCC_STUB:$PATH" script -qec "SHAI_HOME='$TCC_HOME' SHAI_SESSION_ID=ttycc '$DIR/shai-repl'" /dev/null \
    <"$TCC_HOME/in" >"$TCC_HOME/out" 2>&1 &
  TCC_SCRIPT_PID=$!
  exec 7>"$TCC_HOME/in" # open the FIFO's write end so script's stdin open completes

  # the seeded system prompt in the session log means the REPL is at (or a hair before) the
  # prompt; the extra beat lets it settle into the blocked readline read
  wait_for 10 "tty prompt reached (system seed written)" -- \
    bash -c 'jq -e "select(.source==\"system\")" "$1/sessions/ttycc.jsonl" >/dev/null 2>&1' _ "$TCC_HOME"
  sleep 0.3
  printf '\003' >&7 # ^C through the pty: INTR → SIGINT to the REPL's process group
  sleep 0.3
  printf 'tty question\nexit\n' >&7

  wait_for 15 "goodbye after at-prompt ^C" -- bash -c 'grep -q "Goodbye\." "$1/out"' _ "$TCC_HOME"
  kill "$TCC_SCRIPT_PID" 2>/dev/null || true
  wait "$TCC_SCRIPT_PID" 2>/dev/null
  TCC_RC=$?
  exec 7>&-

  TCCOUT=$(cat "$TCC_HOME/out")
  assert_eq "$TCC_RC" "0" "shai-repl: exits 0 after ^C at the TTY prompt (read -e path)"
  assert_contains "$TCCOUT" "tty alive" "shai-repl: prompt after ^C under a TTY processes a new turn"
  assert_contains "$TCCOUT" "Goodbye." "shai-repl: goodbye after ^C at the TTY prompt"
  assert_eq "$(grep -c 'Interrupted\.' <<<"$TCCOUT" || true)" "0" \
    "shai-repl: ^C at the TTY prompt prints no Interrupted notice"
else
  echo "  (skipping SIGINT tests: setsid or env --default-signal unavailable)"
fi

finish
