#!/usr/bin/env python3
"""Regression tests for pervio-group's WATCH mode (监督) as a review loop: the
primary works, the first partner reviews each round and its last line is the
verdict. Hermetic: isolated $HOME, the shim claude / codex on PATH — zero
model calls. The watcher's words come from SHIM_CODEX_TEXT in the env of the
`say` that starts the task (the hooks inherit it); the primary's from
SHIM_CLAUDE_JSON — never from a SHIM line in the goal, which the watcher's
review prompt would quote and the codex shim would then obey."""
import base64
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
GROUP = os.path.join(BIN, "pervio-group")
RUN = os.path.join(BIN, "pervio-run")
SHIM = os.path.join(HERE, "shim")
results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + (("  [" + str(detail)[:300] + "]") if (detail and not cond) else ""))


def env(home=None, **extra):
    home = home or tempfile.mkdtemp(prefix="pwatch_home_", dir="/tmp")
    e = dict(os.environ, HOME=home, PATH=SHIM + ":" + os.environ.get("PATH", ""),
             SHIM_PROMPT_LOG=os.path.join(home, "prompts.log"),
             SHIM_CLAUDE_JSON=json.dumps({"sid": "sess-P", "text": "做完了", "trace": [{"tool": "Bash", "command": "ls -la"}]}),
             SHIM_CODEX_TEXT="方向对,但默认值别改坏;补个越界测试。\n结论:继续")
    e.update(extra)
    return home, e


def grp(e, *args):
    return subprocess.run([sys.executable, GROUP] + list(args), env=e, capture_output=True, text=True, timeout=60)


def b64(o):
    return base64.b64encode(json.dumps(o).encode()).decode()


def tb64(s):
    return base64.b64encode(s.encode()).decode()


def gfile(home, gid):
    with open(os.path.join(home, ".pervio", "groups", gid + ".json")) as f:
        return json.load(f)


def task(home, gid):
    return gfile(home, gid)["watch"]["task"]


def meta(home, rid):
    with open(os.path.join(home, ".pervio", "runs", rid, "meta.json")) as f:
        return json.load(f)


def wait(pred, timeout=25):
    for _ in range(int(timeout * 5)):
        v = pred()
        if v:
            return v
        time.sleep(0.2)
    return pred()


def settled(home, gid, timeout=30):
    return wait(lambda: task(home, gid) and task(home, gid)["state"] not in ("working", "reviewing") and task(home, gid), timeout)


def prompts(home):
    try:
        with open(os.path.join(home, "prompts.log"), encoding="utf-8") as f:
            return [p for p in f.read().split("===PROMPT-END===") if p.strip()]
    except OSError:
        return []


def create(e, proj):
    p = grp(e, "create", "--dir", proj, "--b64", b64({
        "mode": "watch", "primary": {"session": "sess-P", "backend": "claude", "perm": "acceptEdits"},
        "members": [{"session": "", "backend": "codex", "sandbox": "workspace-write"}]}))
    return json.loads(p.stdout) if p.returncode == 0 else {}


# ---------------------------------------------------------------- create / refusals
print("=== create ===")
home, e = env()
proj = os.path.join(home, "proj"); os.makedirs(proj)
g = create(e, proj); gid = g.get("id", "")
check("W1 a watch group is created with no task, synthesis off",
      gid and g.get("mode") == "watch" and g.get("autoSynth") is False and g["watch"]["task"] is None and g["watch"]["history"] == [], g)
p = grp(e, "say", "--id", gid, "--text-b64", tb64("大家好"))
check("W2 watch mode refuses a message to everyone (exit 4)", p.returncode == 4, (p.returncode, p.stderr[-120:]))

