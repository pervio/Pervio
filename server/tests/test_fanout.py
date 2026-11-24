#!/usr/bin/env python3
"""Regression tests for dynamic fan-out in pervio-orchestrate (one child agent turn
per upstream list item). Hermetic: isolated $HOME, scratch git repo, committed shim
claude on PATH. A producer step emits a NUMBERED list where each item is a SHIM json
directive, and the fanout template is 'SHIM:{{item}}', so each child's behavior
(text/cost/sleep/is_error) is controlled per-item with zero model calls. Covers
split, N-item parallel, 0/1 item, max-cap truncation, partial/total failure,
minSuccessRate, budget-ledger isolation, worktree cleanup, and zero-regression.
Also the DAG's two silent-wrong-result guards (C1/C4): {{id.output}} refs are
ordering edges in SHARED mode too (a consumer must never read ""), a ref or a
dependsOn naming no step rejects the start, dependsOn's shape is validated, and a
runner crash lands the run as failed instead of leaving it 'running' forever."""
import base64
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
os.environ.setdefault("PERVIO_RUN_IDLE_GRACE", "1.5")   # a living run ends a beat after its reply here, not 180 s

HERE = os.path.dirname(os.path.realpath(__file__))
BIN = os.path.realpath(os.path.join(HERE, "..", "bin"))
ORCH = os.path.join(BIN, "pervio-orchestrate")
SHIM = os.path.join(HERE, "shim")
WFROOT = os.path.expanduser("~/.pervio/wf")

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + (("  [" + str(detail)[:220] + "]") if (detail and not cond) else ""))


