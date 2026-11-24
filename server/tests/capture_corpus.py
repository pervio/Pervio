#!/usr/bin/env python3
"""capture_corpus.py — record a REAL agent event corpus for BOTH backends.

    python3 server/tests/capture_corpus.py --list         # what would run, and what it costs
    python3 server/tests/capture_corpus.py                # capture everything -> server/tests/corpus/
    python3 server/tests/capture_corpus.py --only claude-text codex-error
    python3 server/tests/capture_corpus.py --out /tmp/fresh   # stage somewhere else (drift sentinel)
    python3 server/tests/capture_corpus.py --rescrub      # re-apply redaction + re-sync iOS; FREE

WHY IT EXISTS
    Every event-shape test we had was fed hand-written JSON, so it could only ever
    prove that our parser agrees with our own imagination. This script spends a few
    cents of REAL quota to record what `claude` and `codex` actually emit, freezes
    it, and lets test_event_corpus.py drive the REAL parsers with it.

    THIS SPENDS REAL MONEY. It is never run by the test suite by default —
    test_event_corpus.py only re-captures under an explicit `--refresh`.

MODEL POLICY (deliberate, not laziness)
    An event ENVELOPE has the same shape whatever the model thinks, so every
    scenario here runs on the CHEAPEST tier: claude-haiku-4-5 / gpt-5.4-mini.
    Nothing in this file tests judgement, so nothing in this file pays for it.
    Hard per-backend turn caps below; the script refuses to exceed them.

HOW IT TALKS TO THE AGENTS
    Through the repo's own wrapper, `server/bin/pervio-chat`, with the exact
    argument shape pervio-orchestrate._run_agent_turn builds — so what we freeze is
    the byte stream production actually parses, not a private invocation.
    * ordinary scenarios: stdout is a FILE (Run mode -> no pervio-hb heartbeats),
    * the approval scenario: stdout is a PIPE (Chat mode), which is the only way
      pervio-approve's permission_request lines are tee'd onto the stream at all.

CREDENTIALS / ISOLATION (the honest version)
    Real agents need real credentials, so — exactly like server/tests/*_e2e.py —
    this runs with the REAL $HOME (pervio-chat sources ~/.pervio/credentials.env and
    claude/codex read their own auth). What is isolated is every OUTPUT: each turn
    runs in its own throwaway /tmp workdir, which is deleted afterwards. Nothing
    here writes ~/.pervio (no templates, no schedules, no archives, no wf dirs).
    Side effect we cannot avoid: claude/codex record their own conversation under
    ~/.claude/projects/<tmpdir>/ and ~/.codex/sessions/. We read those back (that is
    the transcript corpus) and then clean up ONLY our own droppings:
      * the claude project folder, deleted only when its name is exactly the encoded
        form of the mkdtemp dir this run created and it sits directly under
        ~/.claude/projects — otherwise nine junk rows would appear in the user's
        project picker after every capture;
      * the codex rollout is LEFT ALONE. It is invisible in the app (codex threads
        are listed by matching cwd, and this cwd no longer exists) and deleting it
        would desync ~/.codex's own index for no user-visible gain.
    Nothing else on disk is touched, and nothing pre-existing is ever removed.

REDACTION (A2)
    Pass 1 — pure TEXT substitution on the raw line, so field order, key names,
    spacing and escaping survive byte-for-byte and only values change:
      1. the throwaway workdir — its /tmp form, its /private/tmp realpath, AND the
         '-'-encoded form claude uses for project folders -> /home/pervio/work
      2. $HOME (and its realpath) -> /home/pervio ; the bare username -> pervio
      3. this machine's hostname -> pervio-host
      4. every UUID-shaped token -> 00000000-0000-4000-8000-0000000000NN, numbered in
         order of first appearance (so session_id/thread_id stay CONSISTENT within a file)
      5. every Anthropic request id (req_…) -> req_000…NN, same scheme

    Pass 2 — BULK scrub, and only on the lines that need it. A real session file
    carries kilobytes of vendor/operator boilerplate that has nothing to do with any
    parser under test and everything to do with this particular laptop: codex's 21 KB
    built-in system prompt, its <apps_instructions>/<recommended_plugins> blocks, and
    claude's attachment lines listing every skill/agent/slash-command installed here.
    Those VALUES are replaced with a marker (`<redacted: …>`), never the keys: a
    scrubbed array stays a one-element array of strings, a scrubbed string stays a
    string, so every dotted field path the drift sentinel compares survives intact.
    A line that matches nothing is passed through untouched, byte for byte; a line
    that is scrubbed is re-serialized in the separator/escaping style that was first
    proven to round-trip that exact line.

    Finally a leak scan refuses to write anything still carrying the real home, the
    username, the hostname, the workdir, an api-key prefix, or a personal-memory path.

FILE LAYOUT (per scenario)
    corpus/<backend>-<scenario>.jsonl           the agent's stdout, redacted, otherwise verbatim
    corpus/<backend>-<scenario>.session.jsonl   the on-disk conversation the same turn wrote
                                                (claude ~/.claude/projects/…, codex rollout)
    corpus/<backend>-<scenario>.meta.json       capture command, CLI version, date, exit code, usage
    The metadata is a SIDECAR, not a header line inside the .jsonl, for one concrete
    reason: pervio-sessions._codex_meta requires a codex rollout's FIRST line to be
    `session_meta`, so a header line would break the very parser the corpus exists
    to test. Keeping every .jsonl pure costs one extra file per scenario and buys a
    corpus that is byte-faithful everywhere.

    The event streams are ALSO mirrored, byte for byte, into
    ios/Tests/Fixtures/events/ — the phone parses the same bytes with its own Swift
    parser, and test_event_corpus.py fails if the two copies ever diverge.
"""
import argparse
import base64
import glob
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.realpath(os.path.join(HERE, "..", ".."))
BIN = os.path.join(REPO, "server", "bin")
CHAT = os.path.join(BIN, "pervio-chat")
CORPUS = os.path.join(HERE, "corpus")
# The phone parses the SAME bytes with its own Swift parser, so the event streams
# (not the session files — those are server-side transcript input) are mirrored into
# the iOS test bundle. test_event_corpus.py fails if the two copies ever diverge.
IOS_EVENTS = os.path.join(REPO, "ios", "Tests", "Fixtures", "events")

