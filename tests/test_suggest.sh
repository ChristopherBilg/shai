#!/bin/bash
# test_suggest.sh — tests for the wf_suggest post-workflow suggestion helper
# Covers: lib/workflow.sh — wf_suggest, wf_suggest_repo
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "lib/workflow.sh wf_suggest"

make_stub_bin

# git stub driven by two env vars, so each case can describe the work tree it wants:
# STUB_TOPLEVEL is what `rev-parse --show-toplevel` reports, STUB_REMOTE what
# `remote get-url origin` reports. Empty/unset means "reports nothing".
write_git_repo_stub() {
  {
    printf '#!/bin/bash\n'
    printf 'case "$*" in\n'
    printf '  *rev-parse*) echo "${STUB_TOPLEVEL:-}" ;;\n'
    printf '  *get-url*) echo "${STUB_REMOTE:-}" ;;\n'
    printf '  *) echo "stub git: $*" ;;\n'
    printf 'esac\n'
  } >"$STUB/git"
  chmod +x "$STUB/git"
}

# A minimal overlay granting gh — wf_suggest requires one to already be in effect.
write_overlay() {
  printf '{"rules":[{"tool":"gh","action":"allow"}]}\n' >"$1"
}

# Session-log length, the observable proxy for "did an LLM call happen".
# shellcheck disable=SC2031  # deliberate: reads the SHAI_* vars of the subshell that calls it
log_lines() { wc -l <"$SHAI_HOME/sessions/$SHAI_SESSION_ID.jsonl" | tr -d ' '; }

write_git_repo_stub
write_gh_stub

# Every case below the "skips" line must make no LLM call at all; this stub keeps such a
# call offline and observable (shai-eval turns the 500 into an error event, growing the log).
printf '{"error":{"message":"stub: unexpected LLM call"}}' | write_curl_stub 500

# --- wf_suggest: SHAI_SUGGEST=0 opts out entirely (no LLM call, no output) ---
TMP1="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP1")
write_overlay "$TMP1/policy.json"

# shellcheck disable=SC2030,SC2031
(
  export SHAI_HOME="$TMP1"
  export SHAI_POLICY_OVERLAY="$TMP1/policy.json"
  export SHAI_SUGGEST_REPO="Test/Repo"
  export SHAI_SUGGEST=0
  source "$DIR/lib/workflow.sh"
  wf_init

  BEFORE=$(log_lines)
  OUTPUT=$(wf_suggest 2>&1)
  assert_eq "$?" "0" "wf_suggest: exits 0 when disabled"
  assert_eq "$OUTPUT" "" "wf_suggest: silent when SHAI_SUGGEST=0"
  # The curl stub returns 500, so any LLM call would append an error event and grow the log.
  assert_eq "$(log_lines)" "$BEFORE" "wf_suggest: makes no LLM call when SHAI_SUGGEST=0"

  exit "$FAILED"
) || FAILED=1

# --- wf_suggest: skips (never fabricates an overlay) when none is in effect ---
TMP2="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP2")

# shellcheck disable=SC2030,SC2031
(
  export SHAI_HOME="$TMP2"
  unset SHAI_POLICY_OVERLAY
  export SHAI_SUGGEST_REPO="Test/Repo"
  source "$DIR/lib/workflow.sh"
  wf_init

  BEFORE=$(log_lines)
  STDOUT=$(wf_suggest 2>"$TMP2/err")
  assert_eq "$?" "0" "wf_suggest: exits 0 with no policy overlay"
  assert_eq "$STDOUT" "" "wf_suggest: writes nothing to stdout when skipping"
  assert_contains "$(cat "$TMP2/err")" "no policy overlay" \
    "wf_suggest: warns on stderr that no overlay is in effect"
  assert_eq "$(log_lines)" "$BEFORE" "wf_suggest: makes no LLM call without an overlay"

  exit "$FAILED"
) || FAILED=1

# --- wf_suggest: skips when the repo cannot be derived (install dir is not a work tree) ---
TMP3="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP3")
write_overlay "$TMP3/policy.json"

