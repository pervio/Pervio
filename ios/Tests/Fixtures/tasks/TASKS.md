# ios/Tests/Fixtures/tasks

Generated — do NOT edit by hand.

    python3 server/tests/capture_tasks.py --list     # the scenarios
    python3 server/tests/capture_tasks.py            # re-capture all three (spends real quota, about $0.30)

Each `.jsonl` is the stdout of one real turn that used sub-agents (Claude Code
through `server/bin/pervio-chat` the way a phone's Run turn is launched; Codex
through `server/bin/pervio-codex-app`), and
redacted by `capture_corpus.py`'s redactor (workdir, home, username, hostname,
UUIDs, request ids, the installed skills/agents/commands listing). pervio-hb's
heartbeat lines are dropped. Nothing else is touched, and nothing is hand-written.

| fixture | what the turn did | what it is here for |
| --- | --- | --- |
| `claude-subagents-background.jsonl` | two sub-agents and a background command, started in one message (2.1.322, default settings) | every sub-agent is a background task; `task_progress` after each tool; a sub-agent's own background command carries `parent_task_id`; each ending is `task_updated` + `task_notification` and then a reply of the engine's own |
| `claude-subagents-foreground.jsonl` | two sub-agents with `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` | no `background_tasks_changed` at all: the sub-agents are known from `task_started` (`is_backgrounded` false) alone |
| `codex-subagents.jsonl` | a Codex 0.169 turn that spawns two sub-agents, as `pervio-codex-app` hands it to the phone (`--only codex`; the raw app-server stream it was made from is `server/tests/tasks/codex-subagents.appserver.jsonl`) | a Codex sub-agent is a thread of its own — the adapter reports it in Claude Code's task words, and nothing it says or runs is the conversation's |

Read by `ios/Tests/Store/BackgroundBoardTests.swift`. Captured 2026-11-22 with claude 2.1.322.

(Named `TASKS.md`, not `README.md`: Xcode flattens every test resource into one
bundle directory — see `events/EVENTS.md`.)
