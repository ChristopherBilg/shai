#!/bin/bash
# test_update.sh — hermetic tests for the in-place updater
# Covers: shai-update — the upgrade sequence (download, extract, current re-point,
#   wrapper rewrite, repoint --all + completions invoked through current), --check
#   verdicts and its write-nothing guarantee, the confirmation prompt and -y/--yes,
#   two consecutive upgrades keeping current a symlink, upgrades deleting nothing,
#   --list, --rollback (previous, named, unknown, refused self-loop/path-escape targets,
#   none available), --prune --keep N (dry-run, current's target exempt, refusing when
#   current is missing or dangling), offline subcommands with no gh, gh missing or
#   unauthenticated exiting 1, layout equivalence with install.sh, and the
#   install_version completion candidates
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "shai-update"

WORK="$(mktemp -d)"
_CLEANUP_DIRS+=("$WORK")

FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME"
INSTALL_DIR="$FAKE_HOME/.local/share/shai"
BIN_DIR="$FAKE_HOME/.local/bin"

make_stub_bin
SYSTEMCTL_LOG="$STUB/systemctl.log"
: >"$SYSTEMCTL_LOG"
{
  printf '#!/bin/bash\n'
  printf 'echo "$*" >> "%s"\n' "$SYSTEMCTL_LOG"
} >"$STUB/systemctl"
chmod +x "$STUB/systemctl"
# A gh that records every invocation and fails: it shadows the real gh for the offline
# runs (PATH order below), so the empty-log assertion at the end proves the offline
# subcommands never touch gh — while the unauthenticated-gh test doubles as the positive
# control that the stub does record calls.
{
  printf '#!/bin/bash\n'
  printf 'echo "$*" >> "%s"\n' "$STUB/gh.log"
  printf 'exit 1\n'
} >"$STUB/gh"
chmod +x "$STUB/gh"
: >"$STUB/gh.log"

# upd: run the checkout's shai-update against the main fixture (the served gh stub and
# the systemctl stub on PATH); upd_offline is the same without the served gh stub — the
# offline modes must work with only the recording gh (which fails every call).
upd() {
  HOME="$FAKE_HOME" SHAI_UNIT_DIR="$WORK/units" PATH="$WORK/bin:$STUB:$PATH" \
    "$DIR/shai-update" "$@"
}
upd_offline() {
  HOME="$FAKE_HOME" SHAI_UNIT_DIR="$WORK/units" PATH="$STUB:$PATH" \
    "$DIR/shai-update" "$@"
}

# --- fixture: three version trees plus current, one stale + one healthy unit ---
build_fake_tarball "$WORK" "v2026.03.01"
make_install_gh_stub "$WORK" "v2026.03.01"
HOME="$FAKE_HOME" SHAI_VERSION="v2026.03.01" PATH="$WORK/bin:$STUB:$PATH" \
  bash "$DIR/install.sh" >/dev/null 2>&1
build_fake_tarball "$WORK" "v2026.01.01"
mkdir -p "$INSTALL_DIR/v2026.01.01"
tar xzf "$WORK/shai-v2026.01.01.tar.gz" -C "$INSTALL_DIR/v2026.01.01" --strip-components=1
build_fake_tarball "$WORK" "v2026.02.01"
mkdir -p "$INSTALL_DIR/v2026.02.01"
tar xzf "$WORK/shai-v2026.02.01.tar.gz" -C "$INSTALL_DIR/v2026.02.01" --strip-components=1

mkdir -p "$WORK/units"
cat >"$WORK/units/shai-heartbeat.service" <<EOF
[Unit]
Description=shai shai-heartbeat workflow

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/v2026.01.01/shai-repl
Environment=DEEPSEEK_API_KEY=test-key
Environment=SHAI_HOME=$FAKE_HOME/.shai
EOF
chmod 600 "$WORK/units/shai-heartbeat.service"
cat >"$WORK/units/shai-healthy.service" <<EOF
[Unit]
Description=shai shai-healthy workflow

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/current/shai-repl
Environment=DEEPSEEK_API_KEY=test-key
Environment=SHAI_HOME=$FAKE_HOME/.shai
EOF
chmod 600 "$WORK/units/shai-healthy.service"

assert_eq "$(readlink "$INSTALL_DIR/current")" "v2026.03.01" \
  "fixture: seeded current points at v2026.03.01"

