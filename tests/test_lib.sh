#!/bin/bash
# test_lib.sh — unit tests for the assertion helpers and fixture builders in tests/lib.sh
# Covers: assert_fails — empty-fragment usage error, command skipped, literal fragment match;
#         assert_row_count — blank/whitespace-only output is 0 rows, header excluded, exact
#                            count enforced;
#         fixture builders — fixture_session (.latest.json mirroring the tail), fixture_run,
#                            fixture_span_dump, fixture_ledger, fixture_failure output shape
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# setup_fixture_home: a fresh isolated $SHAI_HOME for a fixture-builder test block, so one
# block's store can never leak into the next block's assertions.
setup_fixture_home() {
  export SHAI_HOME
  SHAI_HOME=$(mktemp -d)
  _CLEANUP_DIRS+=("$SHAI_HOME")
}

# --- empty stderr fragment: usage error that flips FAILED and skips the command ---
# Pins issue #349's acceptance criterion: a regression back to the tautological
# `assert_contains "$err" ""` must turn this suite red instead of staying green.
desc "assert_fails: empty fragment is a usage error"
D="$(mktemp -d)"
_CLEANUP_DIRS+=("$D")
(
  FAILED=0
  assert_fails 1 "" "empty fragment usage error" -- touch "$D/ran"
  exit "$FAILED"
)
assert_eq "$?" "1" "empty fragment flips FAILED and returns non-zero"
RC=0
[ -e "$D/ran" ] && RC=1
assert_eq "$RC" "0" "command is not run on the usage error"

# --- fragments containing glob metacharacters are matched literally ---
# assert_contains matches `[[ $1 == *"$2"* ]]`; the quoted "$2" is a literal string, not a
# pattern (bash: "Any part of the pattern may be quoted to force the quoted portion to be
# matched as a string"). Pin that so a fragment like the real
# `([A-Za-z_][A-Za-z0-9_]*)` at tools/ci/run.sh:199 can never false-pass on unrelated stderr.
desc "assert_fails: glob metacharacters in the fragment match literally"
(
  FAILED=0
  assert_fails 1 'bad [x]*?' "metacharacter fragment" -- bash -c 'printf "%s\n" "bad [x]*?" >&2; exit 1'
  exit "$FAILED"
)
assert_eq "$?" "0" "fragment with [ * ? matches the identical literal stderr"

desc "assert_fails: glob-style fragment cannot match unrelated stderr (inner ✗ expected)"
(
  FAILED=0
  assert_fails 1 '[A-Za-z_][A-Za-z0-9_]*' "glob-style fragment" -- bash -c 'printf "%s\n" "foo" >&2; exit 1'
  exit "$FAILED"
)
assert_eq "$?" "1" "a glob-interpreted fragment would false-pass; literal match fails"

# --- assert_row_count: blank output is 0 rows, header excluded, count must be exact ---
# This suite runs each failing-direction probe in a subshell so the inner ✗ (which flips
# FAILED) is itself the assertion. A counting helper that cannot fail is the exact defect
# this helper exists to prevent (CLAUDE.md, "no unfalsifiable assertions").
desc "assert_row_count: blank output counts as 0 rows"
(
  FAILED=0
  assert_row_count "" 0 "blank output is 0 rows"
  exit "$FAILED"
)
assert_eq "$?" "0" "blank output with expected 0 passes"

desc "assert_row_count: blank output is red when a nonzero count is expected (inner ✗ expected)"
(
  FAILED=0
  assert_row_count "" 1 "blank output cannot be 1 row"
  exit "$FAILED"
)
assert_eq "$?" "1" "blank output with expected 1 flips FAILED"

desc "assert_row_count: whitespace-only output counts as 0 rows"
(
  FAILED=0
  assert_row_count $'\n' 0 "whitespace-only output is 0 rows"
  exit "$FAILED"
)
assert_eq "$?" "0" "whitespace-only output with expected 0 passes"

