# Top-Level Script Gap Analysis

Date: 2026-08-27

## Context

An audit of shai's top-level script surface area against best practices for a
Unix-philosophy CLI tool suite of this maturity. The project currently has 22
top-level scripts, 8 workflows, and 11 tool plugins. This document identifies
gaps across new features, observability, and maintenance.

## Current Inventory

| Category | Scripts |
|----------|---------|
| Pipeline core | `shai-read`, `shai-context`, `shai-eval`, `shai-dispatch`, `shai-loop`, `shai-print`, `shai-stamp` |
| REPL + retry | `shai-repl`, `shai-retry` |
| Observability | `shai-sessions`, `shai-runs`, `shai-trace`, `shai-stats`, `shai-failures`, `shai-ledgers` |
| Infrastructure | `shai-doctor`, `shai-version`, `shai-tools`, `shai-prompt`, `shai-workflow`, `shai-supervise`, `shai-prune` |

## New Features

### `shai-ask` — non-interactive one-shot mode

The biggest Unix-philosophy gap. Currently, scripting shai means hand-piping
`shai-read | shai-context | shai-eval | shai-print`, and that loses the tool
dispatch loop entirely. `shai-ask "summarize this PR"` (or
`echo "..." | shai-ask`) would run the full pipeline — including tool dispatch —
and print just the answer to stdout.

`shai-repl` is for humans; `shai-ask` is for scripts, cron jobs, and pipes.

### `shai-completions` — shell tab completion (zsh/bash)

22 scripts, 8 workflows, per-command flags, session/run IDs, workflow names —
this is a lot of surface area to remember. Tab completion is standard practice
for any CLI tool suite of this size.

`shai-completions zsh` / `shai-completions bash` would emit the completion
script (eval'd in `.zshrc` / `.bashrc`), with dynamic completion for session
IDs, run IDs, workflow names, and tool names.

### `shai-config` — programmatic configuration management

Policy rules and CI checks are hand-edited JSON. `shai-config` would replace
error-prone JSON editing with validated commands:

- `shai-config policy list|add|remove|test` — manage permission rules
- `shai-config ci list|add|remove` — manage CI check definitions
- `shai-config policy test gh 'pr merge ...'` — dry-run the policy engine
  against a hypothetical tool call (useful for debugging "why was this denied?")

### `shai-update` — self-update

`install.sh` exists but there's no upgrade path. `shai-update` would check for
newer releases, show what changed (release notes), and upgrade in place.
Especially relevant since `shai-supervise` timers run unattended — a stale
install with a breaking API change silently fails.

## Observability

### `shai-tail` — live event stream

`shai-supervise logs` tails the systemd journal, but there's no way to watch
events flowing through the pipeline in real time with human-readable formatting.

`shai-tail [--session ID]` would follow the active session log (or the most
recent one), piping each new event through `shai-print` as it arrives. The
difference from `tail -f` on the JSONL: event-aware formatting, optional
filtering by event type.

### `shai-events` — event query across sessions

"Show me every `tool_error` from the last week." "Find all runs that called the
`gh` tool." Currently that requires manual `jq` over JSONL files.

`shai-events --type tool_result --after 2026-08-20 --json` would be the
structured query interface the observability suite is missing. The existing
scripts query by run or session — this queries by event.

## Maintenance

### `shai-fsck` — state integrity validation

`shai-doctor` checks the environment (tools on PATH, env vars, config files).
Nothing checks the state. `shai-fsck` would validate SHAI_HOME:

- Malformed JSONL lines
- Orphaned run directories with no matching session
- Schema version parsability
- Corrupt request/response dumps

Doctor checks your tools, fsck checks your data. Standard practice for any
system with append-only state files.

### `shai-migrate` — schema migration

The event schema carries `version: "1.0"` but there's no migration tooling.
When the schema eventually changes, old session logs become unreadable or
misinterpreted.

`shai-migrate [--dry-run]` would detect schema versions and apply transforms
in place. The framework should exist before the first breaking change —
retrofitting migrations is always harder.

## Deliberately Excluded

- **Auto-retention** — `shai-prune` already exists; a cron wrapper is trivial.
- **Notifications/alerting** — belongs in the workflow layer, not a top-level
  script.
- **`shai-backup`** — `cp -r` on SHAI_HOME is sufficient for append-only JSONL.
