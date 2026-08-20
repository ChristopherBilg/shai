#!/bin/bash
# all.sh — run every CI check locally in CI order; the one pre-push command
# Usage: ./tests/all.sh
set -uo pipefail
RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
ROOT="$(cd "$RUN_DIR/.." &>/dev/null && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'
total=0
failed=0

# run_stage <label> <script>: run one CI stage as an isolated subprocess and tally the result.
run_stage() {
  local label="$1" script="$2"
  total=$((total + 1))
  echo "── $label ──"
  if ! bash "$script"; then failed=$((failed + 1)); fi
}

# Every locally reproducible CI job, in the order ci.yml runs it, minus the three all.sh cannot
# reproduce locally: `compat` (re-runs tests under a downloaded bash 4.4), `actionlint`
# (downloaded binary), and `secrets` (TruffleHog GitHub Action). Lint is held until last (after
# tool-schema, not in its ci.yml slot between compat and conventions) because it is the one gated
# stage. Each stage is a standalone script with its own exit status, so the aggregate subprocesses
# it and tallies — the same isolation model as tests/run.sh.
run_stage "run.sh" "$RUN_DIR/run.sh"
run_stage "conventions.sh" "$RUN_DIR/conventions.sh"
run_stage "docs.sh" "$RUN_DIR/docs.sh"
run_stage "tools-sync.sh" "$RUN_DIR/tools-sync.sh"
run_stage "constants-sync.sh" "$RUN_DIR/constants-sync.sh"
run_stage "doctor-sync.sh" "$RUN_DIR/doctor-sync.sh"
run_stage "validate-tool-schema.sh" "$RUN_DIR/validate-tool-schema.sh"

# The lint stage is the single lint target tests/lint.sh (its file list is git-derived, so there
# is no glob to repeat here). It prefers the pinned binaries in ./bin (a gitignored download) and
# falls back to $PATH, so the gate mirrors that: lint runs when shellcheck and shfmt resolve
# either way, and is skipped with a visible notice (never a failure) only when neither is
# available. Run ./tests/install-lint-tools.sh to fetch the pinned binaries.
lint_available() {
  local name="$1"
  [ -x "$ROOT/bin/$name" ] || command -v "$name" >/dev/null 2>&1
}

if lint_available shellcheck && lint_available shfmt; then
  run_stage "lint.sh (shellcheck + shfmt)" "$RUN_DIR/lint.sh"
else
  echo "── lint.sh (shellcheck + shfmt) ──"
  echo -e "  ${YELLOW}⚠${NC} lint skipped — shellcheck/shfmt not in ./bin or \$PATH (run ./tests/install-lint-tools.sh)"
fi

echo
if [ "$failed" -eq 0 ]; then
  echo -e "${GREEN}ALL SUITES PASSED${NC} ($total)"
  exit 0
else
  echo -e "${RED}${failed}/${total} SUITES FAILED${NC}"
  exit 1
fi
