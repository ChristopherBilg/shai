#!/bin/bash
# Project standards/conventions checker. Run in CI and locally.
# Usage: ./tests/conventions.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
cd "$ROOT"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
fail=0
note() {
  echo -e "  ${RED}✗${NC} $1"
  fail=1
}
ok() { echo -e "  ${GREEN}✓${NC} $1"; }

# Derived from git, not hardcoded: a hardcoded list silently skipped shai-retry for two PRs.
mapfile -t RUNTIME < <(git ls-files 'shai' 'shai-*' 'workflows/*.sh')

mapfile -t SCRIPTS < <(
  {
    printf '%s\n' "${RUNTIME[@]}"
    git ls-files 'tests/*.sh'
  } | sort -u
)

# 1. Shebang
for f in "${SCRIPTS[@]}"; do
  if [ "$(head -n1 "$f")" = "#!/bin/bash" ]; then ok "shebang: $f"; else note "shebang missing/incorrect: $f"; fi
done

# 2. Strict mode on runtime scripts
for f in "${RUNTIME[@]}"; do
  if grep -q '^set -euo pipefail$' "$f"; then ok "strict mode: $f"; else note "missing 'set -euo pipefail': $f"; fi
done

# 3. Executable bit
mapfile -t EXEC_TARGETS < <(
  {
    printf '%s\n' "${RUNTIME[@]}"
    echo "tests/run.sh"
    git ls-files 'tests/test_*.sh'
  } | sort -u
)
for f in "${EXEC_TARGETS[@]}"; do
  if [ -x "$f" ]; then ok "executable: $f"; else note "not executable: $f"; fi
done

# 4. tools.json valid JSON
if jq empty tools.json >/dev/null 2>&1; then ok "tools.json is valid JSON"; else note "tools.json is not valid JSON"; fi

# 5. Trailing whitespace + final newline on tracked text files
while IFS= read -r f; do
  case "$f" in *.png | *.jpg | *.jpeg | *.gif) continue ;; esac
  if LC_ALL=C grep -nq '[[:blank:]]$' "$f"; then note "trailing whitespace: $f"; fi
  if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then note "no final newline: $f"; fi
done < <(git ls-files)

echo
if [ "$fail" -eq 0 ]; then
  echo -e "${GREEN}CONVENTIONS OK${NC}"
  exit 0
else
  echo -e "${RED}CONVENTIONS FAILED${NC}"
  exit 1
fi
