# ios/Tests/Fixtures/events

Generated — do NOT edit by hand.

(Named `EVENTS.md`, not `README.md`, on purpose: Xcode flattens every test resource
into one bundle directory, so a second `README.md` collides with
`ios/Tests/Fixtures/README.md` and the test target refuses to build.)

    python3 server/tests/capture_corpus.py            # re-capture (spends real quota)
    python3 server/tests/capture_corpus.py --rescrub  # just re-sync this folder (free)

Every `.jsonl` here is a byte-for-byte copy of `server/tests/corpus/<name>.jsonl`:
the REAL stdout of a real `claude` / `codex` turn, captured through the same
`pervio-chat` invocation production uses, redacted only in the values listed in the
matching `server/tests/corpus/<name>.meta.json`. Nothing here is hand-written, so
`AgentEvent.parse` is tested against what the CLIs emit rather than against what we
imagined they emit.

`bash server/tests/run_all.sh` runs `test_event_corpus.py`, which fails if this
folder ever drifts from `server/tests/corpus/`. That sentence was false until
2026-08-08: the file existed, but it was not in run_all.sh's `SUITES`, so only
`test-release` ever ran it and the drift sentinel this paragraph promises was not
armed on the everyday path. It is in `SUITES` now, and run_all.sh's first check
fails if any `test_*.py` is again left out of every layer.

`server/tests/corpus/README.md` has the full table: which scenario records which
event kind, what each capture cost, and — for the three claude scenarios with no
codex equivalent (thinking text, plan mode, approvals) — the physical reason codex
cannot produce one.
