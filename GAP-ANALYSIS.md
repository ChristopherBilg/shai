# shai — Design-vs-Implementation Gap Analysis

_Working notes, generated 2026-07-27; updated 2026-07-28 as the first three partials landed, then
again to record the ordering constraints among the open items; revised 2026-07-29 when the
execution envelope and env-var context propagation shipped. Tracked in-repo._

**Design reference:** `AI-Assistant-Unix-Philosophy-Design.md` (the origin Gemini conversation; uses `pa-*` naming, implemented as `shai-*`).
**Method:** every concrete proposal in the design doc, classified against the current scripts (`shai`, `shai-read`, `shai-context`, `shai-eval`, `shai-dispatch`, `shai-print`, `tools.json`).

**Legend:** ✅ done · ⚠️ partial · ❌ not started

---

## ✅ Done — core pipeline & the "day-one" architectural choices

- **Append-only JSONL state** — `~/.shai/sessions/<session_id>.jsonl` (+ `latest.json`). Design choice #1 ("State Storage Format").
- **The 5 filters** — `shai-read → shai-context → shai-eval → shai-dispatch → shai-print`, each a pure stdin→stdout filter, plus the `shai` REPL/orchestrator and the re-eval/dispatch loop (`shai:96`).
- **Naive context truncation** — last N user turns (default 10) in `shai-context`. This is exactly design choice #2's *recommended starting point* ("start with naive truncation… isolate this logic entirely inside `pa-context`").
- **Tool-output truncation** — `MAX_BYTES=8000` in `shai-dispatch`. Design choice #4 ("force all local command outputs through a strict truncator").
- **Synchronous / blocking execution** — design choice #5's explicit v1.0 recommendation.
- **Read-only tools** — `gh_pr_view`, `gh_issue_view`, `list_directory`, `print_file` (`tools.json` + `run_tool` in `shai-dispatch`).
- **Loop-safe error handling** — every API/curl/parse failure becomes an `error` event with exit 0; `error` events are dropped in `shai-context` so failures never contaminate future context. (One slice of the design's "Resumability & Error Handling".)
- **Per-tool timeouts** — `timeout` wraps tool execution in `shai-dispatch`. (One slice of the design's concurrency "hard timeouts on network-bound tools".)
- **Context-contamination boundaries** (design "Operational reality #3") — `shai-read --external <source>` and `shai-dispatch` fence untrusted content in `<external_data source="…">…</external_data>`, sanitizing the source label and neutralizing injected `</external_data>` so the fence can't be escaped; the system prompt (`shai:16`) teaches the convention. *(done 2026-07-28)*
- **Always-on request observability** (design "Operational reality #2") — `shai-eval` best-effort dumps the exact finalized request to `$SHAI_HOME/runs/<run_id>/<span_id>-request.json` before every real call. *(done 2026-07-28)*
- **Resumability** (design "Operational reality #4") — `shai-retry` classifies the history tail and resumes an interrupted run (dispatch a dangling tool_use, or re-eval after an error / tool_result / user turn) without re-prompting. *(done 2026-07-28)*
- **Standard execution envelope** (design concurrency §1) — every event carries
  `{version, meta:{run_id, session_id, span_id, parent_span_id, timestamp}}`, added by the
  `shai-stamp` filter. Adopted **additively**: `type`/`source` stay top-level, so no reader
  filter's selectors needed touching and no existing assertion broke — `shai-read`,
  `shai-context`, `shai-dispatch`, and `shai-print` were left untouched entirely.
  *(done 2026-07-29)*
- **Env-var context propagation** (design concurrency §3) — `SHAI_SESSION_ID` / `SHAI_RUN_ID` /
  `SHAI_SPAN_ID` / `SHAI_PARENT_SPAN_ID` / `SHAI_SCHEMA_VERSION` minted at the root wrapper and
  inherited by child filters; an inherited session id always wins. *(done 2026-07-29)*
- **Partitioned storage** (design concurrency §2) — `sessions/<session_id>.jsonl` replaces the
  global `history.jsonl`; `runs/<run_id>/events.jsonl` already shipped. Manual retention via
  `shai-prune`. Per-session file isolation eliminates the need for `flock`-style atomic append
  guards — concurrent sessions write to separate files by construction. *(done 2026-07-31)*
- **`flock` atomic appends** (design concurrency §2) — eliminated by design: per-session file
  isolation removes the concurrent-append surface, so no locking mechanism is needed. The
  user contract is: don't run `shai` and `shai-retry` on the same session concurrently.
  *(done 2026-07-31)*
- **Idempotent, non-destructive retries** (design concurrency §4) — `shai` buffers events
  in the run log during a turn and commits filtered events to the session log only on
  success. `shai-retry --run <run_id>` replays a failed run under a new run_id with
  `retry_of` metadata. Falls back to direct session-log writes when the run dir is
  unavailable. *(done 2026-08-01)*
- **Process supervision** (design concurrency §4.3) — `shai-supervise` generates and manages
  `systemd --user` `.service` + `.timer` unit files for any shai workflow script.
  `shai-heartbeat` is the stub consumer: exercises the full pipeline with a canned prompt,
  reports pass/fail to the journal, and leaves no state behind. *(done 2026-08-02)*

---

## ⚠️ Partial — started, but not to the doc's spec

- **Model agnosticism** (design extensibility pillar #2) — *the lone remaining partial; a true multi-provider adapter is split into its own spec.*
  - Have: `SHAI_MODEL` env var swaps the model (`shai-eval`).
  - Missing: it only swaps *Anthropic* models — `shai-eval` is hardwired to the Anthropic URL/headers/response shape. No adapter layer for Ollama / other providers.

---

## ❌ Not started — grouped by the design doc's sections

> **This order is not a plan.** It mirrors the design doc's section order, which is the chronology
> of a five-exchange conversation — it encodes no dependency or value judgement. See
> [Ordering constraints](#ordering-constraints) for what actually has to precede what.

### Edge cases (§ "The Edge Cases")
- **Token-aware context** — a real tokenizer (Python/Rust `tiktoken`-style) replacing turn-count truncation, to preserve system prompt + latest request while dropping least-relevant history. ⚑ *Conflicts with the zero-dependency rule — needs a decision, not just an implementation.*
- **Streaming** — buffering mid-stream tool calls; streamed responses. (Current pipeline is fully buffered/non-streaming.) *Unconstrained, but the most invasive reshape of the pipeline: `shai-eval` stops emitting a single buffered event.*

### Architectural choices (§ 2nd exchange)
- **Router topology** — a fast Haiku classifier that routes input to a mode-specific system prompt + tool subset, instead of one monolith prompt loading every tool every time. *Unconstrained; its tool-subset logic needs rework if MCP lands afterward.*

### Extensibility (§ 3rd exchange)
- **MCP** — stdio MCP servers discovered/attached dynamically instead of hardcoded `run_tool` cases. ⚠️ **Must follow the permission gate** — see [Ordering constraints](#ordering-constraints).
- **Input "translators"** — separate single-purpose scripts converting PDF / image / web page → markdown or base64 text before piping into `shai-read`. *Unconstrained; fully standalone.*
- **"Tee" middleware hooks** — the split-the-stream pattern exposed as a real extension point (local analytics DB, embeddings, RAG) grafted onto the pipeline without touching the core loop. (`shai` uses `tee` internally, but not as a user-facing hook.) *Unconstrained; benefits from the envelope's `version` field but does not require it.*

### Operational realities (§ 4th exchange)
- **Execution permission matrix + write tools** — the "`rm -rf` problem": read ops auto-approved; write/execute ops pause the pipeline, render the proposed command, and require `Y`/Enter via `/dev/tty`. Today every tool is read-only, so the gate does not exist yet. ⚠️ **Gates MCP, and breaks `shai-retry` on arrival** — see [Ordering constraints](#ordering-constraints).

---

## Ordering constraints

Derived 2026-07-28 by checking each open item against the current scripts; **revised 2026-07-29**
after the execution envelope and env-var propagation shipped; **revised 2026-07-31** after
partitioned storage and `flock` atomic appends shipped. Of the **nine** remaining open
items, **none** have unmet hard technical predecessors. Two items are constrained by safety
rather than by build order. The rest can be sequenced purely on value.

### Hard dependencies

| Item | Requires | Why | Status |
|---|---|---|---|
| Standard execution envelope | Env-var context propagation | `meta.{run_id, session_id, parent_span_id, span_id}` cannot be populated across a five-process pipeline without inherited ambient context. Build the envelope alone and each filter mints its own `run_id`. | ✅ satisfied — both shipped 2026-07-29 |
| Partitioned storage | Standard execution envelope | `sessions/<session_id>.jsonl` + `runs/<run_id>.jsonl` needs the IDs to partition by. | ✅ satisfied — both shipped 2026-07-31 |
| Idempotent, non-destructive retries | Envelope + partitioned storage + propagation | "Commit to the session log only on full success" presupposes both the run/session split and the IDs. | ✅ all prerequisites satisfied; implemented 2026-08-01 |

**Resolved 2026-07-29.** Both were implemented together, propagation first. The envelope turned out
**not** to be a "breaking change to all six scripts and every shape-asserting test" — that holds
only for the doc's *literal* envelope. Measured before implementing: the four reader filters read
only `.type`, `.source`, and `.payload.*`, and no test asserted exact object shape. An additive
envelope therefore required no change to any reader filter's selectors and broke no existing
assertion — every edit to the four readers and the eight original suites was purely additive,
and `shai-context`, `shai-dispatch`, `shai-print`, `shai-read`, and five of the eight suites
were left untouched entirely.

### Safety inversions

- **MCP must not precede the permission gate.** The only thing making the absent gate safe today is
  the all-tools-are-read-only invariant (`tools.json`: `gh_pr_view`, `gh_issue_view`,
  `list_directory`, `print_file`). MCP attaches arbitrary third-party stdio servers whose tools are
  not read-only, which destroys that invariant. Shipping MCP first opens a window where shai
  executes third-party write/exec tools with no approval prompt. The written order puts MCP three
  slots ahead of the gate.
- **Write tools break the shipped `shai-retry`.** `shai-retry:49` re-dispatches a dangling
  `tool_use` with no idempotency check — harmless while every tool is read-only, but with write
  tools it re-executes a write that may already have partially run. The permission-gate item
  therefore needs *either* idempotent non-destructive retries first, *or* a dispatch-side replay
  guard of its own.

### Constraint conflict (not an ordering problem)

**Token-aware context** requires a real tokenizer, which breaks the project's stated
zero-dependency rule (`bash`, `curl`, `jq`, plus `gh` for the GitHub tools). Settle that decision
before the item is scheduled.

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

`CLAUDE.md`'s "Deferred beyond the MVP" line names four headliners — **streaming, write tools + permission gate, concurrency, MCP**. The design doc's real surface is larger. As of 2026-07-28, three former ⚠️ partials are ✅ done (XML `<external_data>` tagging, always-on request-dump observability, `shai-retry` resumability); **model agnosticism** is the lone remaining partial, its true multi-provider adapter deferred to its own spec.
