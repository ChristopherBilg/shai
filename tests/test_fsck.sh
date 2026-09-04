#!/bin/bash
# test_fsck.sh — tests for shai-fsck store-integrity scanner
# Covers: S4 orphan .latest.json detection, healthy #387-built store reports clean (exit 0),
#         the eight-key finding contract, --json findings array ([] when clean, type+length
#         asserted), table renderer row counts, digest on stderr, --store/--check/--after/
#         --before scoping, --summary, --fix/--dry-run parsing, usage errors (exit 2) with
#         distinct messages, operational failures (exit 3), and the R1-R7 run-store checks
#         (empty/garbled run logs, foreign meta.run_id, span gaps and chain breaks, span
#         dump integrity, uncommitted-run classification via lib/replay.sh including the
#         retry_of half, missing run directories)
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FSCK="$DIR/shai-fsck"

# setup_home: a fresh isolated $SHAI_HOME for one test block, so one block's store can
# never leak into the next block's assertions.
setup_home() {
  export SHAI_HOME
  SHAI_HOME=$(mktemp -d)
  _CLEANUP_DIRS+=("$SHAI_HOME")
}

# orphan_latest <session_id>: a sessions/<id>.latest.json with deliberately no sibling
# sessions/<id>.jsonl — the exact state S4 reports. Content is irrelevant to S4 (pure
# filesystem check), so a minimal JSON object is written.
orphan_latest() {
  mkdir -p "$SHAI_HOME/sessions"
  printf '{}\n' >"$SHAI_HOME/sessions/$1.latest.json"
}

# null_run <event>: the event with meta.run_id nulled. Session-only fixtures use this so
# a run-store scan stays clean: R7 reports any session event whose meta.run_id names a
# run directory that is not on disk, and shai-stamp writes exactly this null shape when
# a pipeline runs without ambient SHAI_RUN_ID.
null_run() { printf '%s\n' "$1" | jq -c '.meta.run_id = null'; }

# --- healthy store built entirely from the #387 fixture builders reports clean, exit 0 ---
# Closes #387's deferred assertion. The builders never stage corruption: fixture_session
# mirrors the log tail into .latest.json (so S4 stays quiet by construction), fixture_run
# and fixture_ledger build their healthy shapes, fixture_failure writes a healthy record.
# The run is committed for R6 (the session log carries the same stamped event, so
# meta.run_id matches) and resolves for R7 (the referenced run directory exists); the
# ledger's backing session carries a null run_id (R7-clean by construction).
desc "healthy store from fixture builders: clean, exit 0"
setup_home
ev="$(fixture_event message user '{"text":"hello"}' run_20260810T120000_aabbccdd)"
fixture_session sess_20260810T120000_aabbccdd "$ev"
fixture_run run_20260810T120000_aabbccdd sess_20260810T120000_aabbccdd "$ev"
fixture_ledger heartbeat k1
fixture_failure heartbeat api_error "HTTP 503 from the API"
OUT=$("$FSCK" 2>/dev/null)
assert_eq "$?" "0" "healthy store exits 0"
assert_eq "$OUT" "no problems found (2 sessions, 1 run, 1 ledger, 1 failure log)" \
  "clean line names every store with its count"
# Mutation check (CLAUDE.md: an expected-zero assertion must be mutation-checked). Break the
# store in the open — one orphan .latest.json — and the same scan goes red. Verified by
# deletion: without the S4 scan the corrupted store still reported clean (exit 0, zero rows).
orphan_latest sess_20260811T120000_eeff0011
OUT=$("$FSCK" 2>/dev/null)
assert_eq "$?" "1" "corrupted store exits 1"
assert_row_count "$OUT" 1 "exactly one finding row for the orphan"

# --- S4: the finding carries the full eight-key contract ---
desc "S4: orphan .latest.json reported through the accumulator, eight-key contract"
setup_home
orphan_latest sess_20260903T043418_67e3340f
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "orphan exits 1 in --json mode"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "one finding in the array"
F=$(printf '%s' "$OUT" | jq '.[0]')
assert_eq "$(printf '%s' "$F" | jq 'keys | length')" "8" "finding has exactly eight keys"
assert_eq "$(printf '%s' "$F" | jq -c 'keys')" \
  '["check","fixable","path","remedy","severity","store","summary","target"]' \
  "finding keys are the contract keys"
assert_eq "$(printf '%s' "$F" | jq -r '.check')" "S4" "check id"
assert_eq "$(printf '%s' "$F" | jq -r '.severity')" "error" "severity"
assert_eq "$(printf '%s' "$F" | jq -r '.store')" "sessions" "store"
assert_eq "$(printf '%s' "$F" | jq -r '.target')" "sess_20260903T043418_67e3340f" \
  "target is the store-relative id"
assert_eq "$(printf '%s' "$F" | jq -r '.path')" \
  "$SHAI_HOME/sessions/sess_20260903T043418_67e3340f.latest.json" \
  "path is the absolute file path"
