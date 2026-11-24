#!/usr/bin/env python3
"""Regression tests for the cross-model-audited fixes (2026-07-15). Findings, by id:
  #3  agent/setup/verify no timeout -> _call_gated (killpg the whole group)
  #4  _wf_alive declared long-but-alive runs dead -> pgid start-token identity
  #5  _delete_run trusted a stale/reused pgid -> same identity gate before signaling
  #7  _validate_spec ignored spec.dir/step.dir -> reject '..' traversal
  #9  fanout.max unbounded -> hard cap in _validate_spec
  #10 _read_json swallowed corrupt == missing -> corrupt now traces to stderr
Hermetic: isolated $HOME, committed shim claude on PATH, zero model calls."""
import base64
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.realpath(__file__))
BIN = os.path.realpath(os.path.join(HERE, "..", "bin"))
ORCH = os.path.join(BIN, "pervio-orchestrate")
SHIM = os.path.join(HERE, "shim")

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + (("  [" + str(detail)[:240] + "]") if (detail and not cond) else ""))


# Load the orchestrator as a module for unit tests (same trick as test_fanout).
loader = importlib.machinery.SourceFileLoader("orch_af", ORCH)
orch = importlib.util.module_from_spec(importlib.util.spec_from_loader("orch_af", loader))
loader.exec_module(orch)


# ---------- #7: dir traversal rejection ----------
print("=== #7 spec/step dir validation ===")
check("#7 _dir_ok absent ok", orch._dir_ok(None) is True)
check("#7 _dir_ok '~' ok", orch._dir_ok("~") is True)
check("#7 _dir_ok '~/proj' ok", orch._dir_ok("~/proj") is True)
check("#7 _dir_ok abs ok", orch._dir_ok("/tmp/x") is True)
check("#7 _dir_ok '..' rejected", orch._dir_ok("~/../.ssh") is False)
check("#7 _dir_ok leading '../' rejected", orch._dir_ok("../secrets") is False)
check("#7 _dir_ok backslash '..' rejected", orch._dir_ok("a\\..\\b") is False)
check("#7 _dir_ok empty rejected", orch._dir_ok("  ") is False)


def _valid(spec):
    try:
        orch._validate_spec(spec)
        return None
    except ValueError as e:
        return str(e)


base_step = {"id": "a", "backend": "claude", "prompt": "x"}
check("#7 valid spec dir passes", _valid({"dir": "~/proj", "steps": [dict(base_step)]}) is None)
err = _valid({"dir": "~/../etc", "steps": [dict(base_step)]})
check("#7 spec dir '..' rejected by _validate_spec", err and "traversal" in err, err)
err = _valid({"steps": [dict(base_step, dir="../../root")]})
check("#7 step dir '..' rejected by _validate_spec", err and "traversal" in err, err)

# ---------- #9: fanout.max hard cap ----------
print("=== #9 fanout.max cap ===")
CAP = orch.FANOUT_MAX_CAP
fo_ok = {"id": "f", "backend": "claude", "prompt": "x",
         "fanout": {"over": "{{a.output}}", "max": CAP}}
check("#9 max == cap passes", _valid({"steps": [dict(base_step), fo_ok]}) is None)
fo_big = {"id": "f", "backend": "claude", "prompt": "x",
          "fanout": {"over": "{{a.output}}", "max": CAP + 1}}
err = _valid({"steps": [dict(base_step), fo_big]})
check("#9 max > cap rejected", err and ("1..%d" % CAP) in err, err)
fo_zero = {"id": "f", "backend": "claude", "prompt": "x",
           "fanout": {"over": "{{a.output}}", "max": 0}}
check("#9 max < 1 rejected", _valid({"steps": [dict(base_step), fo_zero]}) is not None)
fo_str = {"id": "f", "backend": "claude", "prompt": "x",
          "fanout": {"over": "{{a.output}}", "max": "lots"}}
err = _valid({"steps": [dict(base_step), fo_str]})
check("#9 non-integer max rejected", err and "integer" in err, err)
# The exact codex catch: a float (1.9 silently truncates) and JSON Infinity (int(inf)
# raises OverflowError the old except missed). Must reject cleanly, never crash.
fo_float = {"id": "f", "backend": "claude", "prompt": "x",
            "fanout": {"over": "{{a.output}}", "max": 1.9}}
