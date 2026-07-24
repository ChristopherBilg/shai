# shai — AI assistant the Unix way

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

State lives in `~/.shai/history.jsonl` (append-only). Rewind the assistant's memory by slicing it, e.g. `head -n 20 ~/.shai/history.jsonl` or truncating the file.

## Composability
Every stage is a filter, so you can run the pipeline by hand:
```shell
gh pr view 123 | ./shai-read | ./shai-context | ./shai-eval | ./shai-print
```

## Tools (read-only)
`gh_pr_view`, `gh_issue_view`, `list_directory`, `print_file`. Defined in `tools.json` (Anthropic shape). Outputs are truncated to 8 KB before entering context.

## Tests
```shell
./tests/tests.sh    # fully offline: curl + gh are stubbed
```

## Scope
This is an MVP. Design and deferred work (streaming, write tools + permission gate, concurrency, MCP, …) are documented in `docs/superpowers/specs/2026-07-21-shai-unix-ai-assistant-mvp-design.md`.
