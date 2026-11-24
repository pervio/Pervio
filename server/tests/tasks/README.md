# server/tests/tasks

Generated — do NOT edit by hand.

    python3 server/tests/capture_tasks.py --only codex    # re-record (spends a few cents of Codex quota)

`codex-subagents.appserver.jsonl` is what a real `codex app-server` (0.169) sent
for one turn that spawned two sub-agents: each sub-agent is a thread of its own,
and its turns, items and token usage arrive on the same connection under its own
`threadId`. Only the notification kinds `pervio-codex-app` reads are kept (the
rest is the account, its rate limits and the MCP servers installed on the
recording Mac); paths, the username and ids are redacted by `capture_corpus.py`'s
redactor.

`test_chat.py` (the CXS checks) plays it back through the shim
(`SHIM_CODEX_REPLAY`) into the adapter. What the adapter makes of it — the stream
the phone reads — is `ios/Tests/Fixtures/tasks/codex-subagents.jsonl`.
