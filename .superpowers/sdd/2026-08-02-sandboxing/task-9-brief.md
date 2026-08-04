# Task 1: Add check_policy to shai-dispatch

**Goal:** Implement the policy file reader that returns `allow`, `prompt`, or `deny` for a given tool name and input.

**Files:**
- Modify: `shai-dispatch` — add `STATE_DIR` variable and `check_policy` function after the existing header block (after line 9, `MAX_BYTES=8000`)

**Acceptance Criteria:**
- [ ] `STATE_DIR` resolved from `SHAI_HOME` with fallback to `$HOME/.shai`
- [ ] `check_policy` returns `allow` for built-in read-only tools (`print_file`, `list_directory`, `gh_pr_view`, `gh_issue_view`) when policy file is missing, and `prompt` for everything else
- [ ] `check_policy` returns `prompt` when policy file is unparseable
- [ ] `check_policy` returns the action of the first matching rule (first-match-wins)
- [ ] Rules with no `args` key match any invocation of that tool
- [ ] Rules with `args` match exact values and glob patterns (`*` only)
- [ ] Glob matching escapes regex-special characters in the literal parts (e.g., `.` in a path must not match arbitrary characters)
- [ ] Falls back to the `default` field when no rule matches
- [ ] Falls back to `prompt` when `default` field is missing or file is broken

**Verify:** `./bin/shellcheck shai-dispatch && ./bin/shfmt -d shai-dispatch` → clean

## Implementation Details

Insert after line 9 (`MAX_BYTES=8000`) in `shai-dispatch`:

```bash
STATE_DIR="${SHAI_HOME:-$HOME/.shai}"

check_policy() {
  local tool_name="$1" tool_input="$2"
  local policy_file="$STATE_DIR/policy.json"

  if [ ! -f "$policy_file" ]; then
    case "$tool_name" in
      print_file | list_directory | gh_pr_view | gh_issue_view) printf 'allow' ;;
      *) printf 'prompt' ;;
    esac
    return 0
  fi

  local action
  action=$(jq -r --arg name "$tool_name" --argjson input "$tool_input" '
    .rules[]?
    | select(.tool == $name)
    | select(
        (has("args") | not) or
        (.args | to_entries | all(
          .key as $k | .value as $v |
          ($input[$k] // "") | test(
            "^" + ($v | gsub("[.+?^${}()|\\[\\]]"; "\\\\\\(.)";"x") | gsub("\\*"; ".*")) + "$"
          )
        ))
      )
    | .action
  ' "$policy_file" 2>/dev/null | head -n 1)

  printf '%s' "${action:-$(jq -r '.default // "prompt"' "$policy_file" 2>/dev/null || printf 'prompt')}"
}
```

## Project Conventions

- Scripts start with `#!/bin/bash` + `set -euo pipefail`
- `jq` programs are single-quoted — `$vars` inside them are jq variables, not shell (SC2016 disabled in `.shellcheckrc`)
- Pipelines use `cat file | filter` for readability (SC2002 disabled)
- 2-space indent with indented case branches (enforced by `shfmt` and `.editorconfig`)
- Run `./bin/shellcheck shai-dispatch` and `./bin/shfmt -d shai-dispatch` to verify

## Policy File Format (for context)

`$SHAI_HOME/policy.json`:
```json
{
  "version": "1.0",
  "default": "prompt",
  "rules": [
    {"tool": "print_file", "action": "allow"},
    {"tool": "git_push", "args": {"repo": "ChristopherBilg/shai"}, "action": "prompt"},
    {"tool": "git_push", "action": "deny"}
  ]
}
```
