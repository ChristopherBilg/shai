#!/bin/bash
# test_fsck.sh — tests for shai-fsck store-integrity scanner
# Covers: S4 orphan .latest.json detection, healthy #387-built store reports clean (exit 0),
#         the eight-key finding contract, --json findings array ([] when clean, type+length
#         asserted), table renderer row counts, digest on stderr, --store/--check/--after/
#         --before scoping, --summary, --fix/--dry-run parsing, usage errors (exit 2) with
#         distinct messages, operational failures (exit 3)
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
assert_fails 2 "error: unknown check id: S9" "unknown check id" -- "$FSCK" --check S9
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