check("#9 float max rejected (not truncated to 1)", _valid({"steps": [dict(base_step), fo_float]}) is not None)
fo_inf = {"id": "f", "backend": "claude", "prompt": "x",
          "fanout": {"over": "{{a.output}}", "max": float("inf")}}
try:
    inf_err = _valid({"steps": [dict(base_step), fo_inf]})
    inf_ok = inf_err is not None                 # rejected cleanly, no exception
except Exception as _e:                          # e.g. the old OverflowError crash
    inf_ok = False
check("#9 Infinity max rejected cleanly (no OverflowError crash)", inf_ok)
fo_bool = {"id": "f", "backend": "claude", "prompt": "x",
           "fanout": {"over": "{{a.output}}", "max": True}}
check("#9 bool max rejected (int subclass guard)", _valid({"steps": [dict(base_step), fo_bool]}) is not None)
fo_none = {"id": "f", "backend": "claude", "prompt": "x",
           "fanout": {"over": "{{a.output}}"}}
check("#9 absent max still allowed (runtime default)", _valid({"steps": [dict(base_step), fo_none]}) is None)

# ---------- #10: _read_json missing vs corrupt ----------
print("=== #10 _read_json distinguishes missing from corrupt ===")
d = tempfile.mkdtemp(prefix="rj_", dir="/tmp")
missing = os.path.join(d, "nope.json")
_err = sys.stderr
sys.stderr = io.StringIO()
mval = orch._read_json(missing)
mtrace = sys.stderr.getvalue()
sys.stderr = _err
check("#10 missing file -> {} AND stays silent (no stderr)", mval == {} and mtrace == "", repr(mtrace)[:80])
corrupt = os.path.join(d, "bad.json")
open(corrupt, "w").write("{not json")
_err = sys.stderr
sys.stderr = io.StringIO()
val = orch._read_json(corrupt)
trace = sys.stderr.getvalue()
sys.stderr = _err
check("#10 corrupt file -> {} (no crash)", val == {})
check("#10 corrupt file leaves a stderr trace (not silent)", "corrupt/unreadable" in trace and corrupt in trace, trace[:120])

