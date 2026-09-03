#!/bin/bash
# test_units.sh — unit tests for lib/units.sh
# Covers: lib/units.sh — norm, unit_exec_start, unit_install_state (the staleness table)
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=lib/units.sh
source "$DIR/lib/units.sh"

echo "units"

# Fixture layout — the five rows of the staleness table plus the degenerate shapes:
#   current -> v2026.09.01  (the eventual `current` symlink, simulated with ln -s)
#   v2026.08.10/…           (an old release install, still present)
#   v2026.09.01/…           (the new release install, the target of `current`)
#   devclone/…              (a dev clone, both ExecStart shapes cmd_install writes)
#   v2026.07.22/…           (never created — the pruned version directory)
FIX="$(mktemp -d)"
_CLEANUP_DIRS+=("$FIX")
mkdir -p "$FIX/units" \
  "$FIX/v2026.08.10/workflows/heartbeat" \
  "$FIX/v2026.09.01/workflows/heartbeat" \
  "$FIX/devclone/workflows/heartbeat"
ln -s v2026.09.01 "$FIX/current"
for p in v2026.08.10 v2026.09.01 devclone; do
  printf '#!/bin/bash\nexit 0\n' >"$FIX/$p/workflows/heartbeat/run.sh"
  chmod +x "$FIX/$p/workflows/heartbeat/run.sh"
done
printf '#!/bin/bash\nexit 0\n' >"$FIX/devclone/shai-print"
chmod +x "$FIX/devclone/shai-print"

# unit_file <unit> <execstart>: write a minimal cmd_install-shaped service file.
# The Environment= values are quoted because that is what cmd_install actually emits (it
# routes every value through unit_env_value); an unquoted fixture here would make this
# helper's "cmd_install-shaped" claim false. legacy_unit_file below covers the other shape.
unit_file() {
  cat >"$FIX/units/$1.service" <<EOF
[Unit]
Description=shai $1 workflow

[Service]
Type=oneshot
ExecStart=$2
Environment=SHAI_API_KEY="x"
Environment=SHAI_HOME="$HOME/.shai"
EOF
}

# legacy_unit_file <unit> <execstart>: the same unit with UNQUOTED Environment= values, the
# shape cmd_install emitted before values were escaped. A user upgrading across that change
# still has units of this shape on disk, so the inspection helpers must classify them
# identically — they parse ExecStart= only, and this is what pins that.
legacy_unit_file() {
  cat >"$FIX/units/$1.service" <<EOF
[Unit]
Description=shai $1 workflow

[Service]
Type=oneshot
ExecStart=$2
Environment=SHAI_API_KEY=x
Environment=SHAI_HOME=$HOME/.shai
EOF
}

# --- row 1: post-migration release install → ok ---
unit_file shai-migrated "$FIX/current/workflows/heartbeat/run.sh"
STATE=$(unit_install_state "$FIX/units" "$FIX/current" shai-migrated)
assert_eq "$STATE" "ok" "staleness: unit and checker both on current → ok"

# --- row 2: pre-migration unit → stale ---
unit_file shai-old "$FIX/v2026.08.10/workflows/heartbeat/run.sh"
STATE=$(unit_install_state "$FIX/units" "$FIX/current" shai-old)
assert_eq "$STATE" "stale" "staleness: pre-migration unit → stale"

# --- row 3: dev clone → ok (no false positive) ---
unit_file shai-dev "$FIX/devclone/workflows/heartbeat/run.sh"
STATE=$(unit_install_state "$FIX/units" "$FIX/devclone" shai-dev)
assert_eq "$STATE" "ok" "staleness: dev clone unit + dev clone checker → ok"

# --- row 4: checker invoked via the versioned path → ok ---
# The unit embeds .../current while the checker runs from .../v2026.09.01; the physical
# comparison must resolve them to the same directory. A naive string compare would call
# this stale (mutation-checked: replacing norm with a plain string compare turns this red).
unit_file shai-vcheck "$FIX/current/workflows/heartbeat/run.sh"
STATE=$(unit_install_state "$FIX/units" "$FIX/v2026.09.01" shai-vcheck)
assert_eq "$STATE" "ok" "staleness: unit on current, checker on the version dir → ok (physical resolution)"

