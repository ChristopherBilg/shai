#!/bin/bash
# test_ledgers.sh — tests for the shai-ledgers work-ledger observability filter
# Covers: summary mode, entry mode, prefix matching, date filtering, --recent, --json, malformed ledgers
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LEDGERS="$DIR/shai-ledgers"

# --- Fixtures ---
setup_ledgers() {
  export SHAI_HOME
  SHAI_HOME=$(mktemp -d)
  _CLEANUP_DIRS+=("$SHAI_HOME")
  mkdir -p "$SHAI_HOME/ledgers"
}

# ledger_entry <key> <ts> [session_id]: one JSONL ledger line, exactly as wf_mark writes it.
ledger_entry() {
  jq -nc --arg k "$1" --arg ts "$2" --arg sid "${3:-sess_20260810T140000_aabbccdd}" \
    '{key: $k, ts: $ts, session_id: $sid}'
}

# make_ledger <workflow_name> [entry...]: write entries to ledgers/<workflow_name>.jsonl.
# With no entries the ledger is created empty (the zero-entry case).
make_ledger() {
  local name="$1" entry
  shift
  mkdir -p "$SHAI_HOME/ledgers"
  : >"$SHAI_HOME/ledgers/$name.jsonl"
  for entry in "$@"; do
    printf '%s\n' "$entry" >>"$SHAI_HOME/ledgers/$name.jsonl"
  done
}

# --- Summary mode ---
desc "empty state: no output"
setup_ledgers
OUT=$("$LEDGERS" 2>/dev/null)
assert_eq "$OUT" "" "empty dir produces no output"

desc "empty state: --json produces empty array"
setup_ledgers
rm -rf "$SHAI_HOME/ledgers"
OUT=$("$LEDGERS" --json)
assert_eq "$OUT" "[]" "missing ledgers dir --json"

desc "single ledger: correct metrics"
setup_ledgers
make_ledger "issue_dispatcher" \
  "$(ledger_entry "issue:owner/repo:1" "2026-08-01T09:15:00Z")" \
  "$(ledger_entry "issue:owner/repo:2" "2026-08-10T14:30:00Z")" \
  "$(ledger_entry "issue:owner/repo:3" "2026-08-14T11:30:00Z")"
OUT=$("$LEDGERS" --json | jq '.[0]')
assert_eq "$(printf '%s' "$OUT" | jq -r '.workflow')" "issue_dispatcher" "workflow name"
assert_eq "$(printf '%s' "$OUT" | jq '.entries')" "3" "entry count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.oldest')" "2026-08-01T09:15:00Z" "oldest ts"
assert_eq "$(printf '%s' "$OUT" | jq -r '.latest')" "2026-08-14T11:30:00Z" "latest ts"

desc "multiple ledgers: sorted alphabetically"
setup_ledgers
make_ledger "z_workflow" "$(ledger_entry "k:1" "2026-08-01T09:00:00Z")"
make_ledger "a_workflow" "$(ledger_entry "k:2" "2026-08-02T09:00:00Z")"
OUT=$("$LEDGERS" --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "both ledgers listed"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].workflow')" "a_workflow" "first is alphabetically first"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[1].workflow')" "z_workflow" "second is alphabetically last"

desc "empty ledger file: zero entries, null dates"
setup_ledgers
make_ledger "empty_workflow"
OUT=$("$LEDGERS" --json | jq '.[0]')
assert_eq "$(printf '%s' "$OUT" | jq '.entries')" "0" "zero entries"
assert_eq "$(printf '%s' "$OUT" | jq '.oldest')" "null" "oldest null"
assert_eq "$(printf '%s' "$OUT" | jq '.latest')" "null" "latest null"

