#!/usr/bin/env python3
"""Failure semantics + resume for pervio-orchestrate (WF-2 of the redesign).

  * optional: true — a step that never blocks the graph. Its failure lets
    dependents run (refs substitute empty), leaves the RUN 'done', and is
    still visible as a failed step row. The three-step fanout charade
    (prep + fanout-of-1 + tolerateAllFail) this replaces can retire.
  * retry: N — the author's own failure budget, agent AND command steps.
    Unset keeps the legacy contract byte-stable: one re-run, transient only.
  * start --resume-from <wfId> — unchanged, already-done steps are seeded
    from the prior run (ledger cached:true, no agent turn, json artifacts and
    fan-out children copied) so only the edited tail spends tokens. Cached
    steps must not re-publish. The first edited step breaks the chain for
    everything downstream. Worktree-isolated specs are refused.

Hermetic: isolated $HOME, scratch git repo, committed shim claude on PATH.
"""
import base64
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
    print(("PASS " if cond else "FAIL ") + name
          + (("  [" + str(detail)[:260] + "]") if (detail and not cond) else ""))


def mkrepo():
    d = tempfile.mkdtemp(prefix="resume_", dir="/tmp")
    for a in (["init", "-q", "-b", "main"], ["config", "user.email", "t@t"],
              ["config", "user.name", "t"]):
        subprocess.run(["git", "-C", d] + a, capture_output=True)
    open(os.path.join(d, "base.txt"), "w").write("base\n")
    subprocess.run(["git", "-C", d, "add", "-A"], capture_output=True)
    subprocess.run(["git", "-C", d, "commit", "-qm", "base"], capture_output=True)
    return d


def env(home):
    e = dict(os.environ, HOME=home, PATH=SHIM + ":" + os.environ.get("PATH", ""))
    e.pop("PERVIO_CHILD_TIMEOUT", None)
    return e


def start(spec, home, resume_from=None):
    b64 = base64.b64encode(json.dumps(spec).encode()).decode()
    cmd = [sys.executable, ORCH, "start", "--spec-b64", b64]
    if resume_from:
        cmd += ["--resume-from", resume_from]
    return subprocess.run(cmd, env=env(home), capture_output=True, text=True, timeout=60)


def wait_done(home, wf, timeout=90):
    rd = os.path.join(home, ".pervio", "wf", wf)
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            led = json.load(open(os.path.join(rd, "ledger.json")))
        except (OSError, ValueError):
            led = {}
        if led.get("status") in ("done", "failed"):
            return led
        time.sleep(0.15)
    return {"status": "TIMEOUT"}


def run_spec(spec, home, resume_from=None):
    p = start(spec, home, resume_from)
    if p.returncode != 0:
        return None, p.stderr.strip()
    wf = json.loads(p.stdout)["wfId"]
    return wait_done(home, wf), wf


def led_step(led, sid):
    return next(s for s in led["steps"] if s["id"] == sid)


def agent(sid, shim, extra=None):
    s = {"id": sid, "backend": "claude", "perm": "plan",
         "prompt": "%s work\nSHIM:%s" % (sid, json.dumps(shim))}
    s.update(extra or {})
    return s


home = tempfile.mkdtemp(prefix="resume_home_", dir="/tmp")
repo = mkrepo()

# ---------- R1: optional step fails, dependents run, run stays done ----------
spec = {"name": "r1", "dir": repo, "steps": [
    agent("a", {"is_error": True, "text": "taste keeper died"}, {"optional": True}),
    {"id": "c", "backend": "claude", "dependsOn": ["a"],
     "command": "printf 'got:[%s]' \"$(cat -)\"", "stdin": "{{a.output}}"},
]}
led, wf = run_spec(spec, home)
check("R1a optional failure: dependent RAN with empty input, run is done",
      led["status"] == "done" and led_step(led, "c")["status"] == "done"
      and led_step(led, "c")["output"] == "got:[]",
      (led["status"], led_step(led, "c") if led.get("steps") else led))
