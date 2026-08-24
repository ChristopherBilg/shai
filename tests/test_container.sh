#!/bin/bash
# test_container.sh — unit tests for shai-container
# Covers: shai-container — usage validation, setup, workflow proxying, shell access
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "shai-container"

make_stub_bin

# --- stateful incus stub: tracks created containers ---
INCUS_LOG="$STUB/incus.log"
INCUS_STATE="$STUB/incus_state"
mkdir -p "$INCUS_STATE"
: >"$INCUS_LOG"
cat >"$STUB/incus" <<'STUBEOF'
#!/bin/bash
echo "$*" >> "${INCUS_LOG}"
case "$1" in
  info)
    [ -f "$INCUS_STATE/$2" ] && exit 0 || { echo "Error: not found" >&2; exit 1; }
    ;;
  launch)
    # $2=image, $3=name
    touch "$INCUS_STATE/$3"
    exit 0
    ;;
  exec|config|file) exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "$STUB/incus"

export INCUS_LOG INCUS_STATE

# helper: reset stub state between tests
reset_state() {
  : >"$INCUS_LOG"
  rm -f "$INCUS_STATE"/*
}

# --- validation: no subcommand ---
desc "validation"
assert_exit 2 "no subcommand → exit 2" -- "$DIR/shai-container"

OUT=$("$DIR/shai-container" 2>&1 || true)
assert_contains "$OUT" "Usage:" "no subcommand prints usage"

# --- validation: unknown subcommand ---
assert_exit 2 "unknown subcommand → exit 2" -- "$DIR/shai-container" badcmd

# --- validation: incus not installed ---
desc "incus check"
(
  RESTRICTED="$(mktemp -d)"
  ln -sf "$(command -v dirname)" "$RESTRICTED/"
  PATH="$RESTRICTED"
  OUT=$("$DIR/shai-container" setup 2>&1)
  RC=$?
  assert_eq "$RC" "1" "missing incus → exit 1"
  assert_contains "$OUT" "incus" "missing incus names incus in error"
  exit "$FAILED"
) || FAILED=1

# --- setup: creates container and installs deps ---
desc "setup"
reset_state
OUT=$("$DIR/shai-container" setup 2>&1)
RC=$?
assert_eq "$RC" "0" "setup exits 0"
assert_contains "$(cat "$INCUS_LOG")" "launch" "setup calls incus launch"
assert_contains "$(cat "$INCUS_LOG")" "ubuntu" "setup launches ubuntu image"
assert_contains "$(cat "$INCUS_LOG")" "shai-sandbox" "setup uses default container name"

assert_contains "$(cat "$INCUS_LOG")" "apt-get" "setup installs system packages"
assert_contains "$(cat "$INCUS_LOG")" "jq" "setup installs jq"
assert_contains "$(cat "$INCUS_LOG")" "curl" "setup installs curl"
assert_contains "$(cat "$INCUS_LOG")" "git" "setup installs git"

assert_contains "$(cat "$INCUS_LOG")" "file push" "setup pushes shai into container"

assert_contains "$(cat "$INCUS_LOG")" "config set" "setup sets container config"
assert_contains "$(cat "$INCUS_LOG")" "DEEPSEEK_API_KEY" "setup passes API key"

assert_contains "$(cat "$INCUS_LOG")" "loginctl" "setup enables linger"

# --- setup: custom container name ---
desc "setup: custom container name"
reset_state
OUT=$(SHAI_CONTAINER_NAME=my-shai "$DIR/shai-container" setup 2>&1)
assert_contains "$(cat "$INCUS_LOG")" "my-shai" "setup uses SHAI_CONTAINER_NAME"

# --- setup: container already exists ---
desc "setup: already exists"
reset_state
touch "$INCUS_STATE/shai-sandbox"
OUT=$("$DIR/shai-container" setup 2>&1)
RC=$?
assert_eq "$RC" "1" "already exists → exit 1"
assert_contains "$OUT" "already exists" "already exists error message"

# --- proxy: container must exist ---
desc "proxy: container required"
reset_state
OUT=$("$DIR/shai-container" install heartbeat 2>&1)
RC=$?
assert_eq "$RC" "1" "install without container → exit 1"
assert_contains "$OUT" "not found" "install without container error mentions not found"

OUT=$("$DIR/shai-container" shell 2>&1)
RC=$?
assert_eq "$RC" "1" "shell without container → exit 1"

# --- proxy: install forwards to shai-supervise inside container ---
desc "proxy: install"
reset_state
touch "$INCUS_STATE/shai-sandbox"
: >"$INCUS_LOG"
OUT=$("$DIR/shai-container" install heartbeat 2>&1)
RC=$?
assert_eq "$RC" "0" "install exits 0"
assert_contains "$(cat "$INCUS_LOG")" "exec shai-sandbox" "install execs into container"
assert_contains "$(cat "$INCUS_LOG")" "shai-supervise" "install calls shai-supervise"
assert_contains "$(cat "$INCUS_LOG")" "install" "install passes install subcommand"
assert_contains "$(cat "$INCUS_LOG")" "heartbeat" "install passes workflow name"

# --- proxy: install with --interval ---
desc "proxy: install --interval"
reset_state
touch "$INCUS_STATE/shai-sandbox"
: >"$INCUS_LOG"
OUT=$("$DIR/shai-container" install heartbeat --interval 1h 2>&1)
RC=$?
assert_eq "$RC" "0" "install --interval exits 0"
assert_contains "$(cat "$INCUS_LOG")" "--interval" "install passes --interval"
assert_contains "$(cat "$INCUS_LOG")" "1h" "install passes interval value"

# --- proxy: uninstall ---
desc "proxy: uninstall"
reset_state
touch "$INCUS_STATE/shai-sandbox"
: >"$INCUS_LOG"
OUT=$("$DIR/shai-container" uninstall heartbeat 2>&1)
RC=$?
assert_eq "$RC" "0" "uninstall exits 0"
assert_contains "$(cat "$INCUS_LOG")" "shai-supervise" "uninstall calls shai-supervise"
assert_contains "$(cat "$INCUS_LOG")" "uninstall" "uninstall passes subcommand"

# --- proxy: start/stop ---
desc "proxy: start/stop"
reset_state
touch "$INCUS_STATE/shai-sandbox"
: >"$INCUS_LOG"
"$DIR/shai-container" start heartbeat >/dev/null 2>&1
assert_contains "$(cat "$INCUS_LOG")" "start" "start passes subcommand"

: >"$INCUS_LOG"
"$DIR/shai-container" stop heartbeat >/dev/null 2>&1
assert_contains "$(cat "$INCUS_LOG")" "stop" "stop passes subcommand"

# --- proxy: status ---
desc "proxy: status"
reset_state
touch "$INCUS_STATE/shai-sandbox"
: >"$INCUS_LOG"
OUT=$("$DIR/shai-container" status 2>&1)
RC=$?
assert_eq "$RC" "0" "status exits 0"
assert_contains "$(cat "$INCUS_LOG")" "shai-supervise" "status calls shai-supervise"
assert_contains "$(cat "$INCUS_LOG")" "status" "status passes subcommand"

# --- proxy: status with workflow and --json ---
: >"$INCUS_LOG"
OUT=$("$DIR/shai-container" status heartbeat --json 2>&1)
RC=$?
assert_contains "$(cat "$INCUS_LOG")" "heartbeat" "status passes workflow name"
assert_contains "$(cat "$INCUS_LOG")" "--json" "status passes --json flag"

# --- proxy: logs ---
desc "proxy: logs"
reset_state
touch "$INCUS_STATE/shai-sandbox"
: >"$INCUS_LOG"
OUT=$("$DIR/shai-container" logs heartbeat 2>&1)
RC=$?
assert_eq "$RC" "0" "logs exits 0"
assert_contains "$(cat "$INCUS_LOG")" "shai-supervise" "logs calls shai-supervise"
assert_contains "$(cat "$INCUS_LOG")" "logs" "logs passes subcommand"

# --- shell ---
desc "shell"
reset_state
touch "$INCUS_STATE/shai-sandbox"
: >"$INCUS_LOG"
OUT=$("$DIR/shai-container" shell 2>&1)
RC=$?
assert_eq "$RC" "0" "shell exits 0"
assert_contains "$(cat "$INCUS_LOG")" "exec shai-sandbox" "shell execs into container"
assert_contains "$(cat "$INCUS_LOG")" "bash" "shell runs bash"

finish
