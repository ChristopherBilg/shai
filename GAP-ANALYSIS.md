# shai — Design-vs-Implementation Gap Analysis

_Working notes, generated 2026-07-27; updated 2026-07-28 as the first three partials landed. Tracked in-repo._

**Design reference:** `AI-Assistant-Unix-Philosophy-Design.md` (the origin Gemini conversation; uses `pa-*` naming, implemented as `shai-*`).
**Method:** every concrete proposal in the design doc, classified against the current scripts (`shai`, `shai-read`, `shai-context`, `shai-eval`, `shai-dispatch`, `shai-print`, `tools.json`).

**Legend:** ✅ done · ⚠️ partial · ❌ not started

---

## ✅ Done — core pipeline & the "day-one" architectural choices

- **Append-only JSONL state** — `~/.shai/history.jsonl` (+ `latest.json`). Design choice #1 ("State Storage Format").
- **The 5 filters** — `shai-read → shai-context → shai-eval → shai-dispatch → shai-print`, each a pure stdin→stdout filter, plus the `shai` REPL/orchestrator and the re-eval/dispatch loop (`shai:46`).
- **Naive context truncation** — last N user turns (default 10) in `shai-context`. This is exactly design choice #2's *recommended starting point* ("start with naive truncation… isolate this logic entirely inside `pa-context`").
- **Tool-output truncation** — `MAX_BYTES=8000` in `shai-dispatch`. Design choice #4 ("force all local command outputs through a strict truncator").
- **Synchronous / blocking execution** — design choice #5's explicit v1.0 recommendation.
- **Read-only tools** — `gh_pr_view`, `gh_issue_view`, `list_directory`, `print_file` (`tools.json` + `run_tool` in `shai-dispatch`).
- **Loop-safe error handling** — every API/curl/parse failure becomes an `error` event with exit 0; `error` events are dropped in `shai-context` so failures never contaminate future context. (One slice of the design's "Resumability & Error Handling".)
- **Per-tool timeouts** — `timeout` wraps tool execution in `shai-dispatch`. (One slice of the design's concurrency "hard timeouts on network-bound tools".)
- **Context-contamination boundaries** (design "Operational reality #3") — `shai-read --external <source>` and `shai-dispatch` fence untrusted content in `<external_data source="…">…</external_data>`, sanitizing the source label and neutralizing injected `</external_data>` so the fence can't be escaped; the system prompt (`shai:13`) teaches the convention. *(done 2026-07-28)*
- **Always-on request observability** (design "Operational reality #2") — `shai-eval` best-effort dumps the exact finalized request to `$SHAI_HOME/last_request.json` before every real call. *(done 2026-07-28)*
- **Resumability** (design "Operational reality #4") — `shai-retry` classifies the history tail and resumes an interrupted run (dispatch a dangling tool_use, or re-eval after an error / tool_result / user turn) without re-prompting. *(done 2026-07-28)*

---

## ⚠️ Partial — started, but not to the doc's spec

- **Model agnosticism** (design extensibility pillar #2) — *the lone remaining partial; a true multi-provider adapter is split into its own spec.*
  - Have: `SHAI_MODEL` env var swaps the model (`shai-eval`).
  - Missing: it only swaps *Anthropic* models — `shai-eval` is hardwired to the Anthropic URL/headers/response shape. No adapter layer for Ollama / other providers.

---

## ❌ Not started — grouped by the design doc's sections

### Edge cases (§ "The Edge Cases")
- **Token-aware context** — a real tokenizer (Python/Rust `tiktoken`-style) replacing turn-count truncation, to preserve system prompt + latest request while dropping least-relevant history.
- **Streaming** — buffering mid-stream tool calls; streamed responses. (Current pipeline is fully buffered/non-streaming.)

### Architectural choices (§ 2nd exchange)
- **Router topology** — a fast Haiku classifier that routes input to a mode-specific system prompt + tool subset, instead of one monolith prompt loading every tool every time.

### Extensibility (§ 3rd exchange)
- **MCP** — stdio MCP servers discovered/attached dynamically instead of hardcoded `run_tool` cases.
- **Input "translators"** — separate single-purpose scripts converting PDF / image / web page → markdown or base64 text before piping into `shai-read`.
- **"Tee" middleware hooks** — the split-the-stream pattern exposed as a real extension point (local analytics DB, embeddings, RAG) grafted onto the pipeline without touching the core loop. (`shai` uses `tee` internally, but not as a user-facing hook.)

### Operational realities (§ 4th exchange)
- **Execution permission matrix + write tools** — the "`rm -rf` problem": read ops auto-approved; write/execute ops pause the pipeline, render the proposed command, and require `Y`/Enter via `/dev/tty`. Today every tool is read-only, so the gate does not exist yet.

### Concurrency (§ 5th exchange — the entire section is open)
- **Standard execution envelope** — wrap every payload in `{version, meta:{run_id, session_id, parent_span_id, span_id, timestamp, source}, payload}`.
- **Partitioned storage** — replace the single global log with `sessions/<session_id>.jsonl` (finalized turns) + `runs/<run_id>.jsonl` (raw intermediate trace).
- **Env-var context propagation** — `SHAI_SESSION_ID` / `SHAI_RUN_ID` / `SHAI_SCHEMA_VERSION` set at the root wrapper, inherited by child filters.
- **`flock` atomic appends** — guard history writes against interleaving when payloads exceed `PIPE_BUF` (~4KB).
- **Idempotent, non-destructive retries** — replay a failed run into a new `run_id`, only committing to the session log on full success.
- **Process supervision** — run background/polling workflows under `systemd --user` / `launchd` / `supervisord` to avoid orphan/zombie processes.

---

## Toolchain integrations (the design doc's mapping table)

| Category | Tools | Status | Notes |
|---|---|---|---|
| Native Terminal | GitHub (`gh`) | ✅ | `gh_pr_view`, `gh_issue_view` |
| Native Terminal | Neovim | ❌ | pipe buffer selections in/out (`:'<,'>w !shai-read`, print back into buffer) |
| Native Terminal | Jira | ❌ | `jira-cli` as input source + dispatch tool |
| Structured SaaS | Notion | ❌ | needs a translation layer (`notion-to-md`) |
| Event-Driven Comms | Outlook, MS Teams | ❌ | push→pull bridge: cron/webhook polling MS Graph, appending as system events |
| Canvas / Spatial | Figma, Miro | ❌ | doc itself flags these as optional / resistant to text pipes |

---

## Note on scope

`CLAUDE.md`'s "Deferred beyond the MVP" line names four headliners — **streaming, write tools + permission gate, concurrency, MCP**. The design doc's real surface is larger. As of 2026-07-28, three former ⚠️ partials are ✅ done (XML `<external_data>` tagging, always-on `last_request.json` observability, `shai-retry` resumability); **model agnosticism** is the lone remaining partial, its true multi-provider adapter deferred to its own spec.