check("R1b the failed optional step is still visible as failed",
      led_step(led, "a")["status"] == "failed" and led_step(led, "a").get("optional") is True,
      led_step(led, "a"))
st_file = open(os.path.join(home, ".pervio", "wf", wf, "status")).read()
check("R1c exit status says 0 (no hard failure)", st_file == "exited:0", st_file)

# ---------- R2: the same shape WITHOUT optional still fails+skips ----------
spec = {"name": "r2", "dir": repo, "steps": [
    agent("a", {"is_error": True, "text": "boom"}),
    agent("b", {"text": "next"}, {"dependsOn": ["a"]}),
]}
led, wf = run_spec(spec, home)
check("R2 non-optional failure keeps legacy semantics: skip + failed run",
      led["status"] == "failed" and led_step(led, "b")["status"] == "skipped",
      (led["status"], led_step(led, "b")["status"]))

# ---------- R3: retry on a command step ----------
flagdir = tempfile.mkdtemp(prefix="r3_", dir="/tmp")
spec = {"name": "r3", "dir": repo, "steps": [
    {"id": "c", "backend": "claude", "retry": 2,
     "command": "if [ -f %s/f ]; then echo fine; else touch %s/f; exit 7; fi"
                % (flagdir, flagdir)},
]}
led, wf = run_spec(spec, home)
check("R3 command retry: first attempt exit 7, second succeeds",
      led["status"] == "done" and led_step(led, "c").get("retried") is True
      and led_step(led, "c")["output"].strip() == "fine",
      led_step(led, "c") if led.get("steps") else led)

# ---------- R4: retry:N covers NON-transient agent failure; unset does not ----------
flag = os.path.join(home, "r4.flag")
shim = {"text": "fixed", "fail_once": {"flag": flag, "text": "wrong, not transient"}}
spec = {"name": "r4a", "dir": repo, "steps": [agent("a", shim, {"retry": 1})]}
led, wf = run_spec(spec, home)
check("R4a retry:1 re-runs a non-transient failure",
      led["status"] == "done" and led_step(led, "a").get("retried") is True
      and led_step(led, "a")["output"] == "fixed", led_step(led, "a") if led.get("steps") else led)
flag2 = os.path.join(home, "r4b.flag")
spec = {"name": "r4b", "dir": repo, "steps": [
    agent("a", {"text": "fixed", "fail_once": {"flag": flag2, "text": "wrong, not transient"}})]}
led, wf = run_spec(spec, home)
check("R4b retry unset keeps the legacy contract: non-transient = no retry",
      led["status"] == "failed" and not led_step(led, "a").get("retried"),
      led_step(led, "a") if led.get("steps") else led)

# ---------- R5/R6: resume — cached head, re-run tail, artifacts copied ----------
mk = {"text": "1. " + json.dumps({"text": "{\"v\": 10}"})
              + "\n2. " + json.dumps({"text": "{\"v\": 20}"})}
child_sch = {"type": "object", "properties": {"v": {"type": "integer"}}, "required": ["v"]}


def big_spec(sink_shim):
    return {"name": "r5", "dir": repo, "steps": [
        agent("mk", mk),
        {"id": "work", "backend": "claude", "perm": "plan", "outputSchema": child_sch,
         "fanout": {"over": "{{mk.output}}", "split": "numbered", "max": 10,
                    "maxParallel": 2},
         "prompt": "p\nSHIM:{{item}}"},
        agent("sink", sink_shim, {"dependsOn": ["work"]}),
    ]}


led1, wf1 = run_spec(big_spec({"is_error": True, "text": "sink exploded"}), home)
check("R5a run 1: head done, sink failed",
      led1["status"] == "failed" and led_step(led1, "work")["status"] == "done"
      and led_step(led1, "sink")["status"] == "failed", led1["status"])

led2, wf2 = run_spec(big_spec({"text": "sink fine now"}), home, resume_from=wf1)
rd2 = os.path.join(home, ".pervio", "wf", wf2)
check("R5b resume: mk+work cached, sink re-ran and succeeded",
      led2["status"] == "done"
      and led_step(led2, "mk").get("cached") is True
      and led_step(led2, "work").get("cached") is True
      and not led_step(led2, "sink").get("cached")
      and led_step(led2, "sink")["output"] == "sink fine now",
      [(s["id"], s.get("cached"), s["status"]) for s in led2["steps"]] if led2.get("steps") else led2)
