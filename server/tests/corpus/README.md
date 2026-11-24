# server/tests/corpus — real agent event corpus

Nothing in this folder is hand-written. Every `.jsonl` is what `claude` and `codex`
actually printed on this machine, captured by

    python3 server/tests/capture_corpus.py            # spends real quota
    python3 server/tests/capture_corpus.py --list     # spends nothing

and consumed by `server/tests/test_event_corpus.py` (server-side parsers) and
`ios/Tests/Contract/EventCorpusTests.swift` (the phone's `AgentEvent` parser).

Read `capture_corpus.py`'s header for the capture method, the isolation story and
the exact redaction rules. Each scenario's own `*.meta.json` records the command,
the CLI version, the capture date, the exit code and the tokens that turn burned.

## Cost of one full re-capture

Nine turns on the cheapest tier of each backend — an event *envelope* has the same
shape whatever the model thinks, so nothing here pays for judgement. Track A's caps
are 8 claude / 5 codex turns; `capture_corpus.py` refuses to exceed them.
The 2026-08-07 capture cost **$0.138 of claude quota over 6 turns** (two of the nine
turns are deliberately free — they die on an invalid model id before any token
burns) plus 3 codex turns (~49k input tokens; `codex exec` reports no cost field).

## Files

| scenario | backend | model | what it exists to record |
| --- | --- | --- | --- |
| `claude-text` | claude | haiku-4.5 | `system/init`, `system/status`, partial-message **text_delta shards**, `assistant` + per-request usage, `result` + usage + `total_cost_usd`, `rate_limit_event` |
| `claude-think` | claude | haiku-4.5, effort high | **thinking_delta** + `signature_delta` shards, `system/thinking_tokens` |
| `claude-tools` | claude | haiku-4.5, acceptEdits | `assistant` `tool_use` (Write, Read), `user` `tool_result`, `input_json_delta` shards |
| `claude-plan` | claude | haiku-4.5, perm plan | `tool_use` **ExitPlanMode** (what the phone's plan sheet is built from) + `result.permission_denials` |
| `claude-approval` | claude | haiku-4.5, perm default | **`permission_request`** and **`permission_resolved`** (pervio-approve, tee'd by pervio-chat-stream), a real **Deny**, and the `result` that carries the denial |
| `claude-error` | claude | *invalid model* | `assistant` with `error`/`request_id`, `result` `is_error` + `api_error_status` — **free** |
| `codex-text` | codex | gpt-5.4-mini | `thread.started`, `turn.started`, `item.completed`/`agent_message`, `turn.completed` + usage |
| `codex-tools` | codex | gpt-5.4-mini, workspace-write | `item.started`/`item.completed` for `command_execution` **and** `file_change` |
| `codex-error` | codex | *invalid model* | `item.completed` with `item.type:"error"`, top-level `error`, `turn.failed` — **free** |

Each scenario also freezes `<name>.session.jsonl`: the conversation the SAME turn
wrote to disk (`~/.claude/projects/…` / a codex rollout), which is what
`pervio-sessions transcript` reads. Those files keep the lines the transcript parser
must *skip* (`queue-operation`, `attachment`, `file-history-snapshot`, `ai-title`,
`last-prompt`; codex's `world_state`, `turn_context`, `event_msg`) — that skipping
is exactly the behaviour a reload regression would break.

## Every claude scenario needs a codex twin — where there isn't one, why

| claude scenario | codex twin | if none, the physical reason |
| --- | --- | --- |
| `claude-text` | `codex-text` | — |
| `claude-tools` | `codex-tools` | — |
| `claude-error` | `codex-error` | — |
| `claude-think` | **none** | codex emits no reasoning **text** on the event stream at all (docs/codex-event-schema.md: no `reasoning` item even at high effort). The only trace is `turn.completed.usage.reasoning_output_tokens`, which `codex-text` already records. (The codex *rollout* does keep a `response_item`/`reasoning` line — see `codex-text.session.jsonl` — but it never reaches the wire the phone parses.) |
| `claude-plan` | **none** | `codex exec` has no plan mode and no `ExitPlanMode` tool. Its whole permission surface is `--sandbox read-only\|workspace-write\|danger-full-access`, which gates writes but never produces a plan-for-approval event. |
| `claude-approval` | **none** | codex has no approval channel: `codex exec` is non-interactive and cannot ask. This repo already pays for that asymmetry — `server/bin/pervio-chat` mounts pervio-mcp **read-only** (`PERVIO_MCP_RO=1`) for codex precisely because there is no Allow/Deny path to gate a write behind. |
| — | `codex-tools` also records `file_change` | claude has no equivalent event: an edit arrives as an ordinary `tool_use` (Write/Edit), already covered by `claude-tools`. |

## Drift sentinel

`test_event_corpus.py --refresh` re-captures (spending quota) and compares the
**field set per event type** against what is frozen here. Values may change freely;
structure may not. Without `--refresh` nothing is captured and nothing is spent —
the sentinel still proves it works by mutating a *copy* of the frozen corpus (add a
field, drop a field, drop an event type) and asserting each mutation is caught.

Re-run the sentinel after upgrading claude or codex. If it fires, look at the diff,
decide whether the parsers need to change, then re-freeze with `capture_corpus.py`.

## Known asymmetries the frozen corpus already proves

* `codex-error.jsonl` carries `item.completed` with `item.type:"error"` — a shape
  `AgentEvent.parseCodex` does not recognise, so an item-level codex error is
  currently swallowed as `.ignored`. The corpus records it; fixing the parser is a
  separate change.
* claude's stream carries `rate_limit_event` and `system/thinking_tokens`, neither
  of which any parser reads. They are frozen so a future "unknown type" regression
  shows up here rather than on a user's phone.
* a claude session file is **not** globally ordered by `timestamp`: the `attachment`
  bookkeeping lines are stamped with the prompt's own time, ~1 ms *before* the `user`
  line they follow. The conversation lines (`user`/`assistant`) are ordered, and that
  is what the transcript parser relies on — `test_event_corpus.py` asserts exactly
  that, and no more. (Found by asserting the stronger claim first and watching real
  files disprove it.)
* `claude-plan` shows plan mode as it really behaves headlessly: the model tried
  `Write` first, permission mode refused it, and the refusal is recorded in
  `result.permission_denials` — so the corpus covers a denial on the plan path too,
  not only on the approval path.
