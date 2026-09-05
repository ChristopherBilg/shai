#!/bin/bash
# test_fsck.sh — tests for shai-fsck store-integrity scanner
# Covers: S4 orphan .latest.json detection, S1-S3/S5-S9 session-store contract checks,
#         healthy #387-built store reports clean (exit 0), the eight-key finding contract,
#         --json findings array ([] when clean, type+length asserted), table renderer row
#         counts, digest on stderr, --store/--check/--after/--before scoping, --summary,
#         --fix/--dry-run repairs (the dedicated log-preservation safety test, per-repair
#         pairs for the six fixable classes, rescan-clean with the unfixable contrast,
#         idempotency, R6's resumable-run protection, scoping, the dry-run/fix plan
#         identity, exit codes 0/1/3), usage errors (exit 2) with distinct messages,
#         operational failures (exit 3), the R1-R7 run-store checks (empty/garbled run
#         logs, foreign meta.run_id, span gaps and chain breaks, span dump integrity,
#         uncommitted-run classification via lib/replay.sh including the retry_of half,
#         missing run directories), L1-L4 ledger checks, F1-F4 failure checks, X1
#         cross-store name patterns, and every check id running alone
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

# sess_event <type> <source> <payload> [...]: fixture_event for a session-store fixture —
# the same stamped event with its meta.run_id nulled, the shape shai-stamp writes when a
# pipeline runs without an ambient SHAI_RUN_ID. fixture_event defaults run_id to the
# placeholder "run_test" and a session-only fixture never builds runs/run_test, so without
# the null every session-store block would also report an R7 info finding (a session event
# whose meta.run_id has no run directory on disk) for a reference it never meant to make.
# Session-store assertions stay full-store scans this way, rather than being narrowed to
# --store sessions to hide the extra row.
sess_event() { fixture_event "$@" | jq -c '.meta.run_id = null'; }

# build_sink: nine sessions, one per check id, each corrupt in exactly one way — the
# isolation store for the --check loop below. Every corruption is staged in the open:
# fixture builders produce the healthy shape first, then exactly one break is applied, so
# a full scan of the sink must report exactly one finding per check id.
build_sink() {
  local ev tmp
  mkdir -p "$SHAI_HOME/sessions"
  # S1: healthy event plus a garbage line (line 2 is not a JSON object)
  ev="$(sess_event message user '{"text":"a"}')"
  fixture_session sess_s1 "$ev"
  printf 'not json\n' >>"$SHAI_HOME/sessions/sess_s1.jsonl"
  # S2: an event with its source key deleted (log and latest rewritten together)
  ev="$(sess_event message user '{"text":"b"}')"
  fixture_session sess_s2 "$ev"
  tmp="$(mktemp)"
  jq -c 'del(.source)' "$SHAI_HOME/sessions/sess_s2.jsonl" >"$tmp"
  mv "$tmp" "$SHAI_HOME/sessions/sess_s2.jsonl"
  cp "$SHAI_HOME/sessions/sess_s2.jsonl" "$SHAI_HOME/sessions/sess_s2.latest.json"
  # S3: first of two events stamped with the wrong session id (latest still mirrors the
  #     untouched second event)
  fixture_session sess_s3 \
    "$(sess_event message user '{"text":"c1"}')" \
    "$(sess_event message user '{"text":"c2"}')"
  tmp="$(mktemp)"
  head -n 1 "$SHAI_HOME/sessions/sess_s3.jsonl" | jq -c '.meta.session_id = "elsewhere"' >"$tmp"
  sed -n '2p' "$SHAI_HOME/sessions/sess_s3.jsonl" >>"$tmp"
  mv "$tmp" "$SHAI_HOME/sessions/sess_s3.jsonl"
  # S4: an orphan .latest.json
  orphan_latest sess_s4
  # S5: three events with an empty .latest.json (multi-event, so never stillborn)
  fixture_session sess_s5 \
    "$(sess_event message user '{"text":"d"}')" \
    "$(sess_event message assistant '{"content":"hi","tool_calls":[],"finish_reason":"stop"}')" \
    "$(sess_event message user '{"text":"e"}')"
  : >"$SHAI_HOME/sessions/sess_s5.latest.json"
  # S6: the stillborn pair — one system event, empty .latest.json
  fixture_session sess_s6 "$(sess_event message system '{"text":"seed"}')"
  : >"$SHAI_HOME/sessions/sess_s6.latest.json"
  # S7: a tool_result whose id no preceding assistant event announced
  fixture_session sess_s7 \
    "$(sess_event message assistant '{"content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"list_directory","arguments":"{}"}}],"finish_reason":"tool_calls"}')" \
    "$(sess_event tool_result tool '{"tool_call_id":"ghost","content":"nope","is_error":false}')"
  # S8: an unanswered tool call on an earlier assistant event (the final assistant has none)
  fixture_session sess_s8 \
    "$(sess_event message user '{"text":"f"}')" \
    "$(sess_event message assistant '{"content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"list_directory","arguments":"{}"}}],"finish_reason":"tool_calls"}')" \
    "$(sess_event message assistant '{"content":"done","tool_calls":[],"finish_reason":"stop"}')"
  # S9: an unrecognized schema version
  ev="$(sess_event message user '{"text":"g"}')"
  fixture_session sess_s9 "$ev"
  tmp="$(mktemp)"
  jq -c '.version = "0.9"' "$SHAI_HOME/sessions/sess_s9.jsonl" >"$tmp"
  mv "$tmp" "$SHAI_HOME/sessions/sess_s9.jsonl"
  cp "$SHAI_HOME/sessions/sess_s9.jsonl" "$SHAI_HOME/sessions/sess_s9.latest.json"
}

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
# event's run_id is nulled (sess_event) so the store is clean under R7 too — the only
# assertion here is "no finding at all".
desc "S4: .latest.json with a sibling session log is not an orphan"
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"hello"}')"
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
# Z1 is deliberately outside every shipped family (S/R/L/F/X): an id a later issue might
# ship — an earlier revision of this assertion used S9, then R1 — turns this test green by
# accident the moment that check lands.
assert_fails 2 "error: unknown check id: Z1" "unknown check id" -- "$FSCK" --check Z1
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

# A malformed session line belongs to S1, not to R7: R7 reads the file's parseable lines
# and keeps reporting their references, because aborting would discard S1's finding along
# with them and turn a reported problem into "the check never ran". The read-failure half
# of ck_R7's guard is the same chmod-only shape as the per-store readability guard
# (documented at the operational-failures block below): not driven, for the same reason.
desc "R7: a malformed session log does not abort the scan — S1 owns that report"
setup_home
fixture_session sess_20260903T043418_67e3340f \
  "$(fixture_event message user '{"text":"hi"}' run_20260903T043418_67e3340f)"
printf '{truncated\n' >>"$SHAI_HOME/sessions/sess_20260903T043418_67e3340f.jsonl"
OUT=$("$FSCK" --check R7 --json)
assert_eq "$?" "1" "the parseable line's reference is still reported"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "one R7 finding, not an aborted scan"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].target')" "run_20260903T043418_67e3340f" \
  "the run reference on the parseable line is the finding"
# Positive control for the division of labour, adjacent so the contrast is visible: the
# same store scanned under S1 reports the malformed line itself.
OUT=$("$FSCK" --check S1 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "S1 reports the malformed line"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "line 2 is not a JSON object" \
  "the malformed line is S1's finding, named by line"

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
# sess_event keeps the session-only fixture clean under R7 (no run directory exists).
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"hello"}')"
OUT=$("$FSCK" --summary)
assert_eq "$?" "0" "clean summary mode exits 0"
assert_eq "$OUT" "no problems found (1 session, 0 runs, 0 ledgers, 0 failure logs)" \
  "clean summary mode prints the clean line"

# --- --fix/--dry-run: the full repair suite lives at the end of this file ---
desc "--fix/--dry-run: usage gates (the repair behaviour is tested below)"
assert_fails 2 "error: --dry-run requires --fix" "--dry-run without --fix" -- "$FSCK" --dry-run

# --- the out-of-scope pointer: policy.json/ci.json stay shai-doctor's, table mode only ---
desc "scope pointer: policy.json and ci.json validation is pointed at shai-doctor"
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"hello"}')"
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
# The two readability guards — SHAI_HOME -r/-x (shai-fsck:155) and the per-store dir
# -r/-x (shai-fsck:548) — are deliberately not driven: the only way to make an existing
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

# =============================================================================
# Ledger checks (L1-L4), failure checks (F1-F4), and the cross-store pattern check (X1).
# Every check has a matched pair adjacent in the file: a corrupt fixture producing exactly
# one finding of that id, and a healthy fixture producing zero. Each zero expectation was
# mutation-checked while writing — delete the check's emission, watch the positive control
# go red, restore — and is stated inline where it is non-obvious.
# =============================================================================

