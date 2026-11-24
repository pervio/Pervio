#!/usr/bin/env python3
"""Regression tests for server/bin/pervio-approve (the stdio-MCP permission bridge
that turns Claude's --permission-prompt-tool into a phone-answerable Allow/Deny).
Drives the REAL server over JSON-RPC on stdin/stdout with an isolated $HOME, and
answers decisions via the control FIFO — no claude. Covers the initialize/tools
handshake, the allow/deny round-trips, updatedInput passthrough, and concurrent
calls dispatched by tool_use_id (answered out of order)."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.realpath(__file__))
APPROVE = os.path.realpath(os.path.join(HERE, "..", "bin", "pervio-approve"))

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + (("  [" + str(detail)[:200] + "]") if (detail and not cond) else ""))


class Server:
    def __init__(self, home, sid):
        self.sid = sid
        self.base = os.path.join(home, ".pervio", "chat", sid)
        self.fifo = os.path.join(self.base, "control.fifo")
        self.events = os.path.join(self.base, "events.jsonl")
        e = dict(os.environ, HOME=home, PERVIO_SID=sid)
        self.p = subprocess.Popen([sys.executable, APPROVE], env=e,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        self.responses = {}
        self.lock = threading.Lock()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for line in self.p.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if "id" in o:
                with self.lock:
                    self.responses[o["id"]] = o

    def send(self, obj):
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()

    def wait_response(self, rid, timeout=8):
        for _ in range(int(timeout * 40)):
            with self.lock:
                if rid in self.responses:
                    return self.responses[rid]
            time.sleep(0.025)
        return None

    def wait_event(self, tool_use_id, timeout=8):
        """Wait for the permission_request line pervio-approve appends when it blocks."""
        for _ in range(int(timeout * 40)):
            try:
                with open(self.events) as f:
                    for l in f:
                        l = l.strip()
                        if not l:
                            continue
                        o = json.loads(l)
                        if o.get("type") == "permission_request" and o.get("tool_use_id") == tool_use_id:
                            return o
            except OSError:
                pass
            time.sleep(0.025)
        return None

    def decide(self, request_id, behavior, message=None, updated=None):
        d = {"request_id": request_id, "behavior": behavior}
        if message is not None:
            d["message"] = message
        if updated is not None:
            d["updatedInput"] = updated
        fd = os.open(self.fifo, os.O_WRONLY)
        try:
            os.write(fd, (json.dumps(d) + "\n").encode())
        finally:
            os.close(fd)

    def call_async(self, rpc_id, tool_use_id, tool_name, tinput):
        self.send({"jsonrpc": "2.0", "id": rpc_id, "method": "tools/call",
                   "params": {"name": "approve",
                              "arguments": {"tool_name": tool_name, "tool_use_id": tool_use_id, "input": tinput}}})

    def result_payload(self, resp):
        """pervio-approve returns MCP content[0].text = json.dumps({behavior,...})."""
        try:
            return json.loads(resp["result"]["content"][0]["text"])
        except Exception:
            return {}

    def close(self):
        try:
            self.p.stdin.close()
        except Exception:
            pass
        try:
            self.p.wait(timeout=3)
        except Exception:
            self.p.kill()


home = tempfile.mkdtemp(prefix="papprove_", dir="/tmp")
sid = "aptest"
srv = Server(home, sid)

# ---- handshake ----
print("=== initialize / tools/list ===")
srv.send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}})
r = srv.wait_response(1)
check("initialize responds with serverInfo", bool(r) and r.get("result", {}).get("serverInfo", {}).get("name") == "pervio", r)
srv.send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
r = srv.wait_response(2)
tools = (r or {}).get("result", {}).get("tools", [])
check("tools/list advertises the approve tool", any(t.get("name") == "approve" for t in tools), tools)

# ---- allow round-trip (with updatedInput passthrough) ----
print("=== allow ===")
srv.call_async(10, "tool-USE-1", "Bash", {"command": "ls"})
ev = srv.wait_event("tool-USE-1")
check("tools/call surfaces a permission_request event", bool(ev) and ev.get("tool_name") == "Bash", ev)
check("permission_request carries the input", (ev or {}).get("input") == {"command": "ls"}, ev)
# not answered yet → no response
check("call BLOCKS until answered (no response yet)", srv.wait_response(10, timeout=0.5) is None)
srv.decide("tool-USE-1", "allow", updated={"command": "ls -la"})
r = srv.wait_response(10)
payload = srv.result_payload(r)
check("allow decision returns behavior=allow", payload.get("behavior") == "allow", payload)
check("allow passes through updatedInput", payload.get("updatedInput") == {"command": "ls -la"}, payload)

# ---- deny round-trip ----
print("=== deny ===")
srv.call_async(11, "tool-USE-2", "Write", {"file_path": "/etc/x"})
srv.wait_event("tool-USE-2")
srv.decide("tool-USE-2", "deny", message="nope")
r = srv.wait_response(11)
payload = srv.result_payload(r)
check("deny decision returns behavior=deny", payload.get("behavior") == "deny", payload)
check("deny carries the message", payload.get("message") == "nope", payload)

# ---- concurrency: two calls open at once, answered OUT OF ORDER ----
print("=== concurrent calls, dispatched by tool_use_id ===")
srv.call_async(20, "cc-A", "Edit", {"n": 1})
srv.call_async(21, "cc-B", "Edit", {"n": 2})
srv.wait_event("cc-A"); srv.wait_event("cc-B")
srv.decide("cc-B", "deny", message="B denied")     # answer B first
srv.decide("cc-A", "allow")                          # then A
ra = srv.wait_response(20); rb = srv.wait_response(21)
check("call A got its OWN (allow) verdict", srv.result_payload(ra).get("behavior") == "allow", srv.result_payload(ra))
check("call B got its OWN (deny) verdict despite reverse answer order", srv.result_payload(rb).get("behavior") == "deny", srv.result_payload(rb))

# ---- resolved events recorded ----
print("=== events log ===")
with open(srv.events) as f:
    kinds = [json.loads(l)["type"] for l in f if l.strip()]
check("events log has requests AND resolutions", kinds.count("permission_request") >= 4 and kinds.count("permission_resolved") >= 4, kinds)

srv.close()
shutil.rmtree(home, ignore_errors=True)

# ---- the approval push speaks the phone's language --------------------------
# 「Claude 在等你批准:跑命令」 is server-authored copy, so it must branch on the
# synced ~/.pervio/push/lang like every other push body (absent file = zh — old-phone compat, the
# shipped words, byte-for-byte). Pure function via module load — the JSON-RPC
# machinery above never fires a push (no blocked tool), and copy needs no server.
print("=== approval push copy ===")
import importlib.machinery                                            # noqa: E402
import importlib.util                                                 # noqa: E402
_loader = importlib.machinery.SourceFileLoader("appr_mod", APPROVE)
_spec = importlib.util.spec_from_loader("appr_mod", _loader)
appr = importlib.util.module_from_spec(_spec)
_loader.exec_module(appr)                 # CLI is under __main__; import is inert

_lang_home = tempfile.mkdtemp(prefix="appr-lang-")
_home_before = os.environ.get("HOME")
os.environ["HOME"] = _lang_home           # hermetic: the real home may hold a synced lang
try:
    for k in ("PERVIO_RUN_ID", "PERVIO_PUSH_DEVICE"):
        os.environ.pop(k, None)
    check("push target: a chat turn with no device pings every phone on the approve thread, as before",
          appr._push_target() == ["--thread", "pervio-approve"], appr._push_target())
    os.environ["PERVIO_PUSH_DEVICE"] = "phoneA"
    check("push target: the turn's phone (pervio-chat --device) is the only one pinged",
          appr._push_target() == ["--thread", "pervio-approve", "--device", "phoneA"], appr._push_target())
    os.environ["PERVIO_RUN_ID"] = "abc123"
    check("push target: inside a detached run the ping rides the run's thread, so a tap reopens that run (2026-10-19)",
          appr._push_target() == ["--thread", "pervio-run-abc123", "--device", "phoneA"], appr._push_target())
    for k in ("PERVIO_RUN_ID", "PERVIO_PUSH_DEVICE"):
        os.environ.pop(k, None)
    check("approve copy: zh default (no file) keeps the shipped words",
          appr._approve_copy("Bash") == ("Claude 在等你批准", "跑命令"),
          appr._approve_copy("Bash"))
    check("approve copy: an unfamiliar tool falls back to its own name",
          appr._approve_copy("FooTool") == ("Claude 在等你批准", "FooTool")
          and appr._approve_copy("") == ("Claude 在等你批准", "操作"),
          (appr._approve_copy("FooTool"), appr._approve_copy("")))
    os.makedirs(os.path.join(_lang_home, ".pervio", "push"), exist_ok=True)
    with open(os.path.join(_lang_home, ".pervio", "push", "lang"), "w") as _f:
        _f.write("en")
    check("approve copy: en file flips title AND verb",
          appr._approve_copy("Bash") == ("Claude is waiting for your approval",
                                         "run a command"),
          appr._approve_copy("Bash"))
    check("approve copy: en fallback for an unfamiliar / empty tool",
          appr._approve_copy("FooTool")[1] == "FooTool"
          and appr._approve_copy("")[1] == "an action",
          (appr._approve_copy("FooTool"), appr._approve_copy("")))
finally:
    if _home_before is None:
        os.environ.pop("HOME", None)
    else:
        os.environ["HOME"] = _home_before
    shutil.rmtree(_lang_home, ignore_errors=True)

# ---- a call to the workflow tools: asked about in the words of what it would RUN ----
# (security review 2026-11-22, #1/#2). The real pervio-mcp and pervio-orchestrate
# answer `--resolve`; the shim claude is never reached (nothing is started).
print("=== workflow calls: resolved, shown, bound ===")
import base64, hashlib
whome = tempfile.mkdtemp(prefix="papprove_wf_", dir="/tmp")
wconv = os.path.join(whome, "conv"); os.makedirs(wconv)
os.makedirs(os.path.join(whome, ".pervio", "templates"))
tpl_spec = {"name": "nightly", "dir": wconv, "steps": [
    {"id": "a", "backend": "claude", "perm": "plan", "prompt": "look"}, {"id": "c", "command": "make test"}]}
with open(os.path.join(whome, ".pervio", "templates", "nightly.json"), "w") as f:
    json.dump({"name": "nightly", "summary": "s", "spec": tpl_spec}, f)
with open(os.path.join(whome, ".pervio", "templates", "full.json"), "w") as f:
    json.dump({"name": "full", "summary": "s", "spec": {"name": "full", "dir": wconv, "steps": [
        {"id": "a", "backend": "claude", "perm": "bypassPermissions", "prompt": "x"}]}}, f)


class WfServer(Server):
    def __init__(self, home, sid, ceiling):
        self.sid = sid
        self.base = os.path.join(home, ".pervio", "chat", sid)
        self.fifo = os.path.join(self.base, "control.fifo")
        self.events = os.path.join(self.base, "events.jsonl")
        e = dict(os.environ, HOME=home, PERVIO_SID=sid, PERVIO_MCP_CEILING=ceiling, PERVIO_MCP_DIR=wconv,
                 PERVIO_SCHED_HOOK="skip")
        self.p = subprocess.Popen([sys.executable, APPROVE], env=e,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        self.responses = {}
        self.lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()

    def lines(self):
        try:
            return [json.loads(l) for l in open(self.events) if l.strip()]
        except OSError:
            return []


w = WfServer(whome, "wfsid", "default")
shown_dir = os.path.join(w.base, "shown")
w.call_async(40, "wf-1", "mcp__perviotools__pervio_start", {"template": "nightly"})
ev = w.wait_event("wf-1", timeout=30) or {}
seen = json.loads(base64.b64decode((ev.get("shown") or {}).get("spec_b64", "") or "e30=").decode())
check("a start by NAME reaches the phone with the workflow itself: its steps and its shell line",
      seen.get("name") == "nightly" and [x.get("command") for x in seen.get("steps", []) if x.get("command")] == ["make test"], ev)
check("…and the model's own input is passed on untouched beside it", ev.get("input") == {"template": "nightly"}, ev)
check("nothing is allowed before the tap: no token yet", not os.path.isdir(shown_dir) or not os.listdir(shown_dir))
w.decide("wf-1", "allow", updated={"template": "something-else"})
pay = w.result_payload(w.wait_response(40, timeout=15))
sha = hashlib.sha256(json.dumps({"spec": seen, "extra": None}, sort_keys=True, ensure_ascii=False,
                                separators=(",", ":")).encode()).hexdigest()
check("Allow leaves one token, named by the hash of exactly what was shown",
      os.path.isdir(shown_dir) and os.listdir(shown_dir) == [sha], (os.listdir(shown_dir) if os.path.isdir(shown_dir) else None, sha))
check("…and the call goes on with the input that was asked about, not an edited one",
      pay.get("behavior") == "allow" and pay.get("updatedInput") == {"template": "nightly"}, pay)
check("the token is for the owner's eyes only", oct(os.stat(os.path.join(shown_dir, sha)).st_mode & 0o777) == "0o600"
      and oct(os.stat(shown_dir).st_mode & 0o777) == "0o700")
w.call_async(41, "wf-2", "mcp__perviotools__pervio_start", {"template": "nightly"})
w.wait_event("wf-2", timeout=30)
w.decide("wf-2", "deny", message="no")
pay = w.result_payload(w.wait_response(41, timeout=15))
check("Deny leaves no new token", pay.get("behavior") == "deny" and os.listdir(shown_dir) == [sha], os.listdir(shown_dir))
n = len(w.lines())
w.call_async(42, "wf-3", "mcp__perviotools__pervio_start", {"template": "full"})
pay = w.result_payload(w.wait_response(42, timeout=30))
check("a call the ceiling would refuse is denied here, in the tool's own words",
      pay.get("behavior") == "deny" and "a (bypassPermissions)" in pay.get("message", ""), pay)
check("…without the phone being asked: no request on the stream", len(w.lines()) == n, w.lines()[n:])
w.call_async(43, "wf-4", "mcp__perviotools__pervio_start", {"template": "no-such-template"})
pay = w.result_payload(w.wait_response(43, timeout=30))
check("a call nobody can resolve (unknown template) is denied unasked too",
      pay.get("behavior") == "deny" and "not found" in pay.get("message", "") and len(w.lines()) == n, pay)
w.call_async(44, "wf-5", "mcp__perviotools__pervio_schedule", {"action": "pause", "id": "abcabcabcabc"})
ev = w.wait_event("wf-5", timeout=30) or {}
check("a workflow-tool call with no workflow in it (a pause) is asked as before, nothing attached",
      ev.get("tool_name") == "mcp__perviotools__pervio_schedule" and "shown" not in ev, ev)
w.decide("wf-5", "allow")
w.wait_response(44, timeout=15)
w.call_async(45, "wf-6", "Bash", {"command": "ls"})
ev = w.wait_event("wf-6") or {}
check("any other tool is untouched: no resolving, nothing attached", ev.get("input") == {"command": "ls"} and "shown" not in ev, ev)
w.decide("wf-6", "allow", updated={"command": "ls -la"})
check("…and its updatedInput still passes through", w.result_payload(w.wait_response(45)).get("updatedInput") == {"command": "ls -la"})
w.close()
wp = WfServer(whome, "wfsid2", "plan")
wp.call_async(50, "wf-p", "mcp__perviotools__pervio_start", {"template": "nightly"})
pay = wp.result_payload(wp.wait_response(50, timeout=30))
check("in plan mode a start is denied unasked", pay.get("behavior") == "deny" and "plan mode" in pay.get("message", "")
      and not wp.lines(), pay)
wp.close()

# Nobody can say what the call would run (the resolver is missing, broken, or
# answers nonsense): the person is not asked to allow a blank — denied, unasked.
bindir = tempfile.mkdtemp(prefix="papprove_bin_", dir="/tmp")
for fn in ("pervio-approve", "_pervio_lib.py"):
    shutil.copy(os.path.join(os.path.dirname(APPROVE), fn), os.path.join(bindir, fn))
for label, body in (("prints nonsense", "print('Traceback (most recent call last): …')"),
                    ("prints nothing", "pass"),
                    ("dies", "import sys; sys.exit(3)"),
                    ("answers with a list", "print('[1, 2]')")):
    with open(os.path.join(bindir, "pervio-mcp"), "w") as f:
        f.write("#!/usr/bin/env python3\n" + body + "\n")

    class Broken(WfServer):
        def __init__(self, home, sid):
            self.sid = sid
            self.base = os.path.join(home, ".pervio", "chat", sid)
            self.fifo = os.path.join(self.base, "control.fifo")
            self.events = os.path.join(self.base, "events.jsonl")
            e = dict(os.environ, HOME=home, PERVIO_SID=sid, PERVIO_MCP_CEILING="default", PERVIO_MCP_DIR=wconv)
            self.p = subprocess.Popen([sys.executable, os.path.join(bindir, "pervio-approve")], env=e,
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
            self.responses = {}
            self.lock = threading.Lock()
            threading.Thread(target=self._read, daemon=True).start()

    wb = Broken(whome, "wfsid3")
    wb.call_async(60, "wf-b", "mcp__perviotools__pervio_start", {"template": "nightly"})
    pay = wb.result_payload(wb.wait_response(60, timeout=30))
    check("a resolver that %s: the start is denied, with words, and the phone is not asked" % label,
          pay.get("behavior") == "deny" and "could not work out" in pay.get("message", "") and not wb.lines(), (pay, wb.lines()))
    wb.call_async(61, "wf-b2", "Bash", {"command": "ls"})
    ev = wb.wait_event("wf-b2") or {}
    check("…while any other tool is still asked about as usual (%s)" % label, ev.get("tool_name") == "Bash", ev)
    wb.decide("wf-b2", "deny")
    wb.wait_response(61)
    wb.close()
    shutil.rmtree(os.path.join(whome, ".pervio", "chat", "wfsid3"), ignore_errors=True)
shutil.rmtree(bindir, ignore_errors=True)
shutil.rmtree(whome, ignore_errors=True)

ok = all(results)
print("\n=== pervio-approve: %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