# --- upgrade: bare + -y skips the prompt and switches to v2026.04.01 ---
build_fake_tarball "$WORK" "v2026.04.01"
make_install_gh_stub "$WORK" "v2026.04.01"
OUT=$(upd -y 2>&1)
RC=$?
assert_eq "$RC" "0" "upgrade: exits 0"
assert_eq "$(readlink "$INSTALL_DIR/current")" "v2026.04.01" \
  "upgrade: current re-points to the new version"
assert_eq "$([ -x "$INSTALL_DIR/v2026.04.01/shai-repl" ] && echo y)" "y" \
  "upgrade: the new version tree is extracted and executable"
if [[ "$OUT" == *"[y/N]"* ]]; then
  echo -e "  ${RED}✗${NC} upgrade: -y skips the confirmation prompt (prompt still printed)"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} upgrade: -y skips the confirmation prompt"
fi
assert_contains "$OUT" "shai v2026.04.01 installed successfully" \
  "upgrade: summary names the installed version"
assert_contains "$OUT" "Current:  $INSTALL_DIR/current -> v2026.04.01" \
  "upgrade: summary names what current points at"
assert_contains "$OUT" "Previous: v2026.03.01 retained" \
  "upgrade: summary names the retained previous version"

# Steps 6-7 must run through current, never a versioned path. The functional proof:
# cmd_repoint refuses versioned invocations outright, so the units being rewritten
# *and* the upgrade exiting 0 together mean the invocation went through current.
assert_contains "$(grep '^ExecStart=' "$WORK/units/shai-heartbeat.service")" \
  "ExecStart=$INSTALL_DIR/current/shai-repl" \
  "upgrade: the stale unit's ExecStart was rewritten through /current/"
assert_contains "$(grep '^ExecStart=' "$WORK/units/shai-healthy.service")" \
  "ExecStart=$INSTALL_DIR/current/shai-repl" \
  "upgrade: the healthy unit's ExecStart stays on /current/"
if grep -h '^ExecStart=' "$WORK/units"/shai-*.service | grep -q 'v2026\.'; then
  echo -e "  ${RED}✗${NC} upgrade: no unit ExecStart bakes in a version string"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} upgrade: no unit ExecStart bakes in a version string"
fi
assert_contains "$OUT" "v2026.01.01 -> current" \
  "upgrade: repoint reports the stale unit's old version"
assert_contains "$OUT" "already current (skipped)" \
  "upgrade: repoint skips the already-current unit in the same run"
assert_contains "$OUT" "daemon-reloaded; 1 unit repointed" \
  "upgrade: exactly one unit repointed and daemon-reloaded"
assert_contains "$(cat "$SYSTEMCTL_LOG")" "daemon-reload" \
  "upgrade: the repoint delegated to systemctl"
assert_contains "$(cat "$BIN_DIR/shai-repl")" \
  "exec '$INSTALL_DIR/current/shai-repl'" \
  "upgrade: wrappers rewritten through current"
assert_contains "$OUT" "Installed zsh completions to" \
  "upgrade: zsh completions reinstalled (step 7)"
assert_contains "$OUT" "Installed bash completions to" \
  "upgrade: bash completions reinstalled (step 7)"
assert_contains "$(cat "$FAKE_HOME/.local/share/zsh/site-functions/_shai")" \
  "fixture release v2026.04.01" \
  "upgrade: completions reinstalled from the new version's tree"

# Nothing is ever deleted (mutation-checked: an `rm -rf` of an old version dir in
# cmd_upgrade makes this assertion go red while every other assertion stays green).
for v in v2026.01.01 v2026.02.01 v2026.03.01 v2026.04.01; do
  assert_eq "$([ -d "$INSTALL_DIR/$v" ] && echo y)" "y" \
    "upgrade: $v survives (no version directory deleted)"
done

# --- second consecutive upgrade: current must stay a symlink (the mv -T regression) ---
build_fake_tarball "$WORK" "v2026.05.01"
make_install_gh_stub "$WORK" "v2026.05.01"
: >"$SYSTEMCTL_LOG"
OUT=$(upd --yes 2>&1)
RC=$?
assert_eq "$RC" "0" "second upgrade: exits 0"
assert_eq "$([ -L "$INSTALL_DIR/current" ] && echo y || echo n)" "y" \
  "second upgrade: current is still a symlink after two consecutive upgrades"
