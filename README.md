# shai — AI assistant the Unix way

[![CI](https://github.com/ChristopherBilg/shai/actions/workflows/ci.yml/badge.svg)](https://github.com/ChristopherBilg/shai/actions/workflows/ci.yml)

Framework-free, terminal-native AI assistant: small shell scripts (`bash`, `curl`, `jq`) over an append-only JSONL history, calling the Anthropic Claude API. A fresh build in the spirit of [llayer](https://github.com/ChristopherBilg/llayer).

## Requirements
- `bash`, `curl`, `jq`
- `gh` CLI, authenticated: `gh auth login`
- `export ANTHROPIC_API_KEY=sk-ant-...`

## Install

```shell
gh api repos/ChristopherBilg/shai/contents/install.sh --jq '.content' | base64 -d | bash
```

Requires `gh` CLI, authenticated (`gh auth login`). Installs to `~/.local/share/shai/<version>/` with wrappers in `~/.local/bin/`. Upgrade by re-running. Rollback: `export SHAI_VERSION=v2026.08.10 && gh api ... | base64 -d | bash`.

Check your version: `shai-version`

## Quick start
```shell
export ANTHROPIC_API_KEY=sk-ant-...
./shai-repl
> summarize PR 123 in owner/repo
> what's in ./README.md
> exit
```

State lives in `~/.shai/`: `sessions/<session_id>.jsonl` (per-session append-only logs), `sessions/<session_id>.latest.json` (the most recent event), and `runs/<run_id>/` holding a per-turn `events.jsonl`, a `<span_id>-request.json` for each API call, and a `<span_id>-response.json` for each successful response. Rewind the assistant's memory by slicing the log, e.g. `head -n 20 ~/.shai/sessions/<session_id>.jsonl` or truncating the file.

## Composability
Every stage is a filter, so you can run the pipeline by hand:
```shell
gh pr view 123 | ./shai-read | ./shai-context | ./shai-eval | ./shai-print
```

## Tools
- `gh` — run any GitHub CLI (gh) command via a pre-tokenized argument array (write, requires approval)
- `jira_issue_view` — view a Jira issue (read-only)
- `list_directory` — list the files and folders in a local directory (read-only)
- `print_file` — print the contents of a local file, with optional `line_numbers` prefixes and an inclusive `start_line`/`end_line` range so `file:line` anchors need no hand counting and files larger than the output cap can be paged (read-only)
- `search_files` — search for a text pattern across files in a directory tree; returns `path:line_number: text` rows plus a `[truncated: showing first N matches]` marker when the cap is hit; supports `glob`, `ignore_case`, and `max_results`; skips binary files and `.git/` (read-only)
- `sleep` — pause execution for a specified number of seconds, 1-300 (read-only)
- `ci` — run a configured CI check for a repository; checks are defined in `$SHAI_HOME/ci.json` (start from [`ci.json.example`](ci.json.example) — see [Configuring `ci`](#configuring-ci)) keyed by normalized git remote URL, with an optional `cwd` input to target a checkout other than the current directory (write, requires approval)
- `write_file` — create or overwrite a file with given content, creating parent directories as needed, with an optional `mode` (3-4 octal digits, e.g. `"755"`) so a new file can be made executable; without it an existing file keeps its mode and a new one gets the umask (write, requires approval)
- `patch_file` — replace a unique string in an existing file; the string must appear exactly once (write, requires approval)
- `delete_file` — delete a file; the file must exist and must not be a directory (write, requires approval)
- `git` — run any Git command via a pre-tokenized argument array (write, requires approval)

Each tool is a directory under `tools/<name>/` with a `tool.json` (Anthropic schema) and a `run.sh`. Outputs are capped at 32000 bytes before entering context: over-cap output keeps its first 24000 and last 8000 bytes with an explicit `[truncated: …]` marker in between that reports the exact byte counts retained and elided, so a clipped result is never mistaken for a complete one and trailing exit codes or error tails survive.

### Configuring `ci`

Nothing creates `$SHAI_HOME/ci.json` for you, and `ci` refuses to run anything that is not listed in it, so copy the shipped [`ci.json.example`](ci.json.example) — it already covers this repo's own checks:

```shell
mkdir -p ~/.shai && cp ci.json.example ~/.shai/ci.json
```

Then edit the `repos` map, keyed by normalized git remote URL (no scheme, no credentials, no trailing `.git`), with a `command` (and optional `timeout` in seconds, default 120) per check. The config stays user-owned under `$SHAI_HOME` on purpose: it is never read from a cloned repo, since `command` runs through `bash -c` and repo-local config would be arbitrary code execution. `shai-doctor` reports whether the file exists, parses, and which repo keys it covers — as a warning, never fatal.

## Observability
Inspect sessions, runs, and aggregate metrics from the terminal:
```shell
./shai-sessions                          # list sessions with event/run/token counts
./shai-sessions --recent 5 --json        # last 5 sessions as JSON
./shai-runs --session <id>               # list runs within a session
./shai-runs --failed                     # show only failed runs
./shai-trace <run_id>                    # render a run's full span chain
./shai-trace <run_id> --request span_1   # dump the exact API request for a span
./shai-stats                             # aggregate metrics across all sessions
./shai-stats --after 2026-08-01 --json   # scoped stats as JSON
./shai-ledgers                           # summarize each workflow's idempotency ledger
./shai-ledgers --workflow issue_d        # list one workflow's ledger entries
```

All five scripts accept `--json` for structured output and prefix matching on their ID/name argument (e.g. `shai-trace run_2026` resolves to the full run ID if unambiguous).

`./shai-supervise status [script] [--json]` renders the same style of table for the installed
`systemd --user` timers (UNIT, STATE, LAST, NEXT), and also accepts `--json`.

## Tests
```shell
./tests/run.sh          # all unit + integration suites, fully offline (curl + gh stubbed)
./tests/conventions.sh  # project standards/hygiene checks
```
Linting/formatting use pinned tools fetched by `./tests/install-lint-tools.sh` (into `bin/`):
```shell
./bin/shellcheck install.sh shai-* lib/*.sh workflows/*/run.sh tests/*.sh
./bin/shfmt -d install.sh shai-* lib/*.sh workflows/*/run.sh tests/*.sh
```
CI runs all of the above on every push and pull request.