def g(cwd, *a):
    p = subprocess.run(["git", "-C", cwd] + list(a), capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def mkrepo(home):
    d = tempfile.mkdtemp(prefix="fout_", dir="/tmp")
    for a in (["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]):
        subprocess.run(["git", "-C", d] + a, capture_output=True)
    open(os.path.join(d, "base.txt"), "w").write("base\n")
    subprocess.run(["git", "-C", d, "add", "-A"], capture_output=True)
    subprocess.run(["git", "-C", d, "commit", "-qm", "base"], capture_output=True)
    return d


def env(home):
    e = dict(os.environ, HOME=home, PATH=SHIM + ":" + os.environ.get("PATH", ""))
    # F15 pins the 180s built-in default — a host shell that happens to export the
    # operator knob must not leak in (F16 sets it explicitly via extra_env).
    e.pop("PERVIO_CHILD_TIMEOUT", None)
    return e


def producer_text(item_dirs):
    """A numbered list whose items are SHIM json directives (one per fanout child).
    Leading 'Here are the items:' preamble exercises the numbered-split preamble drop."""
    return "Here are the items:\n" + "\n".join(
        "%d. %s" % (i + 1, json.dumps(d)) for i, d in enumerate(item_dirs))


def spec_producer_fanout(repo, item_dirs, fanout=None, downstream=False):
    prod_shim = {"text": producer_text(item_dirs)}
    steps = [{"id": "make", "backend": "claude", "perm": "plan",
              "prompt": "make a list\nSHIM:" + json.dumps(prod_shim)}]
    fo = {"over": "{{make.output}}", "split": "numbered", "as": "item"}
    fo.update(fanout or {})
    steps.append({"id": "work", "backend": "claude", "perm": "plan", "fanout": fo,
                  "prompt": "process\nSHIM:{{item}}"})
    if downstream:
        steps.append({"id": "collect", "backend": "claude", "perm": "plan", "dependsOn": ["work"],
                      "prompt": "summary of {{work.output}}\nSHIM:" + json.dumps({"text": "collected"})})
    return {"name": "fout", "dir": repo, "steps": steps}


def run(home, spec, timeout=90, extra_env=None):
    e = env(home)
    e.update(extra_env or {})
    b64 = base64.b64encode(json.dumps(spec).encode()).decode()
    p = subprocess.run([sys.executable, ORCH, "start", "--spec-b64", b64], env=e, capture_output=True, text=True)
    if p.returncode != 0:
        return None, p
    wf = json.loads(p.stdout)["wfId"]
    for _ in range(timeout * 4):
        q = subprocess.run([sys.executable, ORCH, "status", "--wf", wf], env=e, capture_output=True, text=True)
        led = json.loads(q.stdout) if q.returncode == 0 else {}
        if led.get("status") in ("done", "failed"):
            return wf, led
        time.sleep(0.25)
    return wf, {}


def step(led, sid):
    return next((s for s in led.get("steps", []) if s["id"] == sid), {})


def delete(home, wf):
    subprocess.run([sys.executable, ORCH, "delete", "--wf", wf], env=env(home), capture_output=True)


# ---------- unit: _is_reader + split ----------
print("=== unit: fanout classification + split ===")
loader = importlib.machinery.SourceFileLoader("orch", ORCH)
orch = importlib.util.module_from_spec(importlib.util.spec_from_loader("orch", loader))
loader.exec_module(orch)
check("fanout step classified as reader", orch._is_reader({"fanout": {"over": "x"}, "perm": "acceptEdits"}) is True)
check("fanout+verify still reader", orch._is_reader({"fanout": {"over": "x"}, "verify": "true"}) is True)
check("plain default step still writer", orch._is_reader({"perm": "default"}) is False)
check("numbered split strips + drops preamble/signoff", orch._fanout_split("numbered", producer_text([{"a": 1}, {"b": 2}])) == ['{"a": 1}', '{"b": 2}'])

# ---------- F0: happy 5-item fanout + downstream ----------
print("=== F0 happy path (5 items) ===")
home = tempfile.mkdtemp(prefix="fh_", dir="/tmp"); repo = mkrepo(home)
wf, led = run(home, spec_producer_fanout(repo, [{"text": "r%d" % i, "cost": 0.01} for i in range(5)], downstream=True))
w = step(led, "work")
check("F0 run done", led.get("status") == "done", led)
check("F0 fanoutOk=5 fanoutTotal=5", w.get("fanoutOk") == 5 and w.get("fanoutTotal") == 5, w)
check("F0 output summary line first", (w.get("output") or "").startswith("5/5 done (0 failed)"), (w.get("output") or "")[:60])
check("F0 every child output present", all(("r%d" % i) in (w.get("output") or "") for i in range(5)))
check("F0 downstream got the blob", "collected" in (step(led, "collect").get("output") or "") and step(led, "collect").get("status") == "done")
delete(home, wf); shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- F1: 0 items ----------
print("=== F1 zero items ===")
home = tempfile.mkdtemp(prefix="f0_", dir="/tmp"); repo = mkrepo(home)
# producer emits text with NO numbered items
spec = spec_producer_fanout(repo, [])
spec["steps"][0]["prompt"] = "x\nSHIM:" + json.dumps({"text": "no list here, just prose"})
wf, led = run(home, spec)
w = step(led, "work")
check("F1 empty fanout -> step failed", w.get("status") == "failed" and "0 items" in (w.get("error") or ""), w)
check("F1 no worktrees leaked", g(repo, "worktree", "list", "--porcelain")[1].count("worktree ") == 1)
delete(home, wf); shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- F2: 1 item ----------
print("=== F2 single item ===")
home = tempfile.mkdtemp(prefix="f1_", dir="/tmp"); repo = mkrepo(home)
wf, led = run(home, spec_producer_fanout(repo, [{"text": "solo", "cost": 0.02}]))
w = step(led, "work")
check("F2 single-item fanout done, ok=1", w.get("status") == "done" and w.get("fanoutOk") == 1 and w.get("fanoutTotal") == 1, w)
delete(home, wf); shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- F3: max-cap truncation ----------
print("=== F3 max-cap truncation ===")
home = tempfile.mkdtemp(prefix="f3_", dir="/tmp"); repo = mkrepo(home)
wf, led = run(home, spec_producer_fanout(repo, [{"text": "r%d" % i} for i in range(6)], fanout={"max": 3}))
w = step(led, "work")
check("F3 only max ran (fanoutTotal=3)", w.get("fanoutTotal") == 3, w)
check("F3 truncation recorded (fanoutTruncated=3)", w.get("fanoutTruncated") == 3, w)
check("F3 summary shows 3/3 not 3/6, notes drop", (w.get("output") or "").startswith("3/3 done") and "3 dropped" in (w.get("output") or ""), (w.get("output") or "")[:80])
delete(home, wf); shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- F4: partial failure ----------
print("=== F4 partial failure ===")
home = tempfile.mkdtemp(prefix="f4_", dir="/tmp"); repo = mkrepo(home)
items = [{"text": "ok0"}, {"text": "bad1", "is_error": True}, {"text": "ok2"}, {"text": "bad3", "is_error": True}]
wf, led = run(home, spec_producer_fanout(repo, items))
w = step(led, "work")
check("F4 step done despite failures (>=1 ok)", w.get("status") == "done", w)
check("F4 fanoutOk=2 fanoutFail=2", w.get("fanoutOk") == 2 and w.get("fanoutFail") == 2, w)
check("F4 summary counts failures", (w.get("output") or "").startswith("2/4 done (2 failed)"), (w.get("output") or "")[:40])
delete(home, wf); shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- F5: all fail ----------
print("=== F5 all children fail ===")
home = tempfile.mkdtemp(prefix="f5_", dir="/tmp"); repo = mkrepo(home)
wf, led = run(home, spec_producer_fanout(repo, [{"text": "x", "is_error": True} for _ in range(3)]))
w = step(led, "work")
check("F5 all-fail -> step failed", w.get("status") == "failed" and "all 3 children failed" in (w.get("error") or ""), w)
delete(home, wf); shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- F5b: all fail + tolerateAllFail ----------
# A scheduled pipeline (paper digest at 06:30) prefers a degraded downstream step
# over a skipped one: the step must be done, carry the FAIL ledger as output, and
# let dependents run. Non-bool values must be rejected at start.
print("=== F5b all children fail + tolerateAllFail ===")
home = tempfile.mkdtemp(prefix="f5b_", dir="/tmp"); repo = mkrepo(home)
wf, led = run(home, spec_producer_fanout(repo, [{"text": "x", "is_error": True} for _ in range(3)],
                                         fanout={"tolerateAllFail": True}, downstream=True))
w = step(led, "work")
check("F5b all-fail + tolerate -> step done", w.get("status") == "done", w)
check("F5b output carries the FAIL ledger", (w.get("output") or "").startswith("0/3 done (3 failed)"),
      (w.get("output") or "")[:60])
check("F5b downstream ran on the FAIL ledger", step(led, "collect").get("status") == "done",
      step(led, "collect"))
check("F5b run overall done", led.get("status") == "done", led)
delete(home, wf)
_bad = spec_producer_fanout(repo, [{"text": "x"}], fanout={"tolerateAllFail": "yes"})
_wfb, _pb = run(home, _bad)
check("F5b non-bool tolerateAllFail rejected at start",
      _wfb is None and "tolerateAllFail" in ((_pb.stderr or "") if hasattr(_pb, "stderr") else ""),
      getattr(_pb, "stderr", _pb))
shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- F6: minSuccessRate ----------
print("=== F6 minSuccessRate gate ===")
home = tempfile.mkdtemp(prefix="f6_", dir="/tmp"); repo = mkrepo(home)
items = [{"text": "ok"}, {"text": "ok"}, {"text": "x", "is_error": True}, {"text": "x", "is_error": True}]
wf, led = run(home, spec_producer_fanout(repo, items, fanout={"minSuccessRate": 0.6}))
w = step(led, "work")
check("F6 2/4 below 0.6 -> failed", w.get("status") == "failed" and "below minSuccessRate" in (w.get("error") or ""), w)
delete(home, wf); shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- F7: parallelism (maxParallel) ----------
print("=== F7 maxParallel ===")
home = tempfile.mkdtemp(prefix="f7_", dir="/tmp"); repo = mkrepo(home)
t0 = time.time()
wf, led = run(home, spec_producer_fanout(repo, [{"text": "s", "sleep": 1} for _ in range(4)], fanout={"maxParallel": 2}))
dt = time.time() - t0
_w = step(led, "work")      # on a failure, say what the step said: the whole ledger is cut off before it gets there
check("F7 4 items done", _w.get("fanoutOk") == 4,
      (_w.get("fanoutOk"), _w.get("status"), _w.get("error"), (_w.get("output") or "")[:140]))
check("F7 maxParallel=2 → ~2 waves (%.1fs, not ~4s serial)" % dt, dt < 3.6, "%.2fs" % dt)
delete(home, wf); shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- F8: fan-out does NOT consume the dispatch budget/width ledger ----------
print("=== F8 budget-ledger isolation ===")
home = tempfile.mkdtemp(prefix="f8_", dir="/tmp"); repo = mkrepo(home)
wf, led = run(home, spec_producer_fanout(repo, [{"text": "r%d" % i} for i in range(5)]))
disp_ledger = os.path.join(WFROOT, wf, "dispatch", "ledger.ndjson")
check("F8 fanout children NOT written to the dispatch width ledger", not os.path.exists(disp_ledger),
      disp_ledger)
delete(home, wf); shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- F9: worktree + branch cleanup ----------
print("=== F9 cleanup ===")
home = tempfile.mkdtemp(prefix="f9_", dir="/tmp"); repo = mkrepo(home)
wf, led = run(home, spec_producer_fanout(repo, [{"text": "r%d" % i} for i in range(3)]))
check("F9 no stray worktrees after run", g(repo, "worktree", "list", "--porcelain")[1].count("worktree ") == 1)
_, refs, _ = g(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/pervio/wf-%s/dispatch/fanout/" % wf)
check("F9 child branches kept for audit", len([r for r in refs.splitlines() if r.strip()]) == 3, refs)
delete(home, wf)
check("F9 delete sweeps fanout branches + prunes", g(repo, "for-each-ref", "refs/heads/pervio/")[1] == ""
      and g(repo, "worktree", "list", "--porcelain")[1].count("worktree ") == 1)
shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- F10: zero regression + reserved id ----------
print("=== F10 zero regression / validation ===")
home = tempfile.mkdtemp(prefix="fz_", dir="/tmp"); repo = mkrepo(home)
plain = {"name": "plain", "dir": repo, "steps": [
    {"id": "a", "backend": "claude", "perm": "plan", "prompt": "x\nSHIM:" + json.dumps({"text": "A"})}]}
wf, led = run(home, plain)
check("F10 non-fanout run done, no fanout fields", led.get("status") == "done"
      and all("fanoutOk" not in s and "fanoutTotal" not in s for s in led["steps"]), led)
delete(home, wf)
# reserved id 'item' rejected at start
bad = {"name": "bad", "dir": repo, "steps": [{"id": "item", "backend": "claude", "prompt": "x"}]}
p = subprocess.run([sys.executable, ORCH, "start", "--spec-b64", base64.b64encode(json.dumps(bad).encode()).decode()],
                   env=env(home), capture_output=True, text=True)
check("F10 reserved step id 'item' rejected", p.returncode != 0, p.stdout[:60])
shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- F11: fanoutOk/fanoutFail update LIVE while children run ----------
# (the phone's step-row chip ticks on these; before, they appeared only at the end)
print("=== F11 live progress counters ===")
home = tempfile.mkdtemp(prefix="f11_", dir="/tmp"); repo = mkrepo(home)
spec = spec_producer_fanout(repo, [{"sleep": 1.1, "text": "s%d" % i} for i in range(3)],
                            fanout={"maxParallel": 1})   # serial → a wide mid-run window
e = env(home)
p = subprocess.run([sys.executable, ORCH, "start",
                    "--spec-b64", base64.b64encode(json.dumps(spec).encode()).decode()],
                   env=e, capture_output=True, text=True)
wf = json.loads(p.stdout)["wfId"]
live = []                        # (step status, fanoutOk, fanoutFail) snapshots
led = {}
for _ in range(60 * 4):
    q = subprocess.run([sys.executable, ORCH, "status", "--wf", wf], env=e, capture_output=True, text=True)
    led = json.loads(q.stdout) if q.returncode == 0 else {}
    w = step(led, "work")
    live.append((w.get("status"), w.get("fanoutOk"), w.get("fanoutFail")))
    if led.get("status") in ("done", "failed"):
        break
    time.sleep(0.15)
check("F11 counters tick up while the step is still running",
      any(s[0] == "running" and s[1] is not None and 1 <= s[1] < 3 for s in live), live[-15:])
w = step(led, "work")
check("F11 final counts settle at ok=3 fail=0", w.get("fanoutOk") == 3 and w.get("fanoutFail") == 0, w)
delete(home, wf); shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- F12: fanout in a NON-git dir (scratch containment, zero setup) ----------
# The zero-setup market demo runs wherever the user's project dir points — often
# not a git repo. Children must still run contained (throwaway scratch dirs), and
# nothing may be created in the real dir.
print("=== F12 non-git dir fanout ===")
home = tempfile.mkdtemp(prefix="f12_", dir="/tmp")
plaindir = tempfile.mkdtemp(prefix="f12dir_", dir="/tmp")   # deliberately NOT a repo
before = set(os.listdir(plaindir))
spec = spec_producer_fanout(plaindir, [{"text": "r%d" % i} for i in range(3)])
wf, led = run(home, spec)
w = step(led, "work")
check("F12 non-git fanout done, ok=3 total=3",
      led.get("status") == "done" and w.get("fanoutOk") == 3 and w.get("fanoutTotal") == 3, w)
check("F12 all child outputs present", all(("r%d" % i) in (w.get("output") or "") for i in range(3)),
      (w.get("output") or "")[:120])
check("F12 real dir untouched (no .git, nothing new)",
      set(os.listdir(plaindir)) == before and not os.path.exists(os.path.join(plaindir, ".git")),
      sorted(set(os.listdir(plaindir)) - before))
scratch = os.path.join(home, ".pervio", "wf", wf or "x", "dispatch", "fanout", "work")
check("F12 scratch wt dirs discarded after each child",
      all(not os.path.exists(os.path.join(scratch, str(i), "wt")) for i in range(3)))
delete(home, wf); shutil.rmtree(home, ignore_errors=True); shutil.rmtree(plaindir, ignore_errors=True)

# ---------- F13: delete sweeps the conversations the workflow created ----------
# Steps record sessionId+sessionDir in the ledger; delete removes those sessions
# (via pervio-sessions, claude only) plus every project folder for a cwd under the
# workflow's own dir. Planted files stand in for what a real (non-shim) run
# writes; the wf-owned folder is removed through orchestrate's OWN encode copy,
# so this fails if the two encode implementations ever drift.
print("=== F13 delete sweeps conversations ===")
sess_loader = importlib.machinery.SourceFileLoader("psess", os.path.join(BIN, "pervio-sessions"))
psess = importlib.util.module_from_spec(importlib.util.spec_from_loader("psess", sess_loader))
sess_loader.exec_module(psess)
home = tempfile.mkdtemp(prefix="f13_", dir="/tmp"); repo = mkrepo(home)
spec = {"name": "sweep", "dir": repo, "steps": [
    {"id": "a", "backend": "claude", "perm": "plan",
     "prompt": "x\nSHIM:" + json.dumps({"sid": "sessA", "text": "A"})}]}
wf, led = run(home, spec)
st = step(led, "a")
rrepo = os.path.realpath(repo)
check("F13 ledger records the step's sessionId + realpath dir",
      st.get("sessionId") == "sessA" and st.get("sessionDir") == rrepo, st)

proj = os.path.join(home, ".claude", "projects")
user_fold = os.path.join(proj, psess.encode(rrepo))          # the user's real project
os.makedirs(user_fold, exist_ok=True)
open(os.path.join(user_fold, "sessA.jsonl"), "w").write('{"type":"user"}\n')
open(os.path.join(user_fold, "keepme.jsonl"), "w").write('{"type":"user"}\n')
wt_cwd = os.path.realpath(os.path.join(home, ".pervio", "wf", wf, "wt", "steps", "a"))
wf_fold = os.path.join(proj, psess.encode(wt_cwd))           # a wf-owned cwd's project
os.makedirs(wf_fold, exist_ok=True)
open(os.path.join(wf_fold, "child.jsonl"), "w").write('{"type":"user"}\n')

delete(home, wf)
check("F13 the step's own conversation deleted", not os.path.exists(os.path.join(user_fold, "sessA.jsonl")))
check("F13 unrelated conversation in the same project SURVIVES", os.path.exists(os.path.join(user_fold, "keepme.jsonl")))
check("F13 wf-owned project folder removed wholesale", not os.path.exists(wf_fold))
check("F13 encode reference behavior pinned", psess.encode("/a/b.c 个") == "-a-b-c--", psess.encode("/a/b.c 个"))
shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- F14: `spec --wf` returns the original spec verbatim (re-run seed) ----------
print("=== F14 spec fetch for re-run ===")
home = tempfile.mkdtemp(prefix="f14_", dir="/tmp"); repo = mkrepo(home)
spec = spec_producer_fanout(repo, [{"text": "x"}], fanout={"maxParallel": 2, "max": 5})
wf, led = run(home, spec)
p = subprocess.run([sys.executable, ORCH, "spec", "--wf", wf], env=env(home),
                   capture_output=True, text=True)
got = json.loads(p.stdout) if p.returncode == 0 else {}
fo = next((s for s in got.get("steps", []) if s.get("id") == "work"), {}).get("fanout") or {}
check("F14 spec returns name + dir + steps", got.get("name") == "fout" and got.get("dir") == repo
      and [s.get("id") for s in got.get("steps", [])] == ["make", "work"], got)
check("F14 fanout knobs survive verbatim",
      fo.get("over") == "{{make.output}}" and fo.get("maxParallel") == 2 and fo.get("max") == 5, fo)
delete(home, wf); shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- F15: fanout.timeoutSec honored + clamped (ledger fanoutTimeout) ----------
# Spec value is untrusted: floor 60 stops a typo'd "5" insta-killing every child,
# ceiling 900 bounds a runaway pile-up; garbage falls back to the env default.
print("=== F15 timeoutSec clamp ===")
home = tempfile.mkdtemp(prefix="f15_", dir="/tmp"); repo = mkrepo(home)
for req, want, tag in ((None, 180, "absent->default"), (1, 60, "floor"),
                       (99999, 900, "ceiling"), (300, 300, "in-range"),
                       ("abc", 180, "garbage->default")):
    fo = {} if req is None else {"timeoutSec": req}
    wf, led = run(home, spec_producer_fanout(repo, [{"text": "t"}], fanout=fo))
    w = step(led, "work")
    check("F15 %s: timeoutSec=%r -> fanoutTimeout=%d, step done" % (tag, req, want),
          w.get("fanoutTimeout") == want and w.get("status") == "done", w)
    delete(home, wf)
shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- F16: a child that outlives the wall clock is killed + reported FAIL ----------
# (the deep-code-audit failure mode: before timeoutSec, 8/8 auditors died like this)
print("=== F16 child timeout kill path ===")
home = tempfile.mkdtemp(prefix="f16_", dir="/tmp"); repo = mkrepo(home)
t0 = time.time()
wf, led = run(home, spec_producer_fanout(repo, [{"text": "slow", "sleep": 6}, {"text": "fast"}]),
              extra_env={"PERVIO_CHILD_TIMEOUT": "1"})
dt = time.time() - t0
w = step(led, "work")
check("F16 env timeout passes through unclamped (fanoutTimeout=1)", w.get("fanoutTimeout") == 1, w)
check("F16 slow child FAIL: timeout, fast child OK",
      w.get("fanoutOk") == 1 and w.get("fanoutFail") == 1 and "FAIL: timeout" in (w.get("output") or ""),
      (w.get("output") or "")[:120])
check("F16 step still done (>=1 ok) and slow child actually killed (%.1fs < 5s)" % dt,
      w.get("status") == "done" and dt < 5.0, "%.2fs" % dt)
check("F16 no worktrees leaked by the killed child",
      g(repo, "worktree", "list", "--porcelain")[1].count("worktree ") == 1)
delete(home, wf); shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ==================== C1: {{id.output}} refs are DEPENDENCY edges ====================
# A ref is the consumer's data input. Under worktree isolation the scheduler already
# ordered by it; in SHARED mode (the common case: no repo, or fewer than two
# concurrent writers) gating was dependsOn-only, so a consumer could be submitted in
# the SAME scheduling pass as its producer, substitute "" for the ref, and the run
# still reported `done` — a silently wrong result nobody sees. Both modes must go
# through _dep_edges, and a ref to a step that does not exist must be refused BEFORE
# anything is spent.
print("=== C1 ref edges in shared mode + unknown-ref rejection ===")

# unit: _dep_edges is the single source of truth for both modes
_e = orch._dep_edges([{"id": "p", "prompt": "x"},
                      {"id": "c", "prompt": "use {{p.output}}"}])
check("C1 unit: a ref is an edge in _dep_edges", _e["c"] == {"p"} and _e["p"] == set(), _e)

# e2e: dir=/tmp is not a git repo -> _plan_isolation returns None -> SHARED path.
# The producer sleeps; the consumer's OWN reply is built from the substituted ref,
# so its ledger output tells us verbatim what it read.
home = tempfile.mkdtemp(prefix="c1_", dir="/tmp")
c1_spec = {"name": "c1", "dir": "/tmp", "steps": [
    {"id": "prod", "backend": "claude", "perm": "plan",
     "prompt": "produce\nSHIM:" + json.dumps({"text": "PRODUCED", "sleep": 3})},
    {"id": "cons", "backend": "claude", "perm": "plan",
     "prompt": "consume\nSHIM:" + json.dumps({"text": "saw[{{prod.output}}]"})}]}
wf, led = run(home, c1_spec)
_p, _c = step(led, "prod"), step(led, "cons")
check("C1 shared mode: consumer waited and read the real output",
      _c.get("output") == "saw[PRODUCED]", _c.get("output"))
check("C1 shared mode: consumer STARTED after the producer ENDED",
      _p.get("endedAt") and _c.get("startedAt") and _c["startedAt"] >= _p["endedAt"],
      (_p.get("startedAt"), _p.get("endedAt"), _c.get("startedAt")))
check("C1 the run itself is still done (ordering only, no new failure)",
      led.get("status") == "done", led.get("status"))
delete(home, wf)

# A ref to a step that doesn't exist is a typo'd spec: refuse the START (before any
# agent turn is paid for) instead of substituting "" at runtime.
ghost = {"name": "c1g", "dir": "/tmp", "steps": [
    {"id": "a", "backend": "claude", "perm": "plan", "prompt": "x\nSHIM:{\"text\":\"a\"}"},
    {"id": "b", "backend": "claude", "perm": "plan",
     "prompt": "use {{ghost.output}}\nSHIM:{\"text\":\"b\"}"}]}
gp = subprocess.run([sys.executable, ORCH, "start", "--spec-b64",
                     base64.b64encode(json.dumps(ghost).encode()).decode()],
                    env=env(home), capture_output=True, text=True)
check("C1 unknown ref rejects the start (non-zero, names the ref)",
      gp.returncode != 0 and "ghost" in (gp.stderr or ""), (gp.returncode, gp.stdout, gp.stderr))
check("C1 unknown ref started NOTHING (no run dir created)",
      not os.path.isdir(os.path.join(home, ".pervio", "wf"))
      or os.listdir(os.path.join(home, ".pervio", "wf")) == [])
# …and a fan-out `over` pointing at a non-step is the same typo, same refusal.
gfo = {"name": "c1f", "dir": "/tmp", "steps": [
    {"id": "a", "backend": "claude", "perm": "plan", "prompt": "x\nSHIM:{\"text\":\"a\"}"},
    {"id": "b", "backend": "claude", "perm": "plan", "prompt": "p\nSHIM:{{item}}",
     "fanout": {"over": "{{nosuch.output}}"}}]}
gf = subprocess.run([sys.executable, ORCH, "start", "--spec-b64",
                     base64.b64encode(json.dumps(gfo).encode()).decode()],
                    env=env(home), capture_output=True, text=True)
check("C1 unknown fanout 'over' ref rejects the start",
      gf.returncode != 0 and "nosuch" in (gf.stderr or ""), (gf.returncode, gf.stderr))
shutil.rmtree(home, ignore_errors=True)

# ==================== C4: dependsOn is validated; a crash never hangs a run ====
# `dependsOn` was taken on faith. A non-list value (the app's encoder can't produce
# one, but an imported/hand-edited spec can) blew up inside the runner's DAG loop:
# the detached runner died with a traceback nobody reads, ledger.status stayed
# "running" FOREVER and the phone spun on a run that was already dead. Two layers:
# reject the bad shape at start, and — for anything unforeseen — a crash net that
# lands the run as failed instead of leaving it running.
print("=== C4 dependsOn validation + runner crash net ===")
home = tempfile.mkdtemp(prefix="c4_", dir="/tmp")


def _start_rc(spec):
    p = subprocess.run([sys.executable, ORCH, "start", "--spec-b64",
                        base64.b64encode(json.dumps(spec).encode()).decode()],
                       env=env(home), capture_output=True, text=True)
    return p


def _spec_with_dep(dep):
    return {"name": "c4", "dir": "/tmp", "steps": [
        {"id": "a", "backend": "claude", "perm": "plan", "prompt": "x\nSHIM:{\"text\":\"a\"}"},
        {"id": "b", "backend": "claude", "perm": "plan", "dependsOn": dep,
         "prompt": "y\nSHIM:{\"text\":\"b\"}"}]}


for bad, tag in ((5, "int"), ("a", "bare string"), ({"a": 1}, "object"),
                 ([1], "list of non-strings"), ([""], "list with an empty id"),
                 (["ghost"], "unknown step id")):
    rp = _start_rc(_spec_with_dep(bad))
    # rc 2 + no traceback = _die'd cleanly by the validator. A crash (rc 1, traceback
    # naming dependsOn) also "fails", and must not be allowed to pass for it.
    check("C4 dependsOn=%r (%s) rejected cleanly at start" % (bad, tag),
          rp.returncode == 2 and "dependsOn" in (rp.stderr or "")
          and "Traceback" not in (rp.stderr or ""),
          (rp.returncode, rp.stdout.strip(), rp.stderr.strip()[-160:]))
for good, tag in (([], "empty list"), (["a"], "real id")):
    rp = _start_rc(_spec_with_dep(good))
    check("C4 dependsOn=%r (%s) still accepted" % (good, tag), rp.returncode == 0,
          (rp.returncode, rp.stderr.strip()))
for _w in (os.listdir(os.path.join(home, ".pervio", "wf"))
           if os.path.isdir(os.path.join(home, ".pervio", "wf")) else []):
    delete(home, _w)

# The net: a run dir whose spec.json crashes the scheduler (written by an older
# build, or hand-edited past validation) must still END. Hand-build the run dir
# exactly as _start_wf does, then invoke the detached runner directly.
rd = os.path.join(home, ".pervio", "wf", "c4stuck0001")
os.makedirs(rd, exist_ok=True)
json.dump(_spec_with_dep(5), open(os.path.join(rd, "spec.json"), "w"))
json.dump({"wfId": "c4stuck0001", "name": "c4", "dir": "/tmp", "status": "running",
           "startedAt": int(time.time()),
           "steps": [{"id": "a", "backend": "claude", "dependsOn": [], "inputs": [],
                      "status": "pending", "output": "", "error": "", "bytes": 0},
                     {"id": "b", "backend": "claude", "dependsOn": [], "inputs": [],
                      "status": "pending", "output": "", "error": "", "bytes": 0}]},
          open(os.path.join(rd, "ledger.json"), "w"))
open(os.path.join(rd, "status"), "w").write("running")
rp = subprocess.run([sys.executable, ORCH, "run", "--wf", "c4stuck0001"],
                    env=env(home), capture_output=True, text=True, timeout=60)
crashed = json.load(open(os.path.join(rd, "ledger.json")))
status_file = open(os.path.join(rd, "status")).read().strip()
check("C4 crash net: ledger lands 'failed', never stuck 'running'",
      crashed.get("status") == "failed", (crashed.get("status"), rp.stderr[-200:]))
check("C4 crash net: every step is terminal (no eternal pending/running)",
      all(s.get("status") in ("done", "failed", "skipped") for s in crashed.get("steps", [])),
      [s.get("status") for s in crashed.get("steps", [])])
check("C4 crash net: the crash is named in the ledger",
      "runner crashed" in json.dumps(crashed), json.dumps(crashed)[:200])
check("C4 crash net: status file becomes terminal (exited:1)",
      status_file == "exited:1", status_file)
check("C4 crash net: the traceback still reaches stderr for diagnosis",
      "Traceback" in (rp.stderr or ""), (rp.stderr or "")[-200:])
shutil.rmtree(home, ignore_errors=True)

# ---------- F9: truncated producer -> fanout refuses loudly ----------
print("=== F9 truncated source refused (the 92-lost-papers class) ===")
home = tempfile.mkdtemp(prefix="ftr_", dir="/tmp"); repo = mkrepo(home)
# A COMMAND producer: 40 numbered lines (~1.5KB) against a 300-byte capture cap.
# The capture ends mid-list with the truncation marker; fanning out over that
# used to silently dispatch only the surviving prefix (2026-09-01: 12 of 19
# digest shards). Now the work step must FAIL and say why.
trunc_spec = {"name": "ftrunc", "dir": repo, "steps": [
    {"id": "make", "backend": "claude", "prompt": "",
     "command": "python3 -c \"[print('%d. item-%03d' % (i, i)) for i in range(1, 41)]\""},
    {"id": "work", "backend": "claude", "perm": "plan",
     "fanout": {"over": "{{make.output}}", "split": "numbered", "as": "item"},
     "prompt": "process\nSHIM:{{item}}"}]}
wf, led = run(home, trunc_spec, extra_env={"PERVIO_CMD_MAX_OUTPUT": "300"})
mk, w = step(led, "make"), step(led, "work")
check("F9 producer landed done with a MARKED capture",
      mk.get("status") == "done" and "…[truncated" in (mk.get("output") or ""),
      (mk.get("status"), (mk.get("output") or "")[-60:]))
check("F9 fanout REFUSES the partial list, loudly",
      w.get("status") == "failed" and "TRUNCATED" in (w.get("error") or "")
      and "PERVIO_CMD_MAX_OUTPUT" in (w.get("error") or ""),
      w.get("error"))
check("F9 nothing was dispatched off the partial list",
      not w.get("fanoutOk"), w)
delete(home, wf); shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

ok = all(results)
print("\n=== pervio-orchestrate fan-out: %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
