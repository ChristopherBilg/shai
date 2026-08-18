#!/bin/bash
# test_suggest.sh — tests for the wf_suggest post-workflow suggestion helper
# Covers: lib/workflow.sh — wf_suggest
set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "lib/workflow.sh wf_suggest"

make_stub_bin

# --- wf_suggest: exits 0 when git remote fails (non-fatal) ---
TMP="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP")

{
  printf '#!/bin/bash\nexit 1\n'
} >"$STUB/git"
chmod +x "$STUB/git"

# shellcheck disable=SC2030,SC2031
(
  export SHAI_HOME="$TMP"
  source "$DIR/lib/workflow.sh"
  wf_init

  OUTPUT=$(wf_suggest 2>&1)
  assert_eq "$?" "0" "wf_suggest: exits 0 when git remote fails"
  assert_contains "$OUTPUT" "WARN" "wf_suggest: warns on git remote failure"
  assert_contains "$OUTPUT" "shai repo" "wf_suggest: names the failure reason"

  exit "$FAILED"
) || FAILED=1

# --- wf_suggest: exits 0 when prompt file is missing (non-fatal) ---
TMP2="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP2")

{
  printf '#!/bin/bash\n'
  printf 'echo "https://github.com/Test/Repo.git"\n'
} >"$STUB/git"
chmod +x "$STUB/git"

FAKE="$(mktemp -d)"
_CLEANUP_DIRS+=("$FAKE")
# shellcheck disable=SC2031  # deliberate: DIR is set by lib.sh at file scope, not lost
cp "$DIR/shai-prompt" "$FAKE/"
mkdir -p "$FAKE/prompts"
chmod +x "$FAKE/shai-prompt"

# shellcheck disable=SC2030,SC2031
(
  export SHAI_HOME="$TMP2"
  source "$DIR/lib/workflow.sh"
  wf_init

  DIR="$FAKE"
  OUTPUT=$(wf_suggest 2>&1)
  assert_eq "$?" "0" "wf_suggest: exits 0 when prompt missing"
  assert_contains "$OUTPUT" "WARN" "wf_suggest: warns on missing prompt"

  exit "$FAILED"
) || FAILED=1

# --- wf_suggest: exits 0 and appends events on success ---
TMP3="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP3")

printf '{"type":"message","content":[{"type":"text","text":"no suggestions"}],"stop_reason":"end_turn"}' |
  write_curl_stub 200

{
  printf '#!/bin/bash\n'
  printf 'for a in "$@"; do\n'
  printf '  if [ "$a" = "get-url" ]; then\n'
  printf '    echo "https://github.com/Test/Repo.git"\n'
  printf '    exit 0\n'
  printf '  fi\n'
  printf 'done\n'
  printf 'echo "stub git: $*"\n'
} >"$STUB/git"
chmod +x "$STUB/git"

write_gh_stub

# shellcheck disable=SC2030,SC2031
(
  export SHAI_HOME="$TMP3"
  source "$DIR/lib/workflow.sh"
  wf_init

  BEFORE=$(wc -l <"$SHAI_HOME/sessions/$SHAI_SESSION_ID.jsonl" | tr -d ' ')

  wf_suggest >/dev/null 2>&1
  assert_eq "$?" "0" "wf_suggest: exits 0 on success"

  AFTER=$(wc -l <"$SHAI_HOME/sessions/$SHAI_SESSION_ID.jsonl" | tr -d ' ')
  assert_eq "$([ "$AFTER" -gt "$BEFORE" ] && echo yes || echo no)" "yes" \
    "wf_suggest: appends events to session log"

  exit "$FAILED"
) || FAILED=1

# --- wf_suggest: creates temp policy when SHAI_POLICY_OVERLAY is unset ---
TMP4="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP4")

printf '{"type":"message","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}' |
  write_curl_stub 200

{
  printf '#!/bin/bash\n'
  printf 'for a in "$@"; do\n'
  printf '  if [ "$a" = "get-url" ]; then\n'
  printf '    echo "https://github.com/Test/Repo.git"\n'
  printf '    exit 0\n'
  printf '  fi\n'
  printf 'done\n'
  printf 'echo "stub git: $*"\n'
} >"$STUB/git"
chmod +x "$STUB/git"

write_gh_stub

# shellcheck disable=SC2030,SC2031
(
  export SHAI_HOME="$TMP4"
  unset SHAI_POLICY_OVERLAY
  source "$DIR/lib/workflow.sh"
  wf_init

  wf_suggest >/dev/null 2>&1
  assert_eq "$?" "0" "wf_suggest: exits 0 with no pre-existing policy overlay"

  exit "$FAILED"
) || FAILED=1

# --- wf_suggest: preserves existing SHAI_POLICY_OVERLAY ---
TMP5="$(mktemp -d)"
_CLEANUP_DIRS+=("$TMP5")

printf '{"type":"message","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}' |
  write_curl_stub 200

{
  printf '#!/bin/bash\n'
  printf 'for a in "$@"; do\n'
  printf '  if [ "$a" = "get-url" ]; then\n'
  printf '    echo "https://github.com/Test/Repo.git"\n'
  printf '    exit 0\n'
  printf '  fi\n'
  printf 'done\n'
  printf 'echo "stub git: $*"\n'
} >"$STUB/git"
chmod +x "$STUB/git"

write_gh_stub

EXISTING_POLICY="$TMP5/existing_policy.json"
printf '{"rules":[{"tool":"gh","action":"allow"}]}\n' >"$EXISTING_POLICY"

# shellcheck disable=SC2030,SC2031
(
  export SHAI_HOME="$TMP5"
  export SHAI_POLICY_OVERLAY="$EXISTING_POLICY"
  source "$DIR/lib/workflow.sh"
  wf_init

  wf_suggest >/dev/null 2>&1
  assert_eq "$SHAI_POLICY_OVERLAY" "$EXISTING_POLICY" \
    "wf_suggest: does not clobber existing SHAI_POLICY_OVERLAY"

  exit "$FAILED"
) || FAILED=1

finish
