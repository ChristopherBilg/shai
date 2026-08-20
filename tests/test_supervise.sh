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
  printf 'case "$*" in\n'
  printf '  *show*shai-heartbeat.timer*)\n'
  printf '    printf "LoadState=loaded\\n"\n'
  printf '    printf "ActiveState=active\\n"\n'
  printf '    printf "LastTriggerUSec=Mon 2026-08-18 14:30:00 EDT\\n"\n'
  printf '    printf "NextElapseUSecRealtime=Mon 2026-08-18 14:45:00 EDT\\n"\n'
  printf '    printf "NextElapseUSecMonotonic=0\\n"\n'
  printf '    ;;\n'
  printf '  *show*shai-review-dispatcher.timer*)\n'
  printf '    printf "LoadState=loaded\\n"\n'
  printf '    printf "ActiveState=inactive\\n"\n'
  printf '    printf "LastTriggerUSec=n/a\\n"\n'
  printf '    printf "NextElapseUSecRealtime=n/a\\n"\n'
  printf '    printf "NextElapseUSecMonotonic=0\\n"\n'
  printf '    ;;\n'
  # monotonic timer (what `install` writes): realtime elapse is unset, only the
  # monotonic one is reported
  printf '  *show*shai-monotonic.timer*)\n'
  printf '    printf "LoadState=loaded\\n"\n'
  printf '    printf "ActiveState=active\\n"\n'
  printf '    printf "LastTriggerUSec=Mon 2026-08-18 14:30:00 EDT\\n"\n'
  printf '    printf "NextElapseUSecRealtime=n/a\\n"\n'
  printf '    printf "NextElapseUSecMonotonic=Mon 2026-08-18 15:15:00 EDT\\n"\n'
  printf '    ;;\n'
  # a garbage timestamp must not be passed through half-truncated
  printf '  *show*shai-badstamp.timer*)\n'
  printf '    printf "LoadState=loaded\\n"\n'
  printf '    printf "ActiveState=active\\n"\n'
  printf '    printf "LastTriggerUSec=0\\n"\n'
  printf '    printf "NextElapseUSecRealtime=whenever soon:ish\\n"\n'
  printf '    printf "NextElapseUSecMonotonic=n/a\\n"\n'
  printf '    ;;\n'
  printf '  *show*shai-missing.timer*)\n'
  printf '    printf "LoadState=not-found\\n"\n'
  printf '    printf "ActiveState=inactive\\n"\n'
  printf '    printf "LastTriggerUSec=n/a\\n"\n'
  printf '    printf "NextElapseUSecRealtime=n/a\\n"\n'
  printf '    ;;\n'
  # simulates a failing `systemctl show` (e.g. no user bus available)
  printf '  *show*shai-nobus.timer*)\n'
  printf '    echo "Failed to connect to bus" >&2\n'
  printf '    exit 1\n'
  printf '    ;;\n'
  printf '  *show*)\n'
  printf '    printf "LoadState=loaded\\n"\n'
  printf '    printf "ActiveState=inactive\\n"\n'
  printf '    printf "LastTriggerUSec=n/a\\n"\n'
  printf '    printf "NextElapseUSecRealtime=n/a\\n"\n'
  printf '    printf "NextElapseUSecMonotonic=0\\n"\n'
  printf '    ;;\n'
  printf 'esac\n'
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

