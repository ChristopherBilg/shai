# shai — AI assistant the Unix way

[![CI](https://github.com/ChristopherBilg/shai/actions/workflows/ci.yml/badge.svg)](https://github.com/ChristopherBilg/shai/actions/workflows/ci.yml)

Framework-free, terminal-native AI assistant: small shell scripts (`bash`, `curl`, `jq`) over an append-only JSONL history, calling the Anthropic Claude API. A fresh build in the spirit of [llayer](https://github.com/ChristopherBilg/llayer).

## Requirements
- `bash`, `curl`, `jq`
- `gh` CLI, authenticated: `gh auth login`
- `export ANTHROPIC_API_KEY=sk-ant-...`

## Quick start
```shell
export ANTHROPIC_API_KEY=sk-ant-...
./shai
> summarize PR 123 in owner/repo
> what's in ./README.md
> exit
```

State lives in `~/.shai/`: `sessions/<session_id>.jsonl` (per-session append-only logs), `latest.json` (the most recent event), `last_request.json` (the most recent API request), and `runs/<run_id>/` holding a per-turn `events.jsonl` plus a `<span_id>-request.json` for each API call in that turn. Rewind the assistant's memory by slicing the log, e.g. `head -n 20 ~/.shai/sessions/<session_id>.jsonl` or truncating the file.

## Composability
Every stage is a filter, so you can run the pipeline by hand:
```shell
gh pr view 123 | ./shai-read | ./shai-context | ./shai-eval | ./shai-print
```

## Tools (read-only)
`gh_pr_view`, `gh_issue_view`, `list_directory`, `print_file`. Defined in `tools.json` (Anthropic shape). Outputs are truncated to 8000 bytes before entering context.

## Tests
```shell
./tests/run.sh          # all unit + integration suites, fully offline (curl + gh stubbed)
./tests/conventions.sh  # project standards/hygiene checks
```
Linting/formatting use pinned tools fetched by `./tests/install-lint-tools.sh` (into `bin/`):
```shell
./bin/shellcheck shai shai-* tests/*.sh
./bin/shfmt -d shai shai-* tests/*.sh
```
CI runs all of the above on every push and pull request.

## Scope
This is an MVP. Design and deferred work (streaming, write tools + permission gate, concurrency, MCP, …) are documented in `AI-Assistant-Unix-Philosophy-Design.md`.
