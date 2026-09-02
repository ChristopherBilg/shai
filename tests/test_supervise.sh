#!/bin/bash
# test_supervise.sh — unit tests for shai-supervise
# Covers: shai-supervise — unit file generation, naming, validation, subcommand dispatch,
#   status rendering (status_next timestamp + raw-usec next elapse, table + JSON, INSTALL
#   column stale/ok detection), repoint (ExecStart rewrite through current, skip/warn
#   cases, dry-run, usage errors, versioned-dir refusal)
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "shai-supervise"

make_stub_bin

# raw-usec next-elapse value for the shai-rawusec systemctl fixture below: 9 digits
# (inside status_next's 15-digit bound), ~988 s of uptime — the form systemd reports
# for OnBootSec=/OnUnitActiveSec= timers when it does not render a timestamp
RAW_USEC=987654321

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
  # raw-usec monotonic elapse (the form `install`'s OnBootSec=/OnUnitActiveSec= timers
  # actually produce): realtime is unset, monotonic is microseconds since boot
  printf '  *show*shai-rawusec.timer*)\n'
  printf '    printf "LoadState=loaded\\n"\n'
  printf '    printf "ActiveState=active\\n"\n'
  printf '    printf "LastTriggerUSec=0\\n"\n'
  printf '    printf "NextElapseUSecRealtime=n/a\\n"\n'
  printf '    printf "NextElapseUSecMonotonic=%s\\n"\n' "$RAW_USEC"
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

# --- status_next unit tests: extract the functions instead of sourcing the script ---
# shai-supervise runs its `case` dispatch at the global scope (no `main` guard), so it
# cannot be `source`d without also executing the dispatch against the test's own
# arguments. Extract just the function definitions — everything from the top of the
# file up to (but not including) the global `case` — and eval them inside a helper,
# mirroring tests/test_policy.sh. Two isolation layers matter here:
#   - every call site below invokes run_status_next inside a `$(...)` command
#     substitution, which forks a subshell, so the extracted `set -euo pipefail` can
#     never leak into (or change the behavior of) this test script;
#   - the eval'd DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")")" resolves to tests/
#     (${BASH_SOURCE[0]} is this file under eval), so the eval'd `source` of
#     lib/units.sh is rewritten below to the real repo lib instead of tests/lib/.
extract_functions() {
  sed -n '1,/^case "/p' "$DIR/shai-supervise" | head -n -1 |
    sed -e "s|\$DIR/lib/units.sh|$DIR/lib/units.sh|g"
}

run_status_next() {
  local realtime="$1" monotonic="$2" extracted
  extracted=$(extract_functions)
  # If the ^case " anchor in extract_functions ever stops matching, sed prints the
  # whole file — including the global `case` dispatch — and eval'ing it would run the
  # dispatch against this helper's own arguments before dying as a confusing RC. A
  # correct extraction stops before the dispatch, so it contains no column-0
  # `case "` line; reject that text by name instead of eval'ing the dispatch.
  if [[ "$extracted" == *$'\ncase "'* ]]; then
    printf '%s\n' 'run_status_next: extraction broken — extract_functions printed the global dispatch (the ^case " anchor no longer matches shai-supervise)' >&2
    exit 1
  fi
  eval "$extracted"
  # Catch the inverse break too: an anchor that stops matching early truncates the
  # extraction before status_next, leaving it undefined — name that here instead of
  # failing as a bare command-not-found at the call below.
  declare -F status_next >/dev/null 2>&1 ||
    {
      printf '%s\n' 'run_status_next: extraction broken — status_next is not defined after eval (the ^case " anchor stopped matching before it)' >&2
      exit 1
    }
  status_next "$realtime" "$monotonic"
}

