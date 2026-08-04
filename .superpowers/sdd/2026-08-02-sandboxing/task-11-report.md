# Task 3 report: prompt_user + gate in run_tool

**Status:** DONE
**Commit:** `0e3422f` — "Wire permission gate into run_tool (sandboxing task 3)" on branch `sandboxing`
**Worktree:** `/home/chris/Desktop/shai/.claude/worktrees/sandboxing`

## What was done

1. Read `task-11-brief.md` for the requirements and the exact code to insert.
2. Read `shai-dispatch` to confirm the current state: `check_policy` at lines 13-44, `run_tool`
   at 46-72, dispatch loop starting at 74 — matched the brief's description exactly.
3. Read `tests/test_policy.sh` and `tests/lib.sh` to understand the existing test harness
   (`extract_functions`/`run_check_policy`, `setup_policy`, `empty_home`, `make_stub_bin`,
   `write_gh_stub`, `assert_eq`/`assert_contains`, `_CLEANUP_DIRS`, `finish`) before adding to it.
4. Added `prompt_user` after `check_policy` (before `run_tool`), verbatim from the brief: checks
   `[ -t 2 ]` first and fails closed (returns 1) when stderr isn't a terminal; otherwise renders
   the tool name + `input`'s key/value pairs to `/dev/tty` and reads a y/N answer from `/dev/tty`
   (not stdin), defaulting to deny on anything other than `y`/`Y`/`yes`/`YES`.
5. Modified `run_tool`'s header, verbatim from the brief, to call `check_policy` and gate on its
   result before the tool `case` block: `allow` falls through unchanged, `deny` prints `Policy
   denied: <name>` and returns 1, `prompt` delegates to `prompt_user` and prints `Permission
   denied: <name>` + returns 1 if the user (or the fail-closed check) declines. The existing tool
   `case` block (gh_pr_view/gh_issue_view/list_directory/print_file/unknown) is untouched below
   the gate.
6. Added the three integration tests to `tests/test_policy.sh` before `finish`, exercising the
   *full* `shai-dispatch` pipeline (not the extracted functions) via a piped assistant event:
   deny → `is_error:true` + `Policy denied`; non-interactive prompt → `is_error:true` +
   `Permission denied` (fail-closed); allow → `is_error:false` (tool actually runs).
7. **Fixed a bug in the brief's example test code before it would run.** See "Deviation from the
   brief" below — `stub_dir=$(make_stub_bin)` doesn't work with `make_stub_bin`'s actual
   implementation; had to call it unwrapped and read `$STUB` instead.
8. Ran `bash tests/test_policy.sh` — 25/25 assertions pass (22 pre-existing `check_policy` unit
   tests + 3 new integration tests), PASS banner.
9. Ran `./tests/run.sh` — all 12 suites pass, including `test_dispatch.sh` (25/25 assertions,
   unaffected — see backward-compat note below).
10. Ran `./bin/shellcheck shai-dispatch tests/test_policy.sh` — clean, no output.
11. Ran `./bin/shfmt -d shai-dispatch tests/test_policy.sh` — clean, no diff.
12. Ran `bash tests/conventions.sh` — CONVENTIONS OK.
13. Ran `bash tests/docs.sh` — DOCS OK (header block on `shai-dispatch` was not touched; Task 1
    already didn't update it when adding `check_policy`'s own new file-read, so this follows the
    same precedent — `docs.sh` checks field *presence*, not per-line accuracy).
14. Committed to `sandboxing` (`shai-dispatch` + `tests/test_policy.sh` only; the untracked
    `.superpowers/` SDD metadata dir left alone, matching prior tasks' precedent).

## Deviation from the brief: fixed a bug in the example test code

The brief's three integration-test snippets use `stub_dir=$(make_stub_bin)` then
`write_gh_stub "$stub_dir"`. Running that verbatim fails immediately:

```
tests/lib.sh: line 75: STUB: unbound variable
```

Cause: `tests/lib.sh`'s real `make_stub_bin` takes no arguments, prints nothing to stdout, and
communicates its temp dir via the **global** `$STUB` variable plus an in-place `export
PATH="$STUB:$PATH"`. Wrapping the call in `$(...)` (command substitution) runs it in a
**subshell** — `STUB` gets set and `PATH` gets exported *inside that subshell only*, then both
vanish when the subshell exits; `stub_dir` captures empty stdout. The very next line,
`write_gh_stub` (which also ignores any argument and writes straight to `$STUB/gh`), then dies
under this test file's `set -uo pipefail` because `$STUB` was never set in the parent shell —
exactly matching every other `test_*.sh` file's existing usage (`test_dispatch.sh:9-10` calls
`make_stub_bin` and `write_gh_stub` unwrapped, with no arguments, for the same reason).

