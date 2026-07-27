#!/bin/bash
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-dispatch"
make_stub_bin
write_gh_stub

# --- ported from tests/tests.sh:156-201 (no-tool exit 0, gh tool_result + exit 1,
#     unknown tool is_error, 8000-byte truncation, multiple tool_use, backslash path,
#     gh `--` option-injection guard) ---
NOTOOL='{"type":"message","source":"assistant","payload":{"content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn"}}'
echo "$NOTOOL" | "$DIR/shai-dispatch" >/dev/null
assert_eq "$?" "0" "dispatch: no-tool exit 0"

TOOL='{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"t1","name":"gh_pr_view","input":{"number":"123"}}],"stop_reason":"tool_use"}}'
DOUT=$(echo "$TOOL" | "$DIR/shai-dispatch")
DRC=$?
assert_eq "$DRC" "1" "dispatch: tool exit 1"
assert_contains "$DOUT" '"type":"tool_result"' "dispatch: emits tool_result"
assert_contains "$DOUT" '"tool_use_id":"t1"' "dispatch: tool_use_id echoed"
assert_contains "$DOUT" 'stub gh output' "dispatch: ran stubbed gh"

UNK='{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"t9","name":"nope","input":{}}],"stop_reason":"tool_use"}}'
UOUT=$(echo "$UNK" | "$DIR/shai-dispatch") || true
assert_contains "$UOUT" '"is_error":true' "dispatch: unknown tool → is_error"

# truncation path: output > 8000 bytes must still emit a tool_result (SIGPIPE-safe)
BIGFILE=$(mktemp)
_CLEANUP_DIRS+=("$BIGFILE")
head -c 200000 /dev/zero | tr '\0' 'x' >"$BIGFILE"
BIGTOOL=$(jq -nc --arg p "$BIGFILE" '{type:"message",source:"assistant",payload:{content:[{type:"tool_use",id:"tb",name:"print_file",input:{path:$p}}],stop_reason:"tool_use"}}')
BOUT=$(echo "$BIGTOOL" | "$DIR/shai-dispatch")
BRC=$?
assert_eq "$BRC" "1" "dispatch: large output still exits 1 (no SIGPIPE crash)"
assert_contains "$BOUT" '"type":"tool_result"' "dispatch: large output emits tool_result"
assert_eq "$(printf '%s' "$BOUT" | jq -r '.payload.content | length')" "8000" "dispatch: output truncated to 8000 bytes"

NTOUT=$(echo "$NOTOOL" | "$DIR/shai-dispatch")
assert_eq "$NTOUT" "" "dispatch: no-tool produces no output"

MULTI='{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"m1","name":"list_directory","input":{"path":"."}},{"type":"tool_use","id":"m2","name":"print_file","input":{"path":"tools.json"}}],"stop_reason":"tool_use"}}'
MOUT=$(echo "$MULTI" | "$DIR/shai-dispatch")
MRC=$?
assert_eq "$MRC" "1" "dispatch: multiple tool_use → exit 1"
assert_eq "$(printf '%s' "$MOUT" | jq -s 'length')" "2" "dispatch: multiple tool_use → two tool_results"
assert_contains "$MOUT" '"tool_use_id":"m1"' "dispatch: first tool_use_id echoed"
assert_contains "$MOUT" '"tool_use_id":"m2"' "dispatch: second tool_use_id echoed"

# regression: backslash in a path must survive (no @tsv double-escaping)
SPDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$SPDIR")
BSNAME='a\b'
printf 'PASSTHRU_OK' >"$SPDIR/$BSNAME"
SPTOOL=$(jq -nc --arg p "$SPDIR/$BSNAME" '{type:"message",source:"assistant",payload:{content:[{type:"tool_use",id:"sp",name:"print_file",input:{path:$p}}],stop_reason:"tool_use"}}')
SPOUT=$(echo "$SPTOOL" | "$DIR/shai-dispatch")
assert_contains "$SPOUT" 'PASSTHRU_OK' "dispatch: backslash path survives input passthrough"

# regression: a model-supplied number like --web must be positional, not a gh flag
INJ='{"type":"message","source":"assistant","payload":{"content":[{"type":"tool_use","id":"inj","name":"gh_pr_view","input":{"number":"--web"}}],"stop_reason":"tool_use"}}'
IOUT=$(echo "$INJ" | "$DIR/shai-dispatch")
assert_contains "$IOUT" 'stub gh output for: pr view -- --web' "dispatch: gh number is positional (-- guards option injection)"

# new: successful real tool sets is_error:false (list_directory on a temp dir)
TMPD="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMPD")
: >"$TMPD/alpha"
LSTOOL=$(jq -nc --arg p "$TMPD" '{type:"message",source:"assistant",payload:{content:[{type:"tool_use",id:"ls1",name:"list_directory",input:{path:$p}}],stop_reason:"tool_use"}}')
LSOUT=$(echo "$LSTOOL" | "$DIR/shai-dispatch")
assert_eq "$(printf '%s' "$LSOUT" | jq -r '.payload.is_error')" "false" "dispatch: list_directory success → is_error false"
assert_contains "$LSOUT" 'alpha' "dispatch: list_directory returns the entry"

# new: print_file happy path
printf 'FILEBODY' >"$TMPD/beta"
PFTOOL=$(jq -nc --arg p "$TMPD/beta" '{type:"message",source:"assistant",payload:{content:[{type:"tool_use",id:"pf1",name:"print_file",input:{path:$p}}],stop_reason:"tool_use"}}')
PFOUT=$(echo "$PFTOOL" | "$DIR/shai-dispatch")
assert_contains "$PFOUT" 'FILEBODY' "dispatch: print_file returns file contents"

# new: empty stdin → exit 0
assert_exit 0 "dispatch: empty stdin → exit 0" -- bash -c 'printf "" | "'"$DIR"'/shai-dispatch"'

finish
