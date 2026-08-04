#!/bin/bash
# test_prune.sh — tests for shai-prune
# Covers: shai-prune — session/run pruning, --dry-run, --before, confirmation, edge cases
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
assert_eq "$(ls "$PHOME/sessions/")" "$(printf 'sess_b.jsonl\nsess_b.latest.json')" \
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

finish