Fix: call `make_stub_bin` and `write_gh_stub` as plain statements (not inside `$(...)`), then
assign `stub_dir="$STUB"` afterward for readability where the brief's snippet references
`$stub_dir`:

```bash
make_stub_bin
stub_dir="$STUB"
write_gh_stub
```

This preserves the brief's test structure and assertions exactly (same policy fixtures, same
event JSON, same `PATH="$stub_dir:$PATH" bash "$DIR/shai-dispatch" 2>/dev/null` invocation, same
`assert_contains` checks) — only the two lines that stand up the `gh` stub were corrected to
match `lib.sh`'s actual calling convention. No other part of the brief's test code changed.

## Acceptance-criteria coverage

| Brief criterion | Where satisfied |
|---|---|
| `prompt_user` renders tool name and args to `/dev/tty`, reads Y/N | `shai-dispatch` `prompt_user`, verbatim from brief |
| `prompt_user` defaults to N (deny) on empty input | `case "$answer" in y\|Y\|yes\|YES) return 0 ;; *) return 1 ;; esac` — empty string falls to `*` |
| `run_tool` calls `check_policy` before the tool `case` block | `shai-dispatch` `run_tool`, gate inserted before `local number repo path; case "$name" in` |
| `allow` proceeds to execution unchanged | `allow) ;;` no-op arm, falls through to the tool case |
| `deny` prints error message and returns 1 without executing | dedicated integration test: `Policy denied` + `is_error:true` |
| `prompt` + interactive + y/Y → executes | implemented verbatim per brief (`[ -t 2 ]` + `read -r answer </dev/tty`); not covered by an automated test — see note below |
| `prompt` + interactive + n/N/empty → returns 1 | implemented verbatim per brief; same note |
| `prompt` + non-interactive → returns 1 (fail closed) | dedicated integration test: `Permission denied` + `is_error:true` |
| denied/failed-closed calls produce well-formed `tool_result` with `is_error:true` | all three new integration tests assert this via the real dispatch loop's JSON construction (unchanged) |
| `test_dispatch.sh` still passes | `./tests/run.sh` — 12/12 suites, `test_dispatch.sh` 25/25 assertions |

**Note on the two interactive-y/N criteria:** the brief's own three integration tests (the only
ones it asked me to add) cover deny, non-interactive-prompt, and allow — not the two interactive
branches of `prompt_user` itself. Driving a real `/dev/tty` read from a hermetic, non-interactive
test harness would need a pty helper (`script`/`expect`/Python's `pty` module) that isn't part of
this project's test infra, and the brief didn't ask for one. I verified those two branches by
code inspection only (both are a direct, unmodified copy of the brief's specified `prompt_user`
body). Flagging this as the one acceptance box not covered by an automated assertion, in case the
SDD plan wants a follow-up task for it.

## Backward compatibility (test_dispatch.sh)

Confirmed mechanically, not just by inspection: `$HOME/.shai/policy.json` doesn't exist on this
machine, so `check_policy` takes its "no policy file" branch for every tool `test_dispatch.sh`
exercises — `allow` for the four read-only tools (all of `test_dispatch.sh`'s real-tool cases),
and `prompt` for the one synthetic `"nope"` tool (the "unknown tool" test). In this repo's
test-running environments (this sandbox, and presumably GitHub Actions CI) stderr on the
`shai-dispatch` subprocess is not a tty, so `prompt_user`'s `[ -t 2 ]` check is false and it
fails closed immediately — the assertion only checks `"is_error":true`, which now comes from
`Permission denied: nope` instead of the old `Unknown tool: nope`, so the test still passes
unchanged. Ran `./tests/run.sh` to confirm: 12/12 suites, no regressions.

## Concerns

1. **Interactive-terminal hang risk in `test_dispatch.sh`'s "unknown tool" case (not introduced
   by this task's own new tests, but newly *reachable* because of this task's change).** The
   three new integration tests in `tests/test_policy.sh` all redirect `2>/dev/null` on the
   `shai-dispatch` invocation specifically to force `[ -t 2 ]` false and exercise the fail-closed
   path deterministically — the brief's author clearly built that in. `test_dispatch.sh`'s
   pre-existing `"nope"`/unknown-tool case does **not** redirect stderr. Before this task,
   `run_tool` never consulted the policy gate, so that test could never block. After this task,
   if someone runs `bash tests/test_dispatch.sh` (or `./tests/run.sh`) directly in a real
   interactive terminal — as opposed to this sandbox or a CI runner, where stderr is a pipe, not
   a tty — fd 2 on that subprocess is the real terminal, `[ -t 2 ]` is true, and `prompt_user`
   will print a visible `Allow? [y/N]` prompt to `/dev/tty` and block on `read` until a human
   answers (default-deny on Enter, so it self-resolves, but it's an unexpected interactive stall
   partway through an otherwise-unattended test run). This is out of my assigned scope
   (`shai-dispatch` + `tests/test_policy.sh` only) and doesn't fail any required check in this
   environment or in CI, so I left `test_dispatch.sh` untouched rather than unilaterally editing
   a file outside the brief — but it's worth a deliberate decision (e.g., a follow-up task to add
   `2>/dev/null` to that one invocation, or a project-wide convention that all `shai-dispatch`
   test invocations redirect stderr for hermeticity).