# --- L1: every ledger line parses and has a non-empty string key, a ts, and a
#     session_id (error; append-only logs are never auto-fixed, the remedy is manual) ---
desc "L1: a ledger line that does not parse yields exactly one L1; a well-formed ledger yields zero"
setup_home
fixture_ledger heartbeat k1
printf 'this is not json\n' >>"$SHAI_HOME/ledgers/heartbeat.jsonl"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "corrupt ledger exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding (L1)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "L1" "the finding is L1"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].severity')" "error" "L1 is an error"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "line 2 is not valid JSON" \
  "summary names the bad line"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].fixable')" "false" "L1 is not fixable"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].remedy | length > 0')" "true" \
  "L1 carries a manual remedy"
# Healthy positive control. Mutation-checked: without the L1 emission this same corrupt
# ledger scanned clean (exit 0, zero findings) — the control went red against the broken code.
setup_home
fixture_ledger heartbeat k1
OUT=$("$FSCK" --check L1 --json)
assert_eq "$?" "0" "well-formed ledger exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "well-formed ledger yields zero L1"

desc "L1: each bad shape — missing key, missing ts, null session_id — is its own L1"
setup_home
fixture_ledger heartbeat k1
printf '%s\n' '{"ts":"2026-08-11T12:00:00Z","session_id":"sess_x"}' >>"$SHAI_HOME/ledgers/heartbeat.jsonl"
OUT=$("$FSCK" --check L1 --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" \
  "line 2 key is missing or not a non-empty string" "missing key is named"
setup_home
fixture_ledger heartbeat k1
printf '%s\n' '{"key":"k2","session_id":"sess_x"}' >>"$SHAI_HOME/ledgers/heartbeat.jsonl"
OUT=$("$FSCK" --check L1 --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "line 2 is missing ts" \
  "missing ts is named"
setup_home
fixture_ledger heartbeat k1
printf '%s\n' '{"key":"k2","ts":"2026-08-11T12:00:00Z","session_id":null}' >>"$SHAI_HOME/ledgers/heartbeat.jsonl"
OUT=$("$FSCK" --check L1 --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "line 2 is missing session_id" \
  "null session_id is named"

# --- L2: no key appears twice within one ledger (error — a duplicate is evidence of a
#     broken idempotency guarantee, not cosmetics; the finding names the key) ---
desc "L2: a duplicated key yields exactly one L2 naming the key; distinct keys yield zero"
setup_home
fixture_ledger heartbeat k1 k1
OUT=$("$FSCK" 2>/dev/null)
assert_eq "$?" "1" "duplicate key exits 1"
assert_row_count "$OUT" 1 "exactly one finding row for the duplicated key"
assert_contains "$OUT" "L2" "the row's check id is L2"
assert_contains "$OUT" 'duplicate key "k1"' "the row names the duplicated key"
OUT=$("$FSCK" --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one L2 finding (not one per line)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" 'duplicate key "k1" (2 entries)' \
  "the finding names the duplicated key — a count-only implementation cannot pass"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].severity')" "error" \
  "L2 is an error: the ledger exists to answer have-I-done-this-already"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].fixable')" "false" "L2 is not fixable"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].remedy | length > 0')" "true" \
  "L2 carries a manual remedy"
# Healthy positive control. Mutation-checked: without the L2 emission the k1/k1 fixture
# scanned clean (exit 0, zero findings).
setup_home
fixture_ledger heartbeat k1 k2
OUT=$("$FSCK" --json)
assert_eq "$?" "0" "two distinct keys exit 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "two distinct keys yield zero findings"

# --- L3: session_id resolves to an existing session log (info — shai-prune --sessions
#     legitimately removes sessions a ledger still names) ---
desc "L3: a ledger naming a pruned session yields one INFO L3; a resolving session yields zero"
setup_home
fixture_ledger heartbeat k1
rm -rf "$SHAI_HOME/sessions" # what shai-prune --sessions does
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "pruned session exits 1 — the exit an INFO-only run has"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "L3" "the finding is L3"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].severity')" "info" "L3 stays info"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].fixable')" "false" "L3 is not fixable"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].remedy | length > 0')" "true" "L3 has a remedy"
# The severity mapping is asserted on the exit code and digest, not just the finding:
# an INFO-only run must exit 1 (problems found) — never 2 (usage) or 3 (scan failed).
ERR=$("$FSCK" 2>&1 >/dev/null)
assert_eq "$?" "1" "INFO-only run exits 1, never 2 or 3"
assert_contains "$ERR" "0 errors, 0 warnings, 1 info" "digest counts only info"
# Healthy positive control. Mutation-checked: without the L3 emission the pruned-session
# fixture scanned clean (exit 0, zero findings).
setup_home
fixture_ledger heartbeat k1
OUT=$("$FSCK" --check L3 --json)
assert_eq "$?" "0" "a resolving session_id exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "a resolving session_id yields zero L3"

# --- L4: the ledger filename names a directory under workflows/ (info — a ledger
#     outlives a workflow that was renamed or deleted) ---
desc "L4: a ledger whose workflow directory is gone yields one INFO L4; a live workflow yields zero"
setup_home
fixture_ledger gone_workflow k1
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "missing workflow directory exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "L4" "the finding is L4"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].severity')" "info" "L4 stays info"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].target')" "gone_workflow" \
  "target is the workflow name"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].fixable')" "false" "L4 is not fixable"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].remedy | length > 0')" "true" "L4 has a remedy"
# Healthy positive control. Mutation-checked: without the L4 check the gone_workflow
# ledger scanned clean (exit 0, zero findings); heartbeat is the live-workflow control.
setup_home
fixture_ledger heartbeat k1
OUT=$("$FSCK" --check L4 --json)
assert_eq "$?" "0" "a ledger naming a live workflow exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "a live workflow yields zero L4"

# --- F1: every failure line parses and carries all seven documented keys (error) ---
desc "F1: a failure line that does not parse yields exactly one F1; a full record yields zero"
setup_home
fixture_failure heartbeat api_error "HTTP 503 from the API"
printf 'garbage\n' >>"$SHAI_HOME/failures/heartbeat.jsonl"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "corrupt failure log exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding (F1)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "F1" "the finding is F1"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].severity')" "error" "F1 is an error"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "line 2 is not valid JSON" \
  "summary names the bad line"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].fixable')" "false" "F1 is not fixable"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].remedy | length > 0')" "true" "F1 has a remedy"
# Healthy positive control. Mutation-checked: without the F1 emission the corrupt log
# scanned clean (exit 0, zero findings).
setup_home
fixture_failure heartbeat api_error "HTTP 503 from the API"
OUT=$("$FSCK" --check F1 --json)
assert_eq "$?" "0" "a seven-key record exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "a seven-key record yields zero F1"

desc "F1: a missing key is named in the summary"
setup_home
fixture_failure heartbeat api_error "boom"
printf '%s\n' '{"ts":"2026-08-11T12:00:00Z"}' >>"$SHAI_HOME/failures/heartbeat.jsonl"
OUT=$("$FSCK" --check F1 --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "line 2 is missing key workflow" \
  "the first missing key is named"

# --- F2: category is one of the five documented values (warn — a new category may land
#     in code before the docs catch up) ---
desc "F2: an unknown category yields one WARN F2; the five documented categories yield zero"
setup_home
fixture_failure heartbeat new_category "boom"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "unknown category exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding (F2)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "F2" "the finding is F2"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].severity')" "warn" \
  "F2 is a warning, not an error — notice, don't block"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" \
  'line 1 has unknown category "new_category"' "summary names the unknown category"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].fixable')" "false" "F2 is not fixable"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].remedy | length > 0')" "true" "F2 has a remedy"
# All five documented categories stay quiet. Mutation-checked: narrowing the category
# list to four made the healthy case go red.
for c in api_error dispatch_error tool_error policy_denial workflow_error; do
  setup_home
  fixture_failure heartbeat "$c" "boom"
  OUT=$("$FSCK" --check F2 --json)
  assert_eq "$?" "0" "category $c exits 0"
  assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "category $c yields zero F2"
done
# A null category is impossible through fail_record (the category is a --arg string), so a
# present-but-null value is a hand edit and F2 flags it; F1 stays quiet because the key is
# carried — F1 is presence-only, F2 owns values. Mutation-checked: without the F2 null arm
# this record scanned clean (exit 0, zero findings).
setup_home
fixture_failure heartbeat api_error "boom"
printf '%s\n' '{"ts":"2026-08-11T12:00:00Z","workflow":"heartbeat","run_id":null,"session_id":null,"category":null,"summary":"s","context":{}}' >>"$SHAI_HOME/failures/heartbeat.jsonl"
OUT=$("$FSCK" --check F2 --json)
assert_eq "$?" "1" "null category exits 1 under F2"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "null category yields exactly one F2"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "line 2 category is null" \
  "the null category is named"
OUT=$("$FSCK" --check F1 --json)
assert_eq "$?" "0" "F1 stays quiet: the category key is present"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "F1 yields zero for a present-but-null category"

