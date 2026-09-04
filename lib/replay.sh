#!/bin/bash
# replay.sh — classify whether a run log can be replayed (classify_replay and the verdicts)
# Usage: source "$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)/lib/replay.sh"
set -uo pipefail

# classify_replay <run_id>: run shai-retry's five replay preconditions over the run log at
# runs/<run_id>/events.jsonl and set three caller-scope variables:
#   REPLAY_VERDICT  one of:
#     no-log            run log missing or empty (precondition 1)
#     no-session-id     no meta.session_id anywhere in the log (precondition 2)
#     unsafe-session-id session id contains / or .. (precondition 3)
#     committed         the session log already carries meta.run_id == <run_id> or
#                       meta.retry_of == <run_id> (precondition 4 — a replay commits under
#                       a NEW run id carrying retry_of, so both halves must be checked or
#                       every already-retried run reads as an uncommitted orphan forever)
#     no-user-message   no message/user event with a non-null payload.text (precondition 5)
#     replayable        all five preconditions hold
#   REPLAY_SESSION  the first non-null meta.session_id from the log (set before
#                   precondition 3, so a caller can name the offending id on unsafe)
#   USER_TEXT       the first user message's payload.text (set before precondition 5)
# Preconditions are checked in shai-retry's historical order, so a log failing several of
# them classifies as the FIRST failure — the message a user sees does not change.
# The function prints nothing: the payloads are free-form values (USER_TEXT can be
# multi-line), so a caller that needs them must call the function directly — a
# `$(classify_replay ...)` command substitution forks a subshell and discards the
# variables. Both callers (shai-retry's --run branch, shai-fsck's run-store check) call it
# directly and consume the same values the checks ran against.
# Classification has no side effects — it never creates directories or files (shai-fsck's
# R6 classifies uncommitted runs with the same function and must not mutate state).
# State dir: caller's $STATE_DIR wins (shai-retry sets it), else $SHAI_HOME, else ~/.shai;
# $RUNS_DIR wins over the derived $STATE_DIR/runs.
# shellcheck disable=SC2034  # REPLAY_VERDICT/REPLAY_SESSION/USER_TEXT are the function's
#                            # caller-scope outputs, read by the caller (see header)
classify_replay() {
  local rid="$1"
  local state_dir="${STATE_DIR:-${SHAI_HOME:-$HOME/.shai}}"
  local runs_dir="${RUNS_DIR:-$state_dir/runs}"
  local run_log="$runs_dir/$rid/events.jsonl"

  if [ ! -s "$run_log" ]; then
    REPLAY_VERDICT="no-log"
    return 0
  fi

  # First non-null meta.session_id. `-s` slurps the JSONL into one array first, so the
  # first element selected INSIDE jq ([...][0]) is the first across the whole file and the
  # pipeline emits at most one line — without -s, jq evaluates per input line and a
  # `jq ... | head -n 1` pipeline under pipefail can SIGPIPE-discard a valid match (same
  # determinism rule as lib/policy.sh, #294).
  REPLAY_SESSION=$(jq -r -s '[.[] | select(has("meta")) | .meta.session_id // empty][0] // empty' "$run_log")
  if [ -z "$REPLAY_SESSION" ]; then
    REPLAY_VERDICT="no-session-id"
    return 0
  fi

  if [[ "$REPLAY_SESSION" =~ [/] ]] || [[ "$REPLAY_SESSION" == *..* ]]; then
    REPLAY_VERDICT="unsafe-session-id"
    return 0
  fi

  local session_log="$state_dir/sessions/$REPLAY_SESSION.jsonl"
  if [ -f "$session_log" ] && jq -e --arg rid "$rid" 'select(.meta.run_id? == $rid or .meta.retry_of? == $rid)' "$session_log" >/dev/null 2>&1; then
    REPLAY_VERDICT="committed"
    return 0
  fi

  USER_TEXT=$(jq -r -s '[.[] | select(.type=="message" and .source=="user")] | .[0].payload.text' "$run_log")
  if [ -z "$USER_TEXT" ] || [ "$USER_TEXT" = "null" ]; then
    REPLAY_VERDICT="no-user-message"
    return 0
  fi

  REPLAY_VERDICT="replayable"
}
