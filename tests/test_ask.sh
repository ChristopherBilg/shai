#!/bin/bash
# test_ask.sh — integration tests for shai-ask
# Covers: shai-ask — positional/stdin/--external prompt input, answer-only stdout with
#         dispatch markers on stderr, -q/--quiet, --no-tools, --model/--max-tokens
#         forwarding, session persistence + inherited session id, and exit codes
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-ask (one-shot)"

# Default-model assertions below are env-independent: pin the documented defaults off so a
# leaked SHAI_MODEL/SHAI_MAX_TOKENS cannot skew the contrast cases for --model/--max-tokens.
unset SHAI_MODEL SHAI_MAX_TOKENS
DEFAULT_MODEL=$(sed -n 's/^MODEL="${SHAI_MODEL:-\(.*\)}"/\1/p' "$DIR/shai-eval")
DEFAULT_MAX_TOKENS=$(sed -n 's/^MAX_TOKENS="${SHAI_MAX_TOKENS:-\([0-9]*\)}"/\1/p' "$DIR/shai-eval")

make_stub_bin
write_gh_stub
printf '%s' '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"stub reply"},"finish_reason":"stop"}],"model":"deepseek-v4-pro","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' |
  write_curl_stub 200

# --- prompt as positional args: answer on stdout, session log gets system+user+assistant ---
A1="$(mktemp -d)"
_CLEANUP_DIRS+=("$A1")
OUT=$(SHAI_HOME="$A1" SHAI_SESSION_ID=ask1 "$DIR/shai-ask" "summarize" "PR 1" 2>/dev/null)
RC=$?
HIST=$(cat "$A1/sessions/ask1.jsonl")
assert_eq "$RC" "0" "shai-ask: exit 0 on a successful turn"
assert_eq "$OUT" "stub reply" "shai-ask: stdout is exactly the answer text (no JSON, no markers)"
assert_contains "$HIST" '"source":"system"' "shai-ask: seeds the system prompt"
assert_contains "$HIST" '"text":"summarize PR 1"' "shai-ask: positional args joined with spaces become the user prompt"
assert_contains "$HIST" '"source":"assistant"' "shai-ask: records the assistant event"

# --- prompt from piped stdin (not a TTY): same pipeline, stdin becomes the prompt ---
A2="$(mktemp -d)"
_CLEANUP_DIRS+=("$A2")
OUT2=$(printf 'explain this' | SHAI_HOME="$A2" SHAI_SESSION_ID=ask2 "$DIR/shai-ask" 2>/dev/null)
HIST2=$(cat "$A2/sessions/ask2.jsonl")
assert_eq "$OUT2" "stub reply" "shai-ask: piped stdin becomes the prompt"
assert_contains "$HIST2" '"text":"explain this"' "shai-ask: stdin prompt recorded as the user message"

# --- positional args win over piped stdin (never both) ---
A3="$(mktemp -d)"
_CLEANUP_DIRS+=("$A3")
OUT3=$(printf 'IGNORED STDIN' | SHAI_HOME="$A3" SHAI_SESSION_ID=ask3 "$DIR/shai-ask" "use the args" 2>/dev/null)
HIST3=$(cat "$A3/sessions/ask3.jsonl")
assert_eq "$OUT3" "stub reply" "shai-ask: turn completes when both args and stdin are piped"
assert_eq "$(printf '%s\n' "$HIST3" | jq -sr '[.[] | select(.source=="user") | .payload.text] | map(select(contains("IGNORED STDIN"))) | length')" "0" \
  "shai-ask: piped stdin is ignored when positional args are given"
assert_contains "$HIST3" '"text":"use the args"' "shai-ask: positional args are the prompt when stdin is also piped"

# --- no prompt and stdin is a TTY → usage error, exit 2 (script(1) pty) ---
A4="$(mktemp -d)"
_CLEANUP_DIRS+=("$A4")
TTYOUT=$(script -qec "SHAI_HOME='$A4' SHAI_SESSION_ID=ask4 '$DIR/shai-ask'" /dev/null 2>&1)
TTYRC=$?
assert_eq "$TTYRC" "2" "shai-ask: TTY stdin with no prompt exits 2"
assert_contains "$TTYOUT" "Usage: shai-ask" "shai-ask: TTY no-prompt prints the usage message"
assert_eq "$(test -e "$A4/sessions/ask4.jsonl" && echo exists || echo absent)" "absent" \
  "shai-ask: TTY usage error creates no session"

