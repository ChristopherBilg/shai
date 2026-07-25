# shai — test infrastructure & continuous integration

**Status:** Approved design · **Date:** 2026-07-24

## Summary

`shai` currently ships one hand-rolled, offline test file (`tests/tests.sh`) and no CI.
This work grows that into structured, per-script test **infrastructure** with complete,
by-design coverage, and adds a **strict GitHub Actions CI gate** that runs on every push
(and pull request): tests, linting, formatting, and project-convention checks, each of
which must pass or the build fails.

The guiding constraint is the project's identity: **framework-free, pure `bash` + `curl`
+ `jq`**. No new *runtime* dependency is introduced. The only new tools — `shellcheck`
and `shfmt` — are CI/dev-time only and installed in the runner; the six runtime scripts
stay dependency-free.

## Decisions (settled during brainstorming)

| Decision | Choice | Why |
| :--- | :--- | :--- |
| Test framework | **Extend the hand-rolled harness** (no bats/shunit2) | Zero new deps; matches the framework-free ethos; reuses the solid existing harness |
| Coverage | **By design, no measurement tool** (no `kcov`) | An explicit per-script coverage matrix, verified in review, keeps CI dependency-free |
| CI strictness | **Strict gate — all jobs blocking** | Enforces the "standards & conventions" goal; requires cleaning the scripts up front |
| CI triggers | `push` **and** `pull_request` | "Every push" as requested, plus the standard PR gate before merge |
| Runner | `ubuntu-latest` only (no OS/bash matrix) | Portability isn't a goal; scripts target GNU/Linux and use GNU-isms |
| Formatter config | `.editorconfig` (2-space) honored by `shfmt` | Matches existing 2-space style; also aids the author's editor |
| Docs | `AGENTS.md` canonical, `CLAUDE.md` symlink → it | One source of contributor/agent guidance, tool-agnostic |

## Test infrastructure

### Layout

Replace the single `tests/tests.sh` with a runner + shared library + one file per script:

```
tests/
├── run.sh            # entrypoint: discover & run test_*.sh, aggregate pass/fail, set exit code
├── lib.sh            # shared: assert_eq, assert_contains, assert_exit; stub_curl, stub_gh; temp-dir/PATH setup
├── test_read.sh      # unit: shai-read
├── test_context.sh   # unit: shai-context
├── test_eval.sh      # unit: shai-eval
├── test_dispatch.sh  # unit: shai-dispatch
├── test_print.sh     # unit: shai-print
├── test_shai.sh      # integration: the REPL entry
└── conventions.sh    # standards/hygiene checker (run in CI + locally)
```

`tests/tests.sh` is removed; the documented entrypoint becomes `./tests/run.sh`.

### Isolation without a framework

`run.sh` executes each `test_*.sh` as its own **subprocess** and inspects the exit code,
so one file's failure — or a stray `set -e` abort — cannot corrupt another. This is a
lightweight version of the isolation bats provides, in pure bash. Each `test_*.sh` sources
`lib.sh` itself, so it remains runnable standalone (`./tests/test_context.sh`) as well as
under the runner.

- A test file exits non-zero if any of its assertions failed (a per-file `FAILED` flag,
  as today, but scoped to the file).
- `run.sh` prints a per-file line and a final aggregate summary, exiting non-zero if any
  file failed.
- The offline stubs (`curl`, `gh`) move into `lib.sh` as reusable functions that set up a
  `PATH`-prepended temp bin, so every suite is fully offline and spends no API credits
  (unchanged principle from the current harness).

### Coverage-by-design matrix

"Full coverage" is guaranteed by enumerating, per script, a named test for every
documented behavior and branch. The current suite is already strong; the design **ports
every existing assertion** and adds the gaps below. The spec carries this list so review
can confirm each test exists.

- **shai-read** — *(existing)* envelope, `user` source, payload text, `--system` source,
  empty input → empty + exit 0. *(add)* non-`--system` first arg still treated as user;
  multi-line input preserved verbatim.
