#!/bin/bash
# test_supervise.sh — unit tests for shai-supervise
# Covers: shai-supervise — unit file generation, naming, validation, subcommand dispatch
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "shai-supervise"

make_stub_bin

# stub systemctl and journalctl
SYSTEMCTL_LOG="$STUB/systemctl.log"
: >"$SYSTEMCTL_LOG"
{
  printf '#!/bin/bash\n'
  printf 'echo "$*" >> "%s"\n' "$SYSTEMCTL_LOG"
} >"$STUB/systemctl"
chmod +x "$STUB/systemctl"

{
  printf '#!/bin/bash\n'
  printf 'echo "journalctl stub: $*"\n'
} >"$STUB/journalctl"
chmod +x "$STUB/journalctl"

TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP")
export SHAI_UNIT_DIR="$TMP"

# --- unit naming ---
NAME=$("$DIR/shai-supervise" __unit_name shai-heartbeat 2>/dev/null)
assert_eq "$NAME" "shai-heartbeat" "naming: shai-heartbeat → shai-heartbeat"

NAME=$("$DIR/shai-supervise" __unit_name myscript 2>/dev/null)
assert_eq "$NAME" "shai-myscript" "naming: myscript → shai-myscript"

NAME=$("$DIR/shai-supervise" __unit_name shai-foo 2>/dev/null)
assert_eq "$NAME" "shai-foo" "naming: shai-foo → shai-foo"

# --- unit naming: workflows/ subdirectory scripts ---
# workflow path: workflows/heartbeat/run.sh → shai-heartbeat
NAME=$("$DIR/shai-supervise" __unit_name "workflows/heartbeat/run.sh" 2>/dev/null)
assert_eq "$NAME" "shai-heartbeat" "unit_name: workflows/heartbeat/run.sh → shai-heartbeat"

# path traversal must still be caught once the workflows/ prefix and .sh
# suffix are stripped (stripping happens before the guard, not instead of it)
assert_exit 1 "unit_name: workflows/../ path traversal still rejected" -- "$DIR/shai-supervise" __unit_name "workflows/../foo.sh"

ERR=$("$DIR/shai-supervise" __unit_name "workflows/../foo.sh" 2>&1)
assert_contains "$ERR" "must not contain / or .." "unit_name: workflows/../ path traversal error message"

# --- validation: no subcommand ---
assert_exit 2 "validate: no subcommand" -- "$DIR/shai-supervise"

# --- validation: install missing script name ---
assert_exit 1 "validate: install missing script" -- "$DIR/shai-supervise" install

# --- validation: install non-existent script ---
assert_exit 1 "validate: install non-existent script" -- "$DIR/shai-supervise" install nonexistent-script-xyz

# --- validation: path traversal rejected in all subcommands (guard is in unit_name) ---
assert_exit 1 "validate: install rejects / in script name" -- "$DIR/shai-supervise" install "foo/bar"
assert_exit 1 "validate: install rejects .. in script name" -- "$DIR/shai-supervise" install "foo..bar"

ERR=$("$DIR/shai-supervise" uninstall "foo/bar" 2>&1)
assert_contains "$ERR" "must not contain / or .." "validate: path traversal error message (/ variant)"

ERR=$("$DIR/shai-supervise" uninstall "foo..bar" 2>&1)
assert_contains "$ERR" "must not contain / or .." "validate: path traversal error message (.. variant)"

assert_exit 1 "validate: uninstall rejects / in script name" -- "$DIR/shai-supervise" uninstall "foo/bar"
assert_exit 1 "validate: start rejects .. in script name" -- "$DIR/shai-supervise" start "foo..bar"

# --- validation: install missing ANTHROPIC_API_KEY ---
(
  unset ANTHROPIC_API_KEY
  assert_exit 1 "validate: install missing API key" -- "$DIR/shai-supervise" install shai-print
  exit "$FAILED"
) || FAILED=1

# --- install: generates correct unit files ---
: >"$SYSTEMCTL_LOG"
"$DIR/shai-supervise" install shai-print >/dev/null 2>&1
RC=$?
assert_eq "$RC" "0" "install: exits 0"

SERVICE="$TMP/shai-print.service"
TIMER="$TMP/shai-print.timer"

assert_eq "$([ -f "$SERVICE" ] && echo yes || echo no)" "yes" "install: .service file created"
assert_eq "$([ -f "$TIMER" ] && echo yes || echo no)" "yes" "install: .timer file created"

assert_contains "$(cat "$SERVICE")" "Type=oneshot" "install: service Type=oneshot"
assert_contains "$(cat "$SERVICE")" "ExecStart=" "install: service has ExecStart"
assert_contains "$(cat "$SERVICE")" "shai-print" "install: ExecStart references script"
assert_contains "$(cat "$SERVICE")" "ANTHROPIC_API_KEY=" "install: service has API key"
assert_contains "$(cat "$SERVICE")" "SHAI_HOME=" "install: service has SHAI_HOME"
assert_eq "$(stat -c '%a' "$SERVICE")" "600" "install: service file is chmod 600 (contains secret)"

assert_contains "$(cat "$TIMER")" "OnBootSec=5min" "install: timer OnBootSec"
assert_contains "$(cat "$TIMER")" "OnUnitActiveSec=15min" "install: timer default interval"
assert_contains "$(cat "$TIMER")" "WantedBy=timers.target" "install: timer WantedBy"

# systemctl was called for daemon-reload and enable
assert_contains "$(cat "$SYSTEMCTL_LOG")" "daemon-reload" "install: daemon-reload called"
assert_contains "$(cat "$SYSTEMCTL_LOG")" "enable" "install: enable called"