assert_eq "$(readlink "$INSTALL_DIR/current")" "v2026.05.01" \
  "second upgrade: current re-points to the newest version"
assert_eq "$([ -d "$INSTALL_DIR/v2026.04.01" ] && echo y)" "y" \
  "second upgrade: the previous version tree survives"
assert_eq "$(grep -c 'daemon-reload' "$SYSTEMCTL_LOG" || true)" "0" \
  "second upgrade: no daemon-reload when every unit is already current"
assert_contains "$OUT" "already current (skipped)" \
  "second upgrade: repoint --all still runs through current and skips healthy units"

# --- --check: exits 0 either way, writes nothing ---
before_list="$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)"
before_link="$(readlink "$INSTALL_DIR/current")"
OUT=$(upd --check 2>/dev/null)
RC=$?
assert_eq "$RC" "0" "--check: exits 0 when up to date"
assert_eq "$OUT" "up to date (v2026.05.01)" \
  "--check: prints the exact up-to-date line"

build_fake_tarball "$WORK" "v2026.06.01"
make_install_gh_stub "$WORK" "v2026.06.01"
OUT=$(upd --check 2>/dev/null)
RC=$?
assert_eq "$RC" "0" "--check: exits 0 when an update exists"
assert_eq "$OUT" "update available: v2026.05.01 -> v2026.06.01" \
  "--check: prints the exact update-available line"
ERR=$(upd --check 2>&1 >/dev/null)
assert_eq "$ERR" "" "--check: writes nothing to stderr"
after_list="$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)"
after_link="$(readlink "$INSTALL_DIR/current")"
assert_eq "$after_list" "$before_list" \
  "--check: creates no new directories (mutation-checked: a --check that downloads fails this)"
assert_eq "$after_link" "$before_link" \
  "--check: current is untouched"
assert_eq "$([ -d "$INSTALL_DIR/v2026.06.01" ] && echo y || echo n)" "n" \
  "--check: never installs the available version"

# --check on a machine with no install at all: still exit 0, still write nothing.
mkdir -p "$WORK/checkhome"
OUT=$(HOME="$WORK/checkhome" PATH="$WORK/bin:$STUB:$PATH" "$DIR/shai-update" --check 2>/dev/null)
assert_eq "$OUT" "update available: none -> v2026.06.01" \
  "--check: reports none -> v… with no install on disk"
assert_eq "$([ -e "$WORK/checkhome/.local" ] && echo y || echo n)" "n" \
  "--check: creates nothing under a fresh HOME"

# --- usage errors exit 2 ---
assert_exit 2 "unknown flag is a usage error" -- "$DIR/shai-update" --bogus
assert_exit 2 "conflicting modes are a usage error" -- "$DIR/shai-update" --check --list
assert_exit 2 "--prune without --keep is a usage error" -- "$DIR/shai-update" --prune
assert_exit 2 "--keep without --prune is a usage error" -- "$DIR/shai-update" --keep 2
assert_exit 2 "--dry-run without --prune is a usage error" -- "$DIR/shai-update" --dry-run
assert_exit 2 "--version without a value is a usage error" -- "$DIR/shai-update" --version
assert_exit 2 "--version combined with --check is a usage error" -- "$DIR/shai-update" --version v1 --check
assert_exit 2 "--version followed by a flag is a usage error" -- "$DIR/shai-update" --version --check
assert_exit 2 "non-numeric --keep is a usage error" -- "$DIR/shai-update" --prune --keep abc

# --- the prompt: bare invocation prompts, EOF aborts, a piped y proceeds ---
OUT=$(upd </dev/null 2>&1)
RC=$?
assert_eq "$RC" "0" "prompt abort: exits 0 (a declined upgrade is not an error)"
assert_contains "$OUT" "Upgrade shai v2026.05.01 -> v2026.06.01? [y/N]" \
  "prompt: a bare upgrade prompts before switching"
assert_contains "$OUT" "aborted" "prompt: an EOF answer aborts"
assert_eq "$(readlink "$INSTALL_DIR/current")" "v2026.05.01" \
  "prompt abort: current unchanged"
assert_eq "$([ -d "$INSTALL_DIR/v2026.06.01" ] && echo y || echo n)" "n" \
  "prompt abort: nothing downloaded or installed"