desc "--recent 1: only the last workflow"
setup_ledgers
make_ledger "a_workflow" "$(ledger_entry "k:1" "2026-08-01T09:00:00Z")"
make_ledger "z_workflow" "$(ledger_entry "k:2" "2026-08-02T09:00:00Z")"
OUT=$("$LEDGERS" --recent 1 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "recent 1 count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].workflow')" "z_workflow" "recent 1 is alphabetically last"

desc "--recent 0: no workflows"
setup_ledgers
make_ledger "a_workflow" "$(ledger_entry "k:1" "2026-08-01T09:00:00Z")"
OUT=$("$LEDGERS" --recent 0 --json)
assert_eq "$OUT" "[]" "recent 0 produces empty array"

desc "--after: counts and range reflect the filtered entries"
setup_ledgers
make_ledger "issue_dispatcher" \
  "$(ledger_entry "k:1" "2026-08-01T09:00:00Z")" \
  "$(ledger_entry "k:2" "2026-08-12T09:00:00Z")" \
  "$(ledger_entry "k:3" "2026-08-14T09:00:00Z")"
OUT=$("$LEDGERS" --after 2026-08-12 --json | jq '.[0]')
assert_eq "$(printf '%s' "$OUT" | jq '.entries')" "2" "after filter entry count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.oldest')" "2026-08-12T09:00:00Z" "after filter oldest"
assert_eq "$(printf '%s' "$OUT" | jq -r '.latest')" "2026-08-14T09:00:00Z" "after filter latest"

desc "--before: counts and range reflect the filtered entries"
setup_ledgers
make_ledger "issue_dispatcher" \
  "$(ledger_entry "k:1" "2026-08-01T09:00:00Z")" \
  "$(ledger_entry "k:2" "2026-08-12T09:00:00Z")" \
  "$(ledger_entry "k:3" "2026-08-14T09:00:00Z")"
OUT=$("$LEDGERS" --before 2026-08-12 --json | jq '.[0]')
assert_eq "$(printf '%s' "$OUT" | jq '.entries')" "2" "before filter entry count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.oldest')" "2026-08-01T09:00:00Z" "before filter oldest"
assert_eq "$(printf '%s' "$OUT" | jq -r '.latest')" "2026-08-12T09:00:00Z" "before filter latest"

desc "--after + --before: intersection of the two bounds"
setup_ledgers
make_ledger "issue_dispatcher" \
  "$(ledger_entry "k:1" "2026-08-01T09:00:00Z")" \
  "$(ledger_entry "k:2" "2026-08-12T09:00:00Z")" \
  "$(ledger_entry "k:3" "2026-08-14T09:00:00Z")"
OUT=$("$LEDGERS" --after 2026-08-02 --before 2026-08-13 --json | jq '.[0]')
assert_eq "$(printf '%s' "$OUT" | jq '.entries')" "1" "combined filter entry count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.oldest')" "2026-08-12T09:00:00Z" "combined filter oldest"
assert_eq "$(printf '%s' "$OUT" | jq -r '.latest')" "2026-08-12T09:00:00Z" "combined filter latest"

desc "date filter excluding every entry: workflow omitted"
setup_ledgers
make_ledger "in_range" "$(ledger_entry "k:1" "2026-08-12T09:00:00Z")"
make_ledger "out_of_range" "$(ledger_entry "k:2" "2026-07-01T09:00:00Z")"
OUT=$("$LEDGERS" --after 2026-08-01 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "only the in-range workflow listed"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].workflow')" "in_range" "excluded workflow absent"

desc "human output: header and workflow name present"
setup_ledgers
make_ledger "issue_dispatcher" "$(ledger_entry "k:1" "2026-08-01T09:00:00Z")"
OUT=$("$LEDGERS")
assert_contains "$OUT" "WORKFLOW" "header present"
assert_contains "$OUT" "ENTRIES" "entries column present"
assert_contains "$OUT" "issue_dispatcher" "workflow name in output"

desc "human output: empty ledger shows -- for the dates"
setup_ledgers
make_ledger "empty_workflow"
OUT=$("$LEDGERS")
assert_contains "$OUT" "empty_workflow" "empty ledger still listed"
assert_contains "$OUT" "--" "human output shows -- for missing dates"

desc "malformed ledger file: bad lines dropped, workflow row preserved"
setup_ledgers
make_ledger "good_workflow" "$(ledger_entry "k:1" "2026-08-01T09:00:00Z")"
# Simulate a crash mid-append: a truncated, unparseable line with no closing braces.
printf '{"key":"k:2","ts":"2026-08-02T09:00:00Z","session_id":"sess_' >"$SHAI_HOME/ledgers/bad_workflow.jsonl"
OUT=$("$LEDGERS" --json 2>/dev/null)
ERR=$("$LEDGERS" 2>&1 >/dev/null)
assert_eq "$?" "0" "malformed ledger does not abort the run (exit 0)"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "both ledgers listed (bad lines dropped, not whole file)"
assert_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.workflow == "good_workflow")][0].entries')" "1" "good workflow entries correct"
assert_eq "$(printf '%s' "$OUT" | jq '[.[] | select(.workflow == "bad_workflow")][0].entries')" "0" "malformed ledger shows zero valid entries"
assert_contains "$ERR" "warning" "warning printed to stderr for the malformed ledger"
assert_contains "$ERR" "dropped" "warning reports dropped lines"

