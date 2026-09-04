#!/bin/bash
# test_fsck.sh — tests for shai-fsck store-integrity scanner
# Covers: S4 orphan .latest.json detection, S1-S3/S5-S9 session-store contract checks,
#         healthy #387-built store reports clean (exit 0), the eight-key finding contract,
#         --json findings array ([] when clean, type+length asserted), table renderer row
#         counts, digest on stderr, --store/--check/--after/--before scoping, --summary,
#         --fix/--dry-run parsing, usage errors (exit 2) with distinct messages,
#         operational failures (exit 3), L1-L4 ledger checks, F1-F4 failure checks, X1
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

# build_sink: nine sessions, one per check id, each corrupt in exactly one way — the
# isolation store for the --check loop below. Every corruption is staged in the open:
# fixture builders produce the healthy shape first, then exactly one break is applied, so
# a full scan of the sink must report exactly one finding per check id.
build_sink() {
  local ev tmp
  mkdir -p "$SHAI_HOME/sessions"
  # S1: healthy event plus a garbage line (line 2 is not a JSON object)
  ev="$(fixture_event message user '{"text":"a"}')"
  fixture_session sess_s1 "$ev"
  printf 'not json\n' >>"$SHAI_HOME/sessions/sess_s1.jsonl"
  # S2: an event with its source key deleted (log and latest rewritten together)
  ev="$(fixture_event message user '{"text":"b"}')"
  fixture_session sess_s2 "$ev"
  tmp="$(mktemp)"
  jq -c 'del(.source)' "$SHAI_HOME/sessions/sess_s2.jsonl" >"$tmp"
  mv "$tmp" "$SHAI_HOME/sessions/sess_s2.jsonl"
  cp "$SHAI_HOME/sessions/sess_s2.jsonl" "$SHAI_HOME/sessions/sess_s2.latest.json"
  # S3: first of two events stamped with the wrong session id (latest still mirrors the
  #     untouched second event)
  fixture_session sess_s3 \
    "$(fixture_event message user '{"text":"c1"}')" \
    "$(fixture_event message user '{"text":"c2"}')"
  tmp="$(mktemp)"
  head -n 1 "$SHAI_HOME/sessions/sess_s3.jsonl" | jq -c '.meta.session_id = "elsewhere"' >"$tmp"
  sed -n '2p' "$SHAI_HOME/sessions/sess_s3.jsonl" >>"$tmp"
  mv "$tmp" "$SHAI_HOME/sessions/sess_s3.jsonl"
  # S4: an orphan .latest.json
  orphan_latest sess_s4
  # S5: three events with an empty .latest.json (multi-event, so never stillborn)
  fixture_session sess_s5 \
    "$(fixture_event message user '{"text":"d"}')" \
    "$(fixture_event message assistant '{"content":"hi","tool_calls":[],"finish_reason":"stop"}')" \
    "$(fixture_event message user '{"text":"e"}')"
  : >"$SHAI_HOME/sessions/sess_s5.latest.json"
  # S6: the stillborn pair — one system event, empty .latest.json
  fixture_session sess_s6 "$(fixture_event message system '{"text":"seed"}')"
  : >"$SHAI_HOME/sessions/sess_s6.latest.json"
  # S7: a tool_result whose id no preceding assistant event announced
  fixture_session sess_s7 \
    "$(fixture_event message assistant '{"content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"list_directory","arguments":"{}"}}],"finish_reason":"tool_calls"}')" \
    "$(fixture_event tool_result tool '{"tool_call_id":"ghost","content":"nope","is_error":false}')"
  # S8: an unanswered tool call on an earlier assistant event (the final assistant has none)
  fixture_session sess_s8 \
    "$(fixture_event message user '{"text":"f"}')" \
    "$(fixture_event message assistant '{"content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"list_directory","arguments":"{}"}}],"finish_reason":"tool_calls"}')" \
    "$(fixture_event message assistant '{"content":"done","tool_calls":[],"finish_reason":"stop"}')"
  # S9: an unrecognized schema version
  ev="$(fixture_event message user '{"text":"g"}')"
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
desc "healthy store from fixture builders: clean, exit 0"
setup_home
ev="$(fixture_event message user '{"text":"hello"}')"
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
# directly (fixture_session always writes both files, so no corruption is needed).
desc "S4: .latest.json with a sibling session log is not an orphan"
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(fixture_event message user '{"text":"hello"}')"
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
mkdir -p "$SHAI_HOME/runs/run_20260810T120000_aabbccdd"
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
assert_fails 2 "error: unknown check id: R1" "unknown check id" -- "$FSCK" --check R1
assert_fails 2 "error: --check requires a check id" "--check missing value" -- "$FSCK" --check

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
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(fixture_event message user '{"text":"hello"}')"
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
  "$(fixture_event message user '{"text":"hello"}')"
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
ev="$(fixture_event message user '{"text":"hello"}')"
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
ev="$(fixture_event message user '{"text":"hello"}')"
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
  "$(fixture_event message user '{"text":"hello"}')"
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
ev1="$(fixture_event message user '{"text":"a"}')"
ev2="$(fixture_event message user '{"text":"b"}')"
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
  "$(fixture_event message user '{"text":"a"}')"