OUT=$(printf 'y\n' | upd 2>&1)
RC=$?
assert_eq "$RC" "0" "prompt accept: exits 0"
assert_eq "$(readlink "$INSTALL_DIR/current")" "v2026.06.01" \
  "prompt accept: a piped y switches to the new version"
assert_contains "$OUT" "shai v2026.06.01 installed successfully" \
  "prompt accept: summary printed"

# --- no-op when the target version is already current ---
OUT=$(upd --version v2026.06.01 --yes 2>&1)
assert_eq "$OUT" "already up to date (v2026.06.01)" \
  "no-op: --version of the current version reports already up to date"

# --- --list: offline, marks current ---
expected=$(printf 'v2026.01.01\nv2026.02.01\nv2026.03.01\nv2026.04.01\nv2026.05.01\nv2026.06.01 (current)\n')
assert_eq "$(upd_offline --list)" "$expected" \
  "--list: versions on disk, oldest first, current marked"

mkdir -p "$WORK/emptyhome"
assert_eq "$(HOME="$WORK/emptyhome" PATH="$STUB:$PATH" "$DIR/shai-update" --list)" "" \
  "--list: an empty install dir lists nothing"

# --- --rollback: previous version, offline, with repoint + completions from the target ---
cat >"$WORK/units/shai-heartbeat.service" <<EOF
[Unit]
Description=shai shai-heartbeat workflow

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/v2026.01.01/shai-repl
Environment=DEEPSEEK_API_KEY=test-key
Environment=SHAI_HOME=$FAKE_HOME/.shai
EOF
chmod 600 "$WORK/units/shai-heartbeat.service"
rm -f "$FAKE_HOME/.local/share/zsh/site-functions/_shai"
: >"$SYSTEMCTL_LOG"
OUT=$(upd_offline --rollback 2>&1)
RC=$?
assert_eq "$RC" "0" "--rollback: exits 0"
assert_eq "$(readlink "$INSTALL_DIR/current")" "v2026.05.01" \
  "--rollback: re-points current to the previous version"
assert_contains "$(grep '^ExecStart=' "$WORK/units/shai-heartbeat.service")" \
  "ExecStart=$INSTALL_DIR/current/shai-repl" \
  "--rollback: runs repoint --all through current (stale unit rewritten)"
assert_contains "$(cat "$SYSTEMCTL_LOG")" "daemon-reload" \
  "--rollback: the repoint delegated to systemctl"
assert_eq "$([ -f "$FAKE_HOME/.local/share/zsh/site-functions/_shai" ] && echo y)" "y" \
  "--rollback: reinstalls the zsh completions"
assert_contains "$(cat "$FAKE_HOME/.local/share/zsh/site-functions/_shai")" \
  "fixture release v2026.05.01" \
  "--rollback: completions reinstalled from the target version's tree"
assert_contains "$OUT" "rolling back to v2026.05.01" \
  "--rollback: names the version it switches to"
assert_contains "$OUT" "rolled back to v2026.05.01" \
  "--rollback: prints the summary line"

# --- --rollback VERSION: a named version on disk, offline ---
OUT=$(upd_offline --rollback v2026.02.01 2>&1)
RC=$?
assert_eq "$RC" "0" "--rollback v…: exits 0"
assert_eq "$(readlink "$INSTALL_DIR/current")" "v2026.02.01" \
  "--rollback v…: re-points current to the named version"

# --- --rollback of a version not on disk is a failure ---
ERR=$(upd_offline --rollback v2099.01.01 2>&1)
RC=$?
assert_eq "$RC" "1" "--rollback v2099.01.01: exits 1"
assert_contains "$ERR" "error: version v2099.01.01 is not installed" \
  "--rollback v2099.01.01: names the missing version"
assert_eq "$(readlink "$INSTALL_DIR/current")" "v2026.02.01" \
  "--rollback v2099.01.01: current untouched"

# --- --rollback of the current symlink entry itself is refused (no self-loop) ---
# The guard is version_dirs membership, not [ -d ]: a bare [ -d ] follows symlinks, so
# `--rollback current` would re-point current to itself (mutation-checked: restoring the
# old [ -d ] check makes this assertion red with a self-looped current).
ERR=$(upd_offline --rollback current 2>&1)
RC=$?
assert_eq "$RC" "1" "--rollback current: exits 1"
assert_contains "$ERR" "error: version current is not installed" \
  "--rollback current: refused by version_dirs membership"