# --- empty piped stdin (not a TTY) → nothing to ask, exit 2 ---
A5="$(mktemp -d)"
_CLEANUP_DIRS+=("$A5")
assert_exit 2 "shai-ask: empty stdin with no args exits 2" -- bash -c 'SHAI_HOME="$1" "$2/shai-ask" </dev/null' _ "$A5" "$DIR"

# --- unknown option → exit 2 ---
assert_exit 2 "shai-ask: unknown option exits 2" -- bash -c 'SHAI_HOME="$1" "$2/shai-ask" --bogus "hi"' _ "$A5" "$DIR"

# --- --external without positional args → exit 2 ---
assert_exit 2 "shai-ask: --external without a prompt exits 2" -- bash -c 'printf "data" | SHAI_HOME="$1" "$2/shai-ask" --external gh-diff' _ "$A5" "$DIR"

# --- an invalid inherited session id is rejected (path traversal guard) ---
assert_exit 1 "shai-ask: invalid SHAI_SESSION_ID exits 1" -- bash -c 'SHAI_HOME="$1" SHAI_SESSION_ID="a/b" "$2/shai-ask" "hi"' _ "$A5" "$DIR"

# --- missing DEEPSEEK_API_KEY aborts at the health check (exit 1), no session dir ---
A6="$(mktemp -d)"
_CLEANUP_DIRS+=("$A6")
HEALTHERR=$(env -u DEEPSEEK_API_KEY SHAI_HOME="$A6" SHAI_SESSION_ID=ask6 "$DIR/shai-ask" "hello" 2>&1 >/dev/null)
assert_exit 1 "shai-ask: missing key aborts at health-check (exit 1)" -- bash -c 'env -u DEEPSEEK_API_KEY SHAI_HOME="$1" SHAI_SESSION_ID=ask6 "$2/shai-ask" "hello"' _ "$A6" "$DIR"
assert_contains "$HEALTHERR" "hint: run" "shai-ask: health-check failure prints a hint on stderr"
assert_eq "$(test -d "$A6/sessions" && echo exists || echo absent)" "absent" "shai-ask: no session dir when health-check fails"

# --- a turn that ends in an error event exits 1 (shai-loop exits 0 on error events) ---
A7="$(mktemp -d)"
_CLEANUP_DIRS+=("$A7")
printf '{"error":{"message":"boom"}}' | write_curl_stub 400
ERROUT=$(SHAI_HOME="$A7" SHAI_SESSION_ID=ask7 "$DIR/shai-ask" "risky question" 2>/dev/null)
ERRRC=$?
assert_eq "$ERRRC" "1" "shai-ask: turn ending in an error event exits 1"
assert_contains "$ERROUT" "Error: boom" "shai-ask: error text still rendered on stdout"

printf '%s' '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"stub reply"},"finish_reason":"stop"}],"model":"deepseek-v4-pro","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' |
  write_curl_stub 200

# --- tools on by default: dispatch markers on stderr, answer only on stdout ---
A8="$(mktemp -d)"
_CLEANUP_DIRS+=("$A8")
CSTUB="$(mktemp -d)"
_CLEANUP_DIRS+=("$CSTUB")
write_roundtrip_curl_stub "$CSTUB"
DISPOUT=$(printf 'list the dir' | PATH="$CSTUB:$PATH" SHAI_HOME="$A8" SHAI_SESSION_ID=ask8 "$DIR/shai-ask" 2>"$A8/err")
H8=$(cat "$A8/sessions/ask8.jsonl")
assert_eq "$DISPOUT" "done" "shai-ask: stdout carries exactly the final answer after a tool round-trip"
assert_contains "$(cat "$A8/err")" "⏺ list_directory(path: .)" "shai-ask: dispatch marker printed on stderr"
assert_contains "$H8" '"type":"tool_result"' "shai-ask: tool round-trip recorded in the session log"
unset SHAI_ROUND_COUNT

