#!/bin/bash
# Test runner: run each tests/test_*.sh as an isolated subprocess, aggregate results.
set -uo pipefail
RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
total=0
failed=0

for t in "$RUN_DIR"/test_*.sh; do
  [ -e "$t" ] || continue
  total=$((total + 1))
  echo "── $(basename "$t") ──"
  if ! bash "$t"; then failed=$((failed + 1)); fi
done

echo
if [ "$failed" -eq 0 ]; then
  echo -e "${GREEN}ALL SUITES PASSED${NC} ($total)"
  exit 0
else
  echo -e "${RED}${failed}/${total} SUITES FAILED${NC}"
  exit 1
fi
