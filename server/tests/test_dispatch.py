#!/usr/bin/env python3
"""Regression tests for server/bin/pervio-dispatch (P4: agent-calls-agent + the five
guardrails). Hermetic: isolated $HOME, scratch git repo, committed shim `claude`
(driven by SHIM:{json} incl. a `cost` field) on PATH — zero model calls. Covers
depth/concurrency/budget/width caps, the crash-safe slot, the tier clamp + bypass
ceiling, codex-no-cost refusal, child tool-scoping (no Task), heartbeat cleanliness,
worktree cleanup, and zero-regression."""
import base64
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
os.environ.setdefault("PERVIO_RUN_IDLE_GRACE", "1.5")   # a living run ends a beat after its reply here, not 180 s

HERE = os.path.dirname(os.path.realpath(__file__))
BIN = os.path.realpath(os.path.join(HERE, "..", "bin"))
DISPATCH = os.path.join(BIN, "pervio-dispatch")
ORCH = os.path.join(BIN, "pervio-orchestrate")
SHIM = os.path.join(HERE, "shim")

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + (("  [" + str(detail)[:200] + "]") if (detail and not cond) else ""))


def mkrepo():
    d = tempfile.mkdtemp(prefix="p4repo_", dir="/tmp")
    for a in (["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]):
        subprocess.run(["git", "-C", d] + a, capture_output=True)
    open(os.path.join(d, "base.txt"), "w").write("base\n")
    subprocess.run(["git", "-C", d, "add", "-A"], capture_output=True)
    subprocess.run(["git", "-C", d, "commit", "-qm", "base"], capture_output=True)
    return d


def g(cwd, *a):
    p = subprocess.run(["git", "-C", cwd] + list(a), capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def prompt_b64(cost=None, sleep=0, text="child done", rc=0, is_error=False):
    ins = {"text": text, "sleep": sleep, "rc": rc, "is_error": is_error}
    if cost is not None:
        ins["cost"] = cost
    return base64.b64encode(("subtask\nSHIM:" + json.dumps(ins)).encode()).decode()


def base_env(home, repo, **over):
    e = dict(os.environ, HOME=home, PATH=SHIM + ":" + os.environ.get("PATH", ""),
             PERVIO_WF_ID="wftest", PERVIO_REPO_TOP=repo, PERVIO_STEP_ID="parent",
             PERVIO_PARENT_BACKEND="claude", PERVIO_PARENT_TIER="acceptEdits")
    for k, v in over.items():
        e[k] = str(v)
    return e


def dispatch(env, *args, timeout=30):
    p = subprocess.run([sys.executable, DISPATCH] + list(args),
                       env=env, capture_output=True, text=True, timeout=timeout)
    try:
        return json.loads(p.stdout.strip().splitlines()[-1]), p
    except (json.JSONDecodeError, IndexError):
        return {}, p


# ---------- T0: happy path ----------
print("=== T0 happy path (depth 0) ===")
home = tempfile.mkdtemp(prefix="p4home_", dir="/tmp"); repo = mkrepo()
r, p = dispatch(base_env(home, repo), "--backend", "claude", "--prompt-b64", prompt_b64(cost=0.02, text="hello from child"))
check("T0 ok", r.get("ok") is True, (r, p.stderr[-200:]))
check("T0 returns child text", r.get("text") == "hello from child", r)
check("T0 returns cost", abs(r.get("costUSD", 0) - 0.02) < 1e-9, r)
check("T0 returns depth 1", r.get("depth") == 1, r)
_, refs, _ = g(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/pervio/wf-wftest/dispatch/")
check("T0 child branch kept for audit", any("dispatch/parent/" in x for x in refs.splitlines()), refs)
check("T0 child worktree removed", g(repo, "worktree", "list", "--porcelain")[1].count("worktree ") == 1)
check("T0 ledger recorded a done entry", os.path.exists(os.path.join(home, ".pervio/wf/wftest/dispatch/ledger.ndjson")))
shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- T1: depth cap ----------
print("=== T1 depth cap ===")
home = tempfile.mkdtemp(prefix="p4home_", dir="/tmp"); repo = mkrepo()
r, _ = dispatch(base_env(home, repo, PERVIO_DISPATCH_DEPTH=1, PERVIO_MAX_DEPTH=2),
                "--backend", "claude", "--prompt-b64", prompt_b64(cost=0.01))
check("T1 depth 1 < max 2 → ok, runs at depth 2", r.get("ok") is True and r.get("depth") == 2, r)
r, _ = dispatch(base_env(home, repo, PERVIO_DISPATCH_DEPTH=2, PERVIO_MAX_DEPTH=2),
                "--backend", "claude", "--prompt-b64", prompt_b64(cost=0.01))
check("T1 depth 2 == max → depth_cap", r.get("error") == "depth_cap", r)
_, refs, _ = g(repo, "for-each-ref", "refs/heads/pervio/wf-wftest/dispatch/")
n_after_cap = len([x for x in refs.splitlines() if x.strip()])
check("T1 capped call created NO worktree/branch", n_after_cap == 1, refs)   # only the depth-1 one
shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- T2: concurrency cap, fail-fast ----------
print("=== T2 concurrency cap (fail-fast) ===")
home = tempfile.mkdtemp(prefix="p4home_", dir="/tmp"); repo = mkrepo()
outs = [None, None, None]
def worker(i):
    outs[i] = dispatch(base_env(home, repo, PERVIO_MAX_CONCURRENCY=2),
                       "--backend", "claude", "--prompt-b64", prompt_b64(cost=0.01, sleep=2))[0]
ts = [threading.Thread(target=worker, args=(i,)) for i in range(3)]
t0 = time.time()
for t in ts: t.start()
for t in ts: t.join()
oks = [o.get("ok") for o in outs]
caps = [o.get("error") for o in outs]
check("T2 exactly 2 succeed, 1 concurrency_cap", oks.count(True) == 2 and caps.count("concurrency_cap") == 1, outs)
check("T2 the capped caller failed FAST (didn't block ~2s)", time.time() - t0 < 3.5, "%.2fs" % (time.time() - t0))
# slot freed after → a later call succeeds
r, _ = dispatch(base_env(home, repo, PERVIO_MAX_CONCURRENCY=2), "--backend", "claude", "--prompt-b64", prompt_b64(cost=0.01))
check("T2 slot released after → later call ok", r.get("ok") is True, r)
shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- T3: crash-safe slot release ----------
print("=== T3 crash-safe slot (SIGKILL a holder, slot must free) ===")
home = tempfile.mkdtemp(prefix="p4home_", dir="/tmp"); repo = mkrepo()
env1 = base_env(home, repo, PERVIO_MAX_CONCURRENCY=1)
holder = subprocess.Popen([sys.executable, DISPATCH, "--backend", "claude", "--prompt-b64", prompt_b64(cost=0.01, sleep=6)],
                          env=env1, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
time.sleep(1.5)  # let it acquire the only slot
os.killpg(holder.pid, signal.SIGKILL)   # hard kill — no Python finally runs
time.sleep(0.5)
r, _ = dispatch(env1, "--backend", "claude", "--prompt-b64", prompt_b64(cost=0.01))
check("T3 second caller acquires the slot after a SIGKILL'd holder (kernel released the flock)", r.get("ok") is True, r)
try: os.killpg(holder.pid, signal.SIGKILL)
except OSError: pass
shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- T4: budget stop, no TOCTOU overspend ----------
print("=== T4 budget cap (atomic, concurrent) ===")
home = tempfile.mkdtemp(prefix="p4home_", dir="/tmp"); repo = mkrepo()
outs = [None, None, None]
def bworker(i):
    # estimate (0.03) bounds actual (0.03): the reservation model then guarantees
    # cumulative actual never exceeds the budget.
    outs[i] = dispatch(base_env(home, repo, PERVIO_BUDGET="0.05", PERVIO_MAX_CONCURRENCY=4,
                                PERVIO_DISPATCH_ESTIMATE="0.03"),
                       "--backend", "claude", "--prompt-b64", prompt_b64(cost=0.03, sleep=0.2))[0]
ts = [threading.Thread(target=bworker, args=(i,)) for i in range(3)]
for t in ts: t.start()
for t in ts: t.join()
n_ok = sum(1 for o in outs if o.get("ok"))
n_budget = sum(1 for o in outs if o.get("error") == "budget_cap")
check("T4 budget stops overspend (some allowed, some budget_cap)", n_ok in (1, 2) and n_budget >= 1, outs)
led = os.path.join(home, ".pervio/wf/wftest/dispatch/ledger.ndjson")
done = [json.loads(l) for l in open(led) if l.strip() and json.loads(l).get("type") == "done"]
spent = sum(e.get("costUSD", 0) for e in done)
check("T4 actual spend never exceeds the budget", spent <= 0.05 + 1e-9, "spent=%.4f" % spent)
shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- T5: width cap (sequential fan-out) ----------
print("=== T5 width cap ===")
home = tempfile.mkdtemp(prefix="p4home_", dir="/tmp"); repo = mkrepo()
env = base_env(home, repo, PERVIO_MAX_DISPATCHES=3, PERVIO_MAX_CONCURRENCY=8)
seq = [dispatch(env, "--backend", "claude", "--prompt-b64", prompt_b64(cost=0.0))[0] for _ in range(5)]
oks = [o.get("ok") for o in seq]
check("T5 first 3 ok, last 2 width_cap", oks == [True, True, True, False, False]
      and seq[3].get("error") == "width_cap", [o.get("ok") or o.get("error") for o in seq])
shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- T6: codex + budget → refuse (no cost field) ----------
print("=== T6 codex no-cost-field refusal ===")
home = tempfile.mkdtemp(prefix="p4home_", dir="/tmp"); repo = mkrepo()
r, _ = dispatch(base_env(home, repo, PERVIO_BUDGET="1.0"), "--backend", "codex", "--prompt-b64", prompt_b64())
check("T6 codex under a budget → codex_no_cost_field", r.get("error") == "codex_no_cost_field", r)
check("T6 no ledger entry / no worktree consumed", not os.path.exists(os.path.join(home, ".pervio/wf/wftest/dispatch/ledger.ndjson"))
      and g(repo, "worktree", "list", "--porcelain")[1].count("worktree ") == 1, r)
shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- T7 + T8: tier clamp and bypass ceiling ----------
print("=== T7/T8 tier clamp + bypass ceiling ===")
home = tempfile.mkdtemp(prefix="p4home_", dir="/tmp"); repo = mkrepo()
argvlog = os.path.join(home, "argv.log")
e = base_env(home, repo, PERVIO_PARENT_TIER="plan", SHIM_ARGV_LOG=argvlog)
r, _ = dispatch(e, "--backend", "claude", "--perm", "acceptEdits", "--prompt-b64", prompt_b64(cost=0.0))
child_argv = " ".join(sum((json.loads(l) for l in open(argvlog)), [])) if os.path.exists(argvlog) else ""
check("T7 plan parent clamps an acceptEdits request down to plan", "--permission-mode plan" in child_argv, child_argv[:200])
check("T7 child did NOT get acceptEdits", "acceptEdits" not in child_argv, child_argv[:200])
check("T9 child tools exclude Task (no agent-spawn escape)", "--allowedTools" in child_argv and "Task" not in child_argv, child_argv[:200])
# bypass request → hard refuse
r, _ = dispatch(base_env(home, repo, PERVIO_PARENT_TIER="bypassPermissions"),
                "--backend", "claude", "--perm", "bypassPermissions", "--prompt-b64", prompt_b64())
check("T8 bypassPermissions request → tier_refused (hard ceiling)", r.get("error") == "tier_refused", r)
shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- T9-doc: no false "cannot spawn any other way" claim ----------
print("=== T9 source honesty (allowlist is NOT a boundary) ===")
src = " ".join(open(DISPATCH).read().split())        # normalize wrapped lines
check("T9 source states the allowlist is NOT a security boundary", "not a boundary" in src.lower())
check("T9 no false 'literally cannot spawn' claim", "literally cannot" not in src.lower())

# ---------- T10: heartbeat cleanliness ----------
print("=== T10 no heartbeat contamination in the returned JSON ===")
home = tempfile.mkdtemp(prefix="p4home_", dir="/tmp"); repo = mkrepo()
p = subprocess.run([sys.executable, DISPATCH, "--backend", "claude", "--prompt-b64", prompt_b64(cost=0.01)],
                   env=base_env(home, repo), capture_output=True, text=True, timeout=30)
lines = [l for l in p.stdout.splitlines() if l.strip()]
check("T10 stdout is exactly one JSON line", len(lines) == 1, lines)
check("T10 no heartbeat line leaked", not any("heartbeat" in l for l in lines))
shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- T11: worktree cleanup after a crashed dispatch ----------
print("=== T11 worktree cleanup on crash ===")
home = tempfile.mkdtemp(prefix="p4home_", dir="/tmp"); repo = mkrepo()
env1 = base_env(home, repo)
holder = subprocess.Popen([sys.executable, DISPATCH, "--backend", "claude", "--prompt-b64", prompt_b64(cost=0.01, sleep=6)],
                          env=env1, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
time.sleep(2.0)  # let it create the worktree + start the child
os.killpg(holder.pid, signal.SIGKILL)
time.sleep(0.5)
n_wt = g(repo, "worktree", "list", "--porcelain")[1].count("worktree ")
check("T11 crash leaves an orphan worktree registered", n_wt >= 2, n_wt)
# simulate cmd_delete's cleanup: rmtree the run dir, prune, delete the branches
shutil.rmtree(os.path.join(home, ".pervio", "wf", "wftest"), ignore_errors=True)
g(repo, "worktree", "prune")
_, refs, _ = g(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/pervio/wf-wftest/")
for br in refs.splitlines():
    if br.strip():
        g(repo, "branch", "-D", br.strip())
check("T11 cleanup clears worktree registration", g(repo, "worktree", "list", "--porcelain")[1].count("worktree ") == 1)
check("T11 cleanup clears the dispatch branch", g(repo, "for-each-ref", "refs/heads/pervio/")[1] == "")
try: os.killpg(holder.pid, signal.SIGKILL)
except OSError: pass
shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------- T12: zero regression (a run with no allowDispatch) ----------
print("=== T12 zero regression ===")
home = tempfile.mkdtemp(prefix="p4home_", dir="/tmp"); repo = mkrepo()
spec = {"name": "noreg", "dir": repo, "steps": [
    {"id": "a", "backend": "claude", "perm": "plan", "prompt": "look\nSHIM:{\"text\":\"looked\"}"},
]}
e = dict(os.environ, HOME=home, PATH=SHIM + ":" + os.environ.get("PATH", ""))
b64 = base64.b64encode(json.dumps(spec).encode()).decode()
wf = json.loads(subprocess.run([sys.executable, ORCH, "start", "--spec-b64", b64], env=e, capture_output=True, text=True).stdout)["wfId"]
led = {}
for _ in range(120):
    led = json.loads(subprocess.run([sys.executable, ORCH, "status", "--wf", wf], env=e, capture_output=True, text=True).stdout)
    if led.get("status") in ("done", "failed"): break
    time.sleep(0.25)
check("T12 non-dispatch run completes normally", led.get("status") == "done", led)
check("T12 no dispatch/ dir created", not os.path.isdir(os.path.join(home, ".pervio/wf", wf, "dispatch")))
# direct dispatch call with no auth env → not_authorized
r = json.loads(subprocess.run([sys.executable, DISPATCH, "--backend", "claude", "--prompt-b64", prompt_b64()],
                              env=dict(os.environ, HOME=home), capture_output=True, text=True).stdout)
check("T12 unauthorized direct dispatch refused", r.get("error") == "not_authorized", r)
shutil.rmtree(home, ignore_errors=True); shutil.rmtree(repo, ignore_errors=True)

# ---------------- run_child unit: plan 禁 ExitPlanMode + 空产出重试一次 --------
# 2026-08-20 的尸检:plan 权限的无头子代理调 ExitPlanMode「求批准」,无人应答,
# 回合以空白最终消息死掉。两道修法都在 run_child 里,在这里用伪 chat_bin 直测:
# ① claude+plan 的子命令行必须带 --disallow ExitPlanMode(acceptEdits/codex 不带);
# ② OK-但-空的产出恰好重试一次(第一份流存档 out.jsonl.empty1),报错不重试。
print("=== run_child: plan strips ExitPlanMode; empty output retries once ===")
import importlib.machinery                                            # noqa: E402
import importlib.util                                                 # noqa: E402
_l = importlib.machinery.SourceFileLoader("plib", os.path.join(HERE, "..", "bin", "_pervio_lib.py"))
plib = importlib.util.module_from_spec(importlib.util.spec_from_loader("plib", _l))
_l.exec_module(plib)

rcroot = tempfile.mkdtemp(prefix="runchild_", dir="/tmp")
FAKE = os.path.join(rcroot, "fake-chat")
ARGLOG = os.path.join(rcroot, "args.log")
CTR = os.path.join(rcroot, "count")
with open(FAKE, "w") as f:
    f.write("#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "open(os.environ['RC_ARGLOG'], 'a').write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "mode = os.environ.get('RC_MODE', 'ok')\n"
            "ctr = os.environ['RC_CTR']\n"
            "n = int(open(ctr).read()) if os.path.exists(ctr) else 0\n"
            "open(ctr, 'w').write(str(n + 1))\n"
            "if mode == 'empty_once' and n == 0:\n"
            "    print(json.dumps({'type': 'result', 'result': '', 'total_cost_usd': 0.1}))\n"
            "elif mode == 'empty_always':\n"
            "    print(json.dumps({'type': 'result', 'result': '', 'total_cost_usd': 0.1}))\n"
            "elif mode == 'error':\n"
            "    print(json.dumps({'type': 'result', 'result': '', 'is_error': True, 'total_cost_usd': 0.1}))\n"
            "else:\n"
            "    print(json.dumps({'type': 'result', 'result': '文本来了', 'total_cost_usd': 0.1}))\n")
os.chmod(FAKE, 0o755)


def _run_child(mode, tier="plan", backend="claude"):
    for f in (ARGLOG, CTR):
        if os.path.exists(f):
            os.remove(f)
    cdir = tempfile.mkdtemp(prefix="rc_child_", dir=rcroot)
    ok_, text_, cost_, err_ = plib.run_child(
        base64.b64encode(b"do it").decode(), backend, tier, None, cdir,
        "b", 0, 60, FAKE, extra_env={"RC_ARGLOG": ARGLOG, "RC_CTR": CTR,
                                     "RC_MODE": mode})
    argvs = [json.loads(l) for l in open(ARGLOG)] if os.path.exists(ARGLOG) else []
    calls = int(open(CTR).read()) if os.path.exists(CTR) else 0
    return ok_, text_, cost_, err_, argvs, calls, cdir


ok1, _, _, _, argvs, _, _ = _run_child("ok", tier="plan")
check("run_child: plan child's argv strips ExitPlanMode",
      ok1 and argvs and "--disallow" in argvs[0]
      and argvs[0][argvs[0].index("--disallow") + 1] == "ExitPlanMode", argvs[:1])
_, _, _, _, argvs2, _, _ = _run_child("ok", tier="acceptEdits")
_, _, _, _, argvs3, _, _ = _run_child("ok", tier="read-only", backend="codex")
check("run_child: acceptEdits and codex children keep their full toolbox",
      argvs2 and "--disallow" not in argvs2[0]
      and argvs3 and "--disallow" not in argvs3[0], (argvs2[:1], argvs3[:1]))

okr, textr, costr, _, _, callsr, cdirr = _run_child("empty_once")
check("run_child: OK-but-empty retries exactly once and wins",
      okr and textr == "文本来了" and callsr == 2
      and os.path.exists(os.path.join(cdirr, "out.jsonl.empty1"))
      and abs(costr - 0.2) < 1e-9,
      "ok=%s text=%r calls=%s cost=%s" % (okr, textr, callsr, costr))
oke, texte, _, _, _, callse, _ = _run_child("empty_always")
check("run_child: empty twice stays empty — two attempts, never a loop",
      oke and texte == "" and callse == 2, "calls=%s" % callse)
okx, _, _, errx, _, callsx, _ = _run_child("error")
check("run_child: a real error does NOT retry (it means something)",
      not okx and errx == "child_error" and callsx == 1, "calls=%s err=%s" % (callsx, errx))
shutil.rmtree(rcroot, ignore_errors=True)

ok = all(results)
print("\n=== pervio-dispatch (P4): %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