# status_next reads the boot time via `awk '/^btime /…' /proc/stat` and renders the
# converted epoch via `date -d`. Both are stubbed so the two guard branches below
# (no btime line; date failure) can be driven directly: those conditions are not
# reachable end-to-end on a Linux host, and guard branches get unit tests, not
# integration tests — please don't "fix" these tests into provoking the guards
# through the status fixture. The awk stub's default mode reproduces the real
# /proc/stat btime (captured here, before the stub shadows the real awk), so the
# shipped-path tests below stay conversion-true without hardcoding a wall clock.
REAL_DATE="$(command -v date)"
REAL_BTIME=$(awk '/^btime /{print $2; exit}' /proc/stat 2>/dev/null)
{
  printf '#!/bin/bash\n'
  printf 'if [ "${AWK_BTIME_MODE:-btime}" = "none" ]; then exit 0; fi\n'
  printf 'printf "%%s\\n" "%s"\n' "$REAL_BTIME"
} >"$STUB/awk"
chmod +x "$STUB/awk"
{
  printf '#!/bin/bash\n'
  printf 'if [ "${DATE_STUB_FAIL:-0}" = "1" ]; then echo "date stub: simulated failure" >&2; exit 1; fi\n'
  printf 'exec %s "$@"\n' "$REAL_DATE"
} >"$STUB/date"
chmod +x "$STUB/date"

# --- status_next: raw-usec branch (the shipped `install` path) ---
# The expectation is derived the same way the implementation derives its output —
# btime + usec/1000000 through `date -d` — never a hardcoded wall-clock string, so it
# stays correct across reboots and machines. The shape assertion guards the fixture
# itself: if this environment's `date -d` ever fails, the derived expectation is empty
# and the comparisons below would pass vacuously (see the mutation rules in CLAUDE.md).
USEC=123456789 # ~123.46 s after boot
EXPECTED=$(date -d "@$((REAL_BTIME + USEC / 1000000))" '+%Y-%m-%d %H:%M' 2>/dev/null)
if [[ "$EXPECTED" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}$ ]]; then
  SHAPE=ok
else
  SHAPE=bad
fi
assert_eq "$SHAPE" "ok" "status_next: derived expectation has the rendered shape (date -d works here)"
NEXT=$(run_status_next "" "$USEC")
RC=$?
assert_eq "$RC" "0" "status_next: raw-usec conversion completes"
assert_eq "$NEXT" "$EXPECTED" "status_next: raw usec converted via btime + date"

# --- status_next: the 15-digit bound keeps USEC_INFINITY out of the arithmetic ---
# USEC_INFINITY (18446744073709551615 — systemd's "never") is 20 digits: converting
# the full value overflows bash's signed 64-bit arithmetic, so the ^[0-9]{1,15}$ bound
# must reject it first. Mutation-checked: widening the bound to {1,20} lets
# USEC_INFINITY through and the empty-output assertion below went red (on the bash
# tested here the arithmetic silently wrapped, rendering boot's own wall clock instead
# of empty; on a bash that aborts the conversion the extracted `set -e` kills the
# subshell — the RC assertion above covers that flavor).
NEXT=$(run_status_next "" "18446744073709551615")
RC=$?
assert_eq "$RC" "0" "status_next: USEC_INFINITY rejected without an arithmetic abort"
assert_eq "$NEXT" "" "status_next: USEC_INFINITY renders empty (-- in the table)"

# --- status_next: monotonic 0 means "not scheduled", not "epoch + 0" ---
# Mutation-checked: dropping the `!= 0` guard lets 0 reach the conversion, which
# renders btime's own wall clock instead of empty — the assertion below goes red.
NEXT=$(run_status_next "" "0")
RC=$?
assert_eq "$RC" "0" "status_next: monotonic 0 rejected without an arithmetic abort"
assert_eq "$NEXT" "" "status_next: monotonic 0 renders empty (-- in the table), not epoch + 0"

# --- status_next: /proc/stat without a btime line renders empty ---
# Guard branch, driven directly through the awk stub (AWK_BTIME_MODE=none): no Linux
# /proc/stat actually lacks a btime line, so this cannot be provoked end-to-end — keep
# it a direct guard test. Mutation-checked: deleting the `-n "$boot"` guard converts
# the empty boot through `date -d @<usec/1000000>` and the assertion below goes red.
NEXT=$(AWK_BTIME_MODE=none run_status_next "" "$USEC")
RC=$?
assert_eq "$RC" "0" "status_next: missing btime line does not abort"
assert_eq "$NEXT" "" "status_next: missing btime line renders empty (-- in the table)"

