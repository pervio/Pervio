#!/usr/bin/env python3
"""Single-step test runs (WF-3): `teststep` re-runs ONE step — or one fan-out
child — against a PRIOR run's recorded inputs, with the step definition taken
from an EDITED spec when given. The whole point: iterating a prompt on step 19
of a 40-minute pipeline without paying for steps 1-18 again. Contained in
run_child's ephemeral worktree (writes never land), artifacts under the old
run's teststep/<n>/, the old run's ledger untouched.

Hermetic: isolated $HOME, scratch git repo, committed shim claude on PATH."""
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
    d = tempfile.mkdtemp(prefix="tstep_", dir="/tmp")
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


def orch(home, *args):
    return subprocess.run([sys.executable, ORCH] + list(args),
                          env=env(home), capture_output=True, text=True, timeout=90)


def run_spec(spec, home):
    b64 = base64.b64encode(json.dumps(spec).encode()).decode()
    p = orch(home, "start", "--spec-b64", b64)
    assert p.returncode == 0, p.stderr
    wf = json.loads(p.stdout)["wfId"]
    rd = os.path.join(home, ".pervio", "wf", wf)
    deadline = time.time() + 90
    while time.time() < deadline:
        try:
            led = json.load(open(os.path.join(rd, "ledger.json")))
        except (OSError, ValueError):
            led = {}
        if led.get("status") in ("done", "failed"):
            return led, wf
        time.sleep(0.15)
    raise AssertionError("run timed out")


def agent(sid, shim, extra=None):
    s = {"id": sid, "backend": "claude", "perm": "plan",
         "prompt": "%s work\nSHIM:%s" % (sid, json.dumps(shim))}
    s.update(extra or {})
    return s


home = tempfile.mkdtemp(prefix="tstep_home_", dir="/tmp")
repo = mkrepo()

mk = {"text": "1. " + json.dumps({"text": "child one"})
              + "\n2. " + json.dumps({"text": "child two"})}
spec = {"name": "ts", "dir": repo, "steps": [
    agent("mk", mk),
    {"id": "work", "backend": "claude", "perm": "plan",
     "fanout": {"over": "{{mk.output}}", "split": "numbered", "max": 10,
                "maxParallel": 2},
     "prompt": "p\nSHIM:{{item}}"},
    agent("sink", {"text": "sank {{work.output}}"[:20]}, {"dependsOn": ["work"]}),
]}
led, wf = run_spec(spec, home)
rd = os.path.join(home, ".pervio", "wf", wf)
led_bytes = open(os.path.join(rd, "ledger.json"), "rb").read()

# ---------- T1: plain step with an EDITED spec ----------
spec2 = json.loads(json.dumps(spec))
spec2["steps"][2] = agent("sink", {"text": "v2 answer"}, {"dependsOn": ["work"]})
b64 = base64.b64encode(json.dumps(spec2).encode()).decode()
p = orch(home, "teststep", "--wf", wf, "--step", "sink", "--spec-b64", b64)
check("T1a edited step runs against old inputs, prints the new answer",
      p.returncode == 0 and "v2 answer" in p.stdout and "result: OK" in p.stdout,
      (p.returncode, p.stdout[:200], p.stderr[:150]))
check("T1b artifacts under teststep/1, old ledger byte-identical",
      os.path.isdir(os.path.join(rd, "teststep", "1"))
      and open(os.path.join(rd, "ledger.json"), "rb").read() == led_bytes)

# ---------- T2: one fan-out child by index ----------
p = orch(home, "teststep", "--wf", wf, "--step", "work", "--item", "1")
check("T2a fanout teststep runs exactly the chosen child",
      p.returncode == 0 and "child two" in p.stdout and "child one" not in p.stdout,
      p.stdout[:200])
check("T2b out-of-range item refused",
      orch(home, "teststep", "--wf", wf, "--step", "work", "--item", "9").returncode != 0)

# ---------- T3: outputSchema verdict decides the exit code ----------
sch = {"type": "object", "required": ["v"]}
spec3 = json.loads(json.dumps(spec))
spec3["steps"][2] = agent("sink", {"text": "not json"},
                          {"dependsOn": ["work"], "outputSchema": sch})
b64 = base64.b64encode(json.dumps(spec3).encode()).decode()
p = orch(home, "teststep", "--wf", wf, "--step", "sink", "--spec-b64", b64)
check("T3a schema-flunking answer: exit 1 with the verdict printed",
      p.returncode != 0 and "schema: FAIL" in p.stdout, (p.returncode, p.stdout[:200]))
spec3["steps"][2] = agent("sink", {"text": "{\"v\": 1}"},
                          {"dependsOn": ["work"], "outputSchema": sch})
b64 = base64.b64encode(json.dumps(spec3).encode()).decode()
p = orch(home, "teststep", "--wf", wf, "--step", "sink", "--spec-b64", b64)
check("T3b conforming answer: exit 0, schema: ok",
      p.returncode == 0 and "schema: ok" in p.stdout, (p.returncode, p.stdout[:200]))

# ---------- T4: command steps are refused with the hand-run hint ----------
spec4 = json.loads(json.dumps(spec))
spec4["steps"].append({"id": "glue", "backend": "claude", "dependsOn": ["sink"],
                       "command": "true"})
b64 = base64.b64encode(json.dumps(spec4).encode()).decode()
p = orch(home, "teststep", "--wf", wf, "--step", "glue", "--spec-b64", b64)
check("T4 command step refused, hint names PERVIO_WF_DIR",
      p.returncode != 0 and "PERVIO_WF_DIR" in p.stderr, p.stderr[:200])

# ---------- T5: delete sweeps teststep dirs with the run ----------
p = orch(home, "delete", "--wf", wf)
check("T5 delete removes the run including teststep artifacts",
      p.returncode == 0 and not os.path.isdir(rd), (p.returncode, p.stderr[:120]))

shutil.rmtree(home, ignore_errors=True)
shutil.rmtree(repo, ignore_errors=True)

ok = all(results)
print("\n=== test_teststep: %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌",
                                               sum(results), len(results)))
sys.exit(0 if ok else 1)