2. **`run_tool`'s policy-gate `case` has no catch-all arm.** If `check_policy` ever returns
   anything other than exactly `allow`/`deny`/`prompt` — which can only happen today if a user's
   `policy.json` sets `"action"` to some other literal string on a matching rule, since
   `check_policy`'s own fallback logic (`${action:-${fallback:-prompt}}`) can only ever produce
   `prompt` as a default — the `case` silently matches nothing and falls through to the tool
   `case` block, i.e. it **fails open** rather than closed. This is exactly the code given in the
   brief (no `*)` arm was specified), and `check_policy` itself already existed before this task
   (Tasks 1/2), so I implemented it as specified rather than unilaterally changing the gate's
   fail-safe contract. Flagging for awareness given this is a permission gate; a `*) printf
   'Policy denied: %s (unrecognized action)' "$name"; return 1 ;;` arm would close it if the SDD
   plan wants that hardened.

Neither concern blocks this task's acceptance criteria or required verification commands, both
of which pass cleanly; both are flagged for the orchestrator/plan owner to decide on, not fixed
unilaterally outside the given scope.

## Addendum: review fixes (commit `2a7ccc5`)

The task reviewer confirmed both concerns above and asked for them to be fixed. Both were
addressed exactly as the reviewer specified, in the two files their scope now covers
(`shai-dispatch`, `tests/test_dispatch.sh`):

1. **Fail-open on unrecognized policy action (Concern 2, now closed).** Added a `*)` catch-all
   arm to the `case "$policy_action"` block in `run_tool` (`shai-dispatch`), after the existing
   `prompt)` arm and before `esac`:
   ```bash
   *)
     printf 'Policy denied: %s (unrecognized action)' "$name"
     return 1
     ;;
   ```
   Any `check_policy` return value other than exactly `allow`/`deny`/`prompt` now fails closed
   (denies) instead of silently falling through to execute the tool.

2. **Latent interactive hang in `test_dispatch.sh` (Concern 1, now closed).** Added `2>/dev/null`
   to the one dispatch invocation in the pre-existing "unknown tool" test (the `UNK`/`UOUT` case),
   plus a short comment explaining why — matching exactly how the three integration tests added
   to `tests/test_policy.sh` in the base commit already guard the same `prompt_user` path. This
   was the only invocation in `test_dispatch.sh` exercising a tool name outside the four built-in
   read-only tools, so it was the only one exposed to the gate's `prompt_user` call.

### Verification

- `bash tests/test_policy.sh` — 25/25 assertions pass, PASS banner (unchanged from the base
  commit; this addendum touched no policy-test logic).
- `./tests/run.sh` — 12/12 suites pass, including `test_dispatch.sh` (25/25 assertions).
- `./bin/shellcheck shai-dispatch tests/test_dispatch.sh` — clean, no output.
- `./bin/shfmt -d shai-dispatch tests/test_dispatch.sh` — clean, no diff.
- `bash tests/conventions.sh` — CONVENTIONS OK.
- `bash tests/docs.sh` — DOCS OK.

### Status after addendum

**DONE.** Both reviewer-flagged issues are fixed and verified; no new concerns surfaced while
fixing them. Commit `2a7ccc5` — "Fail closed on unrecognized policy action; guard
test_dispatch's tty prompt" on branch `sandboxing`, stacked on the base commit `0e3422f`.