# --- Entry mode ---
desc "--workflow: lists the ledger's entries"
setup_ledgers
make_ledger "issue_dispatcher" \
  "$(ledger_entry "issue:owner/repo:42" "2026-08-10T14:30:00Z" "sess_20260810T143000_abcd1234")" \
  "$(ledger_entry "issue:owner/repo:57" "2026-08-12T09:15:00Z" "sess_20260812T091500_efgh5678")"
OUT=$("$LEDGERS" --workflow issue_dispatcher --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "2" "entry count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].key')" "issue:owner/repo:42" "first key"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].marked')" "2026-08-10T14:30:00Z" "first marked ts"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].session_id')" "sess_20260810T143000_abcd1234" "first session id"

desc "--workflow: entries sorted chronologically by ts"
setup_ledgers
make_ledger "issue_dispatcher" \
  "$(ledger_entry "k:late" "2026-08-14T09:00:00Z")" \
  "$(ledger_entry "k:early" "2026-08-01T09:00:00Z")" \
  "$(ledger_entry "k:mid" "2026-08-07T09:00:00Z")"
OUT=$("$LEDGERS" --workflow issue_dispatcher --json)
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].key')" "k:early" "earliest first"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[1].key')" "k:mid" "middle second"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[2].key')" "k:late" "latest last"