# shellcheck disable=SC2030,SC2031
(
  export SHAI_HOME="$TMP3"
  export SHAI_POLICY_OVERLAY="$TMP3/policy.json"
  unset SHAI_SUGGEST_REPO
  # A release install has no .git of its own; git's parent-directory discovery hands back
  # an unrelated ancestor repo, which must not be treated as the shai repo.
  export STUB_TOPLEVEL="$HOME"
  export STUB_REMOTE="https://github.com/Someone/dotfiles.git"
  source "$DIR/lib/workflow.sh"
  wf_init

  BEFORE=$(log_lines)
  STDOUT=$(wf_suggest 2>"$TMP3/err")
  assert_eq "$?" "0" "wf_suggest: exits 0 when install dir is not the work tree top"
  assert_eq "$STDOUT" "" "wf_suggest: writes nothing to stdout on undetectable repo"
  assert_contains "$(cat "$TMP3/err")" "cannot derive shai repo" \
    "wf_suggest: warns when the repo cannot be derived"
  assert_eq "$(log_lines)" "$BEFORE" "wf_suggest: makes no LLM call on undetectable repo"

  exit "$FAILED"
) || FAILED=1

# --- wf_suggest_repo: honours SHAI_SUGGEST_REPO, validates OWNER/REPO shape ---
TMP4="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP4")

# shellcheck disable=SC2030,SC2031
(
  export SHAI_HOME="$TMP4"
  source "$DIR/lib/workflow.sh"

  assert_eq "$(SHAI_SUGGEST_REPO="Owner/Repo-name.x" wf_suggest_repo)" \
    "Owner/Repo-name.x" "wf_suggest_repo: returns an explicit SHAI_SUGGEST_REPO"

  OUT=$(SHAI_SUGGEST_REPO="not a repo" wf_suggest_repo)
  assert_eq "$?" "1" "wf_suggest_repo: rejects a malformed override"
  assert_eq "$OUT" "" "wf_suggest_repo: prints nothing for a malformed override"

  OUT=$(SHAI_SUGGEST_REPO="Owner/Repo/extra" wf_suggest_repo)
  assert_eq "$?" "1" "wf_suggest_repo: rejects a three-segment override"

  OUT=$(SHAI_SUGGEST_REPO="../evil" wf_suggest_repo)
  assert_eq "$?" "1" "wf_suggest_repo: rejects a traversal-shaped override"

  # $DIR is the top of this work tree, so the origin remote is trustworthy here.
  export STUB_TOPLEVEL="$DIR"
  export STUB_REMOTE="git@github.com:Test/Repo.git"
  unset SHAI_SUGGEST_REPO
  assert_eq "$(wf_suggest_repo)" "Test/Repo" \
    "wf_suggest_repo: derives OWNER/REPO from the origin remote"

  exit "$FAILED"
) || FAILED=1

# --- wf_suggest_repo: the REPO file a release tarball bakes in ---
# A release install has no .git of its own, so git discovery resolves an unrelated ancestor
# work tree and wf_suggest_repo refuses it — leaving no way to derive the repo at all. The
# release tarball therefore bakes OWNER/REPO into $DIR/REPO next to VERSION (release.yml).
# The git stub below reports a toplevel that is NOT the install dir, so discovery cannot
# succeed here: reading the file is the only way these assertions can pass.
INSTALL_FIXTURE="$(mktemp -d)"
_CLEANUP_DIRS+=("$INSTALL_FIXTURE")

