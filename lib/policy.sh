#!/bin/bash
# policy.sh — shared permission-gate policy evaluation (check_policy and its helpers)
# Usage: source "$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/lib/policy.sh"
set -uo pipefail

# Self-contained: resolve this file's own install dir and default both directories, so either
# caller works unchanged. The `:-` is load-bearing: shai-dispatch already sets STATE_DIR and
# TOOLS_DIR, and its values must win so its behavior stays byte-identical after the move.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." &>/dev/null && pwd)"
STATE_DIR="${STATE_DIR:-${SHAI_HOME:-$HOME/.shai}}"
TOOLS_DIR="${TOOLS_DIR:-${SHAI_TOOLS_DIR:-$DIR/tools}}"

# read_only_fallback consults the shared exclusion list (see #118). Re-sourcing is safe —
# read-only.sh assigns RO_EXCLUDED_BASENAMES with a plain `=`, never `+=`, so a caller that
# already sourced it is unaffected.
# shellcheck source=lib/read-only.sh
source "$DIR/lib/read-only.sh"

tool_is_read_only() {
  local name="$1"
  local tool_json="$TOOLS_DIR/$name/tool.json"
  [ -f "$tool_json" ] || {
    printf 'false'
    return 0
  }
  jq -r '.capabilities.read_only // false' "$tool_json" 2>/dev/null || printf 'false'
}

# read_only_fallback <tool_name> <tool_input>: the per-tool fallback used when no policy rule
# matches and no `default` is set. A read-only tool is auto-allowed EXCEPT when its input
# targets an excluded path (the shared list in lib/read-only.sh, see #118) — then it degrades
# to `prompt` (interactive confirmation; non-interactive runs fail closed), so credential-
# adjacent paths are never auto-allowed. The exclusion list is a default, not a boundary: a
# matching policy rule (allow/deny) or an explicit `default` is checked before this fallback
# and wins. Only `.path` is consulted — the path-bearing read-only tools all use that field,
# and path-less read-only tools (sleep) have no input path to exclude.
read_only_fallback() {
  local tool_name="$1" tool_input="$2"
  local ro path
  ro=$(tool_is_read_only "$tool_name" 2>/dev/null)
  if [ "$ro" != "true" ]; then
    printf 'prompt'
    return 0
  fi
  path=$(printf '%s' "$tool_input" | jq -r '.path // empty' 2>/dev/null) || path=""
  if ro_path_excluded "$path"; then
    printf 'prompt\treadonly'
  else
    printf 'allow\treadonly'
  fi
}