# --- F3: context is a JSON object (error — fail_record's {"raw": ...} fallback makes a
#     non-object context impossible through the documented write path) ---
desc "F3: a string context yields one F3; the {\"raw\":...} fallback shape yields zero"
setup_home
fixture_failure heartbeat api_error "boom"
printf '%s\n' '{"ts":"2026-08-11T12:00:00Z","workflow":"heartbeat","run_id":null,"session_id":null,"category":"api_error","summary":"s","context":"raw text"}' >>"$SHAI_HOME/failures/heartbeat.jsonl"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "string context exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding (F3)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "F3" "the finding is F3"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].severity')" "error" \
  "F3 is an error: should be impossible through fail_record"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" \
  "line 2 context is string, not an object" "summary names the actual context type"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].fixable')" "false" "F3 is not fixable"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].remedy | length > 0')" "true" "F3 has a remedy"
# The {"raw": ...} shape fail_record actually writes on bad input is healthy — this is
# exactly why the fallback exists. Mutation-checked: without the F3 emission the
# string-context record scanned clean (exit 0, zero findings).
setup_home
fixture_failure heartbeat api_error "boom"
printf '%s\n' '{"ts":"2026-08-11T12:00:00Z","workflow":"heartbeat","run_id":null,"session_id":null,"category":"api_error","summary":"s","context":{"raw":"not json"}}' >>"$SHAI_HOME/failures/heartbeat.jsonl"
OUT=$("$FSCK" --check F3 --json)
assert_eq "$?" "0" "the raw-fallback shape exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "the raw-fallback shape yields zero F3"

# --- F4: run_id and session_id resolve (info; null ids — no trace context, the state
#     fail_record writes — are skipped, not flagged) ---
desc "F4: an unresolvable run_id or session_id yields one INFO F4 each; null and resolving ids yield zero"
setup_home
fixture_failure heartbeat api_error "boom"
printf '%s\n' '{"ts":"2026-08-11T12:00:00Z","workflow":"heartbeat","run_id":"run_ghost","session_id":null,"category":"api_error","summary":"s","context":{}}' >>"$SHAI_HOME/failures/heartbeat.jsonl"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "unresolvable run_id exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding (F4)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "F4" "the finding is F4"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].severity')" "info" "F4 stays info"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" \
  'line 2 run_id "run_ghost" does not resolve' "summary names the unresolvable run_id"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].fixable')" "false" "F4 is not fixable"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].remedy | length > 0')" "true" "F4 has a remedy"
setup_home
fixture_failure heartbeat api_error "boom"
printf '%s\n' '{"ts":"2026-08-11T12:00:00Z","workflow":"heartbeat","run_id":null,"session_id":"sess_ghost","category":"api_error","summary":"s","context":{}}' >>"$SHAI_HOME/failures/heartbeat.jsonl"
OUT=$("$FSCK" --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" \
  'line 2 session_id "sess_ghost" does not resolve' "summary names the unresolvable session_id"
# Healthy positive control: null ids (fail_record without trace context) and ids that
# resolve are both quiet. Mutation-checked: without the F4 emission the ghost-id records
# scanned clean (exit 0, zero findings).
setup_home
ev="$(fixture_event message user '{"text":"hello"}' run_20260810T120000_aabbccdd)"
SID=$(fixture_session sess_20260810T120000_aabbccdd "$ev")
RID=$(fixture_run run_20260810T120000_aabbccdd "$SID" "$ev")
fixture_failure heartbeat api_error "boom"
jq -nc --arg ts "2026-08-11T12:00:00Z" --arg rid "$RID" --arg sid "$SID" \
  '{ts:$ts, workflow:"heartbeat", run_id:$rid, session_id:$sid,
    category:"api_error", summary:"s", context:{}}' \
  >>"$SHAI_HOME/failures/heartbeat.jsonl"
OUT=$("$FSCK" --check F4 --json)
assert_eq "$?" "0" "null and resolving ids exit 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "null and resolving ids yield zero F4"

# --- X1: every entry under a store directory matches that store's expected name pattern
#     (info, deliberately never fixable — fsck reports the unknown, it never deletes it) ---
desc "X1: a wholly healthy store with .latest.json siblings and span dumps yields zero; one stray file yields one"
setup_home
ev="$(fixture_event message user '{"text":"hello"}' run_20260810T120000_aabbccdd)"
SID=$(fixture_session sess_20260810T120000_aabbccdd "$ev")
RID=$(fixture_run run_20260810T120000_aabbccdd "$SID" "$ev")
fixture_span_dump "$RID" span_1 request
fixture_span_dump "$RID" span_1 response
fixture_ledger heartbeat k1
fixture_failure heartbeat api_error "HTTP 503 from the API"
OUT=$("$FSCK" --json)
assert_eq "$?" "0" "wholly healthy store exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" \
  "zero findings — .latest.json siblings and span dumps are recognized, not unknown"
# This zero is the discriminating X1 assertion: a naive *.jsonl-only sessions rule would
# flag every .latest.json here. Mutation-checked by narrowing the sessions pattern to
# *.jsonl and watching this healthy store go red (one finding per .latest.json), then
# restoring the *.latest.json arm.
printf 'stray notes\n' >"$SHAI_HOME/sessions/notes.txt"
OUT=$("$FSCK" 2>/dev/null)
assert_eq "$?" "1" "one stray file exits 1"
assert_row_count "$OUT" 1 "exactly one finding row for the stray file"
assert_contains "$OUT" "X1" "the row's check id is X1"
assert_contains "$OUT" "notes.txt" "the row names the stray file"
OUT=$("$FSCK" --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one X1 finding"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "X1" "the finding is X1"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].severity')" "info" "X1 stays info"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].store')" "sessions" "store is sessions"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].target')" "notes.txt" \
  "target is the store-relative stray path"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" \
  "unrecognized entry (expected *.jsonl or *.latest.json)" "summary names the expected pattern"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].fixable')" "false" \
  "X1 is never fixable — fsck must not delete what it cannot classify"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].remedy | length > 0')" "true" "X1 has a remedy"

desc "X1: ledgers, failures, and runs entries get the same treatment"
setup_home
mkdir -p "$SHAI_HOME/ledgers"
printf 'x\n' >"$SHAI_HOME/ledgers/notes.txt"
OUT=$("$FSCK" --check X1 --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].store')" "ledgers" "ledgers/ stray file reported"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "unrecognized entry (expected *.jsonl)" \
  "ledgers/ pattern named"
setup_home
mkdir -p "$SHAI_HOME/failures"
printf 'x\n' >"$SHAI_HOME/failures/notes.txt"
OUT=$("$FSCK" --check X1 --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].store')" "failures" "failures/ stray file reported"
setup_home
mkdir -p "$SHAI_HOME/runs/run_20260810T120000_aabbccdd"
printf 'x\n' >"$SHAI_HOME/runs/run_20260810T120000_aabbccdd/notes.txt"
OUT=$("$FSCK" --check X1 --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].target')" "run_20260810T120000_aabbccdd/notes.txt" \
  "a stray file inside a run directory is reported with its store-relative path"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" \
  "unrecognized entry (expected events.jsonl, *-request.json, or *-response.json)" \
  "run-directory patterns named"
setup_home
mkdir -p "$SHAI_HOME/runs"
printf 'x\n' >"$SHAI_HOME/runs/notes.txt"
OUT=$("$FSCK" --check X1 --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" \
  "unrecognized entry (expected a run directory)" \
  "a file where a run directory belongs is reported"

# =============================================================================
# Session-store checks (S1-S3, S5-S9). Every check has a matched pair adjacent in the
# file: a corrupt fixture producing exactly one finding of that id, and a healthy
# fixture producing zero. Each zero expectation was mutation-checked while writing —
# delete the check's emission, watch the positive control go red, restore — and is
# stated inline where it is non-obvious.
# =============================================================================

# --- S1: every line parses as a JSON object (error). A blank line is a violation, not
#     whitespace noise — one reaching the tail of a session log would make shai-retry's
#     classifier report "nothing to resume" for a resumable run (CLAUDE.md's shai-stamp
#     note) ---
desc "S1: a blank line at the tail and one mid-log each yield exactly one S1; a clean log yields zero"
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"hello"}')"
printf '\n' >>"$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.jsonl"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "blank-tail session exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding (S1)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "S1" "the finding is S1"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].severity')" "error" "S1 is an error"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "line 2 is blank" \
  "the tail blank is named by line"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].fixable')" "false" "S1 is not fixable"
