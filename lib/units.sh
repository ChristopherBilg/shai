#!/bin/bash
# units.sh — shared systemd unit inspection and unit-value escaping for shai-supervise and shai-doctor
# Usage: source "$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/lib/units.sh"
set -uo pipefail

# norm <dir>: the physical path of <dir> ("" when it does not exist).
# `cd … && pwd -P` rather than realpath/readlink -f: pure bash and already the project's
# idiom, whereas either alternative would be a new declared dependency.
norm() { (cd "$1" 2>/dev/null && pwd -P); }

# unit_env_value <value>: <value> escaped for embedding inside a double-quoted systemd
# `Environment=` assignment, i.e. what goes between the quotes of `Environment=NAME="…"`.
#
# `Environment=` is space-delimited, so a value containing whitespace must be quoted at all
# (systemd.exec(5)) — an unquoted `my model` sets `my` and discards the rest. Inside double
# quotes systemd then applies C-style escapes, so a literal `"` or `\` in the value must be
# escaped or it silently corrupts the result rather than erroring.
#
# Both failures are silent, and `systemd-analyze verify` reports neither. Verified with
# `systemd-run --user -p 'Environment=SHAI_MODEL=…'`: the unescaped form `"say "hi""` sets
# `say hi` (both quotes eaten), while the escaped form `"say \"hi\""` correctly sets
# `say "hi"`.
#
# Backslash is substituted first on purpose: escaping the quotes introduces backslashes, so
# doing quotes first would come back and double-escape them.
unit_env_value() {
  local v="${1:-}"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '%s' "$v"
}

# unit_exec_start <unit_dir> <unit>: the ExecStart= path in <unit_dir>/<unit>.service
# ("" when the file or the line is absent).
unit_exec_start() {
  local unit_dir="$1" unit="$2" line
  local service="$unit_dir/$unit.service"
  [ -f "$service" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      ExecStart=*)
        printf '%s\n' "${line#ExecStart=}"
        return 0
        ;;
    esac
  done <"$service"
}

# unit_install_state <unit_dir> <install_dir> <unit>: ok | stale | broken | --
# A unit is stale iff the install directory embedded in its ExecStart does not physically
# resolve to <install_dir> (the checker's $DIR). Classification order is significant:
# `--` (no ExecStart line) first, then broken (the ExecStart path is not executable — a
# pruned version directory or a deleted script), then the physical-path comparison, which
# must come after `-x` so a pruned directory (norm "" = norm of nothing) cannot fall
# through to a plain stale.
unit_install_state() {
  local unit_dir="$1" install_dir="$2" unit="$3"
  local exec base
  exec="$(unit_exec_start "$unit_dir" "$unit")"
  case "$exec" in
    */workflows/*/run.sh) base="${exec%/workflows/*/run.sh}" ;;
    *) base="$(dirname "$exec")" ;;
  esac
  if [ -z "$exec" ]; then
    printf '%s' '--'
  elif [ ! -x "$exec" ]; then
    printf '%s' 'broken' # pruned version dir, or deleted script
  elif [ "$(norm "$base")" = "$(norm "$install_dir")" ]; then
    printf '%s' 'ok'
  else
    printf '%s' 'stale'
  fi
}
