#!/bin/bash
# Test runner: run each tests/test_*.sh as an isolated subprocess, aggregate results.
# Usage: ./tests/run.sh [-j N] [name-or-glob]
#   -j N  Run up to N suites in parallel (default: nproc).  -j1 for sequential.
#   With no name argument, run every tests/test_*.sh suite.
#   With an argument, run only suites whose file name matches the given name or
#   glob (e.g. ./tests/run.sh test_eval, ./tests/run.sh test_eval.sh, or
#   ./tests/run.sh 'test_*') — handy for re-running a single failing suite.
# The trailing summary block prints one PASS/FAIL line per suite and, on failure,
# a FAILED SUITES: line naming every suite that exited non-zero, so the retained
# tail of a truncated CI log always names the failing suites.
# Reads: tests/test_*.sh
# Writes: stdout (results), stderr (errors)
# Exit: 0 all pass, 1 any failure or no match
set -uo pipefail
RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

jobs_max="$(nproc 2>/dev/null || echo 4)"
filter=""
while [ $# -gt 0 ]; do
  case "$1" in
    -j)
      [ -n "${2:-}" ] || {
        echo "run.sh: -j requires a number" >&2
        exit 1
      }
      jobs_max="$2"
      shift 2
      ;;
    -j[0-9]*)
      jobs_max="${1#-j}"
      shift
      ;;
    *)
      filter="$1"
      shift
      ;;
  esac
done

if ! [[ "$jobs_max" =~ ^[1-9][0-9]*$ ]]; then
  echo "run.sh: -j value must be a positive integer, got '$jobs_max'" >&2
  exit 1
fi

OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT

suites=()
for t in "$RUN_DIR"/test_*.sh; do
  [ -e "$t" ] || continue
  name="$(basename "$t")"
  if [ -n "$filter" ]; then
    # shellcheck disable=SC2254  # the last pattern is deliberately a glob
    case "$name" in
      "$filter" | "$filter".sh | $filter) ;;
      *) continue ;;
    esac
  fi
  suites+=("$t")
done

total=${#suites[@]}

if [ "$total" -eq 0 ] && [ -n "$filter" ]; then
  echo -e "${RED}no suites matched${NC} filter: $filter" >&2
  exit 1
fi

declare -A pids=()
declare -A exit_codes=()
in_flight=0

for t in "${suites[@]}"; do
  name="$(basename "$t")"
  bash "$t" >"$OUT_DIR/$name" 2>&1 &
  pids["$name"]=$!
  in_flight=$((in_flight + 1))

  while [ "$in_flight" -ge "$jobs_max" ]; do
    wait -n -p finished_pid 2>/dev/null || true
    for n in "${!pids[@]}"; do
      if [ "${pids[$n]}" = "$finished_pid" ]; then
        wait "${pids[$n]}" 2>/dev/null && exit_codes["$n"]=0 || exit_codes["$n"]=$?
        unset 'pids['"$n"']'
        in_flight=$((in_flight - 1))
        break
      fi
    done
  done
done

for n in "${!pids[@]}"; do
  wait "${pids[$n]}" 2>/dev/null && exit_codes["$n"]=0 || exit_codes["$n"]=$?
done

failed=0
failed_names=()
results=()
for t in "${suites[@]}"; do
  name="$(basename "$t")"
  echo "── $name ──"
  cat "$OUT_DIR/$name"
  if [ "${exit_codes[$name]}" -eq 0 ]; then
    results+=("PASS $name")
  else
    failed=$((failed + 1))
    failed_names+=("$name")
    results+=("FAIL $name")
  fi
done

echo
if [ "$total" -gt 0 ]; then
  printf '%s\n' "${results[@]}"
  echo
fi
if [ "$failed" -eq 0 ]; then
  echo -e "${GREEN}ALL SUITES PASSED${NC} ($total)"
  exit 0
else
  echo -e "${RED}${failed}/${total} SUITES FAILED${NC}"
  printf 'FAILED SUITES: %s\n' "${failed_names[*]}"
  exit 1
fi