check("R5c cached steps ran NO agent turn (no fresh jsonl)",
      not os.path.exists(os.path.join(rd2, "mk.jsonl"))
      and os.path.exists(os.path.join(rd2, "sink.jsonl")))
check("R6a cached fan-out's json artifact copied and identical",
      json.load(open(os.path.join(rd2, "json", "work.json"))) == [{"v": 10}, {"v": 20}],
      "missing json/work.json" if not os.path.exists(os.path.join(rd2, "json", "work.json")) else "")
check("R6b cached fan-out children's out.jsonl copied (downstream child_text path)",
      os.path.exists(os.path.join(rd2, "dispatch", "fanout", "work", "0", "out.jsonl"))
      and os.path.exists(os.path.join(rd2, "dispatch", "fanout", "work", "1", "out.jsonl")))

# ---------- R7: editing the HEAD breaks the whole chain ----------
edited = big_spec({"text": "sink fine now"})
edited["steps"][0]["prompt"] += "\n(v2)"
led3, wf3 = run_spec(edited, home, resume_from=wf1)
check("R7 edited head: nothing cached, everything re-ran",
      led3["status"] == "done" and not any(s.get("cached") for s in led3["steps"])
      and os.path.exists(os.path.join(home, ".pervio", "wf", wf3, "mk.jsonl")),
      [(s["id"], s.get("cached")) for s in led3["steps"]] if led3.get("steps") else led3)

# ---------- R8: all-cached resume completes without re-publishing ----------
pubdir = tempfile.mkdtemp(prefix="r8pub_", dir="/tmp")
spec = {"name": "r8", "dir": repo, "steps": [
    agent("a", {"text": "# 刊物 2026-08-21\n正文"}, {"publish": pubdir}),
]}
led1, wf1 = run_spec(spec, home)
issue = os.path.join(pubdir, "2026-08-21.md")
check("R8a run 1 published the issue", led1["status"] == "done" and os.path.exists(issue),
      os.listdir(pubdir) if os.path.isdir(pubdir) else "no dir")
mtime1 = os.stat(issue).st_mtime_ns if os.path.exists(issue) else 0
time.sleep(0.3)
led2, wf2 = run_spec(spec, home, resume_from=wf1)
mtime2 = os.stat(issue).st_mtime_ns if os.path.exists(issue) else -1
check("R8b all-cached resume: done instantly, issue file untouched",
      led2["status"] == "done" and led_step(led2, "a").get("cached") is True
      and mtime1 == mtime2, (led2["status"], mtime1, mtime2))

# ---------- R10: an OLD isolated run with unmerged work refuses resume ----------
# 2026-08-22 audit P1: checking only the NEW spec left a hole — edit the spec so
# the new graph isn't isolated, and the old run's unmerged write-step commits
# (stranded on its branches) would be cached as 'done' on a tree that lacks them.
iso_old = {"name": "r10", "dir": repo, "steps": [
    agent("w1", {"text": "one", "write": [{"file": "r10.txt", "content": "x"}]},
          {"perm": "acceptEdits"}),
    agent("w2", {"is_error": True, "text": "w2 died"}, {"perm": "acceptEdits"}),
]}
led1, wf1 = run_spec(iso_old, home)
check("R10a old run: isolated, failed, NOT merged back",
      led1["status"] == "failed" and (led1.get("git") or {}).get("merged") is False,
      led1.get("git"))
iso_new = json.loads(json.dumps(iso_old))
iso_new["steps"][1] = agent("w2", {"text": "w2 fine"})          # plan reader now:
p = start(iso_new, home, resume_from=wf1)                        # new graph NOT isolated
check("R10b resume refused: old run's work never merged",
      p.returncode != 0 and "merged" in (p.stderr or ""), p.stderr[:200])