OUT=$("$FSCK" 2>/dev/null)
assert_row_count "$OUT" 1 "table mode: exactly one S1 row"
setup_home
# a blank between two events, with the mirrored tail keeping S5 quiet
ev1="$(sess_event message user '{"text":"a"}')"
ev2="$(sess_event message user '{"text":"b"}')"
SID=$(fixture_session sess_20260810T120000_aabbccdd "$ev1" "$ev2")
mapfile -t LINES <"$SHAI_HOME/sessions/$SID.jsonl"
{
  printf '%s\n' "${LINES[0]}"
  printf '\n'
  printf '%s\n' "${LINES[1]}"
} >"$SHAI_HOME/sessions/$SID.jsonl"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "mid-log blank exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding (S1)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "line 2 is blank" \
  "the mid-log blank is named by line"
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"a"}')"
printf 'this is not json\n' >>"$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.jsonl"
OUT=$("$FSCK" --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "line 2 is not a JSON object" \
  "a non-blank garbage line carries its own summary"
# Healthy negative control, written next to the positives. Mutation-checked: without the
# S1 emission the blank-tail fixture scanned clean (exit 0, zero findings).
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"hello"}')"
OUT=$("$FSCK" --check S1 --json)
assert_eq "$?" "0" "a clean one-line log exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "a clean log yields zero S1"

# --- S2: every event carries top-level type, source, and payload — as string/string/object
#     values, not merely present keys (error) ---
desc "S2: a missing key and a null-typed key each yield exactly one S2; a stamped event yields zero"
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"hello"}')"
TMP="$(mktemp)"
jq -c 'del(.source)' "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.jsonl" >"$TMP"
mv "$TMP" "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.jsonl"
cp "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.jsonl" \
  "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.latest.json"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "sourceless event exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding (S2)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "S2" "the finding is S2"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].severity')" "error" "S2 is an error"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" \
  "event 1 missing or invalid type, source, or payload" "the summary names the contract keys"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].fixable')" "false" "S2 is not fixable"
# A null value carries the key, so a has()-only implementation admits it — the check must
# require the values (string type/source, object payload), not just the keys. Mutation-
# checked: with the has() predicate restored this fixture scanned clean (exit 0, zero
# findings) and the assertion below went red.
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"hello"}')"
TMP="$(mktemp)"
jq -c '.type = null' "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.jsonl" >"$TMP"
mv "$TMP" "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.jsonl"
cp "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.jsonl" \
  "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.latest.json"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "null-typed event exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding (S2)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "S2" "the finding is S2"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" \
  "event 1 missing or invalid type, source, or payload" "a null type is named as invalid"
# Healthy negative control. Mutation-checked: without the S2 emission the sourceless
# event scanned clean (exit 0, zero findings).
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"hello"}')"
OUT=$("$FSCK" --check S2 --json)
assert_eq "$?" "0" "a stamped event exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "a stamped event yields zero S2"

# --- S3: every event with a meta.session_id matches the filename stem (error).
#     Unstamped events — no meta at all — are skipped, never flagged ---
desc "S3: a mismatched meta.session_id yields exactly one S3; a legacy unstamped log yields zero"
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"a"}')" \
  "$(sess_event message user '{"text":"b"}')"
TMP="$(mktemp)"
head -n 1 "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.jsonl" |
  jq -c '.meta.session_id = "elsewhere"' >"$TMP"
sed -n '2p' "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.jsonl" >>"$TMP"
mv "$TMP" "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.jsonl"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "mismatched session_id exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding (S3)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "S3" "the finding is S3"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].severity')" "error" "S3 is an error"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" \
  'event 1 meta.session_id "elsewhere" does not match the session id' \
  "the summary names the mismatched id"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].fixable')" "false" "S3 is not fixable"
# Legacy negative control: wholly unstamped events (no meta, no version) yield zero S3
# and zero S9 warnings — flagging them would make fsck report every historical log as
# corrupt. Mutation-checked by flagging unstamped events: this fixture then emitted one
# S3 and the zero-S3 assertion below went red.
setup_home
mkdir -p "$SHAI_HOME/sessions"
printf '%s\n' '{"type":"message","source":"user","payload":{"text":"legacy"}}' \
  >"$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.jsonl"
cp "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.jsonl" \
  "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.latest.json"
OUT=$("$FSCK" --json)
assert_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.check == "S3")] | length')" "0" \
  "an unstamped legacy event yields zero S3"
assert_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.check == "S9" and .severity == "warn")] | length')" "0" \
  "an unstamped legacy event yields zero S9 warnings"

# --- S6 before S5 (the precedence contrast): a stillborn session — one system event,
#     empty .latest.json, the pair wf_seed_session writes — yields exactly one S6 and
#     ZERO S5; adjacent, an empty .latest.json beside a three-event log is a genuine S5
#     and ZERO S6. The two halves are the precedence rule, asserted as one contrast ---
desc "S6/S5 precedence: the stillborn pair is S6's alone; an empty latest beside a real log is S5"
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message system '{"text":"seed"}')"
: >"$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.latest.json"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "stillborn session exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding (S6)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "S6" "the finding is S6"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].severity')" "warn" "S6 is a warning"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" \
  "stillborn session (one system event, empty latest.json)" "the summary names the pair"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].fixable')" "true" "S6 is fixable"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].remedy')" "delete pair" \
  "S6's remedy deletes the pair"
assert_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.check == "S5")] | length')" "0" \
  "the stillborn session yields ZERO S5 — S6 claims it (the precedence half of the contrast)"
OUT=$("$FSCK" 2>/dev/null)
assert_row_count "$OUT" 1 "table mode: exactly one S6 row"
# The other half, adjacent: the same empty .latest.json beside a three-event log is S5.
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"a"}')" \
  "$(sess_event message assistant '{"content":"hi","tool_calls":[],"finish_reason":"stop"}')" \
  "$(sess_event message user '{"text":"b"}')"
: >"$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.latest.json"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "empty latest beside a three-event log exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding (S5)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "S5" "the finding is S5"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].severity')" "error" "S5 is an error"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "latest.json empty" \
  "the summary names the empty latest"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].fixable')" "true" "S5 is fixable"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].remedy')" "rebuild" "S5's remedy rebuilds latest.json"
assert_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.check == "S6")] | length')" "0" \
  "the three-event log yields ZERO S6 — only the seeded pair is stillborn"
# Mutation-checked both directions: removing S5's stillborn gate made the stillborn
# fixture emit a spurious S5 (the ZERO-S5 assertion above went red), and removing the S6
# emission made the stillborn fixture scan clean instead of emitting its one finding.

# --- S5: the single predicate "latest.json is JSON-equal to the last event" — missing,
#     empty, unparseable, and stale are all failures of it (error, fixable by rebuild) ---
desc "S5: missing, unparseable, and stale latest.json each yield exactly one S5; a mirrored or error-event latest yields zero"
setup_home
ev="$(sess_event message user '{"text":"hello"}')"
SID=$(fixture_session sess_20260810T120000_aabbccdd "$ev")
rm "$SHAI_HOME/sessions/$SID.latest.json"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "missing latest exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding (S5)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "S5" "the finding is S5"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "latest.json missing" \
  "a missing latest.json is named"
setup_home
ev="$(sess_event message user '{"text":"hello"}')"
SID=$(fixture_session sess_20260810T120000_aabbccdd "$ev")
printf 'garbage\n' >"$SHAI_HOME/sessions/$SID.latest.json"
OUT=$("$FSCK" --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "S5" "the finding is S5"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "latest.json does not parse as JSON" \
  "an unparseable latest.json is named"
setup_home
SID=$(fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"a"}')" \
  "$(sess_event message user '{"text":"b"}')")
printf '%s\n' '{"type":"message","source":"user","payload":{"text":"stale"}}' \
  >"$SHAI_HOME/sessions/$SID.latest.json"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "stale latest exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "a stale latest yields exactly one S5"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "latest.json is not the last event" \
  "a stale latest.json is named"
# Healthy negative control: fixture_session mirrors the log tail into .latest.json, so a
# builder-built session satisfies S5 by construction. Mutation-checked: without the S5
# emission the stale fixture scanned clean (exit 0, zero findings).
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"a"}')" \
  "$(sess_event message user '{"text":"b"}')"
OUT=$("$FSCK" --check S5 --json)
assert_eq "$?" "0" "a mirrored latest exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "a mirrored latest yields zero S5"
# An error event in .latest.json is the genuine most-recent event of a session that ended
# in an eval/dispatch error, not a stale file: shai-loop's commit_run filters error events
# out of the session log (shai-loop:136) and emit_dispatch_error writes them to LATEST
# only, so latest and log tail legitimately diverge — and "rebuild" would overwrite the
# only copy of the error (CLAUDE.md:139). Mutation-checked: without the error-latest
# exemption this fixture emits exactly one S5 ("latest.json is not the last event").
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"a"}')" \
  "$(sess_event message assistant '{"content":"hi","tool_calls":[],"finish_reason":"stop"}')"
printf '%s\n' '{"type":"error","source":"system","payload":{"text":"eval failed"}}' \
  >"$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.latest.json"
OUT=$("$FSCK" --check S5 --json)
assert_eq "$?" "0" "an error-event latest exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "an error-event latest yields zero S5"

# --- S6 negative: a seeded session whose latest.json mirrors the system event is not
#     stillborn — the empty latest is what makes the pair ---
desc "S6: a seeded session with a mirrored latest.json yields zero S6"
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message system '{"text":"seed"}')"
OUT=$("$FSCK" --check S6 --json)
assert_eq "$?" "0" "a mirrored system event exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "a mirrored system event yields zero S6"