assert_eq "$(readlink "$INSTALL_DIR/current")" "v2026.02.01" \
  "--rollback current: current untouched (no self-loop)"

# --- --rollback of a path escape is refused before any re-pointing ---
ERR=$(upd_offline --rollback .. 2>&1)
RC=$?
assert_eq "$RC" "1" "--rollback ..: exits 1"
assert_contains "$ERR" "must not contain" "--rollback ..: rejected by validate_version"
ERR=$(upd_offline --rollback . 2>&1)
RC=$?
assert_eq "$RC" "1" "--rollback .: exits 1"
assert_contains "$ERR" "error: version . is not installed" \
  "--rollback .: refused by version_dirs membership"
assert_eq "$(readlink "$INSTALL_DIR/current")" "v2026.02.01" \
  "--rollback . / ..: current untouched"

# --- --rollback with no previous version ---
RB_HOME="$WORK/rbhome"
mkdir -p "$RB_HOME/.local/share/shai/v2026.01.01"
echo "v2026.01.01" >"$RB_HOME/.local/share/shai/v2026.01.01/VERSION"
ln -s v2026.01.01 "$RB_HOME/.local/share/shai/current"
ERR=$(HOME="$RB_HOME" PATH="$STUB:$PATH" "$DIR/shai-update" --rollback 2>&1)
RC=$?
assert_eq "$RC" "1" "--rollback: exits 1 when no previous version exists"
assert_contains "$ERR" "no previous version to roll back to" \
  "--rollback: names the reason"

# --- --prune --keep N: dry-run removes nothing ---
before_list="$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)"
OUT=$(upd_offline --prune --keep 2 --dry-run 2>&1)
after_list="$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort)"
assert_eq "$after_list" "$before_list" "--prune --dry-run: removes nothing"
assert_contains "$OUT" "would remove $INSTALL_DIR/v2026.01.01" \
  "--prune --dry-run: lists the oldest excess version"
assert_contains "$OUT" "3 version(s) would be removed (dry run)" \
  "--prune --dry-run: prints the dry-run count"

# --- --prune --keep 2: removes the oldest excess versions, never current's target ---
OUT=$(upd_offline --prune --keep 2 2>&1)
RC=$?
assert_eq "$RC" "0" "--prune: exits 0"
assert_eq "$([ -d "$INSTALL_DIR/v2026.01.01" ] && echo y || echo n)" "n" \
  "--prune: removes the oldest version (positive control)"
assert_eq "$([ -d "$INSTALL_DIR/v2026.03.01" ] && echo y || echo n)" "n" \
  "--prune: removes v2026.03.01"
assert_eq "$([ -d "$INSTALL_DIR/v2026.04.01" ] && echo y || echo n)" "n" \
  "--prune: removes v2026.04.01"
assert_eq "$([ -d "$INSTALL_DIR/v2026.02.01" ] && echo y)" "y" \
  "--prune: current's target survives (mutation-checked: deleting it makes this red)"
assert_eq "$([ -d "$INSTALL_DIR/v2026.05.01" ] && echo y)" "y" \
  "--prune: the newest version survives"
assert_eq "$([ -d "$INSTALL_DIR/v2026.06.01" ] && echo y)" "y" \
  "--prune: the second-newest version survives"
assert_contains "$OUT" "removing $INSTALL_DIR/v2026.01.01" \
  "--prune: reports each removal"
assert_contains "$OUT" "removed 3 version(s)" \
  "--prune: prints the removal count"

OUT=$(upd_offline --prune --keep 2 2>&1)
assert_contains "$OUT" "nothing to prune" "--prune: nothing left to prune"

# --- current's target is exempt even when it is the oldest version on disk ---
PR_HOME="$WORK/prhome"
PR_INSTALL="$PR_HOME/.local/share/shai"
mkdir -p "$PR_INSTALL/v2026.01.01" "$PR_INSTALL/v2026.02.01" "$PR_INSTALL/v2026.03.01"
ln -s v2026.01.01 "$PR_INSTALL/current"
OUT=$(HOME="$PR_HOME" PATH="$STUB:$PATH" "$DIR/shai-update" --prune --keep 1 2>&1)
assert_eq "$([ -d "$PR_INSTALL/v2026.01.01" ] && echo y)" "y" \
  "--prune: current's target survives even when it is the oldest (mutation-checked)"
