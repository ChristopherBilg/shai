#!/bin/bash
# test_issue_dispatcher.sh — unit tests for workflows/issue_dispatcher/run.sh
# Covers: workflows/issue_dispatcher/run.sh — idle tick, gh search failure, dependency-aware
#   dispatch (blocked, ready, API error, missing endpoint, mixed), label removal before dispatch,
#   sequential processing, dual idempotency (label + ledger), worker failure leaving ledger
#   unmarked, and label-removal-failure skip-and-continue (including the already-seen path)
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "workflows/issue_dispatcher/run.sh"

TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP")
export SHAI_HOME="$TMP"

make_stub_bin

# A shai-workflow stub records each `run issue_worker <repo> <number>` invocation to a log
# and returns a configurable exit code (default 0). Tests point SHAI_WORKFLOW at it.
WORKER_LOG="$TMP/worker.log"
WORKER_RC_FILE="$TMP/worker_rc"
echo 0 >"$WORKER_RC_FILE"
cat >"$STUB/shai-workflow" <<WFSTUB
#!/bin/bash
# args: run issue_worker <repo> <number>
if [ "\$1" = "run" ] && [ "\$2" = "issue_worker" ]; then
  printf '%s %s\n' "\$3" "\$4" >>"$WORKER_LOG"
  [ -z "\${SHAI_POLICY_OVERLAY:-}" ] || printf 'OVERLAY=%s\n' "\$SHAI_POLICY_OVERLAY" >>"$WORKER_LOG"
fi
exit "\$(cat "$WORKER_RC_FILE")"
WFSTUB
chmod +x "$STUB/shai-workflow"
export SHAI_WORKFLOW="$STUB/shai-workflow"

# A gh stub whose behavior for `search issues` is driven by a fixture file, and which records
# `issue edit ... --remove-label` calls to a log. `edit` returns a configurable exit code.
SEARCH_FIXTURE="$TMP/search.json"
EDIT_LOG="$TMP/edit.log"
EDIT_RC_FILE="$TMP/edit_rc"
SEARCH_RC_FILE="$TMP/search_rc"
echo 0 >"$EDIT_RC_FILE"
echo 0 >"$SEARCH_RC_FILE"
DEPS_DIR="$TMP/deps"
DEPS_RC_FILE="$TMP/deps_rc"
echo 0 >"$DEPS_RC_FILE"
mkdir -p "$DEPS_DIR"
cat >"$STUB/gh" <<GHSTUB
#!/bin/bash
case "\$*" in
  "search issues"*)
    rc="\$(cat "$SEARCH_RC_FILE")"
    [ "\$rc" = "0" ] || exit "\$rc"
    cat "$SEARCH_FIXTURE"
    ;;
  "api "*"/dependencies/blocked_by"*)
    num=\$(echo "\$*" | sed 's|.*issues/\([0-9][0-9]*\)/.*|\1|')
    rc_file="$DEPS_DIR/\${num}.rc"
    rc="\$(cat "\$rc_file" 2>/dev/null || cat "$DEPS_RC_FILE" 2>/dev/null || echo 0)"
    if [ "\$rc" != "0" ]; then
      msg_file="$DEPS_DIR/\${num}.msg"
      [ -f "\$msg_file" ] && cat "\$msg_file" >&2
      exit "\$rc"
    fi
    fixture="$DEPS_DIR/\${num}.json"
    if [ -f "\$fixture" ]; then
      cat "\$fixture"
    else
      echo '[]'
    fi
    ;;
  "issue edit"*)
    printf '%s\n' "\$*" >>"$EDIT_LOG"
    exit "\$(cat "$EDIT_RC_FILE")"
    ;;
  *)
    echo "stub gh: \$*"
    ;;
esac
GHSTUB
chmod +x "$STUB/gh"

reset_state() {
  rm -f "$WORKER_LOG" "$EDIT_LOG"
  rm -rf "$SHAI_HOME/ledgers" "$SHAI_HOME/sessions" "$SHAI_HOME/failures" "$DEPS_DIR"
  mkdir -p "$DEPS_DIR"
  echo 0 >"$WORKER_RC_FILE"
  echo 0 >"$EDIT_RC_FILE"
  echo 0 >"$SEARCH_RC_FILE"
  echo 0 >"$DEPS_RC_FILE"
}