desc "assert_row_count: whitespace-only output is red when a nonzero count is expected (inner ✗ expected)"
(
  FAILED=0
  assert_row_count $'\n' 1 "whitespace-only output cannot be 1 row"
  exit "$FAILED"
)
assert_eq "$?" "1" "whitespace-only output with expected 1 flips FAILED"

desc "assert_row_count: header-only output counts as 0 rows"
(
  FAILED=0
  assert_row_count "SESSION" 0 "header-only table has 0 data rows"
  exit "$FAILED"
)
assert_eq "$?" "0" "header line alone counts as 0"

desc "assert_row_count: header excluded, one data row"
(
  FAILED=0
  assert_row_count $'SESSION\tSTARTED\nsess_1\t2026-08-11 12:00' 1 "one data row below the header"
  exit "$FAILED"
)
assert_eq "$?" "0" "header + 1 data row counts as 1"

desc "assert_row_count: count off by one goes red (inner ✗ expected)"
(
  FAILED=0
  assert_row_count $'SESSION\tSTARTED\nsess_1\t2026-08-11 12:00' 2 "two rows when only one exists"
  exit "$FAILED"
)
assert_eq "$?" "1" "an over-counted table flips FAILED"

# --- fixture_session: healthy session with a .latest.json mirroring the log's tail ---
# The flagship shape from the issue: events stamped with fixture_event's *default* ids
# must still produce a healthy session, because the builder rewrites meta.session_id to
# the declared id (S3 by construction). The .latest.json comparison is a real content
# comparison (jq -S both sides), never a presence check — a builder that wrote an empty
# or stale latest must go red.
desc "fixture_session: .latest.json is JSON-equal to the log's tail, not merely present"
setup_fixture_home
E1="$(fixture_event message user '{"text":"hi"}')"
E2="$(fixture_event message assistant '{"content":"yo","finish_reason":"stop"}')"
OUT=$(fixture_session sess_a "$E1" "$E2")
assert_eq "$OUT" "sess_a" "prints the resolved session id"
assert_eq "$(jq -s 'length' "$SHAI_HOME/sessions/sess_a.jsonl")" "2" "jsonl holds both events"
assert_eq "$(jq -sr '.[0].meta.session_id' "$SHAI_HOME/sessions/sess_a.jsonl")" "sess_a" \
  "meta.session_id is rewritten to the session id (S3 by construction)"
assert_eq "$(jq -S -c . "$SHAI_HOME/sessions/sess_a.latest.json")" \
  "$(tail -n1 "$SHAI_HOME/sessions/sess_a.jsonl" | jq -S -c .)" \
  ".latest.json is JSON-equal to the last event (jq -S both sides)"
RC=0
[ "$(jq -S -c . "$SHAI_HOME/sessions/sess_a.latest.json")" = "$(head -n1 "$SHAI_HOME/sessions/sess_a.jsonl" | jq -S -c .)" ] && RC=1
assert_eq "$RC" "0" ".latest.json is not the first event (it mirrors the tail, not any event)"

desc "fixture_session: zero events creates the empty pair"
setup_fixture_home
fixture_session sess_empty >/dev/null
assert_eq "$(jq -s 'length' "$SHAI_HOME/sessions/sess_empty.jsonl")" "0" "jsonl is empty"
assert_eq "$(wc -c <"$SHAI_HOME/sessions/sess_empty.latest.json" | tr -d ' ')" "0" \
  ".latest.json is empty"

desc "fixture_session: omitted id mints a real-shaped sess_<ts>_<hex> id"
setup_fixture_home
SID=$(fixture_session "" "$(fixture_event message user '{"text":"minted"}')")
RC=0
[[ "$SID" =~ ^sess_[0-9]{8}T[0-9]{6}_[0-9a-f]{8}$ ]] || RC=1
assert_eq "$RC" "0" "minted id matches the real sess_YYYYMMDDTHHMMSS_<8hex> shape"
assert_eq "$(jq -s 'length' "$SHAI_HOME/sessions/$SID.jsonl")" "1" "minted session's log holds the event"

