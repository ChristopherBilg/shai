#!/bin/bash
# workflow.sh — shared helpers for shai workflow scripts
# Usage: source "$(dirname "$0")/../lib/workflow.sh"
set -uo pipefail

WF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
DIR="$(cd "$WF_DIR/.." &>/dev/null && pwd)"

WF_NAME="${WF_NAME:-$(basename "$(dirname "${BASH_SOURCE[1]:-workflow}")")}"

mint_id() {
  printf '%s_%s_%s' "$1" "$(date -u +%Y%m%dT%H%M%S)" "$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
}

wf_init() {
  SHAI_SESSION_ID="$(mint_id sess)"
  export SHAI_SESSION_ID
  export SHAI_SCHEMA_VERSION="${SHAI_SCHEMA_VERSION:-1.0}"
  export SHAI_HOME="${SHAI_HOME:-$HOME/.shai}"
  export SHAI_RUN_ID=""
  export SHAI_SPAN_ID=""
  export SHAI_PARENT_SPAN_ID=""

  # Deliberately writes no session files (#388): a pure-bash workflow that never emits an
  # event (an idle dispatcher tick) must leave $SHAI_HOME/sessions/ untouched. The session
  # is materialized lazily by wf_seed_session, at the first event write.
  mkdir -p "$SHAI_HOME/sessions"
}

# wf_seed_session: materialize the session, exactly once per session id (#388). wf_init only
# mints the id and prepares the environment; every caller that is about to write the first
# session event — wf_llm before delegating to shai-loop, and the pure-bash dispatchers before
# dispatching — must call this first, so the system prompt is the session's first event and
# the .latest.json sibling exists. A session log that already has content (an earlier call in
# this process, or a session id shared with another process) is left untouched, so the system
# prompt is never seeded twice.
wf_seed_session() {
  local sessions_dir="$SHAI_HOME/sessions" session_log
  session_log="$sessions_dir/$SHAI_SESSION_ID.jsonl"
  if [ -s "$session_log" ]; then
    return 0
  fi
  "$DIR/shai-prompt" system | "$DIR/shai-read" --system | "$DIR/shai-stamp" >>"$session_log"
  : >"$sessions_dir/$SHAI_SESSION_ID.latest.json"
}

wf_llm() {
  local prompt="${!#}"
  local flags=("${@:1:$#-1}")
  # The first event write happens inside shai-loop; seed first so the system prompt
  # remains the first event in the session log.
  wf_seed_session
  printf '%s' "$prompt" | "$DIR/shai-loop" "${flags[@]+"${flags[@]}"}"
}

wf_output() {
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$WF_NAME" "$*"
}

wf_fail() {
  printf '%s %s ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$WF_NAME" "$*" >&2
  # shellcheck source=lib/failure.sh
  source "$DIR/lib/failure.sh"
  fail_record "workflow_error" "$1" '{"script":"'"$0"'","detail":"'"$1"'"}'
  exit 1
}

# wf_suggest_repo: print the OWNER/REPO that suggestion issues should be filed on.
# Three sources, in order:
#
#   1. SHAI_SUGGEST_REPO — an explicit override always wins.
#   2. $DIR/REPO — baked into the release tarball next to VERSION by release.yml, from
#      the ${{ github.repository }} of the repo that built it. This is the only source a
#      release install can have, and being derived at build time it cannot drift from
#      reality or send a fork's suggestions upstream.
#   3. The `origin` remote of $DIR — dev clones, where no REPO file exists.
#
# Source 3 applies only when $DIR is itself the top of that work tree: release installs
# under ~/.local/share/shai/<version>/ have no .git, and git's parent-directory discovery
# would happily resolve an unrelated ancestor repo (e.g. a dotfiles repo at $HOME), which
# would file issues on the wrong repo. Before source 2 existed that guard left a release
# install with no derivable repo at all, silently skipping suggestions on every run.
#
# The result must look like OWNER/REPO, so a corrupt or truncated REPO file is refused
# rather than falling through to the ancestor-repo guess source 3 would produce. Exit 1
# (printing nothing) when no trustworthy repo can be determined.
wf_suggest_repo() {
  local repo="" top
  if [ -n "${SHAI_SUGGEST_REPO:-}" ]; then
    repo="$SHAI_SUGGEST_REPO"
  elif [ -f "$DIR/REPO" ]; then
    repo=$(cat "$DIR/REPO" 2>/dev/null) || return 1
  else
    top=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null) || return 1
    [ "$top" = "$DIR" ] || return 1
    repo=$(git -C "$DIR" remote get-url origin 2>/dev/null |
      sed 's|.*github\.com[:/]||; s|/*$||; s|\.git$||') || return 1
  fi
  [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  # Never end on a bare `test && return` — workflow scripts run under `set -e`, where a
  # failing AND-list as the last statement would abort the caller instead of falling through.
  if [[ "$repo" == *..* ]]; then
    return 1
  fi
  printf '%s' "$repo"
}