# --- status_next: a failing `date -d` renders empty instead of aborting ---
# Guard branch (`|| true`), driven directly through the date stub (DATE_STUB_FAIL=1):
# date failures are not reachable end-to-end here. Mutation-checked: deleting the
# `|| true` kills the subshell under the extracted `set -e` — the RC assertion is the
# control that goes red (again, the aborted subshell prints nothing, so the
# empty-output assertion alone would stay green).
NEXT=$(DATE_STUB_FAIL=1 run_status_next "" "$USEC")
RC=$?
assert_eq "$RC" "0" "status_next: a failing date -d does not abort"
assert_eq "$NEXT" "" "status_next: a failing date -d renders empty (-- in the table)"

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

desc "generated units carry every required provider variable"

# A systemd unit inherits nothing from the installing shell, so any variable not embedded here
# is missing at tick time — the workflow would fail on every timer firing. Values are quoted
# (see the "quoted so embedded whitespace" block below for why), so the expected substrings
# include the surrounding double quotes.
SHAI_API_KEY="k" SHAI_API_URL="https://example.invalid/v1/chat/completions" SHAI_MODEL="m" \
  "$DIR/shai-supervise" install workflows/heartbeat/run.sh >/dev/null 2>&1
SERVICE="$TMP/shai-heartbeat.service"
assert_contains "$(cat "$SERVICE")" 'Environment=SHAI_API_KEY="k"' "unit embeds SHAI_API_KEY"
assert_contains "$(cat "$SERVICE")" \
  'Environment=SHAI_API_URL="https://example.invalid/v1/chat/completions"' \
  "unit embeds SHAI_API_URL"
assert_contains "$(cat "$SERVICE")" 'Environment=SHAI_MODEL="m"' "unit embeds SHAI_MODEL"
assert_contains "$(cat "$SERVICE")" "Environment=SHAI_HOME=" "unit still embeds SHAI_HOME"

# The .service holds a plaintext key, so the mode must stay restrictive.
assert_eq "$(stat -c '%a' "$SERVICE")" "600" "unit stays mode 600 with the added lines"

desc "Environment= values are quoted so embedded whitespace is not silently truncated"

# Per systemd.exec(5), Environment= is space-delimited; an unquoted value containing a space is
# parsed as two tokens, and systemd drops everything from the first space onward with no error
# at install time and none at tick time (confirmed with `systemd-analyze verify`: "Invalid
# environment assignment, ignoring: <word>") — the workflow then silently runs against a
# truncated value instead of failing loudly. SHAI_MODEL="my model" exercises one of the three
# variables this task added; SHAI_HOME with a space in the path exercises the pre-existing line,
# since a home directory is the most plausible real-world case of an unescaped space. Both
# assertions check for the *complete* value between quotes, not just presence of the prefix, so
# a truncating regression is caught.
SHAI_API_KEY="k" SHAI_API_URL="https://example.invalid/v1/chat/completions" SHAI_MODEL="my model" \
  SHAI_HOME="$TMP/my home" "$DIR/shai-supervise" install workflows/heartbeat/run.sh >/dev/null 2>&1
assert_contains "$(cat "$SERVICE")" 'Environment=SHAI_MODEL="my model"' \
  "install: a value containing a space is quoted whole, not truncated"
assert_contains "$(cat "$SERVICE")" "Environment=SHAI_HOME=\"$TMP/my home\"" \
  "install: SHAI_HOME containing a space is quoted whole, not truncated"

desc "install refuses when any required variable is unset"

# assert_fails applies cleanly here: shai-supervise install reads no stdin.
for var in SHAI_API_KEY SHAI_API_URL SHAI_MODEL; do
  assert_fails 1 "$var must be set" "install without $var" \
    -- env -u "$var" "$DIR/shai-supervise" install workflows/heartbeat/run.sh
