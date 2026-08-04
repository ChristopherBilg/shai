# Task 2 report: Test suite for check_policy

**Status:** DONE
**Commit:** `2d22bef` — "Add test suite for check_policy (sandboxing task 2)" on branch `sandboxing`
**Worktree:** `/home/chris/Desktop/shai/.claude/worktrees/sandboxing`

## What was done

1. Read `task-10-brief.md` for the requirements and the suggested test harness.
2. Read `shai-dispatch` to confirm the current `check_policy` implementation (already fixed
   twice by earlier commits `a1030f1` and `f7cdee0` — the empty-file/malformed-file fallback
   and the unguarded jq pipeline were both already addressed before this task started).
3. Read `tests/lib.sh` for the shared helpers (`assert_eq`, `assert_contains`, `_CLEANUP_DIRS`,
   `finish`) and `tests/test_dispatch.sh` / `tests/test_prune.sh` for the project's test style.
4. Prototyped the extract-and-eval harness in a scratch script and empirically verified, before
   writing the real suite, that:
   - the extracted `set -euo pipefail` and the per-call `SHAI_HOME=...` prefix assignment are
     both confined to the `$(...)` subshell each call runs in, and never leak into the rest of
     the test script (confirmed with a `false` immediately after a call not aborting the
     script, and by checking `$SHAI_HOME` is unset in the parent after every call);
   - jq's actual behavior on empty vs. malformed policy files (empty file → exit 0, no output;
     malformed → non-zero exit), so the tests assert the real failure mode rather than a
     guessed one.
5. Wrote `tests/test_policy.sh` — 20 assertions covering every acceptance criterion (mapping
   below), then `chmod +x`.
6. Ran `bash tests/test_policy.sh` — 20/20 pass, PASS banner.
7. Ran `./tests/run.sh` — all 12 suites pass (11 pre-existing + this one), no regressions.
8. Ran `./bin/shellcheck tests/test_policy.sh` and `./bin/shfmt -d tests/test_policy.sh` — both
   clean (lint tools were already installed in `bin/`, so `install-lint-tools.sh` was a no-op).
9. Staged the file (`git add`, required for the two checks below since they enumerate
   `git ls-files`) and ran `bash tests/conventions.sh` and `bash tests/docs.sh` — both OK.
10. Committed to `sandboxing` (only `tests/test_policy.sh` staged; the untracked
    `.superpowers/` SDD metadata dir was left alone, matching the task-1/9 commits' precedent).

## Acceptance-criteria coverage

| Brief criterion | Test(s) |
|---|---|
| no policy file → allow for the 4 read-only tools, prompt for others | loop over the 4 tools + one `some_write_tool` case |
| empty policy file → prompt | dedicated case, plus a whitespace-only regression case |
| malformed (non-JSON) policy file → prompt | dedicated case |
| exact tool match, allow / deny | two dedicated cases |
| rule with `args` exact match | match case + non-matching-value case (falls to default) |
| rule with `args` glob (`*`) | match case + non-matching-path case (falls to default) |
| glob doesn't let regex-special chars act as regex | `foo.bar` rule vs. `fooXbar` (must not match) and vs. `foo.bar` (must match) |
| first-match-wins, specific allow above broad deny | as specified, **plus** the reverse ordering, to prove it's rule order — not specificity — driving the result |
| no rule matches → `default` field | dedicated case |
| no rule matches, no `default` → prompt | dedicated case |
| offline, no real `~/.shai` | structural: every call passes an explicit temp-dir `SHAI_HOME`; none is ever left unset |

## Note: one correction to the brief's illustrative snippet

The brief's `extract_functions` sketch reads `shai-dispatch` via `"$DIR/../shai-dispatch"`.
That's off by one directory level once `lib.sh` is sourced: `lib.sh` defines `$DIR` as the
**repo root** already (its own comment says `# repo root; tests invoke "$DIR/shai-*"`), so
appending another `../` lands one level above the repo root, where `shai-dispatch` doesn't
exist. I used `"$DIR/shai-dispatch"` (no `../`) instead, matching the path convention every
other `test_*.sh` in the suite already uses. I caught this by actually running the harness
before trusting it — with the literal brief path every test would fail with "file not found"
rather than a logic mismatch, which would have been an obvious tell, but I verified the
corrected form end-to-end rather than assuming the sketch was copy-pasteable as-is.

No other deviations, and `check_policy` itself was not touched — this task only adds tests.

## Verification method

Every expected value in `tests/test_policy.sh` was cross-checked two ways before being written
into an `assert_eq`: (1) by tracing the actual `jq` filter and the bash fallback-expansion logic
in the committed `shai-dispatch`, and (2) empirically, by running the same extract-and-eval
harness in a scratch script against real policy-file fixtures and reading back the actual
output. Both agreed in every case, including the trickier ones (empty vs. malformed file both
reaching `prompt`, but via different jq exit-code paths; the escaped-`.`-vs-literal-`X` glob
case; both orderings of the first-match-wins rules; a policy file with no `rules` key at all
not crashing, via `.rules[]?`).

## Concerns

None. `check_policy` as it stands after `f7cdee0` satisfies every acceptance criterion in the
brief; the new test suite is green, lint-clean, and passes both project-hygiene checks
(`tests/conventions.sh`, `tests/docs.sh`).