HAIKU = "claude-haiku-4-5-20251001"      # cheapest claude tier
MINI = "gpt-5.4-mini"                    # cheapest codex tier

# Track A's slice of the batch budget (whole batch: claude <= 25 turns, codex <= 15).
# Counts every CLI INVOCATION, including the two deliberately-free error scenarios,
# so the cap can only ever over-estimate what we spend.
TRACK_CAPS = {"claude": 8, "codex": 5}

WORK_TOKEN = "/home/pervio/work"
HOME_TOKEN = "/home/pervio"
HOST_TOKEN = "pervio-host"

UUID_RE = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                     r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
REQ_RE = re.compile(r"\breq_[A-Za-z0-9]{8,}\b")
# codex writes the host's IANA zone into <environment_context> / world_state — a
# coarse location fingerprint of the operator, so it is pinned to UTC.
TZ_RE = re.compile(r"\b(?:Africa|America|Antarctica|Arctic|Asia|Atlantic|Australia|"
                   r"Europe|Indian|Pacific)/[A-Za-z_]+(?:/[A-Za-z_]+)?\b")

# Anything matching these in a REDACTED file means the redactor missed something.
LEAK_PATTERNS = [
    (re.compile(r"sk-ant-[A-Za-z0-9_-]+"), "anthropic api key"),
    (re.compile(r"sk-proj-[A-Za-z0-9_-]+"), "openai api key"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{16,}\b"), "github token"),
    (re.compile(r"eyJ[A-Za-z0-9_-]{20,}\."), "jwt"),
    (re.compile(r"/Users/(?!pervio\b)[A-Za-z0-9._-]+"), "a real macOS home path"),
    (re.compile(r"/home/(?!pervio\b)[A-Za-z0-9._-]+"), "a real linux home path"),
    (re.compile(r"MEMORY\.md|memory/MEMORY"), "the user's personal memory index"),
    (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "an email address"),
]


# --------------------------------------------------------------------------- #
# scenarios
# --------------------------------------------------------------------------- #

class Scenario(object):
    def __init__(self, name, backend, prompt, model, covers, perm=None, sandbox=None,
                 effort=None, approve=False, free=False, twin=None, no_twin=None):
        self.name = name                  # file stem, "<backend>-<scenario>"
        self.backend = backend
        self.prompt = prompt
        self.model = model
        self.covers = covers              # event kinds this scenario is here to record
        self.perm = perm
        self.sandbox = sandbox
        self.effort = effort
        self.approve = approve            # drive the pervio-approve permission bridge
        self.free = free                  # deliberately errors out before any tokens burn
        self.twin = twin                  # the other backend's matching scenario
        self.no_twin = no_twin            # …or why that backend physically cannot have one


SCENARIOS = [
    Scenario(
        "claude-text", "claude", model=HAIKU, perm="default", effort="low",
        twin="codex-text",
        covers=["system/init", "system/status", "stream_event text_delta (partial-message shards)",
                "assistant message + per-request usage", "result + usage + total_cost_usd"],
        prompt="Reply with exactly this sentence and nothing else: The corpus is alive."),

    Scenario(
        "claude-think", "claude", model=HAIKU, perm="default", effort="high",
        twin=None,
        no_twin=("codex emits NO reasoning text at all — verified in docs/codex-event-schema.md "
                 "(no `reasoning` item type even at high effort); the only trace of thinking is "
                 "turn.completed.usage.reasoning_output_tokens, which codex-text already records."),
        covers=["stream_event thinking_delta (partial-message shards)", "signature_delta"],
        prompt="Think it through step by step, then answer with the number alone: "
               "a barrel holds 31 litres, I pour out 8 and then pour back 5. How many litres?"),

    Scenario(
        "claude-tools", "claude", model=HAIKU, perm="acceptEdits", effort="low",
        twin="codex-tools",
        covers=["assistant content[].tool_use (Write, Read)", "user content[].tool_result",
                "result after a multi-step turn"],
        prompt="Do exactly two things with tools and then stop:\n"
               "1. Use the Write tool to create a file named note.txt in the current directory "
               "containing exactly the line: corpus\n"
               "2. Use the Read tool to read note.txt back.\n"
               "Then reply with the single word: done"),

    Scenario(
        "claude-plan", "claude", model=HAIKU, perm="plan", effort="low",
        twin=None,
        no_twin=("codex exec has no plan mode and no ExitPlanMode tool — its permission surface is "
                 "`--sandbox read-only|workspace-write|danger-full-access`, which gates writes but "
                 "never produces a plan-for-approval event."),
        covers=["assistant tool_use ExitPlanMode (the plan sheet's source event)"],
        prompt="Do NOT edit anything. Make a two-bullet plan for renaming note.txt to notes.txt, "
               "then call ExitPlanMode with that plan."),

    Scenario(
        "claude-approval", "claude", model=HAIKU, perm="default", effort="low", approve=True,
        twin=None,
        no_twin=("codex has NO approval channel: `codex exec` is non-interactive, and this repo "
                 "already documents the consequence — pervio-chat mounts pervio-mcp READ-ONLY for "
                 "codex precisely because there is no Allow/Deny path to gate a write behind "
                 "(see the PERVIO_MCP_RO comment in server/bin/pervio-chat)."),
        covers=["permission_request (pervio-approve, tee'd by pervio-chat-stream)",
                "permission_resolved", "heartbeat (pervio-hb, live-pipe only)",
                "result carrying permission_denials"],
        prompt="Use the Write tool to create a file named approved.txt in the current directory "
               "containing exactly the line: ok. Then stop."),

    Scenario(
        "claude-error", "claude", model="claude-nope-9", perm="default", free=True,
        twin="codex-error",
        covers=["assistant with error/request_id", "result is_error + api_error_status"],
        prompt="hi"),

    Scenario(
        "codex-text", "codex", model=MINI, sandbox="read-only", effort="low",
        twin="claude-text",
        covers=["thread.started", "turn.started", "item.completed agent_message",
                "turn.completed + usage (incl. reasoning_output_tokens)"],
        prompt="Reply with exactly this sentence and nothing else: The corpus is alive."),

    Scenario(
        "codex-tools", "codex", model=MINI, sandbox="workspace-write", effort="low",
        twin="claude-tools",
        covers=["item.started/item.completed command_execution", "item.completed file_change"],
        prompt="Do exactly two things and then stop:\n"
               "1. Create a file named note.txt in the current directory containing exactly the "
               "line: corpus\n"
               "2. Run `cat note.txt`.\n"
               "Then reply with the single word: done"),

    Scenario(
        "codex-error", "codex", model="gpt-nope-9", sandbox="read-only", free=True,
        twin="claude-error",
        covers=["item.completed with item.type=error", "error", "turn.failed"],
        prompt="hi"),
]

BY_NAME = dict((s.name, s) for s in SCENARIOS)


# --------------------------------------------------------------------------- #
# redaction
# --------------------------------------------------------------------------- #

def _encode_path(p):
    """Claude Code's project-folder encoding (same rule as pervio-sessions.encode):
    every non-alphanumeric becomes '-'. The workdir shows up in this form inside
    `memory_paths.auto`, where a plain path replacement would never see it."""
    return re.sub(r"[^a-zA-Z0-9]", "-", p)


class Redactor(object):
    """Text-level, order-preserving. Longest literal first so /private/tmp/x is
    replaced before /tmp, and the home path before the bare username."""

    def __init__(self, workdir):
        home = os.path.expanduser("~")
        user = os.path.basename(home.rstrip("/")) or "user"
        host = socket.gethostname()
        lits = [(os.path.realpath(workdir), WORK_TOKEN), (workdir, WORK_TOKEN),
                (_encode_path(os.path.realpath(workdir)), _encode_path(WORK_TOKEN)),
                (_encode_path(workdir), _encode_path(WORK_TOKEN)),
                (os.path.realpath(home), HOME_TOKEN), (home, HOME_TOKEN),
                (host, HOST_TOKEN), (host.split(".")[0], HOST_TOKEN),
                (user, "pervio")]
        seen = set()
        self.lits = []
        for old, new in sorted(lits, key=lambda p: -len(p[0])):
            if old and old not in seen and old not in ("/", "pervio"):
                seen.add(old)
                self.lits.append((old, new))
        self.ids = {}                     # original id -> normalized id (stable per file)

    def _norm(self, kind, original):
        key = (kind, original)
        if key not in self.ids:
            n = len([k for k in self.ids if k[0] == kind]) + 1
            self.ids[key] = ("00000000-0000-4000-8000-%012d" % n if kind == "uuid"
                             else "req_%023d" % n)
        return self.ids[key]

    def __call__(self, text):
        for old, new in self.lits:
            text = text.replace(old, new)
        text = UUID_RE.sub(lambda m: self._norm("uuid", m.group(0)), text)
        text = REQ_RE.sub(lambda m: self._norm("req", m.group(0)), text)
        text = TZ_RE.sub("Etc/UTC", text)
        return text

    def mapped(self, original):
        """The normalized form of an id we already saw (e.g. the real session_id)."""
        for (kind, orig), new in self.ids.items():
            if orig == original:
                return new
        return original


def _reassembled(text):
    """The stream's partial_json shards, concatenated.

    A tool's input arrives as many `input_json_delta` shards, so a home path can
    be split as '/Users/' + 'realna' + 'me/…' across three lines. A line-wise
    scan sees none of the pieces and passes — that is exactly how a real username
    reached a frozen corpus (caught in review 2026-08-07). Scanning the
    concatenation as well closes it.
    """
    out = []
    for line in text.splitlines():
        if '"partial_json"' not in line:
            continue
        try:
            o = json.loads(line)
        except ValueError:
            continue
        pj = ((o.get("event") or {}).get("delta") or {}).get("partial_json")
        if isinstance(pj, str):
            out.append(pj)
    return "".join(out)


def leak_scan(text, where, literals=()):
    """Every reason this text must not be committed. Empty list == clean."""
    bad = []
    # The raw text AND the reassembled shard stream: a secret split across
    # shards is invisible in the former and obvious in the latter.
    for view, tag in ((text, where), (_reassembled(text), where + " (reassembled shards)")):
        if not view:
            continue
        for rx, what in LEAK_PATTERNS:
            m = rx.search(view)
            if m:
                bad.append("%s: %s (%r)" % (tag, what, m.group(0)[:60]))
        for lit in literals:
            if lit and lit in view:
                bad.append("%s: un-redacted literal (%r)" % (tag, lit[:60]))
    return bad


# --------------------------------------------------------------------------- #
# bulk scrub (pass 2) — values only, never keys
# --------------------------------------------------------------------------- #

BULK_CHARS = 1500        # any single string / string array bigger than this is boilerplate

# Short values that are small enough to survive the size rule but describe THIS
# machine rather than the protocol: matched on a dotted key-path suffix.
BULK_KEYS = frozenset([
    "slash_commands", "agents", "skills", "plugins",     # claude system/init + session
    "attachment.addedNames", "attachment.addedLines", "attachment.addedTypes",
    "attachment.readdedNames", "attachment.names", "attachment.content",
    "timezone",                                          # codex world_state / turn_context
])


REDACTION_NOTES = [
    "workdir (plain, realpath, and '-'-encoded) -> " + WORK_TOKEN,
    "$HOME -> " + HOME_TOKEN + ", username -> pervio",
    "hostname -> " + HOST_TOKEN,
    "IANA timezone -> Etc/UTC",
    "UUIDs -> 00000000-0000-4000-8000-0000000000NN (consistent within a file)",
    "req_… -> req_000…NN",
    "bulk vendor/environment values -> '<redacted: …>' markers "
    "(keys and types preserved; see 'scrubbedPaths')",
]

MARK = "<redacted: "


def _bulk_marker(node, why):
    if isinstance(node, str):
        return "<redacted: %s, %d chars>" % (why, len(node))
    total = sum(len(x) for x in node if isinstance(x, str))
    return ["<redacted: %s, %d entries, %d chars>" % (why, len(node), total)]


def _already(node):
    """Idempotence: a value we have already replaced must not be replaced again
    (otherwise re-running the redactor over a frozen file nests the markers)."""
    if isinstance(node, str):
        return node.startswith(MARK)
    return _is_str_list(node) and len(node) == 1 and node[0].startswith(MARK)


def _is_str_list(node):
    return isinstance(node, list) and bool(node) and all(isinstance(x, str) for x in node)


def _scrub(node, path, hits):
    """Depth-first; returns the (possibly replaced) node and appends hit paths."""
    if isinstance(node, dict):
        for k in list(node):
            p = "%s.%s" % (path, k) if path else k
            node[k] = _scrub(node[k], p, hits)
        return node
    if _already(node):
        return node
    if isinstance(node, list):
        named = any(path == k or path.endswith("." + k) for k in BULK_KEYS)
        if _is_str_list(node) and (named or sum(len(x) for x in node) > BULK_CHARS):
            hits.append(path)
            return _bulk_marker(node, "environment listing" if named else "bulk text")
        return [_scrub(el, path, hits) for el in node]
    if isinstance(node, str):
        named = any(path == k or path.endswith("." + k) for k in BULK_KEYS)
        if named or len(node) > BULK_CHARS:
            hits.append(path)
            return _bulk_marker(node, "environment value" if named else "bulk text")
    return node


_STYLES = [((",", ":"), False), ((",", ":"), True),
           ((", ", ": "), False), ((", ", ": "), True)]


def scrub_line(line):
    """(new_line, hit_paths). Untouched byte-for-byte when nothing matched.
    When something IS replaced the line must be re-serialized, so we first find the
    separator/escaping style that reproduces THIS line exactly and reuse it — a
    scrubbed line therefore differs from the original only in the replaced values."""
    stripped = line.rstrip("\n")
    try:
        obj = json.loads(stripped)
    except ValueError:
        return line, []
    if not isinstance(obj, (dict, list)):
        return line, []
    style = next((s for s in _STYLES
                  if json.dumps(obj, separators=s[0], ensure_ascii=s[1]) == stripped), None)
    hits = []
    obj = _scrub(obj, "", hits)
    if not hits:
        return line, []
    sep, ea = style or ((",", ":"), False)
    return json.dumps(obj, separators=sep, ensure_ascii=ea) + "\n", hits


def scrub_text(text):
    out, hits = [], []
    for line in text.splitlines(True):
        new, h = scrub_line(line)
        out.append(new)
        hits += h
    return "".join(out), sorted(set(hits))


# --------------------------------------------------------------------------- #
# field-shape sentinel (A3)
# --------------------------------------------------------------------------- #

def event_key(obj):
    """The identity a field set is compared under. Claude splits on type/subtype,
    codex on type/item.type — otherwise every item kind would be smeared into one
    `item.completed` bucket and a vanished field would hide behind a sibling."""
    t = obj.get("type")
    if not isinstance(t, str):
        return "<no-type>"
    if isinstance(obj.get("subtype"), str):
        return "%s/%s" % (t, obj["subtype"])
    item = obj.get("item")
    if isinstance(item, dict) and isinstance(item.get("type"), str):
        return "%s/%s" % (t, item["type"])
    return t


def _paths(node, prefix, out, depth=0):
    if depth > 8:
        return
    if isinstance(node, dict):
        for k in node:
            p = "%s.%s" % (prefix, k) if prefix else k
            out.add(p)
            _paths(node[k], p, out, depth + 1)
    elif isinstance(node, list):
        for el in node:
            if isinstance(el, (dict, list)):
                _paths(el, prefix + "[]", out, depth + 1)
            else:
                out.add(prefix + "[]")


def shape(lines):
    """{event key -> set of dotted field paths}. Values are ignored on purpose:
    the sentinel's contract is 'values may change, structure may not'."""
    out = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if not isinstance(o, dict):
            continue
        s = out.setdefault(event_key(o), set())
        _paths(o, "", s)
    return out


def shape_diff(frozen, fresh):
    """Human-readable differences, most alarming first. Empty == no drift."""
    diffs = []
    for key in sorted(set(frozen) - set(fresh)):
        diffs.append("event type GONE from the fresh capture: %s" % key)
    for key in sorted(set(fresh) - set(frozen)):
        diffs.append("event type NEW in the fresh capture: %s" % key)
    for key in sorted(set(frozen) & set(fresh)):
        gone = sorted(frozen[key] - fresh[key])
        new = sorted(fresh[key] - frozen[key])
        if gone:
            diffs.append("%s: fields GONE: %s" % (key, ", ".join(gone)))
        if new:
            diffs.append("%s: fields NEW: %s" % (key, ", ".join(new)))
    return diffs


def shape_of_file(path):
    with open(path, "r", errors="replace") as f:
        return shape(f.readlines())


# --------------------------------------------------------------------------- #
# capture
# --------------------------------------------------------------------------- #

def cli_version(backend):
    exe = "claude" if backend == "claude" else "codex"
    try:
        p = subprocess.run([exe, "--version"], capture_output=True, text=True, timeout=30)
        return (p.stdout or p.stderr).strip().splitlines()[0]
    except Exception as e:                                   # noqa: BLE001 - informational only
        return "unknown (%s)" % e


def build_cmd(sc, workdir, approve_sid=None):
    """The SAME argument shape pervio-orchestrate._run_agent_turn builds."""
    b64 = base64.b64encode(sc.prompt.encode("utf-8")).decode("ascii")
    cmd = [CHAT, "--text", "--backend", sc.backend, "--dir", workdir, "--prompt-b64", b64]
    if sc.backend == "codex":
        cmd += ["--sandbox", sc.sandbox or "workspace-write"]
    else:
        cmd += ["--perm", sc.perm or "default"]
    if sc.model:
        cmd += ["--model", sc.model]
    if sc.effort:
        cmd += ["--effort", sc.effort]
    if approve_sid:
        cmd += ["--approve-sid", approve_sid]
    return cmd


def _killpg(p):
    """Kill the whole session, not just pervio-chat: the agent is a grandchild behind
    a bash wrapper (and, on the approval path, a pipe), so p.kill() would leave the
    turn — and its billing — running. Same reason pervio-orchestrate._call_gated does
    it this way."""
    try:
        os.killpg(os.getpgid(p.pid), signal.SIGKILL)
    except OSError:
        p.kill()


def _run_to_file(cmd, timeout):
    """Run mode: stdout is a regular FILE, exactly like the orchestrator's out.jsonl
    (so pervio-chat skips the pervio-hb heartbeat pipe). Returns (lines, exit_code)."""
    fd, path = tempfile.mkstemp(prefix="corpus_out_", suffix=".jsonl", dir="/tmp")
    os.close(fd)
    try:
        with open(path, "wb") as out:
            p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=out,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
            try:
                p.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                _killpg(p)
                p.communicate()
        with open(path, "r", errors="replace") as f:
            return f.readlines(), (p.returncode if p.returncode is not None else 1)
    finally:
        os.unlink(path)


def _run_approval(cmd, sid, timeout, deny_cap=3):
    """Chat mode: stdout is a PIPE, which is the ONLY configuration in which
    pervio-chat turns on the approval bridge (`! -f /dev/stdout`) and
    pervio-chat-stream tees pervio-approve's permission_request lines onto the
    stream. Answers every request with Deny (one denial is all the corpus needs;
    the Allow/Deny behaviour itself is track B's live suite)."""
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    lines = []
    answered = [0]

    def pump():
        for raw in p.stdout:
            line = raw.decode("utf-8", "replace")
            lines.append(line)
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("type") == "permission_request" and answered[0] < deny_cap:
                answered[0] += 1
                rid = o.get("request_id") or o.get("tool_use_id") or ""
                subprocess.run([CHAT, "respond", "--sid", sid, "--request-id", rid,
                                "--behavior", "deny", "--message",
                                "denied by the corpus capture"],
                               capture_output=True, timeout=20)

    t = threading.Thread(target=pump, daemon=True)
    t.start()
    try:
        p.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        _killpg(p)
    t.join(timeout=10)
    # pervio-chat-stream rmtree's the per-turn session dir on a clean exit; a killed
    # turn never gets there, so sweep OUR nonce (and only a direct child of
    # ~/.pervio/chat, the same guard pervio-chat-stream applies to itself).
    root = os.path.realpath(os.path.join(os.path.expanduser("~"), ".pervio", "chat"))
    left = os.path.realpath(os.path.join(root, sid))
    if sid.startswith("corpuscap") and os.path.dirname(left) == root and os.path.isdir(left):
        shutil.rmtree(left, ignore_errors=True)
    return lines, (p.returncode if p.returncode is not None else 1), answered[0]


def _claude_session_file(workdir, session_id):
    proj = os.path.expanduser("~/.claude/projects")
    for base in (_encode_path(os.path.realpath(workdir)), _encode_path(workdir)):
        cand = os.path.join(proj, base, session_id + ".jsonl")
        if os.path.isfile(cand):
            return cand
    return None


def _drop_claude_project(real_work):
    """Delete the project folder claude minted for OUR throwaway cwd — nothing else.
    Defence in depth on a recursive delete: the folder must sit directly under
    ~/.claude/projects AND be named exactly the encoded form of the mkdtemp path this
    run created (…/corpus_<scenario>_<random>), which no real project can be."""
    root = os.path.realpath(os.path.expanduser("~/.claude/projects"))
    want = _encode_path(real_work)
    if not want.startswith("-") or "corpus-" not in want:
        return False                                  # not one of ours; refuse
    target = os.path.realpath(os.path.join(root, want))
    if os.path.dirname(target) != root or os.path.basename(target) != want:
        return False
    if not os.path.isdir(target):
        return False
    shutil.rmtree(target, ignore_errors=True)
    return True


def _codex_session_file(thread_id):
    hits = glob.glob(os.path.join(os.path.expanduser("~/.codex/sessions"),
                                  "*", "*", "*", "rollout-*-%s.jsonl" % thread_id))
    return hits[0] if hits else None


def session_id_of(lines, backend):
    for line in lines:
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if backend == "codex":
            if o.get("type") == "thread.started" and o.get("thread_id"):
                return o["thread_id"]
        elif o.get("session_id"):
            return o["session_id"]
    return ""


def usage_of(lines, backend):
    """Tokens this turn actually burned, from the terminal event."""
    out = {}
    for line in lines:
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if backend == "codex" and o.get("type") == "turn.completed":
            u = o.get("usage") or {}
            out = {"inputTokens": u.get("input_tokens"), "cachedInputTokens": u.get("cached_input_tokens"),
                   "outputTokens": u.get("output_tokens"),
                   "reasoningOutputTokens": u.get("reasoning_output_tokens"), "costUSD": None}
        elif backend == "claude" and o.get("type") == "result":
            u = o.get("usage") or {}
            out = {"inputTokens": u.get("input_tokens"),
                   "cachedInputTokens": (u.get("cache_read_input_tokens") or 0)
                                        + (u.get("cache_creation_input_tokens") or 0),
                   "outputTokens": u.get("output_tokens"),
                   "reasoningOutputTokens": None, "costUSD": o.get("total_cost_usd")}
    return out


def capture_one(sc, outdir, timeout=300):
    """Run ONE real turn and freeze it. Returns a report dict."""
    workdir = tempfile.mkdtemp(prefix="corpus_%s_" % sc.name.replace("-", "_"), dir="/tmp")
    real_work = os.path.realpath(workdir)      # resolved NOW, before the dir is removed
    sid_nonce = "corpuscap" + os.urandom(4).hex()
    rep = {"scenario": sc.name, "backend": sc.backend, "model": sc.model, "ok": False}
    try:
        cmd = build_cmd(sc, workdir, approve_sid=(sid_nonce if sc.approve else None))
        started = time.time()
        if sc.approve:
            lines, code, denials = _run_approval(cmd, sid_nonce, timeout)
            rep["denialsSent"] = denials
        else:
            lines, code = _run_to_file(cmd, timeout)
        rep["exitCode"] = code
        rep["seconds"] = round(time.time() - started, 1)
        rep["events"] = len([l for l in lines if l.strip()])
        if not rep["events"]:
            rep["error"] = "the agent produced no events at all"
            return rep

        real_sid = session_id_of(lines, sc.backend)
        rep["usage"] = usage_of(lines, sc.backend)

        # the on-disk conversation the SAME turn wrote (transcript-parser corpus)
        sess_path = (_codex_session_file(real_sid) if sc.backend == "codex"
                     else _claude_session_file(workdir, real_sid)) if real_sid else None

        red = Redactor(workdir)
        stream_txt, stream_hits = scrub_text(red("".join(lines)))
        sess_txt, sess_hits = (scrub_text(red(open(sess_path, "r", errors="replace").read()))
                               if sess_path else ("", []))
        rep["scrubbed"] = sorted(set(stream_hits + sess_hits))

        # The workdir under every spelling it can appear in — a dynamic tripwire for
        # the redactor itself, on top of the static secret patterns.
        base = os.path.basename(workdir)
        lits = [workdir, os.path.realpath(workdir), base, _encode_path(base),
                os.path.expanduser("~"), os.path.basename(os.path.expanduser("~"))]
        bad = leak_scan(stream_txt, sc.name + ".jsonl", lits)
        if sess_txt:
            bad += leak_scan(sess_txt, sc.name + ".session.jsonl", lits)
        if bad:
            rep["error"] = "leak scan refused to freeze this capture:\n  " + "\n  ".join(bad)
            return rep

        os.makedirs(outdir, mode=0o755, exist_ok=True)
        stream_file = os.path.join(outdir, sc.name + ".jsonl")
        with open(stream_file, "w") as f:
            f.write(stream_txt)
        rep["file"] = stream_file
        if sess_txt:
            with open(os.path.join(outdir, sc.name + ".session.jsonl"), "w") as f:
                f.write(sess_txt)
            rep["sessionFile"] = sc.name + ".session.jsonl"

        printable = " ".join(("<base64 of the prompt below>" if len(a) > 90 else a) for a in cmd)
        printable = (printable.replace(REPO + "/", "").replace(workdir, WORK_TOKEN)
                              .replace(sid_nonce, "<nonce>"))
        meta = {
            "scenario": sc.name,
            "backend": sc.backend,
            "model": sc.model,
            "capturedUTC": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "cliVersion": cli_version(sc.backend),
            "command": printable,
            "prompt": sc.prompt,
            "exitCode": code,
            "events": rep["events"],
            "seconds": rep["seconds"],
            "usage": rep["usage"],
            "sessionIdRedactedTo": red.mapped(real_sid) if real_sid else "",
            "covers": sc.covers,
            "twin": sc.twin,
            "noTwinBecause": sc.no_twin,
            "free": sc.free,
            "redactions": REDACTION_NOTES,
            "scrubbedPaths": rep["scrubbed"],
            "regenerate": "python3 server/tests/capture_corpus.py --only " + sc.name,
            "note": "REAL agent output. Everything except the values listed under "
                    "'redactions' is byte-for-byte what the CLI emitted.",
        }
        meta_txt = json.dumps(meta, indent=2, ensure_ascii=False) + "\n"
        meta_bad = leak_scan(meta_txt, sc.name + ".meta.json", lits)
        if meta_bad:
            rep["error"] = "leak scan refused the sidecar:\n  " + "\n  ".join(meta_bad)
            return rep
        with open(os.path.join(outdir, sc.name + ".meta.json"), "w") as f:
            f.write(meta_txt)
        rep["ok"] = True
        return rep
    finally:
        shutil.rmtree(workdir, ignore_errors=True)
        if sc.backend == "claude":
            rep["projectFolderRemoved"] = _drop_claude_project(real_work)


# --------------------------------------------------------------------------- #
# cli
# --------------------------------------------------------------------------- #

def _fmt_usage(u):
    if not u:
        return "usage not reported"
    parts = ["in=%s" % u.get("inputTokens"), "cached=%s" % u.get("cachedInputTokens"),
             "out=%s" % u.get("outputTokens")]
    if u.get("reasoningOutputTokens") is not None:
        parts.append("reasoning=%s" % u["reasoningOutputTokens"])
    if u.get("costUSD") is not None:
        parts.append("cost=$%.6f" % u["costUSD"])
    return " ".join(parts)


def sync_ios(outdir):
    """Mirror the event streams into the iOS test bundle. Streams only: the phone
    parses the wire, never a session file. Returns the names it copied."""
    os.makedirs(IOS_EVENTS, mode=0o755, exist_ok=True)
    copied = []
    for sc in SCENARIOS:
        src = os.path.join(outdir, sc.name + ".jsonl")
        if not os.path.isfile(src):
            continue
        dst = os.path.join(IOS_EVENTS, sc.name + ".jsonl")
        if not os.path.isfile(dst) or open(dst, "rb").read() != open(src, "rb").read():
            shutil.copyfile(src, dst)
            copied.append(sc.name + ".jsonl")
    return copied


def rescrub(outdir):
    """Re-apply the CURRENT redaction rules to already-frozen files. No agent runs,
    no cost. Exists so that tightening a redaction rule (e.g. pinning the host's
    timezone) doesn't force us to re-buy the corpus; both passes are idempotent, so
    the result is byte-identical to what a fresh capture would now produce."""
    red = Redactor(WORK_TOKEN)
    changed = []
    for path in sorted(glob.glob(os.path.join(outdir, "*.jsonl"))
                       + glob.glob(os.path.join(outdir, "*.meta.json"))):
        before = open(path, "r", errors="replace").read()
        after = red(before)
        if path.endswith(".jsonl"):
            after, _ = scrub_text(after)
        else:                                  # sidecar: keep its rule list current
            meta = json.loads(after)
            meta["redactions"] = REDACTION_NOTES
            after = json.dumps(meta, indent=2, ensure_ascii=False) + "\n"
        bad = leak_scan(after, os.path.basename(path))
        if bad:
            print("  LEAK in %s:\n    %s" % (os.path.basename(path), "\n    ".join(bad)))
            return 1
        if after != before:
            open(path, "w").write(after)
            changed.append(os.path.basename(path))
    print("rescrub: %d file(s) changed%s"
          % (len(changed), (": " + ", ".join(changed)) if changed else " — corpus already clean"))
    if os.path.realpath(outdir) == os.path.realpath(CORPUS):
        print("ios mirror: %d file(s) updated" % len(sync_ios(outdir)))
    return 0


def main():
    ap = argparse.ArgumentParser(description="Capture a REAL agent event corpus (spends quota).")
    ap.add_argument("--only", nargs="+", metavar="SCENARIO", help="capture just these")
    ap.add_argument("--out", default=CORPUS, help="output dir (default: server/tests/corpus)")
    ap.add_argument("--list", action="store_true", help="print the plan and exit; spends nothing")
    ap.add_argument("--rescrub", action="store_true",
                    help="re-apply redaction to the frozen corpus; runs no agents, spends nothing")
    ap.add_argument("--timeout", type=int, default=300)
    args = ap.parse_args()

    if args.rescrub:
        return rescrub(args.out)

    chosen = SCENARIOS
    if args.only:
        unknown = [n for n in args.only if n not in BY_NAME]
        if unknown:
            print("unknown scenario(s): %s\nknown: %s" % (", ".join(unknown),
                                                          ", ".join(sorted(BY_NAME))))
            return 2
        chosen = [BY_NAME[n] for n in args.only]

    turns = {"claude": 0, "codex": 0}
    for s in chosen:
        turns[s.backend] += 1
    over = [b for b in turns if turns[b] > TRACK_CAPS[b]]
    if over:
        print("REFUSING TO RUN — over track A's turn cap: " +
              ", ".join("%s %d > %d" % (b, turns[b], TRACK_CAPS[b]) for b in over))
        return 2

    print("plan: %d claude turn(s) (cap %d), %d codex turn(s) (cap %d)"
          % (turns["claude"], TRACK_CAPS["claude"], turns["codex"], TRACK_CAPS["codex"]))
    for s in chosen:
        print("  %-16s %-6s %-28s %s" % (s.name, s.backend, s.model,
                                         "FREE (errors before any tokens burn)" if s.free
                                         else "billed, cheapest tier"))
    if args.list:
        print("\n--list: nothing was run, nothing was spent.")
        return 0

    reports = []
    for s in chosen:
        print("\n=== %s (%s, %s) ===" % (s.name, s.backend, s.model))
        r = capture_one(s, args.out, timeout=args.timeout)
        reports.append(r)
        if r.get("ok"):
            print("  ok: %d events, exit %s, %ss, %s"
                  % (r["events"], r["exitCode"], r["seconds"], _fmt_usage(r.get("usage"))))
            if r.get("sessionFile"):
                print("  session corpus: %s" % r["sessionFile"])
            if r.get("denialsSent") is not None:
                print("  permission requests denied: %d" % r["denialsSent"])
        else:
            print("  FAILED: %s" % r.get("error", "unknown"))

    print("\n=== capture summary ===")
    tin = tout = 0
    cost = 0.0
    for r in reports:
        u = r.get("usage") or {}
        tin += (u.get("inputTokens") or 0) + (u.get("cachedInputTokens") or 0)
        tout += u.get("outputTokens") or 0
        cost += u.get("costUSD") or 0.0
        print("  %-16s %-8s %s" % (r["scenario"], "ok" if r.get("ok") else "FAILED",
                                   _fmt_usage(r.get("usage"))))
    print("  TOTAL: %d turns (claude %d / codex %d), %d in + %d out tokens, "
          "claude-reported cost $%.6f (codex exec reports no cost)"
          % (len(reports), turns["claude"], turns["codex"], tin, tout, cost))
    if os.path.realpath(args.out) == os.path.realpath(CORPUS):
        print("  ios mirror: %d file(s) updated" % len(sync_ios(args.out)))
    return 0 if all(r.get("ok") for r in reports) else 1


if __name__ == "__main__":
    sys.exit(main())