assert_eq "$(printf '%s' "$F" | jq -r '.summary')" "orphan latest.json (no session log)" \
  "summary"
assert_eq "$(printf '%s' "$F" | jq -r '.fixable')" "true" "fixable"
assert_eq "$(printf '%s' "$F" | jq -r '.remedy')" "delete" "remedy"

# --- table renderer: one row per finding on stdout, digest trailing on stderr ---
desc "table renderer: header + one row per finding; digest on stderr"
setup_home
orphan_latest sess_20260903T043418_67e3340f
OUT=$("$FSCK" 2>/dev/null)
assert_eq "$?" "1" "table mode exits 1"
assert_contains "$OUT" "SEVERITY" "header present"
assert_contains "$OUT" "sess_20260903T043418_67e3340f" "target id in the row"
assert_contains "$OUT" "orphan latest.json (no session log)" "summary in the row"
assert_row_count "$OUT" 1 "one row per finding (no digest on stdout)"
ERR=$("$FSCK" 2>&1 >/dev/null)
assert_contains "$ERR" "1 error, 0 warnings, 0 info — 1 fixable with --fix" \
  "digest on stderr with severity counts and fixable count"

desc "table renderer: two orphans render as two rows, pluralized digest"
setup_home
orphan_latest sess_20260903T043418_67e3340f
orphan_latest sess_20260903T043419_abcdef01
OUT=$("$FSCK" 2>/dev/null)
assert_eq "$?" "1" "two orphans exit 1"
assert_row_count "$OUT" 2 "one row per finding for two findings"
assert_contains "$OUT" "sess_20260903T043418_67e3340f" "first id in the table"
assert_contains "$OUT" "sess_20260903T043419_abcdef01" "second id in the table"
ERR=$("$FSCK" 2>&1 >/dev/null)
assert_contains "$ERR" "2 errors, 0 warnings, 0 info — 2 fixable with --fix" \
  "digest pluralizes"

# --- S4's negative control: a .latest.json with a sibling .jsonl is not an orphan ---
# The healthy-store block above is the positive control; this block pins the sibling test
# directly (fixture_session always writes both files, so no corruption is needed). The
# event's run_id is nulled (null_run) so the store is clean under R7 too — the only
# assertion here is "no finding at all".
desc "S4: .latest.json with a sibling session log is not an orphan"
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(null_run "$(fixture_event message user '{"text":"hello"}')")"
OUT=$("$FSCK" --json)
assert_eq "$?" "0" "paired .latest.json exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "paired .latest.json produces no finding"

# --- --json on a clean store emits [] ---
desc "--json: clean store emits [] (type and length asserted, never a substring)"
setup_home
mkdir -p "$SHAI_HOME/sessions" "$SHAI_HOME/runs" "$SHAI_HOME/ledgers" "$SHAI_HOME/failures"
OUT=$("$FSCK" --json)
assert_eq "$?" "0" "clean store exits 0 in --json mode"
assert_eq "$(printf '%s' "$OUT" | jq 'type')" '"array"' "clean --json output is a JSON array"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "clean --json array has length 0"
assert_eq "$OUT" "[]" "clean --json output is exactly []"

# --- date windowing: inclusive, on the id's embedded date, short-circuiting at the
#     filename level; undated ids drop when a window is active (shai-events semantics) ---
desc "--after/--before: inclusive window on the id's embedded date"
setup_home
orphan_latest sess_20260810T120000_aabbccdd
orphan_latest sess_20260812T120000_eeff0011
OUT=$("$FSCK" --after 2026-08-11 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "after drops the earlier orphan"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].target')" "sess_20260812T120000_eeff0011" \
  "after keeps the later orphan"
OUT=$("$FSCK" --before 2026-08-11 --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].target')" "sess_20260810T120000_aabbccdd" \
  "before keeps the earlier orphan"
