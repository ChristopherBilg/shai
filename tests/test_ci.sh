#!/bin/bash
# test_ci.sh — unit tests for tools/ci/run.sh
# Covers: tools/ci/run.sh — list/run actions, URL normalization, config lookup, timeout, error paths
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "tools/ci/run.sh"

TOOL="$DIR/tools/ci/run.sh"

# --- setup: temp SHAI_HOME with ci.json ---
SHAI_HOME="$(mktemp -d)"
_CLEANUP_DIRS+=("$SHAI_HOME")
export SHAI_HOME

make_stub_bin

# Helper: write a git stub that returns a specific remote URL
write_remote_stub() {
  local url="$1"
  cat >"$STUB/git" <<STUBEOF
#!/bin/bash
if [ "\$1" = "remote" ] && [ "\$2" = "get-url" ]; then
  echo "$url"
  exit 0
fi
echo "stub git: \$*"
STUBEOF
  chmod +x "$STUB/git"
}

# Helper: write ci.json
write_ci_config() {
  cat >"$SHAI_HOME/ci.json"
}

# --- config with two repos ---
write_ci_config <<'JSON'
{
  "version": "1.0",
  "repos": {
    "github.com/owner/repo": {
      "checks": {
        "test": { "command": "echo tests-passed" },
        "lint": { "command": "echo lint-ok" },
        "slow": { "command": "sleep 999", "timeout": 1 }
      }
    },
    "github.com/other/project": {
      "checks": {
        "build": { "command": "echo built" }
      }
    }
  }
}
JSON

# ===== list action =====
desc "list action"
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"list"}')
RC=$?
assert_eq "$RC" "0" "list: exit 0"
assert_contains "$OUT" "test" "list: shows test check"
assert_contains "$OUT" "lint" "list: shows lint check"
assert_contains "$OUT" "slow" "list: shows slow check"

# ===== run action (success) =====
desc "run action — passing check"
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"run","check":"test"}')
RC=$?
assert_eq "$RC" "0" "run success: exit 0"
assert_contains "$OUT" "tests-passed" "run success: command output present"
assert_contains "$OUT" "exit_code: 0" "run success: exit_code 0 reported"

# ===== run action (command fails) =====
desc "run action — failing check"
write_ci_config <<'JSON'
{
  "version": "1.0",
  "repos": {
    "github.com/owner/repo": {
      "checks": {
        "fail": { "command": "echo failure-output; exit 1" }
      }
    }
  }
}
JSON
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"run","check":"fail"}')
RC=$?
assert_eq "$RC" "0" "run fail: tool exits 0 (not is_error)"
assert_contains "$OUT" "failure-output" "run fail: command output present"
assert_contains "$OUT" "exit_code: 1" "run fail: exit_code 1 reported"

# restore config for remaining tests
write_ci_config <<'JSON'
{
  "version": "1.0",
  "repos": {
    "github.com/owner/repo": {
      "checks": {
        "test": { "command": "echo tests-passed" },
        "lint": { "command": "echo lint-ok" },
        "slow": { "command": "sleep 999", "timeout": 1 }
      }
    },
    "github.com/other/project": {
      "checks": {
        "build": { "command": "echo built" }
      }
    }
  }
}
JSON

# ===== run action (timeout) =====
desc "run action — timeout"
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"run","check":"slow"}' 2>&1) || true
assert_contains "$OUT" "timed out" "run timeout: error message"
assert_exit 1 "run timeout: exit 1" -- "$TOOL" '{"action":"run","check":"slow"}'

# ===== missing ci.json =====
desc "missing ci.json"
rm "$SHAI_HOME/ci.json"
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"list"}' 2>&1) || true
assert_contains "$OUT" "ci.json" "missing config: mentions ci.json"
assert_exit 1 "missing config: exit 1" -- "$TOOL" '{"action":"list"}'

# ===== malformed ci.json =====
desc "malformed ci.json"
write_ci_config <<'JSON'
{ "version": "1.0", "repos": { this is not valid json
JSON
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"list"}' 2>&1) || true
assert_contains "$OUT" "not valid JSON" "malformed config: mentions not valid JSON"
assert_exit 1 "malformed config: exit 1" -- "$TOOL" '{"action":"list"}'

# restore for remaining tests
write_ci_config <<'JSON'
{
  "version": "1.0",
  "repos": {
    "github.com/owner/repo": {
      "checks": {
        "test": { "command": "echo tests-passed" },
        "lint": { "command": "echo lint-ok" },
        "slow": { "command": "sleep 999", "timeout": 1 }
      }
    },
    "github.com/other/project": {
      "checks": {
        "build": { "command": "echo built" }
      }
    }
  }
}
JSON

# ===== unknown repo =====
desc "unknown repo"
write_remote_stub "https://github.com/unknown/thing.git"
OUT=$("$TOOL" '{"action":"list"}' 2>&1) || true
assert_contains "$OUT" "github.com/unknown/thing" "unknown repo: shows detected URL"
assert_exit 1 "unknown repo: exit 1" -- "$TOOL" '{"action":"list"}'

# ===== unknown check =====
desc "unknown check"
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"run","check":"nonexistent"}' 2>&1) || true
assert_contains "$OUT" "nonexistent" "unknown check: mentions requested check"
assert_contains "$OUT" "test" "unknown check: lists available checks"
assert_exit 1 "unknown check: exit 1" -- "$TOOL" '{"action":"run","check":"nonexistent"}'

# ===== missing check param =====
desc "missing check param"
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"run"}' 2>&1) || true
assert_contains "$OUT" "check" "missing check: mentions check param"
assert_exit 1 "missing check: exit 1" -- "$TOOL" '{"action":"run"}'

# ===== invalid action =====
desc "invalid action"
OUT=$("$TOOL" '{"action":"bogus"}' 2>&1) || true
assert_contains "$OUT" "list" "invalid action: mentions valid actions"
assert_exit 1 "invalid action: exit 1" -- "$TOOL" '{"action":"bogus"}'

# ===== URL normalization =====
desc "URL normalization"

# HTTPS with .git
write_remote_stub "https://github.com/owner/repo.git"
OUT=$("$TOOL" '{"action":"list"}')
assert_eq "$?" "0" "normalize: HTTPS with .git"

# HTTPS without .git
write_remote_stub "https://github.com/owner/repo"
OUT=$("$TOOL" '{"action":"list"}')
assert_eq "$?" "0" "normalize: HTTPS without .git"

# SSH
write_remote_stub "git@github.com:owner/repo.git"
OUT=$("$TOOL" '{"action":"list"}')
assert_eq "$?" "0" "normalize: SSH with .git"

# SSH without .git
write_remote_stub "git@github.com:owner/repo"
OUT=$("$TOOL" '{"action":"list"}')
assert_eq "$?" "0" "normalize: SSH without .git"

# HTTPS with trailing slash
write_remote_stub "https://github.com/owner/repo/"
OUT=$("$TOOL" '{"action":"list"}')
assert_eq "$?" "0" "normalize: trailing slash"

# ===== no git remote =====
desc "no git remote"
cat >"$STUB/git" <<'STUBEOF'
#!/bin/bash
echo "fatal: not a git repository" >&2
exit 128
STUBEOF
chmod +x "$STUB/git"
OUT=$("$TOOL" '{"action":"list"}' 2>&1) || true
assert_contains "$OUT" "not in a git repository" "no remote: error message"
assert_exit 1 "no remote: exit 1" -- "$TOOL" '{"action":"list"}'

finish