# --- row 5: old version directory pruned → broken ---
# `-x` must precede the physical comparison: norm of the dead base is "", which would
# otherwise fall through to stale (mutation-checked: deleting the -x branch turns this
# assertion red). The adjacent stale fixture above is the positive control for the shape.
unit_file shai-pruned "$FIX/v2026.07.22/workflows/heartbeat/run.sh"
STATE=$(unit_install_state "$FIX/units" "$FIX/current" shai-pruned)
assert_eq "$STATE" "broken" "staleness: pruned version dir → broken (not stale)"

# --- deleted script (base exists, script does not) → broken ---
unit_file shai-script-gone "$FIX/devclone/workflows/removed/run.sh"
STATE=$(unit_install_state "$FIX/units" "$FIX/devclone" shai-script-gone)
assert_eq "$STATE" "broken" "staleness: deleted script → broken"

# --- direct script path (cmd_install's other ExecStart shape) ---
unit_file shai-direct "$FIX/devclone/shai-print"
STATE=$(unit_install_state "$FIX/units" "$FIX/devclone" shai-direct)
assert_eq "$STATE" "ok" "staleness: direct script ExecStart shape → ok"

# --- Environment= quoting is irrelevant to classification (both shapes agree) ---
# Paired positive/negative on the same ExecStart: the quoted shape is what cmd_install writes
# now, the unquoted shape is what it wrote before values were escaped, and a user upgrading
# across that change has the latter on disk. Both must classify the same, because these
# helpers read ExecStart= and nothing else. Not vacuous: the same pair on a stale ExecStart
# below yields stale for both, so a reader that keyed on Environment= at all would split them.
unit_file shai-quoted-env "$FIX/current/workflows/heartbeat/run.sh"
QUOTED_STATE=$(unit_install_state "$FIX/units" "$FIX/current" shai-quoted-env)
legacy_unit_file shai-legacy-env "$FIX/current/workflows/heartbeat/run.sh"
LEGACY_STATE=$(unit_install_state "$FIX/units" "$FIX/current" shai-legacy-env)
assert_eq "$QUOTED_STATE" "ok" "staleness: quoted Environment= values (current install shape) → ok"
assert_eq "$LEGACY_STATE" "$QUOTED_STATE" \
  "staleness: unquoted legacy Environment= values classify identically to quoted"

unit_file shai-quoted-stale "$FIX/v2026.08.10/workflows/heartbeat/run.sh"
legacy_unit_file shai-legacy-stale "$FIX/v2026.08.10/workflows/heartbeat/run.sh"
assert_eq "$(unit_install_state "$FIX/units" "$FIX/current" shai-quoted-stale)" "stale" \
  "staleness: quoted values on a stale ExecStart → stale (the pair's negative control)"
assert_eq "$(unit_install_state "$FIX/units" "$FIX/current" shai-legacy-stale)" "stale" \
  "staleness: unquoted values on a stale ExecStart → stale"

# --- no ExecStart line → --, and absent service file → -- ---
# Absence-shaped: paired with the positive controls above — the same-shaped fixtures that
# do carry an ExecStart yield ok/stale/broken, so a reader that always returned "" would
# go red on them while this stays green.
printf '[Unit]\nDescription=x\n\n[Service]\nType=oneshot\n' >"$FIX/units/shai-noexec.service"
STATE=$(unit_install_state "$FIX/units" "$FIX/current" shai-noexec)
assert_eq "$STATE" "--" "staleness: no ExecStart line → --"
STATE=$(unit_install_state "$FIX/units" "$FIX/current" shai-absent)
assert_eq "$STATE" "--" "staleness: no service file → --"

# --- unit_exec_start: the raw ExecStart value ---
EXEC=$(unit_exec_start "$FIX/units" shai-migrated)
assert_eq "$EXEC" "$FIX/current/workflows/heartbeat/run.sh" "unit_exec_start: reads the ExecStart path"
EXEC=$(unit_exec_start "$FIX/units" shai-absent)
assert_eq "$EXEC" "" "unit_exec_start: empty when the service file is absent"

# --- norm: physical resolution of a symlink ---
assert_eq "$(norm "$FIX/current")" "$(norm "$FIX/v2026.09.01")" "norm: symlink resolves physically to its target"
assert_eq "$(norm "$FIX/v2026.07.22")" "" "norm: empty when the directory does not exist"

finish
