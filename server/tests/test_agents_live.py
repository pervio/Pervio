#!/usr/bin/env python3
"""test_agents_live.py — Track B: the OPT-IN real-agent CONTRACT suite.

    python3 server/tests/test_agents_live.py            # skips everything, spends 0
    python3 server/tests/test_agents_live.py --list     # the plan + the cost model, FREE
    python3 server/tests/test_agents_live.py --rehearse # whole harness on SHIM agents, FREE
    python3 server/tests/test_agents_live.py --live     # THE REAL THING — spends quota
    python3 server/tests/test_agents_live.py --live --only B1 B5
    bash server/tests/run_all.sh --live                 # same, inside the suite runner

WHY IT EXISTS
    Everything else in server/tests/ drives the real scripts with a FAKE agent
    (server/tests/shim). That proves our plumbing agrees with our own imagination.
    This file is the other half: real `claude` and real `codex`, asserting the
    CONTRACT each backend owes the product — a result event with usage, a ledger
    that says done with tokens on it, references that really substitute, an MCP
    tool a real model picks on its own, and an approval a real turn honours.

    IT SPENDS REAL MONEY, so it is opt-in and never runs by default.

MODEL POLICY (deliberate, not laziness)
    CHEAP tier by default — claude-haiku-4-5 / gpt-5.4-mini. A pipe carries the
    same bytes whatever the model thinks, so the plumbing scenarios (B1/B2/B3/B5)
    never pay for judgement. Only the two scenarios that actually TEST judgement —
    "will the model pick the right tool by itself" (B4) and "will it call a named
    template tool with the right argument" (B6) — run on claude-opus-5, one each.

WHAT ONE FULL --live RUN ACTUALLY COST (measured 2026-08-07, not estimated)
    claude 2.1.181 / codex-cli 0.146.1, 8 claude turns + 3 codex turns:
        B1-claude  cheap      $0.015478     B1-codex  cheap   in 12079 / out 16
        B2-claude  cheap      $0.018099     B2-codex  cheap   in 12081 / out 17
        B3-claude  cheap      $0.019867     B3-codex  cheap   in 12084 / out 16
        B5-claude  cheap      $0.039341  (2 turns: one Allow, one Deny)
        B4-claude  EXPENSIVE  $0.243041  (the one paid judgement call)
        B6-claude  EXPENSIVE  $0.167727  (2 turns: the opus pick + the haiku step it launched)
        TOTAL      $0.503553 of claude quota; codex reports no cost field anywhere on
                   its stream, so its 3 turns can only be priced in tokens (~36k in).
    Two thirds of the bill is B4 + B6 — that is what buying judgement costs, and it
    is why there is exactly one of each.

BUDGET (enforced, not aspirational)
    The whole batch is capped at 25 claude / 15 codex turns; Track A's corpus
    capture already booked 8 claude / 5 codex of that, so Track B holds itself to
    the REMAINDER (17 / 10). `Budget` counts every CLI invocation this process is
    about to make — direct pervio-chat turns AND the agent steps a workflow will
    spawn — and REFUSES to start one that would cross the cap. A full `--live` run
    plans 8 claude + 3 codex turns. The counter is per-process (it cannot know
    about your previous runs), so `--list` prints the plan before you commit.

CREDENTIALS / ISOLATION (the honest version)
    Real agents need real credentials, so — exactly like server/tests/*_e2e.py and
    capture_corpus.py — this uses the machine's real claude/codex auth. What is new
    here is that it does NOT run against the real ~/.pervio: every scenario runs
    under a throwaway $HOME (`LiveHome`) whose credential dirs (.claude,
    .claude.json, .codex) are SYMLINKS to the real ones, while ~/.pervio is a
    fresh empty tree holding one link of its own, to the real credentials.env.
    Consequences, all of them deliberate:
      * pervio-orchestrate writes its run dirs, and pervio-mcp reads its templates,
        under the throwaway home — the user's real templates / schedules / archives
        / runs are never created, edited or deleted. A guard at the end of the run
        re-lists them and FAILS if a single entry appeared or vanished.
      * pervio-chat still finds ~/.pervio/credentials.env (that one file is
        linked into the fresh tree) and claude/codex still find their own auth,
        because those paths cross the symlinks.
      * the two side effects we cannot avoid are the ones capture_corpus.py already
        documents: claude records its conversation under ~/.claude/projects/<encoded
        workdir>/ and codex writes a rollout. We delete only OUR OWN claude project
        folders (name must be exactly the encoded form of a workdir this process
        created), and leave the codex rollout alone (invisible in the app — codex
        threads are listed by matching cwd, and the cwd no longer exists).
    Nothing else on disk is touched, and nothing pre-existing is ever removed.

EVERY CLAUDE SCENARIO NEEDS A CODEX TWIN — and three of them cannot have one
    B1/B2/B3 are symmetric pairs. B4 (MCP), B5 (approval) and B6 (named template
    tool) are claude-only, and the reason is not laziness — it is `codex exec`:
      * codex auto-cancels EVERY MCP tool call ("user cancelled MCP tool call",
        openai/codex#24135 + #16685), which is why pervio-chat carries
        `CODEX_MCP_READY=""` and mounts nothing at all for codex;
      * codex has no approval channel — `codex exec` is non-interactive and cannot
        ask, so there is no Allow/Deny to drive.
    Those skips are SELF-POLICING: each one first asserts, for free, that the
    blocker is still real in the source (the CODEX_MCP_READY gate, the
    `backend != codex` approval gate). The day someone flips either gate this file
    goes red and tells them to come write the twin.

WHAT EACH SCENARIO PINS
    B1  one plain turn        claude+codex  result/turn.completed + usage + exit code
    B2  workflow single step  claude+codex  ledger done, output landed, tokensIn/Out
    B3  command + agent step  claude+codex  dependency ORDER and {{ref}} substitution
    B4  MCP tool selection    claude only   a real model picks pervio_templates itself
    B5  approval Allow+Deny   claude only   allow really writes; deny really doesn't
    B6  named template tool   claude only   right tool, right ARG, workflow really ran
    B7  every scenario prints its own token/USD cost; a summary totals the run.
"""
import argparse
import base64
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.realpath(os.path.join(HERE, "..", ".."))
BIN = os.path.join(REPO, "server", "bin")
CHAT = os.path.join(BIN, "pervio-chat")
ORCH = os.path.join(BIN, "pervio-orchestrate")
SHIM = os.path.join(HERE, "shim")
REAL_HOME = os.path.expanduser("~")

# ---- model tiers -----------------------------------------------------------
HAIKU = "claude-haiku-4-5-20251001"   # cheapest claude tier — the plumbing scenarios
MINI = "gpt-5.4-mini"                 # cheapest codex tier  — the plumbing scenarios
OPUS = "claude-opus-5"                # judgement only: B4 (tool choice), B6 (named tool)

# ---- budget ----------------------------------------------------------------
# Whole batch: claude <= 25, codex <= 15. Track A's capture_corpus.py booked 8/5.
# Track B holds itself to the remainder and refuses to cross it.
TRACK_CAPS = {"claude": 17, "codex": 10}

# Every mkdtemp this process makes carries this token, so the claude-project
# cleanup can never match a folder that isn't ours.
NONCE_TAG = "perviolive"