assert_eq "$([ -d "$PR_INSTALL/v2026.02.01" ] && echo y || echo n)" "n" \
  "--prune: an older non-current version in the same run IS removed (positive control)"
assert_eq "$([ -d "$PR_INSTALL/v2026.03.01" ] && echo y)" "y" \
  "--prune: the newest version is kept"
assert_contains "$OUT" "removed 1 version(s)" "--prune: count matches the positive control"

# --- --prune --dry-run on the same shape removes nothing ---
PR2_HOME="$WORK/pr2home"
PR2_INSTALL="$PR2_HOME/.local/share/shai"
mkdir -p "$PR2_INSTALL/v2026.01.01" "$PR2_INSTALL/v2026.02.01" "$PR2_INSTALL/v2026.03.01"
ln -s v2026.01.01 "$PR2_INSTALL/current"
OUT=$(HOME="$PR2_HOME" PATH="$STUB:$PATH" "$DIR/shai-update" --prune --keep 1 --dry-run 2>&1)
assert_eq "$([ -d "$PR2_INSTALL/v2026.01.01" ] && echo y)" "y" \
  "--prune --dry-run: current's target untouched"
assert_eq "$([ -d "$PR2_INSTALL/v2026.02.01" ] && echo y)" "y" \
  "--prune --dry-run: the would-be removal is not performed (mutation-checked)"
assert_eq "$([ -d "$PR2_INSTALL/v2026.03.01" ] && echo y)" "y" \
  "--prune --dry-run: the newest version untouched"
assert_contains "$OUT" "would remove $PR2_INSTALL/v2026.02.01" \
  "--prune --dry-run: names what it would remove"
assert_contains "$OUT" "1 version(s) would be removed (dry run)" \
  "--prune --dry-run: prints the dry-run count"

# --- --prune refuses when there is no current symlink (a pre-cycle-2 install) ---
# Without current, no version is provably the one the wrappers exec, so nothing may be
# exempted (mutation-checked: removing the guard makes the oldest-version assertion red
# because the run deletes it).
NP_HOME="$WORK/nphome"
NP_INSTALL="$NP_HOME/.local/share/shai"
mkdir -p "$NP_INSTALL/v2026.01.01" "$NP_INSTALL/v2026.02.01"
ERR=$(HOME="$NP_HOME" PATH="$STUB:$PATH" "$DIR/shai-update" --prune --keep 1 2>&1)
RC=$?
assert_eq "$RC" "1" "--prune: exits 1 with no current symlink"
assert_contains "$ERR" "refusing to prune" "--prune: names the missing current symlink"
assert_eq "$([ -d "$NP_INSTALL/v2026.01.01" ] && echo y)" "y" \
  "--prune: the oldest version survives"
assert_eq "$([ -d "$NP_INSTALL/v2026.02.01" ] && echo y)" "y" \
  "--prune: nothing was removed"

# --- ... and when current is dangling ---
ln -s v2026.03.01 "$NP_INSTALL/current"
ERR=$(HOME="$NP_HOME" PATH="$STUB:$PATH" "$DIR/shai-update" --prune --keep 1 2>&1)
RC=$?
assert_eq "$RC" "1" "--prune: exits 1 with a dangling current symlink"
assert_contains "$ERR" "refusing to prune" "--prune: names the dangling current symlink"
assert_eq "$([ -d "$NP_INSTALL/v2026.01.01" ] && echo y)" "y" \
  "--prune: nothing removed with a dangling current"

# Every offline section above ran with the recording gh stub shadowing the real gh, so
# an empty log means --list/--rollback/--prune never reached for gh (mutation-checked:
# the unauthenticated test below fills this log, proving the stub records calls).
assert_eq "$(cat "$STUB/gh.log")" "" "offline modes: never invoked gh"

# --- gh missing or unauthenticated exits 1, not 2 ---
mkdir -p "$WORK/nopath"
ERR=$(HOME="$FAKE_HOME" PATH="$WORK/nopath" "$DIR/shai-update" --check 2>&1)
RC=$?
assert_eq "$RC" "1" "gh missing: --check exits 1 (not 2)"
assert_contains "$ERR" "error: gh CLI is required" "gh missing: names the missing prerequisite"
assert_exit 1 "gh missing: the bare upgrade also exits 1" -- \
  env HOME="$FAKE_HOME" PATH="$WORK/nopath" "$DIR/shai-update" --yes