# --- S7: every tool_result's tool_call_id appears in a PRECEDING assistant event's
#     tool_calls (error). Ordering is part of the check, not just set membership: a
#     result matching a LATER assistant event is equally malformed ---
desc "S7: an unmatched tool_call_id yields exactly one S7; a result matching a later assistant event still fails"
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message assistant '{"content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"list_directory","arguments":"{}"}}],"finish_reason":"tool_calls"}')" \
  "$(sess_event tool_result tool '{"tool_call_id":"ghost","content":"nope","is_error":false}')"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "unmatched tool_result exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding (S7)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "S7" "the finding is S7"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].severity')" "error" "S7 is an error"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" \
  'tool_result 2 tool_call_id "ghost" has no preceding assistant tool call' \
  "the summary names the orphaned tool_call_id"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].fixable')" "false" "S7 is not fixable"
# The ordering discriminator: the matching assistant event comes AFTER the result. A
# set-membership implementation passes this fixture wrongly; only a preceding-order
# implementation reports it.
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event tool_result tool '{"tool_call_id":"call1","content":"early","is_error":false}')" \
  "$(sess_event message assistant '{"content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"list_directory","arguments":"{}"}}],"finish_reason":"tool_calls"}')"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "a result matching a later assistant event exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding (S7)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "S7" "the finding is S7"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" \
  'tool_result 1 tool_call_id "call1" has no preceding assistant tool call' \
  "the premature result is named"
# Healthy negative control: the result follows the assistant event that announced the id.
# Mutation-checked: without the S7 emission the ghost fixture scanned clean (exit 0,
# zero findings).
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message assistant '{"content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"list_directory","arguments":"{}"}}],"finish_reason":"tool_calls"}')" \
  "$(sess_event tool_result tool '{"tool_call_id":"call1","content":"ok","is_error":false}')"
OUT=$("$FSCK" --check S7 --json)
assert_eq "$?" "0" "a matched tool_result exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "a matched tool_result yields zero S7"

# --- S8: every assistant tool_calls[].id has a matching tool_result later in the
#     session (warn) — EXCEPT on the final assistant event, the resumable-tail case
#     shai-retry exists to handle. Without the exemption every interrupted session (the
#     REPL's healthy Ctrl-C path) would fire ---
desc "S8: the final assistant event is exempt; an unanswered call on an earlier assistant event yields exactly one"
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"list files"}')" \
  "$(sess_event message assistant '{"content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"list_directory","arguments":"{}"}}],"finish_reason":"tool_calls"}')"
OUT=$("$FSCK" --json)
assert_eq "$?" "0" "an interrupted session (unanswered calls on the final event) exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" \
  "the resumable tail is exempt — zero findings, zero S8"
# Mutation-checked by removing the final-assistant exemption: this same fixture then
# emitted exactly one S8 and the zero-findings assertion above went red. That is the
# state the check must not treat as corruption.
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"a"}')" \
  "$(sess_event message assistant '{"content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"list_directory","arguments":"{}"}}],"finish_reason":"tool_calls"}')" \
  "$(sess_event message assistant '{"content":"done","tool_calls":[],"finish_reason":"stop"}')"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "an unanswered earlier call exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding (S8)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "S8" "the finding is S8"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].severity')" "warn" "S8 is a warning"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" \
  'assistant tool call "call1" (event 2) has no tool_result' \
  "the summary names the unanswered call and its event"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].fixable')" "false" "S8 is not fixable"

# --- S9: version is a known schema version ("1.0"). An unrecognized version is WARN;
#     no version at all is INFO, never WARN — the same legacy tolerance as S3 ---
desc "S9: an unrecognized version yields exactly one WARN S9; a versionless legacy log yields INFO only"
setup_home
ev="$(sess_event message user '{"text":"hello"}')"
SID=$(fixture_session sess_20260810T120000_aabbccdd "$ev")
TMP="$(mktemp)"
jq -c '.version = "0.9"' "$SHAI_HOME/sessions/$SID.jsonl" >"$TMP"
mv "$TMP" "$SHAI_HOME/sessions/$SID.jsonl"
cp "$SHAI_HOME/sessions/$SID.jsonl" "$SHAI_HOME/sessions/$SID.latest.json"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "unknown version exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding (S9)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "S9" "the finding is S9"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].severity')" "warn" "an unrecognized version is WARN"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" \
  'event 1 has unknown version "0.9"' "the summary names the unknown version"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].fixable')" "false" "S9 is not fixable"
setup_home
mkdir -p "$SHAI_HOME/sessions"
printf '%s\n' \
  '{"type":"message","source":"user","payload":{"text":"one"}}' \
  '{"type":"message","source":"user","payload":{"text":"two"}}' \
  >"$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.jsonl"
printf '%s\n' '{"type":"message","source":"user","payload":{"text":"two"}}' \
  >"$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.latest.json"
OUT=$("$FSCK" --json)
assert_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.check == "S9" and .severity == "warn")] | length')" "0" \
  "a wholly unstamped log yields zero S9 WARNINGS"
assert_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.check == "S9" and .severity == "info")] | length')" "2" \
  "each versionless event yields one INFO S9, never a warning"
# Healthy negative control: sess_event always stamps version 1.0. Mutation-checked:
# without the S9 emission the unknown-version fixture scanned clean (exit 0, zero
# findings).
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"hello"}')"
OUT=$("$FSCK" --check S9 --json)
assert_eq "$?" "0" "a version 1.0 event exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "a version 1.0 event yields zero S9"

# --- --check S1 … --check S9: each id selects exactly its own finding from a
#     nine-corruption store (isolation, not just reachability) ---
desc "--check: each S id selects exactly its own finding from the nine-corruption sink"
setup_home
build_sink
for id in S1 S2 S3 S4 S5 S6 S7 S8 S9; do
  OUT=$("$FSCK" --check "$id" --json)
  assert_eq "$?" "1" "--check $id exits 1 on its own corruption"
  assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "--check $id reports exactly one finding"
  assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "$id" "--check $id reports only $id"
done
# The full scan sees all nine, exactly one per check — the stillborn sess_s6 must not
# also leak an S5 (S6 claims it), and sess_s7's final assistant must stay S8-exempt.
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "the sink store exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "9" "the full scan reports all nine corruptions"
assert_eq "$(printf '%s' "$OUT" | jq -r '[.[].check] | sort | join(",")')" \
  "S1,S2,S3,S4,S5,S6,S7,S8,S9" "every check fired exactly once"
