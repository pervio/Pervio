# Pervio server regression tests

One command, zero model cost:

```bash
bash server/tests/run_all.sh          # all no-cost suites (shim agents)
bash server/tests/run_all.sh --e2e    # + real-agent e2e (spends a little Claude/Codex quota)
```

Every suite is **hermetic** — it runs against `server/bin/*` with an isolated
`$HOME` and/or scratch git repos under `/tmp`, and cleans up after itself. The
agents are **committed shims** (`shim/claude`, `shim/codex`) driven by a
`SHIM:{json}` line in the prompt, so nothing calls a real model.

| Suite | Covers |
|---|---|
| `test_run.py` | `pervio-run` start/tail(--from)/list(--dir)/status/stop, done-vs-failed state machine, run-id traversal rejection |
| `test_sessions.py` | `pervio-sessions` folder encoding (CJK/space/dot), projects/list, transcript coalescing + subagent/noise filtering + limit, context math, delete, codex parsing, session-id traversal |
| `test_upload.py` | `pervio-upload` init/finish round-trip, filename sanitization, temp-file containment, size caps |
| `test_approve.py` | `pervio-approve` MCP handshake, allow/deny round-trips, updatedInput, concurrent calls dispatched by tool_use_id |
| `test_term.sh` | `pervio-term` parse/arg-reject + `~/sub` tilde expansion (tmux-gated) |
| `test_orchestrate_unit.py` | P3 worktree isolation: trigger matrix, happy-path merge, conflict, hostile hooks, reader rescue, delete-mid-run, crash recovery, merge-back guards, setup/verify, zero-regression |
| `test_orchestrate_security.py` | injection, traversal, containment, cleanup blast-radius, two-workflow isolation, permissions, crash safety |
| `test_orchestrate_efficiency.py` | parallelism, MAX_PARALLEL cap, isolation git overhead, shared-mode zero-overhead, `pervio-hb` throughput + idle cost |
| `test_orchestrate_e2e.py` (opt-in) | before/after clobber demo + real haiku/codex agents in worktrees |

Adding a test: put shim behavior in the prompt as `SHIM:{"write":[...],"sleep":N,"rc":N,"text":"...","is_error":false,"sid":"..."}`.