# --- install with --interval override ---
: >"$SYSTEMCTL_LOG"
"$DIR/shai-supervise" install shai-print --interval 1h >/dev/null 2>&1

assert_contains "$(cat "$TIMER")" "OnUnitActiveSec=1h" "install: --interval overrides default"

# --- idempotent reinstall ---
: >"$SYSTEMCTL_LOG"
"$DIR/shai-supervise" install shai-print >/dev/null 2>&1
RC=$?
assert_eq "$RC" "0" "reinstall: exits 0 (idempotent)"

# --- uninstall ---
: >"$SYSTEMCTL_LOG"
"$DIR/shai-supervise" uninstall shai-print >/dev/null 2>&1
RC=$?
assert_eq "$RC" "0" "uninstall: exits 0"
assert_eq "$([ -f "$SERVICE" ] && echo yes || echo no)" "no" "uninstall: .service removed"
assert_eq "$([ -f "$TIMER" ] && echo yes || echo no)" "no" "uninstall: .timer removed"
assert_contains "$(cat "$SYSTEMCTL_LOG")" "daemon-reload" "uninstall: daemon-reload called"
assert_contains "$(cat "$SYSTEMCTL_LOG")" "stop shai-print.timer" "uninstall: stop called on timer"
assert_contains "$(cat "$SYSTEMCTL_LOG")" "disable shai-print.timer" "uninstall: disable called on timer"

# --- idempotent uninstall ---
: >"$SYSTEMCTL_LOG"
"$DIR/shai-supervise" uninstall shai-print >/dev/null 2>&1
RC=$?
assert_eq "$RC" "0" "uninstall: idempotent (no error when files absent)"

# --- install: resolves scripts in the workflows/ subdirectory ---
WF_SERVICE="$TMP/shai-heartbeat.service"
WF_TIMER="$TMP/shai-heartbeat.timer"

: >"$SYSTEMCTL_LOG"
"$DIR/shai-supervise" install "workflows/heartbeat/run.sh" >/dev/null 2>&1
RC=$?
assert_eq "$RC" "0" "install: workflows/heartbeat/run.sh exits 0"
assert_eq "$([ -f "$WF_SERVICE" ] && echo yes || echo no)" "yes" "install: workflows/heartbeat/run.sh creates shai-heartbeat.service"
assert_eq "$([ -f "$WF_TIMER" ] && echo yes || echo no)" "yes" "install: workflows/heartbeat/run.sh creates shai-heartbeat.timer"
assert_contains "$(cat "$WF_SERVICE")" "ExecStart=$DIR/workflows/heartbeat/run.sh" "install: workflows/heartbeat/run.sh resolves ExecStart to the workflows/ path"

# bare filename (no workflows/ prefix) exercises the new cmd_install fallback lookup
: >"$SYSTEMCTL_LOG"
"$DIR/shai-supervise" install "heartbeat" >/dev/null 2>&1
RC=$?
assert_eq "$RC" "0" "install: bare heartbeat falls back to workflows/ and exits 0"
assert_contains "$(cat "$WF_SERVICE")" "ExecStart=$DIR/workflows/heartbeat/run.sh" "install: bare heartbeat resolves ExecStart to the workflows/ path"

: >"$SYSTEMCTL_LOG"
"$DIR/shai-supervise" uninstall shai-heartbeat >/dev/null 2>&1
assert_eq "$([ -f "$WF_SERVICE" ] && echo yes || echo no)" "no" "uninstall: shai-heartbeat (workflows/ script) .service removed"
assert_eq "$([ -f "$WF_TIMER" ] && echo yes || echo no)" "no" "uninstall: shai-heartbeat (workflows/ script) .timer removed"

# --- start/stop delegate to systemctl ---
: >"$SYSTEMCTL_LOG"
"$DIR/shai-supervise" start shai-heartbeat >/dev/null 2>&1
assert_contains "$(cat "$SYSTEMCTL_LOG")" "start" "start: delegates to systemctl"
assert_contains "$(cat "$SYSTEMCTL_LOG")" "shai-heartbeat.timer" "start: uses correct unit name"

: >"$SYSTEMCTL_LOG"
"$DIR/shai-supervise" stop shai-heartbeat >/dev/null 2>&1
assert_contains "$(cat "$SYSTEMCTL_LOG")" "stop" "stop: delegates to systemctl"

# --- status with argument ---
: >"$SYSTEMCTL_LOG"
"$DIR/shai-supervise" status shai-heartbeat >/dev/null 2>&1
assert_contains "$(cat "$SYSTEMCTL_LOG")" "status" "status: delegates to systemctl"

# --- status without argument ---
: >"$SYSTEMCTL_LOG"
"$DIR/shai-supervise" status >/dev/null 2>&1
assert_contains "$(cat "$SYSTEMCTL_LOG")" "list-units" "status (no arg): lists shai-* units"

# --- logs delegates to journalctl ---
LOG_OUTPUT=$("$DIR/shai-supervise" logs shai-heartbeat 2>&1)
assert_contains "$LOG_OUTPUT" "journalctl stub:" "logs: invokes journalctl"
assert_contains "$LOG_OUTPUT" "-u shai-heartbeat.service" "logs: journalctl invoked with correct unit"
assert_contains "$LOG_OUTPUT" "-f" "logs: journalctl invoked with -f (follow)"

# --- validation: start/stop/logs missing script name ---
assert_exit 1 "validate: start missing script" -- "$DIR/shai-supervise" start
assert_exit 1 "validate: stop missing script" -- "$DIR/shai-supervise" stop
assert_exit 1 "validate: logs missing script" -- "$DIR/shai-supervise" logs

# --- validation: --interval missing value ---
assert_exit 1 "validate: --interval missing value" -- "$DIR/shai-supervise" install shai-heartbeat --interval

finish
