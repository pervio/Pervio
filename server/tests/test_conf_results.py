#!/usr/bin/env python3
"""conf-results template: the deterministic skeleton EXECUTED end to end.
Hermetic: fake $HOME, fixture papers (PERVIO_CONF_FIXTURE), shim claude for the
three agent steps (prompts swapped for SHIM directives — the commands under test
run VERBATIM from the shipped template). Pins: cold-start card on missing
credentials; fixture fetch; prescreen shard blocks; focus's stdin merge;
assemble's five sections; publish from a COMMAND step lands the dated issue.
"""
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.realpath(__file__))
BIN = os.path.realpath(os.path.join(HERE, "..", "bin"))
ORCH = os.path.join(BIN, "pervio-orchestrate")
SHIM = os.path.join(HERE, "shim")
TPL = json.load(open(os.path.join(HERE, "..", "templates", "conf-results.json")))
FIX = os.path.join(HERE, "fixtures", "conf")

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + (("  [" + str(detail)[:200] + "]") if (detail and not cond) else ""))


def env(home):
    e = dict(os.environ)
    e["HOME"] = home
    e["PATH"] = SHIM + os.pathsep + e.get("PATH", "")
    e["PERVIO_CONF_FIXTURE"] = FIX
    e.pop("OPENREVIEW_USERNAME", None)
    e.pop("OPENREVIEW_PASSWORD", None)
    return e


# ---------- S1: the cold-start card (no creds, no fixture) ----------
print("=== S1 cold-start: missing credentials fail fast with the human card ===")
home = tempfile.mkdtemp(prefix="conf1_", dir="/tmp")
chk = next(s for s in TPL["spec"]["steps"] if s["id"] == "check")
e1 = dict(os.environ, HOME=home)
e1.pop("PERVIO_CONF_FIXTURE", None)
e1.pop("OPENREVIEW_USERNAME", None); e1.pop("OPENREVIEW_PASSWORD", None)
p = subprocess.run(["bash", "-c", chk["command"]], env=e1, capture_output=True, text=True, timeout=60)
check("S1 exits nonzero without credentials", p.returncode != 0, p.returncode)
check("S1 card speaks human: 注册链接 + 对话配置指引 + 再点运行",
      "openreview.net/signup" in p.stdout and "发给 Claude" in p.stdout
      and "再点一次「运行」" in p.stdout, p.stdout[:200])
shutil.rmtree(home, ignore_errors=True)

# ---------- S2: full skeleton run (fixture + shim agents) ----------
print("=== S2 full run: fixture data, shim juries, real commands ===")
home = tempfile.mkdtemp(prefix="conf2_", dir="/tmp")
spec = json.loads(json.dumps(TPL["spec"]))
ids = ["sub%04d" % i for i in range(1, 25)]
score_arr = [{"id": i, "stars": 3.0 + (n % 5) * 0.5, "hit": "agent RL" if n % 2 else "评测",
              "reason": "r%d" % n} for n, i in enumerate(ids)]
cards_arr = [{"id": i, "what": "干了 w%d" % n, "how": "how", "why": "why"}
             for n, i in enumerate(ids)]
land_arr = [{"track": "Machine Learning for NLP", "n": 10, "summary": "都在卷 RL。",
             "picks": ["代表作甲"]}]
for s in spec["steps"]:
    if s["id"] == "score":
        s["prompt"] = "SHIM:" + json.dumps({"text": json.dumps(score_arr, ensure_ascii=False)})
        s["fanout"]["maxParallel"] = 2
    if s["id"] == "cards":
        s["prompt"] = "SHIM:" + json.dumps({"text": json.dumps(cards_arr, ensure_ascii=False)})
        s["fanout"]["maxParallel"] = 2
    if s["id"] == "landscape":
        s["prompt"] = "SHIM:" + json.dumps({"text": json.dumps(land_arr, ensure_ascii=False)})
spec_b64 = base64.b64encode(json.dumps(spec).encode()).decode()
params_b64 = base64.b64encode(json.dumps({"venue": "EMNLP 2026", "focus": "20"}).encode()).decode()
p = subprocess.run([sys.executable, ORCH, "start", "--spec-b64", spec_b64,
                    "--params-b64", params_b64], env=env(home), capture_output=True, text=True)
check("S2 start accepted", p.returncode == 0, p.stderr[-200:])
wf = json.loads(p.stdout)["wfId"] if p.returncode == 0 else ""
led = {}
for _ in range(240):
    q = subprocess.run([sys.executable, ORCH, "status", "--wf", wf], env=env(home),
                       capture_output=True, text=True)
    led = json.loads(q.stdout) if q.returncode == 0 else {}
    if led.get("status") in ("done", "failed"):
        break
    time.sleep(0.5)
step = {s["id"]: s for s in led.get("steps", [])}
check("S2 run done", led.get("status") == "done",
      {k: (v.get("status"), (v.get("error") or "")[:80]) for k, v in step.items()})
check("S2 prescreen emitted shard blocks", "1) 分片" in (step.get("prescreen", {}).get("output") or ""))
check("S2 focus merged jury via stdin (picked>0)",
      "分片" in (step.get("focus", {}).get("output") or ""), (step.get("focus", {}).get("output") or "")[:80])
arch = os.path.join(home, ".pervio", "conf", "archive")
issues = os.listdir(arch) if os.path.isdir(arch) else []
check("S2 publish from a COMMAND step landed a dated issue",
      any(re.match(r"\d{4}-\d{2}-\d{2}\.md$", f) for f in issues), issues)
doc = open(os.path.join(arch, issues[0]), encoding="utf-8").read() if issues else ""
check("S2 issue has the five sections + honest footer",
      all(k in doc for k in ("放榜速览", "## 总览", "## 全景", "## 组织榜", "## 焦点", "程序装配")),
      doc[:160])
check("S2 fixture orgs note honest", "fixture 模式跳过组织统计" in doc, "")
check("S2 jury coverage line present", re.search(r"焦点评审:\d+/\d+ 片", doc), doc[:300])
subprocess.run([sys.executable, ORCH, "delete", "--wf", wf], env=env(home), capture_output=True)
shutil.rmtree(home, ignore_errors=True)

# ---------- S3: params must NEVER reach a shell command ----------
print("=== S3 param-in-command still refused (injection guard) ===")
home = tempfile.mkdtemp(prefix="conf3_", dir="/tmp")
bad = {"name": "bad", "dir": "/tmp", "steps": [
    {"id": "x", "backend": "claude", "prompt": "", "command": "echo {{param.v}}"}]}
p = subprocess.run([sys.executable, ORCH, "start",
                    "--spec-b64", base64.b64encode(json.dumps(bad).encode()).decode(),
                    "--params-b64", base64.b64encode(json.dumps({"v": "x"}).encode()).decode()],
                   env=dict(os.environ, HOME=home), capture_output=True, text=True)
check("S3 start refused with the guard message",
      p.returncode != 0 and "prompts, dir and stdin" in (p.stderr or ""), p.stderr[-160:])
shutil.rmtree(home, ignore_errors=True)

ok = all(results)
print("\n=== conf-results skeleton: %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