OUT=$("$FSCK" --after 2026-08-12 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "--after is inclusive of the bound"
OUT=$("$FSCK" --after 2026-08-10 --before 2026-08-10 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "single-day window is inclusive on both ends"
OUT=$("$FSCK" --after 2026-08-13 --json)
assert_eq "$?" "0" "windowed-away findings exit 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "windowed-away findings are empty"
# Undated ids: reported with no window, dropped when a window is active — the same
# documented shai-events semantics the filename-level short-circuit must match.
orphan_latest weird
OUT=$("$FSCK" --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "3" "undated id reported when no window is set"
OUT=$("$FSCK" --after 2026-01-01 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "undated id dropped when a window is set"

# --- --store scoping: narrows both the scan and the clean-line counts ---
desc "--store: scopes the scan and the clean line"
setup_home
orphan_latest sess_20260810T120000_aabbccdd
# A committed run keeps the runs store clean under R1-R7 (an empty directory would be
# an R1 finding; an uncommitted one an R6 finding).
ev="$(fixture_event message user '{"text":"hi"}' run_20260810T120000_aabbccdd)"
fixture_session sess_20260810T120001_aabbccdd "$ev"
fixture_run run_20260810T120000_aabbccdd sess_20260810T120001_aabbccdd "$ev"
OUT=$("$FSCK" --store sessions --json)
assert_eq "$?" "1" "sessions scope still finds the orphan"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "sessions scope reports one finding"
OUT=$("$FSCK" --store runs 2>/dev/null)
assert_eq "$?" "0" "runs scope ignores the sessions orphan"
assert_eq "$OUT" "no problems found (1 run)" "clean line counts only the selected store"
OUT=$("$FSCK" --store runs --store sessions --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "combined stores scan both"
OUT=$("$FSCK" --store sessions --store sessions --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "a repeated --store does not double the scan"

# --- --check scoping: unknown ids are usage errors; a check disjoint from the selected
#     store scans nothing and the run stays clean ---
desc "--check: catalog scoping and the disjoint-store intersection"
setup_home
orphan_latest sess_20260810T120000_aabbccdd
OUT=$("$FSCK" --check S4 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "--check S4 selects the shipped check"
OUT=$("$FSCK" --check S4 --check S4 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "a repeated --check does not double the scan"
OUT=$("$FSCK" --check S4 --store runs 2>/dev/null)
assert_eq "$?" "0" "a check disjoint from the selected store scans nothing"
assert_eq "$OUT" "no problems found (0 runs)" "disjoint selection reports clean"
assert_fails 2 "error: unknown check id: S9" "unknown check id" -- "$FSCK" --check S9
assert_fails 2 "error: --check requires a check id" "--check missing value" -- "$FSCK" --check

# --- R1: three adjacent shapes — wholly empty (fixable), dumps without a log
#     (not fixable), and a healthy log (no finding), plus the two log-corruption shapes ---
# Each expected-one assertion is mutation-checked: with the ck_R1 dispatch arm deleted
# the scan reports zero findings and every one of these goes red (verified during
# development, then restored).
desc "R1: a wholly empty run directory is the narrow fixable case"
setup_home
mkdir -p "$SHAI_HOME/runs/run_20260903T043418_67e3340f"
OUT=$("$FSCK" --check R1 --json)
assert_eq "$?" "1" "empty run directory exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "one R1 finding"
F=$(printf '%s' "$OUT" | jq '.[0]')
assert_eq "$(printf '%s' "$F" | jq -r '.severity')" "error" "severity error"
assert_eq "$(printf '%s' "$F" | jq -r '.fixable')" "true" "wholly empty directory is fixable"
assert_eq "$(printf '%s' "$F" | jq -r '.remedy')" "delete" "remedy is delete"

desc "R1: dumps without an event log are reported, not fixable"
setup_home
fixture_span_dump run_20260903T043418_67e3340f span_1 request
OUT=$("$FSCK" --check R1 --json)
assert_eq "$?" "1" "dumps-without-log exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "one R1 finding"
F=$(printf '%s' "$OUT" | jq '.[0]')
assert_eq "$(printf '%s' "$F" | jq -r '.fixable')" "false" "dumps are the only trace of a call — not fixable"
assert_contains "$(printf '%s' "$F" | jq -r '.remedy')" "manual" "remedy is a manual instruction"

desc "R1: an empty event log is a finding, not fixable"
setup_home
fixture_run run_20260903T043418_67e3340f sess_20260903T043418_67e3340f
OUT=$("$FSCK" --check R1 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "empty event log is one finding"
F=$(printf '%s' "$OUT" | jq '.[0]')
assert_contains "$(printf '%s' "$F" | jq -r '.summary')" "events.jsonl is empty" "summary names the empty log"
assert_eq "$(printf '%s' "$F" | jq -r '.fixable')" "false" "empty log is not fixable"

desc "R1: a line that does not parse and a non-object line are each one finding"
setup_home
mkdir -p "$SHAI_HOME/runs/run_20260903T043418_67e3340f"
ev="$(fixture_event message user '{"text":"hi"}')"
{ printf '%s\n' "$ev" '{garbage'; } >"$SHAI_HOME/runs/run_20260903T043418_67e3340f/events.jsonl"
OUT=$("$FSCK" --check R1 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "unparseable line is one finding"
assert_contains "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "does not parse as JSON" \
  "summary names the unparseable line"
setup_home
mkdir -p "$SHAI_HOME/runs/run_20260903T043418_67e3340f"
printf '%s\n' '42' >"$SHAI_HOME/runs/run_20260903T043418_67e3340f/events.jsonl"
OUT=$("$FSCK" --check R1 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "non-object line is one finding"
assert_contains "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "line 1 is not a JSON object" \
  "summary names the offending line"

desc "R1: a healthy run log produces no finding (positive control)"
setup_home
fixture_run run_20260903T043418_67e3340f sess_20260903T043418_67e3340f \
  "$(fixture_event message user '{"text":"hi"}')"
OUT=$("$FSCK" --check R1 --json)
assert_eq "$?" "0" "healthy run log exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "healthy run log produces no R1 finding"

# --- R2: meta.run_id must equal the directory name ---
# Mutation-checked: deleting the ck_R2 arm drops the expected-one finding below
# (verified during development).
desc "R2: a foreign meta.run_id in the log is one error finding"
setup_home
ev="$(fixture_event message user '{"text":"hi"}' run_other sess_20260903T043418_67e3340f)"
mkdir -p "$SHAI_HOME/runs/run_20260903T043418_67e3340f"
printf '%s\n' "$ev" | jq -c '.meta.session_id = "sess_20260903T043418_67e3340f"' \
  >"$SHAI_HOME/runs/run_20260903T043418_67e3340f/events.jsonl"
OUT=$("$FSCK" --check R2 --json)
assert_eq "$?" "1" "foreign run_id exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "one R2 finding"
F=$(printf '%s' "$OUT" | jq '.[0]')
assert_eq "$(printf '%s' "$F" | jq -r '.severity')" "error" "severity error"
assert_contains "$(printf '%s' "$F" | jq -r '.summary')" \
  "meta.run_id run_other does not match the run directory" "summary names the foreign run_id"
assert_eq "$(printf '%s' "$F" | jq -r '.fixable')" "false" "R2 is not fixable"

desc "R2: a matching meta.run_id produces no finding (positive control)"
setup_home
fixture_run run_20260903T043418_67e3340f sess_20260903T043418_67e3340f \
  "$(fixture_event message user '{"text":"hi"}')"
OUT=$("$FSCK" --check R2 --json)
assert_eq "$?" "0" "matching run_id exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "matching run_id produces no R2 finding"

# --- R3/R5: span_0 is exempt from both; a missing span_2 is one R3 finding ---
# Both zero-finding halves are mutation-checked at the exemption, not the check: the
# first fixture below (the issue's exact wording — span_0 dump, events starting at
# span_1) goes red when the span_0 skip is removed from ck_R5 (the dump reads as an
# orphan); the second (a span_0 event among the spans) goes red when the `.n > 0`
# exemption is removed from ck_R3's chain check (span_0 reads as a chain member with
# an impossible "span_-1" parent). Both verified during development, then restored.
# The gap finding is mutation-checked by deleting the ck_R3 arm (goes red).
desc "R3/R5: a span_0 dump with events starting at span_1 produces zero findings"
setup_home
ev1="$(fixture_event message user '{"text":"hi"}' run_20260903T043418_67e3340f sess_20260903T043418_67e3340f span_1)"
ev2="$(fixture_event message assistant '{"content":"a"}' run_20260903T043418_67e3340f sess_20260903T043418_67e3340f span_2)"
ev2="$(printf '%s' "$ev2" | jq -c '.meta.parent_span_id = "span_1"')"
fixture_run run_20260903T043418_67e3340f sess_20260903T043418_67e3340f "$ev1" "$ev2"
fixture_span_dump run_20260903T043418_67e3340f span_0 request
OUT=$("$FSCK" --check R3 --check R5 --json)
assert_eq "$?" "0" "span_0 dump fixture exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "span_0 dump is never a gap or an orphan"

desc "R3: a run missing span_2 between span_1 and span_3 is one warning"
setup_home
ev1="$(fixture_event message user '{"text":"hi"}' run_20260903T043418_67e3340f sess_20260903T043418_67e3340f span_1)"
ev3="$(fixture_event message assistant '{"content":"hi"}' run_20260903T043418_67e3340f sess_20260903T043418_67e3340f span_3)"
ev3="$(printf '%s' "$ev3" | jq -c '.meta.parent_span_id = "span_2"')"
fixture_run run_20260903T043418_67e3340f sess_20260903T043418_67e3340f "$ev1" "$ev3"
OUT=$("$FSCK" --check R3 --json)
assert_eq "$?" "1" "gapped run exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one R3 finding"
F=$(printf '%s' "$OUT" | jq '.[0]')
assert_eq "$(printf '%s' "$F" | jq -r '.severity')" "warn" "severity warn"
assert_contains "$(printf '%s' "$F" | jq -r '.summary')" "span_2 missing" "summary names the gap"
assert_eq "$(printf '%s' "$F" | jq -r '.fixable')" "false" "R3 is not fixable"

desc "R3: a span_0 event is never a gap or a chain member"
setup_home
ev0="$(fixture_event message user '{"text":"hand-run"}' run_20260903T043418_67e3340f sess_20260903T043418_67e3340f span_0)"
ev1="$(fixture_event message assistant '{"content":"a"}' run_20260903T043418_67e3340f sess_20260903T043418_67e3340f span_1)"
ev2="$(fixture_event message assistant '{"content":"b"}' run_20260903T043418_67e3340f sess_20260903T043418_67e3340f span_2)"
ev2="$(printf '%s' "$ev2" | jq -c '.meta.parent_span_id = "span_1"')"
fixture_run run_20260903T043418_67e3340f sess_20260903T043418_67e3340f "$ev0" "$ev1" "$ev2"
fixture_span_dump run_20260903T043418_67e3340f span_0 request
OUT=$("$FSCK" --check R3 --check R5 --json)
assert_eq "$?" "0" "span_0 event fixture exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "span_0 event is never a gap or a chain member"

desc "R3: a non-linear parent chain is one finding"
setup_home
ev1="$(fixture_event message user '{"text":"hi"}' run_20260903T043418_67e3340f sess_20260903T043418_67e3340f span_1)"
ev2="$(fixture_event message assistant '{"content":"hi"}' run_20260903T043418_67e3340f sess_20260903T043418_67e3340f span_2)"
ev2="$(printf '%s' "$ev2" | jq -c '.meta.parent_span_id = "span_9"')"
fixture_run run_20260903T043418_67e3340f sess_20260903T043418_67e3340f "$ev1" "$ev2"
OUT=$("$FSCK" --check R3 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "broken chain is one finding"
assert_contains "$(printf '%s' "$OUT" | jq -r '.[0].summary')" \
  "span_2 parent_span_id is span_9 (expected span_1)" "summary names the chain break"

desc "R3: a span id outside the span_N shape is one warning, never silently ignored"
setup_home
ev1="$(fixture_event message user '{"text":"hi"}' run_20260903T043418_67e3340f sess_20260903T043418_67e3340f span_1)"
evx="$(fixture_event message assistant '{"content":"a"}' run_20260903T043418_67e3340f sess_20260903T043418_67e3340f span_1x)"
fixture_run run_20260903T043418_67e3340f sess_20260903T043418_67e3340f "$ev1" "$evx"
OUT=$("$FSCK" --check R3 --json)
assert_eq "$?" "1" "malformed span id exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "one R3 finding"
F=$(printf '%s' "$OUT" | jq '.[0]')
assert_contains "$(printf '%s' "$F" | jq -r '.summary')" \
  "span id span_1x is not in span_N form" "summary names the malformed id"
assert_eq "$(printf '%s' "$F" | jq -r '.severity')" "warn" "severity warn"
assert_eq "$(printf '%s' "$F" | jq -r '.fixable')" "false" "malformed id is not fixable"

# --- R4: span dumps must parse as JSON, never fixable ---
# Mutation-checked: deleting the ck_R4 arm drops the expected-one finding (verified
# during development).
desc "R4: a malformed span dump is one warn finding, never fixable"
setup_home
fixture_span_dump run_20260903T043418_67e3340f span_1 request '{not json'
OUT=$("$FSCK" --check R4 --json)
assert_eq "$?" "1" "malformed dump exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "one R4 finding"
F=$(printf '%s' "$OUT" | jq '.[0]')
assert_eq "$(printf '%s' "$F" | jq -r '.severity')" "warn" "severity warn"
assert_contains "$(printf '%s' "$F" | jq -r '.summary')" \
  "span_1-request.json does not parse as JSON" "summary names the malformed dump"
assert_eq "$(printf '%s' "$F" | jq -r '.fixable')" "false" \
  "a malformed dump is the only record of a failed call — not fixable"

desc "R4: well-formed dumps produce no finding (positive control)"
setup_home
fixture_span_dump run_20260903T043418_67e3340f span_1 request
fixture_span_dump run_20260903T043418_67e3340f span_1 response
OUT=$("$FSCK" --check R4 --json)
assert_eq "$?" "0" "well-formed dumps exit 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "well-formed dumps produce no R4 finding"

# --- R5: an orphan span dump (the audit's defect: span_9 dump, events through span_8) ---
# Mutation-checked: deleting the ck_R5 arm drops the expected-one finding (verified
# during development).
desc "R5: a dump whose span has no event is one fixable orphan finding"
setup_home
evs=()
for i in {1..8}; do
  if [ "$i" -eq 1 ]; then
    ev="$(fixture_event message user '{"text":"hi"}' run_20260903T043418_67e3340f sess_20260903T043418_67e3340f span_1)"
  else
    ev="$(fixture_event message assistant '{"content":"step"}' run_20260903T043418_67e3340f sess_20260903T043418_67e3340f "span_$i")"
    ev="$(printf '%s' "$ev" | jq -c --arg p "span_$((i - 1))" '.meta.parent_span_id = $p')"
  fi
  evs+=("$ev")
done
fixture_run run_20260903T043418_67e3340f sess_20260903T043418_67e3340f "${evs[@]+"${evs[@]}"}"
fixture_span_dump run_20260903T043418_67e3340f span_9 request
OUT=$("$FSCK" --check R5 --json)
assert_eq "$?" "1" "orphan dump exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one R5 finding"
F=$(printf '%s' "$OUT" | jq '.[0]')
assert_contains "$(printf '%s' "$F" | jq -r '.summary')" \
  "span_9-request.json has no matching event in the run log" "summary names the orphan dump"
assert_eq "$(printf '%s' "$F" | jq -r '.fixable')" "true" "orphan dump is fixable"
assert_eq "$(printf '%s' "$F" | jq -r '.remedy')" "delete" "remedy is delete"

# --- R6: committed (including retry_of-only), resumable vs dead ---
# The retry_of zero-finding assertion below is the highest-value test in this issue and
# was mutation-checked the way the issue prescribes: removing the
# `or .meta.retry_of? == $rid` clause from lib/replay.sh makes classify_replay miss the
# commit, the fixture's user message then satisfies precondition 5, the verdict falls
# through to "replayable", and this assertion goes red (verified during development,
# then restored). The resumable/dead expected-ones are mutation-checked by deleting the
# ck_R6 arm (goes red).
desc "R6: events committed only via meta.retry_of are not an uncommitted orphan"
setup_home
ev="$(fixture_event message user '{"text":"again"}')"
rid=$(fixture_run run_20260903T043418_67e3340f sess_20260903T043418_67e3340f "$ev")
# A replay commits under a NEW run id carrying meta.retry_of, so the session log below
# matches the run only via retry_of — no meta.run_id match exists.
retried="$(printf '%s' "$ev" | jq -c --arg new run_20260903T043419_89abcdef --arg rof "$rid" \
  '.meta.run_id = $new | .meta.retry_of = $rof')"
fixture_session sess_20260903T043418_67e3340f "$retried"
OUT=$("$FSCK" --check R6 --json)
assert_eq "$?" "0" "already-retried run exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "retry_of match means committed — no R6 finding"

desc "R6: resumable run is unfixable with the literal resume command; dead run is fixable"
setup_home
rid=$(fixture_run run_20260903T043418_67e3340f sess_20260903T043418_67e3340f \
  "$(fixture_event message user '{"text":"hello"}')")
# An unrelated earlier turn in the session log: the committed probe runs and misses,
# the user message holds — exactly an interrupted-but-resumable run.
fixture_session sess_20260903T043418_67e3340f \
  "$(fixture_event message user '{"text":"older turn"}' run_20260903T043400_00000001)"
OUT=$("$FSCK" --check R6 --json)
assert_eq "$?" "1" "uncommitted resumable run exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "one R6 finding for the resumable run"
F=$(printf '%s' "$OUT" | jq '.[0]')
assert_contains "$(printf '%s' "$F" | jq -r '.summary')" "resumable" "summary subclassifies resumable"
assert_eq "$(printf '%s' "$F" | jq -r '.fixable')" "false" "resumable run is never fixable"
assert_eq "$(printf '%s' "$F" | jq -r '.remedy')" "shai-retry --run $rid" \
  "remedy is the literal resume command"
# Adjacent: no user message anywhere in the log — the run is dead and deletable.
setup_home
fixture_run run_20260903T043419_89abcdef sess_20260903T043419_89abcdef \
  "$(fixture_event error system '{"text":"timeout"}')"
OUT=$("$FSCK" --check R6 --json)
assert_eq "$?" "1" "dead run exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "one R6 finding for the dead run"
F=$(printf '%s' "$OUT" | jq '.[0]')
assert_contains "$(printf '%s' "$F" | jq -r '.summary')" "dead" "summary subclassifies dead"
assert_eq "$(printf '%s' "$F" | jq -r '.fixable')" "true" "dead run is fixable"
assert_eq "$(printf '%s' "$F" | jq -r '.remedy')" "delete" "remedy is delete"

desc "R6: a session id shai-retry would refuse is one unfixable finding naming the id"
setup_home
fixture_run run_20260903T043418_67e3340f "sess/../20260903T043418_67e3340f" \
  "$(fixture_event message user '{"text":"hello"}')"
OUT=$("$FSCK" --check R6 --json)
assert_eq "$?" "1" "unsafe session id exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "one R6 finding for the unsafe session id"
F=$(printf '%s' "$OUT" | jq '.[0]')
assert_contains "$(printf '%s' "$F" | jq -r '.summary')" \
  "session id in the run log is unsafe" "summary names the unsafe verdict"
assert_contains "$(printf '%s' "$F" | jq -r '.summary')" "sess/../20260903T043418_67e3340f" \
  "summary interpolates the offending session id"
assert_eq "$(printf '%s' "$F" | jq -r '.fixable')" "false" "unsafe session id is never fixable"
assert_contains "$(printf '%s' "$F" | jq -r '.remedy')" "manual" "remedy is manual"

# --- R7: session references must have a run directory on disk (info, never fixable) ---
# Mutation-checked: removing the scan loop's missing-runs/ exception (the path R7
# fires through when runs/ is absent — its dispatch arm never runs then) drops the
# expected-one finding below (verified during development, then restored).
desc "R7: a session event referencing a missing run directory is one info finding"
setup_home
fixture_session sess_20260903T043418_67e3340f \
  "$(fixture_event message user '{"text":"hi"}' run_20260903T043418_67e3340f)"
OUT=$("$FSCK" --check R7 --json)
assert_eq "$?" "1" "missing run directory exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "one R7 finding"
F=$(printf '%s' "$OUT" | jq '.[0]')
assert_eq "$(printf '%s' "$F" | jq -r '.severity')" "info" "R7 is info, not a defect"
assert_eq "$(printf '%s' "$F" | jq -r '.target')" "run_20260903T043418_67e3340f" \
  "target is the missing run id"
assert_eq "$(printf '%s' "$F" | jq -r '.fixable')" "false" "R7 is never fixable"
assert_contains "$(printf '%s' "$F" | jq -r '.summary')" "run directory missing" \
  "summary explains the missing directory"
OUT=$("$FSCK" --check R7 --summary)
assert_eq "$OUT" "0 errors, 0 warnings, 1 info — 0 fixable with --fix" \
  "digest counts R7 as info"

desc "R7: a referenced run directory on disk produces no finding (positive control)"
setup_home
ev="$(fixture_event message user '{"text":"hi"}' run_20260903T043418_67e3340f)"
fixture_session sess_20260903T043418_67e3340f "$ev"
fixture_run run_20260903T043418_67e3340f sess_20260903T043418_67e3340f "$ev"
OUT=$("$FSCK" --check R7 --json)
assert_eq "$?" "0" "referenced run directory exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "referenced run directory produces no R7 finding"

desc "R7: run ids containing / or .. are skipped; a plain missing id is still reported"
setup_home
fixture_session sess_20260903T043418_67e3340f \
  "$(fixture_event message user '{"text":"hi"}' "run/20260903T043418_67e3340f")" \
  "$(fixture_event message user '{"text":"hi"}' run_..20260903T043418_67e3340f)" \
  "$(fixture_event message user '{"text":"hi"}' run_20260903T043419_89abcdef)"
OUT=$("$FSCK" --check R7 --json)
assert_eq "$?" "1" "plain missing id still exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "traversal ids are skipped — exactly one finding"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].target')" "run_20260903T043419_89abcdef" \
  "the plain missing id is the finding"

# The sessions-dir readability guard ck_R7 carries on the --store runs path is the same
# chmod-only shape as the per-store guard (documented at the operational-failures block
# below): not driven, for the same reason. The jq half IS driven — a malformed session
# log is platform-producible corruption, and it must read as exit 3, never as a
# false-clean R7 report.
desc "R7: an unparseable session log aborts the scan (exit 3), never a false-clean report"
setup_home
fixture_session sess_20260903T043418_67e3340f \
  "$(fixture_event message user '{"text":"hi"}' run_20260903T043418_67e3340f)"
printf '{truncated\n' >>"$SHAI_HOME/sessions/sess_20260903T043418_67e3340f.jsonl"
assert_fails 3 "unreadable or unparseable" "unparseable session log exits 3" \
  -- "$FSCK" --check R7

# --- R6 in table mode: one row per finding, the resume command printed in the report ---
desc "R6 table mode: resumable and dead render two rows; digest counts the fixable one"
setup_home
fixture_run run_20260903T043418_67e3340f sess_a "$(fixture_event message user '{"text":"hi"}')"
fixture_run run_20260903T043419_89abcdef sess_b "$(fixture_event error system '{"text":"boom"}')"
OUT=$("$FSCK" --check R6 2>/dev/null)
assert_eq "$?" "1" "two uncommitted runs exit 1"
assert_row_count "$OUT" 2 "one row per finding"
assert_contains "$OUT" "shai-retry --run run_20260903T043418_67e3340f" \
  "resume command printed in the report"
ERR=$("$FSCK" --check R6 2>&1 >/dev/null)
assert_contains "$ERR" "0 errors, 2 warnings, 0 info — 1 fixable with --fix" \
  "digest counts only the dead run fixable"

# --- --check R1..R7: every run check selects and runs alone on a healthy store ---
# Each zero here is pinned by the check's corrupt-fixture block above (deleting a check
# leaves these green but turns its expected-one block red), so these assertions cover
# the selectability criterion without needing a per-check deletion pass.
desc "--check R1..R7: each run check runs alone"
setup_home
ev="$(fixture_event message user '{"text":"hi"}' run_20260903T043418_67e3340f)"
fixture_session sess_20260903T043418_67e3340f "$ev"
fixture_run run_20260903T043418_67e3340f sess_20260903T043418_67e3340f "$ev"
for c in R1 R2 R3 R4 R5 R6 R7; do
  OUT=$("$FSCK" --check "$c" --json)
  assert_eq "$?" "0" "--check $c runs alone on a healthy store"
  assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "--check $c reports zero findings on a healthy run"
done

# --- --summary: the digest alone, exit 1 when problems exist ---
desc "--summary: digest only, no rows"
setup_home
orphan_latest sess_20260903T043418_67e3340f
OUT=$("$FSCK" --summary)
assert_eq "$?" "1" "summary mode exits 1 with findings"
assert_eq "$OUT" "1 error, 0 warnings, 0 info — 1 fixable with --fix" \
  "summary mode prints only the digest"
ERR=$("$FSCK" --summary 2>&1 >/dev/null)
assert_eq "$ERR" "" "summary mode keeps stderr quiet"
# Clean store: the digest case reports the distinctive clean line, still exit 0.
# null_run keeps the session-only fixture clean under R7 (no run directory exists).
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(null_run "$(fixture_event message user '{"text":"hello"}')")"
OUT=$("$FSCK" --summary)
assert_eq "$?" "0" "clean summary mode exits 0"
assert_eq "$OUT" "no problems found (1 session, 0 runs, 0 ledgers, 0 failure logs)" \
  "clean summary mode prints the clean line"

# --- --fix/--dry-run: parsed and validated, no behaviour yet ---
desc "--fix/--dry-run: parsed and validated only — nothing is modified"
setup_home
orphan_latest sess_20260810T120000_aabbccdd
OUT=$("$FSCK" --fix 2>/dev/null)
assert_eq "$?" "1" "--fix still reports the findings"
assert_row_count "$OUT" 1 "--fix table still has one row"
assert_eq "$([ -e "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.latest.json" ] && echo yes || echo no)" \
  "yes" "--fix does not delete anything yet"
ERR=$("$FSCK" --fix 2>&1 >/dev/null)
assert_contains "$ERR" "warning: --fix is parsed but not implemented yet" \
  "--fix warns that its behaviour lands later"
OUT=$("$FSCK" --fix --dry-run 2>/dev/null)
assert_eq "$?" "1" "--fix --dry-run is a valid combination"
assert_row_count "$OUT" 1 "--fix --dry-run still reports one row"
assert_fails 2 "error: --dry-run requires --fix" "--dry-run without --fix" -- "$FSCK" --dry-run

# --- the out-of-scope pointer: policy.json/ci.json stay shai-doctor's, table mode only ---
desc "scope pointer: policy.json and ci.json validation is pointed at shai-doctor"
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(null_run "$(fixture_event message user '{"text":"hello"}')")"
ERR=$("$FSCK" 2>&1 >/dev/null)
assert_contains "$ERR" "validated by shai-doctor" \
  "table mode points policy/ci validation at shai-doctor"
# Paired negative: --json keeps both streams to the array contract, so the note must not
# leak into stderr either (a JSON consumer composes shai-fsck --json with jq).
ERR=$("$FSCK" --json 2>&1 >/dev/null)
assert_not_contains "$ERR" "validated by shai-doctor" \
  "json mode carries no human notes on stderr"

# --- usage errors: exit 2, each branch asserting its own distinct message ---
desc "usage errors: exit 2 with distinct messages"
assert_fails 2 "error: unknown option: --bogus" "unknown flag" -- "$FSCK" --bogus
assert_fails 2 "error: --store requires one of: sessions, runs, ledgers, failures" \
  "--store missing value" -- "$FSCK" --store
assert_fails 2 "error: unknown store: bogus" "unknown store" -- "$FSCK" --store bogus
assert_fails 2 "error: --after requires a date (YYYY-MM-DD)" "--after missing value" -- "$FSCK" --after
assert_fails 2 "error: --after date must be YYYY-MM-DD" "--after malformed date" -- "$FSCK" --after 20260810
assert_fails 2 "error: --before requires a date (YYYY-MM-DD)" "--before missing value" -- "$FSCK" --before
assert_fails 2 "error: --before date must be YYYY-MM-DD" "--before malformed date" -- "$FSCK" --before 2026/08/10
assert_fails 2 "error: --summary cannot be combined with --json" "--summary with --json" -- "$FSCK" --summary --json

# --- operational failures: exit 3, driven directly at the guards ---
# CLAUDE.md: guard branches get unit tests, not integration tests — point the guards at
# inputs that cannot be produced by the platform (an absent SHAI_HOME, a SHAI_HOME that is
# a file, a PATH without jq) instead of trying to provoke them through a real store.
# The two readability guards — SHAI_HOME -r/-x (shai-fsck:146) and the per-store dir
# -r/-x (shai-fsck:239) — are deliberately not driven: the only way to make an existing
# path unreadable is chmod, and root CI reads through any mode bits, so such an assertion
# would pass vacuously there and flip green/red by runner user. Documented here rather
# than "fixed" into vacuity.
desc "operational failures: exit 3"
D="$(mktemp -d)"
_CLEANUP_DIRS+=("$D")
assert_fails 3 "error: SHAI_HOME does not exist" "absent SHAI_HOME" -- env SHAI_HOME="$D/nope" "$FSCK"
touch "$D/afile"
assert_fails 3 "error: SHAI_HOME is not a directory" "SHAI_HOME is a file" -- env SHAI_HOME="$D/afile" "$FSCK"
make_stub_bin
assert_fails 3 "error: jq is required but was not found on PATH" "jq missing from PATH" -- env PATH="$STUB" "$FSCK"

finish
