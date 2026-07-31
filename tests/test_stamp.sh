#!/bin/bash
# Tests for shai-stamp: the additive execution envelope (version + meta) on each event.
# Covers: env-var stamping, schema-version override, unset vars → nulls, discriminator and
#         payload preservation, malformed/non-object passthrough, empty input, multi-line
#         input, missing trailing newline, and the exit-0-always invariant.
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-stamp"

# --- 1. a fully populated environment lands in meta ---
OUT=$(echo '{"type":"message","source":"user","payload":{"text":"hi"}}' |
  SHAI_RUN_ID=run_1 SHAI_SESSION_ID=sess_1 SHAI_SPAN_ID=span_2 SHAI_PARENT_SPAN_ID=span_1 \
    "$DIR/shai-stamp")
assert_eq "$(printf '%s' "$OUT" | jq -r '.version')" "1.0" "stamp: default schema version"
assert_eq "$(printf '%s' "$OUT" | jq -r '.meta.run_id')" "run_1" "stamp: run_id from env"
assert_eq "$(printf '%s' "$OUT" | jq -r '.meta.session_id')" "sess_1" "stamp: session_id from env"
assert_eq "$(printf '%s' "$OUT" | jq -r '.meta.span_id')" "span_2" "stamp: span_id from env"
assert_eq "$(printf '%s' "$OUT" | jq -r '.meta.parent_span_id')" "span_1" "stamp: parent from env"
assert_contains "$(printf '%s' "$OUT" | jq -r '.meta.timestamp')" "T" "stamp: ISO-8601 timestamp"

# --- 2. the additive contract: discriminators and payload must survive untouched ---
assert_eq "$(printf '%s' "$OUT" | jq -r '.type')" "message" "stamp: type preserved"
assert_eq "$(printf '%s' "$OUT" | jq -r '.source')" "user" "stamp: source preserved"
assert_eq "$(printf '%s' "$OUT" | jq -r '.payload.text')" "hi" "stamp: payload preserved"

# --- 3. schema version is overridable ---
VOUT=$(echo '{"type":"message"}' | SHAI_SCHEMA_VERSION=2.0 "$DIR/shai-stamp")
assert_eq "$(printf '%s' "$VOUT" | jq -r '.version')" "2.0" "stamp: schema version override"

# --- 4. unset vars become explicit nulls (a hand-run pipeline has no ambient context) ---
UOUT=$(printf '%s' '{"type":"message"}' |
  env -u SHAI_RUN_ID -u SHAI_SESSION_ID -u SHAI_SPAN_ID -u SHAI_PARENT_SPAN_ID \
    "$DIR/shai-stamp")
URC=$?
assert_eq "$(printf '%s' "$UOUT" | jq -r '.meta.run_id')" "null" "stamp: unset run_id → null"
assert_eq "$(printf '%s' "$UOUT" | jq -r '.meta.session_id')" "null" "stamp: unset session → null"
assert_eq "$(printf '%s' "$UOUT" | jq -r '.meta.span_id')" "null" "stamp: unset span → null"
assert_eq "$(printf '%s' "$UOUT" | jq -r '.meta.parent_span_id')" "null" "stamp: unset parent → null"
assert_eq "$URC" "0" "stamp: unset vars still exit 0"

# --- 5. malformed input passes through verbatim rather than being dropped ---
BAD=$(printf 'not json at all\n' | "$DIR/shai-stamp")
BRC=$?
assert_eq "$BAD" "not json at all" "stamp: malformed line passed through verbatim"
assert_eq "$BRC" "0" "stamp: malformed line still exit 0"

# --- 6. valid JSON that is not an object also passes through ---
NONOBJ=$(printf '[1,2,3]\n42\n' | "$DIR/shai-stamp")
assert_contains "$NONOBJ" "[1,2,3]" "stamp: JSON array passed through"
assert_contains "$NONOBJ" "42" "stamp: JSON scalar passed through"

# --- 7. nothing is ever dropped, even when mixed ---
MIXED=$(printf '{"a":1}\nGARBAGE\n{"b":2}\n' | "$DIR/shai-stamp" | wc -l)
assert_eq "$MIXED" "3" "stamp: mixed valid/garbage keeps every line"

# --- 8. empty input → empty output, exit 0 ---
EMPTY=$(printf '' | "$DIR/shai-stamp")
ERC=$?
assert_eq "$EMPTY" "" "stamp: empty input → empty output"
assert_eq "$ERC" "0" "stamp: empty input → exit 0"

# --- 9. every line of a multi-line stream is stamped ---
MULTI=$(printf '{"a":1}\n{"b":2}\n{"c":3}\n' | SHAI_RUN_ID=run_m "$DIR/shai-stamp" |
  jq -r '.meta.run_id' | sort -u)
assert_eq "$MULTI" "run_m" "stamp: every line in a multi-line stream stamped"

# --- 10. a final line with no trailing newline is still handled ---
NONL=$(printf '{"z":9}' | SHAI_RUN_ID=run_n "$DIR/shai-stamp" | jq -r '.meta.run_id')
assert_eq "$NONL" "run_n" "stamp: final line without trailing newline processed"

# --- 11. a reader that closes early must not make us exit non-zero ---
printf '{"a":1}\n' | "$DIR/shai-stamp" | true
assert_eq "${PIPESTATUS[1]}" "0" "stamp: SIGPIPE from a closed reader still exits 0"
printf '{"a":1}\n' | "$DIR/shai-stamp" | false
assert_eq "${PIPESTATUS[1]}" "0" "stamp: exit 0 even when the reader fails"

# --- 12. a blank line is DELIBERATELY skipped, not passed through ---
# The one exception to verbatim passthrough: a blank carries no event, and one reaching the tail
# of history.jsonl would make shai-retry's classifier report "nothing to resume" for a resumable
# run. Pinned here so the behavior stays deliberate rather than incidental.
BLANKOUT=$(printf '{"a":1}\n\n{"b":2}\n' | SHAI_RUN_ID=run_blank "$DIR/shai-stamp")
BLANKRC=$?
assert_eq "$(printf '%s\n' "$BLANKOUT" | wc -l)" "2" "stamp: a blank line between events is skipped"
assert_eq "$BLANKRC" "0" "stamp: a blank line still exits 0"
assert_eq "$(printf '%s\n' "$BLANKOUT" | jq -r '.meta.run_id' | sort -u)" "run_blank" \
  "stamp: the surrounding events are still stamped"
assert_eq "$(printf '%s\n' "$BLANKOUT" | jq -sr '[.[].a, .[].b] | map(select(. != null)) | @tsv')" \
  "$(printf '1\t2')" "stamp: skipping a blank drops neither neighbouring event"
# whitespace-only is NOT blank: it is a non-empty non-object line, so it passes through verbatim
WSOUT=$(printf '   \n' | "$DIR/shai-stamp")
assert_eq "$WSOUT" "   " "stamp: a whitespace-only line passes through verbatim"

finish