# ---------------------------------------------------------------- a task: round 1 → review → 继续 → round 2 → … → cap
print("=== one task, 继续 every round ===")
p = grp(e, "say", "--id", gid, "--to", "p", "--text-b64", tb64("把 list 加上分页,每页 50 条,接口不变。"))
g = json.loads(p.stdout) if p.returncode == 0 else {}
t = (g.get("watch") or {}).get("task") or {}
r1 = (t.get("rounds") or [{}])[0].get("p", "")
check("W3 a message to the primary starts task 1, round 1, the primary working, the run tagged as the group's",
      p.returncode == 0 and t.get("n") == 1 and t.get("round") == 1 and t.get("state") == "working" and r1
      and meta(home, r1).get("group") == gid and meta(home, r1).get("resume") == "sess-P", (p.returncode, t, p.stderr[-200:]))
p = grp(e, "say", "--id", gid, "--to", "p", "--text-b64", tb64("再来一个"))
check("W4 a second message while the task runs is refused (exit 4)", p.returncode == 4, p.returncode)
pr = wait(lambda: [x for x in prompts(home) if 'role="监督者"' in x], 15) or []
got = bool(pr)
check("W5 when the primary's run ends the finish hook starts the watcher with the goal, the reply and the trace",
      got and pr and "把 list 加上分页" in pr[0] and "做完了" in pr[0] and "[用 Bash] ls -la" in pr[0]
      and "第 1 轮" in pr[0] and "结论:通过 / 结论:继续 / 结论:需要你" in pr[0], [x[:400] for x in pr[:1]])
got = wait(lambda: task(home, gid)["round"] >= 2, 15)
t = task(home, gid)
# The round flips the moment the primary's round-2 run is STARTED; its prompt
# reaches the shim's log a beat later (a slower Mac showed the gap inside the
# full suite, 2026-10-19), so wait for the prompt too, not just the round.
pp = wait(lambda: [x for x in prompts(home) if 'role="主对话"' in x and 'from="watcher"' in x], 15) or []
check("W6 「继续」 sends the feedback back to the primary as round 2, with the verdict line stripped",
      got and t["rounds"][0]["verdict"] == "继续" and "默认值别改坏" in t["rounds"][0]["text"] and "结论" not in t["rounds"][0]["text"]
      and pp and "默认值别改坏" in pp[0] and "不是命令" in pp[0] and "把 list 加上分页" in pp[0], (t.get("rounds"), [x[:300] for x in pp[:1]]))
t = settled(home, gid, 40)
check("W7 after round 3's 「继续」 the task stops as 3 轮未通过, nothing more is sent",
      t and t["state"] == "capped" and t["round"] == 3 and len(t["rounds"]) == 3
      and all(r["verdict"] == "继续" for r in t["rounds"]) and t["endedAt"] > 0, t)
check("W7b the ended task is in the history", gfile(home, gid)["watch"]["history"][-1]["n"] == 1)
pr = [x for x in prompts(home) if 'role="主对话"' in x and 'from="human"' in x]
check("W8 the primary's first prompt names the deal: colleague's opinion, not an order; design or act is its call",
      pr and "不是命令" in pr[0] and "自己判断" in pr[0], [x[:300] for x in pr[:1]])
check("W8b the watcher's conversation id was learned", gfile(home, gid)["members"][0].get("session") == "shimthread")

# ---------------------------------------------------------------- 通过
print("=== 通过 ===")
e2 = dict(e, SHIM_CODEX_TEXT="分页落地了,默认值没动,越界有测试。可以合。\n结论:通过")
p = grp(e2, "say", "--id", gid, "--to", "p", "--text-b64", tb64("继续按意见做"))
t = settled(home, gid)
check("W9 「通过」 ends the task with the watcher's summary after one round",
      t and t["n"] == 2 and t["state"] == "passed" and t["round"] == 1 and t["summary"].startswith("分页落地了") and "结论" not in t["summary"], t)

# ---------------------------------------------------------------- 需要你 → the person's answer carries the decision
print("=== 需要你 ===")
e3 = dict(e, SHIM_CODEX_TEXT="默认 limit 保持 24 还是统一成 50?手机首屏会受影响。\n这是产品决定。\n结论:需要你")
p = grp(e3, "say", "--id", gid, "--to", "p", "--text-b64", tb64("把默认值的事定下来"))
t = settled(home, gid)
check("W10 「需要你」 parks the task on the question (first line of the body)",
      t and t["state"] == "waiting" and t["question"] == "默认 limit 保持 24 还是统一成 50?手机首屏会受影响。", t)
