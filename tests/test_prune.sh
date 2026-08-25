#!/bin/bash
# test_prune.sh — tests for shai-prune
# Covers: shai-prune — session/run/ledger/failure pruning, --dry-run, --before, confirmation, edge cases
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-prune"

new_home() {
  PHOME="$(mktemp -d)"
  _CLEANUP_DIRS+=("$PHOME")
  mkdir -p "$PHOME/sessions" "$PHOME/runs/run_001" "$PHOME/runs/run_002"
  printf '%s\n' '{}' >"$PHOME/sessions/sess_a.jsonl"
  printf '%s\n' '{}' >"$PHOME/sessions/sess_a.latest.json"
  printf '%s\n' '{}' >"$PHOME/sessions/sess_b.jsonl"
  printf '%s\n' '{}' >"$PHOME/sessions/sess_b.latest.json"
  printf '%s\n' '{}' >"$PHOME/runs/run_001/events.jsonl"
  printf '%s\n' '{}' >"$PHOME/runs/run_002/events.jsonl"
}

new_home_with_ledgers() {
  new_home
  mkdir -p "$PHOME/ledgers"
  printf '{"key":"pr:1","ts":"2026-08-01T00:00:00Z","session_id":"s1"}\n' >"$PHOME/ledgers/review.jsonl"
  printf '{"key":"item:1","ts":"2026-08-01T00:00:00Z","session_id":"s2"}\n' >"$PHOME/ledgers/poll.jsonl"
}

new_home_with_failures() {
  new_home_with_ledgers
  mkdir -p "$PHOME/failures"
  # review.jsonl mixes an old record and a recent record in one file
  printf '%s\n' \
    '{"ts":"2026-08-01T00:00:00Z","workflow":"review","run_id":null,"session_id":null,"category":"api_error","summary":"old review failure","context":{}}' \
    '{"ts":"2026-09-01T00:00:00Z","workflow":"review","run_id":null,"session_id":null,"category":"api_error","summary":"recent review failure","context":{}}' \
    >"$PHOME/failures/review.jsonl"
  # poll.jsonl holds only records older than the 2026-08-15 cutoff used below
  printf '%s\n' '{"ts":"2026-07-01T00:00:00Z","workflow":"poll","run_id":null,"session_id":null,"category":"tool_error","summary":"old poll failure","context":{}}' \
    >"$PHOME/failures/poll.jsonl"
}

# --sessions prunes only session files
new_home
SHAI_HOME="$PHOME" "$DIR/shai-prune" --sessions </dev/null >/dev/null 2>&1
assert_eq "$(find "$PHOME/sessions/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "prune: --sessions removes session files"
assert_eq "$(find "$PHOME/runs/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "2" \
  "prune: --sessions leaves runs untouched"
assert_eq "$(find "$PHOME/sessions/" -name '*.latest.json' 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "prune: --sessions removes latest.json files"

# --runs prunes only run directories
new_home
SHAI_HOME="$PHOME" "$DIR/shai-prune" --runs </dev/null >/dev/null 2>&1
assert_eq "$(find "$PHOME/runs/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "prune: --runs removes run dirs"
assert_eq "$(find "$PHOME/sessions/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "4" \
  "prune: --runs leaves sessions untouched"

# no flags prunes both
new_home
SHAI_HOME="$PHOME" "$DIR/shai-prune" </dev/null >/dev/null 2>&1
assert_eq "$(find "$PHOME/sessions/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "prune: no flags removes sessions"
assert_eq "$(find "$PHOME/runs/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "prune: no flags removes runs"

# --dry-run lists but does not delete
new_home
DRYOUT=$(SHAI_HOME="$PHOME" "$DIR/shai-prune" --dry-run </dev/null 2>&1)
assert_contains "$DRYOUT" "dry run" "prune: --dry-run prints dry run notice"
assert_eq "$(find "$PHOME/sessions/" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "4" \
  "prune: --dry-run does not delete sessions"