results = []          # (name, ok) for every assertion
skips = []            # (scenario id, reason) for every honest skip
spend = []            # per-scenario cost rows (B7)


# --------------------------------------------------------------------------- #
# reporting
# --------------------------------------------------------------------------- #

def check(name, cond, detail=""):
    ok = bool(cond)
    results.append((name, ok))
    print(("PASS " if ok else "FAIL ") + name
          + (("  [" + str(detail)[:300] + "]") if (detail and not ok) else ""))
    return ok


class SkipScenario(Exception):
    """Raised by a scenario that physically cannot exist on this backend. The
    reason is printed and recorded; the honesty assertions run FIRST."""


# --------------------------------------------------------------------------- #
# budget
# --------------------------------------------------------------------------- #

class BudgetExceeded(Exception):
    pass


class Budget(object):
    """Counts CLI INVOCATIONS (not tokens) per backend and refuses to start one
    that would cross the cap. Reserve BEFORE spawning: an over-cap run must not
    burn the turn and then complain."""

    def __init__(self, caps):
        self.caps = dict(caps)
        self.used = {b: 0 for b in caps}

    def take(self, backend, n=1, why=""):
        cap = self.caps.get(backend)
        if cap is None:
            raise BudgetExceeded("unknown backend %r" % backend)
        if self.used[backend] + n > cap:
            raise BudgetExceeded(
                "%s turn cap reached (%d/%d used, %s wants %d more) — cut a "
                "scenario instead of raising the cap"
                % (backend, self.used[backend], cap, why or "this scenario", n))
        self.used[backend] += n

    def line(self):
        return "  ".join("%s %d/%d turns" % (b, self.used[b], self.caps[b])
                         for b in sorted(self.caps))


BUDGET = Budget(TRACK_CAPS)


def _refuses(budget, backend):
    try:
        budget.take(backend, 1, "probe")
        return False
    except BudgetExceeded:
        return True


# --------------------------------------------------------------------------- #
# cost meter (B7)
# --------------------------------------------------------------------------- #

class Cost(object):
    """Token/USD totals harvested from REAL events — claude's terminal `result`
    (usage + total_cost_usd), codex's `turn.completed` (usage; codex exec reports
    no cost field at all, which is why costUSD stays None on that side)."""

    def __init__(self):
        self.tin = 0
        self.cached = 0
        self.tout = 0
        self.usd = 0.0
        self.usd_seen = False
        self.turns = 0

    def add_events(self, events):
        for o in events:
            if not isinstance(o, dict):
                continue
            t = o.get("type")
            if t == "result":                                     # claude
                self.turns += 1
                u = o.get("usage") or {}
                self.tin += _i(u.get("input_tokens"))
                self.cached += _i(u.get("cache_read_input_tokens")) + \
                    _i(u.get("cache_creation_input_tokens"))
                self.tout += _i(u.get("output_tokens"))
                if isinstance(o.get("total_cost_usd"), (int, float)):
                    self.usd += float(o["total_cost_usd"])
                    self.usd_seen = True
            elif t == "turn.completed":                           # codex
                self.turns += 1
                u = o.get("usage") or {}
                self.tin += _i(u.get("input_tokens"))
                self.cached += _i(u.get("cached_input_tokens"))
                self.tout += _i(u.get("output_tokens"))
        return self

    def merge(self, other):
        self.tin += other.tin
        self.cached += other.cached
        self.tout += other.tout
        self.usd += other.usd
        self.usd_seen = self.usd_seen or other.usd_seen
        self.turns += other.turns
        return self

    def text(self):
        s = ("%d turn(s)  in=%d (cached %d)  out=%d"
             % (self.turns, self.tin, self.cached, self.tout))
        # `$—` is not "free": codex exec simply reports no cost field anywhere on
        # its stream (Track A's corpus records the same gap), so a codex row can
        # only ever be priced in tokens.
        return s + ("  $%.6f" % self.usd if self.usd_seen else "  $— (no cost field on the stream)")


def _i(v):
    return v if isinstance(v, int) and not isinstance(v, bool) else 0


def cost_of_run_dir(rd):
    """Every agent turn a workflow spawned wrote <rd>/<stepId>.jsonl — the same
    bytes _step_output parses. Sum them."""
    c = Cost()
    try:
        names = sorted(os.listdir(rd))
    except OSError:
        return c
    for fn in names:
        if fn.endswith(".jsonl"):
            c.add_events(read_events(os.path.join(rd, fn)))
    return c