# issue_obj <number> <state>: emit a single issue object shaped like the real
# `dependencies/blocked_by` response (full issue objects, not `{state, number}`), so the
# suite pins that the dispatcher's `.state` filter tolerates the actual schema.
issue_obj() {
  jq -nc \
    --arg num "$1" \
    --arg state "$2" \
    '{url: ("https://api.github.com/repos/owner/repo/issues/" + $num),
      id: ($num | tonumber),
      node_id: ("I_kwDOAB1234" + $num),
      number: ($num | tonumber),
      title: ("dependency " + $num),
      state: $state,
      state_reason: (if $state == "closed" then "completed" else null end),
      locked: false,
      comments: 0,
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-02T00:00:00Z",
      closed_at: (if $state == "closed" then "2026-01-02T00:00:00Z" else null end),
      author_association: "OWNER",
      html_url: ("https://github.com/owner/repo/issues/" + $num),
      user: {login: "octocat"},
      labels: []}'
}

# --- idle tick: no matching issues ---
desc "idle tick"
reset_state
echo '[]' >"$SEARCH_FIXTURE"
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_dispatcher: exit 0 when no issues match"
assert_contains "$OUT" "no matching issues" "issue_dispatcher: reports idle tick"
assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
  "issue_dispatcher: no worker dispatched on idle tick"
# Expected-zero assertion (#388): an idle tick must leave $SHAI_HOME/sessions/ empty — no
# stillborn session files on every timer tick. Mutation-checked: reverting wf_init to eager
# seeding turns this red.
assert_eq "$(find "$SHAI_HOME/sessions" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "issue_dispatcher: idle tick creates no session files"

# --- dispatching tick: session IS materialized (positive control for the idle zero-count) ---
# The same fixture shape with a matching issue must produce the artifact the idle tick does
# not: exactly two files — the session log seeded with the system prompt plus the empty
# .latest.json sibling. The count (not bare existence) catches a fix that writes one file
# instead of two; the adjacent zero-count above provides the contrast. Mutation-checked
# (#388): removing the dispatcher's wf_seed_session call turns these red.
desc "dispatching tick materializes the session"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":42}]
JSON
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_dispatcher: dispatching tick exits 0"
assert_eq "$(find "$SHAI_HOME/sessions" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')" "2" \
  "issue_dispatcher: dispatching tick creates exactly two session files"
SESSION_LOG=$(find "$SHAI_HOME/sessions" -maxdepth 1 -type f -name '*.jsonl' | head -n1)
assert_eq "$(jq -r '.source' "$SESSION_LOG" | head -n1)" "system" \
  "issue_dispatcher: dispatching tick seeds the system prompt as the first event"

# --- gh search failure ---
desc "gh search failure"
reset_state
echo '[]' >"$SEARCH_FIXTURE"
echo 1 >"$SEARCH_RC_FILE"
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "1" "issue_dispatcher: exit 1 when gh search fails"
assert_contains "$OUT" "ERROR" "issue_dispatcher: prints ERROR on search failure"
# wf_fail on a pure-bash tick still records a failure attributed to this workflow (not the
# _repl fallback) with the minted session id, and still writes no session files.
assert_eq "$(find "$SHAI_HOME/sessions" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "issue_dispatcher: failed search tick creates no session files"
FAILURE_LOG="$SHAI_HOME/failures/issue_dispatcher.jsonl"
assert_eq "$(test -f "$FAILURE_LOG" && echo yes || echo no)" "yes" \
  "issue_dispatcher: records the search failure"
assert_eq "$(jq -r '.workflow' "$FAILURE_LOG" | head -n1)" "issue_dispatcher" \
  "issue_dispatcher: failure attributed to the workflow name, not _repl"
FAILURE_SID=$(jq -r '.session_id' "$FAILURE_LOG" | head -n1)
assert_eq "$(test -n "$FAILURE_SID" && echo set || echo empty)" "set" \
  "issue_dispatcher: failure record carries the minted session_id"

# --- single issue: label removed before dispatch, then worker run, then ledger marked ---
desc "single issue happy path"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":42}]
JSON
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_dispatcher: exit 0 on successful dispatch"
assert_contains "$OUT" "dispatched owner/repo#42" "issue_dispatcher: logs the dispatch"
assert_contains "$(cat "$EDIT_LOG")" "--remove-label shai-issue-dispatcher" \
  "issue_dispatcher: removes the shai-issue-dispatcher label"
