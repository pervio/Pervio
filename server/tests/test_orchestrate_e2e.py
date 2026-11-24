#!/usr/bin/env python3
"""P3 e2e: E0 = the BEFORE/AFTER clobber demonstration (old orchestrator from git
HEAD vs new one; shim agents, deterministic). E2/E1 = real claude haiku working in
worktrees (disjoint merge + same-file conflict). E4 = real codex workspace-write in
a worktree (closes the probe's un-runnable-sandbox gap)."""
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.realpath(__file__))
NEW = os.path.realpath(os.path.join(HERE, "..", "bin", "pervio-orchestrate"))
OLD_DIR = tempfile.mkdtemp(prefix="p3old_", dir="/tmp")
OLD = os.path.join(OLD_DIR, "pervio-orchestrate")
SHIM = os.path.join(HERE, "shim")
SHIM_ENV = dict(os.environ, PATH=SHIM + ":" + os.environ.get("PATH", ""))
REAL_ENV = dict(os.environ)

results = []


def check(name, cond, detail=""):
    results.append(cond)
    print(("PASS " if cond else "FAIL ") + name + (("  [" + str(detail)[:200] + "]") if (detail and not cond) else ""))


def g(cwd, *args):
    p = subprocess.run(["git", "-C", cwd] + list(args), capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def mkrepo(files):
    d = tempfile.mkdtemp(prefix="p3e_", dir="/tmp")
    g(d, "init", "-q", "-b", "main")
    g(d, "config", "user.email", "t@t")
    g(d, "config", "user.name", "t")
    for f, c in files:
        with open(os.path.join(d, f), "w") as fh:
            fh.write(c)
    g(d, "add", "-A")
    g(d, "commit", "-qm", "base")
    return d


def run_wf(orch, spec, env, timeout=420):
    b64 = base64.b64encode(json.dumps(spec).encode()).decode()
    p = subprocess.run([sys.executable, orch, "start", "--spec-b64", b64],
                       env=env, capture_output=True, text=True)
    wf = json.loads(p.stdout)["wfId"]
    for _ in range(timeout):
        q = subprocess.run([sys.executable, orch, "status", "--wf", wf],
                           env=env, capture_output=True, text=True)
        led = json.loads(q.stdout) if q.returncode == 0 else {}
        if led.get("status") in ("done", "failed"):
            return wf, led
        time.sleep(1)
    raise TimeoutError(wf)


def delete(orch, wf, env):
    subprocess.run([sys.executable, orch, "delete", "--wf", wf], env=env,
                   capture_output=True, text=True)


def shim_step(sid, writes, perm="acceptEdits"):
    ins = {"write": [{"file": f, "content": c} for f, c in writes], "text": "done " + sid}
    return {"id": sid, "backend": "claude", "perm": perm,
            "prompt": "task %s\nSHIM:%s" % (sid, json.dumps(ins))}


# ---------------- E0: the headline before/after ----------------
# The "before" orchestrator is PINNED to the last pre-P3 commit: E0's whole point
# is to demonstrate the silent clobber that P3 fixed. It used to extract HEAD,
# which stopped being "old" the moment P3 merged — and stopped even importing
# once run_child split into _pervio_lib (single-file extraction to /tmp).
print("=== E0 BEFORE (pre-P3 orchestrator, pinned) — silent clobber ===")
PRE_P3 = "654b18a^"   # parent of "Isolate parallel workflow write-steps in git worktrees"
rc = subprocess.run(["git", "-C", os.path.join(HERE, "..", ".."), "show",
                     PRE_P3 + ":server/bin/pervio-orchestrate"], capture_output=True, text=True)
with open(OLD, "w") as f:
    f.write(rc.stdout)
# the pre-P3 orchestrator resolves pervio-chat NEXT TO ITSELF (SELF_DIR) — give the
# extracted copy a neighbor, or every step dies hunting for <tmpdir>/pervio-chat
os.symlink(os.path.join(HERE, "..", "bin", "pervio-chat"), os.path.join(OLD_DIR, "pervio-chat"))
clobber = lambda: [shim_step("east", [("greeting.txt", "east version\n")]),
                   shim_step("west", [("greeting.txt", "west version\n")])]
repo = mkrepo([("greeting.txt", "original\n")])
wf, led = run_wf(OLD, {"name": "e0-before", "dir": repo, "steps": clobber()}, SHIM_ENV)
sts = sorted(s["status"] for s in led["steps"])
with open(os.path.join(repo, "greeting.txt")) as f:
    content = f.read()
check("E0-before BOTH steps report done (no error at all)", sts == ["done", "done"], sts)
check("E0-before one write silently LOST (the P3 bug)",
      content in ("east version\n", "west version\n"), content)
print("   -> old code: both 'done', file ended as %r — the other step's work vanished, nobody told you" % content.strip())
delete(OLD, wf, SHIM_ENV)
shutil.rmtree(repo, ignore_errors=True)

print("=== E0 AFTER (new orchestrator) — deterministic, honest ===")
repo = mkrepo([("greeting.txt", "original\n")])
_, base_head, _ = g(repo, "rev-parse", "HEAD")
wf, led = run_wf(NEW, {"name": "e0-after", "dir": repo, "steps": clobber()}, SHIM_ENV)
sts = sorted(s["status"] for s in led["steps"])
loser = next((s for s in led["steps"] if s["status"] == "failed"), {})
check("E0-after exactly one winner, one explicit failure", sts == ["done", "failed"], sts)
check("E0-after failure names file + branch",
      "greeting.txt" in loser.get("error", "") and "pervio/wf-" in loser.get("error", ""), loser.get("error"))
_, head_now, _ = g(repo, "rev-parse", "HEAD")
check("E0-after user checkout untouched", head_now == base_head)
delete(NEW, wf, SHIM_ENV)
shutil.rmtree(repo, ignore_errors=True)

# ---------------- E2: real claude haiku, disjoint parallel ----------------
print("=== E2 real claude (haiku): disjoint parallel writers ===")
HK = "claude-haiku-4-5-20251001"
repo = mkrepo([("readme.md", "test repo\n")])
spec = {"name": "e2", "dir": repo, "steps": [
    {"id": "a", "backend": "claude", "perm": "acceptEdits", "model": HK, "effort": "low",
     "prompt": "Create a file named a.txt in the current directory containing exactly the line: alpha\nUse the Write tool. Do nothing else, then stop."},
    {"id": "b", "backend": "claude", "perm": "acceptEdits", "model": HK, "effort": "low",
     "prompt": "Create a file named b.txt in the current directory containing exactly the line: beta\nUse the Write tool. Do nothing else, then stop."},
]}
wf, led = run_wf(NEW, spec, REAL_ENV)
gg = led.get("git") or {}
check("E2 run done", led.get("status") == "done",
      json.dumps({"steps": [(s["id"], s["status"], s.get("error", "")[:80]) for s in led["steps"]]}))
check("E2 merged back", gg.get("merged") is True, gg)
a_ok = os.path.exists(os.path.join(repo, "a.txt")) and "alpha" in open(os.path.join(repo, "a.txt")).read()
b_ok = os.path.exists(os.path.join(repo, "b.txt")) and "beta" in open(os.path.join(repo, "b.txt")).read()
check("E2 both real-agent edits landed on the user's branch", a_ok and b_ok)
_, refs, _ = g(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/pervio/")
check("E2 zero pervio refs left", refs == "", refs)
delete(NEW, wf, REAL_ENV)
shutil.rmtree(repo, ignore_errors=True)

# ---------------- E1: real claude haiku, same-file conflict ----------------
print("=== E1 real claude (haiku): same-file conflict ===")
repo = mkrepo([("greeting.txt", "original greeting\n")])
_, base_head, _ = g(repo, "rev-parse", "HEAD")
spec = {"name": "e1", "dir": repo, "steps": [
    {"id": "east", "backend": "claude", "perm": "acceptEdits", "model": HK, "effort": "low",
     "prompt": "Replace the ENTIRE content of greeting.txt with exactly this one line: hello from east\nUse the Edit or Write tool. Do nothing else, then stop."},
    {"id": "west", "backend": "claude", "perm": "acceptEdits", "model": HK, "effort": "low",
     "prompt": "Replace the ENTIRE content of greeting.txt with exactly this one line: hello from west\nUse the Edit or Write tool. Do nothing else, then stop."},
]}
wf, led = run_wf(NEW, spec, REAL_ENV)
sts = sorted(s["status"] for s in led["steps"])
loser = next((s for s in led["steps"] if s["status"] == "failed"), {})
check("E1 exactly one winner", sts == ["done", "failed"],
      json.dumps([(s["id"], s["status"], s.get("error", "")[:80]) for s in led["steps"]]))
check("E1 loser explains the conflict", "merge conflict" in loser.get("error", "")
      and "greeting.txt" in loser.get("error", ""), loser.get("error"))
_, head_now, _ = g(repo, "rev-parse", "HEAD")
check("E1 user checkout untouched (results on branches)", head_now == base_head)
delete(NEW, wf, REAL_ENV)
shutil.rmtree(repo, ignore_errors=True)

# ---------------- E4: real codex workspace-write in a worktree ----------------
print("=== E4 real codex: workspace-write pair in worktrees ===")
repo = mkrepo([("readme.md", "codex test\n")])
spec = {"name": "e4", "dir": repo, "steps": [
    {"id": "x", "backend": "codex", "sandbox": "workspace-write", "effort": "low",
     "prompt": "Create a file named x.txt in the current directory containing exactly the line: xray\nDo nothing else, then stop."},
    {"id": "y", "backend": "codex", "sandbox": "workspace-write", "effort": "low",
     "prompt": "Create a file named y.txt in the current directory containing exactly the line: yankee\nDo nothing else, then stop."},
]}
wf, led = run_wf(NEW, spec, REAL_ENV)
gg = led.get("git") or {}
check("E4 codex run done", led.get("status") == "done",
      json.dumps({"steps": [(s["id"], s["status"], s.get("error", "")[:80]) for s in led["steps"]]}))
check("E4 merged back", gg.get("merged") is True, gg)
x_ok = os.path.exists(os.path.join(repo, "x.txt"))
y_ok = os.path.exists(os.path.join(repo, "y.txt"))
check("E4 codex edits (made INSIDE worktrees) landed", x_ok and y_ok, (x_ok, y_ok))
delete(NEW, wf, REAL_ENV)
shutil.rmtree(repo, ignore_errors=True)

ok = all(results)
print("\n=== P3 E-SUITE: %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