done

desc "install refuses when any required variable is set but empty"

# ${!v:-} treats unset and empty identically, which is what makes the loop above correct for the
# empty case too; nothing until now pinned that specifically. Guards a future refactor to
# `[ -v "$v" ]` (which DOES distinguish empty from unset) from silently reintroducing an
# empty-string bypass. `env "$var="` sets that one variable to the empty string for the child
# while leaving the other two at their ambient (non-empty) values, isolating which check fires.
for var in SHAI_API_KEY SHAI_API_URL SHAI_MODEL; do
  assert_fails 1 "$var must be set" "install with $var empty" \
    -- env "$var=" "$DIR/shai-supervise" install workflows/heartbeat/run.sh
done

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
assert_contains "$(cat "$SERVICE")" "SHAI_API_KEY=" "install: service has API key"
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

# --- status: INSTALL column reports a stale install, and status still exits 0 ---
# Fixture: a .service whose ExecStart points at an old install directory that still exists
# and is executable — the post-upgrade state this feature exists to surface. The stale row
# must be asserted present before the exit-0 assertion below (mutation-checked: a build
# that never detects staleness would still exit 0 and the test would pass trivially).
mkdir -p "$TMP/oldinstall/workflows/heartbeat"
printf '#!/bin/bash\nprintf "old heartbeat\\n"\n' >"$TMP/oldinstall/workflows/heartbeat/run.sh"
chmod +x "$TMP/oldinstall/workflows/heartbeat/run.sh"
cat >"$TMP/shai-heartbeat.service" <<EOF
[Unit]
Description=shai shai-heartbeat workflow

[Service]
Type=oneshot
ExecStart=$TMP/oldinstall/workflows/heartbeat/run.sh
Environment=SHAI_API_KEY=test-key
Environment=SHAI_HOME=$HOME/.shai
EOF
# healthy control: the direct-script ExecStart shape under the real checkout → ok
cat >"$TMP/shai-review-dispatcher.service" <<EOF
[Unit]
Description=shai shai-review-dispatcher workflow

[Service]
Type=oneshot
ExecStart=$DIR/shai-print
Environment=SHAI_API_KEY=test-key
Environment=SHAI_HOME=$HOME/.shai
EOF

: >"$SYSTEMCTL_LOG"
OUT=$("$DIR/shai-supervise" status heartbeat 2>&1)
RC=$?
assert_contains "$OUT" "INSTALL" "status table: header has INSTALL"
assert_contains "$OUT" "2026-08-18 14:45   stale" \
  "status table: NEXT keeps its full value next to the new INSTALL column"
assert_eq "$RC" "0" "status: stale unit still exits 0 (a query, not a check)"

OUT=$("$DIR/shai-supervise" status 2>&1)
assert_contains "$OUT" "ok" "status table: healthy unit renders ok in the INSTALL column"

: >"$SYSTEMCTL_LOG"
OUT=$("$DIR/shai-supervise" status --json 2>&1)
FIRST_KEYS=$(echo "$OUT" | jq -r '.[0] | keys[]' 2>/dev/null | sort | tr '\n' ',')
assert_contains "$FIRST_KEYS" "install," "status --json: has install field"
INSTALL=$(echo "$OUT" | jq -r '.[] | select(.unit == "shai-heartbeat") | .install' 2>/dev/null)
assert_eq "$INSTALL" "stale" "status --json: install key is stale for the stale unit"
INSTALL=$(echo "$OUT" | jq -r '.[] | select(.unit == "shai-review-dispatcher") | .install' 2>/dev/null)
assert_eq "$INSTALL" "ok" "status --json: install key is ok for the healthy unit"

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