# --- validation: install missing DEEPSEEK_API_KEY ---
(
  unset DEEPSEEK_API_KEY
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
assert_contains "$(cat "$SERVICE")" "DEEPSEEK_API_KEY=" "install: service has API key"
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

# --- status with argument (queries systemctl show) ---
: >"$SYSTEMCTL_LOG"
OUT=$("$DIR/shai-supervise" status shai-heartbeat 2>&1)
assert_contains "$(cat "$SYSTEMCTL_LOG")" "show" "status <script>: queries systemctl show"
assert_contains "$OUT" "shai-heartbeat" "status <script>: output contains unit name"

# --- status without argument (discovers timer files, queries each) ---
touch "$TMP/shai-heartbeat.timer"
: >"$SYSTEMCTL_LOG"
OUT=$("$DIR/shai-supervise" status 2>&1)
assert_contains "$(cat "$SYSTEMCTL_LOG")" "show" "status (no arg): queries systemctl show for discovered units"
assert_contains "$OUT" "UNIT" "status (no arg): output has table header"
rm -f "$TMP/shai-heartbeat.timer"

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

# --- status: formatted table output ---

touch "$TMP/shai-heartbeat.timer"
touch "$TMP/shai-review-dispatcher.timer"

: >"$SYSTEMCTL_LOG"
OUT=$("$DIR/shai-supervise" status 2>&1)
assert_contains "$OUT" "UNIT" "status table: header has UNIT"
assert_contains "$OUT" "STATE" "status table: header has STATE"
assert_contains "$OUT" "LAST" "status table: header has LAST"
assert_contains "$OUT" "NEXT" "status table: header has NEXT"

assert_contains "$OUT" "shai-heartbeat" "status table: lists shai-heartbeat"
assert_contains "$OUT" "shai-review-dispatcher" "status table: lists shai-review-dispatcher"

assert_contains "$OUT" "active" "status table: shows active state"
assert_contains "$OUT" "inactive" "status table: shows inactive state"

assert_contains "$OUT" "2026-08-18 14:30" "status table: shows parsed last trigger time"
assert_contains "$OUT" "2026-08-18 14:45" "status table: shows parsed next trigger time"

assert_contains "$OUT" "--" "status table: n/a timing rendered as --"

HB_NUM=$(echo "$OUT" | grep -n "shai-heartbeat" | head -1 | cut -d: -f1)
RD_NUM=$(echo "$OUT" | grep -n "shai-review-dispatcher" | head -1 | cut -d: -f1)
if [ "$HB_NUM" -lt "$RD_NUM" ]; then ORDERED="yes"; else ORDERED="no"; fi
assert_eq "$ORDERED" "yes" "status table: units in alphabetical order"

# --- status: script arg filters to one unit ---
: >"$SYSTEMCTL_LOG"
OUT=$("$DIR/shai-supervise" status heartbeat 2>&1)
assert_contains "$OUT" "shai-heartbeat" "status <script>: shows named unit"
if echo "$OUT" | grep -q "review-dispatcher"; then FILTERED="no"; else FILTERED="yes"; fi
assert_eq "$FILTERED" "yes" "status <script>: filters to named unit only"

# --- status --json ---
: >"$SYSTEMCTL_LOG"
OUT=$("$DIR/shai-supervise" status --json 2>&1)
echo "$OUT" | jq empty 2>/dev/null
assert_eq "$?" "0" "status --json: valid JSON"

UNITS=$(echo "$OUT" | jq -r '.[].unit' 2>/dev/null | sort)
assert_contains "$UNITS" "shai-heartbeat" "status --json: contains shai-heartbeat"
assert_contains "$UNITS" "shai-review-dispatcher" "status --json: contains shai-review-dispatcher"

FIRST_KEYS=$(echo "$OUT" | jq -r '.[0] | keys[]' 2>/dev/null | sort | tr '\n' ',')
assert_contains "$FIRST_KEYS" "unit," "status --json: has unit field"
assert_contains "$FIRST_KEYS" "state," "status --json: has state field"
assert_contains "$FIRST_KEYS" "last," "status --json: has last field"
assert_contains "$FIRST_KEYS" "next," "status --json: has next field"

# --- status: script + --json ---
: >"$SYSTEMCTL_LOG"
OUT=$("$DIR/shai-supervise" status heartbeat --json 2>&1)
COUNT=$(echo "$OUT" | jq 'length' 2>/dev/null)
assert_eq "$COUNT" "1" "status <script> --json: one element"
UNIT_NAME=$(echo "$OUT" | jq -r '.[0].unit' 2>/dev/null)
assert_eq "$UNIT_NAME" "shai-heartbeat" "status <script> --json: correct unit"

# --- status: empty UNIT_DIR ---
rm -f "$TMP"/shai-*.timer "$TMP"/shai-*.service
: >"$SYSTEMCTL_LOG"
OUT=$("$DIR/shai-supervise" status 2>&1)
if [ -z "$OUT" ]; then EMPTY="yes"; else EMPTY="no"; fi
assert_eq "$EMPTY" "yes" "status: empty produces no output"

: >"$SYSTEMCTL_LOG"
OUT=$("$DIR/shai-supervise" status --json 2>&1)
assert_eq "$OUT" "[]" "status --json: empty produces []"

# --- status: argument validation ---
assert_exit 1 "status: unknown option rejected" -- "$DIR/shai-supervise" status --jsn
ERR=$("$DIR/shai-supervise" status --jsn 2>&1)
assert_contains "$ERR" "unknown option: --jsn" "status: unknown option error message"

assert_exit 1 "status: extra positional argument rejected" -- "$DIR/shai-supervise" status heartbeat extra
ERR=$("$DIR/shai-supervise" status heartbeat extra 2>&1)
assert_contains "$ERR" "unexpected argument: extra" "status: extra argument error message"

# --- status: monotonic timers (what install writes) still report NEXT ---
: >"$SYSTEMCTL_LOG"
OUT=$("$DIR/shai-supervise" status monotonic 2>&1)
assert_contains "$(cat "$SYSTEMCTL_LOG")" "NextElapseUSecMonotonic" "status: queries NextElapseUSecMonotonic too"
assert_contains "$OUT" "2026-08-18 15:15" "status: falls back to monotonic next-elapse when realtime is n/a"

OUT=$("$DIR/shai-supervise" status monotonic --json 2>&1)
NEXT=$(echo "$OUT" | jq -r '.[0].next' 2>/dev/null)
assert_eq "$NEXT" "2026-08-18 15:15" "status --json: monotonic fallback shared with table renderer"

# --- status: unparseable timestamps render as -- rather than being truncated ---
OUT=$("$DIR/shai-supervise" status badstamp 2>&1)
if echo "$OUT" | grep -q "whenever"; then LEAKED="yes"; else LEAKED="no"; fi
assert_eq "$LEAKED" "no" "status: unrecognized timestamp format is not passed through"
NEXT=$("$DIR/shai-supervise" status badstamp --json 2>&1 | jq -r '.[0].next' 2>/dev/null)
assert_eq "$NEXT" "--" "status --json: unrecognized timestamp renders as --"
LAST=$("$DIR/shai-supervise" status badstamp --json 2>&1 | jq -r '.[0].last' 2>/dev/null)
assert_eq "$LAST" "--" "status --json: bare 0 timestamp renders as --"

# --- status: named unit unknown to systemd is an error ---
assert_exit 1 "status <unknown unit>: exits 1" -- "$DIR/shai-supervise" status missing
ERR=$("$DIR/shai-supervise" status missing 2>&1)
assert_contains "$ERR" "shai-missing.timer not found" "status <unknown unit>: reports not-found"

# --- status: a failing systemctl show warns and exits non-zero ---
assert_exit 1 "status: systemctl failure exits 1" -- "$DIR/shai-supervise" status nobus
ERR=$("$DIR/shai-supervise" status nobus 2>&1 >/dev/null)
assert_contains "$ERR" "warning: systemctl show failed" "status: systemctl failure warns on stderr"

finish