# --- --quiet suppresses the markers on stderr, answer still on stdout ---
A9="$(mktemp -d)"
_CLEANUP_DIRS+=("$A9")
CSTUB2="$(mktemp -d)"
_CLEANUP_DIRS+=("$CSTUB2")
write_roundtrip_curl_stub "$CSTUB2"
QUIETOUT=$(printf 'list the dir' | PATH="$CSTUB2:$PATH" SHAI_HOME="$A9" SHAI_SESSION_ID=ask9 "$DIR/shai-ask" --quiet 2>"$A9/err")
QH9=$(cat "$A9/sessions/ask9.jsonl")
assert_eq "$QUIETOUT" "done" "shai-ask: --quiet keeps the answer on stdout"
assert_eq "$(grep -c '⏺' "$A9/err" || true)" "0" "shai-ask: --quiet suppresses dispatch markers on stderr"
assert_contains "$QH9" '"type":"tool_result"' "shai-ask: --quiet still records the tool round-trip"
unset SHAI_ROUND_COUNT

# --- the short -q flag suppresses markers just like --quiet ---
A10="$(mktemp -d)"
_CLEANUP_DIRS+=("$A10")
CSTUB3="$(mktemp -d)"
_CLEANUP_DIRS+=("$CSTUB3")
write_roundtrip_curl_stub "$CSTUB3"
SQUIETOUT=$(printf 'list the dir' | PATH="$CSTUB3:$PATH" SHAI_HOME="$A10" SHAI_SESSION_ID=ask10 "$DIR/shai-ask" -q 2>"$A10/err")
assert_eq "$SQUIETOUT" "done" "shai-ask: -q keeps the answer on stdout"
assert_eq "$(grep -c '⏺' "$A10/err" || true)" "0" "shai-ask: -q suppresses dispatch markers (short form)"
unset SHAI_ROUND_COUNT

# --- --no-tools: pure Q&A — the request payload offers no tools ---
A11="$(mktemp -d)"
_CLEANUP_DIRS+=("$A11")
NT_OUT=$(SHAI_HOME="$A11" SHAI_SESSION_ID=ask11 "$DIR/shai-ask" --no-tools "no tools here" 2>/dev/null)
NT_HIST=$(cat "$A11/sessions/ask11.jsonl")
NT_RUN=$(printf '%s\n' "$NT_HIST" | jq -r 'select(.source=="user") | .meta.run_id')
NT_REQ="$A11/runs/$NT_RUN/span_1-request.json"
assert_eq "$NT_OUT" "stub reply" "shai-ask: --no-tools still answers (pure Q&A)"
assert_eq "$(jq 'has("tools")' "$NT_REQ")" "false" "shai-ask: --no-tools request payload has no tools key"

# --- tools offered by default: the request payload carries the tool array (contrast case) ---
A12="$(mktemp -d)"
_CLEANUP_DIRS+=("$A12")
T_OUT=$(SHAI_HOME="$A12" SHAI_SESSION_ID=ask12 "$DIR/shai-ask" "use tools please" 2>/dev/null)
T_HIST=$(cat "$A12/sessions/ask12.jsonl")
T_RUN=$(printf '%s\n' "$T_HIST" | jq -r 'select(.source=="user") | .meta.run_id')
T_REQ="$A12/runs/$T_RUN/span_1-request.json"
assert_eq "$T_OUT" "stub reply" "shai-ask: default turn completes"
assert_eq "$(jq 'has("tools")' "$T_REQ")" "true" "shai-ask: tools enabled by default — request payload has tools"
assert_contains "$(cat "$T_REQ")" '"name":"list_directory"' "shai-ask: default tool array includes the repo's tools"
assert_eq "$(jq -r '.model' "$T_REQ")" "$DEFAULT_MODEL" "shai-ask: default model when --model is absent"
assert_eq "$(jq -r '.max_tokens' "$T_REQ")" "$DEFAULT_MAX_TOKENS" "shai-ask: default max_tokens when --max-tokens is absent"