- **shai-context** — *(existing)* system extraction, user/assistant mapping, assistant
  content array preserved, single `tool_result` folded with correct `tool_use_id` into a
  user turn, `--window 1`, `--window 0`, malformed/shape-bad lines skipped. *(add)*
  multiple consecutive `tool_result`s fold into **one** user turn; `--window` with no
  value → error + exit 1; default window keeps expected turns; empty history → empty
  `messages`.
- **shai-eval** — *(existing)* `--dry-run` payload (model, max_tokens, tools), no-tools
  case, empty `system` omitted, non-empty `system` included, stubbed 200 → assistant event
  + `stop_reason` + content, health-check with/without key, non-200 JSON error, non-200
  non-JSON → `HTTP <code>` fallback, 200 `type:error`, 200 non-JSON, 200 unexpected shape.
  *(add)* `--model`/`--max-tokens` overrides appear in payload; unknown option → exit 2;
  empty stdin → exit 0; `curl` hard-failure (non-zero) → error event.
- **shai-dispatch** — *(existing)* no-tool → exit 0 + no output, tool → exit 1 +
  `tool_result` + echoed `tool_use_id` + ran stubbed `gh`, unknown tool → `is_error:true`,
  output truncation to 8000 bytes (SIGPIPE-safe), multiple `tool_use` → multiple results,
  backslash path survives passthrough, `gh` number positional (`--` guards option
  injection). *(add)* `is_error:false` on success; `list_directory` and `print_file`
  happy paths individually; empty stdin → exit 0.
- **shai-print** — *(existing)* assistant text, `error` line, default hides
  `tool_use`/`tool_result`, `--debug` shows both. *(add)* multiple text blocks printed in
  order; text + `tool_use` ordering under `--debug`.
- **shai (integration)** — *(existing)* seeds system prompt, logs user/assistant events,
  tool round-trip records `tool_use` + `tool_result` and the loop re-evaluates to
  completion, final prompt without trailing newline is processed. *(add)* `exit`/`quit`
  ends the loop cleanly; a blank line is skipped; a failed startup health-check aborts
  before the loop.

## Script hygiene pass (prerequisite for the strict gate)

Because every check blocks, the existing scripts must pass them before CI is switched on.

- **shellcheck** — the six runtime scripts were shellchecked during MVP development, so
  this is expected to be an audit plus, where genuinely warranted, a few
  `# shellcheck disable=SCxxxx` directives **each with a reason comment** — not a rewrite.
  `tests/*.sh` are added to lint scope. Sourcing `lib.sh` is resolved with
  `# shellcheck source=` directives and/or a repo `.shellcheckrc` (`external-sources=true`).
- **shfmt** — a one-time `shfmt -w` normalizes formatting across all scripts. To preserve
  the existing **2-space** indentation (shfmt defaults to tabs), the repo gains a
  **`.editorconfig`** (`indent_style=space`, `indent_size=2`, plus
  `trim_trailing_whitespace=true` and `insert_final_newline=true`), which `shfmt` reads.
  CI then runs `shfmt -d` with no extra flags.

## CI workflow — `.github/workflows/ci.yml`

**Triggers:** `on: [push, pull_request]`.

**Runner:** `ubuntu-latest`. It ships `bash` 5, `jq`, and `shellcheck` preinstalled.
`shfmt` is installed by downloading its **pinned, checksum-verified release binary** from
the `mvdan/sh` releases (exact version + SHA256 pinned in the plan), rather than depending
on a third-party marketplace action — a cleaner supply chain and no version drift.

**Four parallel jobs**, each an independent signal, all blocking:

| Job | Runs | Fails when |
| :--- | :--- | :--- |
| `test` | `./tests/run.sh` | any assertion in any suite fails |
| `shellcheck` | `shellcheck` over all repo shell scripts | any finding (default severity) |
| `shfmt` | `shfmt -d` over all repo shell scripts | any file is not already formatted |
| `conventions` | `./tests/conventions.sh` | any project convention is violated |