OUT=$("$FSCK" 2>/dev/null)
assert_row_count "$OUT" 9 "table mode: one row per finding (9)"
# --check S5 alone on the sink still respects S6's claim: one S5 (sess_s5), none from the
# stillborn sess_s6.
OUT=$("$FSCK" --check S5 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" \
  "--check S5 alone never reports the stillborn session (S6 precedence holds without S6 selected)"

# --- one jq pass per store file, per the shai-events:167 pattern: a counting jq stub
#     must observe the session log opened by exactly one jq invocation ---
# Scoped to --store sessions deliberately. The property under test is that the S family
# shares one pass, not that a whole scan opens each session log once: R7 is a run-store
# check that reads session logs (its subject is the run directories they reference), so it
# adds a second, by-design pass that --store sessions keeps out of the count.
desc "one jq pass per store file: the S-family shares a single jq pass over the session log"
setup_home
SID=$(fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"hello"}')" \
  "$(sess_event message assistant '{"content":"hi","tool_calls":[],"finish_reason":"stop"}')")
REAL_JQ="$(command -v jq)"
JQ_LOG="$SHAI_HOME/jq.log"
make_stub_bin
cat >"$STUB/jq" <<EOF
#!/bin/bash
# one line per invocation: the jq program itself is multi-line, so flatten with tr
printf '%s ' "\$*" | tr '\n' ' ' >>"$JQ_LOG"
printf '\n' >>"$JQ_LOG"
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$STUB/jq"
OUT=$("$FSCK" --store sessions --json)
assert_eq "$?" "0" "healthy session exits 0 under the counting jq stub"
assert_eq "$(grep -c "$SID.jsonl" "$JQ_LOG" || true)" "1" \
  "the session log is opened by exactly one jq pass"

# --- --check S1 … --check X1: every shipped id runs alone (each catalog entry is
#     reachable, and no id depends on another id's scan side effects) ---
desc "--check: each of the twenty-five check ids runs alone"
for id in S1 S2 S3 S4 S5 S6 S7 S8 S9 R1 R2 R3 R4 R5 R6 R7 L1 L2 L3 L4 F1 F2 F3 F4 X1; do
  setup_home
  RC=0
  "$FSCK" --check "$id" --json >/dev/null 2>&1 || RC=$?
  assert_eq "$RC" "0" "--check $id runs alone (exit 0 on an empty store)"
done

# =============================================================================
# --fix: safe repairs driven by the findings accumulator (#393). --fix consumes
# the same FINDINGS_FILE the renderers read — it never re-scans or re-derives
# fixability — and maps each fixable check to exactly one safe action: rebuild a
# derived file (S5) or delete a whole redundant unit (S4, S6, R1's wholly-empty
# run directory, R5, R6's dead run). Anything else is refused with its named
# manual remedy on stderr. The dedicated safety test (byte-identity of malformed
# event logs, with a repaired-finding positive control) leads, because it is the
# property the whole --fix design exists to protect.
# =============================================================================

# store_checksum: one "sha256  path" line per file under $SHAI_HOME, sorted by path —
# the snapshot the idempotency and byte-identity assertions compare.
store_checksum() {
  local f
  if [ -d "$SHAI_HOME" ]; then
    while IFS= read -r f; do
      sha256sum "$f" 2>/dev/null
    done < <(find "$SHAI_HOME" -type f | LC_ALL=C sort)
  fi
}

# build_fixable_store: one corruption per fixable check — S4 orphan latest.json, S5
# three-event log with an empty latest.json, S6 the stillborn pair, R1 a wholly empty
# run directory, R5 an orphan span dump, R6 a dead uncommitted run. Each is a healthy
# fixture with exactly one break, and every cross-reference (committed runs, nulled
# run_ids) is arranged so a full scan finds exactly these six findings.
build_fixable_store() {
  local ev
  mkdir -p "$SHAI_HOME/sessions" "$SHAI_HOME/runs"
  # S4: orphan .latest.json
  printf '{}\n' >"$SHAI_HOME/sessions/sess_s4.latest.json"
  # S5: three events, empty .latest.json (multi-event, so never stillborn)
  fixture_session sess_s5 \
    "$(sess_event message user '{"text":"a"}')" \
    "$(sess_event message assistant '{"content":"hi","tool_calls":[],"finish_reason":"stop"}')" \
    "$(sess_event message user '{"text":"b"}')"
  : >"$SHAI_HOME/sessions/sess_s5.latest.json"
  # S6: the stillborn pair
  fixture_session sess_s6 "$(sess_event message system '{"text":"seed"}')"
  : >"$SHAI_HOME/sessions/sess_s6.latest.json"
  # R1: a wholly empty run directory
  mkdir -p "$SHAI_HOME/runs/run_20260903T043418_67e3340f"
  # R5: an orphan span dump beside a healthy committed one-span run
  ev="$(fixture_event message user '{"text":"hi"}' run_r5 sess_r5 span_1)"
  fixture_session sess_r5 "$ev"
  fixture_run run_r5 sess_r5 "$ev"
  fixture_span_dump run_r5 span_9 request
  # R6: a dead uncommitted run — error event, no user message
  fixture_run run_r6 sess_r6 "$(fixture_event error system '{"text":"boom"}')"
}

# build_unfixable_store: one corruption per REFUSED check — S1/S2/S3/S7/S8/S9, R1's
# unfixable empty-log shape, R2, R3, R4, R6's resumable verdict, R7, L1-L4, F1-F4, X1.
# The ledger fixtures each get their own workflow name because fixture_ledger truncates
# its file (L1's garbage line would otherwise be wiped by the next builder call);
# failure fixtures append and may share one file because each corruption is distinct.
build_unfixable_store() {
  local ev tmp sid
  mkdir -p "$SHAI_HOME/sessions" "$SHAI_HOME/runs"
  # S1: garbage line after a healthy event
  ev="$(sess_event message user '{"text":"a"}')"
  fixture_session sess_s1 "$ev"
  printf 'not json\n' >>"$SHAI_HOME/sessions/sess_s1.jsonl"
  # S2: source deleted (log and latest rewritten together)
  ev="$(sess_event message user '{"text":"b"}')"
  fixture_session sess_s2 "$ev"
  tmp="$(mktemp)"
  jq -c 'del(.source)' "$SHAI_HOME/sessions/sess_s2.jsonl" >"$tmp"
  mv "$tmp" "$SHAI_HOME/sessions/sess_s2.jsonl"
  cp "$SHAI_HOME/sessions/sess_s2.jsonl" "$SHAI_HOME/sessions/sess_s2.latest.json"
  # S3: first of two events stamped with the wrong session id
  fixture_session sess_s3 \
    "$(sess_event message user '{"text":"c1"}')" \
    "$(sess_event message user '{"text":"c2"}')"
  tmp="$(mktemp)"
  head -n 1 "$SHAI_HOME/sessions/sess_s3.jsonl" | jq -c '.meta.session_id = "elsewhere"' >"$tmp"
  sed -n '2p' "$SHAI_HOME/sessions/sess_s3.jsonl" >>"$tmp"
  mv "$tmp" "$SHAI_HOME/sessions/sess_s3.jsonl"
  # S7: a tool_result whose id no preceding assistant event announced
  fixture_session sess_s7 \
    "$(sess_event message assistant '{"content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"list_directory","arguments":"{}"}}],"finish_reason":"tool_calls"}')" \
    "$(sess_event tool_result tool '{"tool_call_id":"ghost","content":"nope","is_error":false}')"
  # S8: an unanswered tool call on an earlier assistant event
  fixture_session sess_s8 \
    "$(sess_event message user '{"text":"f"}')" \
    "$(sess_event message assistant '{"content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"list_directory","arguments":"{}"}}],"finish_reason":"tool_calls"}')" \
    "$(sess_event message assistant '{"content":"done","tool_calls":[],"finish_reason":"stop"}')"
  # S9: an unrecognized schema version
  ev="$(sess_event message user '{"text":"g"}')"
  fixture_session sess_s9 "$ev"
  tmp="$(mktemp)"
  jq -c '.version = "0.9"' "$SHAI_HOME/sessions/sess_s9.jsonl" >"$tmp"
  mv "$tmp" "$SHAI_HOME/sessions/sess_s9.jsonl"
  cp "$SHAI_HOME/sessions/sess_s9.jsonl" "$SHAI_HOME/sessions/sess_s9.latest.json"
  # R1 (unfixable shape): an empty event log
  fixture_run run_r1 sess_r1
  # R2: a foreign meta.run_id, in a run that R6/R7 still classify as committed/resolved
  ev="$(fixture_event message user '{"text":"hi"}' run_other sess_r2)"
  mkdir -p "$SHAI_HOME/runs/run_r2"
  printf '%s\n' "$ev" >"$SHAI_HOME/runs/run_r2/events.jsonl"
  fixture_session sess_r2 "$(fixture_event message user '{"text":"hi"}' run_r2 sess_r2)"
  # R3: a span gap (span_1 then span_3)
  ev="$(fixture_event message user '{"text":"hi"}' run_r3 sess_r3 span_1)"
  tmp="$(fixture_event message assistant '{"content":"hi"}' run_r3 sess_r3 span_3)"
  tmp="$(printf '%s' "$tmp" | jq -c '.meta.parent_span_id = "span_2"')"
  fixture_session sess_r3 "$ev" "$tmp"
  fixture_run run_r3 sess_r3 "$ev" "$tmp"
  # R4: a malformed span dump whose span does have an event (so R5 stays quiet)
  ev="$(fixture_event message user '{"text":"hi"}' run_r4 sess_r4 span_1)"
  fixture_session sess_r4 "$ev"
  fixture_run run_r4 sess_r4 "$ev"
  fixture_span_dump run_r4 span_1 request '{garbage'
  # R6 (resumable): a user message whose session was never committed
  fixture_run run_r6 sess_r6 "$(fixture_event message user '{"text":"hi"}')"
  # R7: a session event referencing a run directory that does not exist
  fixture_session sess_r7 "$(fixture_event message user '{"text":"hi"}' run_ghost sess_r7)"
  # L1: a ledger line that does not parse
  fixture_ledger heartbeat k1
  printf 'not json\n' >>"$SHAI_HOME/ledgers/heartbeat.jsonl"
  # L2: a duplicate key
  fixture_ledger jira_worker k2 k2
  # L3: a ledger entry naming a session that was removed
  sid="$(fixture_ledger pr_reviewer k3)"
  rm "$SHAI_HOME/sessions/$sid.jsonl" "$SHAI_HOME/sessions/$sid.latest.json"
  # L4: a ledger for a workflow that no longer exists
  fixture_ledger nope_workflow_xyz k4
  # F1: a failure line that does not parse
  fixture_failure heartbeat api_error "HTTP 503"
  printf 'not json\n' >>"$SHAI_HOME/failures/heartbeat.jsonl"
  # F2: an unknown category
  fixture_failure heartbeat banana "unknown category"
  # F3: a context that is not an object
  jq -nc '{ts:"2026-08-11T12:00:00Z", workflow:"heartbeat", run_id:null, session_id:null,
           category:"api_error", summary:"ctx", context:"not-an-object"}' \
    >>"$SHAI_HOME/failures/heartbeat.jsonl"
  # F4: a non-null run_id that does not resolve
  jq -nc '{ts:"2026-08-11T12:00:00Z", workflow:"heartbeat", run_id:"run_ghost",
           session_id:null, category:"api_error", summary:"x", context:{}}' \
    >>"$SHAI_HOME/failures/heartbeat.jsonl"
  # X1: a stray file where only *.jsonl / *.latest.json belong
  printf 'stray\n' >"$SHAI_HOME/sessions/stray.txt"
}