def read_events(path):
    out = []
    try:
        with open(path, "r", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        pass
    return out


# --------------------------------------------------------------------------- #
# throwaway $HOME with real credentials
# --------------------------------------------------------------------------- #

# Symlinked straight through to the real home: this is what makes `claude` and
# `codex` authenticate. .claude/.claude.json (claude's auth + config), .codex
# (codex's login); .local/.config ride along because find_cli probes
# ~/.local/bin and a CLI may keep state under XDG.
#
# ~/.pervio is NOT on this list and must never be: it is the tree the scenarios
# write into. It is born empty, and the one file in it that carries a credential
# is linked in by itself (PERVIO_CRED_FILES). Until 2026-11-17 this list named
# ".pervio" — a leftover from when the credentials had a directory of their own —
# which linked the REAL tree in whole and made every promise in the docstring
# above false: on a machine whose real ~/.pervio already held templates/ the
# suite died at start-up, and on one that did not it would have written its
# scenarios into the person's own data. test_live_home.py now holds the line.
CRED_LINKS = (".claude", ".claude.json", ".codex", ".local", ".config")
PERVIO_CRED_FILES = ("credentials.env",)


class LiveHome(object):
    """A $HOME whose ~/.pervio is FRESH and whose credentials are the real ones.

    Everything Pervio owns (templates / wf / schedules / archives) lives inside
    the throwaway tree, so no scenario can create, edit or delete anything in the
    user's real ~/.pervio. Everything the CLIs own is reached through a symlink,
    so the turns actually authenticate."""

    def __init__(self):
        self.path = tempfile.mkdtemp(prefix=NONCE_TAG + "home_", dir="/tmp")
        for name in CRED_LINKS:
            src = os.path.join(REAL_HOME, name)
            if os.path.exists(src):
                os.symlink(src, os.path.join(self.path, name))
        # mkdir, not makedirs: if anything has put a ~/.pervio here already (a
        # link, above all) this must stop, not quietly build inside it.
        os.mkdir(self.pervio, 0o700)
        for sub in ("templates", "wf", "schedules", "archives"):
            os.mkdir(os.path.join(self.pervio, sub), 0o700)
        for name in PERVIO_CRED_FILES:
            src = os.path.join(REAL_HOME, ".pervio", name)
            if os.path.isfile(src):
                os.symlink(src, os.path.join(self.pervio, name))
        self.assert_isolated()

    def assert_isolated(self):
        """The red line as a refusal, not a hope: this home's ~/.pervio is a
        directory of its own, inside the throwaway tree. Raises otherwise, before
        a single scenario can run against the person's real data."""
        real = os.path.realpath(os.path.join(REAL_HOME, ".pervio"))
        mine = os.path.realpath(self.pervio)
        inside = mine.startswith(os.path.realpath(self.path) + os.sep)
        if os.path.islink(self.pervio) or mine == real or not inside:
            raise RuntimeError("LiveHome: %s resolves to %s — refusing to run anything "
                               "against the real ~/.pervio" % (self.pervio, mine))

    @property
    def pervio(self):
        return os.path.join(self.path, ".pervio")

    @property
    def templates(self):
        return os.path.join(self.pervio, "templates")

    def env(self, **extra):
        e = dict(os.environ, HOME=self.path)
        e.pop("PERVIO_WF_ID", None)      # a machine turn gets no MCP mount (B4/B6 need one)
        e.update(extra)
        return e

    def write_template(self, filename, obj):
        p = os.path.join(self.templates, filename)
        with open(p, "w") as f:
            json.dump(obj, f, ensure_ascii=False)
        return p

    def wf_dir(self, wf):
        return os.path.join(self.pervio, "wf", wf)

    def cleanup(self):
        """rmtree does NOT follow directory symlinks (it unlinks them), so the
        real ~/.claude & friends are never walked. Unlink them explicitly first
        anyway — this is the one place a bug would be unrecoverable."""
        for name in CRED_LINKS:
            p = os.path.join(self.path, name)
            if os.path.islink(p):
                os.unlink(p)
        for name in PERVIO_CRED_FILES:
            p = os.path.join(self.pervio, name)
            if os.path.islink(p):
                os.unlink(p)
        stray = [n for n in os.listdir(self.path)
                 if os.path.islink(os.path.join(self.path, n))]
        if stray:
            # Refuse to recurse anywhere a link we did not expect could lead.
            # Leaking one /tmp dir beats any chance of walking the real home.
            print("NOTE: %s still holds symlink(s) %s — left in place, not deleted"
                  % (self.path, stray))
            return
        shutil.rmtree(self.path, ignore_errors=True)


def encode_path(p):
    """pervio-sessions.encode: the ~/.claude/projects folder name for a cwd."""
    return re.sub(r"[^a-zA-Z0-9]", "-", p)


def sweep_claude_projects(workdirs):
    """Delete ONLY the project folders these workdirs produced. A folder is
    removed when its name is exactly the encoded form of one of our own
    (NONCE_TAG-bearing) temp dirs, or that form plus a '-' suffix."""
    root = os.path.join(REAL_HOME, ".claude", "projects")
    try:
        present = os.listdir(root)
    except OSError:
        return
    keys = set()
    for d in workdirs:
        if NONCE_TAG not in d:
            continue
        keys.add(encode_path(d))
        keys.add(encode_path(os.path.realpath(d)))
    for name in present:
        if any(name == k or name.startswith(k + "-") for k in keys):
            shutil.rmtree(os.path.join(root, name), ignore_errors=True)


def mkworkdir(tag):
    return tempfile.mkdtemp(prefix="%s_%s_" % (NONCE_TAG, tag), dir="/tmp")


def mkrepo(tag):
    """A git repo, same shape the existing e2e tests build."""
    d = mkworkdir(tag)
    for a in (["init", "-q", "-b", "main"], ["config", "user.email", "t@t"],
              ["config", "user.name", "t"]):
        subprocess.run(["git", "-C", d] + a, capture_output=True)
    with open(os.path.join(d, "base.txt"), "w") as f:
        f.write("base\n")
    subprocess.run(["git", "-C", d, "add", "-A"], capture_output=True)
    subprocess.run(["git", "-C", d, "commit", "-qm", "base"], capture_output=True)
    return d


# --------------------------------------------------------------------------- #
# agent turns
# --------------------------------------------------------------------------- #

def _killpg(p):
    """Kill the whole session: the agent is a grandchild behind a bash wrapper
    (and, on the approval path, a pipe), so p.kill() would leave the turn — and
    its billing — running. Same reason pervio-orchestrate._call_gated does it."""
    try:
        os.killpg(os.getpgid(p.pid), signal.SIGKILL)
    except OSError:
        p.kill()


class Turn(object):
    def __init__(self, events, rc, requests, resolutions):
        self.events = events
        self.rc = rc
        self.requests = requests        # permission_request events, in order
        self.resolutions = resolutions  # permission_resolved events, in order
        self.cost = Cost().add_events(events)

    def of_type(self, t):
        return [o for o in self.events if o.get("type") == t]

    @property
    def result(self):
        r = self.of_type("result")
        return r[-1] if r else {}

    def final_text(self):
        if self.result:
            return self.result.get("result") or ""
        last = ""
        for o in self.events:                                    # codex
            if o.get("type") == "item.completed":
                it = o.get("item") or {}
                if it.get("type") == "agent_message" and it.get("text"):
                    last = it["text"]
        return last

    def tool_uses(self):
        """(name, input) for every tool_use claude emitted, plus codex's
        command_execution / file_change items."""
        out = []
        for o in self.events:
            if o.get("type") == "assistant":
                for c in ((o.get("message") or {}).get("content") or []):
                    if isinstance(c, dict) and c.get("type") == "tool_use":
                        out.append((c.get("name"), c.get("input") or {}))
            elif o.get("type") == "item.completed":
                it = o.get("item") or {}
                if it.get("type") in ("command_execution", "file_change"):
                    out.append((it.get("type"), it))
        return out

    def tool_results(self):
        """(tool_use_id, is_error, text) for every tool_result claude got back."""
        out = []
        for o in self.events:
            if o.get("type") != "user":
                continue
            for c in ((o.get("message") or {}).get("content") or []):
                if isinstance(c, dict) and c.get("type") == "tool_result":
                    body = c.get("content")
                    if isinstance(body, list):
                        body = " ".join(x.get("text", "") for x in body
                                        if isinstance(x, dict))
                    out.append((c.get("tool_use_id"), bool(c.get("is_error")),
                                body if isinstance(body, str) else json.dumps(body)))
        return out


def build_cmd(prompt, backend, workdir, model=None, perm="default", sandbox=None,
              effort="low", pervio_ctx=False, approve_sid=None, shim_hint=None):
    """The SAME argument shape pervio-orchestrate._run_agent_turn builds — the
    point of going through pervio-chat is that we assert on the bytes production
    parses, not on a private invocation."""
    if shim_hint is not None:
        prompt = prompt + "\nSHIM:" + json.dumps(shim_hint)
    b64 = base64.b64encode(prompt.encode("utf-8")).decode("ascii")
    cmd = [CHAT, "--text", "--backend", backend, "--dir", workdir, "--prompt-b64", b64]
    if backend == "codex":
        cmd += ["--sandbox", sandbox or "read-only"]
    else:
        cmd += ["--perm", perm]
    if model:
        cmd += ["--model", model]
    if effort:
        cmd += ["--effort", effort]
    if pervio_ctx:
        cmd += ["--pervio-context"]
    if approve_sid:
        cmd += ["--approve-sid", approve_sid]
    return cmd


def run_turn(home, prompt, backend, workdir, timeout=300, **kw):
    """Run mode: stdout is a regular FILE, exactly like the orchestrator's
    out.jsonl, so pervio-chat skips the pervio-hb heartbeat pipe."""
    cmd = build_cmd(prompt, backend, workdir, **kw)
    fd, path = tempfile.mkstemp(prefix=NONCE_TAG + "_out_", suffix=".jsonl", dir="/tmp")
    os.close(fd)
    try:
        with open(path, "wb") as out:
            p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=out,
                                 stderr=subprocess.DEVNULL, env=home.env(),
                                 start_new_session=True)
            try:
                p.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                _killpg(p)
                p.communicate()
        return Turn(read_events(path), p.returncode if p.returncode is not None else 1,
                    [], [])
    finally:
        os.unlink(path)


