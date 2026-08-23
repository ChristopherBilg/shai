#!/bin/bash
# Test runner: run each tests/test_*.sh as an isolated subprocess, aggregate results.
# Usage: ./tests/run.sh [name-or-glob]
#   With no argument, run every tests/test_*.sh suite.
#   With an argument, run only suites whose file name matches the given name or
#   glob (e.g. ./tests/run.sh test_eval, ./tests/run.sh test_eval.sh, or
#   ./tests/run.sh 'test_*') — handy for re-running a single failing suite.
# The trailing summary block prints one PASS/FAIL line per suite and, on failure,
# a FAILED SUITES: line naming every suite that exited non-zero, so the retained
# tail of a truncated CI log always names the failing suites.
set -uo pipefail
RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
total=0
failed=0
failed_names=()
results=()

filter="${1:-}"
for t in "$RUN_DIR"/test_*.sh; do
  [ -e "$t" ] || continue
  name="$(basename "$t")"
  if [ -n "$filter" ]; then
    # Match the bare suite name (test_eval), the file name (test_eval.sh), or a glob.
    # shellcheck disable=SC2254  # the last pattern is deliberately a glob (./tests/run.sh 'test_*')
    case "$name" in
      "$filter" | "$filter".sh | $filter) ;;
      *) continue ;;
    esac
  fi
  total=$((total + 1))
  echo "── $name ──"
  if bash "$t"; then
    results+=("PASS $name")
  else
    failed=$((failed + 1))
    failed_names+=("$name")
    results+=("FAIL $name")
  fi
done

echo
if [ "$total" -eq 0 ] && [ -n "$filter" ]; then
  echo -e "${RED}no suites matched${NC} filter: $filter" >&2
  exit 1
fi
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