# --- status: timestamp-form monotonic next elapse (systemd can render the monotonic
#     value as a timestamp) still reports NEXT. This fixture supplies the timestamp
#     form, which takes status_next's early `return`; the raw-usec form of the same
#     value — the shai-rawusec fixture and the status_next unit tests above — is
#     covered separately. ---
: >"$SYSTEMCTL_LOG"
OUT=$("$DIR/shai-supervise" status monotonic 2>&1)
assert_contains "$(cat "$SYSTEMCTL_LOG")" "NextElapseUSecMonotonic" "status: queries NextElapseUSecMonotonic too"
assert_contains "$OUT" "2026-08-18 15:15" "status: falls back to timestamp-form monotonic next-elapse when realtime is n/a"

OUT=$("$DIR/shai-supervise" status monotonic --json 2>&1)
NEXT=$(echo "$OUT" | jq -r '.[0].next' 2>/dev/null)
assert_eq "$NEXT" "2026-08-18 15:15" "status --json: timestamp-form monotonic fallback shared with table renderer"

# --- status: raw-usec monotonic next elapse (the form `install`'s
#     OnBootSec=/OnUnitActiveSec= timers actually produce) is converted in the table
#     and in --json, which share status_query and therefore cannot disagree ---
RAW_EXPECTED=$(date -d "@$((REAL_BTIME + RAW_USEC / 1000000))" '+%Y-%m-%d %H:%M' 2>/dev/null)
if [[ "$RAW_EXPECTED" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}$ ]]; then
  RAW_SHAPE=ok
else
  RAW_SHAPE=bad
fi
assert_eq "$RAW_SHAPE" "ok" "status: derived raw-usec expectation has the rendered shape"
: >"$SYSTEMCTL_LOG"
OUT=$("$DIR/shai-supervise" status rawusec 2>&1)
assert_contains "$OUT" "$RAW_EXPECTED" "status: raw-usec next elapse converted to wall clock in the table"

OUT=$("$DIR/shai-supervise" status rawusec --json 2>&1)
NEXT=$(echo "$OUT" | jq -r '.[0].next' 2>/dev/null)
assert_eq "$NEXT" "$RAW_EXPECTED" "status --json: raw-usec conversion shared with the table renderer"

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

# --- repoint: fixture install tree with a current symlink ---
# Invoking shai-supervise through <root>/current/shai-supervise makes it compute
# $DIR=<root>/current (the logical path), so a repointed ExecStart resolves through
# current instead of a version directory. The old version tree is a real directory —
# a distinct physical location, so unit_install_state reports it stale rather than ok.
REPOINT_ROOT="$(mktemp -d)"
_CLEANUP_DIRS+=("$REPOINT_ROOT")
mkdir -p "$REPOINT_ROOT/v2026.07.01/workflows/heartbeat"
printf '#!/bin/bash\nprintf "old heartbeat\\n"\n' >"$REPOINT_ROOT/v2026.07.01/workflows/heartbeat/run.sh"
chmod +x "$REPOINT_ROOT/v2026.07.01/workflows/heartbeat/run.sh"
printf '#!/bin/bash\nprintf "old print\\n"\n' >"$REPOINT_ROOT/v2026.07.01/shai-print"
chmod +x "$REPOINT_ROOT/v2026.07.01/shai-print"
ln -s "$DIR" "$REPOINT_ROOT/v2026.08.10"
ln -s "v2026.08.10" "$REPOINT_ROOT/current"
SUPERVISE="$REPOINT_ROOT/current/shai-supervise"

# --- repoint <script>: rewrites only the ExecStart= line ---
cat >"$TMP/shai-heartbeat.service" <<EOF
[Unit]
Description=shai shai-heartbeat workflow

[Service]
Type=oneshot
ExecStart=$REPOINT_ROOT/v2026.07.01/workflows/heartbeat/run.sh
Environment=SHAI_API_KEY=test-key
Environment=SHAI_HOME=$HOME/.shai
EOF
chmod 600 "$TMP/shai-heartbeat.service"
cat >"$TMP/shai-heartbeat.timer" <<EOF
[Unit]
Description=shai shai-heartbeat timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=45min

[Install]
WantedBy=timers.target
EOF
BEFORE=$(grep -v '^ExecStart=' "$TMP/shai-heartbeat.service")