def run_turn_approval(home, prompt, workdir, decide, timeout=300, **kw):
    """Chat mode: stdout is a PIPE, the ONLY configuration in which pervio-chat
    turns the approval bridge on (`! -f /dev/stdout`) and pervio-chat-stream tees
    pervio-approve's permission_request lines onto the stream.

    `decide(request) -> (behavior, message)` answers each one through the very
    door the phone uses: a SEPARATE `pervio-chat respond` invocation writing one
    line to the per-session control FIFO."""
    sid = NONCE_TAG + os.urandom(5).hex()          # matches pervio-chat's ^[A-Za-z0-9_-]{1,64}$
    cmd = build_cmd(prompt, "claude", workdir, approve_sid=sid, **kw)
    env = home.env()
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, env=env, start_new_session=True)
    events, requests, resolutions = [], [], []

    def pump():
        for raw in p.stdout:
            try:
                o = json.loads(raw.decode("utf-8", "replace"))
            except ValueError:
                continue
            events.append(o)
            if o.get("type") == "permission_resolved":
                resolutions.append(o)
            elif o.get("type") == "permission_request":
                requests.append(o)
                behavior, message = decide(o)
                rid = o.get("request_id") or o.get("tool_use_id") or ""
                subprocess.run([CHAT, "respond", "--sid", sid, "--request-id", rid,
                                "--behavior", behavior, "--message", message],
                               env=env, capture_output=True, timeout=20)

    t = threading.Thread(target=pump, daemon=True)
    t.start()
    try:
        p.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        _killpg(p)
    t.join(timeout=15)
    # pervio-chat-stream rmtree's the per-turn session dir on a clean exit; a killed
    # turn never gets there, so sweep OUR nonce — and only a direct child of
    # ~/.pervio/chat, the same guard pervio-chat-stream applies to itself.
    root = os.path.realpath(os.path.join(home.path, ".pervio", "chat"))
    left = os.path.realpath(os.path.join(root, sid))
    if sid.startswith(NONCE_TAG) and os.path.dirname(left) == root and os.path.isdir(left):
        shutil.rmtree(left, ignore_errors=True)
    return Turn(events, p.returncode if p.returncode is not None else 1,
                requests, resolutions)


# --------------------------------------------------------------------------- #
# workflows
# --------------------------------------------------------------------------- #

def start_wf(home, spec, extra_env=None):
    b64 = base64.b64encode(json.dumps(spec).encode()).decode()
    p = subprocess.run([sys.executable, ORCH, "start", "--spec-b64", b64],
                       env=home.env(**(extra_env or {})), capture_output=True, text=True)
    try:
        return json.loads(p.stdout.strip().splitlines()[-1])["wfId"]
    except (ValueError, KeyError, IndexError):
        raise RuntimeError("start gave no wfId: %r / %r" % (p.stdout[:300], p.stderr[:300]))


def wait_wf(home, wf, timeout=420, extra_env=None):
    env = home.env(**(extra_env or {}))
    led = {}
    for _ in range(timeout):
        q = subprocess.run([sys.executable, ORCH, "status", "--wf", wf],
                           env=env, capture_output=True, text=True)
        try:
            led = json.loads(q.stdout)
        except ValueError:
            led = {}
        if led.get("status") in ("done", "failed"):
            return led
        time.sleep(1)
    return led


def delete_wf(home, wf, extra_env=None):
    subprocess.run([sys.executable, ORCH, "delete", "--wf", wf],
                   env=home.env(**(extra_env or {})), capture_output=True)


def step(led, sid):
    return next((s for s in (led.get("steps") or []) if s.get("id") == sid), {})


def steps_brief(led):
    return json.dumps([(s.get("id"), s.get("status"), (s.get("error") or "")[:70])
                       for s in (led.get("steps") or [])], ensure_ascii=False)


# --------------------------------------------------------------------------- #
# scenarios
# --------------------------------------------------------------------------- #

SCENARIOS = []


def scenario(sid, backend, tier, title, twin=None, no_twin=None, rehearsable=False,
             plans=None):
    """`plans` = the CLI invocations this scenario will make, {backend: n} — the
    budget reserves them BEFORE the first process is spawned."""
    def deco(fn):
        SCENARIOS.append({"sid": sid, "backend": backend, "tier": tier, "title": title,
                          "twin": twin, "no_twin": no_twin, "fn": fn,
                          "rehearsable": rehearsable, "plans": plans or {}})
        return fn
    return deco


class Ctx(object):
    def __init__(self, home, rehearse):
        self.home = home
        self.rehearse = rehearse
        self.workdirs = []

    def workdir(self, tag, git=False):
        d = mkrepo(tag) if git else mkworkdir(tag)
        self.workdirs.append(d)
        return d

    def model(self, backend, tier):
        """In rehearsal the shim ignores the model; keep the real ids anyway so
        the argv a rehearsal builds is the argv a live run builds."""
        if backend == "codex":
            return MINI if tier == "cheap" else "gpt-5.6-sol"
        return HAIKU if tier == "cheap" else OPUS

    def shim(self, hint):
        """SHIM: instructions are appended ONLY in rehearsal — a live prompt is
        never polluted by them."""
        return hint if self.rehearse else None

    def model_check(self, name, cond, detail=""):
        """An assertion that depends on what a MODEL decided. The shim cannot
        decide anything, so in rehearsal it is reported as not-applicable
        instead of silently passing."""
        if self.rehearse:
            print("n/a  " + name + "  (model-dependent; shim rehearsal)")
            return True
        return check(name, cond, detail)


# ---- B1: one plain turn ---------------------------------------------------- #

@scenario("B1-claude", "claude", "cheap", "one plain turn: result event + usage + exit code",
          twin="B1-codex", rehearsable=True, plans={"claude": 1})
def b1_claude(ctx):
    wd = ctx.workdir("b1c")
    t = run_turn(ctx.home, "Reply with exactly this word and nothing else: PONG",
                 "claude", wd, model=ctx.model("claude", "cheap"), perm="default",
                 shim_hint=ctx.shim({"text": "PONG", "usage": {"input_tokens": 11,
                                                               "output_tokens": 3}}))
    check("B1-claude exit code 0", t.rc == 0, t.rc)
    check("B1-claude exactly one terminal result event", len(t.of_type("result")) == 1,
          [o.get("type") for o in t.events][-5:])
    r = t.result
    check("B1-claude result is a non-error success",
          r.get("is_error") is False and r.get("subtype") == "success", r.get("subtype"))
    ctx.model_check("B1-claude the model answered the asked word",
                    "PONG" in (t.final_text() or "").upper(), t.final_text()[:120])
    u = r.get("usage") or {}
    check("B1-claude result carries integer usage",
          isinstance(u.get("input_tokens"), int) and isinstance(u.get("output_tokens"), int), u)
    if not ctx.rehearse:
        check("B1-claude result carries total_cost_usd > 0",
              isinstance(r.get("total_cost_usd"), (int, float)) and r["total_cost_usd"] > 0,
              r.get("total_cost_usd"))
    return t.cost


