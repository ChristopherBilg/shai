# shai — AI assistant the Unix way

[![CI](https://github.com/ChristopherBilg/shai/actions/workflows/ci.yml/badge.svg)](https://github.com/ChristopherBilg/shai/actions/workflows/ci.yml)

Framework-free, terminal-native AI assistant: small shell scripts (`bash`, `curl`, `jq`) over an append-only JSONL history, calling an OpenAI-compatible chat-completions API. A fresh build in the spirit of [llayer](https://github.com/ChristopherBilg/llayer).

## Requirements
- `bash`, `curl`, `jq`
- `gh` CLI, authenticated: `gh auth login`
- `export SHAI_API_KEY=sk-...`
- `export SHAI_API_URL=https://api.example.com/v1/chat/completions`
- `export SHAI_MODEL=<model-name>`

## Install

```shell
gh api repos/ChristopherBilg/shai/contents/install.sh --jq '.content' | base64 -d | bash
```

Requires `gh` CLI, authenticated (`gh auth login`). Installs to `~/.local/share/shai/<version>/` with wrappers in `~/.local/bin/`; `~/.local/share/shai/current` always points at the active version. Upgrade by re-running (it re-points `current`); supervised timers then migrate with one `shai-supervise repoint --all`, which rewrites each unit's `ExecStart=` to the new version path and preserves a customized interval — `repoint` only ever touches `ExecStart=`. A unit installed before `SHAI_API_KEY`/`SHAI_API_URL`/`SHAI_MODEL` existed still carries its old `Environment=` lines (or none at all), so `repoint` cannot migrate it: run `shai-supervise uninstall <script>` followed by `shai-supervise install <script>` (re-passing `--interval` if customized) instead. Rollback: `export SHAI_VERSION=v2026.08.10 && gh api ... | base64 -d | bash`.

Check your version: `shai-version`

## Quick start
```shell
export SHAI_API_KEY=sk-...
export SHAI_API_URL=https://api.example.com/v1/chat/completions
export SHAI_MODEL=<model-name>
./shai-repl
> summarize PR 123 in owner/repo
> what's in ./README.md
> exit
```

`shai-repl` is for humans. For scripts, cron jobs, and pipes, `shai-ask` runs the same full
pipeline (tools included) once and prints just the answer:

```shell
./shai-ask "summarize PR 123 in owner/repo"          # prompt as arguments
echo "explain this repo" | ./shai-ask                # prompt from stdin
cat diff.txt | ./shai-ask --external gh-diff "review this"   # stdin as fenced external data
./shai-ask --no-tools "pure Q&A"                     # disable tool dispatch
./shai-ask -q "quiet mode"                           # hide tool dispatch markers
```

State lives in `~/.shai/`: `sessions/<session_id>.jsonl` (per-session append-only logs), `sessions/<session_id>.latest.json` (the most recent event), and `runs/<run_id>/` holding a per-turn `events.jsonl`, a `<span_id>-request.json` for each API call, and a `<span_id>-response.json` for each successful response. Rewind the assistant's memory by slicing the log, e.g. `head -n 20 ~/.shai/sessions/<session_id>.jsonl` or truncating the file.

## Composability
Every stage is a filter, so you can run the pipeline by hand:
```shell
gh pr view 123 | ./shai-read | ./shai-context | ./shai-eval | ./shai-print
```

## Tools
- `gh` — run any GitHub CLI (gh) command via a pre-tokenized argument array (write, requires approval)
- `jira` — run any Jira CLI (jira) command via a pre-tokenized argument array (write, requires approval)
- `list_directory` — list the files and folders in a local directory (read-only)
- `print_file` — print the contents of a local file, with optional `line_numbers` prefixes and an inclusive `start_line`/`end_line` range so `file:line` anchors need no hand counting and files larger than the output cap can be paged (read-only)
- `search_files` — search for a text pattern across files in a directory tree; returns `path:line_number: text` rows plus a `[truncated: showing first N matches]` marker when the cap is hit; supports `glob`, `ignore_case`, `literal`, and `max_results`; the pattern is grep extended regex, so `|` alternates and the other metacharacters `+ ? ( ) { } [ ] . * ^ $` must be backslash-escaped for a literal match (e.g. `C\+\+`) — or set `literal: true` for exact-string matching with no escaping; skips binary files and default-excluded paths (`.git`, `.ssh`, `.env`, `node_modules`, …); a zero-match pattern containing regex metacharacters gets a `[note: 0 matches …]` line so an empty result is never silently misread (read-only)
- `sleep` — pause execution for a specified number of seconds, 1-300 (read-only)
- `ci` — run a configured CI check for a repository; checks are defined in `$SHAI_HOME/ci.json` (start from [`ci.json.example`](ci.json.example) — see [Configuring `ci`](#configuring-ci)) keyed by normalized git remote URL, with an optional `cwd` input to target a checkout other than the current directory (write, requires approval)
- `write_file` — create or overwrite a file with given content, creating parent directories as needed, with an optional `mode` (3-4 octal digits, e.g. `"755"`) so a new file can be made executable; without it an existing file keeps its mode and a new one gets the umask (write, requires approval)
- `patch_file` — replace a unique string in an existing file; the string must appear exactly once (write, requires approval)
- `delete_file` — delete a file; the file must exist and must not be a directory (write, requires approval)
- `git` — run any Git command via a pre-tokenized argument array (write, requires approval)

Each tool is a directory under `tools/<name>/` with a `tool.json` (OpenAI-compatible schema) and a `run.sh`. Outputs are capped at 32000 bytes before entering context: over-cap output keeps its first 24000 and last 8000 bytes with an explicit `[truncated: …]` marker in between that reports the exact byte counts retained and elided, so a clipped result is never mistaken for a complete one and trailing exit codes or error tails survive.

### Configuring `ci`

Nothing creates `$SHAI_HOME/ci.json` for you, and `ci` refuses to run anything that is not listed in it, so copy the shipped [`ci.json.example`](ci.json.example) — it already covers this repo's own checks:

```shell
mkdir -p ~/.shai && cp ci.json.example ~/.shai/ci.json
```

Then edit the `repos` map, keyed by normalized git remote URL (no scheme, no credentials, no trailing `.git`), with a `command` (and optional `timeout` in seconds, default 120) per check. The config stays user-owned under `$SHAI_HOME` on purpose: it is never read from a cloned repo, since `command` runs through `bash -c` and repo-local config would be arbitrary code execution. `shai-doctor` reports whether the file exists, parses, and which repo keys it covers — as a warning, never fatal.

Every `ci` list/run output begins with a `ci-tool: <path>` line naming the `run.sh` that orchestrated it, so when the repo under test is shai itself you can see whether the installed tool or a checkout's tool ran. Pass `tool_dir` (e.g. `/tmp/clone/tools`) to explicitly have that directory's `ci/run.sh` drive the run — the override is only honored when given, never derived from repo content.

## Observability
Inspect sessions, runs, events, and aggregate metrics from the terminal:
```shell
./shai-sessions                          # list sessions with event/run/token counts
./shai-sessions --recent 5 --json        # last 5 sessions as JSON
./shai-runs --session <id>               # list runs within a session
./shai-runs --failed                     # show only failed runs
./shai-runs --failed --after 2026-08-01  # failed runs since a date
./shai-events --type tool_result --after 2026-08-01  # query individual events across sessions
./shai-events --tool gh --json                       # events that called the gh tool, as JSON
./shai-trace <run_id>                    # render a run's full span chain
./shai-trace <run_id> --request span_1   # dump the exact API request for a span
./shai-stats                             # aggregate metrics across all sessions
./shai-stats --after 2026-08-01 --json   # scoped stats as JSON
./shai-ledgers                           # summarize each workflow's idempotency ledger
./shai-ledgers --workflow issue_d        # list one workflow's ledger entries
./shai-failures                          # summarize each workflow's failure records
./shai-failures list --workflow issue_d  # list one workflow's failure records
```

All seven scripts accept `--json` for structured output and prefix matching on their ID/name argument (e.g. `shai-trace run_2026` resolves to the full run ID if unambiguous).

`./shai-supervise status [script] [--json]` renders the same style of table for the installed
`systemd --user` timers (UNIT, STATE, LAST, NEXT, INSTALL), and also accepts `--json`.
The INSTALL column is `ok` / `stale` / `broken` / `--` (no `.service` file, or none with an
`ExecStart=` line): `stale` means the unit's `ExecStart` still points at an older shai install
than the one this command runs from.

## Store health

`shai-fsck` audits the four event stores for internal inconsistencies and reports them as
normalized findings — one row per finding, scoped by store, check, and date:
```shell
./shai-fsck                                # findings table across all four stores
./shai-fsck --store sessions --check S4    # one store, one check
./shai-fsck --after 2026-08-01 --json      # findings as a JSON array ([] when clean)
./shai-fsck --summary                      # only the trailing digest
```

Exit codes: `0` clean, `1` problems found, `2` usage error, `3` the scan could not complete.
`shai-doctor` remains the owner of `policy.json`/`ci.json` validation, and `shai-prune` the
owner of date/category-based deletion — `shai-fsck` only reports, it never deletes.

## Tests
```shell
./tests/run.sh          # all unit + integration suites, fully offline (curl + gh stubbed)
./tests/conventions.sh  # project standards/hygiene checks
```
Linting/formatting use pinned tools fetched by `./tests/install-lint-tools.sh` (into `bin/`):
```shell
./tests/lint.sh          # ShellCheck + shfmt -d, exactly what CI runs
./tests/lint.sh --list   # the file list it lints, derived from git
./tests/lint.sh --write  # shfmt -w instead of -d (rewrite in place)
```
There is no glob to keep in sync: `tests/lint.sh` derives its file list fail-closed from
`git ls-files` (every tracked `*.sh` plus every file with a `#!/bin/bash` shebang), and
`tests/conventions.sh` asserts every runtime script is in it.
CI runs all of the above on every push and pull request.