# --- fixture_run: run log with the declared ids written into the envelope ---
desc "fixture_run: events.jsonl with run_id/session_id normalized into each event"
setup_fixture_home
RID=$(fixture_run run_x sess_a \
  "$(fixture_event message user '{"text":"q"}')" \
  "$(fixture_event message assistant '{"content":"a","finish_reason":"stop"}')")
assert_eq "$RID" "run_x" "prints the resolved run id"
assert_eq "$(jq -s 'length' "$SHAI_HOME/runs/run_x/events.jsonl")" "2" "run log holds both events"
assert_eq "$(jq -sr '.[0].meta.run_id' "$SHAI_HOME/runs/run_x/events.jsonl")" "run_x" \
  "meta.run_id is rewritten to the directory name (R2 by construction)"
assert_eq "$(jq -sr '.[0].meta.session_id' "$SHAI_HOME/runs/run_x/events.jsonl")" "sess_a" \
  "meta.session_id is rewritten to the declared session id"
assert_eq "$(jq -sr '.[1].meta.span_id' "$SHAI_HOME/runs/run_x/events.jsonl")" "span_1" \
  "span ids are left as stamped (span structure is the caller's to set)"

desc "fixture_run: omitted ids mint real-shaped run_/sess_ ids"
setup_fixture_home
RID=$(fixture_run "" "" "$(fixture_event message user '{"text":"q"}')")
RC=0
[[ "$RID" =~ ^run_[0-9]{8}T[0-9]{6}_[0-9a-f]{8}$ ]] || RC=1
assert_eq "$RC" "0" "minted run id matches the real run_YYYYMMDDTHHMMSS_<8hex> shape"
assert_eq "$(jq -s 'length' "$SHAI_HOME/runs/$RID/events.jsonl")" "1" "minted run log holds the event"

# --- fixture_span_dump: span dumps with a fail-closed kind ---
desc "fixture_span_dump: request and response dumps, explicit and default json"
setup_fixture_home
fixture_span_dump run_x span_1 request '{"model":"m","messages":[{"role":"user","content":"q"}]}'
fixture_span_dump run_x span_1 response '{"message_id":"m1","model":"m","usage":{},"finish_reason":"stop","latency_ms":1}'
assert_eq "$(jq -r '.model' "$SHAI_HOME/runs/run_x/span_1-request.json")" "m" \
  "request dump written at the <span>-request.json filename"
assert_eq "$(jq -r '.message_id' "$SHAI_HOME/runs/run_x/span_1-response.json")" "m1" \
  "response dump written at the <span>-response.json filename"
fixture_span_dump run_x span_2 request
fixture_span_dump run_x span_2 response
assert_eq "$(jq -r '.model' "$SHAI_HOME/runs/run_x/span_2-request.json")" "test-model" \
  "omitted json defaults to a well-formed request dump"
assert_eq "$(jq -r '.message_id' "$SHAI_HOME/runs/run_x/span_2-response.json")" "m1" \
  "omitted json defaults to a well-formed response dump"

desc "fixture_span_dump: a third kind is a usage error that writes nothing"
setup_fixture_home
(
  fixture_span_dump run_x span_1 requets '{}' 2>/dev/null
  exit "$?"
)
assert_eq "$?" "1" "unknown kind returns non-zero"
assert_eq "$([ -e "$SHAI_HOME/runs/run_x/span_1-requets.json" ] && echo yes || echo no)" "no" \
  "no file is written for the typo'd kind"

