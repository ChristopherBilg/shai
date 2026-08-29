#!/bin/bash
# completions-sync.sh — fail-closed completions gate: manifest coverage, flag declarations, freshness
# Usage: ./tests/completions-sync.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
"$ROOT/shai-completions" check