# --- the dedicated safety test: malformed event logs stay byte-identical, and the
#     fixable finding in the same store WAS repaired (the positive control — without
#     it the byte-identity half passes trivially against a --fix that does nothing) ---
desc "--fix safety: malformed event logs are byte-identical; the fixable finding is repaired"
setup_home
ev="$(sess_event message user '{"text":"hello"}')"
SID=$(fixture_session sess_20260810T120000_aabbccdd "$ev")
printf 'not json\n' >>"$SHAI_HOME/sessions/$SID.jsonl"
fixture_ledger heartbeat k1
printf 'not json\n' >>"$SHAI_HOME/ledgers/heartbeat.jsonl"
fixture_failure heartbeat api_error "HTTP 503 from the API"
printf 'not json\n' >>"$SHAI_HOME/failures/heartbeat.jsonl"
orphan_latest sess_20260811T120000_eeff0011
log_hashes() {
  sha256sum \
    "$SHAI_HOME/sessions/$SID.jsonl" \
    "$SHAI_HOME/ledgers/heartbeat.jsonl" \
    "$SHAI_HOME/failures/heartbeat.jsonl"
}
BEFORE="$(log_hashes)"
ERR=$("$FSCK" --fix 2>&1 >/dev/null)
assert_eq "$?" "1" "--fix exits 1 when malformed logs cannot be safely repaired"
assert_eq "$(log_hashes)" "$BEFORE" \
  "the three malformed event-bearing .jsonl logs are byte-identical after --fix"
assert_eq "$([ -e "$SHAI_HOME/sessions/sess_20260811T120000_eeff0011.latest.json" ] && echo yes || echo no)" "no" \
  "the fixable S4 orphan WAS repaired (the positive control, mutation-checked: a no-op --fix keeps the orphan and fails this)"
assert_contains "$ERR" \
  "repair: delete $SHAI_HOME/sessions/sess_20260811T120000_eeff0011.latest.json (S4)" \
  "the repair line names the orphan"
assert_contains "$ERR" \
  "manual: S1 $SHAI_HOME/sessions/$SID.jsonl — manual: hand-edit the session log to repair or remove the line" \
  "the refused S1 prints its named manual remedy"
assert_contains "$ERR" \
  "manual: L1 $SHAI_HOME/ledgers/heartbeat.jsonl — hand-edit the ledger to repair or remove the line" \
  "the refused L1 prints its named manual remedy"
assert_contains "$ERR" \
  "manual: F1 $SHAI_HOME/failures/heartbeat.jsonl — hand-edit the failure log to repair or remove the line" \
  "the refused F1 prints its named manual remedy"
OUT=$("$FSCK" --check S4 --json)
assert_eq "$?" "0" "rescan: the S4 orphan is gone"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "rescan: zero S4 findings"

# --- per-repair pairs: each of the six fixable classes gets its own corrupt fixture
#     and an assertion that the specific repair happened. Each was mutation-checked
#     while written — break the individual repair arm in apply_fixes, watch the
#     assertion go red, restore ---
desc "S4 repair pair: --fix deletes the orphan latest.json"
setup_home
orphan_latest sess_20260810T120000_aabbccdd
ERR=$("$FSCK" --fix --check S4 2>&1 >/dev/null)
assert_eq "$?" "0" "S4-only fix exits 0"
assert_eq "$([ -e "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.latest.json" ] && echo yes || echo no)" "no" \
  "the orphan was deleted"
assert_contains "$ERR" \
  "repair: delete $SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.latest.json (S4)" \
  "the repair line names the orphan"

desc "S5 repair pair: --fix rebuilds latest.json from the log's last line, never deletes it"
setup_home
SID=$(fixture_session sess_20260810T120000_aabbccdd \
  "$(sess_event message user '{"text":"a"}')" \
  "$(sess_event message assistant '{"content":"hi","tool_calls":[],"finish_reason":"stop"}')" \
  "$(sess_event message user '{"text":"b"}')")
head -n 1 "$SHAI_HOME/sessions/$SID.jsonl" >"$SHAI_HOME/sessions/$SID.latest.json"
ERR=$("$FSCK" --fix --check S5 2>&1 >/dev/null)
assert_eq "$?" "0" "S5-only fix exits 0"
assert_eq "$([ -e "$SHAI_HOME/sessions/$SID.latest.json" ] && echo yes || echo no)" "yes" \
  "latest.json was rebuilt, not deleted"
assert_eq "$(cat "$SHAI_HOME/sessions/$SID.latest.json")" \
  "$(tail -n 1 "$SHAI_HOME/sessions/$SID.jsonl")" \
  "latest.json is byte-equal to the log's last line — rebuilt, not merely changed"
assert_eq "$(jq -S . "$SHAI_HOME/sessions/$SID.latest.json")" \
  "$(tail -n 1 "$SHAI_HOME/sessions/$SID.jsonl" | jq -S .)" \
  "latest.json is JSON-equal to the log's last event"
assert_contains "$ERR" "repair: rebuild $SHAI_HOME/sessions/$SID.latest.json (S5)" \
  "the repair line names the rebuild"

desc "S6 repair pair: --fix deletes both halves of the stillborn pair"
setup_home
fixture_session sess_20260810T120000_aabbccdd "$(sess_event message system '{"text":"seed"}')"
: >"$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.latest.json"
ERR=$("$FSCK" --fix --check S6 2>&1 >/dev/null)
assert_eq "$?" "0" "S6-only fix exits 0"
assert_eq "$([ -e "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.jsonl" ] && echo yes || echo no)" "no" \
  "the stillborn session log was deleted"
assert_eq "$([ -e "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.latest.json" ] && echo yes || echo no)" "no" \
  "the stillborn latest.json was deleted"
assert_contains "$ERR" \
  "repair: delete pair $SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.jsonl and $SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.latest.json (S6)" \
  "the repair line names both halves of the pair"

desc "R1 repair pair: --fix rmdir's the wholly empty run directory"
setup_home
mkdir -p "$SHAI_HOME/runs/run_20260810T120000_aabbccdd"
ERR=$("$FSCK" --fix --check R1 2>&1 >/dev/null)
assert_eq "$?" "0" "R1-only fix exits 0"
assert_eq "$([ -d "$SHAI_HOME/runs/run_20260810T120000_aabbccdd" ] && echo yes || echo no)" "no" \
  "the empty run directory was removed"
assert_contains "$ERR" "repair: delete $SHAI_HOME/runs/run_20260810T120000_aabbccdd (R1)" \
  "the repair line names the run directory"

desc "R5 repair pair: --fix deletes the orphan dump, leaves the run log untouched"
setup_home
ev="$(fixture_event message user '{"text":"hi"}' run_20260810T120000_aabbccdd sess_20260810T120000_aabbccdd span_1)"
fixture_session sess_20260810T120000_aabbccdd "$ev"
fixture_run run_20260810T120000_aabbccdd sess_20260810T120000_aabbccdd "$ev"
fixture_span_dump run_20260810T120000_aabbccdd span_9 request
LOG_HASH_BEFORE="$(sha256sum "$SHAI_HOME/runs/run_20260810T120000_aabbccdd/events.jsonl")"
ERR=$("$FSCK" --fix --check R5 2>&1 >/dev/null)
assert_eq "$?" "0" "R5-only fix exits 0"
assert_eq "$([ -e "$SHAI_HOME/runs/run_20260810T120000_aabbccdd/span_9-request.json" ] && echo yes || echo no)" "no" \
  "the orphan dump was deleted"
assert_eq "$(sha256sum "$SHAI_HOME/runs/run_20260810T120000_aabbccdd/events.jsonl")" "$LOG_HASH_BEFORE" \
  "the run log is byte-identical after the R5 repair"
assert_contains "$ERR" \
  "repair: delete $SHAI_HOME/runs/run_20260810T120000_aabbccdd/span_9-request.json (R5)" \
  "the repair line names the dump"

desc "R6 repair pair: --fix deletes the dead run directory"
setup_home
fixture_run run_20260810T120000_aabbccdd sess_20260810T120000_aabbccdd \
  "$(fixture_event error system '{"text":"boom"}')"
ERR=$("$FSCK" --fix --check R6 2>&1 >/dev/null)
assert_eq "$?" "0" "R6-only fix exits 0"
assert_eq "$([ -d "$SHAI_HOME/runs/run_20260810T120000_aabbccdd" ] && echo yes || echo no)" "no" \
  "the dead run directory was deleted"
assert_contains "$ERR" "repair: delete $SHAI_HOME/runs/run_20260810T120000_aabbccdd (R6)" \
  "the repair line names the run directory"