assert_contains "$(cat "$WORKER_LOG")" "owner/repo 42" \
  "issue_dispatcher: delegates to issue_worker with repo and number"
assert_eq "$(grep -c 'OVERLAY=' "$WORKER_LOG" 2>/dev/null || true)" "0" \
  "issue_dispatcher: worker does not inherit SHAI_POLICY_OVERLAY"
LEDGER="$SHAI_HOME/ledgers/issue_dispatcher.jsonl"
if [ -f "$LEDGER" ] && grep -q '"issue:owner/repo:42"' "$LEDGER"; then
  echo -e "  ${GREEN}✓${NC} issue_dispatcher: wf_mark recorded issue key on success"
else
  echo -e "  ${RED}✗${NC} issue_dispatcher: wf_mark did not record issue key"
  FAILED=1
fi
LEDGER_SID=$(jq -r '.session_id' "$LEDGER" 2>/dev/null | head -n1)
assert_eq "$(test -n "$LEDGER_SID" && echo set || echo empty)" "set" \
  "issue_dispatcher: wf_mark ledger entry carries a non-empty session_id"

# --- multiple issues: all processed sequentially ---
desc "multiple issues"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":1},
 {"repository":{"nameWithOwner":"other/proj"},"number":7}]
JSON
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_dispatcher: exit 0 processing multiple issues"
assert_contains "$(cat "$WORKER_LOG")" "owner/repo 1" "issue_dispatcher: dispatches first issue"
assert_contains "$(cat "$WORKER_LOG")" "other/proj 7" "issue_dispatcher: dispatches second issue"
assert_contains "$OUT" "dispatched=2" "issue_dispatcher: summary counts both dispatches"

# --- ledger idempotency: an already-seen issue is skipped (no label edit, no worker) ---
desc "ledger idempotency"
reset_state
mkdir -p "$SHAI_HOME/ledgers"
printf '{"key":"issue:owner/repo:99","ts":"2026-08-13T00:00:00Z","session_id":"s1"}\n' \
  >"$SHAI_HOME/ledgers/issue_dispatcher.jsonl"
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":99}]
JSON
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_dispatcher: exit 0 when only match is already seen"
assert_contains "$OUT" "skipped=1" "issue_dispatcher: summary counts the skip"
assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
  "issue_dispatcher: already-seen issue is not dispatched"
assert_contains "$(cat "$EDIT_LOG")" "--remove-label shai-issue-dispatcher" \
  "issue_dispatcher: already-seen issue still has label removed"

# --- already-seen issue whose label cannot be removed is reported, not silently skipped ---
desc "already-seen label removal failure"
reset_state
mkdir -p "$SHAI_HOME/ledgers"
printf '{"key":"issue:owner/repo:99","ts":"2026-08-13T00:00:00Z","session_id":"s1"}\n' \
  >"$SHAI_HOME/ledgers/issue_dispatcher.jsonl"
echo 1 >"$EDIT_RC_FILE"
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":99}]
JSON
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_dispatcher: exit 0 when an already-seen issue cannot be de-labeled"
assert_contains "$OUT" "already-seen owner/repo#99" \
  "issue_dispatcher: warns when an already-seen issue's label cannot be removed"
assert_contains "$OUT" "skipped=1" "issue_dispatcher: still counts the skip"
assert_contains "$OUT" "failed=0" \
  "issue_dispatcher: already-seen removal failure is not counted as a failure"
assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
  "issue_dispatcher: already-seen issue is not dispatched when its label cannot be removed"

# --- label removal failure: skip and continue, label stays for retry, no dispatch ---
desc "label removal failure"
reset_state
echo 1 >"$EDIT_RC_FILE"
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":55}]
JSON
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "1" "issue_dispatcher: exit 1 when all dispatches fail (label removal)"
assert_contains "$OUT" "WARNING" "issue_dispatcher: warns on label removal failure"
assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
  "issue_dispatcher: no dispatch when label removal fails"
