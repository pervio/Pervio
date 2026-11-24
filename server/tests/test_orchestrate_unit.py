#!/usr/bin/env python3
"""P3 worktree-isolation U-suite: drives the REAL pervio-orchestrate + REAL
pervio-chat with shim claude/codex binaries (zero model calls, controlled timing).
Covers: trigger matrix (U2), happy-path merge incl. a step literally named
"integration" (U1+U3), conflict (U4), hostile hooks (U5), reader rescue (U6),
delete mid-run (U7), crash (U8), merge-back guards (U9), setup/verify (U10),
zero-regression shared mode (U11)."""
import base64
import importlib.machinery
import importlib.util
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
os.environ.setdefault("PERVIO_RUN_IDLE_GRACE", "1.5")   # a living run ends a beat after its reply here, not 180 s

HERE = os.path.dirname(os.path.realpath(__file__))
ORCH = os.path.realpath(os.path.join(HERE, "..", "bin", "pervio-orchestrate"))
SHIM = os.path.join(HERE, "shim")

# --- hermetic $HOME -----------------------------------------------------------
# This suite drives the REAL pervio-orchestrate, which keeps every run under
# $HOME/.pervio/wf and sweeps conversations out of $HOME/.claude/projects. Aimed
# at the user's own home it wrote LIVE workflow state there (observed 2026-08-07:
# run dirs present under ~/.pervio/wf for the whole length of the suite) and made
# that directory a resource shared with any other copy of the suite running at
# the same time. It now gets a throwaway home. The real one is never written and
# never read — it is not needed here: the agents are shims, so there are no
# credentials to inherit. HOME is set BEFORE anything computes expanduser("~"),
# including the in-process import of pervio-orchestrate below (its WF/SCHED
# constants are frozen at import time).
REAL_HOME = os.path.realpath(os.path.expanduser("~"))
HOME = tempfile.mkdtemp(prefix="p3unit_home_", dir="/tmp")
os.environ["HOME"] = HOME
ENV = dict(os.environ, PATH=SHIM + ":" + os.environ.get("PATH", ""))
WFROOT = os.path.join(HOME, ".pervio", "wf")
REAL_WF = os.path.join(REAL_HOME, ".pervio", "wf")

results = []
# Where each run this suite starts was seen to live, sampled WHILE it existed:
# (wfId, present under the throwaway home, present under the real one). Read by
# U0b at the end — see the note there for why it cannot be sampled at exit.
RUNS = []
OWNERS = []   # (device, origin) each start recorded — the phone its pushes go to


def check(name, cond, detail=""):
    results.append(cond)
    print(("PASS " if cond else "FAIL ") + name + (("  [" + str(detail)[:160] + "]") if (detail and not cond) else ""))