printf 'this is not json\n' >>"$SHAI_HOME/sessions/sess_20260810T120000_aabbccdd.jsonl"
OUT=$("$FSCK" --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "line 2 is not a JSON object" \
  "a non-blank garbage line carries its own summary"
# Healthy negative control, written next to the positives. Mutation-checked: without the
# S1 emission the blank-tail fixture scanned clean (exit 0, zero findings).
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(fixture_event message user '{"text":"hello"}')"
OUT=$("$FSCK" --check S1 --json)
assert_eq "$?" "0" "a clean one-line log exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "a clean log yields zero S1"

# --- S2: every event carries top-level type, source, and payload (error) ---
desc "S2: an event missing the source key yields exactly one S2; a stamped event yields zero"
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(fixture_event message user '{"text":"hello"}')"
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
  "event 1 missing type, source, or payload" "the summary names the contract keys"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].fixable')" "false" "S2 is not fixable"
# Healthy negative control. Mutation-checked: without the S2 emission the sourceless
# event scanned clean (exit 0, zero findings).
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(fixture_event message user '{"text":"hello"}')"
OUT=$("$FSCK" --check S2 --json)
assert_eq "$?" "0" "a stamped event exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "a stamped event yields zero S2"

# --- S3: every event with a meta.session_id matches the filename stem (error).
#     Unstamped events — no meta at all — are skipped, never flagged ---
desc "S3: a mismatched meta.session_id yields exactly one S3; a legacy unstamped log yields zero"
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(fixture_event message user '{"text":"a"}')" \
  "$(fixture_event message user '{"text":"b"}')"
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
  "$(fixture_event message system '{"text":"seed"}')"
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
  "$(fixture_event message user '{"text":"a"}')" \
  "$(fixture_event message assistant '{"content":"hi","tool_calls":[],"finish_reason":"stop"}')" \
  "$(fixture_event message user '{"text":"b"}')"
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
desc "S5: missing, unparseable, and stale latest.json each yield exactly one S5; a mirrored latest yields zero"
setup_home
ev="$(fixture_event message user '{"text":"hello"}')"
SID=$(fixture_session sess_20260810T120000_aabbccdd "$ev")
rm "$SHAI_HOME/sessions/$SID.latest.json"
OUT=$("$FSCK" --json)
assert_eq "$?" "1" "missing latest exits 1"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "exactly one finding (S5)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "S5" "the finding is S5"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "latest.json missing" \
  "a missing latest.json is named"
setup_home
ev="$(fixture_event message user '{"text":"hello"}')"
SID=$(fixture_session sess_20260810T120000_aabbccdd "$ev")
printf 'garbage\n' >"$SHAI_HOME/sessions/$SID.latest.json"
OUT=$("$FSCK" --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].check')" "S5" "the finding is S5"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].summary')" "latest.json does not parse as JSON" \
  "an unparseable latest.json is named"
setup_home
SID=$(fixture_session sess_20260810T120000_aabbccdd \
  "$(fixture_event message user '{"text":"a"}')" \
  "$(fixture_event message user '{"text":"b"}')")
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
  "$(fixture_event message user '{"text":"a"}')" \
  "$(fixture_event message user '{"text":"b"}')"