if [ -f "$SHAI_HOME/ledgers/issue_dispatcher.jsonl" ] &&
  grep -q '"issue:owner/repo:55"' "$SHAI_HOME/ledgers/issue_dispatcher.jsonl"; then
  echo -e "  ${RED}✗${NC} issue_dispatcher: should not mark ledger when label removal fails"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} issue_dispatcher: ledger not marked when label removal fails"
fi

# --- worker failure: label already removed, ledger left unmarked for manual re-label retry ---
desc "worker failure leaves ledger unmarked"
reset_state
echo 1 >"$WORKER_RC_FILE"
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":77}]
JSON
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "1" "issue_dispatcher: exit 1 when all dispatches fail (worker failure)"
assert_contains "$OUT" "WARNING" "issue_dispatcher: warns when worker fails"
assert_contains "$(cat "$EDIT_LOG")" "--remove-label shai-issue-dispatcher" \
  "issue_dispatcher: label was still removed before the failing worker ran"
if [ -f "$SHAI_HOME/ledgers/issue_dispatcher.jsonl" ] &&
  grep -q '"issue:owner/repo:77"' "$SHAI_HOME/ledgers/issue_dispatcher.jsonl"; then
  echo -e "  ${RED}✗${NC} issue_dispatcher: should not mark ledger when worker fails"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} issue_dispatcher: ledger not marked when worker fails"
fi

# --- seed failure: label already removed, failure recorded, item skipped, tick continues ---
# wf_seed_session runs after the label is removed, so a bare call under `set -e` would abort
# the tick after the `gh` mutation with no failure record — pre-#388 the same failure aborted
# in wf_init before any mutation. A read-only sessions dir makes the seed fail (skipped as
# root, where chmod 555 is no obstacle). Mutation-checked: reverting the guard to a bare
# `wf_seed_session` call turns the WARNING, failure-record, and zero-file assertions red.
if [ "$(id -u)" -ne 0 ]; then
  desc "seed failure records a failure and skips the dispatch"
  reset_state
  mkdir -p "$SHAI_HOME/sessions"
  chmod 555 "$SHAI_HOME/sessions"
  cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":42}]
JSON
  OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
  RC=$?
  chmod 755 "$SHAI_HOME/sessions"
  assert_eq "$RC" "1" "issue_dispatcher: exit 1 when seeding fails (only item, nothing dispatched)"
  assert_contains "$OUT" "WARNING: could not materialize session for owner/repo#42" \
    "issue_dispatcher: warns when seeding fails"
  assert_contains "$(cat "$EDIT_LOG")" "--remove-label shai-issue-dispatcher" \
    "issue_dispatcher: label was still removed before the seed failure"
  assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
    "issue_dispatcher: no dispatch when seeding fails"
  FAILURE_LOG="$SHAI_HOME/failures/issue_dispatcher.jsonl"
  assert_eq "$(test -f "$FAILURE_LOG" && echo yes || echo no)" "yes" \
    "issue_dispatcher: seed failure recorded in the failure store"
  assert_eq "$(jq -r '.workflow' "$FAILURE_LOG" | head -n1)" "issue_dispatcher" \
    "issue_dispatcher: seed failure attributed to the workflow name"
  assert_eq "$(jq -r '.context.detail' "$FAILURE_LOG" | head -n1)" "re-label to retry" \
    "issue_dispatcher: seed failure tells the operator to re-label"
  SEED_SID=$(jq -r '.session_id' "$FAILURE_LOG" | head -n1)
  assert_eq "$(test -n "$SEED_SID" && echo set || echo empty)" "set" \
    "issue_dispatcher: seed failure record carries the minted session_id"
  if [ -f "$SHAI_HOME/ledgers/issue_dispatcher.jsonl" ] &&
    grep -q '"issue:owner/repo:42"' "$SHAI_HOME/ledgers/issue_dispatcher.jsonl"; then
    echo -e "  ${RED}✗${NC} issue_dispatcher: should not mark ledger when seeding fails"
    FAILED=1
  else
    echo -e "  ${GREEN}✓${NC} issue_dispatcher: ledger not marked when seeding fails"
  fi
  assert_eq "$(find "$SHAI_HOME/sessions" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')" "0" \
    "issue_dispatcher: failed seed leaves no session files"
fi