@scenario("B1-codex", "codex", "cheap", "one plain turn: turn.completed + usage + exit code",
          twin="B1-claude", rehearsable=True, plans={"codex": 1})
def b1_codex(ctx):
    wd = ctx.workdir("b1x")
    t = run_turn(ctx.home, "Reply with exactly this word and nothing else: PONG",
                 "codex", wd, model=ctx.model("codex", "cheap"), sandbox="read-only",
                 shim_hint=ctx.shim({"text": "PONG", "usage": {"input_tokens": 12,
                                                               "output_tokens": 4}}))
    check("B1-codex exit code 0", t.rc == 0, t.rc)
    check("B1-codex no turn.failed", not t.of_type("turn.failed"), t.of_type("turn.failed")[:1])
    done = t.of_type("turn.completed")
    check("B1-codex exactly one terminal turn.completed", len(done) == 1,
          [o.get("type") for o in t.events][-5:])
    ctx.model_check("B1-codex the model answered the asked word",
                    "PONG" in (t.final_text() or "").upper(), t.final_text()[:120])
    u = (done[0].get("usage") if done else {}) or {}
    check("B1-codex turn.completed carries integer usage",
          isinstance(u.get("input_tokens"), int) and isinstance(u.get("output_tokens"), int), u)
    check("B1-codex thread.started carries a thread id",
          bool((t.of_type("thread.started") or [{}])[0].get("thread_id")))
    return t.cost


# ---- B2: workflow single step ---------------------------------------------- #

def _b2(ctx, backend):
    wd = ctx.workdir("b2" + backend[0], git=True)
    tier = ctx.model(backend, "cheap")
    s = {"id": "solo", "backend": backend, "effort": "low", "model": tier,
         "prompt": "Reply with exactly this word and nothing else: LEDGER"}
    if backend == "codex":
        s["sandbox"] = "read-only"
    else:
        s["perm"] = "plan"
    if ctx.rehearse:
        s["prompt"] += "\nSHIM:" + json.dumps({"text": "LEDGER",
                                               "usage": {"input_tokens": 21, "output_tokens": 5}})
    wf = start_wf(ctx.home, {"name": "b2-" + backend, "dir": wd, "steps": [s]})
    led = wait_wf(ctx.home, wf)
    st = step(led, "solo")
    p = "B2-" + backend
    check(p + " run reached done", led.get("status") == "done", steps_brief(led))
    check(p + " the step's ledger row says done", st.get("status") == "done",
          (st.get("error") or "")[:200])
    ctx.model_check(p + " the step's output landed in the ledger",
                    "LEDGER" in (st.get("output") or "").upper(), (st.get("output") or "")[:120])
    check(p + " token accounting fields are on the ledger row",
          isinstance(st.get("tokensIn"), int) and isinstance(st.get("tokensOut"), int)
          and st["tokensIn"] > 0 and st["tokensOut"] > 0,
          {k: st.get(k) for k in ("tokensIn", "tokensOut")})
    rd = ctx.home.wf_dir(wf)
    check(p + " the turn's raw event stream was kept next to the ledger",
          os.path.exists(os.path.join(rd, "solo.jsonl")), sorted(os.listdir(rd))[:12])
    check(p + " the run dir is inside the throwaway home, not the user's ~/.pervio",
          os.path.realpath(rd).startswith(os.path.realpath(ctx.home.pervio)), rd)
    c = cost_of_run_dir(rd)
    delete_wf(ctx.home, wf)
    return c


@scenario("B2-claude", "claude", "cheap", "workflow single step: ledger done + output + tokens",
          twin="B2-codex", rehearsable=True, plans={"claude": 1})
def b2_claude(ctx):
    return _b2(ctx, "claude")


@scenario("B2-codex", "codex", "cheap", "workflow single step: ledger done + output + tokens",
          twin="B2-claude", rehearsable=True, plans={"codex": 1})
def b2_codex(ctx):
    return _b2(ctx, "codex")


# ---- B3: a command step feeding an agent step ------------------------------ #

def _b3(ctx, backend):
    """The command step's stdout is the ONLY place the word exists. If the agent
    step answers with its lowercase form, {{seed.output}} really substituted AND
    the runner really waited for the producer."""
    wd = ctx.workdir("b3" + backend[0], git=True)
    agent = {"id": "use", "backend": backend, "effort": "low",
             "model": ctx.model(backend, "cheap"),
             "prompt": "Reply with ONLY the lowercase form of this word, nothing "
                       "else, no punctuation: {{seed.output}}"}
    if backend == "codex":
        agent["sandbox"] = "read-only"
    else:
        agent["perm"] = "plan"
    if ctx.rehearse:
        agent["prompt"] += "\nSHIM:" + json.dumps({"text": "orange"})
    spec = {"name": "b3-" + backend, "dir": wd, "steps": [
        {"id": "seed", "command": "printf ORANGE"}, agent]}
    wf = start_wf(ctx.home, spec)
    led = wait_wf(ctx.home, wf)
    seed, use = step(led, "seed"), step(led, "use")
    p = "B3-" + backend
    check(p + " run reached done", led.get("status") == "done", steps_brief(led))
    check(p + " the command step produced the word", (seed.get("output") or "").strip() == "ORANGE",
          repr(seed.get("output"))[:120])
    check(p + " the agent step waited for the command step (startedAt >= its endedAt)",
          isinstance(use.get("startedAt"), (int, float))
          and isinstance(seed.get("endedAt"), (int, float))
          and use["startedAt"] >= seed["endedAt"],
          {k: (seed.get(k), use.get(k)) for k in ("startedAt", "endedAt")})
    out = (use.get("output") or "").strip()
    ctx.model_check(p + " the agent saw the SUBSTITUTED value, not the literal ref",
                    "orange" in out.lower() and "{{" not in out, repr(out)[:160])
    check(p + " no unexpanded {{seed.output}} survived into the output",
          "{{" not in out, repr(out)[:160])
    rd = ctx.home.wf_dir(wf)
    check(p + " the command step spent no model turn (no event stream of its own)",
          not os.path.exists(os.path.join(rd, "seed.jsonl")), sorted(os.listdir(rd))[:12])
    c = cost_of_run_dir(rd)
    delete_wf(ctx.home, wf)
    return c


@scenario("B3-claude", "claude", "cheap", "command step + agent step: order + {{ref}} substitution",
          twin="B3-codex", rehearsable=True, plans={"claude": 1})
def b3_claude(ctx):
    return _b3(ctx, "claude")


@scenario("B3-codex", "codex", "cheap", "command step + agent step: order + {{ref}} substitution",
          twin="B3-claude", rehearsable=True, plans={"codex": 1})
def b3_codex(ctx):
    return _b3(ctx, "codex")


# ---- B4: will a real model pick the right MCP tool by itself? --------------- #

MARKER_TPL = "Zarquon Sweep"     # a name that exists nowhere but our fake templates dir