Shell scripts are enumerated consistently (the six extension-less runtime scripts —
identified by their `#!/bin/bash` shebang — plus `tests/*.sh`), and `.git` is excluded.
Parallel jobs are chosen over a single sequential job so that a failure names the exact
check; the extra checkout overhead is negligible for a repo this size.

A **CI status badge** for this workflow is added to the top of `README.md`, linking to the
workflow's runs on the default branch.

## Conventions/standards checker — `tests/conventions.sh`

A first-class, locally-runnable script (not inline YAML) enforcing the project's own
conventions, so contributors get the same signal as CI:

1. `#!/bin/bash` shebang present on every script.
2. `set -euo pipefail` present on the six **runtime** scripts. (Test scripts intentionally
   use `set -uo pipefail` — no `-e` — so this strict check is scoped to runtime scripts.)
3. Executable bit set on the runtime scripts and `tests/run.sh`.
4. `tools.json` is valid JSON (`jq empty tools.json`).
5. No trailing whitespace, and a final newline at EOF, on tracked text files.

## Contributor & agent guidance — `AGENTS.md` (final step)

After the infrastructure and CI are in place and green, add an `AGENTS.md` at the repo
root as the canonical contributor/agent guide, with `CLAUDE.md` as a **symlink** to it
(`ln -s AGENTS.md CLAUDE.md`, committed as a symlink). It is concise and **links** to the
README and design docs rather than duplicating them. Contents:

- One-line description + pointers to `README.md` and `docs/superpowers/specs/`.
- Architecture map: the read → context → eval → dispatch → print pipeline, one line per
  script, and the append-only JSONL event schema (pointer to the MVP design).
- Conventions: bash strict mode, 2-space indent via `.editorconfig`, `shellcheck`/`shfmt`
  clean, read-only tools only, tool output truncated to 8000 bytes.
- Local verification: how to run tests (`./tests/run.sh`) and the exact CI checks locally
  (`shellcheck …`, `shfmt -d …`, `./tests/conventions.sh`).

## File inventory (added / changed / removed)

```
.github/workflows/ci.yml     # new: the four-job CI gate
.editorconfig                # new: 2-space + whitespace/newline conventions (shfmt reads it)
.shellcheckrc                # new (if needed): external-sources=true for sourced lib.sh
AGENTS.md                    # new: contributor/agent guide
CLAUDE.md                    # new: symlink → AGENTS.md
tests/run.sh                 # new: test runner/entrypoint
tests/lib.sh                 # new: shared assertions + stubs
tests/test_read.sh           # new
tests/test_context.sh        # new
tests/test_eval.sh           # new
tests/test_dispatch.sh       # new
tests/test_print.sh          # new
tests/test_shai.sh           # new
tests/conventions.sh         # new: standards/hygiene checker
tests/tests.sh               # removed (content ported into the files above)
README.md                    # changed: test command → ./tests/run.sh; CI status badge
shai, shai-read, …           # changed only as needed to pass shellcheck + shfmt
```

## Out of scope (deferred)

- **kcov coverage measurement** and **bats/shunit2** — decided against.
- **macOS / multi-bash-version matrix** — portability isn't a stated goal.
- **Optional extra (skipped unless requested):** a `git pre-push` hook mirroring the four
  CI checks locally.

## Definition of done

1. `./tests/run.sh` passes fully offline (stubbed `curl` + `gh`); every per-script suite
   is green.
2. Every behavior in the coverage-by-design matrix has a corresponding named test.
3. `shellcheck` is clean on all repo shell scripts.
4. `shfmt -d` reports no diff on all repo shell scripts.
5. `./tests/conventions.sh` passes.
6. `.github/workflows/ci.yml` runs the four jobs on `push` and `pull_request`, and all
   four are green on a real push.
7. `README.md` reflects the new test entrypoint and shows the CI status badge.
8. `AGENTS.md` exists and documents architecture, conventions, and local checks;
   `CLAUDE.md` is a committed symlink to it.