# shellcheck disable=SC2030,SC2031
(
  source "$DIR/lib/workflow.sh"
  export STUB_TOPLEVEL="/not/the/install/dir"
  export STUB_REMOTE="https://github.com/Someone/dotfiles.git"
  unset SHAI_SUGGEST_REPO
  DIR="$INSTALL_FIXTURE"

  printf 'Owner/FromReleaseFile\n' >"$DIR/REPO"
  assert_eq "$(wf_suggest_repo)" "Owner/FromReleaseFile" \
    "wf_suggest_repo: reads the install dir's REPO file when git discovery cannot resolve it"

  # Precedence: an explicit override still beats the baked-in file.
  assert_eq "$(SHAI_SUGGEST_REPO="Owner/Override" wf_suggest_repo)" "Owner/Override" \
    "wf_suggest_repo: SHAI_SUGGEST_REPO takes precedence over the REPO file"

  # Fail-closed on a corrupt artifact: a malformed REPO file must not fall through to git
  # discovery, which would hand back the unrelated dotfiles repo the stub reports above.
  # Positive control is the valid-file assertion at the top of this block — same fixture,
  # same stub, differing only in the file's contents.
  printf 'not a repo\n' >"$DIR/REPO"
  OUT=$(wf_suggest_repo)
  assert_eq "$?" "1" "wf_suggest_repo: rejects a malformed REPO file"
  assert_eq "$OUT" "" "wf_suggest_repo: prints nothing for a malformed REPO file"

  # And an empty file is not a repo either (a truncated download must not read as one).
  : >"$DIR/REPO"
  OUT=$(wf_suggest_repo)
  assert_eq "$?" "1" "wf_suggest_repo: rejects an empty REPO file"

  exit "$FAILED"
) || FAILED=1

# --- wf_suggest: skips when the prompt file is missing (non-fatal) ---
TMP5="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP5")
write_overlay "$TMP5/policy.json"

FAKE="$(mktemp -d)"
_CLEANUP_DIRS+=("$FAKE")
# shellcheck disable=SC2031  # deliberate: DIR is set by lib.sh at file scope, not lost
cp "$DIR/shai-prompt" "$FAKE/"
mkdir -p "$FAKE/prompts"
chmod +x "$FAKE/shai-prompt"

# shellcheck disable=SC2030,SC2031
(
  export SHAI_HOME="$TMP5"
  export SHAI_POLICY_OVERLAY="$TMP5/policy.json"
  export SHAI_SUGGEST_REPO="Test/Repo"
  source "$DIR/lib/workflow.sh"
  wf_init

  DIR="$FAKE"
  STDOUT=$(wf_suggest 2>"$TMP5/err")
  assert_eq "$?" "0" "wf_suggest: exits 0 when prompt missing"
  assert_eq "$STDOUT" "" "wf_suggest: writes nothing to stdout on missing prompt"
  assert_contains "$(cat "$TMP5/err")" "cannot load suggest prompt" \
    "wf_suggest: warns on stderr about the missing prompt"

  exit "$FAILED"
) || FAILED=1

# --- wf_suggest: runs the step, keeps stdout clean, leaves the overlay untouched ---
TMP6="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP6")
EXISTING_POLICY="$TMP6/existing_policy.json"
write_overlay "$EXISTING_POLICY"

printf '{"id":"chatcmpl-test","choices":[{"message":{"role":"assistant","content":"no suggestions"},"finish_reason":"stop"}],"model":"test-model","usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}' |
  write_curl_stub 200

# shellcheck disable=SC2030,SC2031
(
  export SHAI_HOME="$TMP6"
  export SHAI_POLICY_OVERLAY="$EXISTING_POLICY"
  export SHAI_SUGGEST_REPO="Test/Repo"
  source "$DIR/lib/workflow.sh"
  wf_init

  BEFORE=$(log_lines)
  STDOUT=$(wf_suggest 2>/dev/null)
  assert_eq "$?" "0" "wf_suggest: exits 0 on success"
  assert_eq "$STDOUT" "" "wf_suggest: writes nothing to stdout on success"
  assert_eq "$([ "$(log_lines)" -gt "$BEFORE" ] && echo yes || echo no)" "yes" \
    "wf_suggest: appends events to session log"
  assert_eq "$SHAI_POLICY_OVERLAY" "$EXISTING_POLICY" \
    "wf_suggest: does not clobber existing SHAI_POLICY_OVERLAY"
  assert_eq "$([ -f "$SHAI_POLICY_OVERLAY" ] && echo yes || echo no)" "yes" \
    "wf_suggest: leaves the existing overlay file in place"

  exit "$FAILED"
) || FAILED=1

finish