# --- R6 safety: two adjacent uncommitted runs, one resumable and one dead. --fix
#     deletes only the dead one — deleting replayable work is the single worst thing
#     this tool could do, so both halves get explicit assertions ---
desc "R6 safety: --fix deletes the dead run, keeps the resumable one"
setup_home
fixture_run run_20260903T043418_67e3340f sess_a "$(fixture_event message user '{"text":"hi"}')"
fixture_run run_20260903T043419_89abcdef sess_b "$(fixture_event error system '{"text":"boom"}')"
ERR=$("$FSCK" --fix --check R6 2>&1 >/dev/null)
assert_eq "$?" "1" "the resumable run stays unfixable (exit 1)"
assert_eq "$([ -d "$SHAI_HOME/runs/run_20260903T043418_67e3340f" ] && echo yes || echo no)" "yes" \
  "the resumable run still exists"
assert_eq "$([ -d "$SHAI_HOME/runs/run_20260903T043419_89abcdef" ] && echo yes || echo no)" "no" \
  "the dead run was deleted"
assert_contains "$ERR" "repair: delete $SHAI_HOME/runs/run_20260903T043419_89abcdef (R6)" \
  "the repair line names the dead run directory"
assert_contains "$ERR" \
  "manual: R6 $SHAI_HOME/runs/run_20260903T043418_67e3340f/events.jsonl — shai-retry --run run_20260903T043418_67e3340f" \
  "the refused resumable run prints its resume command"

# --- scoping: --fix honors --check, --store, and --after exactly like the scan ---
desc "--fix scoping: --check S6 repairs only stillborn sessions"
setup_home
orphan_latest sess_20260810T120000_aabbccdd
fixture_session sess_20260811T120000_aabbccdd "$(sess_event message system '{"text":"seed"}')"
: >"$SHAI_HOME/sessions/sess_20260811T120000_aabbccdd.latest.json"
OUT=$("$FSCK" --fix --check S6 2>/dev/null)
assert_eq "$?" "0" "--fix --check S6 exits 0 (its one finding was repaired)"
assert_eq "$([ -e "$SHAI_HOME/sessions/sess_20260811T120000_aabbccdd.jsonl" ] && echo yes || echo no)" "no" \
  "the stillborn log was deleted"
assert_eq "$([ -e "$SHAI_HOME/sessions/sess_20260811T120000_aabbccdd.latest.json" ] && echo yes || echo no)" "no" \
  "the stillborn latest.json was deleted"
assert_eq "$([ -e "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.latest.json" ] && echo yes || echo no)" "yes" \
  "the S4 orphan in the same store was left untouched by --check S6"

desc "--fix scoping: --store runs and --after both narrow the worklist"
setup_home
orphan_latest sess_20260810T120000_aabbccdd
mkdir -p "$SHAI_HOME/runs/run_20260810T120000_aabbccdd"
"$FSCK" --fix --store runs >/dev/null 2>&1
assert_eq "$([ -d "$SHAI_HOME/runs/run_20260810T120000_aabbccdd" ] && echo yes || echo no)" "no" \
  "--fix --store runs deleted the empty run directory"
assert_eq "$([ -e "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.latest.json" ] && echo yes || echo no)" "yes" \
  "--fix --store runs left the sessions orphan alone"
setup_home
orphan_latest sess_20260810T120000_aabbccdd
orphan_latest sess_20260812T120000_eeff0011
"$FSCK" --fix --after 2026-08-11 --check S4 >/dev/null 2>&1
assert_eq "$([ -e "$SHAI_HOME/sessions/sess_20260812T120000_eeff0011.latest.json" ] && echo yes || echo no)" "no" \
  "--fix --after repaired the in-window orphan"
assert_eq "$([ -e "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.latest.json" ] && echo yes || echo no)" "yes" \
  "--fix --after left the out-of-window orphan alone"

# --- --dry-run prints the same plan --fix then executes, and writes nothing ---
desc "--dry-run prints exactly the plan --fix executes; the store stays dirty"
setup_home
build_fixable_store
DRY_ERR=$("$FSCK" --fix --dry-run 2>&1 >/dev/null)
assert_eq "$?" "0" "--fix --dry-run exits 0 (the plan repairs everything found)"
assert_eq "$(printf '%s\n' "$DRY_ERR" | grep -c '^repair: ' || true)" "6" \
  "dry-run prints all six repair lines"
OUT=$("$FSCK" --fix --dry-run 2>/dev/null)
assert_row_count "$OUT" 6 "dry-run table still renders one row per finding"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "after dry-run the store is still dirty"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "6" "after dry-run all six findings remain"
FIX_ERR=$("$FSCK" --fix 2>&1 >/dev/null)
dry_plan="$(printf '%s\n' "$DRY_ERR" | grep '^repair: ')"
fix_plan="$(printf '%s\n' "$FIX_ERR" | grep '^repair: ')"
assert_eq "$dry_plan" "$fix_plan" "dry-run printed exactly the plan --fix then executed"

# --- rescan-clean: a store holding every fixable class at once is clean after --fix;
#     adjacent, a store holding every unfixable class still reports them all — the
#     contrast that proves the first result came from repair, not dead checks ---
desc "--fix rescan-clean: every fixable class repaired, fresh scan clean (exit 0)"
setup_home
build_fixable_store
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "the all-fixable store is dirty before --fix"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "6" "six fixable findings before --fix"
ERR=$("$FSCK" --fix 2>&1 >/dev/null)
assert_eq "$?" "0" "--fix repaired everything it found (exit 0)"
assert_eq "$(printf '%s\n' "$ERR" | grep -c '^repair: ' || true)" "6" \
  "one repair: line per repaired finding"
assert_eq "$(printf '%s\n' "$ERR" | grep -c '^manual: ' || true)" "0" \
  "no manual: lines when nothing is refused"
OUT=$("$FSCK" --json)
assert_eq "$?" "0" "rescan after --fix exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "rescan after --fix reports zero findings"
OUT=$("$FSCK" 2>/dev/null)
assert_eq "$OUT" "no problems found (2 sessions, 1 run, 0 ledgers, 0 failure logs)" \
  "the clean line counts the surviving healthy items"

desc "--fix contrast: every unfixable class is refused, reported with a manual remedy, and re-reported by the next scan"
setup_home
build_unfixable_store
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "the all-unfixable store exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "21" "exactly 21 findings — one per refused check"
assert_eq "$(printf '%s' "$OUT" | jq -r '[.[].check] | sort | join(",")')" \
  "F1,F2,F3,F4,L1,L2,L3,L4,R1,R2,R3,R4,R6,R7,S1,S2,S3,S7,S8,S9,X1" \
  "every refused check fired exactly once"
BEFORE="$(store_checksum)"
ERR=$("$FSCK" --fix 2>&1 >/dev/null)
assert_eq "$?" "1" "--fix on the all-unfixable store exits 1"
assert_not_contains "$ERR" "repair:" "--fix repairs nothing it cannot safely repair"
assert_eq "$(store_checksum)" "$BEFORE" "--fix changed nothing in the all-unfixable store"
assert_eq "$(printf '%s\n' "$ERR" | grep -c '^manual: ' || true)" "21" \
  "one manual: line per refused finding"
REFUSED=(S1 S2 S3 S7 S8 S9 R1 R2 R3 R4 R6 R7 L1 L2 L3 L4 F1 F2 F3 F4 X1)
for id in "${REFUSED[@]}"; do
  assert_contains "$ERR" "manual: $id " "--fix prints a named manual remedy for $id"
done
# The contrast half: the checks still fire after --fix — all 21 findings re-reported,
# proving the fixable store's clean rescan came from repair, not from dead checks.
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "rescan of the all-unfixable store still exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "21" "rescan still reports all 21 findings"

# --- idempotency: a second --fix repairs nothing and changes nothing ---
desc "--fix idempotency: the second run repairs nothing and the store is byte-identical"
setup_home
build_fixable_store
"$FSCK" --fix >/dev/null 2>&1
assert_eq "$?" "0" "first --fix exits 0"
SNAP="$(store_checksum)"
ERR=$("$FSCK" --fix 2>&1 >/dev/null)
assert_eq "$?" "0" "second --fix exits 0"
assert_not_contains "$ERR" "repair:" "the second run reports zero repairs"
assert_eq "$(store_checksum)" "$SNAP" "the store is byte-identical after the second run"

# --- exit codes: 0 repaired-everything (above), 1 unfixable remain (above), 3 when a
#     repair cannot complete. The S5 rebuild guard drives the 3 directly: a directory
#     sitting where .latest.json belongs makes the rebuild fail ---
desc "--fix exit 3: a repair that cannot complete"
setup_home
fixture_session sess_20260810T120000_aabbccdd "$(sess_event message user '{"text":"hi"}')"
rm "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.latest.json"
mkdir "$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.latest.json"
assert_fails 3 "error: cannot rebuild" "--fix fails a repair it cannot complete" -- "$FSCK" --fix

finish
