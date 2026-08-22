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
mapfile -t RUNTIME < <({
  git ls-files 'shai-*'
  git ls-files 'install.sh'
  git ls-files 'tools/*/run.sh'
  git ls-files 'workflows/*/run.sh'
} | sort -u)

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
    echo "tests/lint.sh"
    git ls-files 'tests/test_*.sh'
  } | sort -u
)
for f in "${EXEC_TARGETS[@]}"; do
  if [ -x "$f" ]; then ok "executable: $f"; else note "not executable: $f"; fi
done

# 4. tools/*/tool.json valid JSON
for tj in tools/*/tool.json; do
  [ -f "$tj" ] || continue
  if jq empty "$tj" >/dev/null 2>&1; then ok "$tj is valid JSON"; else note "$tj is not valid JSON"; fi
done

# 5. Every runtime script is in the lint target. The inverse relation to the checks above: a new
# category of runtime script cannot be held to these conventions while staying invisible to
# the linters, which is exactly how tools/*/run.sh went unlinted (see #81).
declare -A LINTED=()
if LINT_LIST="$(bash tests/lint.sh --list)"; then
  while IFS= read -r f; do LINTED["$f"]=1; done <<<"$LINT_LIST"
  for f in "${RUNTIME[@]}"; do
    if [ -n "${LINTED[$f]:-}" ]; then
      ok "in the lint target: $f"
    else
      note "not in the lint target: $f"
    fi
  done
else
  note "tests/lint.sh --list failed — cannot verify runtime scripts are in the lint target"
fi

# 6. Trailing whitespace + final newline on tracked text files
while IFS= read -r f; do
  case "$f" in *.png | *.jpg | *.jpeg | *.gif) continue ;; esac
  if LC_ALL=C grep -nq '[[:blank:]]$' "$f"; then note "trailing whitespace: $f"; fi
  if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then note "no final newline: $f"; fi
done < <(git ls-files)

# 7. No outer-shell variable splices into bash -c bodies (see #154). The quote-splice
# `"'"$VAR"'"` interpolates the outer shell's value into the -c string, which the inner
# shell then re-parses — a checkout path containing shell metacharacters (e.g.
# /tmp/issue-worker-$$) is re-expanded and the command stops resolving (exit 127).
# Pass values positionally instead: `bash -c '...' _ "$DIR"`. The splice always contains
# the byte sequence `"'"$` (body close, splice open, `$`); inner-shell positional refs
# (`"$1"`) and the `'"'"'` single-quote idiom never do.
splice_bad=0
while IFS= read -r f; do
  while IFS= read -r line; do
    case "$line" in
      *"bash -c"*"'"\$*)
        note "bash -c body splices an outer-shell variable (see #154): $f: $line"
        splice_bad=1
        ;;
    esac
  done <"$f"
done < <(git ls-files 'tests/*.sh')
if [ "$splice_bad" -eq 0 ]; then ok "no outer-shell splices into bash -c bodies"; fi

echo
if [ "$fail" -eq 0 ]; then
  echo -e "${GREEN}CONVENTIONS OK${NC}"
  exit 0
else
  echo -e "${RED}CONVENTIONS FAILED${NC}"
  exit 1
fi