check_policy() {
  local tool_name="$1" tool_input="$2"
  local policy_file="$STATE_DIR/policy.json"
  local overlay_file="${SHAI_POLICY_OVERLAY:-}"
  local has_base=false has_overlay=false

  [ -f "$policy_file" ] && has_base=true
  [ -n "$overlay_file" ] && [ -f "$overlay_file" ] && has_overlay=true

  # Every return is "<action>\t<reason>": the bare action drives run_tool's case dispatch, the
  # reason lets a denial name the policy that decided it (rule vs default vs no rule vs
  # arg-scope miss) instead of collapsing every cause into one indistinguishable three-word
  # string. Reasons: rule:<file>:<idx> (matched rule, 1-based index), default:<file> (the
  # policy's `.default`), readonly (read-only heuristic), nopolicy (no policy files),
  # unmatched:<overlay>:<base> (no rule matched, no default; `-` where a file is absent), and
  # argscope:<file>:<key>=<pattern>[,...] (an allow rule for the tool exists but its args
  # did not match — the one denial an agent can fix by retrying with different arguments).
  if ! "$has_base" && ! "$has_overlay"; then
    local ar
    ar=$(read_only_fallback "$tool_name" "$tool_input")
    if [ "$ar" = "prompt" ]; then
      printf 'prompt\tnopolicy'
    else
      printf '%s' "$ar"
    fi
    return 0
  fi

  # Match lookup: first-match-wins over the policy's .rules array, in file order. The first
  # element is selected INSIDE jq ([...][0] // empty) so the pipeline emits at most one line.
  # A `jq ... | head -n 1` pipeline under `set -o pipefail` is racy: head closes the pipe
  # after the first line, jq can die with SIGPIPE (141) while still writing further matches,
  # pipefail then reports the pipeline as failed, and the `|| match=""` guard below discards
  # a VALID match — the call falls through to the fallback and identical calls get different
  # verdicts depending on process timing (see #294). One line out, nothing to race.
  local match_filter='
    [ .rules | to_entries[]
      | select(.value.tool == $name)
      | select(
          (.value | has("args") | not) or
          (.value.args | to_entries | all(
            .key as $k | .value as $v |
            ($input[$k] // "" | tostring) | test(
              "^" + ($v | gsub("(?<c>[.+?^${}()|\\[\\]])"; "\\\(.c)";"x") | gsub("\\*"; ".*")) + "$"
            )
          ))
        )
      | "\(.value.action)\t\(.key + 1)"
    ][0] // empty
  '

  # Overlay rules are checked first and intentionally supersede base rules (including deny).
  local match="" matched_file=""

  if "$has_overlay"; then
    match=$(jq -r --arg name "$tool_name" --argjson input "$tool_input" \
      "$match_filter" "$overlay_file" 2>/dev/null) || match=""
    if [ -n "$match" ]; then matched_file="$overlay_file"; fi
  fi

  if [ -z "$match" ] && "$has_base"; then
    match=$(jq -r --arg name "$tool_name" --argjson input "$tool_input" \
      "$match_filter" "$policy_file" 2>/dev/null) || match=""
    if [ -n "$match" ]; then matched_file="$policy_file"; fi
  fi

  if [ -n "$match" ]; then
    printf '%s\trule:%s:%s' "${match%%$'\t'*}" "$matched_file" "${match##*$'\t'}"
    return 0
  fi

  local fallback="" fallback_file=""
  if "$has_overlay"; then
    fallback=$(jq -r '.default // empty' "$overlay_file" 2>/dev/null) || fallback=""
    if [ -n "$fallback" ]; then fallback_file="$overlay_file"; fi
  fi
  if [ -z "$fallback" ] && "$has_base"; then
    fallback=$(jq -r '.default // empty' "$policy_file" 2>/dev/null) || fallback=""
    if [ -n "$fallback" ]; then fallback_file="$policy_file"; fi
  fi
  if [ -n "$fallback" ]; then
    printf '%s\tdefault:%s' "$fallback" "$fallback_file"
    return 0
  fi

  local ar
  ar=$(read_only_fallback "$tool_name" "$tool_input")
  if [ "$ar" != "prompt" ]; then
    printf '%s' "$ar"
    return 0
  fi

  # No rule matched and no default: distinguish "no rule for this tool at all" from "an allow
  # rule exists but its args did not match" (arg-scope miss — the only case an agent can fix by
  # retrying with different arguments). Only allow rules count: retrying to match a deny rule's
  # args would just land on the deny, so a deny rule with args that miss must not be reported
  # as an arg-scope miss. An allow rule can only fail to match when the call's args missed its
  # patterns, so finding one means the args are the reason.
  local scope_rule="" scope_file=""
  # Same determinism constraint as the match lookup above (#294): first element inside jq,
  # never a `| head -n 1` that can SIGPIPE-discard a valid arg-scope rule.
  local scope_filter='
    [ .rules[]?
      | select(.tool == $name and has("args") and .action == "allow")
      | .args | to_entries | map("\(.key)=\(.value)") | join(",")
    ][0] // empty
  '
  if "$has_overlay"; then
    scope_rule=$(jq -r --arg name "$tool_name" "$scope_filter" "$overlay_file" 2>/dev/null) || scope_rule=""
    if [ -n "$scope_rule" ]; then scope_file="$overlay_file"; fi
  fi
  if [ -z "$scope_rule" ] && "$has_base"; then
    scope_rule=$(jq -r --arg name "$tool_name" "$scope_filter" "$policy_file" 2>/dev/null) || scope_rule=""
    if [ -n "$scope_rule" ]; then scope_file="$policy_file"; fi
  fi
  if [ -n "$scope_rule" ]; then
    printf 'prompt\targscope:%s:%s' "$scope_file" "$scope_rule"
  else
    local overlay_disp="-" base_disp="-"
    if "$has_overlay"; then overlay_disp="$overlay_file"; fi
    if "$has_base"; then base_disp="$policy_file"; fi
    printf 'prompt\tunmatched:%s:%s' "$overlay_disp" "$base_disp"
  fi
}