# ---------- #4 / #5: pgid start-token identity ----------
print("=== #4/#5 pgid identity via start token ===")
check("#4 _proc_start(self) non-empty", bool(orch._proc_start(os.getpid())))
# A real session leader: its pid == its pgid, so killpg(pid,0) targets its group.
child = subprocess.Popen(["sleep", "30"], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
time.sleep(0.3)
rd = tempfile.mkdtemp(prefix="pg_", dir="/tmp")
tok = orch._proc_start(child.pid)
check("#4 leader has a start token", bool(tok), tok)
# No recorded token yet -> can't prove identity -> None (callers fall back to age).
check("#4 no pgid.start -> None (unprovable)", orch._pgid_identity_ok(rd, child.pid) is None)
open(os.path.join(rd, "pgid.start"), "w").write(tok)
check("#5 matching token -> True (ours, safe to signal)", orch._pgid_identity_ok(rd, child.pid) is True)
open(os.path.join(rd, "pgid.start"), "w").write("99999999-not-our-token")
check("#5 mismatched token -> False (pid reused, do NOT signal)", orch._pgid_identity_ok(rd, child.pid) is False)
child.terminate(); child.wait()
time.sleep(0.2)
check("#5 dead group -> False regardless of token", orch._pgid_identity_ok(rd, child.pid) is False)


# ---------- #3: setup/verify/agent timeouts kill the group ----------
def env(home, **extra):
    e = dict(os.environ, HOME=home, PATH=SHIM + ":" + os.environ.get("PATH", ""))
    # Drop every timeout knob a test sets explicitly, so a value exported in the host
    # shell can't leak in and flip a default-vs-override assertion (hermeticity).
    for k in ("PERVIO_AGENT_TIMEOUT", "PERVIO_VERIFY_TIMEOUT", "PERVIO_SETUP_TIMEOUT",
              "PERVIO_CHILD_TIMEOUT", "PERVIO_CMD_TIMEOUT"):
        e.pop(k, None)
    e.update(extra)
    return e


def _alive(pid):
    """True while the PROCESS pid exists (os.kill 0 — checks the process, not a group;
    a `sleep` grandchild is not a group leader). init reaps a killed orphan promptly,
    so this flips to False reliably once it's actually dead."""
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def mkrepo(home):
    d = tempfile.mkdtemp(prefix="afrepo_", dir="/tmp")
    for a in (["init", "-q", "-b", "main"], ["config", "user.email", "t@t"],
              ["config", "user.name", "t"]):
        subprocess.run(["git", "-C", d] + a, capture_output=True)
    open(os.path.join(d, "base.txt"), "w").write("base\n")
    subprocess.run(["git", "-C", d, "add", "-A"], capture_output=True)
    subprocess.run(["git", "-C", d, "commit", "-qm", "base"], capture_output=True)
    return d


def run(home, spec, extra_env=None, timeout=60):
    e = env(home, **(extra_env or {}))
    b64 = base64.b64encode(json.dumps(spec).encode()).decode()
    p = subprocess.run([sys.executable, ORCH, "start", "--spec-b64", b64],
                       env=e, capture_output=True, text=True)
    if p.returncode != 0:
        return None, {}, p
    wf = json.loads(p.stdout)["wfId"]
    for _ in range(timeout * 4):
        q = subprocess.run([sys.executable, ORCH, "status", "--wf", wf], env=e,
                           capture_output=True, text=True)
        led = json.loads(q.stdout) if q.returncode == 0 else {}
        if led.get("status") in ("done", "failed"):
            return wf, led, p
        time.sleep(0.25)
    return wf, {}, p


def step(led, sid):
    return next((s for s in led.get("steps", []) if s["id"] == sid), {})


print("=== #3 agent turn timeout (killpg) ===")
home = tempfile.mkdtemp(prefix="af3a_", dir="/tmp")
t0 = time.time()
spec = {"name": "agto", "dir": home, "steps": [
    {"id": "hang", "backend": "claude", "perm": "plan",
     "prompt": "x\nSHIM:" + json.dumps({"sleep": 30, "text": "should never land"})}]}
wf, led, p = run(home, spec, extra_env={"PERVIO_AGENT_TIMEOUT": "1"})
dt = time.time() - t0
s = step(led, "hang")
check("#3 agent step FAILED on timeout (not stuck running)", s.get("status") == "failed", s)
check("#3 agent timeout error names the bound", "agent turn timed out" in (s.get("error") or ""), s.get("error"))
check("#3 the 30s shim was actually killed early (%.1fs < 15s)" % dt, dt < 15, "%.2fs" % dt)

print("=== #3 verify gate timeout (killpg) ===")
home = tempfile.mkdtemp(prefix="af3v_", dir="/tmp")
t0 = time.time()
spec = {"name": "vfto", "dir": home, "steps": [
    {"id": "s", "backend": "claude", "perm": "plan", "verify": "sleep 30",
     "prompt": "x\nSHIM:" + json.dumps({"text": "done"})}]}
wf, led, p = run(home, spec, extra_env={"PERVIO_VERIFY_TIMEOUT": "1"})
dt = time.time() - t0
s = step(led, "s")
check("#3 verify-timeout step FAILED (not stuck)", s.get("status") == "failed", s)
check("#3 verify timeout error names the bound", "verify timed out" in (s.get("error") or ""), s.get("error"))
check("#3 verify sleep 30 killed early (%.1fs < 15s)" % dt, dt < 15, "%.2fs" % dt)

# A verify that PASSES within budget must still succeed (no false timeout).
print("=== #3 fast verify still passes ===")
home = tempfile.mkdtemp(prefix="af3ok_", dir="/tmp")
spec = {"name": "vfok", "dir": home, "steps": [
    {"id": "s", "backend": "claude", "perm": "plan", "verify": "true",
     "prompt": "x\nSHIM:" + json.dumps({"text": "done"})}]}
wf, led, p = run(home, spec, extra_env={"PERVIO_VERIFY_TIMEOUT": "5"})
check("#3 sub-budget verify still passes", step(led, "s").get("status") == "done", step(led, "s"))

# ---------- #3 killpg PROOF: an agent timeout reaps the whole subtree ----------
# (the old test only proved 'fails fast'; reverting killpg->p.kill() would still pass
#  it. Here the shim spawns a grandchild in its group; killpg kills it, p.kill won't.)
print("=== #3 agent timeout kills the GROUP (grandchild dies) ===")
home = tempfile.mkdtemp(prefix="af3g_", dir="/tmp")
gc = os.path.join(home, "gc.pid")
spec = {"name": "agkg", "dir": home, "steps": [
    {"id": "hang", "backend": "claude", "perm": "plan",
     "prompt": "x\nSHIM:" + json.dumps({"spawn": {"pidfile": gc, "secs": 60}, "sleep": 30})}]}
wf, led, p = run(home, spec, extra_env={"PERVIO_AGENT_TIMEOUT": "3"})
gcpid = None
try:
    gcpid = int(open(gc).read().strip())
except (OSError, ValueError):
    pass
check("#3 shim actually spawned a grandchild", gcpid is not None, gc)
dead = False
for _ in range(40):
    if gcpid and not _alive(gcpid):
        dead = True
        break
    time.sleep(0.1)
check("#3 agent timeout reaped the grandchild too (killpg, not just the leader)", dead)
shutil.rmtree(home, ignore_errors=True)

# ---------- A: delete reaps a still-running agent turn (regression from #3) ----------
# _call_gated runs the turn in its OWN session, so killing the runner's pgid no longer
# reaches it. The live registry + _reap_live_children must reap it on delete, or the
# turn (and its subtree) is orphaned. Reverting the reap leaves the grandchild alive.
print("=== A: delete reaps the running agent turn's subtree ===")
home = tempfile.mkdtemp(prefix="afA_", dir="/tmp")
gcf = os.path.join(home, "gcA.pid")
e = env(home, PERVIO_AGENT_TIMEOUT="60")   # long, so the turn is mid-run when we delete
spec = {"name": "reap", "dir": home, "steps": [
    {"id": "long", "backend": "claude", "perm": "plan",
     "prompt": "x\nSHIM:" + json.dumps({"spawn": {"pidfile": gcf, "secs": 60}, "sleep": 40})}]}
b64 = base64.b64encode(json.dumps(spec).encode()).decode()
pp = subprocess.run([sys.executable, ORCH, "start", "--spec-b64", b64], env=e,
                    capture_output=True, text=True)
wfA = json.loads(pp.stdout)["wfId"]
liveA = os.path.join(home, ".pervio", "wf", wfA, "live")
gcA = None
for _ in range(120):
    try:
        gcA = int(open(gcf).read().strip())
        break
    except (OSError, ValueError):
        time.sleep(0.1)
regd = False
try:
    regd = any(n.isdigit() for n in os.listdir(liveA))
except OSError:
    pass
check("A the agent turn registered its own-session pgid in <rd>/live", regd)
check("A grandchild alive before delete", gcA is not None and _alive(gcA))
subprocess.run([sys.executable, ORCH, "delete", "--wf", wfA], env=e, capture_output=True)
reaped = False
for _ in range(50):
    if gcA and not _alive(gcA):
        reaped = True
        break
    time.sleep(0.1)
check("A delete reaped the orphaned agent-turn subtree (grandchild dead)", reaped)
shutil.rmtree(home, ignore_errors=True)

# ---------- D: _wf_alive itself (not just the helper) honors identity ----------
# The old #4/#5 tests only exercised _pgid_identity_ok; reverting _wf_alive to the
# age-cap-only logic would still pass them. Drive _wf_alive directly against a wf dir.
print("=== D: _wf_alive caller honors identity, bypassing the age cap ===")
home = tempfile.mkdtemp(prefix="afD_", dir="/tmp")
wfd = os.path.join(home, ".pervio", "wf", "aaaaaaaa0001")
os.makedirs(wfd)
kid = subprocess.Popen(["sleep", "30"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, start_new_session=True)
time.sleep(0.3)
open(os.path.join(wfd, "status"), "w").write("running")
open(os.path.join(wfd, "pgid"), "w").write(str(kid.pid))
open(os.path.join(wfd, "pgid.start"), "w").write(orch._proc_start(kid.pid))
json.dump({"startedAt": 1}, open(os.path.join(wfd, "ledger.json"), "w"))  # ancient
_savedWF = orch.WF
orch.WF = os.path.join(home, ".pervio", "wf")
check("D _wf_alive: proven-alive ANCIENT run is still alive (identity > 6h age cap)",
      orch._wf_alive("aaaaaaaa0001") is True)
open(os.path.join(wfd, "pgid.start"), "w").write("not-the-real-token")   # simulate pid reuse
check("D _wf_alive: token mismatch (reused pid) -> dead even though pgid answers",
      orch._wf_alive("aaaaaaaa0001") is False)
orch.WF = _savedWF
kid.terminate(); kid.wait()
shutil.rmtree(home, ignore_errors=True)

# ---------- B: a fan-out child timeout kills its whole group (grandchild) ----------
print("=== B: fan-out child timeout reaps its grandchild (run_child killpg) ===")
home = tempfile.mkdtemp(prefix="afB_", dir="/tmp")
gcb = os.path.join(home, "gcB.pid")
spec = {"name": "bkill", "dir": home, "steps": [
    {"id": "make", "backend": "claude", "perm": "plan",
     "prompt": "l\nSHIM:" + json.dumps({"text": "1. only"})},
    {"id": "work", "backend": "claude", "perm": "plan",
     "fanout": {"over": "{{make.output}}", "split": "numbered"},
     "prompt": "p\nSHIM:" + json.dumps({"spawn": {"pidfile": gcb, "secs": 60}, "sleep": 30})}]}
wf, led, p = run(home, spec, extra_env={"PERVIO_CHILD_TIMEOUT": "3"})
gcB = None
try:
    gcB = int(open(gcb).read().strip())
except (OSError, ValueError):
    pass
check("B fan-out child spawned a grandchild", gcB is not None, gcb)
bdead = False
for _ in range(40):
    if gcB and not _alive(gcB):
        bdead = True
        break
    time.sleep(0.1)
check("B fan-out child timeout reaped its grandchild (killpg in run_child)", bdead)
check("B the fan-out step still reported FAIL: timeout", "FAIL: timeout" in (step(led, "work").get("output") or ""),
      (step(led, "work").get("output") or "")[:80])
shutil.rmtree(home, ignore_errors=True)

# ---------- F: a timed-out agent turn still records its session id ----------
# The shim writes its init line (carrying session_id) before it sleeps, so the partial
# jsonl has the id when the timeout fires. Without F's salvage the ledger loses it and
# the (real, on-disk) timed-out conversation can never be swept.
print("=== F: timed-out agent turn keeps its session id (sweepable) ===")
home = tempfile.mkdtemp(prefix="afF_", dir="/tmp")
spec = {"name": "fsid", "dir": home, "steps": [
    {"id": "t", "backend": "claude", "perm": "plan",
     "prompt": "x\nSHIM:" + json.dumps({"sid": "sess-timed-out", "sleep": 20})}]}
wf, led, p = run(home, spec, extra_env={"PERVIO_AGENT_TIMEOUT": "2"})
s = step(led, "t")
check("F timed-out step is failed", s.get("status") == "failed", s)
check("F but the session id was still recorded for the sweep", s.get("sessionId") == "sess-timed-out", s)
shutil.rmtree(home, ignore_errors=True)

# ---------- #3 setup-timeout: an isolated step's setup shell is bounded ----------
# setup only runs for a worktree-isolated step, so this needs a git repo + 2 parallel
# writers. Reverting setup to the un-timed subprocess.call would hang, not fail-fast.
print("=== #3 setup timeout (isolated step) ===")
home = tempfile.mkdtemp(prefix="afsu_", dir="/tmp"); repo = mkrepo(home)
t0 = time.time()
spec = {"name": "suto", "dir": repo, "setup": "sleep 30", "steps": [
    {"id": "a", "backend": "claude", "perm": "acceptEdits",
     "prompt": "x\nSHIM:" + json.dumps({"write": [{"file": "a.txt", "content": "A"}], "text": "a"})},
    {"id": "b", "backend": "claude", "perm": "acceptEdits",
     "prompt": "x\nSHIM:" + json.dumps({"write": [{"file": "b.txt", "content": "B"}], "text": "b"})}]}
wf, led, p = run(home, spec, extra_env={"PERVIO_SETUP_TIMEOUT": "1"}, timeout=40)
dt = time.time() - t0
sa = step(led, "a")
check("#3 setup-timeout failed the step (not stuck running)", sa.get("status") == "failed", sa)
check("#3 setup timeout error names the bound", "setup timed out" in (sa.get("error") or ""), sa.get("error"))
check("#3 setup sleep 30 killed early (%.1fs < 20s)" % dt, dt < 20, "%.2fs" % dt)
shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

ok = all(results)
print("\n=== audit fixes: %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