assert_eq "$(find "$PHOME/runs/" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "2" \
  "prune: --dry-run does not delete runs"

# --before filters by mtime
new_home
touch -t 202501010000 "$PHOME/sessions/sess_a.jsonl"
touch -t 202501010000 "$PHOME/sessions/sess_a.latest.json"
touch -t 202501010000 "$PHOME/runs/run_001"
SHAI_HOME="$PHOME" "$DIR/shai-prune" --before 2026-01-01 </dev/null >/dev/null 2>&1
assert_eq "$(find "$PHOME/sessions/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "2" \
  "prune: --before removes only old session and its latest.json"
assert_eq "$(find "$PHOME/sessions/" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)" "$(printf 'sess_b.jsonl\nsess_b.latest.json')" \
  "prune: --before keeps recent session files"
assert_eq "$(find "$PHOME/runs/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "1" \
  "prune: --before removes only old run dir"

# nothing to prune
EMPTYH="$(mktemp -d)"
_CLEANUP_DIRS+=("$EMPTYH")
EMPTYOUT=$(SHAI_HOME="$EMPTYH" "$DIR/shai-prune" 2>&1)
assert_contains "$EMPTYOUT" "nothing to prune" "prune: empty state → nothing to prune"

# non-interactive skips confirmation (stdin is /dev/null, not a tty)
new_home
SHAI_HOME="$PHOME" "$DIR/shai-prune" --sessions </dev/null >/dev/null 2>&1
assert_eq "$(find "$PHOME/sessions/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "prune: non-interactive removes without prompting"

# unknown option exits 1
assert_exit 1 "prune: unknown option exits 1" -- "$DIR/shai-prune" --bogus

# --ledgers prunes only ledger files
new_home_with_ledgers
SHAI_HOME="$PHOME" "$DIR/shai-prune" --ledgers </dev/null >/dev/null 2>&1
assert_eq "$(find "$PHOME/ledgers/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "prune: --ledgers removes ledger files"
assert_eq "$(find "$PHOME/sessions/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "4" \
  "prune: --ledgers leaves sessions untouched"
assert_eq "$(find "$PHOME/runs/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "2" \
  "prune: --ledgers leaves runs untouched"

# default prune (no flags) removes ledger files too
new_home_with_ledgers
SHAI_HOME="$PHOME" "$DIR/shai-prune" </dev/null >/dev/null 2>&1
assert_eq "$(find "$PHOME/ledgers/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "prune: no flags removes ledger files"

# --ledgers --before filters by mtime
new_home_with_ledgers
touch -t 202501010000 "$PHOME/ledgers/review.jsonl"
SHAI_HOME="$PHOME" "$DIR/shai-prune" --ledgers --before 2026-01-01 </dev/null >/dev/null 2>&1
assert_eq "$(find "$PHOME/ledgers/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "1" \
  "prune: --ledgers --before removes only old ledger"
assert_eq "$(find "$PHOME/ledgers/" -maxdepth 1 -type f -printf '%f\n')" "poll.jsonl" \
  "prune: --ledgers --before keeps recent ledger"

# --ledgers --dry-run lists but does not delete
new_home_with_ledgers
DRYOUT_L=$(SHAI_HOME="$PHOME" "$DIR/shai-prune" --ledgers --dry-run </dev/null 2>&1)
assert_contains "$DRYOUT_L" "dry run" "prune: --ledgers --dry-run prints dry run notice"
assert_eq "$(find "$PHOME/ledgers/" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "2" \
  "prune: --ledgers --dry-run does not delete"

# --failures prunes only failure files
new_home_with_failures
SHAI_HOME="$PHOME" "$DIR/shai-prune" --failures </dev/null >/dev/null 2>&1
assert_eq "$(find "$PHOME/failures/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "prune: --failures removes failure files"
assert_eq "$(find "$PHOME/sessions/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "4" \
  "prune: --failures leaves sessions untouched"