desc "--workflow prefix: unambiguous prefix resolves"
setup_ledgers
make_ledger "issue_dispatcher" "$(ledger_entry "k:1" "2026-08-01T09:00:00Z")"
OUT=$("$LEDGERS" --workflow issue_d --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "prefix match works"

desc "--workflow prefix: ambiguous produces an error"
setup_ledgers
make_ledger "issue_dispatcher" "$(ledger_entry "k:1" "2026-08-01T09:00:00Z")"
make_ledger "issue_worker" "$(ledger_entry "k:2" "2026-08-01T09:00:00Z")"
assert_fails 1 "error: ambiguous prefix \"issue_\"" "ambiguous prefix" -- "$LEDGERS" --workflow issue_
ERR=$("$LEDGERS" --workflow issue_ 2>&1 >/dev/null)
assert_contains "$ERR" "ambiguous" "stderr says ambiguous"
assert_contains "$ERR" "issue_dispatcher" "stderr lists the first candidate"
assert_contains "$ERR" "issue_worker" "stderr lists the second candidate"

desc "--workflow prefix: no match produces an error"
setup_ledgers
make_ledger "issue_dispatcher" "$(ledger_entry "k:1" "2026-08-01T09:00:00Z")"
assert_fails 1 "error: no match for \"nope\"" "no match prefix" -- "$LEDGERS" --workflow nope
ERR=$("$LEDGERS" --workflow nope 2>&1 >/dev/null)
assert_contains "$ERR" "no match" "stderr says no match"

desc "--workflow + --recent 1: only the latest entry"
setup_ledgers
make_ledger "issue_dispatcher" \
  "$(ledger_entry "k:1" "2026-08-01T09:00:00Z")" \
  "$(ledger_entry "k:2" "2026-08-07T09:00:00Z")" \
  "$(ledger_entry "k:3" "2026-08-14T09:00:00Z")"
OUT=$("$LEDGERS" --workflow issue_dispatcher --recent 1 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "recent 1 entry count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].key')" "k:3" "recent 1 is the latest entry"

desc "--workflow + --after: filters entries"
setup_ledgers
make_ledger "issue_dispatcher" \
  "$(ledger_entry "k:1" "2026-08-01T09:00:00Z")" \
  "$(ledger_entry "k:2" "2026-08-14T09:00:00Z")"
OUT=$("$LEDGERS" --workflow issue_dispatcher --after 2026-08-10 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "after filter entry count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].key')" "k:2" "after filter entry key"

desc "--workflow + --before: filters entries"
setup_ledgers
make_ledger "issue_dispatcher" \
  "$(ledger_entry "k:1" "2026-08-01T09:00:00Z")" \
  "$(ledger_entry "k:2" "2026-08-14T09:00:00Z")"
OUT=$("$LEDGERS" --workflow issue_dispatcher --before 2026-08-10 --json)
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "before filter entry count"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].key')" "k:1" "before filter entry key"

desc "--workflow --json: valid array with the documented shape"
setup_ledgers
make_ledger "issue_dispatcher" "$(ledger_entry "issue:owner/repo:42" "2026-08-10T14:30:00Z")"
OUT=$("$LEDGERS" --workflow issue_dispatcher --json)
assert_eq "$(printf '%s' "$OUT" | jq -r 'type')" "array" "output is a JSON array"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0] | keys_unsorted | join(",")')" \
  "key,marked,session_id" "entry object shape"

desc "--workflow: empty ledger yields an empty array"
setup_ledgers
make_ledger "empty_workflow"
OUT=$("$LEDGERS" --workflow empty_workflow --json)
assert_eq "$OUT" "[]" "empty ledger entry mode --json"

desc "--workflow human output: header and key present"
setup_ledgers
make_ledger "issue_dispatcher" "$(ledger_entry "issue:owner/repo:42" "2026-08-10T14:30:00Z")"
OUT=$("$LEDGERS" --workflow issue_dispatcher)
assert_contains "$OUT" "KEY" "KEY header present"
assert_contains "$OUT" "MARKED" "MARKED header present"
assert_contains "$OUT" "SESSION" "SESSION header present"
assert_contains "$OUT" "issue:owner/repo:42" "key in output"

desc "--workflow: malformed entry dropped, good entries survive"
setup_ledgers
make_ledger "issue_dispatcher" "$(ledger_entry "k:good" "2026-08-01T09:00:00Z")"
# Simulate a crash mid-append: a truncated trailing line with no closing braces.
printf '{"key":"k:trunc","ts":"2026-08-02T09:00:00Z","session_id":"sess_' >>"$SHAI_HOME/ledgers/issue_dispatcher.jsonl"
OUT=$("$LEDGERS" --workflow issue_dispatcher --json 2>/dev/null)
ERR=$("$LEDGERS" --workflow issue_dispatcher 2>&1 >/dev/null)
assert_eq "$?" "0" "malformed entry does not abort the run (exit 0)"
assert_eq "$(printf '%s' "$OUT" | jq 'length')" "1" "malformed entry excluded"
assert_eq "$(printf '%s' "$OUT" | jq -r '.[0].key')" "k:good" "good entry still listed"
assert_contains "$ERR" "warning" "warning printed to stderr for the malformed entry"
assert_contains "$ERR" "dropped" "warning reports dropped line count"

# --- Error handling ---
desc "--workflow path traversal: / rejected"
setup_ledgers
assert_fails 1 "error: --workflow must not contain / or .. (got \"../sessions/foo\")" "slash in workflow name" -- "$LEDGERS" --workflow "../sessions/foo"
ERR=$("$LEDGERS" --workflow "../sessions/foo" 2>&1 >/dev/null || true)
assert_contains "$ERR" "must not contain" "error message for path traversal"

desc "--workflow path traversal: .. rejected"
setup_ledgers
assert_fails 1 "error: --workflow must not contain / or .. (got \"..ledger\")" "dotdot in workflow name" -- "$LEDGERS" --workflow "..ledger"
ERR=$("$LEDGERS" --workflow "..ledger" 2>&1 >/dev/null || true)
assert_contains "$ERR" "must not contain" "error message for dotdot"

desc "invalid args: exit 1"
setup_ledgers
assert_fails 1 "error: unknown option: --bogus" "unknown flag" -- "$LEDGERS" --bogus
assert_fails 1 "error: --workflow requires a name or prefix" "--workflow with no value" -- "$LEDGERS" --workflow
assert_fails 1 "error: --recent requires a value" "--recent with no value" -- "$LEDGERS" --recent
assert_fails 1 "error: --recent value must be an integer" "--recent with a non-integer value" -- "$LEDGERS" --recent abc
assert_fails 1 "error: --after date must be YYYY-MM-DD" "--after with a bad date format" -- "$LEDGERS" --after not-a-date
assert_fails 1 "error: --before date must be YYYY-MM-DD" "--before with a bad date format" -- "$LEDGERS" --before 2026/08/10

finish
