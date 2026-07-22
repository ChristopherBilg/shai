# shai — a Unix-philosophy AI personal assistant (MVP)

**Status:** Approved design · **Date:** 2026-07-21

## Summary

`shai` ("shell AI") is a framework-free, terminal-native AI personal assistant built
from small, single-purpose shell scripts that communicate over standard text pipes —
the same architecture as [`llayer`](https://github.com/ChristopherBilg/llayer), pointed
at the Anthropic Claude API and at the author's real toolchain.

The MVP delivers **one real workflow, end to end**: from the terminal, ask about a
GitHub PR/issue or a local file, and Claude answers by calling read-only tools through a
synchronous tool-call loop, with every interaction recorded in an append-only history
file. It proves the architecture is worth adopting as a daily driver before any of the
larger vision (streaming, routing, concurrency, MCP, safety rails) is built.

## Background & references

- **Design conversation:** `AI-Assistant-Unix-Philosophy-Design.md` (a Gemini session
  exploring this system). It proposes the `pa-*` pipeline shape, then layers on a large
  vision — Haiku router, MCP, write-permission gate, request-debug dumps, XML sandboxing,
  and a full concurrency substrate. That vision is an enterprise agent runtime; this MVP
  is the thin slice under it.
- **Reference implementation:** `../llayer` already implements the exact pipeline
  (`ll-read → ll-context → ll-eval → ll-dispatch → ll-print` + an `agent` REPL) against a
  local Ollama server. `shai` is a **fresh build** in this repo that reuses llayer's
  *ideas* (append-only JSONL state, `jq` context reducer, bash dispatch loop) but is
  written from scratch for the Claude Messages API.

## Key decisions

| Decision | Choice | Why |
| :--- | :--- | :--- |
| MVP scope | One real workflow, end to end | Validate the architecture with real tools before investing further |
| Model backend | Anthropic Messages API via `curl` | Matches the design; strongest tool use. Auth: `x-api-key: $ANTHROPIC_API_KEY` |
| Default model | `claude-opus-4-8` | Most capable Opus-tier model |
| First tools | GitHub-read (`gh`) + local files, all **read-only** | Author uses `gh` daily; read-only sidesteps a permission gate |
| Starting point | Fresh build in `shai/`, llayer as reference only | Cleaner slate; the API differences (below) make a straight fork awkward anyway |
| Eval mode | **Non-streaming** (one `curl` POST, parse one JSON) | Smallest correct build; avoids SSE + partial-JSON tool reassembly (the doc's flagged hard cases). Streaming is a clean later add. |
| Thinking | Omitted (Opus 4.8 default-off) | Avoids thinking-block echo-back bookkeeping in the tool loop |

### Three deliberate departures from llayer

These are why the MVP is a fresh build rather than a rename of `ll-*`:

1. **`tools.json` uses Anthropic's flat shape** — `{name, description, input_schema}` —
   not llayer's OpenAI-nested `{type:"function", function:{…}}`.
2. **`system` is a separate top-level request parameter**, not a message role — so
   `shai-context` emits `{system, messages}`, and `shai-eval` splices `system` into the
   payload alongside `messages`.
3. **The tool loop pairs on `tool_use_id`** (Anthropic requirement): each `tool_use`
   block's `id` must return as a `tool_result` in the immediately following user turn.

## Architecture

### File inventory (flat repo root, matching llayer)

| File | Role |
| :--- | :--- |
| `shai` | REPL entry: health-check, init, seed system prompt, run the loop |
| `shai-read` | Ingestion: stdin → JSON `message` event → append to history |
| `shai-context` | Reduction: history JSONL → `{system, messages}` (pure `jq`) |
| `shai-eval` | Inference: one `curl` POST to `/v1/messages` → `assistant` event |
| `shai-dispatch` | Action: run `tool_use` blocks → `tool_result` events |
| `shai-print` | Formatting: assistant event → human-readable stdout |
| `tools.json` | Tool definitions in Anthropic shape |
| `tests/tests.sh` | Offline test suite (`curl` + `gh` stubbed) |
| `README.md` | Usage + the "power of pipes" examples |

### State (single global log for the MVP)

```
~/.shai/
├── history.jsonl   # append-only event log — the whole memory
└── latest.json     # the last assistant turn, for the dispatch loop
```

Home-dir state (not cwd) because `shai` is a personal assistant invoked from anywhere;
the `gh`/file tools still operate on the current working directory. Rewind memory with
`head`/`sed` on `history.jsonl`. Session partitioning is deferred (see Non-goals).

### Data flow

Each script is a standalone filter; `shai` chains them into a read→eval→dispatch→print
loop:

```
   you ──▶ shai-read ──▶ history.jsonl
                              │
                    shai-context (jq: window + normalize)
                              │  {system, messages}
                              ▼
                         shai-eval ──HTTP──▶ Claude Messages API
                              │  assistant event (text + tool_use)
                    ┌─────────┼──────────┐
                    ▼         ▼           ▼
              history.jsonl  latest.json  shai-print ──▶ you
                              │
                    shai-dispatch (runs tools) ──▶ tool_result ──▶ history.jsonl
                              │
              exit 1 = tools ran → loop back to shai-context
              exit 0 = no tools  → turn done
```

One-shot composability is preserved because every stage is a filter:

```shell
gh pr view 123 | shai-read | shai-context | shai-eval | shai-print
```

## Event schema

One JSON object per line in `history.jsonl`:

```json
{"type":"message","source":"system","payload":{"text":"You are shai, a terminal assistant…"}}
{"type":"message","source":"user","payload":{"text":"summarize PR 123 in owner/repo"}}
{"type":"message","source":"assistant","payload":{"content":[ /* raw Anthropic content blocks */ ],"stop_reason":"tool_use"}}
{"type":"tool_result","source":"tool","payload":{"tool_use_id":"toolu_…","content":"…","is_error":false}}
{"type":"error","source":"system","payload":{"text":"…"}}
```

The assistant event stores the **whole `content` array verbatim**, so it echoes back into
the next request unchanged and `shai-print` simply reads the `text` blocks. There are no
token events and no reconstruction step — the payoff of the non-streaming choice.

## Component contracts

### `shai-read`
- **In:** text on stdin; optional `--system` flag.
- **Out:** one `message` event (`source` = `user`, or `system` with the flag).
- **Behavior:** wrap-only, via `jq -Rs`. Empty input → no output (exit 0).

### `shai-context`
- **In:** history JSONL on stdin; optional `--window N` (default 10 user turns).
- **Out:** one JSON object `{ "system": "<text>", "messages": [ … ] }`.
- **Behavior (pure `jq`):**
  - `system` = concatenation of all `type:"message", source:"system"` payload texts.
  - Window: keep every non-system event from the most recent **N user turns** onward
    (slice at the Nth-from-last `user` message). Slicing on a user boundary guarantees the
    `messages` array starts with a `user` turn and never orphans a `tool_use`/`tool_result`.
  - Map each event in order:
    - user `message` → `{ "role":"user", "content": "<text>" }`
    - assistant `message` → `{ "role":"assistant", "content": <stored content array> }`
    - run of consecutive `tool_result` events → one
      `{ "role":"user", "content": [ { "type":"tool_result", "tool_use_id":…, "content":…, "is_error":… } … ] }`
      placed immediately after the assistant turn that requested them.
  - Skip malformed lines (`try fromjson catch null`).

### `shai-eval`
- **In:** `{system, messages}` on stdin. Flags: `--tools`, `--model <id>`,
  `--max-tokens <n>`, `--dry-run`, `--health-check`.
- **Out:** one `assistant` event, or an `error` event on failure.
- **Behavior:**
  - Defaults: `model=claude-opus-4-8`, `max_tokens=16000`. `thinking` omitted.
  - `--health-check`: verify `ANTHROPIC_API_KEY` is set; exit non-zero with a clear
    message if not. (`shai` calls this on startup.)
  - Build payload with `jq`:
    `{ model, max_tokens, system, messages, tools? }` (tools included only with `--tools`,
    read from `tools.json`).
  - `--dry-run`: print the payload and exit (offline-testable).
  - POST to `https://api.anthropic.com/v1/messages` with headers
    `content-type: application/json`, `x-api-key: $ANTHROPIC_API_KEY`,
    `anthropic-version: 2023-06-01`. No `stream`. `curl --max-time 120`, capturing HTTP
    status separately.
  - Non-2xx, or a body with `.type=="error"` → emit
    `{type:"error", source:"system", payload:{text: <.error.message>}}`.
  - 2xx → emit
    `{type:"message", source:"assistant", payload:{content: .content, stop_reason: .stop_reason}}`.

### `shai-dispatch`
- **In:** assistant event(s) on stdin (the `shai` loop feeds it `latest.json`).
- **Out:** one `tool_result` event per `tool_use` block. **Exit 1** if any tool ran (loop
  continues), **exit 0** if none (turn done). This exit-code contract is copied from
  `ll-dispatch`.
- **Behavior:**
  - Extract `.payload.content[] | select(.type=="tool_use")` → `{id, name, input}`.
  - Dispatch on `name`; run the tool; capture stdout+stderr; truncate `head -c 8000`.
  - `gh` calls wrapped in `timeout 30s`.
  - Emit
    `{type:"tool_result", source:"tool", payload:{tool_use_id:id, content:output, is_error:bool}}`.
    Tool failure or unknown tool → `is_error:true` with the error text (keeps the loop
    alive so Claude can recover).

### `shai-print`
- **In:** events on stdin; optional `--debug`.
- **Out:** human text — assistant `text` blocks; `error` events as `Error: …`.
- **Behavior:** default prints only assistant text; `--debug` also shows `tool_use` /
  `tool_result`. Plain stdout for the MVP (no `glow`/`bat` dependency).

### `shai` (entry / REPL)
- Run `shai-eval --health-check`; create `~/.shai/` if missing; if `history.jsonl` is
  empty, seed a default `system` message via `shai-read --system`.
- Loop: read a prompt → `shai-read >> history` → `shai-context | shai-eval | tee -a
  history | tee latest.json | shai-print` → then `until shai-dispatch < latest.json >>
  history` returns 0, re-run `shai-context | shai-eval | …`. Mirrors llayer's `agent`.

## `tools.json` and the tool set

Anthropic flat shape (array of `{name, description, input_schema}`). All tools are
read-only, so no permission gate is required for the MVP.

| Tool | Runs | Required input | Optional |
| :--- | :--- | :--- | :--- |
| `gh_pr_view` | `gh pr view <number> [--repo <r>]` | `number` | `repo` |
| `gh_issue_view` | `gh issue view <number> [--repo <r>]` | `number` | `repo` |
| `list_directory` | `ls -1 -- <path>` | `path` | — |
| `print_file` | `cat -- <path>` | `path` | — |

Every tool output passes through `head -c 8000` before becoming a `tool_result`, so a
large PR or file cannot blow out the context window.

## Error handling

- All scripts use `set -euo pipefail`.
- **Auth:** missing `ANTHROPIC_API_KEY` fails fast in `shai-eval` (and is what
  `--health-check` guards on startup).
- **API:** HTTP non-2xx or `.type=="error"` → `error` event carrying Anthropic's message;
  `stop_reason:"refusal"` → short printed note; `max_tokens` → truncation note.
  `curl --max-time 120` prevents a hung request from wedging the REPL.
- **Tools:** failures / unknown tool → `tool_result` with `is_error:true`; `gh` wrapped in
  `timeout 30s`.
- **Parsing:** `shai-context` skips malformed lines (`try fromjson catch null`).

## Testing

Extend llayer's harness: a single `tests/tests.sh` with an `assert_contains` helper.
Stub `curl` (for `shai-eval`) and `gh` (for `shai-dispatch`) via a PATH-prepended
fake-bin directory, so the suite is **fully offline and spends no API credits**.

Coverage:

- `shai-read`: envelope + payload text + `--system` source.
- `shai-context`: system texts → `system` field; user/assistant mapping; `tool_result`
  folded into a user turn with the correct `tool_use_id`; window trimming on a user
  boundary.
- `shai-eval`: `--dry-run` payload shape (model, max_tokens, system, messages, tools);
  missing-key error; stubbed-`curl` 200 → assistant event; stubbed error body → error
  event.
- `shai-dispatch`: no `tool_use` → exit 0; `tool_use` → runs stubbed `gh` → `tool_result`
  + exit 1; output truncation; unknown tool → `is_error`.
- `shai-print`: text extraction; `error` formatting.

## Non-goals (deferred)

Named explicitly so scope is unambiguous. `↳` marks a trivial later add.

- Streaming / live token print ↳ additive to `shai-eval` + `shai-print`.
- Write/execute tools + a `/dev/tty` `Y/N` permission gate — **required before any
  mutating tool**.
- Debug request dump `~/.shai/last_request.json` ↳ one `tee` line in `shai-eval`.
- XML-sandboxing of external/tool data against prompt injection.
- Haiku router / per-mode tool loading; MCP servers.
- Concurrency substrate: metadata envelope (`run_id`/`session_id`/`span_id`),
  session-partitioned storage, `flock`, non-destructive retries, process supervision.
- Token-aware context truncation (real tokenizer) — replaces naive last-N windowing when
  Jira epics / large diffs get huge.
- Adaptive thinking (needs thinking-block echo-back); model-agnostic adapter (Ollama
  fallback); input translators (PDF/web → text); `tee` middleware hooks.

## Definition of done

1. `./tests/tests.sh` passes (offline, stubbed `curl` + `gh`).
2. `echo "hi" | ./shai-read | ./shai-context | ./shai-eval | ./shai-print` returns a
   Claude reply in the terminal.
3. From `./shai`, a prompt like *"summarize PR 123 in owner/repo"* drives at least one
   `gh_pr_view` tool call and prints a useful summary, with the full exchange recorded in
   `~/.shai/history.jsonl`.
4. A read-only local-file prompt (e.g. *"what's in ./README.md"*) drives a `print_file`
   or `list_directory` call and answers.
5. `README.md` documents setup (`ANTHROPIC_API_KEY`, `gh auth`) and the composable-pipe
   examples.