ERR=$(HOME="$FAKE_HOME" PATH="$STUB:$PATH" "$DIR/shai-update" --check 2>&1)
RC=$?
assert_eq "$RC" "1" "gh unauthenticated: --check exits 1 (not 2)"
assert_contains "$ERR" "error: gh CLI is not authenticated" \
  "gh unauthenticated: names the auth problem"
# Positive control for the offline-gh-log assertion below: the recording stub does
# capture calls, so an offline mode that reached for gh would show up in the log.
assert_contains "$(cat "$STUB/gh.log")" "auth status" \
  "gh recording stub: the unauthenticated run above was recorded"
: >"$STUB/gh.log"

# --- a --version with / or .. is rejected before any download ---
ERR=$(upd --version "../../etc" --yes 2>&1)
RC=$?
assert_eq "$RC" "1" "--version ../../etc: exits 1"
assert_contains "$ERR" "must not contain" "--version ../../etc: names the guard"

# --- layout equivalence: install.sh and shai-update produce the same install ---
EQ1="$WORK/eq1"
mkdir -p "$EQ1"
build_fake_tarball "$WORK" "v2026.07.01"
make_install_gh_stub "$WORK" "v2026.07.01"
HOME="$EQ1" SHAI_VERSION="v2026.07.01" PATH="$WORK/bin:$STUB:$PATH" \
  bash "$DIR/install.sh" >/dev/null 2>&1
EQ2="$WORK/eq2"
mkdir -p "$EQ2"
HOME="$EQ2" PATH="$WORK/bin:$STUB:$PATH" \
  "$DIR/shai-update" --version v2026.07.01 --yes >/dev/null 2>&1

assert_eq "$(readlink "$EQ1/.local/share/shai/current")" \
  "$(readlink "$EQ2/.local/share/shai/current")" \
  "layout: both installers write the same relative current target"
assert_eq "$(sed "s|$EQ1|HOME|g" "$EQ1/.local/bin/shai-repl")" \
  "$(sed "s|$EQ2|HOME|g" "$EQ2/.local/bin/shai-repl")" \
  "layout: wrapper exec lines are identical modulo the home path"
assert_eq "$(cd "$EQ1" && find .local -mindepth 1 -printf '%P\n' | LC_ALL=C sort)" \
  "$(cd "$EQ2" && find .local -mindepth 1 -printf '%P\n' | LC_ALL=C sort)" \
  "layout: identical file tree under .local"
assert_eq "$(cat "$EQ1/.local/share/zsh/site-functions/_shai")" \
  "$(cat "$EQ2/.local/share/zsh/site-functions/_shai")" \
  "layout: identical generated zsh completions"

# --- install_version completion candidates resolve from the install directory ---
# The wrapper's exec line resolves _shai_dir to $INSTALL_DIR/current, so the
# candidates are the version directories on disk; the [ -L …/current ] guard inside
# the command is what keeps a dev checkout from enumerating its parent directory
# (negative control below). Versions left after the prune: v02 (current), v05, v06.
candidates="$(PATH="$BIN_DIR:$PATH" bash -c '
  source "$1/completions/shai.bash"
  COMP_WORDS=(shai-update --rollback "")
  COMP_CWORD=2
  _shai_bash_install_version
  printf "%s\n" "${COMPREPLY[*]}"
' _ "$DIR")"
assert_contains "$candidates" "v2026.02.01" "install_version: offers the current version"
assert_contains "$candidates" "v2026.05.01" "install_version: offers an older version"
assert_contains "$candidates" "v2026.06.01" "install_version: offers the newest version"
if [[ " $candidates " == *" current "* ]]; then
  echo -e "  ${RED}✗${NC} install_version: never offers the current symlink entry itself"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} install_version: never offers the current symlink entry itself"
fi
nocandidates="$(PATH="$DIR:$PATH" bash -c '
  source "$1/completions/shai.bash"
  COMP_WORDS=(shai-update --rollback "")
  COMP_CWORD=2
  _shai_bash_install_version
  printf "%s\n" "${COMPREPLY[*]}"
' _ "$DIR")"
assert_eq "$nocandidates" "" \
  "install_version: no candidates from a dev checkout (the /current guard)"

finish