# wf_suggest: post-workflow suggestion step. Runs a second LLM call that reviews the
# session and may create GitHub issues on the shai repo for improvement suggestions.
# Opt out entirely with SHAI_SUGGEST=0.
# Requires an existing SHAI_POLICY_OVERLAY: it never fabricates one, because overlay
# rules supersede base rules (including `deny` — see shai-dispatch), so a synthesized
# "allow gh" overlay would silently override a user who denied gh and would hand tool
# access to workflows that deliberately run without tools.
# Non-fatal: all failures are warnings on **stderr** (stdout belongs to the parent
# workflow — release_notes writes its markdown there), never crashes the parent.
wf_suggest() {
  local shai_repo prompt err_log detail
  if [ "${SHAI_SUGGEST:-1}" = "0" ]; then
    return 0
  fi
  if [ -z "${SHAI_POLICY_OVERLAY:-}" ]; then
    wf_output "WARN: no policy overlay in effect, skipping suggestions" >&2
    return 0
  fi
  shai_repo=$(wf_suggest_repo) || {
    wf_output "WARN: cannot derive shai repo, skipping suggestions" >&2
    return 0
  }
  prompt=$("$DIR/shai-prompt" suggest 2>/dev/null) || {
    wf_output "WARN: cannot load suggest prompt, skipping suggestions" >&2
    return 0
  }
  prompt="${prompt//\{\{SHAI_REPO\}\}/$shai_repo}"
  err_log=$(mktemp)
  if ! wf_llm --tools --quiet "$prompt" >/dev/null 2>"$err_log"; then
    detail=$(tail -n 3 "$err_log" | tr '\n' ' ')
    wf_output "WARN: suggestion step failed (non-fatal)${detail:+: $detail}" >&2
  fi
  rm -f "$err_log"
  return 0
}

# wf_seen KEY: exit 0 if KEY was previously wf_mark'd for this $WF_NAME, exit 1 otherwise.
# -n/inputs streams the JSONL without loading the whole file; any() short-circuits on first
# match. Produces exactly one boolean, sidestepping jq -e's exit code 4 ("no output at
# all") that a bare `select | halt` would otherwise return for a miss.
wf_seen() {
  local ledger="$SHAI_HOME/ledgers/$WF_NAME.jsonl"
  [ -f "$ledger" ] || return 1
  jq -ne --arg k "$1" 'any(inputs; .key == $k)' "$ledger" >/dev/null 2>&1
}

# wf_mark KEY: append a ledger entry for KEY under this $WF_NAME (idempotent — a KEY
# already seen is a no-op, so double-marking never produces a duplicate line).
wf_mark() {
  local ledger_dir="$SHAI_HOME/ledgers"
  local ledger="$ledger_dir/$WF_NAME.jsonl"
  wf_seen "$1" && return 0
  mkdir -p "$ledger_dir"
  jq -nc --arg k "$1" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "$SHAI_SESSION_ID" \
    '{key: $k, ts: $ts, session_id: $sid}' >>"$ledger"
}