# --- blocked issue: open dependencies, label stays, not dispatched ---
desc "blocked issue skipped when dependencies are open"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":42}]
JSON
{
  printf '['
  issue_obj 10 closed
  printf ','
  issue_obj 11 open
  printf ']\n'
} >"$DEPS_DIR/42.json"
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_dispatcher: exit 0 when only issue is blocked"
assert_contains "$OUT" "blocked=1" "issue_dispatcher: summary counts the blocked issue"
assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
  "issue_dispatcher: blocked issue is not dispatched"
assert_eq "$(test -f "$EDIT_LOG" && echo yes || echo no)" "no" \
  "issue_dispatcher: blocked issue's label is not removed"

# --- all dependencies closed: proceeds to dispatch ---
desc "all dependencies closed dispatches normally"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":42}]
JSON
{
  printf '['
  issue_obj 10 closed
  printf ','
  issue_obj 11 closed
  printf ']\n'
} >"$DEPS_DIR/42.json"
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_dispatcher: exit 0 when deps are all closed"
assert_contains "$OUT" "dispatched owner/repo#42" "issue_dispatcher: dispatches when all deps closed"
assert_contains "$OUT" "dispatched=1" "issue_dispatcher: summary counts the dispatch"
assert_contains "$OUT" "blocked=0" "issue_dispatcher: no blocked count when all deps closed"

# --- dependency API error: skip safely, label stays ---
desc "dependency API error defers issue"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":42}]
JSON
echo 1 >"$DEPS_DIR/42.rc"
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_dispatcher: exit 0 when dep check fails (not a dispatch failure)"
assert_contains "$OUT" "WARNING" "issue_dispatcher: warns on dependency check failure"
assert_contains "$OUT" "blocked=1" "issue_dispatcher: counts dep-check failure as blocked"
assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
  "issue_dispatcher: no dispatch when dependency check fails"
assert_eq "$(test -f "$EDIT_LOG" && echo yes || echo no)" "no" \
  "issue_dispatcher: label not removed when dependency check fails"

# --- dependency endpoint missing (404): fail loudly instead of deferring forever ---
desc "missing dependency endpoint fails loudly"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":42}]
JSON
echo 22 >"$DEPS_DIR/42.rc"
echo "gh: HTTP 404: Not Found (https://api.github.com/repos/owner/repo/issues/42/dependencies/blocked_by)" >"$DEPS_DIR/42.msg"
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "1" "issue_dispatcher: exit 1 when dependency endpoint is missing"
assert_contains "$OUT" "WARNING" "issue_dispatcher: warns on missing dependency endpoint"
assert_contains "$OUT" "failed=1" "issue_dispatcher: counts missing endpoint as failed"
assert_eq "$(test -f "$WORKER_LOG" && echo yes || echo no)" "no" \
  "issue_dispatcher: no dispatch when dependency endpoint is missing"
assert_eq "$(test -f "$EDIT_LOG" && echo yes || echo no)" "no" \
  "issue_dispatcher: label not removed when dependency endpoint is missing"

# --- mixed: one blocked, one ready ---
desc "mixed blocked and ready issues"
reset_state
cat >"$SEARCH_FIXTURE" <<'JSON'
[{"repository":{"nameWithOwner":"owner/repo"},"number":1},
 {"repository":{"nameWithOwner":"owner/repo"},"number":7}]
JSON
{
  printf '['
  issue_obj 99 open
  printf ']\n'
} >"$DEPS_DIR/1.json"
OUT=$("$DIR/workflows/issue_dispatcher/run.sh" 2>&1)
RC=$?
assert_eq "$RC" "0" "issue_dispatcher: exit 0 with mixed blocked and ready"
assert_contains "$OUT" "dispatched=1" "issue_dispatcher: dispatches only the ready issue"
assert_contains "$OUT" "blocked=1" "issue_dispatcher: counts the blocked issue"
assert_contains "$(cat "$WORKER_LOG")" "owner/repo 7" "issue_dispatcher: dispatches the unblocked issue"
if grep -q "owner/repo 1" "$WORKER_LOG" 2>/dev/null; then
  echo -e "  ${RED}✗${NC} issue_dispatcher: blocked issue #1 should not be dispatched"
  FAILED=1
else
  echo -e "  ${GREEN}✓${NC} issue_dispatcher: blocked issue #1 was not dispatched"
fi

finish