OUT=$("$FSCK" --check S5 --json)
assert_eq "$?" "0" "a mirrored latest exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "a mirrored latest yields zero S5"

# --- S6 negative: a seeded session whose latest.json mirrors the system event is not
#     stillborn — the empty latest is what makes the pair ---
desc "S6: a seeded session with a mirrored latest.json yields zero S6"
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(fixture_event message system '{"text":"seed"}')"
OUT=$("$FSCK" --check S6 --json)
assert_eq "$?" "0" "a mirrored system event exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" "a mirrored system event yields zero S6"

# --- S7: every tool_result's tool_call_id appears in a PRECEDING assistant event's
#     tool_calls (error). Ordering is part of the check, not just set membership: a
#     result matching a LATER assistant event is equally malformed ---
desc "S7: an unmatched tool_call_id yields exactly one S7; a result matching a later assistant event still fails"
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(fixture_event message assistant '{"content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"list_directory","arguments":"{}"}}],"finish_reason":"tool_calls"}')" \
  "$(fixture_event tool_result tool '{"tool_call_id":"ghost","content":"nope","is_error":false}')"
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
  "$(fixture_event tool_result tool '{"tool_call_id":"call1","content":"early","is_error":false}')" \
  "$(fixture_event message assistant '{"content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"list_directory","arguments":"{}"}}],"finish_reason":"tool_calls"}')"
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
  "$(fixture_event message assistant '{"content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"list_directory","arguments":"{}"}}],"finish_reason":"tool_calls"}')" \
  "$(fixture_event tool_result tool '{"tool_call_id":"call1","content":"ok","is_error":false}')"
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
  "$(fixture_event message user '{"text":"list files"}')" \
  "$(fixture_event message assistant '{"content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"list_directory","arguments":"{}"}}],"finish_reason":"tool_calls"}')"
OUT=$("$FSCK" --json)
assert_eq "$?" "0" "an interrupted session (unanswered calls on the final event) exits 0"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "0" \
  "the resumable tail is exempt — zero findings, zero S8"
# Mutation-checked by removing the final-assistant exemption: this same fixture then
# emitted exactly one S8 and the zero-findings assertion above went red. That is the
# state the check must not treat as corruption.
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(fixture_event message user '{"text":"a"}')" \
  "$(fixture_event message assistant '{"content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"list_directory","arguments":"{}"}}],"finish_reason":"tool_calls"}')" \
  "$(fixture_event message assistant '{"content":"done","tool_calls":[],"finish_reason":"stop"}')"
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
ev="$(fixture_event message user '{"text":"hello"}')"
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
# Healthy negative control: fixture_event always stamps version 1.0. Mutation-checked:
# without the S9 emission the unknown-version fixture scanned clean (exit 0, zero
# findings).
setup_home
fixture_session sess_20260810T120000_aabbccdd \
  "$(fixture_event message user '{"text":"hello"}')"
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
desc "one jq pass per store file: the S-family shares a single jq pass over the session log"
setup_home
SID=$(fixture_session sess_20260810T120000_aabbccdd \
  "$(fixture_event message user '{"text":"hello"}')" \
  "$(fixture_event message assistant '{"content":"hi","tool_calls":[],"finish_reason":"stop"}')")
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
OUT=$("$FSCK" --json)
assert_eq "$?" "0" "healthy session exits 0 under the counting jq stub"
assert_eq "$(grep -c "$SID.jsonl" "$JQ_LOG" || true)" "1" \
  "the session log is opened by exactly one jq pass"

# --- --check S1 … --check X1: every shipped id runs alone (each catalog entry is
#     reachable, and no id depends on another id's scan side effects) ---
desc "--check: each of the eighteen check ids runs alone"
for id in S1 S2 S3 S4 S5 S6 S7 S8 S9 L1 L2 L3 L4 F1 F2 F3 F4 X1; do
  setup_home
  RC=0
  "$FSCK" --check "$id" --json >/dev/null 2>&1 || RC=$?
  assert_eq "$RC" "0" "--check $id runs alone (exit 0 on an empty store)"
done

finish
