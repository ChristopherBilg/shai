# Top-Level Script Gap Analysis

Date: 2026-08-27

## Context

An audit of shai's top-level script surface area against best practices for a
Unix-philosophy CLI tool suite of this maturity. The project currently has 27
top-level scripts, 9 workflows, and 11 tool plugins. This document identifies
gaps across new features, observability, and maintenance.

## Current Inventory

| Category | Scripts |
|----------|---------|
| Pipeline core | `shai-read`, `shai-context`, `shai-eval`, `shai-dispatch`, `shai-loop`, `shai-print`, `shai-stamp`, `shai-ask` |
| REPL + retry | `shai-repl`, `shai-retry` |
| Observability | `shai-sessions`, `shai-runs`, `shai-events`, `shai-trace`, `shai-stats`, `shai-failures`, `shai-ledgers` |
| Infrastructure | `shai-doctor`, `shai-version`, `shai-update`, `shai-tools`, `shai-prompt`, `shai-workflow`, `shai-supervise`, `shai-prune`, `shai-completions`, `shai-config` |

## New Features

### `shai-ask` — non-interactive one-shot mode

**Implemented** — `shai-ask` is now a top-level script (see #315), closing the
biggest Unix-philosophy gap: `shai-ask "summarize this PR"` (or
`echo "..." | shai-ask`) runs the full pipeline — including tool dispatch —
and prints just the answer to stdout. Before it existed, scripting shai meant
hand-piping `shai-read | shai-context | shai-eval | shai-print`, which lost the
tool dispatch loop entirely.

`shai-repl` is for humans; `shai-ask` is for scripts, cron jobs, and pipes.

### `shai-completions` — shell tab completion (zsh/bash)

**Implemented** — `shai-completions generate zsh|bash` emits a self-contained
completion script from the manifest (`completions.json`), with dynamic
completion for session IDs, run IDs, workflow names, and tool names (see #319),
and `shai-completions install zsh|bash` writes it to the standard user-local
location (`~/.local/share/zsh/site-functions/_shai` and
`~/.local/share/bash-completion/completions/shai`), creating the target
directory if needed (see #321). `install.sh` runs both installs on every
release install, and `shai-doctor` reports whether the files are present — a
warning, never an error. The generated files are checked in
(`completions/_shai`, `completions/shai.bash`) and kept byte-identical to
`generate` output by `tests/test_completions.sh`. `shai-completions check`
(see #320) is the fail-closed gate behind that freshness: every git-tracked
`shai-*` script must have a manifest entry, every parsed `--flag` must be
declared in it, and `generate` must reproduce the checked-in files byte for
byte — the `completions` CI job runs it on every push.

### `shai-config` — programmatic configuration management

**Implemented** — `shai-config` is now a top-level script (see #343, #344, #345,
#346, and #347), replacing error-prone JSON editing of policy rules and CI
checks with validated commands: `shai-config policy list|add|remove|test`
manages permission rules in `$SHAI_HOME/policy.json`, and
`shai-config ci list|add|remove` manages CI check definitions in
`$SHAI_HOME/ci.json`. The "why was this denied?" debugging use case for
`policy test` is mostly covered elsewhere — #294 logs
`policy: <action> <tool> (<reason>)` with `rule:<file>:<idx>` for every real
call — so `test`'s remaining value is the *hypothetical* dry-run: it evaluates
one would-be call through the same `check_policy` the dispatcher uses, without
executing anything. The larger value of the script is **validated writes**: a
malformed `policy.json` silently discards every rule, and a mis-keyed `ci.json`
entry is silently never found, so `shai-config` parses a config before writing
it and aborts on a corrupt file rather than replacing it, and CI entries are
keyed with the same `normalize_url` the `ci` tool looks them up by — a
mis-keyed entry cannot be written.

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

**Implemented** — `shai-events` is now a top-level script (see #326), closing
the event-level axis of the observability suite: "show me every `tool_result`
from the last week" and "find every event that called the `gh` tool" no longer
require manual `jq` over JSONL files. `shai-events --type tool_result --after
2026-08-20 --json` returns the matches as a JSON array of the full, unmodified
event objects; without `--json` each match is one human-readable row
(`TIMESTAMP TYPE SOURCE SUMMARY`, summary truncated to 80 chars, tool calls
rendered as `name(...)`). All flags — `--type`, `--source`, `--tool`,
`--session`, `--run`, `--after`/`--before` (inclusive dates), `--recent N` —
are optional and AND-combinable; malformed lines are skipped with a warning;
empty results exit 0. The existing scripts query by session, run, span, or
aggregate — this queries by event.

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