# --- fixture_ledger: entries referencing a real backing session ---
desc "fixture_ledger: well-formed entries referencing a real backing session"
setup_fixture_home
SID=$(fixture_ledger heartbeat k1 k2)
assert_eq "$(jq -s 'length' "$SHAI_HOME/ledgers/heartbeat.jsonl")" "2" "one line per key"
assert_eq "$(jq -sr '.[0].key' "$SHAI_HOME/ledgers/heartbeat.jsonl")" "k1" "first entry's key"
assert_eq "$(jq -sr '.[1].key' "$SHAI_HOME/ledgers/heartbeat.jsonl")" "k2" "second entry's key"
assert_eq "$(jq -sr '.[0].session_id' "$SHAI_HOME/ledgers/heartbeat.jsonl")" "$SID" \
  "entries reference the printed backing session id"
RC=0
[[ "$SID" =~ ^sess_[0-9]{8}T[0-9]{6}_[0-9a-f]{8}$ ]] || RC=1
assert_eq "$RC" "0" "backing session id is real-shaped"
assert_eq "$(jq -sr '.[0].ts' "$SHAI_HOME/ledgers/heartbeat.jsonl" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')" "1" \
  "ts is ISO-8601 shaped"
assert_eq "$([ -f "$SHAI_HOME/sessions/$SID.jsonl" ] && [ -f "$SHAI_HOME/sessions/$SID.latest.json" ] && echo yes)" "yes" \
  "backing session pair exists (fsck L3 resolves)"
assert_eq "$(jq -S -c . "$SHAI_HOME/sessions/$SID.latest.json")" \
  "$(tail -n1 "$SHAI_HOME/sessions/$SID.jsonl" | jq -S -c .)" \
  "backing session's .latest.json matches its tail (healthy, not stillborn)"

desc "fixture_ledger: zero keys creates the empty ledger with its backing session"
setup_fixture_home
SID=$(fixture_ledger heartbeat)
assert_eq "$(jq -s 'length' "$SHAI_HOME/ledgers/heartbeat.jsonl")" "0" "no keys means zero entries"
assert_eq "$([ -f "$SHAI_HOME/sessions/$SID.jsonl" ] && echo yes)" "yes" "backing session still created"

# --- fixture_failure: all seven documented keys, one record per call ---
desc "fixture_failure: all seven documented keys, appending one record per call"
setup_fixture_home
fixture_failure heartbeat api_error "boom"
assert_eq "$(jq -s 'length' "$SHAI_HOME/failures/heartbeat.jsonl")" "1" "one record per call"
assert_eq "$(jq -sr '.[0] | keys | sort | join(",")' "$SHAI_HOME/failures/heartbeat.jsonl")" \
  "category,context,run_id,session_id,summary,ts,workflow" "exactly the seven documented keys"
assert_eq "$(jq -sr '.[0].workflow' "$SHAI_HOME/failures/heartbeat.jsonl")" "heartbeat" "workflow field"
assert_eq "$(jq -sr '.[0].category' "$SHAI_HOME/failures/heartbeat.jsonl")" "api_error" "category field"
assert_eq "$(jq -sr '.[0].summary' "$SHAI_HOME/failures/heartbeat.jsonl")" "boom" "summary field"
assert_eq "$(jq -sr '.[0].run_id' "$SHAI_HOME/failures/heartbeat.jsonl")" "null" \
  "run_id null without trace context (as fail_record writes)"
assert_eq "$(jq -sr '.[0].session_id' "$SHAI_HOME/failures/heartbeat.jsonl")" "null" \
  "session_id null without trace context"
assert_eq "$(jq -sr '.[0].context | type' "$SHAI_HOME/failures/heartbeat.jsonl")" "object" \
  "context is a JSON object"
assert_eq "$(jq -sr '.[0].ts' "$SHAI_HOME/failures/heartbeat.jsonl" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')" "1" \
  "ts is ISO-8601 shaped"
fixture_failure heartbeat dispatch_error "d2"
assert_eq "$(jq -s 'length' "$SHAI_HOME/failures/heartbeat.jsonl")" "2" \
  "a second call appends, it does not truncate the first record"

finish