: >"$SYSTEMCTL_LOG"
OUT=$("$SUPERVISE" repoint heartbeat 2>&1)
RC=$?
assert_eq "$RC" "0" "repoint: exits 0"
assert_contains "$(cat "$TMP/shai-heartbeat.service")" \
  "ExecStart=$REPOINT_ROOT/current/workflows/heartbeat/run.sh" \
  "repoint: ExecStart rewritten to resolve through /current/"
assert_eq "$(grep -v '^ExecStart=' "$TMP/shai-heartbeat.service")" "$BEFORE" \
  "repoint: every line except ExecStart is byte-preserved"
assert_contains "$(cat "$TMP/shai-heartbeat.service")" "Environment=SHAI_API_KEY=test-key" \
  "repoint: the API key line is preserved"
assert_eq "$(stat -c '%a' "$TMP/shai-heartbeat.service")" "600" \
  "repoint: the .service file is still mode 600"
assert_contains "$(cat "$TMP/shai-heartbeat.timer")" "OnUnitActiveSec=45min" \
  "repoint: the customized timer interval is untouched"
assert_contains "$OUT" "v2026.07.01 -> current" "repoint: reports old version -> current"
assert_contains "$OUT" "daemon-reloaded; 1 unit repointed" "repoint: summary names the reload and count"
assert_contains "$(cat "$SYSTEMCTL_LOG")" "daemon-reload" "repoint: daemon-reload called after a rewrite"

# --- repoint --all: stale unit rewritten, already-current unit skipped ---
# The stale fixture doubles as the mutation control for the skip assertion: a build
# that classified everything as current would print the skip line but fail the
# rewrite assertions, and vice versa.
cat >"$TMP/shai-issue-dispatcher.service" <<EOF
[Unit]
Description=shai shai-issue-dispatcher workflow

[Service]
Type=oneshot
ExecStart=$REPOINT_ROOT/v2026.07.01/shai-print
Environment=SHAI_API_KEY=test-key
Environment=SHAI_HOME=$HOME/.shai
EOF
chmod 600 "$TMP/shai-issue-dispatcher.service"
# heartbeat was repointed by the test above: it is the already-current control here.
: >"$SYSTEMCTL_LOG"
OUT=$("$SUPERVISE" repoint --all 2>&1)
RC=$?
assert_eq "$RC" "0" "repoint --all: exits 0"
assert_contains "$(cat "$TMP/shai-issue-dispatcher.service")" \
  "ExecStart=$REPOINT_ROOT/current/shai-print" \
  "repoint --all: direct-script ExecStart rewritten through /current/"
assert_contains "$OUT" "already current (skipped)" \
  "repoint --all: the already-current unit is skipped"
assert_contains "$OUT" "v2026.07.01 -> current" \
  "repoint --all: the stale unit in the same run is repointed (mutation control)"
assert_eq "$(grep -c 'daemon-reload' "$SYSTEMCTL_LOG")" "1" \
  "repoint --all: exactly one daemon-reload for the whole run"

# --- repoint --all again: nothing to do, no daemon-reload ---
: >"$SYSTEMCTL_LOG"
OUT=$("$SUPERVISE" repoint --all 2>&1)
RC=$?
assert_eq "$RC" "0" "repoint: exits 0 when nothing to do"
assert_contains "$OUT" "already current (skipped)" "repoint: nothing-to-do run still reports the skip"
if grep -q 'daemon-reload' "$SYSTEMCTL_LOG"; then RELOADED="yes"; else RELOADED="no"; fi
assert_eq "$RELOADED" "no" \
  "repoint: no daemon-reload when nothing changed (the test above is the reloading case)"

# --- repoint --dry-run: prints the diff, writes nothing ---
cat >"$TMP/shai-heartbeat.service" <<EOF
[Unit]
Description=shai shai-heartbeat workflow

