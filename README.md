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

Requires `gh` CLI, authenticated (`gh auth login`). Installs to `~/.local/share/shai/<version>/` with wrappers in `~/.local/bin/`. Upgrade by re-running. Rollback: `export SHAI_VERSION=v2026.08.09 && gh api ... | base64 -d | bash`.

Check your version: `shai-repl --version`

## Quick start
```shell
export ANTHROPIC_API_KEY=sk-ant-...
./shai-repl
> summarize PR 123 in owner/repo
> what's in ./README.md
> exit
```

State lives in `~/.shai/`: `sessions/<session_id>.jsonl` (per-session append-only logs), `sessions/<session_id>.latest.json` (the most recent event), and `runs/<run_id>/` holding a per-turn `events.jsonl` plus a `<span_id>-request.json` for each API call in that turn. Rewind the assistant's memory by slicing the log, e.g. `head -n 20 ~/.shai/sessions/<session_id>.jsonl` or truncating the file.

## Composability
Every stage is a filter, so you can run the pipeline by hand:
```shell
gh pr view 123 | ./shai-read | ./shai-context | ./shai-eval | ./shai-print
```

## Tools
- `gh_pr_view` — view a GitHub pull request (read-only)
- `gh_issue_view` — view a GitHub issue (read-only)
- `list_directory` — list the files and folders in a local directory (read-only)
- `print_file` — print the contents of a local file (read-only)
- `write_file` — create or overwrite a file with given content, creating parent directories as needed (write, requires approval)
- `patch_file` — replace a unique string in an existing file; the string must appear exactly once (write, requires approval)

Defined in `tools.json` (Anthropic shape). Outputs are truncated to 32000 bytes before entering context.

## Tests
```shell
./tests/run.sh          # all unit + integration suites, fully offline (curl + gh stubbed)
./tests/conventions.sh  # project standards/hygiene checks
```
Linting/formatting use pinned tools fetched by `./tests/install-lint-tools.sh` (into `bin/`):
```shell
./bin/shellcheck install.sh shai-* tests/*.sh
./bin/shfmt -d install.sh shai-* tests/*.sh
```
CI runs all of the above on every push and pull request.

## Scope
This is an MVP. Design and deferred work (streaming, concurrency, MCP, …) are documented in `AI-Assistant-Unix-Philosophy-Design.md`.