# --- --model and --max-tokens forwarded to shai-eval (visible in the request dump) ---
A13="$(mktemp -d)"
_CLEANUP_DIRS+=("$A13")
M_OUT=$(SHAI_HOME="$A13" SHAI_SESSION_ID=ask13 "$DIR/shai-ask" --model deepseek-chat --max-tokens 1234 "model test" 2>/dev/null)
M_HIST=$(cat "$A13/sessions/ask13.jsonl")
M_RUN=$(printf '%s\n' "$M_HIST" | jq -r 'select(.source=="user") | .meta.run_id')
M_REQ="$A13/runs/$M_RUN/span_1-request.json"
assert_eq "$M_OUT" "stub reply" "shai-ask: turn completes with --model/--max-tokens"
assert_eq "$(jq -r '.model' "$M_REQ")" "deepseek-chat" "shai-ask: --model overrides the model in the request"
assert_eq "$(jq -r '.max_tokens' "$M_REQ")" "1234" "shai-ask: --max-tokens overrides the token budget in the request"

# --- --external: stdin is fenced as external data and seeded before the prompt ---
A14="$(mktemp -d)"
_CLEANUP_DIRS+=("$A14")
EXTOUT=$(printf 'DIFF BODY' | SHAI_HOME="$A14" SHAI_SESSION_ID=ask14 "$DIR/shai-ask" --external gh-diff "review this" 2>/dev/null)
EXT_HIST=$(cat "$A14/sessions/ask14.jsonl")
EXT_FENCE=$(printf '%s\n' "$EXT_HIST" | jq -r 'select((.payload.text // "") | contains("external_data")) | .payload.text')
assert_eq "$EXTOUT" "stub reply" "shai-ask: --external turn completes"
assert_contains "$EXT_FENCE" 'source="gh-diff"' "shai-ask: external fence carries the given source"
assert_contains "$EXT_FENCE" 'DIFF BODY' "shai-ask: external data content seeded into the session"
assert_contains "$EXT_HIST" '"text":"review this"' "shai-ask: positional prompt recorded after the external seed"
assert_eq "$(printf '%s\n' "$EXT_HIST" | jq -sr '[.[] | select(.type=="message" and .source=="user")] | map((.payload.text // "") | contains("external_data")) | index(true)')" "0" \
  "shai-ask: external data precedes the prompt in the session (prior context)"
assert_eq "$(printf '%s\n' "$EXT_HIST" | jq -sr '[.[] | select(.type=="message" and .source=="user") | .meta.run_id] | unique | length')" "1" \
  "shai-ask: external seed and prompt share one run id"

# --- an inherited session id attaches: the system prompt is seeded exactly once ---
A15="$(mktemp -d)"
_CLEANUP_DIRS+=("$A15")
SHAI_HOME="$A15" SHAI_SESSION_ID=shared "$DIR/shai-ask" "first ask" >/dev/null 2>&1
SHAI_HOME="$A15" SHAI_SESSION_ID=shared "$DIR/shai-ask" "second ask" >/dev/null 2>&1
SH_HIST=$(cat "$A15/sessions/shared.jsonl")
assert_eq "$(printf '%s\n' "$SH_HIST" | jq -sr '[.[] | select(.source=="system")] | length')" "1" \
  "shai-ask: inherited session seeds the system prompt exactly once"
assert_contains "$SH_HIST" '"text":"second ask"' "shai-ask: second ask attaches to the inherited session"

# --- a minted session id keeps its sortable prefix + hex suffix ---
A16="$(mktemp -d)"
_CLEANUP_DIRS+=("$A16")
SHAI_HOME="$A16" "$DIR/shai-ask" "mint test" >/dev/null 2>&1
MINTF=$(ls "$A16/sessions/"*.jsonl)
MINTSESS=$(basename "$MINTF" .jsonl)
assert_eq "$(printf '%s' "$MINTSESS" | grep -cE '^sess_[0-9]{8}T[0-9]{6}_[0-9a-f]{8}$')" "1" \
  "shai-ask: minted session id keeps its sortable prefix + 8 hex chars"

finish