# ---------- R11: a cached structured step must still have its artifact ----------
sch11 = {"type": "object", "required": ["v"]}
spec11 = {"name": "r11", "dir": repo, "steps": [
    agent("a", {"text": "{\"v\": 1}"}, {"outputSchema": sch11}),
    agent("b", {"is_error": True, "text": "boom"}, {"dependsOn": ["a"]}),
]}
led1, wf1 = run_spec(spec11, home)
os.remove(os.path.join(home, ".pervio", "wf", wf1, "json", "a.json"))
spec11["steps"][1] = agent("b", {"text": "fine"}, {"dependsOn": ["a"]})
led2, wf2 = run_spec(spec11, home, resume_from=wf1)
check("R11 missing json artifact: the step re-runs instead of caching a hole",
      led2["status"] == "done" and not led_step(led2, "a").get("cached")
      and os.path.exists(os.path.join(home, ".pervio", "wf", wf2, "json", "a.json")),
      [(s["id"], s.get("cached")) for s in led2["steps"]] if led2.get("steps") else led2)

# ---------- R12: a hard-killed runner's corpse gets reconciled at every exit ----------
# 2026-08-22 audit P1: kill -9 / reboot left ledger.status "running" forever —
# status/list echoed it, tail never ended, the pruner skipped the corpse. Now
# any of those exits consults the process's actual liveness and settles the
# record once (steps failed/skipped, status file exited:1).
import signal as _sig
spec = {"name": "r12", "dir": repo, "steps": [
    agent("slow", {"text": "zzz", "sleep": 30}),
]}
p12 = start(spec, home)
wf12 = json.loads(p12.stdout)["wfId"]
rd12 = os.path.join(home, ".pervio", "wf", wf12)
deadline = time.time() + 30
while time.time() < deadline:
    try:
        led = json.load(open(os.path.join(rd12, "ledger.json")))
        if led["steps"][0]["status"] == "running":
            break
    except (OSError, ValueError, KeyError, IndexError):
        pass
    time.sleep(0.1)
pgid12 = int(open(os.path.join(rd12, "pgid")).read().strip())
os.killpg(pgid12, _sig.SIGKILL)
time.sleep(0.5)
p12 = subprocess.run([sys.executable, ORCH, "status", "--wf", wf12],
                     env=env(home), capture_output=True, text=True, timeout=30)
led12 = json.loads(p12.stdout)
check("R12a status reconciles the corpse: run failed, step error names the death",
      led12["status"] == "failed"
      and "runner died" in led12["steps"][0]["error"], led12)
check("R12b the settled record persists (status file + ledger on disk)",
      open(os.path.join(rd12, "status")).read() == "exited:1"
      and json.load(open(os.path.join(rd12, "ledger.json")))["status"] == "failed")
p12 = subprocess.run([sys.executable, ORCH, "list"],
                     env=env(home), capture_output=True, text=True, timeout=30)
row = next(i for i in json.loads(p12.stdout) if i["wfId"] == wf12)
check("R12c list shows the truth, not the stale 'running'", row["status"] == "failed", row)
subprocess.run([sys.executable, ORCH, "delete", "--wf", wf12],
               env=env(home), capture_output=True, timeout=30)

# ---------- R9: worktree-isolated spec refuses resume ----------
iso_spec = {"name": "r9", "dir": repo, "steps": [
    agent("w1", {"text": "one"}, {"perm": "acceptEdits"}),
    agent("w2", {"text": "two"}, {"perm": "acceptEdits"}),
]}
led1, wf1 = run_spec(iso_spec, home)
p = start(iso_spec, home, resume_from=wf1)
check("R9 resume refused for worktree-isolated workflows",
      p.returncode != 0 and "worktree" in (p.stderr or ""), p.stderr[:200])

shutil.rmtree(home, ignore_errors=True)
shutil.rmtree(repo, ignore_errors=True)
shutil.rmtree(flagdir, ignore_errors=True)
shutil.rmtree(pubdir, ignore_errors=True)

ok = all(results)
print("\n=== test_resume: %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌",
                                             sum(results), len(results)))
sys.exit(0 if ok else 1)
