#!/bin/bash
# search_files/run.sh — search for a text pattern across files in a directory tree
# Usage: run.sh '<json input>'
# Reads: $1 (JSON with .pattern, optional .path, .glob, .ignore_case, .max_results)
# Writes: matching lines as path:line_number: text to stdout, plus a truncation marker when capped
#         and a [note: search incomplete — N unreadable path(s) skipped] line when unreadable
#         paths were skipped
# Exit: 0 on success (including no matches, and partial success where unreadable paths were
#       skipped), 1 on failure (bad input, grep error, timeout)
set -euo pipefail
# The source directive is CWD-relative: tests/lint.sh invokes shellcheck from the repo root.
# shellcheck source=lib/read-only.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." &>/dev/null && pwd)/lib/read-only.sh"
input="$1"
pattern=$(printf '%s' "$input" | jq -r '.pattern // empty')
path=$(printf '%s' "$input" | jq -r '.path // empty')
glob=$(printf '%s' "$input" | jq -r '.glob // empty')
# These use `jq -c`, not `jq -r`, so JSON types survive the read: the string "true" arrives as
# `"true"` (quoted) and is rejected below, whereas -r would stringify it into a value that passes
# the boolean check. Same for max_results — the string "5" is not an integer.
ignore_case=$(printf '%s' "$input" | jq -c '.ignore_case // false')
max_results=$(printf '%s' "$input" | jq -c '.max_results // empty')

if [ -z "$pattern" ]; then
  printf 'error: pattern is required\n'
  exit 1
fi

if [ "$ignore_case" != "true" ] && [ "$ignore_case" != "false" ]; then
  printf 'error: ignore_case must be a boolean (got %s)\n' "$ignore_case"
  exit 1
fi

: "${path:=.}"

if [ ! -e "$path" ]; then
  printf 'error: path not found: %s\n' "$path"
  exit 1
fi

if [ -n "$max_results" ]; then
  if ! [[ "$max_results" =~ ^[0-9]+$ ]] || [ "$max_results" -lt 1 ] || [ "$max_results" -gt 500 ]; then
    printf 'error: max_results must be an integer between 1 and 500 (got %s)\n' "$max_results"
    exit 1
  fi
else
  max_results=100
fi

# -H so a single-file path is prefixed like a recursive hit; -I skips binaries; the
# --exclude/--exclude-dir flags from lib/read-only.sh keep VCS internals, credential paths and
# dependency noise out of the scan (see #118) — .git was the original --exclude-dir, now the
# shared list owns it alongside .ssh, .env, node_modules, ...
# Ordering matters: --include must come before --exclude. With GNU grep 3.11 an --exclude flag
# listed first disables the include filter entirely (a non-globbed search still honors every
# exclusion), so the glob is pushed to the front of the argument array.
# -E selects extended regex: without it, basic regex treats `|` as a literal character, so an
# alternation like `foo|bar` silently searches for the literal pipe and returns zero matches
# (see #136). With -E, `foo|bar` means alternation, which is what agents mean when they write it.
args=(-rnIH -E)
if [ -n "$glob" ]; then
  args+=(--include="$glob")
fi
mapfile -t exclude_args < <(ro_grep_exclude_args)
args+=("${exclude_args[@]}")

if [ "$ignore_case" = "true" ]; then
  args+=(-i)
fi

args+=(-- "$pattern" "$path")

err=$(mktemp)
# shellcheck disable=SC2064  # expand $err now: the trap must survive the variable going out of scope
trap "rm -f '$err'" EXIT

# grep's diagnostics go to a file rather than being folded into the result rows with 2>&1, and its
# status is inspected instead of being discarded with `|| true`: 0 (matches) and 1 (no matches) are
# both successful searches. GNU grep exits 2 when ANY error occurred — including unreadable
# directories — while still printing the matches it found in readable subtrees, so status 2 is
# handled as a partial search (see #169), not a hard failure: matches are kept, a note counts the
# skipped paths, and only a real grep error (e.g. an invalid regex) fails the whole search.
# `timeout 30s` matches the other read-only tools so a huge tree cannot stall the agent loop.
# One row past the cap is read so a full page can be told apart from an exact fit; awk does the
# clipping rather than `head` because awk drains grep instead of closing the pipe on it, which
# would surface as a SIGPIPE status indistinguishable from a genuine grep failure.
status=0
matches=$(
  timeout 30s grep "${args[@]}" 2>"$err" | awk -v n="$((max_results + 1))" 'NR <= n'
  exit "${PIPESTATUS[0]}"
) || status=$?

# print_matches: emit the captured rows, capped at max_results with the truncation marker
print_matches() {
  if [ "$(printf '%s\n' "$matches" | wc -l)" -gt "$max_results" ]; then
    printf '%s\n' "$matches" | awk -v n="$max_results" 'NR <= n'
    printf '[truncated: showing first %s matches]\n' "$max_results"
  else
    printf '%s\n' "$matches"
  fi
}

case "$status" in
  0 | 1) ;;
  124)
    printf 'error: search timed out after 30s: %s\n' "$path"
    exit 1
    ;;
  2)
    # A tree with an unreadable directory makes GNU grep exit 2, but it still prints the matches
    # from readable subtrees. Keep them — the old behavior discarded them, turning one unreadable
    # dir into a permanently broken search with zero matches and no way to tell "nothing matched"
    # from "search failed" (see #169).
    if [ -n "$matches" ]; then
      print_matches
      printf '[note: search incomplete — %s unreadable path(s) skipped]\n' "$(wc -l <"$err")"
      exit 0
    fi
    # No matches: tell unreadable paths apart from a real grep error. Every line of $err being a
    # per-path diagnostic (`grep: <path>: Permission denied` / `No such file or directory`) means
    # the scan was incomplete, so report that instead of the generic "search failed (exit 2)".
    # Anything else (e.g. an invalid-regex message, which has no path) falls through to the hard
    # failure below.
    per_path_only=1
    if [ -s "$err" ]; then
      while IFS= read -r line; do
        case "$line" in
          grep:\ *:\ *Permission\ denied | grep:\ *:\ *No\ such\ file\ or\ directory) ;;
          *) per_path_only=0; break ;;
        esac
      done <"$err"
    else
      per_path_only=0
    fi
    if [ "$per_path_only" -eq 1 ]; then
      printf 'error: search incomplete — %s unreadable path(s) could not be searched\n' "$(wc -l <"$err")"
      if [ -s "$err" ]; then cat -- "$err"; fi
      exit 1
    fi
    printf 'error: search failed (exit %s)\n' "$status"
    if [ -s "$err" ]; then cat -- "$err"; fi
    exit 1
    ;;
  *)
    printf 'error: search failed (exit %s)\n' "$status"
    if [ -s "$err" ]; then cat -- "$err"; fi
    exit 1
    ;;
esac

[ -n "$matches" ] || exit 0
print_matches
