#!/usr/bin/env python3
"""capture_tasks.py — record what a REAL Claude Code says about its sub-agents
and background tasks, for the phone's task line to be tested against.

    python3 server/tests/capture_tasks.py --list            # the scenarios
    python3 server/tests/capture_tasks.py                    # capture all three (spends real quota)
    python3 server/tests/capture_tasks.py --only background
    python3 server/tests/capture_tasks.py --only codex       # the Codex one alone
    python3 server/tests/capture_tasks.py --redact RAW --workdir DIR --as background
                                                             # redact a stream already captured; free

WHY IT IS NOT A capture_corpus.py SCENARIO
    That corpus is one prompt, one turn, the cheapest model. These need a turn
    that stays open after its reply (the stream-json input a living run uses —
    background tasks end later and each ending is a reply of its own), a model
    that makes parallel tool calls as told, and — for the second scenario — an
    environment variable. The redaction, the leak scan and the cleanup of the
    throwaway project folder are capture_corpus.py's own, imported.

WHAT IT RECORDS (ios/Tests/Fixtures/tasks/, read by BackgroundBoardTests)
    claude-subagents-background  two sub-agents and a background command, as
        Claude Code 2.1.322 runs them by default: all three are background
        tasks (background_tasks_changed lists them, task_started says
        is_backgrounded true), a sub-agent reports after every tool it uses
        (task_progress), one sub-agent puts a command of its own in the
        background (parent_task_id), each ending is task_updated +
        task_notification and then a reply of the engine's own.
    claude-subagents-foreground  two sub-agents where background tasks are off
        (CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 — how every sub-agent ran before
        they became background tasks): no background_tasks_changed at all, the
        sub-agents are known from task_started (is_backgrounded false) alone.

    codex-subagents  a Codex turn that spawns two sub-agents (0.169). TWO files:
        server/tests/tasks/codex-subagents.appserver.jsonl — what `codex
        app-server` itself sent (each sub-agent is a thread of its own, its
        turns, items and token usage arriving on the same connection under its
        own threadId), replayed through the shim into pervio-codex-app by
        test_chat.py's CXS checks; and ios/Tests/Fixtures/tasks/codex-subagents.jsonl
        — what the adapter made of it, the stream the phone reads. Of the raw
        stream only the notification kinds the adapter reads are kept
        (thread/status/changed, turn/started, turn/completed, item/started,
        item/completed, thread/tokenUsage/updated): the rest is the account,
        its rate limits and the MCP servers installed on this Mac.

HOW IT TALKS TO CLAUDE
    Through server/bin/pervio-chat in stream mode, the launch a phone's Run turn
    uses (same flags, the same saved login) — never through pervio-run, which
    would push the reply to a phone. bypassPermissions in a throwaway folder
    holding one file: the prompts run `ls`, `sleep` and `echo` and nothing else.

THIS SPENDS REAL MONEY (about $0.25 for the two Claude turns on sonnet, a few cents of Codex quota). Never run by a test suite.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import capture_corpus as cap   # noqa: E402  (the redactor, the leak scan, the project-folder cleanup)

OUT = os.path.join(cap.REPO, "ios", "Tests", "Fixtures", "tasks")
RAW_OUT = os.path.join(HERE, "tasks")           # what an engine's own protocol said, for the server-side replay
CODEX_APP = os.path.join(cap.BIN, "pervio-codex-app")
CODEX_PROMPT = (
    "This is a probe of your tool plumbing; do exactly this, nothing else. Spawn TWO sub-agents in parallel (use your "
    "agent-spawning tool): the first runs `ls -la` and then `sleep 8` and reports the number of entries; the second reads "
    "note.txt, runs `sleep 5`, and reports its content. Wait for both to finish, then answer with one line that contains "
    "both results.")
CODEX_KEEP = ("thread/status/changed", "turn/started", "turn/completed", "item/started", "item/completed",
              "thread/tokenUsage/updated")

SCENARIOS = {
    "background": {
        "env": {},
        "prompt": (
            "This is a probe of your tool plumbing; do exactly this, nothing else.\n"
            "In ONE message, make these three tool calls in parallel:\n"
            "1. Agent tool, subagent_type general-purpose, description \"List the folder\", "
            "prompt: run `ls -la` with Bash, then `sleep 8`, then answer with the number of entries.\n"
            "2. Agent tool, subagent_type general-purpose, description \"Slow background helper\", "
            "run_in_background true, prompt: run `sleep 25; echo helper-done` with Bash and answer with its output.\n"
            "3. Bash tool with run_in_background true, description \"Background sleep\", command: sleep 35; echo bash-done\n"
            "After the calls return, answer with the single word: launched.\n"
            "Later, each time you are told a background task finished, answer with one short line."),
    },
    "foreground": {
        "env": {"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1"},
        "prompt": (
            "This is a probe of your tool plumbing; do exactly this, nothing else.\n"
            "In ONE message, make two Agent tool calls in parallel, both subagent_type general-purpose:\n"
            "1. description \"Count the entries\", prompt: run `ls -la` with Bash, then run `sleep 6` with Bash, "
            "then answer with the number of entries.\n"
            "2. description \"Read the note\", prompt: read note.txt with the Read tool, run `sleep 4` with Bash, "
            "then answer with its content.\n"
            "When both return, answer with the single word: done."),
    },
}


def capture(name, model, limit):
    """Run the scenario for real; returns (raw text, workdir)."""
    sc = SCENARIOS[name]
    work = tempfile.mkdtemp(prefix="corpus_tasks_%s_" % name, dir="/tmp")
    with open(os.path.join(work, "note.txt"), "w") as f:
        f.write("hello\n")
    env = {k: os.environ[k] for k in ("HOME", "PATH", "USER", "LOGNAME", "LANG", "SHELL", "TMPDIR") if k in os.environ}
    env["TERM"] = "dumb"
    env.update(sc["env"])
    # A session of its own, so that a capture that runs out of time takes the
    # WHOLE tree down — pervio-chat, the real CLI behind its pipe, whatever
    # that started — not just the launcher (the 2026-11-22 review).
    p = subprocess.Popen([cap.CHAT, "--dir", work, "--perm", "bypassPermissions", "--model", model],
                         cwd=work, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    msg = {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": sc["prompt"]}]}}
    p.stdin.write((json.dumps(msg) + "\n").encode()); p.stdin.flush()
    state = {"results": 0, "pending": None, "last": time.time(), "raw": []}

    def pump():
        for raw in p.stdout:
            state["raw"].append(raw); state["last"] = time.time()
            try:
                ev = json.loads(raw)
            except ValueError:
                continue
            if ev.get("type") == "result":
                state["results"] += 1
            if ev.get("type") == "system" and ev.get("subtype") == "background_tasks_changed":
                state["pending"] = len(ev.get("tasks") or [])
    threading.Thread(target=pump, daemon=True).start()
    start = time.time()
    while time.time() - start < limit and p.poll() is None:
        time.sleep(1)
        quiet = time.time() - state["last"]
        # Answered, nothing pending (or nothing was ever put in the background), and quiet.
        if state["results"] >= 1 and state["pending"] in (0, None) and quiet > (12 if state["pending"] == 0 else 20):
            break
    try:
        p.stdin.close()
    except OSError:
        pass
    try:
        p.wait(timeout=30)
    except subprocess.TimeoutExpired:
        import signal
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(p.pid, sig)
            except OSError:
                break
            try:
                p.wait(timeout=10); break
            except subprocess.TimeoutExpired:
                continue
    cap._drop_claude_project(os.path.realpath(work))
    return b"".join(state["raw"]).decode("utf-8", "replace"), work


def capture_codex(model, limit):
    """One real Codex turn through pervio-codex-app (one-shot, read-only
    sandbox), codex's own stdout copied aside by a wrapper. Returns
    (raw app-server text, the adapter's output, workdir)."""
    import base64, shutil
    codex = shutil.which("codex")
    if not codex:
        sys.exit("capture_tasks: no codex on PATH")
    work = os.path.realpath(tempfile.mkdtemp(prefix="corpus_tasks_codex_", dir="/tmp"))
    with open(os.path.join(work, "note.txt"), "w") as f:
        f.write("hello\n")
    side = tempfile.mkdtemp(prefix="corpus_tasks_codex_side_", dir="/tmp")
    raw_path, wrapper = os.path.join(side, "raw.jsonl"), os.path.join(side, "codex-tee")
    with open(wrapper, "w") as f:
        f.write("#!/bin/bash\n\"%s\" \"$@\" | tee -a \"%s\"\n" % (codex, raw_path))
    os.chmod(wrapper, 0o700)
    done = subprocess.run([sys.executable, CODEX_APP, "--codex", wrapper, "--dir", work, "--sandbox", "read-only",
                           "--approval", "never", "--model", model, "--effort", "low",
                           "--prompt-b64", base64.b64encode(CODEX_PROMPT.encode()).decode()],
                          cwd=work, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=limit)
    raw = open(raw_path, encoding="utf-8", errors="replace").read() if os.path.exists(raw_path) else ""
    shutil.rmtree(side, ignore_errors=True)
    if done.returncode != 0 or not raw:
        sys.exit("capture_tasks: the codex turn failed (exit %s)" % done.returncode)
    return raw, done.stdout.decode("utf-8", "replace"), work


def codex_notifications(raw):
    """Only the notification kinds the adapter reads (see the header)."""
    keep = []
    for line in raw.splitlines(True):
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if isinstance(m, dict) and m.get("method") in CODEX_KEEP:
            keep.append(line)
    return "".join(keep)


def write_codex(raw, adapted, workdir, version):
    os.makedirs(RAW_OUT, exist_ok=True); os.makedirs(OUT, exist_ok=True)
    # One redactor for both files, so a thread id reads the same in the stream
    # codex sent and in what the adapter made of it.
    red = cap.Redactor(workdir)
    home = os.path.expanduser("~")
    for path, text in ((os.path.join(RAW_OUT, "codex-subagents.appserver.jsonl"), codex_notifications(raw)),
                       (os.path.join(OUT, "codex-subagents.jsonl"), adapted)):
        text, _hits = cap.scrub_text("".join(red(l) for l in text.splitlines(True)))
        bad = cap.leak_scan(text, os.path.basename(path), literals=(home, os.path.basename(home.rstrip("/"))))
        if bad:
            sys.exit("capture_tasks: NOT written — the redactor left something:\n  " + "\n  ".join(bad))
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        print("%s: %d lines (codex %s)" % (os.path.relpath(path, cap.REPO), len(text.splitlines()), version))


def redact(raw, workdir):
    """capture_corpus's two passes, then its leak scan. Heartbeats (pervio-hb's
    own keep-alive lines on a live pipe, nothing of the engine's) are dropped:
    a turn left open for its background tasks is mostly those."""
    red = cap.Redactor(workdir)
    lines = [l for l in raw.splitlines(True) if l.strip() != '{"type": "heartbeat"}' and l.strip() != '{"type":"heartbeat"}']
    text, _hits = cap.scrub_text("".join(red(l) for l in lines))
    home = os.path.expanduser("~")
    bad = cap.leak_scan(text, "tasks stream", literals=(home, os.path.basename(home.rstrip("/"))))
    if bad:
        sys.exit("capture_tasks: NOT written — the redactor left something:\n  " + "\n  ".join(bad))
    return text


def write(name, text, version):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, "claude-subagents-%s.jsonl" % name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    kinds = {}
    for l in text.splitlines():
        try:
            ev = json.loads(l)
        except ValueError:
            continue
        if ev.get("type") == "system" and str(ev.get("subtype", "")).startswith(("task_", "background_")):
            kinds[ev["subtype"]] = kinds.get(ev["subtype"], 0) + 1
    print("%s: %d lines, %s (claude %s)" % (os.path.relpath(path, cap.REPO), len(text.splitlines()),
                                           ", ".join("%s×%d" % kv for kv in sorted(kinds.items())), version))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--only", choices=sorted(SCENARIOS) + ["codex"])
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--codex-model", default="gpt-6.1-terra")
    ap.add_argument("--limit", type=int, default=220, help="seconds a capture may take")
    ap.add_argument("--redact", metavar="RAW", help="redact an already captured raw stream instead of capturing")
    ap.add_argument("--workdir", help="…the folder that capture ran in (for --redact)")
    ap.add_argument("--as", dest="as_name", choices=sorted(SCENARIOS), help="…and which scenario it is (for --redact)")
    a = ap.parse_args()
    if a.list:
        for name, sc in sorted(SCENARIOS.items()):
            print("%-11s env=%s" % (name, sc["env"] or "{}"))
        print("%-11s a Codex turn with two sub-agents, through pervio-codex-app" % "codex")
        return
    version = cap.cli_version("claude")
    if a.redact:
        if not (a.workdir and a.as_name):
            sys.exit("capture_tasks: --redact needs --workdir and --as")
        write(a.as_name, redact(open(a.redact, encoding="utf-8", errors="replace").read(), a.workdir), version)
        return
    for name in ([a.only] if a.only else sorted(SCENARIOS) + ["codex"]):
        if name == "codex":
            raw, adapted, work = capture_codex(a.codex_model, a.limit)
            write_codex(raw, adapted, work, cap.cli_version("codex"))
            continue
        raw, work = capture(name, a.model, a.limit)
        write(name, redact(raw, work), version)


if __name__ == "__main__":
    main()