def seed_templates(home):
    """Two wrappers in the THROWAWAY home's templates dir. `pervio_templates`
    reads them; the real ~/.pervio/templates is never opened."""
    home.write_template("zarquon.json", {
        "name": MARKER_TPL, "summary": "巡检 Zarquon 星区的示例工作流(仅用于契约测试)。",
        "spec": {"name": "zarquon", "dir": "/tmp", "steps": [
            {"id": "noop", "command": "printf zarquon"}]}})
    home.write_template("bellwether.json", {
        "name": "Bellwether Digest", "summary": "另一个示例工作流(仅用于契约测试)。",
        "spec": {"name": "bellwether", "dir": "/tmp", "steps": [
            {"id": "noop", "command": "printf bellwether"}]}})


@scenario("B4-claude", "claude", "EXPENSIVE",
          "MCP: a real model picks pervio_templates on its own",
          twin=None, plans={"claude": 1},
          no_twin="`codex exec` auto-cancels EVERY MCP tool call (\"user cancelled MCP "
                  "tool call\"; openai/codex#24135 + #16685) and no config suppresses it, "
                  "so pervio-chat deliberately mounts NOTHING for codex "
                  "(CODEX_MCP_READY=\"\"). There is no codex MCP call to contract-test.")
def b4_claude(ctx):
    seed_templates(ctx.home)
    wd = ctx.workdir("b4c")
    # The prompt names NO tool. Picking pervio_templates over Bash archaeology is
    # exactly the judgement this (expensive) scenario buys.
    t = run_turn(ctx.home,
                 "这台服务器上都有哪些现成的工作流可以跑?把名字列出来就行,不用启动任何东西。",
                 "claude", wd, model=OPUS, perm="default", effort="low",
                 pervio_ctx=True, timeout=420)
    names = [n for n, _ in t.tool_uses()]
    check("B4-claude exit code 0", t.rc == 0, t.rc)
    check("B4-claude the perviotools MCP server was mounted at all",
          any(isinstance(n, str) and n.startswith("mcp__perviotools__") for n in names)
          or any("perviotools" in json.dumps(o.get("mcp_servers", ""))
                 for o in t.of_type("system")),
          names)
    check("B4-claude the model chose pervio_templates ITSELF (no tool named in the prompt)",
          "mcp__perviotools__pervio_templates" in names, names)
    errs = [txt for _, is_err, txt in t.tool_results() if is_err]
    check("B4-claude every tool call the model made came back without an error",
          not errs, errs[:1])
    check("B4-claude the answer repeats a template that only exists in the throwaway home",
          MARKER_TPL.split()[0].lower() in (t.final_text() or "").lower(),
          (t.final_text() or "")[:220])
    # Informational, deliberately NOT an assertion: the contract is "the model can
    # reach the tool", and failing a paid turn because it also ran one `ls` would be
    # a flaky red, not a regression. Printed so a drift toward shell archaeology is
    # still visible to whoever reads the run.
    print("     tools the model used: %s" % (names or "(none)"))
    return t.cost


@scenario("B4-codex", "codex", "cheap", "MCP tool call — physically impossible on codex",
          twin="B4-claude", rehearsable=True, plans={})
def b4_codex(ctx):
    """Self-policing skip: assert the blocker is STILL REAL in the source. The day
    someone flips CODEX_MCP_READY this goes red and demands the twin."""
    src = open(os.path.join(BIN, "pervio-chat")).read()
    check("B4-codex the skip is honest: pervio-chat still mounts NO MCP for codex",
          re.search(r'^\s*CODEX_MCP_READY=""\s*$', src, re.M) is not None,
          "CODEX_MCP_READY is no longer empty — codex can mount MCP now, so this "
          "scenario must be written for real")
    check("B4-codex the codex mount is gated on that flag",
          re.search(r'if \[\[ -n "\$CODEX_MCP_READY".*codex_pervio_mcp', src, re.S) is not None)
    raise SkipScenario(
        "codex exec auto-cancels every MCP tool call (\"user cancelled MCP tool call\"); "
        "probed dead 2026-08-04, tracked upstream as openai/codex#24135 + #16685. "
        "pervio-chat therefore mounts nothing for codex (CODEX_MCP_READY=\"\"), so there "
        "is no codex MCP call in production to contract-test. Verified above, not assumed.")


# ---- B5: the approval channel, Allow and Deny ------------------------------- #

@scenario("B5-claude", "claude", "cheap", "approval: a real Allow writes, a real Deny doesn't",
          twin=None, plans={"claude": 2},
          no_twin="codex has no approval channel at all: `codex exec` is non-interactive "
                  "and cannot ask (--permission-prompt-tool / allowlists do not exist). "
                  "Its whole permission surface is --sandbox, which gates writes but never "
                  "produces an Allow/Deny request to answer.")
def b5_claude(ctx):
    cost = Cost()

    # --- Allow ---
    wd = ctx.workdir("b5a")
    target = os.path.join(wd, "allowed.txt")
    t = run_turn_approval(
        ctx.home,
        "Use the Write tool to create a file named allowed.txt in the current "
        "directory containing exactly the line: ok\nThen reply with the single word DONE.",
        wd, decide=lambda req: ("allow", ""),
        model=HAIKU, perm="default", effort="low", timeout=300)
    cost.merge(t.cost)
    check("B5-allow the turn asked for permission at all", len(t.requests) >= 1,
          [o.get("type") for o in t.events][:8])
    check("B5-allow the request named the Write tool and its input",
          any(r.get("tool_name") == "Write" and (r.get("input") or {}).get("file_path")
              for r in t.requests), t.requests[:1])
    check("B5-allow pervio-approve reported the decision back on the stream",
          any(r.get("behavior") == "allow" for r in t.resolutions), t.resolutions[:2])
    check("B5-allow the approved Write REALLY happened on disk",
          os.path.exists(target) and "ok" in open(target).read(), os.listdir(wd))
    check("B5-allow the turn ended without error", t.result.get("is_error") is False,
          {k: t.result.get(k) for k in ("is_error", "subtype")})
    check("B5-allow nothing was recorded as denied", not (t.result.get("permission_denials") or []),
          t.result.get("permission_denials"))

    # --- Deny ---
    wd2 = ctx.workdir("b5d")
    target2 = os.path.join(wd2, "denied.txt")
    t2 = run_turn_approval(
        ctx.home,
        "Use the Write tool to create a file named denied.txt in the current "
        "directory containing exactly the line: nope\nThen reply with the single word DONE.",
        wd2, decide=lambda req: ("deny", "denied by the live contract suite"),
        model=HAIKU, perm="default", effort="low", timeout=300)
    cost.merge(t2.cost)
    check("B5-deny the turn asked for permission at all", len(t2.requests) >= 1,
          [o.get("type") for o in t2.events][:8])
    check("B5-deny pervio-approve reported the deny back on the stream",
          any(r.get("behavior") == "deny" for r in t2.resolutions), t2.resolutions[:2])
    check("B5-deny the refused Write really did NOT happen on disk",
          not os.path.exists(target2), os.listdir(wd2))
    check("B5-deny the denial is recorded on the result event",
          any(d.get("tool_name") == "Write"
              for d in (t2.result.get("permission_denials") or [])),
          t2.result.get("permission_denials"))
    check("B5-deny a denial is not an error — the turn still completes cleanly",
          t2.result.get("is_error") is False and t2.rc == 0,
          {"is_error": t2.result.get("is_error"), "rc": t2.rc})
    return cost


@scenario("B5-codex", "codex", "cheap", "approval flow — physically impossible on codex",
          twin="B5-claude", rehearsable=True, plans={})