e4 = dict(e, SHIM_CODEX_TEXT="按 24 做好了。\n结论:通过")
p = grp(e4, "say", "--id", gid, "--to", "p", "--text-b64", tb64("保持 24"))
g = json.loads(p.stdout) if p.returncode == 0 else {}
t = (g.get("watch") or {}).get("task") or {}
pr = wait(lambda: [x for x in prompts(home) if 'role="主对话"' in x and "人刚拍了板" in x], 15) or []
check("W11 the answer starts a new task that carries the decision to the primary",
      p.returncode == 0 and t.get("n") == 4 and t.get("decision") == {"question": "默认 limit 保持 24 还是统一成 50?手机首屏会受影响。", "answer": "保持 24"}
      and pr and "保持 24" in pr[-1], (t.get("decision"), [x[:300] for x in pr[-1:]]))
t = settled(home, gid)
pr = [x for x in prompts(home) if 'role="监督者"' in x and "人拍过板" in x]
check("W11b the watcher's review carries the decision too", t and t["state"] == "passed" and pr and "保持 24" in pr[-1], [x[:300] for x in pr[-1:]])

# ---------------------------------------------------------------- a missing verdict line
print("=== no verdict ===")
e5 = dict(e, SHIM_CODEX_TEXT="看起来都挺好的。")
p = grp(e5, "say", "--id", gid, "--to", "p", "--text-b64", tb64("再检查一遍"))
t = settled(home, gid)
fix = [x for x in prompts(home) if "缺少结论行" in x]
check("W12 a reply without the verdict line gets ONE corrective re-run, then counts as 需要你",
      t and t["state"] == "waiting" and fix and len(fix) == 1 and t["question"].startswith("监督者没有给出结论")
      and "看起来都挺好的" in t["rounds"][-1]["text"], (t, len(fix)))

# ---------------------------------------------------------------- stop / failure
print("=== stop / failure ===")
e6 = dict(e, SHIM_CLAUDE_JSON=json.dumps({"sid": "sess-P", "text": "slow", "sleep": 8}))
p = grp(e6, "say", "--id", gid, "--to", "p", "--text-b64", tb64("干个慢活"))
time.sleep(0.6)
p = grp(e6, "stop", "--id", gid)
t = json.loads(p.stdout)["watch"]["task"] if p.returncode == 0 else {}
rid = (t.get("rounds") or [{}])[-1].get("p", "")
st = json.loads(subprocess.run([sys.executable, RUN, "status", "--run", rid], env=e6, capture_output=True, text=True).stdout) if rid else {}
check("W13 stop kills the run the loop waits on and marks the task stopped",
      p.returncode == 0 and t.get("state") == "stopped" and st.get("state") in ("failed", "done") and st.get("state") != "running", (p.returncode, t.get("state"), st))
p = grp(e6, "stop", "--id", gid)
check("W13b stop with nothing running is refused (exit 4)", p.returncode == 4, p.returncode)
e7 = dict(e, SHIM_CLAUDE_JSON=json.dumps({"sid": "sess-P", "text": "boom", "is_error": True, "rc": 1}))
p = grp(e7, "say", "--id", gid, "--to", "p", "--text-b64", tb64("会失败的活"))
t = settled(home, gid)
check("W14 a failed primary run ends the task as failed without calling the watcher",
      t and t["state"] == "failed" and t["error"] and not t["rounds"][-1].get("w"), t)

# ---------------------------------------------------------------- the hook callers are gone
print("=== callers ===")
with open(RUN, encoding="utf-8") as f:
    run_src = f.read()
with open(os.path.join(BIN, "pervio-approve"), encoding="utf-8") as f:
    appr_src = f.read()
check("W15 no start hook in pervio-run, no watcher call in pervio-approve (the loop needs only the finish hook)",
      "--event start" not in run_src and "_tell_watcher" not in appr_src)

shutil.rmtree(home, ignore_errors=True)
ok = all(results)
print("\n=== pervio-group watch: %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