[Service]
Type=oneshot
ExecStart=$REPOINT_ROOT/v2026.07.01/workflows/heartbeat/run.sh
Environment=SHAI_API_KEY=test-key
Environment=SHAI_HOME=$HOME/.shai
EOF
chmod 600 "$TMP/shai-heartbeat.service"
cp "$TMP/shai-heartbeat.service" "$TMP/heartbeat.before"

: >"$SYSTEMCTL_LOG"
OUT=$("$SUPERVISE" repoint --all --dry-run 2>&1)
RC=$?
assert_eq "$RC" "0" "repoint --dry-run: exits 0"
if cmp -s "$TMP/heartbeat.before" "$TMP/shai-heartbeat.service"; then
  echo -e "  ${GREEN}✓${NC} repoint --dry-run: the unit file is byte-identical afterwards (writes nothing)"
else
  echo -e "  ${RED}✗${NC} repoint --dry-run: the unit file was modified"
  FAILED=1
fi
assert_contains "$OUT" "-ExecStart=$REPOINT_ROOT/v2026.07.01/workflows/heartbeat/run.sh" \
  "repoint --dry-run: the diff shows the old ExecStart"
assert_contains "$OUT" "+ExecStart=$REPOINT_ROOT/current/workflows/heartbeat/run.sh" \
  "repoint --dry-run: the diff shows the new ExecStart"
assert_contains "$OUT" "1 unit(s) would be repointed (dry run)" \
  "repoint --dry-run: summary line"
if grep -q 'daemon-reload' "$SYSTEMCTL_LOG"; then RELOADED="yes"; else RELOADED="no"; fi
assert_eq "$RELOADED" "no" "repoint --dry-run: no daemon-reload"
"$SUPERVISE" repoint heartbeat >/dev/null 2>&1
assert_contains "$(cat "$TMP/shai-heartbeat.service")" \
  "ExecStart=$REPOINT_ROOT/current/workflows/heartbeat/run.sh" \
  "repoint: a real run after --dry-run rewrites the unit (positive control)"

# --- repoint: unrecognized ExecStart shape is warned about and skipped ---
cat >"$TMP/shai-review-dispatcher.service" <<EOF
[Unit]
Description=shai shai-review-dispatcher workflow

[Service]
Type=oneshot
ExecStart=/usr/bin/something-else
Environment=SHAI_API_KEY=test-key
Environment=SHAI_HOME=$HOME/.shai
EOF
chmod 600 "$TMP/shai-review-dispatcher.service"
# Make heartbeat stale again so the same run has a recognized-shape positive control.
cat >"$TMP/shai-heartbeat.service" <<EOF
[Unit]
Description=shai shai-heartbeat workflow

[Service]
Type=oneshot
ExecStart=$REPOINT_ROOT/v2026.07.01/workflows/heartbeat/run.sh
Environment=SHAI_API_KEY=test-key
Environment=SHAI_HOME=$HOME/.shai
EOF
chmod 600 "$TMP/shai-heartbeat.service"
# A workflow segment containing a slash (workflows/a/b/run.sh) is a hand-edit
# cmd_install's unit_name could never have written (it rejects /), so it must be
# warned about and skipped too — rewriting it would produce a nonexistent
# $DIR/workflows/a/b/run.sh. Mutation-checked: without the slash check the old
# ..-only guard accepts the shape and rewrites the line to .../current/..., which
# fails the byte-exact ExecStart assertion below.
mkdir -p "$REPOINT_ROOT/v2026.07.01/workflows/a/b"
printf '#!/bin/bash\necho nested\n' >"$REPOINT_ROOT/v2026.07.01/workflows/a/b/run.sh"
chmod +x "$REPOINT_ROOT/v2026.07.01/workflows/a/b/run.sh"
cat >"$TMP/shai-nested-path.service" <<EOF
[Unit]
Description=shai shai-nested-path workflow

[Service]
Type=oneshot
ExecStart=$REPOINT_ROOT/v2026.07.01/workflows/a/b/run.sh
Environment=SHAI_API_KEY=test-key
Environment=SHAI_HOME=$HOME/.shai
EOF
chmod 600 "$TMP/shai-nested-path.service"
OUT=$("$SUPERVISE" repoint --all 2>&1)
assert_contains "$OUT" "unrecognized ExecStart shape (skipped)" \
  "repoint: unrecognized shape warned and skipped"