def b5_codex(ctx):
    """Self-policing skip: the approval bridge's own gate must still exclude codex."""
    src = open(os.path.join(BIN, "pervio-chat")).read()
    check("B5-codex the skip is honest: the approval bridge still refuses codex",
          re.search(r'if \[\[ "\$backend" != "codex" && -n "\$approve_sid"', src) is not None,
          "the approve_mode gate no longer excludes codex — write the twin")
    check("B5-codex codex still runs with approvals disabled outright",
          'approval_policy="never"' in src)
    raise SkipScenario(
        "codex exec is non-interactive and has no approval channel — no "
        "--permission-prompt-tool, no allowlist, approval_policy is pinned to "
        "\"never\" and the sandbox is the only gate. pervio-chat's approval bridge "
        "excludes the codex backend by construction. Verified above, not assumed.")


# ---- B6: a named template tool, launched with an argument ------------------- #

B6_SLUG = "live_echo"
B6_WORD = "PERSIMMON"


@scenario("B6-claude", "claude", "EXPENSIVE",
          "named template tool: right tool, right ARG, workflow really ran",
          twin=None, plans={"claude": 2},
          no_twin="two independent blockers, either one fatal: codex cannot call an MCP "
                  "tool at all (openai/codex#24135), and a named template tool is a SPEND "
                  "verb kept off the read-only allowlist on purpose, so it can only be "
                  "reached through the Allow/Deny sheet codex does not have.")
def b6_claude(ctx):
    """The expensive turn buys ONE judgement: given a wrapper named in Chinese and
    a word, does the model reach for pervio_run_<slug> and pass the word as the
    declared parameter? Everything after that is mechanical and cheap — the launch
    it triggers is a single haiku step, and its output is the proof the argument
    survived all the way through {{param.word}} substitution."""
    seed_templates(ctx.home)
    wd = ctx.workdir("b6c")
    ctx.home.write_template("echo.json", {
        "name": "实时回声", "summary": "把一个词原样回声出来的示例工作流(契约测试用)。",
        "expose": True, "slug": B6_SLUG,
        "params": [{"name": "word", "label": "要回声的词", "required": True}],
        "spec": {"name": "live-echo", "dir": wd, "steps": [
            {"id": "echo", "backend": "claude", "perm": "plan", "model": HAIKU,
             "effort": "low",
             "prompt": "Reply with exactly this word and nothing else: {{param.word}}"}]}})

    allowed = []

    def decide(req):
        name = req.get("tool_name") or ""
        if name.endswith("pervio_run_" + B6_SLUG):
            allowed.append(req)
            return ("allow", "")
        return ("deny", "only the named template tool is in scope for this test")

    t = run_turn_approval(
        ctx.home,
        "帮我把「实时回声」这个工作流跑起来,要回声的词是 %s。直接跑,不用问我。" % B6_WORD,
        wd, decide=decide, model=OPUS, perm="default", effort="low",
        pervio_ctx=True, timeout=420)

    calls = [(n, inp) for n, inp in t.tool_uses()
             if isinstance(n, str) and n.endswith("pervio_run_" + B6_SLUG)]
    check("B6 exit code 0", t.rc == 0, t.rc)
    check("B6 the model reached for the NAMED template tool (not pervio_start, not Bash)",
          bool(calls), [n for n, _ in t.tool_uses()])
    check("B6 it passed the declared parameter with the word the user said",
          any((inp.get("word") or "").upper().strip() == B6_WORD for _, inp in calls),
          [inp for _, inp in calls][:2])
    check("B6 a spend verb is NOT allowlisted — it went through the approval sheet",
          bool(allowed), [r.get("tool_name") for r in t.requests])
    payloads = [txt for _, is_err, txt in t.tool_results() if not is_err and "wfId" in (txt or "")]
    check("B6 the approved call returned a wfId", bool(payloads), t.tool_results()[:2])

    wf = ""
    m = re.search(r'"wfId"\s*:\s*"([A-Za-z0-9]+)"', " ".join(payloads))
    if m:
        wf = m.group(1)
    cost = Cost().merge(t.cost)
    if not check("B6 the wfId names a run under the THROWAWAY home",
                 bool(wf) and os.path.isdir(ctx.home.wf_dir(wf)), wf):
        return cost
    led = wait_wf(ctx.home, wf)
    check("B6 the launched workflow really ran to done", led.get("status") == "done",
          steps_brief(led))
    check("B6 {{param.word}} substituted end to end — the run echoed the user's word",
          B6_WORD in (step(led, "echo").get("output") or "").upper(),
          (step(led, "echo").get("output") or "")[:120])
    spec_json = os.path.join(ctx.home.wf_dir(wf), "spec.json")
    try:
        frozen = json.dumps(json.load(open(spec_json)), ensure_ascii=False)
    except (OSError, ValueError):
        frozen = ""
    check("B6 the launched spec was frozen with the value, not the placeholder",
          B6_WORD in frozen and "{{param." not in frozen, frozen[:200])
    cost.merge(cost_of_run_dir(ctx.home.wf_dir(wf)))
    delete_wf(ctx.home, wf)
    return cost


@scenario("B6-codex", "codex", "cheap", "named template tool — physically impossible on codex",
          twin="B6-claude", rehearsable=True, plans={})
def b6_codex(ctx):
    src = open(os.path.join(BIN, "pervio-chat")).read()
    mcp = open(os.path.join(BIN, "pervio-mcp")).read()
    check("B6-codex the skip is honest: codex still gets no MCP mount",
          re.search(r'^\s*CODEX_MCP_READY=""\s*$', src, re.M) is not None)
    check("B6-codex named tools are still a spend verb kept off the read-only surface",
          'RO_TOOLS = ("pervio_list_runs"' in mcp
          and "pervio_run_" not in mcp.split("RO_TOOLS = (")[1].split(")")[0],
          "pervio_run_* joined RO_TOOLS — re-check whether codex can reach it now")
    raise SkipScenario(
        "two independent blockers: (1) codex cannot call ANY MCP tool "
        "(openai/codex#24135 — every call is auto-cancelled), and (2) a named template "
        "tool is a spend verb deliberately kept off the read-only allowlist, so the only "
        "way to reach it is the Allow/Deny sheet codex has no channel for. Verified above.")


# --------------------------------------------------------------------------- #
# the red-line guard: the user's real ~/.pervio must be untouched
# --------------------------------------------------------------------------- #

GUARDED = ("templates", "schedules", "archives", "wf", "papers")


def snapshot_real_pervio():
    snap = {}
    for sub in GUARDED:
        p = os.path.join(REAL_HOME, ".pervio", sub)
        try:
            snap[sub] = sorted(os.listdir(p))
        except OSError:
            snap[sub] = None
    return snap


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #

def plan_rows(only):
    rows = []
    for sc in SCENARIOS:
        if only and not any(sc["sid"].startswith(o) for o in only):
            continue
        rows.append(sc)
    return rows