def g(cwd, *args):
    p = subprocess.run(["git", "-C", cwd] + list(args), capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def mkrepo():
    d = tempfile.mkdtemp(prefix="p3repo_", dir="/tmp")
    g(d, "init", "-q", "-b", "main")
    g(d, "config", "user.email", "t@t")
    g(d, "config", "user.name", "t")
    with open(os.path.join(d, "base.txt"), "w") as f:
        f.write("base\n")
    g(d, "add", "-A")
    g(d, "commit", "-qm", "base")
    return d


def shim_step(sid, writes=None, sleep=0, perm="acceptEdits", backend="claude",
              deps=None, verify=None, text=None, sandbox=None, rc=0):
    ins = {"write": [{"file": f, "content": c} for f, c in (writes or [])],
           "sleep": sleep, "rc": rc, "text": text or ("done " + sid)}
    s = {"id": sid, "backend": backend, "prompt": "task %s\nSHIM:%s" % (sid, json.dumps(ins))}
    if backend == "codex":
        if sandbox:
            s["sandbox"] = sandbox
    else:
        s["perm"] = perm
    if deps:
        s["dependsOn"] = deps
    if verify:
        s["verify"] = verify
    return s


def start(spec):
    b64 = base64.b64encode(json.dumps(spec).encode()).decode()
    # Every start carries the starting phone (as the app sends it): U-dev
    # reads one ledger back at the end.
    p = subprocess.run([sys.executable, ORCH, "start", "--spec-b64", b64,
                        "--device", "phone-unit", "--origin", "entry-unit"],
                       env=ENV, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError("start failed: " + p.stderr)
    wf = json.loads(p.stdout)["wfId"]
    led = json.load(open(os.path.join(WFROOT, wf, "ledger.json")))
    OWNERS.append((led.get("device"), led.get("origin")))
    # The evidence U0b reads. `start` has already created the run dir and written
    # its ledger, so both halves are answerable right now — and only now.
    RUNS.append((wf, os.path.isdir(os.path.join(WFROOT, wf)),
                 os.path.exists(os.path.join(REAL_WF, wf))))
    return wf


def status(wf):
    p = subprocess.run([sys.executable, ORCH, "status", "--wf", wf],
                       env=ENV, capture_output=True, text=True)
    return json.loads(p.stdout) if p.returncode == 0 else {}


def wait(wf, timeout=90):
    for _ in range(timeout * 4):
        led = status(wf)
        if led.get("status") in ("done", "failed"):
            return led
        time.sleep(0.25)
    raise TimeoutError(wf)


def delete(wf):
    subprocess.run([sys.executable, ORCH, "delete", "--wf", wf],
                   env=ENV, capture_output=True, text=True)


def pervio_refs(repo):
    _, out, _ = g(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/pervio/")
    return [l for l in out.splitlines() if l.strip()]


def registered_wts(repo):
    _, out, _ = g(repo, "worktree", "list", "--porcelain")
    return out.count("worktree ")


def step(led, sid):
    for s in led.get("steps", []):
        if s["id"] == sid:
            return s
    return {}


# ---------------- U2: trigger matrix (module-level, no runs) ----------------
loader = importlib.machinery.SourceFileLoader("orch", ORCH)
spec_ = importlib.util.spec_from_loader("orch", loader)
orch = importlib.util.module_from_spec(spec_)
loader.exec_module(orch)

print("=== U0 hermetic home ===")
# The containment claim, asserted rather than assumed: the module we just loaded
# is the same code the subprocesses run, and its run root is the throwaway home.
check("U0 pervio-orchestrate's run root is the throwaway home, not the user's",
      os.path.realpath(orch.WF) == os.path.realpath(WFROOT)
      and not os.path.realpath(orch.WF).startswith(REAL_HOME + os.sep),
      (orch.WF, WFROOT, REAL_HOME))
check("U0 ...and so are the schedule and template roots",
      not os.path.realpath(orch.SCHED).startswith(REAL_HOME + os.sep)
      and not os.path.realpath(orch.TPL).startswith(REAL_HOME + os.sep),
      (orch.SCHED, orch.TPL))

print("=== U2 trigger matrix ===")
check("U2 plan is reader", orch._is_reader({"perm": "plan"}))
check("U2 codex read-only is reader", orch._is_reader({"backend": "codex", "sandbox": "read-only"}))
check("U2 plan+verify is WRITER", not orch._is_reader({"perm": "plan", "verify": "true"}))
check("U2 default is WRITER", not orch._is_reader({"perm": "default"}))
check("U2 auto is WRITER", not orch._is_reader({"perm": "auto"}))
check("U2 codex no-sandbox is WRITER", not orch._is_reader({"backend": "codex"}))
check("U2 codex typo'd sandbox is WRITER", not orch._is_reader({"backend": "codex", "sandbox": "read_only"}))

repo_u2 = mkrepo()
two = [shim_step("a", [("a.txt", "1")]), shim_step("b", [("b.txt", "2")])]
iso = orch._plan_isolation({"dir": repo_u2, "steps": two}, two)
check("U2 two concurrent writers -> isolated", iso is not None)
chain = [shim_step("a", [("a.txt", "1")]), shim_step("b", [("b.txt", "2")], deps=["a"])]
check("U2 dependent chain -> shared", orch._plan_isolation({"dir": repo_u2, "steps": chain}, chain) is None)
refchain = [shim_step("a", [("a.txt", "1")])]
b = shim_step("b", [("b.txt", "2")])
b["prompt"] = "use {{a.output}}\n" + b["prompt"]
refchain.append(b)
check("U2 {{ref}} counts as an edge -> shared", orch._plan_isolation({"dir": repo_u2, "steps": refchain}, refchain) is None)
nonrepo = tempfile.mkdtemp(prefix="p3plain_", dir="/tmp")
check("U2 non-git dir -> shared", orch._plan_isolation({"dir": nonrepo, "steps": two}, two) is None)
sub = os.path.join(repo_u2, "pkg")
os.makedirs(sub, exist_ok=True)
subspec = [shim_step("a", [("a.txt", "1")]), shim_step("b", [("b.txt", "2")])]
subspec[0]["dir"] = sub
iso2 = orch._plan_isolation({"dir": repo_u2, "steps": subspec}, subspec)
check("U2 in-repo subdir maps a prefix", bool(iso2) and iso2["prefix"].get("a") == "pkg", iso2 and iso2["prefix"])
shutil.rmtree(nonrepo, ignore_errors=True)
shutil.rmtree(repo_u2, ignore_errors=True)

# ---------------- U1+U3: happy path, disjoint writers, step named "integration"
print("=== U1+U3 happy path ===")
repo = mkrepo()
_, base_head, _ = g(repo, "rev-parse", "HEAD")
wf = start({"name": "u3", "dir": repo, "steps": [
    shim_step("a", [("a.txt", "alpha\n")]),
    shim_step("b", [("b.txt", "beta\n")]),
    shim_step("integration", [("c.txt", "gamma\n")]),
]})
led = wait(wf)
check("U3 run done", led.get("status") == "done", led)
check("U3 all steps isolation=worktree", all(s.get("isolation") == "worktree" for s in led["steps"]))
check("U3 merged back", (led.get("git") or {}).get("merged") is True, led.get("git"))
ok_files = all(os.path.exists(os.path.join(repo, f)) for f in ("a.txt", "b.txt", "c.txt"))
check("U3 all three files on the user's branch", ok_files)
_, porc, _ = g(repo, "status", "--porcelain")
check("U3 user tree clean after ff", porc == "", porc)
check("U3 zero pervio refs left", pervio_refs(repo) == [], pervio_refs(repo))
check("U3 zero extra worktree registrations", registered_wts(repo) == 1)
_, cnt, _ = g(repo, "rev-list", "--count", "HEAD")
check("U3 history advanced (merge commits present)", int(cnt or 0) >= 4, cnt)
delete(wf)
shutil.rmtree(repo, ignore_errors=True)

# ---------------- U4: conflict ----------------
print("=== U4 conflict ===")
repo = mkrepo()
_, base_head, _ = g(repo, "rev-parse", "HEAD")
wf = start({"name": "u4", "dir": repo, "steps": [
    shim_step("east", [("conflict.txt", "east version\n")]),
    shim_step("west", [("conflict.txt", "west version\n")]),
]})
led = wait(wf)
sts = {s["id"]: s["status"] for s in led["steps"]}
check("U4 run failed overall", led.get("status") == "failed", sts)
check("U4 exactly one winner", sorted(sts.values()) == ["done", "failed"], sts)
loser = next((s for s in led["steps"] if s["status"] == "failed"), {})
check("U4 loser names the file", "conflict.txt" in loser.get("error", ""), loser.get("error"))
check("U4 loser names its branch", "pervio/wf-" in loser.get("error", ""), loser.get("error"))
check("U4 not merged back", (led.get("git") or {}).get("merged") is False)
_, head_now, _ = g(repo, "rev-parse", "HEAD")
_, porc, _ = g(repo, "status", "--porcelain")
check("U4 user checkout untouched", head_now == base_head and porc == "")
refs = pervio_refs(repo)
check("U4 branches kept for inspection", any("/steps/" in r for r in refs) and any(r.endswith("/integration") for r in refs), refs)
lbr = "pervio/wf-%s/steps/%s" % (wf, loser.get("id"))
_, lcontent, _ = g(repo, "show", "%s:conflict.txt" % lbr)
check("U4 loser's work preserved on its branch", "version" in lcontent, lcontent)
delete(wf)
check("U4 delete clears refs + registrations", pervio_refs(repo) == [] and registered_wts(repo) == 1)
shutil.rmtree(repo, ignore_errors=True)

# ---------------- U5: hostile repo (failing hook + gpgsign) ----------------
print("=== U5 hostile hooks ===")
repo = mkrepo()
hook = os.path.join(repo, ".git", "hooks", "pre-commit")
with open(hook, "w") as f:
    f.write("#!/bin/sh\nexit 1\n")
os.chmod(hook, 0o755)
g(repo, "config", "commit.gpgsign", "true")
wf = start({"name": "u5", "dir": repo, "steps": [
    shim_step("a", [("a.txt", "1\n")]),
    shim_step("b", [("b.txt", "2\n")]),
]})
led = wait(wf)
check("U5 hostile repo still merges", led.get("status") == "done" and (led.get("git") or {}).get("merged") is True,
      json.dumps({"status": led.get("status"), "git": led.get("git"), "errs": [s.get("error") for s in led.get("steps", [])]}))
delete(wf)
shutil.rmtree(repo, ignore_errors=True)

# ---------------- U6: reader rescue ----------------
print("=== U6 reader rescue ===")
repo = mkrepo()
wf = start({"name": "u6", "dir": repo, "steps": [
    shim_step("sneaky", [("r.txt", "written by a 'plan' step\n")], perm="plan"),
    shim_step("w1", [("a.txt", "1\n")]),
    shim_step("w2", [("b.txt", "2\n")]),
]})
led = wait(wf)
sn = step(led, "sneaky")
check("U6 sneaky reader FAILED", sn.get("status") == "failed", sn.get("status"))
check("U6 error explains rescue", "read-classified" in sn.get("error", ""), sn.get("error"))
rbr = "pervio/wf-%s/steps/sneaky" % wf
rc, rcontent, _ = g(repo, "show", "%s:r.txt" % rbr)
check("U6 rescue branch holds the work", rc == 0 and "plan" in rcontent, rcontent)
check("U6 writers unaffected", step(led, "w1").get("status") == "done" and step(led, "w2").get("status") == "done")
check("U6 run not merged (a step failed)", (led.get("git") or {}).get("merged") is False)
delete(wf)
shutil.rmtree(repo, ignore_errors=True)

# ---------------- U7: delete mid-run ----------------
print("=== U7 delete mid-run ===")
repo = mkrepo()
_, base_head, _ = g(repo, "rev-parse", "HEAD")
wf = start({"name": "u7", "dir": repo, "steps": [
    shim_step("slow", [("s.txt", "slow\n")], sleep=20),
    shim_step("quick", [("q.txt", "quick\n")]),
]})
for _ in range(80):
    if step(status(wf), "slow").get("status") == "running":
        break
    time.sleep(0.25)
rd = os.path.join(WFROOT, wf)
pid = None
try:
    with open(os.path.join(rd, "pgid")) as f:
        pid = int(f.read().strip())
except OSError:
    pass
t0 = time.time()
delete(wf)
dead = None
if pid:
    try:
        os.killpg(pid, 0)
        dead = False
    except ProcessLookupError:
        dead = True
check("U7 runner group dead after delete", dead is True, "pid=%s" % pid)
check("U7 run dir removed", not os.path.isdir(rd))
check("U7 refs cleaned", pervio_refs(repo) == [], pervio_refs(repo))
check("U7 registrations cleaned", registered_wts(repo) == 1)
_, head_now, _ = g(repo, "rev-parse", "HEAD")
_, porc, _ = g(repo, "status", "--porcelain")
check("U7 user checkout untouched", head_now == base_head and porc == "", porc)
shutil.rmtree(repo, ignore_errors=True)

# ---------------- U8: crash (SIGKILL) then re-run then delete ----------------
print("=== U8 crash recovery ===")
repo = mkrepo()
wf = start({"name": "u8", "dir": repo, "steps": [
    shim_step("slow", [("s.txt", "slow\n")], sleep=20),
    shim_step("quick", [("q.txt", "quick\n")]),
]})
for _ in range(80):
    led = status(wf)
    if step(led, "slow").get("status") == "running":
        break
    time.sleep(0.25)
check("U8 ledger.git present while running (crash-visible)", bool(status(wf).get("git")), status(wf).get("git"))
try:
    with open(os.path.join(WFROOT, wf, "pgid")) as f:
        os.killpg(int(f.read().strip()), signal.SIGKILL)
except OSError:
    pass
time.sleep(0.5)
wf2 = start({"name": "u8b", "dir": repo, "steps": [
    shim_step("x", [("x.txt", "x\n")]),
    shim_step("y", [("y.txt", "y\n")]),
]})
led2 = wait(wf2)
check("U8 a new isolated run works after a crash", led2.get("status") == "done" and (led2.get("git") or {}).get("merged") is True,
      json.dumps({"status": led2.get("status"), "git": led2.get("git"), "errs": [s.get("error") for s in led2.get("steps", [])]}))
delete(wf2)
delete(wf)
check("U8 delete clears the crashed run's refs+registrations", pervio_refs(repo) == [] and registered_wts(repo) == 1,
      (pervio_refs(repo), registered_wts(repo)))
shutil.rmtree(repo, ignore_errors=True)

# ---------------- U9: merge-back guards ----------------
print("=== U9 merge-back guards ===")
repo = mkrepo()  # (a) branch moved during the run
wf = start({"name": "u9a", "dir": repo, "steps": [
    shim_step("a", [("a.txt", "1\n")], sleep=3),
    shim_step("b", [("b.txt", "2\n")]),
]})
time.sleep(1.0)
g(repo, "checkout", "-q", "-b", "elsewhere")
led = wait(wf)
gg = led.get("git") or {}
check("U9a moved checkout -> not merged", led.get("status") == "done" and gg.get("merged") is False, gg)
check("U9a note says results are on the branch", "pervio/wf-" in gg.get("note", ""), gg.get("note"))
rc, _, _ = g(repo, "rev-parse", "--verify", "refs/heads/" + gg.get("branch", "missing"))
check("U9a integration branch kept", rc == 0)
delete(wf)
shutil.rmtree(repo, ignore_errors=True)

repo = mkrepo()  # (c) unrelated dirty file must NOT block the ff (per-file rule)
with open(os.path.join(repo, "base.txt"), "a") as f:
    f.write("user edit in flight\n")
wf = start({"name": "u9c", "dir": repo, "steps": [
    shim_step("a", [("a.txt", "1\n")]),
    shim_step("b", [("b.txt", "2\n")]),
]})
led = wait(wf)
gg = led.get("git") or {}
_, basetxt, _ = g(repo, "show", ":0:base.txt")  # staged/index copy untouched;
with open(os.path.join(repo, "base.txt")) as f:
    live = f.read()
check("U9c unrelated dirty file: ff succeeded", gg.get("merged") is True, gg)
check("U9c user's in-flight edit preserved", "user edit in flight" in live)
check("U9c dirty note carried", "uncommitted" in (gg.get("note", "") + " ").lower() or gg.get("merged") is True)
delete(wf)
shutil.rmtree(repo, ignore_errors=True)

# ---------------- U10: setup + verify in the worktree ----------------
print("=== U10 setup/verify ===")
repo = mkrepo()
wf = start({"name": "u10", "dir": repo, "setup": "touch .provisioned", "steps": [
    shim_step("a", [("a.txt", "1\n")], verify="test -f .provisioned && test -f a.txt"),
    shim_step("b", [("b.txt", "2\n")]),
    shim_step("peek", [], perm="plan", text="peeked"),
]})
led = wait(wf)
check("U10 setup ran in the worktree (verify saw it)", led.get("status") == "done",
      json.dumps([s.get("error") for s in led.get("steps", [])]))
check("U10 setup droppings NOT committed", not os.path.exists(os.path.join(repo, ".provisioned")))
check("U10 setup dirt doesn't trip the reader rescue", step(led, "peek").get("status") == "done",
      step(led, "peek").get("error"))
delete(wf)
wf = start({"name": "u10b", "dir": repo, "setup": "exit 7", "steps": [
    shim_step("a", [("a.txt", "1\n")]),
    shim_step("b", [("b.txt", "2\n")]),
]})
led = wait(wf)
erra = step(led, "a").get("error", "")
check("U10b failing setup -> explains fresh checkout", "fresh worktree" in erra and "exit 7" in erra, erra)
delete(wf)
shutil.rmtree(repo, ignore_errors=True)

# ---------------- U11: zero-regression shared mode ----------------
print("=== U11 zero-regression ===")
repo = mkrepo()
wf = start({"name": "u11", "dir": repo, "steps": [
    shim_step("look", [], perm="plan", text="looked"),
    shim_step("edit", [("z.txt", "zzz\n")], deps=["look"]),
]})
led = wait(wf)
check("U11 run done", led.get("status") == "done")
check("U11 no git key in ledger", "git" not in led, list(led.keys()))
check("U11 no isolation keys on steps", all("isolation" not in s and "branch" not in s for s in led["steps"]))
check("U11 edit landed LIVE in the working tree", os.path.exists(os.path.join(repo, "z.txt")))
_, porc, _ = g(repo, "status", "--porcelain")
check("U11 change is uncommitted (legacy behavior)", "?? z.txt" in porc, porc)
check("U11 zero pervio refs", pervio_refs(repo) == [])
check("U11 zero extra registrations", registered_wts(repo) == 1)
delete(wf)
shutil.rmtree(repo, ignore_errors=True)

# ---------------- U12: exactly ONE completion push per workflow run ----------
# The workflow-level ping used to fire on FAILURE ONLY, on the theory that a
# successful workflow was covered by "the app's own completion banner". Both
# halves of that were wrong: the app can only banner while iOS has not suspended
# it, and when it did banner the user got TWO notifications for one workflow
# (the app's "Task finished" beside this script's push). The app now defers to
# this push, so a silent success here is a silent success everywhere.
#
# pervio-orchestrate calls its SIBLING pervio-push, so the only faithful way to
# watch is to run a COPY out of a temp bin dir whose pervio-push records argv.
print("--- U12: workflow completion push ---")
PBIN = os.path.join(HOME, "pushbin")
os.makedirs(PBIN, exist_ok=True)
for _f in ("pervio-orchestrate", "_pervio_lib.py", "pervio-chat", "pervio-approve",
           "pervio-hb"):
    _src = os.path.realpath(os.path.join(HERE, "..", "bin", _f))
    if os.path.exists(_src):
        shutil.copy2(_src, os.path.join(PBIN, _f))
        os.chmod(os.path.join(PBIN, _f), 0o755)
PUSH_LOG = os.path.join(HOME, "wf_push.log")
with open(os.path.join(PBIN, "pervio-push"), "w") as _f:
    _f.write("#!/usr/bin/env python3\n"
             "import json, os, sys\n"
             "p = os.environ.get('PUSH_LOG')\n"
             "if p:\n"
             "    with open(p, 'a') as fh: fh.write(json.dumps(sys.argv[1:]) + '\\n')\n"
             "sys.exit(0)\n")
os.chmod(os.path.join(PBIN, "pervio-push"), 0o755)
PORCH = os.path.join(PBIN, "pervio-orchestrate")
PENV = dict(ENV, PUSH_LOG=PUSH_LOG)


def push_run(spec, timeout=90):
    """Run `spec` through the intercepted copy and return its recorded pushes."""
    open(PUSH_LOG, "w").close()
    b64 = base64.b64encode(json.dumps(spec).encode()).decode()
    p = subprocess.run([sys.executable, PORCH, "start", "--spec-b64", b64],
                       env=PENV, capture_output=True, text=True)
    w = json.loads(p.stdout)["wfId"]
    for _ in range(timeout * 4):
        s = subprocess.run([sys.executable, PORCH, "status", "--wf", w],
                           env=PENV, capture_output=True, text=True)
        led = json.loads(s.stdout) if s.returncode == 0 else {}
        if led.get("status") in ("done", "failed"):
            break
        time.sleep(0.25)
    for _ in range(60):                  # _push_notify is detached — let it land
        if os.path.getsize(PUSH_LOG) > 0:
            break
        time.sleep(0.1)
    time.sleep(0.4)
    with open(PUSH_LOG) as fh:
        return led, [json.loads(l) for l in fh if l.strip()]


def _flag(argv, name):
    return argv[argv.index(name) + 1] if name in argv else ""


led12, pushes12 = push_run({"name": "每日体检", "dir": HOME,
                            "steps": [shim_step("a"), shim_step("b", deps=["a"])]})
check("U12 a SUCCESSFUL workflow pushes (it used to say nothing at all)",
      led12.get("status") == "done" and len(pushes12) == 1, (led12.get("status"), pushes12))
if pushes12:
    check("U12 the push names the workflow, so the phone knows WHICH job spoke",
          _flag(pushes12[0], "--title") == "每日体检", pushes12[0])
    check("U12 ...and its body says what happened, not a generic 「回答好了」",
          _flag(pushes12[0], "--body") == "2 步全部完成", pushes12[0])

led13, pushes13 = push_run({"name": "每日体检", "dir": HOME,
                            "steps": [shim_step("boom", rc=7)]})
check("U13 a FAILED workflow still pushes exactly once, naming the step",
      led13.get("status") == "failed" and len(pushes13) == 1
      and _flag(pushes13[0], "--body").startswith("失败:boom"),
      (led13.get("status"), pushes13))

# ---------------- U14: push copy follows the phone's synced language ----------
# The app writes ~/.pervio/push/lang beside its push token; every server-authored
# push body branches on it (default zh — the file absent is exactly today's
# behavior, which U12/U13 above keep pinned). The copy lives in pure functions,
# same policy as pervio-run's _push_text: a string you can assert without running
# a workflow. Then ONE end-to-end run proves the file is actually consulted at
# push time, not just importable.
print("--- U14: push copy in the phone's language ---")
check("U14 published body, both languages",
      orch._push_copy_published("2026-08-17", "zh") == "2026-08-17 已送达"
      and orch._push_copy_published("2026-08-17", "en") == "2026-08-17 delivered",
      (orch._push_copy_published("2026-08-17", "zh"),
       orch._push_copy_published("2026-08-17", "en")))
check("U14 failed body names the first step, both languages",
      orch._push_copy_failed({"read"}, "zh") == "失败:read"
      and orch._push_copy_failed({"read"}, "en") == "Failed: read",
      (orch._push_copy_failed({"read"}, "zh"), orch._push_copy_failed({"read"}, "en")))
check("U14 failed body counts the steps when several failed",
      orch._push_copy_failed({"read", "verify"}, "zh") == "失败:read 等 2 步"
      and orch._push_copy_failed({"read", "verify"}, "en") == "Failed: read (2 steps)",
      (orch._push_copy_failed({"read", "verify"}, "zh"),
       orch._push_copy_failed({"read", "verify"}, "en")))
check("U14 done body, both languages",
      orch._push_copy_done(7, "zh") == "7 步全部完成"
      and orch._push_copy_done(7, "en") == "All 7 steps finished",
      (orch._push_copy_done(7, "zh"), orch._push_copy_done(7, "en")))

# End to end: with the file saying en under this suite's throwaway HOME, the
# same successful workflow that pushed 「2 步全部完成」 in U12 now pushes English.
_lang_dir = os.path.join(HOME, ".pervio", "push")
os.makedirs(_lang_dir, exist_ok=True)
with open(os.path.join(_lang_dir, "lang"), "w") as _f:
    _f.write("en")
led14, pushes14 = push_run({"name": "每日体检", "dir": HOME,
                            "steps": [shim_step("a"), shim_step("b", deps=["a"])]})
check("U14 the finished-workflow push reads the file at push time",
      led14.get("status") == "done" and len(pushes14) == 1
      and _flag(pushes14[0], "--body") == "All 2 steps finished", pushes14)
os.remove(os.path.join(_lang_dir, "lang"))   # later sections expect the zh default

# ---------------- U15: one clock names the issue ------------------------------
# The issue TITLES itself with the fetch's UTC-cycle date (REPORT_DATE); the
# archive filename and the「已送达」push must repeat THAT date, not read the wall
# clock again — two clocks is how 08-13's papers got published as 2026-08-14.md
# by a run that straddled local midnight. A report without a dated first line
# (not every publisher is the digest) keeps the old local-date name.
print("--- U15: publish filename and push follow the issue's own date ---")
_pub15 = os.path.join(HOME, "pub15")
_s15 = shim_step("issue", text="# 论文晨报 2026-01-05\n\n正文……")
_s15["publish"] = _pub15
led15, pushes15 = push_run({"name": "论文晨报", "dir": HOME, "steps": [_s15]})
check("U15 the file is named by the issue's title date, not today",
      led15.get("status") == "done"
      and os.path.exists(os.path.join(_pub15, "2026-01-05.md"))
      and not os.path.exists(os.path.join(_pub15, time.strftime("%Y-%m-%d") + ".md")),
      os.listdir(_pub15) if os.path.isdir(_pub15) else "no dir")
check("U15 the push names that same issue",
      len(pushes15) == 1 and _flag(pushes15[0], "--body") == "2026-01-05 已送达",
      pushes15)
_pub15b = os.path.join(HOME, "pub15b")
_s15b = shim_step("issue", text="# 一份不带日期的报告\n\n正文……")
_s15b["publish"] = _pub15b
led15b, _ = push_run({"name": "无日期报告", "dir": HOME, "steps": [_s15b]})
check("U15 a report with no dated title keeps the local-date filename",
      led15b.get("status") == "done"
      and os.path.exists(os.path.join(_pub15b, time.strftime("%Y-%m-%d") + ".md")),
      os.listdir(_pub15b) if os.path.isdir(_pub15b) else "no dir")

# ---------------- U0b: the throwaway home is where the state actually went ----
# Sampled per run, at `start`, because nothing survives to be sampled here: every
# section above deletes its workflow, so a scan at exit finds an empty WFROOT
# whether the suite was hermetic or not. The second half used to assert that the
# `shutil.rmtree` on its own previous line had worked — a fact about shutil that
# is true no matter where the product wrote, so it could not go red for the
# failure it was named after (2026-08-07: live run dirs in the USER's ~/.pervio/wf).
# These two read the runs themselves: each one existed under the throwaway home
# while it ran, and no run id of ours was ever a directory under the real home.
missing = [w for w, here, _ in RUNS if not here]
leaked = [w for w, _, there in RUNS if there]
check("U0b all %d runs materialised under the throwaway home, which is outside the user's"
      % len(RUNS),
      bool(RUNS) and not missing
      and not os.path.realpath(WFROOT).startswith(REAL_HOME + os.sep),
      (missing, WFROOT, REAL_HOME))
check("U0b ...and not one of them ever appeared under the real home's .pervio/wf",
      not leaked, (leaked, REAL_WF))
check("U-dev every start recorded the phone that started it (device + origin) in its ledger",
      bool(OWNERS) and all(o == ("phone-unit", "entry-unit") for o in OWNERS), OWNERS[:3])
shutil.rmtree(HOME, ignore_errors=True)

# ---------------- U12: one workflow at a time lands on a repository ----------------
print("=== U12 the landing lock ===")
import threading
lrepo = tempfile.mkdtemp(prefix="u12_", dir="/tmp")
subprocess.run(["git", "init", "-q", lrepo], check=True)
subprocess.run(["git", "-C", lrepo, "-c", "user.name=t", "-c", "user.email=t@example.com",
                "commit", "-q", "--allow-empty", "-m", "base"], check=True)
with orch._LandingLock(lrepo) as first:
    check("U12a a workflow takes the repository's landing lock", first.held and first.f is not None)
    t0 = time.time()
    with orch._LandingLock(lrepo, wait=0.4) as second:
        waited = time.time() - t0
        check("U12b a second one, while it is held, waits its time and is told no",
              not second.held and 0.3 <= waited < 3, (second.held, waited))
    got = {}

    def later():
        with orch._LandingLock(lrepo, wait=10) as third:
            got["held"] = third.held
            got["at"] = time.time()

    th = threading.Thread(target=later); th.start()
    time.sleep(0.5)
    released = time.time()
th.join(15)
check("U12c and gets it the moment the first lets go — not before",
      got.get("held") is True and got.get("at", 0) >= released, got)
st = subprocess.run(["git", "-C", lrepo, "status", "--porcelain"], capture_output=True, text=True).stdout
check("U12d the lock costs the working tree nothing (git status stays empty)", st == "", st)
fs = subprocess.run(["git", "-C", lrepo, "fsck", "--no-dangling"], capture_output=True, text=True)
check("U12e and the repository still checks out clean", fs.returncode == 0, fs.stderr[:200])
notrepo = tempfile.mkdtemp(prefix="u12n_", dir="/tmp")
with orch._LandingLock(notrepo) as none:
    check("U12f where there is no repository to lock, the old behaviour stands (held, no file)",
          none.held and none.f is None)
shutil.rmtree(lrepo, ignore_errors=True); shutil.rmtree(notrepo, ignore_errors=True)

# ---------------- U16: the Claude menu from the CLI's own model table ----------------
print("=== U16 the Claude menu from the CLI's own table ===")
lib = sys.modules["_pervio_lib"]
_u16home = tempfile.mkdtemp(prefix="u14_", dir="/tmp")     # the suite's HOME is gone by now
_home_before = os.environ.get("HOME")
os.environ["HOME"] = _u16home
# A stand-in for the Claude Code program: junk around the table rows the real
# binary carries (2.1.322), fable 5.2 twice as the real one has it, mythos too.
_rows = [("claude-3-5-haiku", "haiku", "Haiku 3.5"), ("claude-haiku-4-5", "haiku", "Haiku 4.5"),
         ("claude-sonnet-5", "sonnet", "Sonnet 5"), ("claude-sonnet-5-5", "sonnet", "Sonnet 5.5"),
         ("claude-opus-4-7", "opus", "Opus 4.7"), ("claude-opus-4-8", "opus", "Opus 4.8"),
         ("claude-opus-5", "opus", "Opus 5"), ("claude-opus-5-5", "opus", "Opus 5.5"),
         ("claude-fable-5", "fable", "Fable 5"), ("claude-fable-5-1", "fable", "Fable 5.1"),
         ("claude-fable-5-2", "fable", "Fable 5.2"), ("claude-mythos-5-2", "mythos", "Mythos 5.2")]
def _fake_claude(rows, pad=b"\x00\x01junk{id:\"not-a-model\"}"):
    body = b""
    for mid, fam, name in rows:
        body += pad + b'{id:"%s",family:"%s",display_name:"%s",knowledge_cutoff:"June 2026",pricing:"x"},' % (
            mid.encode(), fam.encode(), name.encode())
    return body + pad + b'{id:"claude-fable-5-2",family:"fable",display_name:"Fable 5.2"}' + pad
_bin = os.path.join(_u16home, "claude-fake-bin")
with open(_bin, "wb") as f:
    f.write(_fake_claude(_rows))
t14 = lib.claude_cli_table(_bin)
check("U16a every row of the table is read once, in the program's order",
      [r["id"] for r in t14] == [r[0] for r in _rows] and t14[-2]["name"] == "Fable 5.2", [r["id"] for r in t14])
menu14 = lib.claude_menu_from_table(t14)
ids14 = [r["id"] for r in menu14]
check("U16b each family newest first, its newest few only, mythos left out, then the aliases",
      ids14 == ["claude-opus-5-5", "claude-opus-5", "claude-opus-4-8",
                "claude-fable-5-2", "claude-fable-5-1", "claude-fable-5",
                "claude-sonnet-5-5", "claude-sonnet-5",
                "claude-haiku-4-5", "claude-3-5-haiku",
                "opus", "fable", "sonnet", "haiku"], ids14)
notes14 = {r["id"]: r["note"] for r in menu14}
check("U16c the rows say what they are: display name, newest, recommended, what an alias means today",
      notes14["claude-fable-5-2"] == "Fable 5.2 · newest fable" and notes14["claude-fable-5-1"] == "Fable 5.1"
      and notes14["claude-opus-5"] == "Opus 5 · recommended"
      and notes14["fable"] == "alias: always the newest fable (Fable 5.2 today)", notes14)
check("U16d versions compare as numbers, a date suffix is not a version",
      lib._claude_version("claude-fable-5-2") == (5, 2) and lib._claude_version("claude-3-5-haiku") == (3, 5)
      and lib._claude_version("claude-opus-5") == (5, 0) and lib._claude_version("claude-haiku-4-5-20251001") == (4, 5)
      and lib._claude_version("claude-opus-4-1[1m]") == (4, 1))
# The cache: the same program (path, size, mtime) is not read again — new bytes
# of the same size and age come back as the OLD rows; a touched program is re-read.
_st = os.stat(_bin)
_rows2 = [r for r in _rows if r[0] != "claude-fable-5-2"] + [("claude-fable-5-3", "fable", "Fable 5.3")]
with open(_bin, "wb") as f:
    f.write(_fake_claude(_rows2))
os.utime(_bin, (_st.st_atime, _st.st_mtime))
check("U16e the same program by path, size and mtime is answered from the cache",
      [r["id"] for r in lib.claude_cli_table(_bin)] == [r[0] for r in _rows]
      and os.path.isfile(os.path.join(_u16home, ".pervio", "cache", "claude-cli-models.json")))
os.utime(_bin, (_st.st_atime, _st.st_mtime + 100))
check("U16f a program with a new mtime is read again",
      "claude-fable-5-3" in [r["id"] for r in lib.claude_cli_table(_bin)])
_empty = os.path.join(_u16home, "claude-empty"); open(_empty, "wb").close()
check("U16g no table (an empty program, a missing one) is an empty answer, no error",
      lib.claude_cli_table(_empty) == [] and lib.claude_cli_table(os.path.join(_u16home, "nope")) == []
      and lib.claude_menu_from_table([]) == [])
_orig_find = lib._find_claude
try:
    lib._find_claude = lambda: ""
    floor = [r["id"] for r in lib.claude_models()]
    check("U16h with no claude installed, the table is empty and the shipped menu stands",
          lib.claude_cli_table() == [] and floor[:5] == [m["id"] for m in lib.CHAT_MODELS["claude"]], floor)
    with open(_bin, "wb") as f:                       # the original table again (U15f left 5.3 in it)
        f.write(_fake_claude(_rows))
    os.utime(_bin, (_st.st_atime, _st.st_mtime + 200))
    lib._find_claude = lambda: _bin
    live = [r["id"] for r in lib.claude_models()]
    check("U16i with one, the menu is the program's table and the phone's paper carries it",
          live[:14] == ids14 and [r["id"] for r in lib.models_menu()["chat"]["claude"]][:3] == ids14[:3], live)
finally:
    lib._find_claude = _orig_find
    if _home_before is not None:
        os.environ["HOME"] = _home_before
    shutil.rmtree(_u16home, ignore_errors=True)

# ---------------- summary ----------------
ok = all(results)
print("\n=== P3 U-SUITE: %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