assert_eq "$(find "$PHOME/runs/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "2" \
  "prune: --failures leaves runs untouched"
assert_eq "$(find "$PHOME/ledgers/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "2" \
  "prune: --failures leaves ledgers untouched"

# default prune (no flags) removes failure files too
new_home_with_failures
SHAI_HOME="$PHOME" "$DIR/shai-prune" </dev/null >/dev/null 2>&1
assert_eq "$(find "$PHOME/failures/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "prune: no flags removes failure files"

# --failures --before filters on the ts field: keeps recent records, drops old lines,
# and deletes the files that end up empty (mutation-checked: dropping the content
# filter keeps the old line and the test fails)
new_home_with_failures
SHAI_HOME="$PHOME" "$DIR/shai-prune" --failures --before 2026-08-15 </dev/null >/dev/null 2>&1
assert_eq "$(jq -r '.summary' "$PHOME/failures/review.jsonl")" "recent review failure" \
  "prune: --failures --before keeps recent record in file"
assert_eq "$(wc -l <"$PHOME/failures/review.jsonl" | tr -d ' ')" "1" \
  "prune: --failures --before removes old record from file"
assert_eq "$(find "$PHOME/failures/" -maxdepth 1 -type f -printf '%f\n')" "review.jsonl" \
  "prune: --failures --before deletes file left empty"
assert_eq "$(find "$PHOME/sessions/" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" "4" \
  "prune: --failures --before leaves sessions untouched"

# empty failure files are deleted after pruning
new_home_with_failures
: >"$PHOME/failures/empty.jsonl"
SHAI_HOME="$PHOME" "$DIR/shai-prune" --failures --before 2026-08-15 </dev/null >/dev/null 2>&1
assert_eq "$(find "$PHOME/failures/" -maxdepth 1 -type f -printf '%f\n')" "review.jsonl" \
  "prune: --failures --before deletes already-empty failure file"

# unparseable failure files are left untouched and warned about (fail closed;
# mutation-checked: swallowing jq's error drops the warning and the test fails)
new_home_with_failures
printf 'not valid json\n' >"$PHOME/failures/bad.jsonl"
WARNOUT=$(SHAI_HOME="$PHOME" "$DIR/shai-prune" --failures --before 2026-08-15 </dev/null 2>&1)
assert_contains "$WARNOUT" "warning: cannot parse" \
  "prune: --failures --before warns on unparseable failure file"
assert_eq "$(cat "$PHOME/failures/bad.jsonl")" "not valid json" \
  "prune: --failures --before leaves unparseable file untouched"
assert_eq "$(find "$PHOME/failures/" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)" \
  "$(printf 'bad.jsonl\nreview.jsonl')" \
  "prune: --failures --before prunes parseable files, keeps unparseable one"

# rewritten failure files keep their original permission bits (mutation-checked:
# dropping the mode copy leaves the file at mktemp's 0600 and the test fails)
new_home_with_failures
chmod 640 "$PHOME/failures/review.jsonl"
SHAI_HOME="$PHOME" "$DIR/shai-prune" --failures --before 2026-08-15 </dev/null >/dev/null 2>&1
assert_eq "$(stat -c '%a' "$PHOME/failures/review.jsonl")" "640" \
  "prune: --failures --before preserves file mode across rewrite"

# --failures --dry-run lists failure files but does not delete them
new_home_with_failures
DRYOUT_F=$(SHAI_HOME="$PHOME" "$DIR/shai-prune" --failures --dry-run </dev/null 2>&1)
assert_contains "$DRYOUT_F" "dry run" "prune: --failures --dry-run prints dry run notice"
assert_contains "$DRYOUT_F" "failures/review.jsonl" "prune: --failures --dry-run lists failure files"
assert_eq "$(find "$PHOME/failures/" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "2" \
  "prune: --failures --dry-run does not delete failure files"

finish
