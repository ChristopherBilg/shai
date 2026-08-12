#!/bin/bash
# test_release_notes.sh — unit tests for workflows/release_notes.sh
# Covers: workflows/release_notes.sh — arg parsing, data gathering, LLM dispatch, edge cases
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "workflows/release_notes.sh"

TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP")
export SHAI_HOME="$TMP"

# --- usage error: no arguments ---
OUT=$("$DIR/workflows/release_notes.sh" 2>&1)
RC=$?
assert_eq "$RC" "2" "release_notes: exit 2 with no arguments"
assert_contains "$OUT" "Usage" "release_notes: prints usage on no args"

# --- usage error: only one argument ---
OUT=$("$DIR/workflows/release_notes.sh" owner/repo 2>&1)
RC=$?
assert_eq "$RC" "2" "release_notes: exit 2 with only repo"

# --- usage error: invalid repo format ---
OUT=$("$DIR/workflows/release_notes.sh" "not-a-repo" v1 2>&1)
RC=$?
assert_eq "$RC" "2" "release_notes: exit 2 on invalid repo format"
assert_contains "$OUT" "OWNER/REPO" "release_notes: error names the expected format"

# --- usage error: repo with extra slash ---
OUT=$("$DIR/workflows/release_notes.sh" "foo/bar/baz" v1 2>&1)
RC=$?
assert_eq "$RC" "2" "release_notes: exit 2 on repo with extra slash"

make_stub_bin

# gh stub that dispatches on subcommand:
#   gh api repos/OWNER/REPO --jq .default_branch        -> "main" (fallback arm)
#   gh api repos/OWNER/REPO/compare/BASE...HEAD          -> $compare_json
#   gh pr list --repo REPO --state merged ...            -> $pr_json
# The JSON payloads are spliced in between two here-doc fragments (each written with a
# quoted delimiter so `$*`/`$1` etc. reach the generated script literally, unexpanded here)
# via `printf '%s\n' "$var"`, which inserts the argument verbatim with no backslash
# interpretation — so this is safe even though the caller never needs embedded "\n" here.
write_release_notes_gh_stub() {
  local compare_json="$1"
  local pr_json="$2"
  cat >"$STUB/gh" <<'GHSTUB'
#!/bin/bash
case "$*" in
  *"api repos/"*"/compare/"*)
    cat <<'COMPARE'
GHSTUB
  # shellcheck disable=SC2129  # each append must sit between the adjacent here-docs it splices; a { } group would work too but reads worse threaded through the nesting below
  printf '%s\n' "$compare_json" >>"$STUB/gh"
  cat >>"$STUB/gh" <<'GHSTUB'
COMPARE
    ;;
  "pr list"*)
    cat <<'PRLIST'
GHSTUB
  printf '%s\n' "$pr_json" >>"$STUB/gh"
  cat >>"$STUB/gh" <<'GHSTUB'
PRLIST
    ;;
  *"api repos/"*)
    echo "main"
    ;;
  *)
    echo "stub gh: $*" >&2
    ;;
esac
GHSTUB
  chmod +x "$STUB/gh"
}

# --- success case: valid response with PRs ---
COMPARE_JSON='{"merge_base_commit":{"commit":{"committer":{"date":"2026-08-10T00:00:00Z"}}},"commits":[{"sha":"aaa"},{"sha":"bbb"},{"sha":"ccc"}]}'
PR_JSON='[{"number":1,"title":"Add feature X","labels":[{"name":"enhancement"}],"author":{"login":"alice"},"mergedAt":"2026-08-10T12:00:00Z","mergeCommit":{"oid":"aaa"}},{"number":2,"title":"Fix bug Y","labels":[{"name":"bug"}],"author":{"login":"bob"},"mergedAt":"2026-08-10T13:00:00Z","mergeCommit":{"oid":"bbb"}},{"number":3,"title":"Update CI config","labels":[{"name":"chore"}],"author":{"login":"carol"},"mergedAt":"2026-08-10T14:00:00Z","mergeCommit":{"oid":"ccc"}}]'

write_release_notes_gh_stub "$COMPARE_JSON" "$PR_JSON"

# The API response body must be valid JSON, so the newlines inside the "text" field are
# encoded here as the two literal characters \ and n. Piping this through `printf '%s'`
# (the JSON as printf's *argument*, not its format string) writes it byte-for-byte — unlike
# `printf 'literal-with-\n-in-it'`, which would have bash's printf interpret \n as a real
# newline and corrupt the JSON (a raw control character inside a JSON string is invalid).
LLM_RESPONSE='{"type":"message","content":[{"type":"text","text":"## Added\n- Feature X (#1)\n\n## Fixed\n- Bug Y (#2)\n\n## Infrastructure\n- CI config (#3)"}],"stop_reason":"end_turn"}'
printf '%s' "$LLM_RESPONSE" | write_curl_stub 200

STDOUT=$("$DIR/workflows/release_notes.sh" owner/repo v1 v2 2>/dev/null)
RC=$?
assert_eq "$RC" "0" "release_notes: exit 0 on valid response"
assert_contains "$STDOUT" "Added" "release_notes: stdout contains Added category"
assert_contains "$STDOUT" "(#1)" "release_notes: stdout contains PR reference"
assert_contains "$STDOUT" "Fixed" "release_notes: stdout contains Fixed category"
assert_contains "$STDOUT" "(#2)" "release_notes: stdout contains second PR reference"
assert_contains "$STDOUT" "Infrastructure" "release_notes: stdout contains Infrastructure category"
assert_contains "$STDOUT" "(#3)" "release_notes: stdout contains third PR reference"

# --- no commits (identical refs) ---
COMPARE_EMPTY='{"merge_base_commit":{"commit":{"committer":{"date":"2026-08-10T00:00:00Z"}}},"commits":[]}'
write_release_notes_gh_stub "$COMPARE_EMPTY" '[]'

STDERR=$("$DIR/workflows/release_notes.sh" owner/repo v1 v1 2>&1 >/dev/null)
RC=$?
assert_eq "$RC" "0" "release_notes: exit 0 on no commits"
assert_contains "$STDERR" "no changes" "release_notes: stderr reports no changes"

# --- no matching PRs ---
COMPARE_COMMITS='{"merge_base_commit":{"commit":{"committer":{"date":"2026-08-10T00:00:00Z"}}},"commits":[{"sha":"xxx"}]}'
PR_NOMATCH='[{"number":99,"title":"Unrelated PR","labels":[],"author":{"login":"eve"},"mergedAt":"2026-08-10T12:00:00Z","mergeCommit":{"oid":"zzz"}}]'
write_release_notes_gh_stub "$COMPARE_COMMITS" "$PR_NOMATCH"

STDERR=$("$DIR/workflows/release_notes.sh" owner/repo v1 v2 2>&1 >/dev/null)
RC=$?
assert_eq "$RC" "0" "release_notes: exit 0 on no matching PRs"
assert_contains "$STDERR" "no merged PRs" "release_notes: stderr reports no PRs"

# --- gh failure ---
printf '#!/bin/bash\nexit 1\n' >"$STUB/gh"
chmod +x "$STUB/gh"

OUT=$("$DIR/workflows/release_notes.sh" owner/repo v1 v2 2>&1)
RC=$?
assert_eq "$RC" "1" "release_notes: exit 1 on gh failure"
assert_contains "$OUT" "ERROR" "release_notes: prints ERROR on gh failure"

finish