def cmd_list(only):
    print("Track B — real-agent contract suite. Planned CLI turns per backend:\n")
    tot = {"claude": 0, "codex": 0}
    for sc in plan_rows(only):
        for b, n in sc["plans"].items():
            tot[b] = tot.get(b, 0) + n
        cost = ", ".join("%s x%d" % (b, n) for b, n in sorted(sc["plans"].items())) or "FREE (skip)"
        print("  %-11s %-9s %-42s  %s" % (sc["sid"], sc["tier"], sc["title"][:42], cost))
    print("\n  planned total: " + "  ".join("%s %d turns (cap %d)" % (b, tot.get(b, 0),
                                                                     TRACK_CAPS[b])
                                            for b in sorted(TRACK_CAPS)))
    print("  models: cheap = %s / %s ; EXPENSIVE = %s / %s (judgement only)"
          % (HAIKU, MINI, OPUS, "gpt-5.6-sol"))
    print("\n  twins:")
    for sc in plan_rows(only):
        if sc["twin"]:
            print("    %-11s <-> %s" % (sc["sid"], sc["twin"]))
        else:
            print("    %-11s  NO TWIN — %s" % (sc["sid"], sc["no_twin"]))
    print("\nNothing was spent. Add --live to run for real, --rehearse to run the "
          "harness on shim agents for free.")
    return 0


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--live", action="store_true",
                    help="actually run real agents (SPENDS REAL QUOTA)")
    ap.add_argument("--rehearse", action="store_true",
                    help="run the harness against the committed shim agents; costs nothing")
    ap.add_argument("--list", action="store_true", help="print the plan and exit; costs nothing")
    ap.add_argument("--only", nargs="*", default=[], help="scenario id prefixes, e.g. B1 B5")
    args = ap.parse_args()

    if args.list:
        return cmd_list(args.only)

    live = args.live or os.environ.get("PERVIO_LIVE") == "1"
    if not live and not args.rehearse:
        print("test_agents_live.py: SKIPPED — this suite drives REAL claude and REAL "
              "codex turns and spends real quota.")
        print("  enable with:  python3 server/tests/test_agents_live.py --live")
        print("            or:  PERVIO_LIVE=1 python3 server/tests/test_agents_live.py")
        print("            or:  bash server/tests/run_all.sh --live")
        print("  free alternatives:  --list (the plan + cost model)   --rehearse (shim agents)")
        return 0

    mode = "REHEARSAL (shim agents, zero cost)" if args.rehearse else "LIVE (real quota)"
    print("=== Track B real-agent contract suite — %s ===" % mode)
    print("caps: " + "  ".join("%s <= %d turns" % (b, TRACK_CAPS[b]) for b in sorted(TRACK_CAPS)))

    before = snapshot_real_pervio()
    home = LiveHome()
    ctx = Ctx(home, args.rehearse)
    print("throwaway HOME: %s   (~/.pervio is fresh; .claude/.codex are symlinks)\n"
          % home.path)

    # ---- pre-flight, FREE: prove the two safety mechanisms before spending ----
    # A cap nobody ever hits is a comment, not a control. Drive it once, here, so
    # every live run carries its own evidence that the refusal path works.
    probe = Budget({"claude": 1, "codex": 0})
    probe.take("claude", 1, "probe")
    try:
        probe.take("claude", 1, "probe")
        capped = False
    except BudgetExceeded:
        capped = True
    check("pre-flight: the turn cap REFUSES the turn that would cross it", capped)
    check("pre-flight: a backend with a zero cap can never spawn",
          _refuses(probe, "codex"))
    isolated = (not os.path.islink(home.pervio)
                and os.path.realpath(home.pervio) != os.path.realpath(os.path.join(REAL_HOME, ".pervio"))
                and os.listdir(home.templates) == [])
    check("pre-flight: ~/.pervio really points at the throwaway home, not the real one",
          isolated, home.pervio)
    if not isolated:
        # Not a check to tally at the end: with this false, the very next line
        # would be a scenario writing into the person's own templates.
        home.cleanup()
        print("ABORT: the throwaway home is not isolated — nothing was run, nothing was spent.")
        return 1
    check("pre-flight: credentials still resolve through the symlink",
          os.path.isfile(os.path.join(home.path, ".pervio", "credentials.env"))
          or not os.path.isfile(os.path.join(REAL_HOME, ".pervio", "credentials.env")),
          "the throwaway home cannot see ~/.pervio/credentials.env — turns would run unauthenticated")

    env_shim = {}
    if args.rehearse:
        env_shim = {"PATH": SHIM + ":" + os.environ.get("PATH", "")}
        os.environ["PATH"] = env_shim["PATH"]

    try:
        for sc in plan_rows(args.only):
            if args.rehearse and not sc["rehearsable"]:
                print("\n---- %s: %s ----" % (sc["sid"], sc["title"]))
                print("n/a  not rehearsable on shim agents (needs a real MCP mount / real "
                      "approval decisions); run --live for this one")
                continue
            print("\n---- %s [%s] %s ----" % (sc["sid"], sc["tier"], sc["title"]))
            if not args.rehearse:
                try:
                    for b, n in sc["plans"].items():
                        BUDGET.take(b, n, sc["sid"])
                except BudgetExceeded as e:
                    check(sc["sid"] + " fits the turn budget", False, str(e))
                    continue
            t0 = time.time()
            try:
                cost = sc["fn"](ctx) or Cost()
            except SkipScenario as e:
                skips.append((sc["sid"], str(e)))
                print("SKIP %s — %s" % (sc["sid"], e))
                continue
            except Exception as e:                       # noqa: BLE001 - one bad scenario
                check(sc["sid"] + " ran without blowing up", False,
                      "%s: %s" % (type(e).__name__, e))
                continue
            row = {"sid": sc["sid"], "tier": sc["tier"], "cost": cost,
                   "secs": time.time() - t0}
            spend.append(row)
            # B7: every scenario states its own bill, in the same breath as its checks.
            print("     cost: %s   (%.1fs)" % (cost.text(), row["secs"]))
    finally:
        sweep_claude_projects(ctx.workdirs)
        for d in ctx.workdirs:
            shutil.rmtree(d, ignore_errors=True)
        home.cleanup()

    # ---- the red line, asserted ----
    after = snapshot_real_pervio()
    moved = [k for k in GUARDED if before[k] != after[k]]
    check("in the user's real ~/.pervio (templates/schedules/archives/wf/papers) no entry appeared or vanished",
          not moved, {k: (before[k], after[k]) for k in moved})

    # ---- B7: the bill ----
    print("\n========================================================")
    print("COST SUMMARY" + ("  (rehearsal — nothing was spent)" if args.rehearse else ""))
    total = Cost()
    for row in spend:
        total.merge(row["cost"])
        print("  %-11s %-9s %s" % (row["sid"], row["tier"], row["cost"].text()))
    print("  " + "-" * 54)
    print("  %-21s %s" % ("TOTAL", total.text()))
    if not args.rehearse:
        print("  turns used: " + BUDGET.line())
    if skips:
        print("\nHONEST SKIPS (codex physically cannot do these):")
        for sid, why in skips:
            print("  - %s: %s" % (sid, why))

    failed = [n for n, ok in results if not ok]
    print("\n========================================================")
    if not failed:
        print("TRACK B: ALL PASS (%d assertions, %d honest skips)" % (len(results), len(skips)))
        return 0
    print("TRACK B: FAILURES (%d/%d assertions failed)" % (len(failed), len(results)))
    for n in failed:
        print("   - " + n)
    return 1


if __name__ == "__main__":
    sys.exit(main())
