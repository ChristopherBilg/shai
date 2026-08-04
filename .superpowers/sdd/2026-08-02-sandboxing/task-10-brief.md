# Task 2: Test suite for check_policy

**Goal:** Hermetic test suite covering all policy matching behaviors — exact match, glob, first-match-wins, missing file, broken file, default fallback.

**Files:**
- Create: `tests/test_policy.sh`

**Acceptance Criteria:**
- [ ] Test: no policy file → allow for read-only tools (`print_file`, `list_directory`, `gh_pr_view`, `gh_issue_view`), prompt for others
- [ ] Test: empty policy file → returns `prompt`
- [ ] Test: malformed (non-JSON) policy file → returns `prompt`
- [ ] Test: exact tool match with `allow` → returns `allow`
- [ ] Test: exact tool match with `deny` → returns `deny`
- [ ] Test: rule with `args` exact match → returns correct action
- [ ] Test: rule with `args` glob pattern (`*`) → returns correct action
- [ ] Test: glob does not match regex-special chars unescaped (e.g., `foo.bar` must not match `fooXbar`)
- [ ] Test: first-match-wins — specific allow above broad deny
- [ ] Test: no rule matches → returns `default` field value
- [ ] Test: no rule matches and no `default` → returns `prompt`
- [ ] All tests are offline (no network, no real policy file at `~/.shai`)

**Verify:** `bash tests/test_policy.sh` → all assertions pass, PASS banner

## Test Pattern

Tests follow the project's existing pattern (see `tests/test_dispatch.sh` or `tests/test_eval.sh`):

```bash
#!/bin/bash
# tests/test_policy.sh — test suite for the permission gate policy matcher
# Covers: check_policy in shai-dispatch (policy file parsing, rule matching, fallbacks)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=tests/lib.sh
source "$DIR/lib.sh"
```

- Source `tests/lib.sh` for `assert_eq`, `assert_contains`, `make_stub_bin`, `_CLEANUP_DIRS`, `finish`
- `lib.sh` fakes `ANTHROPIC_API_KEY=test-key` and provides automatic temp dir cleanup
- End with `finish` which prints PASS/FAIL and exits accordingly
- Tests use `set -uo pipefail` (no `-e` — `lib.sh` assertions set `FAILED=1` without aborting)

## How to test `check_policy` in isolation

`shai-dispatch` runs its dispatch loop at the global scope (no `main` guard), so you can't just `source` it. Extract the function definitions:

```bash
extract_functions() {
  # Extract everything from line 1 up to (but not including) the dispatch loop
  sed -n '1,/^tool_calls=/p' "$DIR/../shai-dispatch" | head -n -1
}

run_check_policy() {
  local tool_name="$1" tool_input="$2"
  eval "$(extract_functions)"
  check_policy "$tool_name" "$tool_input"
}
```

Then each test sets `SHAI_HOME` to a temp dir with an injected `policy.json`:

```bash
setup_policy() {
  local tmpdir
  tmpdir=$(mktemp -d)
  _CLEANUP_DIRS+=("$tmpdir")
  printf '%s' "$1" > "$tmpdir/policy.json"
  printf '%s' "$tmpdir"
}

# usage:
tmpdir=$(setup_policy '{"version":"1.0","default":"deny","rules":[{"tool":"print_file","action":"allow"}]}')
result=$(SHAI_HOME="$tmpdir" run_check_policy "print_file" '{"path":"/tmp/x"}')
assert_eq "$result" "allow" "exact tool allow"
```

## Important edge case

The `check_policy` function (as committed in Task 1) treats empty files the same as broken files — both fall through to the nested `${fallback:-prompt}` expansion. Make sure to test both empty-file and malformed-file separately.