assert_contains "$(cat "$TMP/shai-review-dispatcher.service")" "ExecStart=/usr/bin/something-else" \
  "repoint: unrecognized shape is not rewritten"
assert_contains "$(cat "$TMP/shai-nested-path.service")" \
  "ExecStart=$REPOINT_ROOT/v2026.07.01/workflows/a/b/run.sh" \
  "repoint: a workflow segment with a slash is not rewritten"
assert_contains "$(cat "$TMP/shai-heartbeat.service")" \
  "ExecStart=$REPOINT_ROOT/current/workflows/heartbeat/run.sh" \
  "repoint: the recognized-shape unit in the same run is rewritten (positive control)"

# --- repoint: usage errors ---
assert_exit 2 "repoint: neither script nor --all is a usage error" -- "$SUPERVISE" repoint
ERR=$("$SUPERVISE" repoint 2>&1)
assert_contains "$ERR" "specify a script or --all" "repoint: usage error message for neither"
assert_exit 2 "repoint: script and --all together is a usage error" -- "$SUPERVISE" repoint heartbeat --all
ERR=$("$SUPERVISE" repoint heartbeat --all 2>&1)
assert_contains "$ERR" "not both" "repoint: usage error message for both"
assert_exit 2 "repoint: unknown option is a usage error" -- "$SUPERVISE" repoint --jsn

# --- repoint: no provider variables required ---
(
  unset SHAI_API_KEY SHAI_API_URL SHAI_MODEL
  "$SUPERVISE" repoint shai-issue-dispatcher >/dev/null 2>&1
  exit $?
) && RC=0 || RC=$?
assert_eq "$RC" "0" "repoint: runs without SHAI_API_KEY/SHAI_API_URL/SHAI_MODEL"

# --- repoint: refused from a versioned install directory ---
# The rewrite is version-independent only when $DIR is the install's `current`
# symlink; a versioned binary invoked directly (e.g. .../shai/v2026.09.01/
# shai-supervise) would rewrite ExecStart to another versioned path and re-bake
# the bug class repoint removes, so it must refuse instead. Mutation-checked:
# without the guard this command would rewrite shai-versioned-guard to
# $REPOINT_ROOT/shai/v2026.09.01/shai-print, and the ExecStart assertion below
# would go red.
mkdir -p "$REPOINT_ROOT/shai"
ln -s "$DIR" "$REPOINT_ROOT/shai/v2026.09.01"
cat >"$TMP/shai-versioned-guard.service" <<EOF
[Unit]
Description=shai shai-versioned-guard workflow

[Service]
Type=oneshot
ExecStart=$REPOINT_ROOT/v2026.07.01/shai-print
Environment=SHAI_API_KEY=test-key
Environment=SHAI_HOME=$HOME/.shai
EOF
chmod 600 "$TMP/shai-versioned-guard.service"
OUT=$("$REPOINT_ROOT/shai/v2026.09.01/shai-supervise" repoint shai-versioned-guard 2>&1)
RC=$?
assert_eq "$RC" "1" "repoint: invoked from a versioned install dir exits 1"
assert_contains "$OUT" "must run through the current symlink" \
  "repoint: the refusal names the current symlink"
assert_contains "$(cat "$TMP/shai-versioned-guard.service")" \
  "ExecStart=$REPOINT_ROOT/v2026.07.01/shai-print" \
  "repoint: the refused run rewrites nothing (mutation control)"

# --- repoint: a named unit with no unit file warns and exits 0 ---
OUT=$("$SUPERVISE" repoint shai-nosuch 2>&1)
RC=$?
assert_eq "$RC" "0" "repoint: missing unit file exits 0 (nothing to do)"
assert_contains "$OUT" "no unit file or ExecStart line (skipped)" "repoint: missing unit file warns"

finish
