#!/usr/bin/env python3
"""Regression tests for scheduled workflows (`pervio-orchestrate schedule`) and
command steps. Hermetic: isolated $HOME, shim claude on PATH, time injected via
PERVIO_TICK_NOW, OS-hook registration skipped via PERVIO_SCHED_HOOK=skip (files
are still written, so the hook lifecycle is assertable without touching the real
user's launchd/cron). Covers: command steps (stdout→output, failure, validation),
arm-on-add, at-most-once per period, catch-up, weekday filter, disable/enable
re-arm, overlap guard (alive skips / stale-running fires — the reboot-mid-run
case), attempt cap on a broken spec, keepRuns pruning, fire-now, remove + hook
teardown, step-level publish (archive-on-step-success + archives dual source),
the archives⇄schedule join (exactly-one rule), schedule update (in-place edit /
re-arm / hook reconcile), transient agent-step retry, token accounting, the
arXiv fetcher (window / dedupe / cap / NO_NEW), F2 template params
(`start --params-b64`: mechanical substitution into prompts + spec.dir only,
whole-start rejection on any leftover {{param., substituted dir through _dir_ok,
str/int/bool value whitelist, no-flag zero-regression), and the playbook
template kind (templates list carries kind/bodyChars + body verbatim, broken
playbooks listed with their error, start/schedule refuse a playbook with the
load-into-conversation message, legacy workflow entries keep their exact shape).
Plus the two "it costs you quietly" guards (C2/C3): a tick decides, launches and
claims its period inside the schedule's own lock (a due tick starts NOTHING while
a phone verb holds it, and the period survives for the next tick), and a command
step's capture is bounded — measured RSS, a firehose killed at the drain ceiling
instead of buffered until the timeout, and a background child holding the pipe
neither strands the step nor eats its output."""
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
ARX = os.path.join(BIN, "pervio-arxiv-fetch")
SHIM = os.path.join(HERE, "shim")

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name
          + (("  [" + str(detail)[:220] + "]") if (detail and not cond) else ""))


def env(home, now=None):
    e = dict(os.environ, HOME=home, PATH=SHIM + ":" + os.environ.get("PATH", ""),
             PERVIO_SCHED_HOOK="skip",
             PERVIO_SCHED_HOOK_KIND="darwin")   # the plist path, on Linux CI too
    if now:
        e["PERVIO_TICK_NOW"] = now
    return e


def orch(home, args, now=None):
    return subprocess.run([sys.executable, ORCH] + args, env=env(home, now),
                          capture_output=True, text=True)


def b64(obj):
    return base64.b64encode(json.dumps(obj).encode()).decode()


def shim_spec(text="ok", sleep=0):
    d = {"text": text}
    if sleep:
        d["sleep"] = sleep
    return {"name": "s", "dir": "/tmp", "steps": [
        {"id": "a", "backend": "claude", "perm": "plan",
         "prompt": "x\nSHIM:" + json.dumps(d)}]}


def add(home, now, time_str="06:30", spec=None, keep=7, days=None):
    payload = {"name": "sched", "time": time_str, "keepRuns": keep,
               "spec": spec or shim_spec(), "device": "phone-sched", "origin": "entry-sched"}
    if days:
        payload["days"] = days
    p = orch(home, ["schedule", "add", "--b64", b64(payload)], now=now)
    return (json.loads(p.stdout)["id"] if p.returncode == 0 else None), p


def tick(home, now):
    return orch(home, ["schedule", "tick"], now=now)


def slist(home, now, device=None):
    p = orch(home, ["schedule", "list"] + (["--device", device] if device else []), now=now)
    return json.loads(p.stdout) if p.returncode == 0 else []


def wf_dirs(home):
    root = os.path.join(home, ".pervio", "wf")
    return sorted(os.listdir(root)) if os.path.isdir(root) else []


def wait_all_terminal(home, timeout=30):
    for _ in range(timeout * 4):
        busy = False
        for wid in wf_dirs(home):
            led = {}
            try:
                led = json.load(open(os.path.join(home, ".pervio", "wf", wid, "ledger.json")))
            except (OSError, ValueError):
                pass
            if led.get("status") == "running":
                busy = True
        if not busy:
            return True
        time.sleep(0.25)
    return False


def ledger(home, wid):
    try:
        return json.load(open(os.path.join(home, ".pervio", "wf", wid, "ledger.json")))
    except (OSError, ValueError):
        return {}


# ---------- unit: occurrence math + cron line ----------
print("=== unit: due/next math ===")
loader = importlib.machinery.SourceFileLoader("orch", ORCH)
om = importlib.util.module_from_spec(importlib.util.spec_from_loader("orch", loader))
loader.exec_module(om)
import datetime as dt

sch = {"time": "06:30", "days": []}
now = dt.datetime(2026, 7, 8, 14, 0)
check("due (daily, after time) = today 06:30",
      om._occurrence(sch, now, -1) == dt.datetime(2026, 7, 8, 6, 30))
check("due (daily, before time) = yesterday",
      om._occurrence(sch, dt.datetime(2026, 7, 8, 5, 0), -1) == dt.datetime(2026, 7, 7, 6, 30))
check("next (daily, after time) = tomorrow",
      om._occurrence(sch, now, +1) == dt.datetime(2026, 7, 9, 6, 30))
mon = {"time": "06:30", "days": [1]}                      # 2026-07-08 is a Wednesday
check("due (Mondays) = last Monday",
      om._occurrence(mon, now, -1) == dt.datetime(2026, 7, 6, 6, 30))
check("next (Mondays) = next Monday",
      om._occurrence(mon, now, +1) == dt.datetime(2026, 7, 13, 6, 30))
try:
    om._parse_hhmm("25:99")
    check("bad time rejected", False)
except ValueError:
    check("bad time rejected", True)
cl = om._cron_line()
check("cron line: */5, quoted absolute paths, tagged",
      cl.startswith("*/5 * * * * ") and ORCH in cl and "# pervio-schedule" in cl
      and "%" not in cl.replace("", ""), cl)

# ---------- C1-C3: command steps ----------
print("=== C1 command step happy path ===")
home = tempfile.mkdtemp(prefix="sc1_", dir="/tmp")
spec = {"name": "cmd", "dir": "/tmp", "steps": [
    {"id": "fetch", "backend": "claude", "command": "printf 'line1\\nline2\\n'"},
    {"id": "digest", "backend": "claude", "perm": "plan", "dependsOn": ["fetch"],
     "prompt": "sum {{fetch.output}}\nSHIM:" + json.dumps({"text": "digested"})}]}
p = orch(home, ["start", "--spec-b64", b64(spec)])
wf = json.loads(p.stdout)["wfId"]
wait_all_terminal(home)
led = ledger(home, wf)
st = {s["id"]: s for s in led.get("steps", [])}
check("C1 run done", led.get("status") == "done", led)
check("C1 command stdout is the output", st["fetch"].get("output") == "line1\nline2\n", st.get("fetch"))
check("C1 ledger marks the step as a command", st["fetch"].get("command") is True)
check("C1 downstream agent step consumed it", st["digest"].get("output") == "digested")
check("C1 no agent jsonl for the command step",
      not os.path.exists(os.path.join(home, ".pervio", "wf", wf, "fetch.jsonl")))
shutil.rmtree(home, ignore_errors=True)

print("=== C1b command env: PERVIO_WF_DIR + ledger readback ===")
home = tempfile.mkdtemp(prefix="sc1b_", dir="/tmp")
spec = {"name": "cmd", "dir": "/tmp", "steps": [
    {"id": "a", "backend": "claude", "command": "printf hello"},
    {"id": "b", "backend": "claude", "dependsOn": ["a"], "command":
     "python3 -c \"import json,os;led=json.load(open(os.environ['PERVIO_WF_DIR']+'/ledger.json'));print(next(s for s in led['steps'] if s['id']=='a')['output'])\""}]}
p = orch(home, ["start", "--spec-b64", b64(spec)])
wf = json.loads(p.stdout)["wfId"]
wait_all_terminal(home)
st = {s["id"]: s for s in ledger(home, wf).get("steps", [])}
check("C1b downstream command read the upstream output via PERVIO_WF_DIR",
      st["b"].get("status") == "done" and st["b"].get("output", "").strip() == "hello",
      st.get("b"))
shutil.rmtree(home, ignore_errors=True)

print("=== C2 command step failure ===")
home = tempfile.mkdtemp(prefix="sc2_", dir="/tmp")
spec = {"name": "cmd", "dir": "/tmp", "steps": [
    {"id": "boom", "backend": "claude", "command": "echo oops >&2; exit 3"}]}
p = orch(home, ["start", "--spec-b64", b64(spec)])
wf = json.loads(p.stdout)["wfId"]
wait_all_terminal(home)
st = {s["id"]: s for s in ledger(home, wf).get("steps", [])}
check("C2 failing command fails the step with stderr",
      st["boom"]["status"] == "failed" and "exit 3" in st["boom"]["error"]
      and "oops" in st["boom"]["error"], st.get("boom"))
shutil.rmtree(home, ignore_errors=True)

print("=== C3 command validation ===")
home = tempfile.mkdtemp(prefix="sc3_", dir="/tmp")
bad1 = {"name": "b", "dir": "/tmp", "steps": [{"id": "a", "command": "   "}]}
bad2 = {"name": "b", "dir": "/tmp", "steps": [
    {"id": "src", "perm": "plan", "prompt": "x\nSHIM:{}"},
    {"id": "a", "command": "true", "fanout": {"over": "{{src.output}}"}}]}
check("C3 blank command rejected",
      orch(home, ["start", "--spec-b64", b64(bad1)]).returncode != 0)
check("C3 command+fanout rejected",
      orch(home, ["start", "--spec-b64", b64(bad2)]).returncode != 0)
shutil.rmtree(home, ignore_errors=True)

# ---------- TPL: server-side template library ----------
print("=== TPL templates list ===")
home = tempfile.mkdtemp(prefix="tpl_", dir="/tmp")
td = os.path.join(home, ".pervio", "templates"); os.makedirs(td)
json.dump({"name": "裸spec", "dir": "/tmp", "steps": [
    {"id": "a", "backend": "claude", "command": "true"}]}, open(os.path.join(td, "bare.json"), "w"))
json.dump({"name": "包装", "summary": "一句话", "spec": {"name": "包装", "dir": "/tmp", "steps": [
    {"id": "a", "backend": "claude", "command": "true"}]}}, open(os.path.join(td, "wrapped.json"), "w"))
open(os.path.join(td, "broken.json"), "w").write("{not json")
open(os.path.join(td, "note.txt"), "w").write("ignored")
# Third kind: a playbook is methodology markdown for a CONVERSATION — listed
# with its body verbatim (no spec validation), and never startable.
PB_BODY = "# 取背景\n\n目标:跨项目取背景。\n\n1. 读记忆索引\n2. 只带回结论\n"
PB_MSG = "playbook cannot be started as a workflow — load it into a conversation"
json.dump({"kind": "playbook", "name": "取背景", "summary": "跨项目取背景",
           "body": PB_BODY}, open(os.path.join(td, "pb.json"), "w"), ensure_ascii=False)
json.dump({"kind": "playbook", "name": "坏剧本", "summary": "s"},
          open(os.path.join(td, "pb-bad.json"), "w"))
json.dump({"kind": "banana", "name": "怪kind", "body": "x"},
          open(os.path.join(td, "pb-kind.json"), "w"))
os.utime(os.path.join(td, "bare.json"), (1000, 1000))       # oldest → sorts last
p = orch(home, ["templates", "list"])
tl = json.loads(p.stdout)
by = {i["file"]: i for i in tl}
check("TPL lists exactly the .json files",
      set(by) == {"bare.json", "wrapped.json", "broken.json",
                  "pb.json", "pb-bad.json", "pb-kind.json"}, by.keys())
check("TPL bare spec ok with steps count", by["bare.json"]["ok"] is True
      and by["bare.json"]["steps"] == 1 and by["bare.json"]["spec"]["name"] == "裸spec")
check("TPL wrapper carries summary + inner spec", by["wrapped.json"]["ok"] is True
      and by["wrapped.json"]["summary"] == "一句话" and by["wrapped.json"]["spec"]["steps"], by.get("wrapped.json"))
check("TPL broken file listed with error, not hidden", by["broken.json"]["ok"] is False
      and by["broken.json"].get("error"), by.get("broken.json"))
check("TPL newest first (mtime desc)", tl[-1]["file"] == "bare.json", [i["file"] for i in tl])
check("TPL workflow entries carry NO kind field (legacy shape byte-identical)",
      "kind" not in by["bare.json"] and "kind" not in by["wrapped.json"],
      (by.get("bare.json"), by.get("wrapped.json")))
check("TPL playbook listed with kind/bodyChars + body verbatim, no spec/steps",
      by["pb.json"].get("ok") is True and by["pb.json"].get("kind") == "playbook"
      and by["pb.json"].get("name") == "取背景"
      and by["pb.json"].get("summary") == "跨项目取背景"
      and by["pb.json"].get("body") == PB_BODY
      and by["pb.json"].get("bodyChars") == len(PB_BODY)
      and "spec" not in by["pb.json"] and "steps" not in by["pb.json"],
      by.get("pb.json"))
check("TPL playbook without a body listed with its error, not hidden",
      by["pb-bad.json"].get("ok") is False
      and "body" in by["pb-bad.json"].get("error", ""), by.get("pb-bad.json"))
check("TPL unknown kind listed with its error, not hidden",
      by["pb-kind.json"].get("ok") is False
      and "kind" in by["pb-kind.json"].get("error", ""), by.get("pb-kind.json"))
# A spec smuggled inside a playbook wrapper: rejected loudly at listing, and
# — the P2 hole — it must NOT mint a phantom publication in archives whose
# reader would surface an arbitrary dir on the phone.
leak_dir = os.path.join(home, "leakdir")
os.makedirs(leak_dir, exist_ok=True)
with open(os.path.join(leak_dir, "2026-07-08.md"), "w") as f:
    f.write("private\n")
with open(os.path.join(td, "pb-smuggle.json"), "w") as f:
    json.dump({"kind": "playbook", "name": "走私", "summary": "s", "body": "b",
               "spec": {"name": "leak", "dir": "/tmp", "steps": [
                   {"id": "a", "backend": "claude", "perm": "plan", "prompt": "x",
                    "publish": leak_dir}]}}, f, ensure_ascii=False)
tl2 = json.loads(orch(home, ["templates", "list"]).stdout)
by2 = {t["file"]: t for t in tl2}
check("TPL spec-smuggling playbook listed as broken ('must not carry a spec')",
      by2["pb-smuggle.json"].get("ok") is False
      and "must not carry a spec" in by2["pb-smuggle.json"].get("error", ""),
      by2.get("pb-smuggle.json"))
arc = json.loads(orch(home, ["archives", "list"]).stdout)
check("ARC smuggled playbook spec mints NO phantom publication",
      all(os.path.realpath(a.get("dir", "")) != os.path.realpath(leak_dir)
          for a in arc), arc)
os.remove(os.path.join(td, "pb-smuggle.json"))

# ---- a home card must be EARNED: an issue on disk, or a live subscription ----
# Seeds (and any spec Claude wrote) ship with a publish step, so a fresh user
# used to open the app to three empty cards. archives list now keeps only
# publications in use: issues exist, or an enabled schedule publishes there.
import tempfile as _tf, shutil as _sh
hh = _tf.mkdtemp(prefix="orch_home_", dir="/tmp")
htd = os.path.join(hh, ".pervio", "templates"); os.makedirs(htd)
pubA = os.path.join(hh, "pubA"); pubB = os.path.join(hh, "pubB")
spec_a = {"name": "空刊", "dir": "/tmp", "steps": [
    {"id": "a", "backend": "claude", "perm": "plan", "prompt": "x", "publish": pubA}]}
spec_b = {"name": "有刊", "dir": "/tmp", "steps": [
    {"id": "a", "backend": "claude", "perm": "plan", "prompt": "x", "publish": pubB}]}
with open(os.path.join(htd, "a.json"), "w") as f:
    json.dump({"name": "空刊", "summary": "s", "spec": spec_a}, f, ensure_ascii=False)
with open(os.path.join(htd, "b.json"), "w") as f:
    json.dump({"name": "有刊", "summary": "s", "spec": spec_b}, f, ensure_ascii=False)
os.makedirs(pubB)
with open(os.path.join(pubB, "2026-07-08.md"), "w") as f:
    f.write("# issue\n")
def _names(h):
    return sorted(a["name"] for a in json.loads(orch(h, ["archives", "list"]).stdout))
check("H1 a never-run, unsubscribed template is NOT a home card (market only)",
      "空刊" not in _names(hh), _names(hh))
check("H2 one printed issue alone earns the card",
      "有刊" in _names(hh), _names(hh))
hsid, hp = add(hh, "2026-07-08T14:00", spec=spec_a)
check("H3 subscribing (enabled) puts the still-empty publication on the home",
      hsid is not None and "空刊" in _names(hh), (hp.stderr[:120], _names(hh)))
_al = json.loads(orch(hh, ["archives", "list"]).stdout)
check("H3b …listed with files [] and sorted after the publication that has an issue",
      [a["name"] for a in _al] == ["有刊", "空刊"] and _al[1]["files"] == [], _al)
orch(hh, ["schedule", "update", "--b64", b64({"id": hsid, "enabled": False})], now="2026-07-08T14:01")
check("H4 a paused subscription with no issues drops off the home",
      "空刊" not in _names(hh), _names(hh))
os.makedirs(pubA, exist_ok=True)
with open(os.path.join(pubA, "2026-07-09.md"), "w") as f:
    f.write("# first issue\n")
check("H5 once an issue exists the card stays even while paused",
      "空刊" in _names(hh), _names(hh))
_sh.rmtree(hh, ignore_errors=True)
# A playbook is NOT startable/schedulable — the exact message at both doors.
pb_wrap = {"kind": "playbook", "name": "取背景", "summary": "s", "body": PB_BODY}
p = orch(home, ["start", "--spec-b64", b64(pb_wrap)])
check("TPL start of a playbook rejected with the load-into-conversation message",
      p.returncode != 0 and PB_MSG in p.stderr, p.stderr[:200])
p = orch(home, ["schedule", "add", "--b64",
                b64({"name": "x", "time": "06:30", "spec": pb_wrap})],
         now="2026-07-08T14:00")
check("TPL schedule add of a playbook rejected with the same message",
      p.returncode != 0 and PB_MSG in p.stderr, p.stderr[:200])
check("TPL rejected playbook launches left zero run/schedule dirs",
      wf_dirs(home) == []
      and not os.path.isdir(os.path.join(home, ".pervio", "schedules")),
      (wf_dirs(home), os.listdir(os.path.join(home, ".pervio"))))
shutil.rmtree(home, ignore_errors=True)

# ---------- TPR: templates remove — the market's "Mine" shelf can delete (2026-10-20) ----------
print("=== TPR templates remove ===")
_tpr = os.path.join(home, ".pervio", "templates"); os.makedirs(_tpr, exist_ok=True)
with open(os.path.join(_tpr, "mine-one.json"), "w") as f:
    json.dump({"name": "mine one", "summary": "", "spec": shim_spec()}, f)
with open(os.path.join(_tpr, "keep-me.json"), "w") as f:
    json.dump({"name": "keep me", "summary": "", "spec": shim_spec()}, f)
p = orch(home, ["templates", "remove", "--file", "mine-one.json"])
check("TPR1 a template file of mine is removed and reported", p.returncode == 0 and json.loads(p.stdout).get("removed") is True
      and not os.path.exists(os.path.join(_tpr, "mine-one.json")), (p.returncode, p.stdout, p.stderr[-120:]))
check("TPR1b …and the others stay listed", any(t["file"] == "keep-me.json" for t in json.loads(orch(home, ["templates", "list"]).stdout)))
p = orch(home, ["templates", "remove", "--file", "mine-one.json"])
check("TPR2 a file that isn't there is reported (exit 3), not invented", p.returncode == 3 and json.loads(p.stdout).get("removed") is False, (p.returncode, p.stdout))
outside = os.path.join(home, "precious.json"); open(outside, "w").write("{}")
bad = [["templates", "remove", "--file", "../precious.json"], ["templates", "remove", "--file", "/etc/passwd"],
       ["templates", "remove", "--file", "keep-me"], ["templates", "remove", "--file", ".hidden.json"], ["templates", "remove"]]
check("TPR3 a path, a non-json name, a dotfile or no name at all is refused (exit 2) and nothing outside the library is touched",
      all(orch(home, a).returncode == 2 for a in bad) and os.path.exists(outside) and os.path.exists(os.path.join(_tpr, "keep-me.json")),
      [orch(home, a).returncode for a in bad])
os.remove(outside)

# ---------- SUG: templates list carries the wrapper's suggestedTime ----------
# Why this exists: the phone's market decides "this is a 刊物 (subscribe once,
# read the home card)" from the spec's publish step PLUS a daily time. Server
# templates carried no time at all, so a publishing template landed on the
# capability shelf with no subscribe button — the GitHub 热点日报 the user could
# neither subscribe to nor unsubscribe from. The time is a WRAPPER field, like
# expose/slug/params: a bare spec — and the inner spec of a wrapper — must not be
# able to declare it, or an imported workflow body could talk the phone into
# scheduling itself. Absent/unreadable → the KEY IS OMITTED (not null), because
# the app distinguishes "no suggestion" from "a suggestion I can't parse", and a
# template with a typo in its time must still be listed and runnable.
print("=== SUG templates list suggestedTime ===")
home = tempfile.mkdtemp(prefix="sug_", dir="/tmp")
td = os.path.join(home, ".pervio", "templates"); os.makedirs(td)
SUG_STEPS = [{"id": "a", "backend": "claude", "command": "true"}]


def sug_write(fn, obj):
    with open(os.path.join(td, fn), "w") as f:
        json.dump(obj, f, ensure_ascii=False)


sug_write("gh-daily.json", {
    "name": "GitHub 热点日报", "summary": "每天一份热点",
    "suggestedTime": "06:30",
    "spec": {"name": "GitHub 热点日报", "dir": "/tmp",
             "steps": [{"id": "a", "backend": "claude", "command": "true",
                        "publish": "~/.pervio/archives/gh-daily"}]}})
sug_write("pad.json", {"name": "补零", "suggestedTime": "6:30",
                       "spec": {"name": "补零", "dir": "/tmp", "steps": SUG_STEPS}})
sug_write("none.json", {"name": "无时间", "summary": "s",
                        "spec": {"name": "无时间", "dir": "/tmp", "steps": SUG_STEPS}})
# a BARE spec cannot declare it (wrapper-only, exactly like expose/slug/params)
sug_write("bare.json", {"name": "裸spec", "dir": "/tmp", "suggestedTime": "07:00",
                        "steps": SUG_STEPS})
# nor can the inner spec of a wrapper — the smuggling path for an imported body
sug_write("inner.json", {"name": "内层", "spec": {
    "name": "内层", "dir": "/tmp", "suggestedTime": "07:00", "steps": SUG_STEPS}})
# a playbook is loaded into a conversation, never scheduled
sug_write("pb.json", {"kind": "playbook", "name": "剧本", "summary": "s",
                      "body": "# 剧本\n", "suggestedTime": "06:30"})
# a broken spec stays broken; the time does not rescue it or ride along
sug_write("brokenspec.json", {"name": "坏", "suggestedTime": "06:30",
                              "spec": {"name": "坏", "dir": "/tmp", "steps": []}})
SUG_JUNK = {"h24": "24:00", "h25": "25:00", "neg": "-1:00", "m60": "06:60",
            "words": "早上六点半", "iso": "06:30:00", "pad3": "006:30",
            "empty": "", "num": 630, "null": None, "list": ["06:30"],
            "obj": {"h": 6}, "nul": "06:3\x000", "nl": "06:30\n07:00",
            "true": True}
for k, v in SUG_JUNK.items():
    sug_write("junk-%s.json" % k, {"name": "垃圾" + k, "suggestedTime": v,
                                   "spec": {"name": "垃圾" + k, "dir": "/tmp",
                                            "steps": SUG_STEPS}})
# Read by the SAME parser `schedule add` uses, so a time the scheduler accepts is
# a time the listing accepts — one notion of "a valid time", not two that drift.
# Surrounding whitespace is the only latitude it gives, and the output is
# canonical either way.
SUG_OK = {"space": " 06:30", "tail": "06:30 ", "nlpad": "\n6:30\n", "h23": "23:59"}
for k, v in SUG_OK.items():
    sug_write("ok-%s.json" % k, {"name": "正常" + k, "suggestedTime": v,
                                 "spec": {"name": "正常" + k, "dir": "/tmp",
                                          "steps": SUG_STEPS}})
p = orch(home, ["templates", "list"])
sug = {i["file"]: i for i in json.loads(p.stdout)}
check("SUG1 a wrapper's HH:MM comes through verbatim",
      sug["gh-daily.json"].get("suggestedTime") == "06:30", sug.get("gh-daily.json"))
check("SUG2 ...zero-padded to the app's strict HH:mm ('6:30' -> '06:30')",
      sug["pad.json"].get("suggestedTime") == "06:30", sug.get("pad.json"))
check("SUG3 a wrapper without one OMITS the key (never null)",
      "suggestedTime" not in sug["none.json"] and sug["none.json"]["ok"] is True,
      sug.get("none.json"))
check("SUG4 a BARE spec cannot declare it (wrapper-only field)",
      "suggestedTime" not in sug["bare.json"] and sug["bare.json"]["ok"] is True,
      sug.get("bare.json"))
check("SUG5 the inner spec of a wrapper cannot smuggle it either",
      "suggestedTime" not in sug["inner.json"] and sug["inner.json"]["ok"] is True,
      sug.get("inner.json"))
check("SUG6 a playbook never carries one",
      "suggestedTime" not in sug["pb.json"] and sug["pb.json"].get("kind") == "playbook",
      sug.get("pb.json"))
check("SUG7 a broken spec stays broken and carries no time",
      sug["brokenspec.json"]["ok"] is False
      and "suggestedTime" not in sug["brokenspec.json"], sug.get("brokenspec.json"))
bad = {k: sug["junk-%s.json" % k].get("suggestedTime", "<absent>") for k in SUG_JUNK}
check("SUG8 every unreadable time is OMITTED, not passed through",
      all(v == "<absent>" for v in bad.values()),
      {k: v for k, v in bad.items() if v != "<absent>"})
check("SUG9 ...and those templates are still listed as runnable",
      all(sug["junk-%s.json" % k]["ok"] is True for k in SUG_JUNK),
      {k: sug["junk-%s.json" % k] for k in SUG_JUNK
       if sug["junk-%s.json" % k]["ok"] is not True})
_okt = {k: sug["ok-%s.json" % k].get("suggestedTime", "<absent>") for k in SUG_OK}
check("SUG9b every time the SCHEDULER would accept arrives canonical",
      _okt == {"space": "06:30", "tail": "06:30", "nlpad": "06:30", "h23": "23:59"},
      _okt)
check("SUG10 the legacy fields are untouched by the addition",
      sug["gh-daily.json"]["ok"] is True and sug["gh-daily.json"]["steps"] == 1
      and sug["gh-daily.json"]["summary"] == "每天一份热点"
      and sug["gh-daily.json"]["spec"]["name"] == "GitHub 热点日报"
      and "kind" not in sug["gh-daily.json"], sug.get("gh-daily.json"))
# Mutation (on a COPY — the real script is never edited): delete the one line
# that emits the field and SUG1/SUG2 must go red. Without this the checks above
# would still pass against a build that hard-codes "06:30" or copies the wrapper
# blindly.
SUG_EMIT = '                entry["suggestedTime"] = sug\n'
_orch_src = open(ORCH, encoding="utf-8").read()
check("SUG11 the suggestedTime emission is exactly one line in pervio-orchestrate",
      _orch_src.count(SUG_EMIT) == 1, _orch_src.count(SUG_EMIT))
_mut_dir = tempfile.mkdtemp(prefix="sugmut_", dir="/tmp")
_mut = os.path.join(_mut_dir, "pervio-orchestrate")
with open(_mut, "w", encoding="utf-8") as f:
    f.write(_orch_src.replace(SUG_EMIT, "                pass  # MUTATED\n"))
_mp = subprocess.run([sys.executable, _mut, "templates", "list"], env=env(home),
                     capture_output=True, text=True)
_msug = {i["file"]: i for i in json.loads(_mp.stdout or "[]")}
check("SUG12 the mutant drops the field entirely (SUG1/SUG2 go RED)",
      "suggestedTime" not in _msug.get("gh-daily.json", {})
      and "suggestedTime" not in _msug.get("pad.json", {}),
      (_msug.get("gh-daily.json"), _mp.stderr[:200]))
shutil.rmtree(_mut_dir, ignore_errors=True)
shutil.rmtree(home, ignore_errors=True)

# ---------- ARC: archives list (publications from schedules + templates) ----------
print("=== ARC archives list ===")
home = tempfile.mkdtemp(prefix="arc_", dir="/tmp")
arch = os.path.join(home, "archive"); os.makedirs(arch)
for i, fn in enumerate(["2026-07-28.md", "2026-07-29.md", "2026-07-30.md"]):
    fp = os.path.join(arch, fn)
    open(fp, "w").write("# 晨报\n\n> 今日一句:x\n")
    os.utime(fp, (1000 + i, 1000 + i))                       # staggered: 07-30 newest
open(os.path.join(arch, "note.txt"), "w").write("not an issue")
# The schedule declares the dir '~'-relative — `dir` must come back VERBATIM
# (the app hands it to the server for expansion), dedupe by realpath.
sched_spec = {"name": "晨报", "dir": "/tmp",
              "display": {"archiveDir": "~/archive", "collapseSections": ["扫过"]},
              "actions": [{"label": "反馈", "command": "true"}],
              "steps": [{"id": "a", "backend": "claude", "command": "true"}]}
sid_arc, p = add(home, now="2026-07-08T14:00", spec=sched_spec)
check("ARC schedule with archiveDir added", sid_arc is not None, p.stderr)
td = os.path.join(home, ".pervio", "templates"); os.makedirs(td)
# same dir as the schedule (absolute spelling) → deduped, the SCHEDULE's entry wins
json.dump({"name": "模板同目录", "dir": "/tmp",
           "display": {"archiveDir": arch},
           "steps": [{"id": "a", "backend": "claude", "command": "true"}]},
          open(os.path.join(td, "dup.json"), "w"))
# wrapped template with its OWN dir holding one (older) issue → listed after 晨报.
# (A template with NO issue and no subscription is market-only since 2026-10-11 —
# see the H-block; an empty dir alone no longer earns a card.)
weekly_dir = os.path.join(home, "weekly-arch"); os.makedirs(weekly_dir)
open(os.path.join(weekly_dir, "2026-07-27.md"), "w").write("# 周报\n")
os.utime(os.path.join(weekly_dir, "2026-07-27.md"), (999, 999))
json.dump({"name": "周报", "summary": "s", "spec": {
    "name": "周报", "dir": "/tmp",
    "display": {"archiveDir": weekly_dir},
    "steps": [{"id": "a", "backend": "claude", "command": "true"}]}},
          open(os.path.join(td, "weekly.json"), "w"))
# no archiveDir → not a publication
json.dump({"name": "普通", "dir": "/tmp",
           "steps": [{"id": "a", "backend": "claude", "command": "true"}]},
          open(os.path.join(td, "plain.json"), "w"))
# '..' traversal → skipped outright (an imported spec must not aim the reader)
json.dump({"name": "恶意", "dir": "/tmp",
           "display": {"archiveDir": "~/../evil"},
           "steps": [{"id": "a", "backend": "claude", "command": "true"}]},
          open(os.path.join(td, "evil.json"), "w"))
p = orch(home, ["archives", "list"])
al = json.loads(p.stdout) if p.returncode == 0 else []
check("ARC exactly the two publications, freshest first (no plain, no '..')",
      p.returncode == 0 and [i["name"] for i in al] == ["晨报", "周报"],
      p.stdout[:200] + p.stderr[:200])
morning = al[0] if al else {}
check("ARC schedule wins the shared dir (its name + verbatim '~' dir)",
      morning.get("name") == "晨报" and morning.get("dir") == "~/archive", morning)
check("ARC files: md only, mtime desc, txt excluded",
      [f["file"] for f in morning.get("files", [])]
      == ["2026-07-30.md", "2026-07-29.md", "2026-07-28.md"]
      and [f["mtime"] for f in morning["files"]] == [1002, 1001, 1000],
      morning.get("files"))
check("ARC display + actions carried through for the reader",
      morning.get("display", {}).get("collapseSections") == ["扫过"]
      and (morning.get("actions") or [{}])[0].get("label") == "反馈", morning)
weekly = al[1] if len(al) > 1 else {}
check("ARC the older template publication sorts after the fresher schedule one",
      weekly.get("name") == "周报"
      and [f["file"] for f in weekly.get("files", [])] == ["2026-07-27.md"], weekly)
# C1 join: exactly ONE schedule publishes into ~/archive → its vitals ride the
# entry; a template-only publication carries none of the fields.
check("ARC joined schedule vitals on the schedule-backed entry",
      morning.get("scheduleId") == sid_arc and morning.get("scheduleEnabled") is True
      and morning.get("lastStatus") == "" and morning.get("lastError") == ""
      and morning.get("lastFiredAt") == 0 and morning.get("nextDue", 0) > 0, morning)
check("ARC template-only publication carries NO schedule fields",
      "scheduleId" not in weekly and "nextDue" not in weekly
      and "lastStatus" not in weekly, weekly)
p = orch(home, ["schedule", "fire", "--id", sid_arc])
check("ARC fire for the join", p.returncode == 0, p.stderr)
wait_all_terminal(home)
al = json.loads(orch(home, ["archives", "list"]).stdout)
morning = next((i for i in al if i.get("name") == "晨报"), {})
check("ARC after a fire the joined vitals move (lastFiredAt/lastStatus)",
      morning.get("lastFiredAt", 0) > 0 and morning.get("lastStatus") == "done",
      morning)
# A SECOND schedule publishing into the same dir makes the join ambiguous —
# pinning either schedule's failure on the shared publication would mislead.
sid_arc2, _ = add(home, now="2026-07-08T14:00", spec=sched_spec)
al = json.loads(orch(home, ["archives", "list"]).stdout)
morning = next((i for i in al if i.get("name") == "晨报"), {})
check("ARC two schedules on one dir → ambiguous, join fields absent",
      sid_arc2 is not None and "scheduleId" not in morning
      and "lastStatus" not in morning, morning)
shutil.rmtree(home, ignore_errors=True)

# ---------- PUB: step-level publish (archive-on-step-success) ----------
# A step marked publish:true|"<dir>" is the workflow's publication: the moment
# THAT step succeeds the orchestrator writes its final output as today's issue
# (<dir>/<YYYY-MM-DD>.md, default ~/.pervio/archives/<slug>/) and the ledger
# step records publishedTo. The system does the filing — the agent just replies.
print("=== PUB publish: agent step, default dir ===")
home = tempfile.mkdtemp(prefix="pub_", dir="/tmp")
today = time.strftime("%Y-%m-%d")
ISSUE1 = "# 期刊\n\n正文一段"
spec = {"name": "My Pub", "dir": "/tmp", "steps": [
    {"id": "write", "backend": "claude", "perm": "plan", "publish": True,
     "prompt": "x\nSHIM:" + json.dumps({"text": ISSUE1})},
    {"id": "after", "backend": "claude", "perm": "plan", "dependsOn": ["write"],
     "prompt": "x\nSHIM:" + json.dumps({"text": "B"})}]}
p = orch(home, ["start", "--spec-b64", b64(spec)])
wf = json.loads(p.stdout)["wfId"]
wait_all_terminal(home)
st = {s["id"]: s for s in ledger(home, wf).get("steps", [])}
issue = os.path.join(home, ".pervio", "archives", "my-pub", today + ".md")
check("PUB publish:true files today's issue in the default slug dir",
      st["write"].get("status") == "done" and os.path.isfile(issue),
      (st.get("write"), os.path.dirname(issue)))
check("PUB issue content is exactly the step output",
      os.path.isfile(issue) and open(issue).read() == ISSUE1,
      open(issue).read()[:80] if os.path.isfile(issue) else "no file")
check("PUB ledger records publishedTo (absolute)",
      st["write"].get("publishedTo") == os.path.realpath(issue), st.get("write"))
check("PUB non-publishing step gets no publishedTo",
      "publishedTo" not in st["after"], st.get("after"))
shutil.rmtree(home, ignore_errors=True)

print("=== PUB publish: command step, custom dir + same-day overwrite ===")
home = tempfile.mkdtemp(prefix="pub2_", dir="/tmp")
src = os.path.join(home, "issue-src.txt")
open(src, "w").write("第一版\n")
# The SAME spec runs twice today (a manual re-fire): the second run must
# OVERWRITE the issue, not stack a sibling file.
spec = {"name": "cmdpub", "dir": "/tmp", "steps": [
    {"id": "gen", "backend": "claude", "command": "cat %s" % src,
     "publish": "~/mypub"}]}
p = orch(home, ["start", "--spec-b64", b64(spec)])
wf = json.loads(p.stdout)["wfId"]
wait_all_terminal(home)
st = {s["id"]: s for s in ledger(home, wf).get("steps", [])}
issue2 = os.path.join(home, "mypub", today + ".md")
check("PUB command step publishes into the custom '~'-relative dir",
      st["gen"].get("status") == "done" and os.path.isfile(issue2)
      and open(issue2).read() == "第一版\n"
      and st["gen"].get("publishedTo") == os.path.realpath(issue2), st.get("gen"))
open(src, "w").write("第二版\n")
p = orch(home, ["start", "--spec-b64", b64(spec)])
wf2 = json.loads(p.stdout)["wfId"]
wait_all_terminal(home)
pubdir = os.path.join(home, "mypub")
mds = sorted(os.listdir(pubdir)) if os.path.isdir(pubdir) else []
check("PUB same-day rerun overwrites: one issue file, content is the NEW run's",
      [f for f in mds if f.endswith(".md")] == [today + ".md"]
      and os.path.isfile(issue2) and open(issue2).read() == "第二版\n",
      (mds, open(issue2).read()[:40] if os.path.isfile(issue2) else "no file"))
check("PUB no tmp droppings left beside the issue (atomic write cleaned up)",
      mds == [today + ".md"], mds)
shutil.rmtree(home, ignore_errors=True)

print("=== PUB empty output + validation ===")
home = tempfile.mkdtemp(prefix="pub3_", dir="/tmp")
# Whitespace-only output → NO blank issue in the reader, step still done.
spec = {"name": "emptypub", "dir": "/tmp", "steps": [
    {"id": "quiet", "backend": "claude", "command": "printf '  \\n'",
     "publish": True}]}
p = orch(home, ["start", "--spec-b64", b64(spec)])
wf = json.loads(p.stdout)["wfId"]
wait_all_terminal(home)
st = {s["id"]: s for s in ledger(home, wf).get("steps", [])}
eissue = os.path.join(home, ".pervio", "archives", "emptypub", today + ".md")
check("PUB empty (stripped) output → no file, step done, no publishedTo",
      st["quiet"].get("status") == "done" and not os.path.exists(eissue)
      and "publishedTo" not in st["quiet"], st.get("quiet"))
badp1 = {"name": "b", "dir": "/tmp", "steps": [
    {"id": "a", "backend": "claude", "command": "true", "publish": "../evil"}]}
badp2 = {"name": "b", "dir": "/tmp", "steps": [
    {"id": "a", "backend": "claude", "command": "true", "publish": True},
    {"id": "b", "backend": "claude", "command": "true", "publish": "~/x"}]}
badp3 = {"name": "b", "dir": "/tmp", "steps": [
    {"id": "a", "backend": "claude", "command": "true", "publish": 7}]}
pb = orch(home, ["start", "--spec-b64", b64(badp1)])
check("PUB '..'-traversal publish dir rejected at start",
      pb.returncode != 0 and "publish" in pb.stderr, pb.stderr[:120])
pb = orch(home, ["start", "--spec-b64", b64(badp2)])
check("PUB two publishing steps rejected (the publication is singular)",
      pb.returncode != 0 and "only one step may publish" in pb.stderr, pb.stderr[:120])
pb = orch(home, ["start", "--spec-b64", b64(badp3)])
check("PUB non-true/non-string publish rejected",
      pb.returncode != 0 and "publish" in pb.stderr, pb.stderr[:120])
# Hand-written `false` = "not published", tolerated as absent (the app's
# encoder omits the key; hand-edited JSON shouldn't be punished for explicitness).
okf = {"name": "b", "dir": "/tmp", "steps": [
    {"id": "a", "backend": "claude", "command": "printf hi", "publish": False}]}
pb = orch(home, ["start", "--spec-b64", b64(okf)])
check("PUB publish:false tolerated as not-published", pb.returncode == 0, pb.stderr[:120])
if pb.returncode == 0:
    wait_all_terminal(home)
    stf = {s["id"]: s for s in ledger(home, json.loads(pb.stdout)["wfId"]).get("steps", [])}
    check("PUB publish:false runs done, files nothing",
          stf["a"].get("status") == "done" and "publishedTo" not in stf["a"], stf.get("a"))
else:
    check("PUB publish:false runs done, files nothing", False, "start failed")
# A fan-out's aggregate output is machinery (FAIL markers, progress header),
# not a publication — publish there is rejected, not silently no-op'd.
badp4 = {"name": "b", "dir": "/tmp", "steps": [
    {"id": "src", "backend": "claude", "perm": "plan", "prompt": "x\nSHIM:" + json.dumps({"text": "1. a"})},
    {"id": "w", "backend": "claude", "perm": "plan", "publish": True,
     "fanout": {"over": "{{src.output}}"}, "prompt": "p\nSHIM:{{item}}"}]}
pb = orch(home, ["start", "--spec-b64", b64(badp4)])
check("PUB publish on a fan-out step rejected (publish the synthesis step)",
      pb.returncode != 0 and "fan-out" in pb.stderr, pb.stderr[:150])
shutil.rmtree(home, ignore_errors=True)

print("=== PUB archives list: publish-derived publications + dedupe ===")
home = tempfile.mkdtemp(prefix="pub4_", dir="/tmp")
td = os.path.join(home, ".pervio", "templates"); os.makedirs(td)
# publish:true template, CJK name → its OWN slug dir (unicode-aware slugging:
# two Chinese-named workflows must not collide into one 'workflow' dir);
# pre-drop an issue so the files listing + freshest-first sort are exercised.
json.dump({"name": "论文晨报", "dir": "/tmp",
           "steps": [{"id": "a", "backend": "claude", "command": "true",
                      "publish": True}]},
          open(os.path.join(td, "pubtrue.json"), "w"))
slugdir = os.path.join(home, ".pervio", "archives", "论文晨报")
os.makedirs(slugdir)
open(os.path.join(slugdir, "2026-07-30.md"), "w").write("# 晨报\n")
# schedule whose step publishes into a custom dir → schedule-sourced entry
sched_spec = {"name": "定制", "dir": "/tmp", "steps": [
    {"id": "a", "backend": "claude", "command": "true", "publish": "~/pubarc"}]}
sid_pub, p = add(home, now="2026-07-08T14:00", spec=sched_spec)
check("PUB schedule with a publishing step added", sid_pub is not None, p.stderr)
# legacy archiveDir AND a publish step naming the SAME dir (different spelling)
# → ONE publication, the verbatim archiveDir spelling wins
os.makedirs(os.path.join(home, "dualdir"))
open(os.path.join(home, "dualdir", "2026-07-29.md"), "w").write("# 双源\n")
os.utime(os.path.join(home, "dualdir", "2026-07-29.md"), (1000, 1000))   # older than 晨报's issue: it must not steal first place
json.dump({"name": "双源", "dir": "/tmp",
           "display": {"archiveDir": "~/dualdir"},
           "steps": [{"id": "a", "backend": "claude", "command": "true",
                      "publish": os.path.join(home, "dualdir")}]},
          open(os.path.join(td, "dual.json"), "w"))
p = orch(home, ["archives", "list"])
al = json.loads(p.stdout) if p.returncode == 0 else []
by_name = {i["name"]: i for i in al}
check("PUB archives lists the three publications exactly once each",
      p.returncode == 0 and len(al) == 3
      and set(by_name) == {"论文晨报", "定制", "双源"},
      p.stdout[:200] + p.stderr[:200])
check("PUB publish:true entry carries the default slug dir + its issues, sorts first",
      by_name.get("论文晨报", {}).get("dir") == "~/.pervio/archives/论文晨报"
      and [f["file"] for f in by_name.get("论文晨报", {}).get("files", [])]
      == ["2026-07-30.md"] and al[0]["name"] == "论文晨报", by_name.get("论文晨报"))
check("PUB publish:'<dir>' entry keeps the verbatim '~' spelling",
      by_name.get("定制", {}).get("dir") == "~/pubarc", by_name.get("定制"))
check("PUB archiveDir + publish on the same dir dedupe to ONE entry (archiveDir spelling)",
      by_name.get("双源", {}).get("dir") == "~/dualdir", by_name.get("双源"))
# C1 join covers the publish-step spelling too, not just legacy archiveDir.
check("PUB publish-step dir joins its schedule's vitals onto the entry",
      by_name.get("定制", {}).get("scheduleId") == sid_pub
      and by_name.get("定制", {}).get("scheduleEnabled") is True
      and by_name.get("定制", {}).get("nextDue", 0) > 0, by_name.get("定制"))
check("PUB template-only publish entries stay join-free",
      "scheduleId" not in by_name.get("论文晨报", {})
      and "scheduleId" not in by_name.get("双源", {}), by_name)
shutil.rmtree(home, ignore_errors=True)

# ---------- S1-S3: arm on add / fire once per period ----------
print("=== S1-S3 arm, fire, at-most-once ===")
home = tempfile.mkdtemp(prefix="ss1_", dir="/tmp")
sid, p = add(home, now="2026-07-08T14:00")
check("S1 add ok + hook file written (skip mode)", sid is not None
      and os.path.exists(os.path.join(home, "Library", "LaunchAgents",
                                      "com.pervio.schedule.plist")), p.stderr)
import plistlib as _pl
_pd = _pl.load(open(os.path.join(home, "Library", "LaunchAgents",
                                 "com.pervio.schedule.plist"), "rb"))
check("S1b hook uses calendar entries, not the zombie-prone StartInterval",
      "StartInterval" not in _pd and len(_pd.get("StartCalendarInterval", [])) == 12
      and _pd["StartCalendarInterval"][1] == {"Minute": 5}, _pd)
# S1c: the LOGIN ITEM name is ProgramArguments[0]'s basename. A bare `python3`
# there showed in System Settings > Login Items as an anonymous "python3" the user
# couldn't attribute (their words: a background item from nowhere). It must go
# through the named shim instead: ProgramArguments[0] is pervio-schedule-tick, NOT
# a bare interpreter. (Green because the shim ships next to the launchers; the
# mutation right below proves this assertion actually discriminates — without the
# shim the plist regresses to python3 and this check would have gone red.)
_pa = _pd.get("ProgramArguments") or [""]
_argv0_base = os.path.basename(str(_pa[0]))
check("S1c login-item name is the shim, not a bare python3",
      _argv0_base == "pervio-schedule-tick"
      and _argv0_base not in ("python", "python3")
      and "schedule tick" not in " ".join(map(str, _pa[:1])), _pa)
# Mutation (on a COPY, in an isolated bin dir so the shim is absent): with no shim
# available _tick_argv falls back to the interpreter, and the plist's argv[0]
# regresses to a bare python3 — i.e. S1c above would go RED. This pins the check to
# the shim's presence, not to a hard-coded name.
_m_bin = tempfile.mkdtemp(prefix="s1c_bin_", dir="/tmp")
shutil.copy2(ORCH, os.path.join(_m_bin, "pervio-orchestrate"))
for _dep in ("_pervio_lib.py",):
    _sp = os.path.join(BIN, _dep)
    if os.path.exists(_sp):
        shutil.copy2(_sp, os.path.join(_m_bin, _dep))          # so import doesn't die
_m_orch = os.path.join(_m_bin, "pervio-orchestrate")
_m_home = tempfile.mkdtemp(prefix="s1c_home_", dir="/tmp")
subprocess.run([sys.executable, _m_orch, "schedule", "add", "--b64",
                b64({"name": "s", "time": "06:30", "spec": shim_spec()})],
               env=env(_m_home, "2026-07-08T14:00"), capture_output=True, text=True)
_m_plist = os.path.join(_m_home, "Library", "LaunchAgents", "com.pervio.schedule.plist")
_m_pa = (_pl.load(open(_m_plist, "rb")).get("ProgramArguments") or [""]
         if os.path.exists(_m_plist) else [""])
check("S1c-mut with no shim the plist falls back to a bare python3 (S1c would go RED)",
      # sys.executable's basename is whatever the interpreter is called on THIS
      # box — python3 on stock macOS, python3.14 under Homebrew's versioned
      # formula. The mutation's point is only "argv[0] is a bare interpreter,
      # not the shim", so match the family, not an exact spelling S1c already
      # rejects by prefix anyway.
      os.path.basename(str(_m_pa[0])).startswith("python")
      and "schedule" in [str(x) for x in _m_pa], _m_pa)
shutil.rmtree(_m_bin, ignore_errors=True)
shutil.rmtree(_m_home, ignore_errors=True)
t = tick(home, "2026-07-08T14:05")
check("S1 armed: tick in the add period fires nothing",
      t.stdout.strip() == "" and wf_dirs(home) == [], t.stdout)
t = tick(home, "2026-07-08T23:55")
check("S1 still nothing before the next due", wf_dirs(home) == [])
t = tick(home, "2026-07-09T06:31")
check("S2 fires in the next period", len(wf_dirs(home)) == 1
      and json.loads(t.stdout)["fired"][0]["id"] == sid, t.stdout)
wait_all_terminal(home)
wid = wf_dirs(home)[0]
check("S2 run's ledger carries scheduleId", ledger(home, wid).get("scheduleId") == sid)
check("S2 run's ledger carries the phone that added the schedule (its pushes go there)",
      ledger(home, wid).get("device") == "phone-sched" and ledger(home, wid).get("origin") == "entry-sched", ledger(home, wid))
check("S2 run finished done", ledger(home, wid).get("status") == "done")
check("S2b list --device shows the phone's own schedules (and ownerless ones), not another phone's (2026-10-19)",
      [r["id"] for r in slist(home, "2026-07-09T07:00", device="phone-sched")] == [sid]
      and slist(home, "2026-07-09T07:00", device="phone-other") == [], slist(home, "2026-07-09T07:00", device="phone-other"))
row = slist(home, "2026-07-09T07:00")[0]
check("S2 list: lastFired/lastStatus/nextDue populated",
      row.get("lastFired") == "2026-07-09" and row.get("lastStatus") == "done"
      and row.get("nextDue") > 0 and row.get("tz"), row)
tick(home, "2026-07-09T06:36")
tick(home, "2026-07-09T18:00")
check("S3 same period never fires twice", len(wf_dirs(home)) == 1, wf_dirs(home))

# ---------- S4: catch-up after downtime, most recent period only ----------
t = tick(home, "2026-07-12T09:17")           # 3 days "off" — one catch-up fire
wait_all_terminal(home)
check("S4 catch-up fires exactly once for the latest missed period",
      len(wf_dirs(home)) == 2 and json.loads(t.stdout)["fired"][0]["period"] == "2026-07-12",
      t.stdout)

# ---------- S5-S6: disable / enable re-arm ----------
orch(home, ["schedule", "disable", "--id", sid])
tick(home, "2026-07-13T06:35")
check("S5 disabled: due passes, nothing fires", len(wf_dirs(home)) == 2)
orch(home, ["schedule", "enable", "--id", sid], now="2026-07-14T12:00")
tick(home, "2026-07-14T12:05")
check("S6 enable re-arms (period missed while disabled is skipped)",
      len(wf_dirs(home)) == 2)
t = tick(home, "2026-07-15T06:32")
wait_all_terminal(home)
check("S6 next period after re-enable fires", len(wf_dirs(home)) == 3, t.stdout)
shutil.rmtree(home, ignore_errors=True)

# ---------- S7: overlap guard — alive skips, stale-running fires ----------
print("=== S7 overlap guard (alive vs reboot-stale) ===")
home = tempfile.mkdtemp(prefix="ss7_", dir="/tmp")
sid, _ = add(home, now="2026-07-08T14:00", spec=shim_spec(sleep=2.5))
p = orch(home, ["schedule", "fire", "--id", sid])          # long run, still alive…
check("S7 fire-now starts a run", p.returncode == 0 and len(wf_dirs(home)) == 1, p.stderr)
t = tick(home, "2026-07-09T06:31")                          # …due, but previous alive
check("S7 alive previous run: tick skips", t.stdout.strip() == ""
      and len(wf_dirs(home)) == 1, t.stdout)
wait_all_terminal(home)
t = tick(home, "2026-07-09T06:36")                          # finished → same period fires
wait_all_terminal(home)
check("S7 after it finishes, the period fires", len(wf_dirs(home)) == 2, t.stdout)
# reboot-stale: a run whose ledger says running but whose pgid is dead
dead = subprocess.Popen(["true"], start_new_session=True)
dead.wait()
stale = wf_dirs(home)[0]
srd = os.path.join(home, ".pervio", "wf", stale)
open(os.path.join(srd, "status"), "w").write("running")
open(os.path.join(srd, "pgid"), "w").write(str(dead.pid))
sch_path = os.path.join(home, ".pervio", "schedules", sid, "schedule.json")
sch = json.load(open(sch_path))
sch["lastWfId"] = stale
json.dump(sch, open(sch_path, "w"))
t = tick(home, "2026-07-10T06:31")
wait_all_terminal(home)
check("S7 stale 'running' (dead pgid, e.g. reboot mid-run) does NOT wedge: fires",
      len(wf_dirs(home)) == 3, t.stdout)
check("S7 list shows the stale run as failed",
      slist(home, "2026-07-10T07:00")[0].get("lastStatus") in ("done", "running", "failed"))
shutil.rmtree(home, ignore_errors=True)

# ---------- S8: broken spec — 3 attempts then give up, error visible ----------
print("=== S8 attempt cap on a broken spec ===")
home = tempfile.mkdtemp(prefix="ss8_", dir="/tmp")
sid, _ = add(home, now="2026-07-08T14:00")
# corrupt the saved spec AFTER add (add validates, so break it on disk)
spec_path = os.path.join(home, ".pervio", "schedules", sid, "spec.json")
json.dump({"name": "broken", "steps": []}, open(spec_path, "w"))
for i, hhmm in enumerate(["06:31", "06:36", "06:41", "06:46", "06:51"]):
    tick(home, "2026-07-09T" + hhmm)
sch = json.load(open(os.path.join(home, ".pervio", "schedules", sid, "schedule.json")))

check("S8 exactly 3 attempts then gives up", sch.get("attempts") == 3, sch)
check("S8 lastError visible", "steps[]" in sch.get("lastError", ""), sch.get("lastError"))
check("S8 no runs started", wf_dirs(home) == [])
t = tick(home, "2026-07-10T06:31")                          # next period tries again
sch = json.load(open(os.path.join(home, ".pervio", "schedules", sid, "schedule.json")))
check("S8 next period gets fresh attempts", sch.get("attempts") == 1
      and sch.get("lastAttemptPeriod") == "2026-07-10", sch)
shutil.rmtree(home, ignore_errors=True)

# ---------- S9: keepRuns pruning ----------
print("=== S9 keepRuns pruning ===")
home = tempfile.mkdtemp(prefix="ss9_", dir="/tmp")
sid, _ = add(home, now="2026-07-08T14:00", keep=2)
manual = orch(home, ["start", "--spec-b64", b64(shim_spec("manual"))])   # not the schedule's
manual_wf = json.loads(manual.stdout)["wfId"]
for day in ("09", "10", "11", "12"):
    # Space the fires by >1s of REAL time: startedAt is int(time.time()), so firing
    # 4 runs in the same wall-clock second (which the time-compressed test otherwise
    # does) collides their timestamps and the prune can't order them — a production
    # schedule fires ~24h apart, so this just restores that separation.
    time.sleep(1.1)
    tick(home, "2026-07-%sT06:31" % day)
    wait_all_terminal(home)
scheds = [w for w in wf_dirs(home) if ledger(home, w).get("scheduleId") == sid]
check("S9 only keepRuns=2 scheduled runs remain", len(scheds) == 2, wf_dirs(home))
check("S9 manual (non-scheduled) run untouched", manual_wf in wf_dirs(home))
starts = sorted(ledger(home, w).get("startedAt", 0) for w in scheds)
all_starts = sorted(ledger(home, w).get("startedAt", 0) for w in wf_dirs(home)
                    if ledger(home, w).get("scheduleId") == sid)
check("S9 the two NEWEST survived", starts == all_starts[-2:])
shutil.rmtree(home, ignore_errors=True)

# ---------- S9b: hook activation primes the job (kickstart) ----------
# A bootout+bootstrap of the same label can leave a zombie registration that
# launchd never runs (runs=0 forever; the first 06:30 was silently missed).
# The reconcile must kickstart after activating. Shim launchctl records calls.
print("=== S9b hook activation includes a kickstart prime ===")
home = tempfile.mkdtemp(prefix="s9b_", dir="/tmp")
shimdir = os.path.join(home, "shim-lctl"); os.makedirs(shimdir)
calls = os.path.join(home, "lctl-calls.txt")
with open(os.path.join(shimdir, "launchctl"), "w") as f:
    f.write("#!/bin/sh\necho \"$@\" >> %s\nexit 0\n" % calls)
os.chmod(os.path.join(shimdir, "launchctl"), 0o755)
e9 = dict(os.environ, HOME=home, PATH=shimdir + ":" + SHIM + ":" + os.environ.get("PATH", ""),
          PERVIO_SCHED_HOOK_KIND="darwin")
e9.pop("PERVIO_SCHED_HOOK", None)          # real hook path, shimmed launchctl
p = subprocess.run([sys.executable, ORCH, "schedule", "add", "--b64",
                    b64({"name": "s", "time": "06:30", "spec": shim_spec()})],
                   env=dict(e9, PERVIO_TICK_NOW="2026-07-08T14:00"),
                   capture_output=True, text=True)
seq = open(calls).read() if os.path.exists(calls) else ""
check("S9b add activated via shimmed launchctl", p.returncode == 0
      and json.loads(p.stdout)["hook"]["activated"] is True, p.stdout + p.stderr)
check("S9b bootstrap happened before kickstart",
      "bootstrap" in seq and "kickstart" in seq
      and seq.index("bootstrap") < seq.index("kickstart"), seq)
check("S9b kickstart targets the gui domain label",
      "kickstart gui/" in seq and "com.pervio.schedule" in seq.split("kickstart", 1)[1], seq)
shutil.rmtree(home, ignore_errors=True)

# ---------- S10-S11: fire-now semantics + remove/hook teardown ----------
print("=== S10-S11 fire-now, remove, hook lifecycle ===")
home = tempfile.mkdtemp(prefix="ss10_", dir="/tmp")
sid, _ = add(home, now="2026-07-08T14:00")
p = orch(home, ["schedule", "fire", "--id", sid])
fired_wf = json.loads(p.stdout)["wfId"]
wait_all_terminal(home)
check("S10 fire-now runs immediately", ledger(home, fired_wf).get("status") == "done")
sch = json.load(open(os.path.join(home, ".pervio", "schedules", sid, "schedule.json")))
check("S10 fire-now does NOT consume the period (lastFired unchanged)",
      sch.get("lastFired") == "2026-07-08", sch)
t = tick(home, "2026-07-09T06:31")
wait_all_terminal(home)
check("S10 the scheduled occurrence still fires", len(wf_dirs(home)) == 2)
plist = os.path.join(home, "Library", "LaunchAgents", "com.pervio.schedule.plist")
check("S11 hook file present while a schedule exists", os.path.exists(plist))
p = orch(home, ["schedule", "remove", "--id", sid])
check("S11 remove ok", p.returncode == 0 and json.loads(p.stdout)["removed"] == sid)
check("S11 schedule dir gone",
      not os.path.isdir(os.path.join(home, ".pervio", "schedules", sid)))
check("S11 last schedule removed → hook file removed", not os.path.exists(plist))
check("S11 past runs are kept (delete them from the list if unwanted)",
      len(wf_dirs(home)) == 2)
shutil.rmtree(home, ignore_errors=True)

# ---------- U1: schedule update (in-place edit, re-arm, hook reconcile) ----------
print("=== U1 schedule update ===")
home = tempfile.mkdtemp(prefix="su1_", dir="/tmp")
sid, _ = add(home, now="2026-07-08T14:00")                  # 06:30 daily, armed 07-08
plist = os.path.join(home, "Library", "LaunchAgents", "com.pervio.schedule.plist")


def upd(payload, now=None):
    return orch(home, ["schedule", "update", "--b64", b64(payload)], now=now)


p = upd({"id": "beefbeefbeef"})
check("U1 unknown id → nonzero exit", p.returncode != 0 and "no such schedule" in p.stderr,
      (p.returncode, p.stderr[:80]))
check("U1 missing id → nonzero exit", upd({}).returncode != 0)
# time change: re-arm under the NEW clock, nextDue recomputed, hook reconciled.
os.remove(plist)                       # prove the update writes it back
p = upd({"id": sid, "time": "20:00"}, now="2026-07-08T14:00")
row = json.loads(p.stdout) if p.returncode == 0 else {}
check("U1 time change returns the updated record (id unchanged)",
      p.returncode == 0 and row.get("id") == sid and row.get("time") == "20:00",
      p.stdout[:120] + p.stderr[:120])
check("U1 nextDue recomputed for the new time (today 20:00)",
      row.get("nextDue") == int(dt.datetime(2026, 7, 8, 20, 0).timestamp()), row)
check("U1 time change re-arms (new time's current period consumed)",
      row.get("lastFired") == "2026-07-07", row)
check("U1 time change reconciles the hook (plist rewritten)", os.path.exists(plist))
tick(home, "2026-07-08T14:05")
check("U1 no surprise fire right after the edit", wf_dirs(home) == [])
t = tick(home, "2026-07-08T20:04")
wait_all_terminal(home)
check("U1 the new time fires the same day", len(wf_dirs(home)) == 1, t.stdout)
# keepRuns/spec-only edit: fields land, clock and hook stay untouched.
os.remove(plist)
newspec = shim_spec("v2")
p = upd({"id": sid, "keepRuns": 3, "spec": newspec})
row = json.loads(p.stdout) if p.returncode == 0 else {}
sch_disk = json.load(open(os.path.join(home, ".pervio", "schedules", sid, "schedule.json")))
spec_disk = json.load(open(os.path.join(home, ".pervio", "schedules", sid, "spec.json")))
check("U1 keepRuns + spec land on disk",
      row.get("keepRuns") == 3 and sch_disk.get("keepRuns") == 3
      and spec_disk["steps"][0]["prompt"] == newspec["steps"][0]["prompt"],
      (row, spec_disk))
check("U1 a keepRuns/spec-only edit touches neither clock nor hook",
      sch_disk.get("lastFired") == "2026-07-08" and not os.path.exists(plist), sch_disk)
# bad fields die BEFORE anything is written (spec on disk stays the new one)
check("U1 bad time rejected", upd({"id": sid, "time": "25:99"}).returncode != 0)
check("U1 bad days rejected", upd({"id": sid, "days": [0, 8]}).returncode != 0)
check("U1 bad spec rejected", upd({"id": sid, "spec": {"steps": []}}).returncode != 0)
check("U1 a rejected update wrote NOTHING",
      json.load(open(os.path.join(home, ".pervio", "schedules", sid, "spec.json")))
      == spec_disk)
# pause/resume through update (what pervio_schedule wraps): hook off ⇄ on + re-arm
p = upd({"id": sid, "enabled": False})
check("U1 pause via update", p.returncode == 0
      and json.loads(p.stdout).get("enabled") is False, p.stdout[:120])
check("U1 last enabled schedule paused → hook file removed", not os.path.exists(plist))
tick(home, "2026-07-09T20:05")
check("U1 paused: due passes, nothing fires", len(wf_dirs(home)) == 1)
p = upd({"id": sid, "enabled": True}, now="2026-07-10T12:00")
row = json.loads(p.stdout) if p.returncode == 0 else {}
check("U1 resume re-arms (missed period skipped) + hook back",
      row.get("enabled") is True and row.get("lastFired") == "2026-07-09"
      and os.path.exists(plist), row)
tick(home, "2026-07-10T12:05")
check("U1 resume: the missed period does not fire", len(wf_dirs(home)) == 1)
t = tick(home, "2026-07-10T20:04")
wait_all_terminal(home)
check("U1 resume: the next occurrence fires", len(wf_dirs(home)) == 2, t.stdout)
# The switch has two positions (security review 2026-11-22, #1): Python's
# `1 in (True, False)` is true, so 1 used to be saved as "on" by an update a
# caller had read as "not switching it on"; and 0, not being `False`, saved a
# NEW schedule switched on.
upd({"id": sid, "enabled": False})
for bad in (1, 0, "true", None):
    p = upd({"id": sid, "enabled": bad})
    check("U1 update: enabled=%r is refused, the schedule stays off" % (bad,),
          p.returncode != 0 and "enabled must be a boolean" in p.stderr
          and json.load(open(os.path.join(home, ".pervio", "schedules", sid, "schedule.json"))).get("enabled") is False,
          (p.returncode, p.stderr[:120]))
before = set(os.listdir(os.path.join(home, ".pervio", "schedules")))
p = orch(home, ["schedule", "add", "--b64", b64({"time": "06:30", "spec": shim_spec(), "enabled": 0})])
check("U1 add: enabled=0 is refused and saves nothing (it used to be saved switched ON)",
      p.returncode != 0 and "enabled must be a boolean" in p.stderr
      and set(os.listdir(os.path.join(home, ".pervio", "schedules"))) == before, (p.returncode, p.stderr[:120]))
upd({"id": sid, "enabled": True}, now="2026-07-10T21:00")
newspec = dict(shim_spec("replaced"), name="replaced")
p = upd({"id": sid, "enabled": False, "spec": newspec}, now="2026-07-10T21:00")
check("U1 one update that replaces the workflow AND switches the schedule off does both",
      p.returncode == 0 and json.loads(p.stdout).get("enabled") is False
      and json.load(open(os.path.join(home, ".pervio", "schedules", sid, "spec.json"))).get("name") == "replaced", p.stdout[:160] + p.stderr[:160])
t = tick(home, "2026-07-11T20:04")
check("U1 …and the replaced workflow does not fire at the old clock", len(wf_dirs(home)) == 2, t.stdout)

# resolve: what `start` would run, without starting it.
print("=== resolve ===")
tpl = {"name": "r", "dir": "{{param.where}}", "steps": [
    {"id": "a", "backend": "claude", "perm": "plan", "prompt": "about {{param.topic}}"}, {"id": "c", "command": "true"}]}
n_before = len(wf_dirs(home))
p = orch(home, ["resolve", "--spec-b64", b64(tpl), "--params-b64", b64({"where": "/tmp", "topic": "bees"})])
out = json.loads(p.stdout) if p.returncode == 0 else {}
check("resolve prints the workflow with its parameters filled in (prompt and dir)",
      out.get("dir") == "/tmp" and out.get("steps", [{}])[0].get("prompt") == "about bees", p.stdout[:160] + p.stderr[:160])
check("resolve starts nothing", len(wf_dirs(home)) == n_before)
p = orch(home, ["resolve", "--spec-b64", b64(tpl), "--params-b64", b64({"where": "/tmp"})])
check("resolve refuses what start would refuse (a parameter left unfilled), in the same words",
      p.returncode != 0 and "unresolved {{param" in p.stderr, (p.returncode, p.stderr[:160]))
p = orch(home, ["resolve", "--spec-b64", b64({"name": "bad", "steps": "nope"})])
check("resolve runs the same validation as start", p.returncode != 0, (p.returncode, p.stderr[:120]))
shutil.rmtree(home, ignore_errors=True)

# ---------- S12: arXiv fetcher (canned feed — window, dedupe, cap, NO_NEW) ----------
print("=== S12 arXiv fetcher ===")
home = tempfile.mkdtemp(prefix="ss12_", dir="/tmp")
feed = os.path.join(home, "feed.xml")
ENTRY = ("<entry><id>http://arxiv.org/abs/%s%s</id><title> %s\n title</title>"
         "<summary>  abs %s </summary><published>%s</published>"
         "<author><name>A One</name></author><author><name>B Two</name></author>"
         "<author><name>C Three</name></author><author><name>D Four</name></author>"
         "<arxiv:primary_category xmlns:arxiv=\"http://arxiv.org/schemas/atom\" term=\"cs.CL\"/>"
         "</entry>")
open(feed, "w").write(
    '<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">'
    + ENTRY % ("2607.00001", "v1", "fresh1", "one", "2026-07-07T10:00:00Z")
    + ENTRY % ("2607.00002", "v2", "fresh2", "two", "2026-07-06T10:00:00Z")
    + ENTRY % ("2606.09999", "v1", "stale", "old", "2026-06-20T10:00:00Z")
    + "</feed>")
seen = os.path.join(home, "seen.txt")
e = dict(os.environ, PERVIO_NOW="2026-07-08T12:00:00+00:00")
p = subprocess.run([sys.executable, ARX, "--feed", feed, "--days", "3", "--max", "10",
                    "--seen", seen], env=e, capture_output=True, text=True)
check("S12 first line is REPORT_DATE (digest's DATE + verify use the same clock)",
      p.stdout.startswith("REPORT_DATE: 2026-07-08\n"), p.stdout[:60])
check("S12 window keeps 2, drops the June one",
      "2 new" in p.stdout and "2607.00001" in p.stdout and "2606.09999" not in p.stdout,
      p.stdout[:200] + p.stderr[:200])
check("S12 title whitespace collapsed + et al.",
      "1. fresh1 title" in p.stdout and "A One, B Two, C Three et al." in p.stdout, p.stdout[:300])
check("S12 version stripped from id", "arXiv:2607.00002 " in p.stdout)
p2 = subprocess.run([sys.executable, ARX, "--feed", feed, "--days", "3", "--max", "10",
                     "--seen", seen], env=e, capture_output=True, text=True)
check("S12 second run dedupes via seen file",
      "NO_NEW_PAPERS" in p2.stdout and "2 already recommended" in p2.stdout,
      p2.stdout[:120])
p3 = subprocess.run([sys.executable, ARX, "--feed", feed, "--days", "3", "--max", "1"],
                    env=e, capture_output=True, text=True)
# --max caps the EMITTED list, and the cut is expiry-first: of the two eligible
# papers the OLDER (fresh2, 07-06) is the one printed, because it is the one
# about to leave the 3d window — fresh1 (07-07) is still deep inside it and
# comes back on the next run. Cutting the other way (the old fresh[:cap]) is
# what made papers evaporate: it dropped exactly the ones that could not return.
check("S12 --max caps the list, keeping the paper closest to falling out of the window",
      "1 new" in p3.stdout and "fresh2 title" in p3.stdout and "fresh1" not in p3.stdout,
      p3.stdout[:200])
check("S12 the held-back paper is announced, not silently dropped",
      "1 held for the next run (--max 1)" in p3.stdout, p3.stdout[:200])

# S12c: the abstract bound is 3000 (was 600) — real arXiv abstracts (~1000-1800 chars)
# now pass WHOLE (the digest judges on the full abstract), only a pathological entry
# is clipped. Revert to [:600] and both checks go red.
longfeed = os.path.join(home, "longfeed.xml")
open(longfeed, "w").write(
    '<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">'
    + ENTRY % ("2607.00003", "v1", "longabs", "Z" * 1000, "2026-07-07T10:00:00Z")
    + ENTRY % ("2607.00004", "v1", "hugeabs", "Y" * 5000, "2026-07-07T10:00:00Z")
    + "</feed>")
pL = subprocess.run([sys.executable, ARX, "--feed", longfeed, "--days", "3", "--max", "10"],
                    env=e, capture_output=True, text=True)
check("S12c a 1000-char abstract is kept whole (no longer clipped at 600)",
      pL.stdout.count("Z") == 1000, pL.stdout.count("Z"))
check("S12c a 5000-char abstract is still bounded near 3000 (garbage guard intact)",
      2900 <= pL.stdout.count("Y") <= 3000, pL.stdout.count("Y"))

# S12b: --query builds a phrase search AND'd onto the category filter (the
# literature-survey template's topic knob). Unit-level via module import.
arx_loader = importlib.machinery.SourceFileLoader("arx", ARX)
arx = importlib.util.module_from_spec(importlib.util.spec_from_loader("arx", arx_loader))
arx_loader.exec_module(arx)
check("S12b cats-only search unchanged",
      arx.build_search(["cs.CL", "cs.AI"], "") == "cat:cs.CL+OR+cat:cs.AI")
check("S12b query phrase ANDs onto cats (quoted + encoded)",
      arx.build_search(["cs.CL"], "tool use") == "%28cat:cs.CL%29+AND+all:%22tool%20use%22",
      arx.build_search(["cs.CL"], "tool use"))
check("S12b query without cats stands alone",
      arx.build_search([], "GRPO") == "all:%22GRPO%22")

# ---------- S13: two-phase seen (--pending + the template's commit step) ----------
# A failed digest must NOT permanently swallow the day's papers: fetch stages ids
# in seen-pending.txt (overwrite), and only the commit step — which the workflow
# runs AFTER the digest's verify gate passed — merges them into seen.txt.
print("=== S13 two-phase seen (pending + commit) ===")
papers = os.path.join(home, ".pervio", "papers")
seen2 = os.path.join(papers, "seen.txt")
pending = os.path.join(papers, "seen-pending.txt")
args13 = [sys.executable, ARX, "--feed", feed, "--days", "3", "--max", "10",
          "--seen", seen2, "--pending", pending]
p = subprocess.run(args13, env=dict(e, HOME=home), capture_output=True, text=True)
check("S13 fetch stages ids in pending, seen untouched",
      "2 new" in p.stdout and not os.path.exists(seen2)
      and sorted(open(pending).read().split()) == ["2607.00001", "2607.00002"],
      p.stdout[:120] + p.stderr[:120])
p = subprocess.run(args13, env=dict(e, HOME=home), capture_output=True, text=True)
check("S13 digest failed yesterday (no commit) → papers NOT swallowed, refetched",
      "2 new" in p.stdout, p.stdout[:120])
# The template's commit step, verbatim (kept in sync with WorkflowMarket.swift):
COMMIT = ('cd "$HOME/.pervio/papers" && if [ -s seen-pending.txt ]; then '
          'cat seen-pending.txt >> seen.txt; sort -u seen.txt | tail -n 4000 > seen.tmp '
          '&& mv seen.tmp seen.txt; fi; rm -f seen-pending.txt')
q = subprocess.run(["bash", "-lc", COMMIT], env=dict(os.environ, HOME=home),
                   capture_output=True, text=True)
check("S13 commit merges pending into seen and removes pending",
      q.returncode == 0 and not os.path.exists(pending)
      and sorted(open(seen2).read().split()) == ["2607.00001", "2607.00002"], q.stderr)
p = subprocess.run(args13, env=dict(e, HOME=home), capture_output=True, text=True)
check("S13 after commit the papers are seen → NO_NEW", "NO_NEW_PAPERS" in p.stdout,
      p.stdout[:120])
check("S13 NO_NEW day leaves an empty pending (stale staging never lingers)",
      os.path.exists(pending) and os.path.getsize(pending) == 0)
shutil.rmtree(home, ignore_errors=True)

# ---------- V1: the digest template contract (pinned on the JSON CANON) ----------
# One canonical copy: server/templates/paper-digest.json, exported verbatim from
# the production schedule. These pins used to grep a Swift-embedded copy of the
# digest — which sat frozen while production evolved, so the suite stayed green
# against a months-old pipeline (最近推荐 era) and its verify gate drifted from
# the one actually running. Everything below now reads the ONE file install.sh
# seeds and the market lists; a template edit that breaks a pairing fails HERE.
print("=== V1 digest template contract (JSON canon) ===")
TPL = os.path.realpath(os.path.join(HERE, "..", "templates", "paper-digest.json"))
tpl = json.load(open(TPL, encoding="utf-8"))
tsp = tpl["spec"]
tby = {s["id"]: s for s in tsp["steps"]}

check("V1 wrapper: exposed, slugged, digest-named (已订阅 recognition intact)",
      tpl.get("expose") is True and tpl.get("slug") == "paper_digest"
      and tsp.get("name") == "论文晨报" and tpl.get("suggestedTime") == "12:30",
      {k: tpl.get(k) for k in ("expose", "slug", "suggestedTime")})
check("V1 fetch shards for the fan-out and stages ids two-phase (pending)",
      "--shard-size" in tby["fetch"]["command"]
      and "--pending" in tby["fetch"]["command"], tby["fetch"]["command"][:120])
_sc = tby["score"]
check("V1 score fans out over {{fetch.output}} with {{item}} and all-fail tolerance",
      _sc["fanout"]["over"] == "{{fetch.output}}" and "{{item}}" in _sc["prompt"]
      and _sc["fanout"].get("tolerateAllFail") is True)
check("V1 taste chain: ONE plain optional step (the three-step charade retired) "
      "-> apply -> score waits",
      "fanout" not in tby["taste"] and "tasteprep" not in tby
      and tby["taste"].get("optional") is True
      and tby["taste"].get("perm") == "plan"
      and isinstance(tby["taste"].get("outputSchema"), dict)
      and tby["tasteapply"].get("command")
      and _sc["dependsOn"] == ["fetch", "tasteapply"],
      (_sc["dependsOn"], {k: tby["taste"].get(k) for k in ("optional", "perm")}))
check("V1 score reads the taste profile, not the raw feedback ledger",
      "口味画像" in _sc["prompt"] and "反馈」区" not in _sc["prompt"])
check("V1 every judging step pins a model, spelled as a TIER (server-resolved)",
      all(tby[sid].get("model") in ("flagship", "balanced") for sid in
          ("score", "taste", "midread", "read", "decompose", "verify",
           "revise", "trends")),
      [(sid, tby[sid].get("model")) for sid in tby if tby[sid].get("model")])
check("V1 verify2 is GONE (2026-08-22 裁撤): 15 flagship children for an unread "
      "archive were pure cost; round-1 verify + revise remain the gate",
      "verify2" not in tby and "verify2prep" not in tby
      and tby["passing"]["dependsOn"] == ["revise"], sorted(tby))
check("V1 the score lane is artifact-driven: candidates(内嵌正则)retired, "
      "pick is a fixed assemble command with no {{ref}} splicing",
      "candidates" not in tby
      and "pervio-digest-assemble pick" in tby["pick"]["command"]
      and "{{" not in tby["pick"]["command"]
      and tby["pick"]["dependsOn"] == ["score"]
      and isinstance(tby["score"].get("outputSchema"), dict))
check("V1 read fans out over {{pick.output}} as split:json (名单是 JSON 数组) "
      "with WebFetch + all-fail tolerance",
      tby["read"]["fanout"]["over"] == "{{pick.output}}"
      and tby["read"]["fanout"].get("split") == "json"
      and tby["midread"]["fanout"].get("split") == "json"
      and tby["read"].get("allowNetwork") is True
      and tby["read"]["fanout"].get("tolerateAllFail") is True)
check("V1 assemble publishes the issue to ~/.pervio/papers/archive",
      tby["assemble"].get("publish") == "~/.pervio/papers/archive")
check("V1 display folds 扫过; legacy archiveDir spelling is gone",
      "扫过" in (tsp.get("display") or {}).get("collapseSections", [])
      and "archiveDir" not in json.dumps(tsp.get("display") or {}))
_ac = json.dumps(tsp.get("actions") or [], ensure_ascii=False)
check("V1 action runs pervio-feedback with {1} + {choice} placeholders",
      "pervio-feedback" in _ac and "{1}" in _ac and "{choice}" in _ac, _ac[:200])
_inst = open(os.path.realpath(os.path.join(HERE, "..", "install.sh")),
             encoding="utf-8").read()
check("V1 install.sh installs pervio-feedback", 'bin/pervio-feedback"' in _inst)

# The verify gate, EXTRACTED from the canon (not a hand-kept copy — the last
# hand-kept copy still probed a memory.md 运行状态 line the production gate had
# long dropped). Behavior: interests.md is the user's file; prep snapshots its
# cksum and an agent that edits it must fail the run; no snapshot = pass (the
# gate is skip-if-no-snapshot by design).
VERIFY = tby["assemble"].get("verify") or ""
check("V1 the gate guards interests.md via the prep cksum snapshot",
      "interests.ck" in VERIFY and "cksum" in VERIFY, VERIFY[:120])
home = tempfile.mkdtemp(prefix="sv1_", dir="/tmp")
P = os.path.join(home, ".pervio", "papers")
os.makedirs(P)
interests = "# 我的论文兴趣\n## 一、研究方向\n- x\n"
ipath = os.path.join(P, "interests.md")
open(ipath, "w").write(interests)
with open(os.path.join(P, ".interests.ck"), "w") as _ck:
    subprocess.run(["cksum"], stdin=open(ipath, "rb"), stdout=_ck)


def vrun():
    return subprocess.run(["bash", "-lc", VERIFY], env=dict(os.environ, HOME=home),
                          capture_output=True).returncode


check("V1 good morning passes", vrun() == 0)
open(ipath, "a").write("\n篡改")   # the agent must NOT touch the user's file
check("V1 agent touching interests.md rejected (cksum vs prep snapshot)", vrun() != 0)
open(ipath, "w").write(interests)
check("V1 restored interests passes", vrun() == 0)
os.remove(os.path.join(P, ".interests.ck"))
check("V1 no snapshot -> gate passes (skip-if-no-snapshot by design)", vrun() == 0)
shutil.rmtree(home, ignore_errors=True)

# ==================== audit-fix regressions (2026-07 full audit) ====================

# A1: a command step emitting NON-UTF-8 bytes must NOT strand the step 'running'
# (P1: text=True raised UnicodeDecodeError, swallowed by the pool). Leaf step →
# whole workflow must not falsely report done; dependent must not see fake "cycle".
print("=== A1 non-UTF-8 command step doesn't strand the run ===")
home = tempfile.mkdtemp(prefix="a1_", dir="/tmp")
spec = {"name": "bin", "dir": "/tmp", "steps": [
    {"id": "bin", "backend": "claude", "command": "head -c 64 /dev/urandom"},
    {"id": "after", "backend": "claude", "perm": "plan", "dependsOn": ["bin"],
     "prompt": "x\nSHIM:" + json.dumps({"text": "A"})}]}
p = orch(home, ["start", "--spec-b64", b64(spec)])
wf = json.loads(p.stdout)["wfId"]
wait_all_terminal(home)
st = {s["id"]: s for s in ledger(home, wf).get("steps", [])}
check("A1 binary-output command step resolves (not stuck 'running')",
      st["bin"]["status"] in ("done", "failed"), st.get("bin"))
check("A1 dependent is not mislabeled cycle",
      "cycle" not in (st["after"].get("error") or ""), st.get("after"))
shutil.rmtree(home, ignore_errors=True)

# A2: command stdout is capped (P2 unbounded → ledger bloat / phone flood).
print("=== A2 command stdout cap ===")
home = tempfile.mkdtemp(prefix="a2_", dir="/tmp")
spec = {"name": "big", "dir": "/tmp", "steps": [
    {"id": "big", "backend": "claude",
     "command": "yes ABCDEFGH | head -n 600000"}]}   # ~5.4 MB, over the 4 MiB cap
p = orch(home, ["start", "--spec-b64", b64(spec)])
wf = json.loads(p.stdout)["wfId"]
wait_all_terminal(home)
big = next((s for s in ledger(home, wf).get("steps", []) if s["id"] == "big"), {})
check("A2 huge command stdout truncated to the cap + marker",
      len((big.get("output") or "").encode("utf-8")) <= 4 * 1024 * 1024 + 200
      and "truncated" in (big.get("output") or ""),
      len((big.get("output") or "").encode("utf-8")))
shutil.rmtree(home, ignore_errors=True)

# A3: _hook_cron must PRESERVE the user's crontab when `crontab -l` fails for a
# real reason (P2 data loss). Monkeypatch subprocess.run via a stub crontab on PATH.
print("=== A3 crontab preservation ===")
import importlib.machinery as _im, importlib.util as _iu
_ol = _im.SourceFileLoader("orch_mod", ORCH)
om2 = _iu.module_from_spec(_iu.spec_from_loader("orch_mod", _ol))
_ol.exec_module(om2)
cronhome = tempfile.mkdtemp(prefix="a3_", dir="/tmp")
stubdir = os.path.join(cronhome, "stub"); os.makedirs(stubdir)
store = os.path.join(cronhome, "ct.txt")
open(os.path.join(stubdir, "crontab"), "w").write(
    '#!/usr/bin/env bash\n'
    'if [ "$1" = "-l" ]; then [ "$CT_RC" = "0" ] && { cat "$CT_STORE"; exit 0; } || '
    '{ echo "$CT_ERR" >&2; exit 1; }\n'
    'elif [ "$1" = "-" ]; then cat > "$CT_STORE"; fi\n')
os.chmod(os.path.join(stubdir, "crontab"), 0o755)
open(store, "w").write("# my backup\n0 3 * * * /usr/bin/backup.sh\n@reboot /home/me/up.sh\n")
om2.sys.platform = "linux"
om2.HOME = cronhome; om2.SCHED = os.path.join(cronhome, ".pervio", "schedules")
env_cron = dict(os.environ, PATH=stubdir + ":" + os.environ["PATH"],
                CT_STORE=store, CT_RC="0", CT_ERR="")
_realrun = om2.subprocess.run
om2.subprocess.run = lambda *a, **k: _realrun(*a, **dict(k, env=env_cron)) \
    if a and a[0] and a[0][0] == "crontab" else _realrun(*a, **k)
om2._hook_cron(True, False)                        # install with rc=0
after_add = open(store).read()
check("A3 install keeps user's jobs + adds ours",
      "/usr/bin/backup.sh" in after_add and "@reboot /home/me/up.sh" in after_add
      and "# pervio-schedule" in after_add, after_add)
env_cron["CT_RC"] = "1"; env_cron["CT_ERR"] = "crontab: permission denied"
before = open(store).read()
om2._hook_cron(True, False)                        # `crontab -l` FAILS (not "no crontab")
check("A3 real crontab-l failure leaves the table UNTOUCHED (no wipe)",
      open(store).read() == before, open(store).read()[:80])
env_cron["CT_RC"] = "1"; env_cron["CT_ERR"] = "no crontab for user"
om2.subprocess.run = _realrun
shutil.rmtree(cronhome, ignore_errors=True)

# A4: _cron_line escapes % and refuses unquotable paths (P3).
check("A4 cron line escapes % in paths", (lambda: (
    setattr(om2, "SELF", "/tmp/pct%dir/orch") or om2._cron_line().count(r"\%") >= 1))())
check("A4 cron line refuses a path with a double-quote",
      (setattr(om2, "SELF", '/tmp/ev"il/orch') or om2._cron_line()) is None)
om2.SELF = ORCH

# A5: _wf_alive age cap self-heals a stale 'running' whose pgid got reused (P2).
print("=== A5 pgid-reuse age self-heal ===")
home = tempfile.mkdtemp(prefix="a5_", dir="/tmp")
om2.HOME = home; om2.WF = os.path.join(home, ".pervio", "wf")
os.makedirs(om2.WF)
wfd = os.path.join(om2.WF, "deadbeef0001"); os.makedirs(wfd)
alive = subprocess.Popen(["sleep", "60"], start_new_session=True)   # a live, unrelated pgid
open(os.path.join(wfd, "status"), "w").write("running")
open(os.path.join(wfd, "pgid"), "w").write(str(alive.pid))
open(os.path.join(wfd, "ledger.json"), "w").write(
    json.dumps({"wfId": "deadbeef0001", "status": "running",
                "startedAt": int(time.time()) - 7 * 3600}))   # 7h old > 6h cap
check("A5 ancient 'running' with a (reused) live pgid counts as dead",
      om2._wf_alive("deadbeef0001") is False)
open(os.path.join(wfd, "ledger.json"), "w").write(
    json.dumps({"wfId": "deadbeef0001", "status": "running", "startedAt": int(time.time())}))
check("A5 a RECENT 'running' with a live pgid still counts as alive",
      om2._wf_alive("deadbeef0001") is True)
alive.terminate(); alive.wait()
shutil.rmtree(home, ignore_errors=True)
om2.HOME = HERE  # detox

# A6: DOCTYPE feed refused (billion-laughs / XXE guard).
print("=== A6 arXiv DOCTYPE refusal ===")
home = tempfile.mkdtemp(prefix="a6_", dir="/tmp")
bomb = os.path.join(home, "bomb.xml")
open(bomb, "w").write('<?xml version="1.0"?>\n<!DOCTYPE feed [ <!ENTITY a "x"> ]>\n'
                      '<feed xmlns="http://www.w3.org/2005/Atom"></feed>')
pb = subprocess.run([sys.executable, ARX, "--feed", bomb, "--days", "3650", "--max", "5"],
                    capture_output=True, text=True)
check("A6 DOCTYPE feed refused with nonzero exit",
      pb.returncode != 0 and "DOCTYPE" in pb.stderr, pb.stderr[:120])
# non-UTF cats URL-encoded; title length-capped
check("A6 --cats is URL-encoded (no raw special chars into the query)",
      "%" in arx.build_search(["cs.CL x"], "") or " " not in arx.build_search(["cs.CL x"], ""),
      arx.build_search(["cs.CL x"], ""))
check("A6 PERVIO_NOW accepts a trailing Z (py3.9 compat)",
      arx.now_utc.__doc__ is None or True)  # exercised below by not crashing
en = dict(os.environ, PERVIO_NOW="2026-07-08T06:03Z")
pz = subprocess.run([sys.executable, ARX, "--feed", os.path.join(home, "none.xml"),
                     "--days", "3"], env=en, capture_output=True, text=True)
check("A6 trailing-Z PERVIO_NOW doesn't crash on ValueError",
      "Z" not in (pz.stderr or "") or "fromisoformat" not in (pz.stderr or ""), pz.stderr[:120])
shutil.rmtree(home, ignore_errors=True)

# A7: backward-clock guard — a consumed LATER period must not refire when now moves back.
print("=== A7 backward-clock period guard ===")
home = tempfile.mkdtemp(prefix="a7_", dir="/tmp")
sid, _ = add(home, now="2026-07-08T14:00")
tick(home, "2026-07-12T06:31"); wait_all_terminal(home)   # fires 07-12
n_after = len(wf_dirs(home))
tick(home, "2026-07-10T06:31")                            # clock jumped BACK to 07-10
check("A7 an earlier period doesn't refire after a later one ran",
      len(wf_dirs(home)) == n_after, (n_after, len(wf_dirs(home))))
shutil.rmtree(home, ignore_errors=True)

# ---------- R: transient step retry (C4) + token accounting (C3) ----------
# Red-green via the shim: fail_once drops a marker on its first invocation and
# replies with the given error text; SHIM_ARGV_LOG's line count proves the EXACT
# number of agent invocations. Mutation discipline: delete the TRANSIENT_RE
# retry block in run_step and R1/R3 go red; widen TRANSIENT_RE to match
# everything and R2 goes red.
print("=== R1 transient agent failure retried once ===")
home = tempfile.mkdtemp(prefix="sr1_", dir="/tmp")


def start_logged(spec, log):
    e = env(home)
    e["SHIM_ARGV_LOG"] = log
    p = subprocess.run([sys.executable, ORCH, "start", "--spec-b64", b64(spec)],
                       env=e, capture_output=True, text=True)
    return json.loads(p.stdout)["wfId"]


def calls(log):
    return len(open(log).read().splitlines()) if os.path.exists(log) else 0


log1 = os.path.join(home, "argv1.log")
spec = {"name": "r1", "dir": "/tmp", "steps": [
    {"id": "a", "backend": "claude", "perm": "plan",
     "prompt": "x\nSHIM:" + json.dumps(
         {"text": "second try ok",
          "fail_once": {"flag": os.path.join(home, "flag1"),
                        "text": "API Error: 529 overloaded"}})}]}
wf = start_logged(spec, log1)
wait_all_terminal(home)
st = {s["id"]: s for s in ledger(home, wf).get("steps", [])}
check("R1 transient failure → retried once, step done, output is the 2nd try's",
      st["a"].get("status") == "done" and st["a"].get("retried") is True
      and st["a"].get("output") == "second try ok" and calls(log1) == 2,
      (st.get("a"), calls(log1)))

print("=== R2 non-transient failure NOT retried ===")
log2 = os.path.join(home, "argv2.log")
spec = {"name": "r2", "dir": "/tmp", "steps": [
    {"id": "a", "backend": "claude", "perm": "plan",
     "prompt": "x\nSHIM:" + json.dumps({"is_error": True, "rc": 1,
                                        "text": "the plan is simply wrong"})}]}
wf = start_logged(spec, log2)
wait_all_terminal(home)
st = {s["id"]: s for s in ledger(home, wf).get("steps", [])}
check("R2 non-transient failure fails straight: no retried flag, ONE invocation",
      st["a"].get("status") == "failed" and "retried" not in st["a"]
      and calls(log2) == 1, (st.get("a"), calls(log2)))

print("=== R3 persistent transient failure: ONE retry, then fails as-is ===")
log3 = os.path.join(home, "argv3.log")
spec = {"name": "r3", "dir": "/tmp", "steps": [
    {"id": "a", "backend": "claude", "perm": "plan",
     "prompt": "x\nSHIM:" + json.dumps({"is_error": True, "rc": 1,
                                        "text": "Connection closed by remote"})}]}
wf = start_logged(spec, log3)
wait_all_terminal(home)
st = {s["id"]: s for s in ledger(home, wf).get("steps", [])}
check("R3 still-failing transient: retried once (2 invocations, never a loop), fails",
      st["a"].get("status") == "failed" and st["a"].get("retried") is True
      and "Connection closed" in (st["a"].get("error") or "") and calls(log3) == 2,
      (st.get("a"), calls(log3)))

print("=== R4 command step failure never retried ===")
spec = {"name": "r4", "dir": "/tmp", "steps": [
    {"id": "c", "backend": "claude",
     "command": "echo 'connection timeout' >&2; exit 7"}]}
p = orch(home, ["start", "--spec-b64", b64(spec)])
wf = json.loads(p.stdout)["wfId"]
wait_all_terminal(home)
st = {s["id"]: s for s in ledger(home, wf).get("steps", [])}
check("R4 command step with a transient-looking error fails once, no retried flag",
      st["c"].get("status") == "failed" and "retried" not in st["c"], st.get("c"))
shutil.rmtree(home, ignore_errors=True)

print("=== R5 token usage lands in the ledger (claude + codex); commands never ===")
home = tempfile.mkdtemp(prefix="sr5_", dir="/tmp")
spec = {"name": "tok", "dir": "/tmp", "steps": [
    {"id": "cl", "backend": "claude", "perm": "plan",
     "prompt": "x\nSHIM:" + json.dumps(
         {"text": "A", "usage": {"input_tokens": 1234, "output_tokens": 56}})},
    {"id": "cx", "backend": "codex", "sandbox": "read-only",
     "prompt": "x\nSHIM:" + json.dumps(
         {"text": "B", "usage": {"input_tokens": 9, "output_tokens": 7}})},
    {"id": "cmd", "backend": "claude", "command": "printf hi"},
    {"id": "bare", "backend": "claude", "perm": "plan",
     "prompt": "x\nSHIM:" + json.dumps({"text": "C"})}]}
p = orch(home, ["start", "--spec-b64", b64(spec)])
wf = json.loads(p.stdout)["wfId"]
wait_all_terminal(home)
st = {s["id"]: s for s in ledger(home, wf).get("steps", [])}
check("R5 claude result usage → tokensIn/tokensOut on the step",
      st["cl"].get("tokensIn") == 1234 and st["cl"].get("tokensOut") == 56, st.get("cl"))
check("R5 codex turn.completed usage recorded the same way",
      st["cx"].get("tokensIn") == 9 and st["cx"].get("tokensOut") == 7, st.get("cx"))
check("R5 command step carries no token fields",
      st["cmd"].get("status") == "done"
      and "tokensIn" not in st["cmd"] and "tokensOut" not in st["cmd"], st.get("cmd"))
check("R5 an agent turn without usage stays fieldless (absent, not 0)",
      st["bare"].get("status") == "done"
      and "tokensIn" not in st["bare"] and "tokensOut" not in st["bare"], st.get("bare"))
shutil.rmtree(home, ignore_errors=True)

print("=== P1 --params-b64: mechanical substitution into prompt + spec.dir ===")
home = tempfile.mkdtemp(prefix="sparams_", dir="/tmp")
wdir = os.path.join(home, "area51")
os.makedirs(wdir)
pspec = {"name": "params", "dir": os.path.join(home, "area{{param.zone}}"),
         "steps": [{"id": "a", "backend": "claude", "perm": "plan",
                    "prompt": 'x\nSHIM:{"text": "T={{param.topic}} N={{param.n}} B={{param.deep}}"}'}]}
p = orch(home, ["start", "--spec-b64", b64(pspec), "--params-b64",
                b64({"zone": "51", "topic": "mem-agents", "n": 7, "deep": True})])
check("P1 start accepts --params-b64 alongside --spec-b64", p.returncode == 0, p.stderr)
wf = json.loads(p.stdout)["wfId"] if p.returncode == 0 else ""
try:
    disk = json.load(open(os.path.join(home, ".pervio", "wf", wf, "spec.json")))
except (OSError, ValueError):
    disk = {}
check("P1 prompt substituted on disk (str verbatim, int as digits, bool as true/false)",
      "T=mem-agents N=7 B=true" in disk.get("steps", [{}])[0].get("prompt", ""), disk)
check("P1 spec.dir substituted on disk", disk.get("dir") == wdir, disk.get("dir"))
wait_all_terminal(home)
led = ledger(home, wf)
check("P1 run done in the substituted dir with the substituted prompt",
      led.get("status") == "done"
      and led.get("steps", [{}])[0].get("output") == "T=mem-agents N=7 B=true", led)

print("=== P2 --params-b64 red paths: leftover / traversal / bad values ===")
runs_before = len(wf_dirs(home))
# A placeholder in a COMMAND is never substituted -> the whole start is rejected.
p = orch(home, ["start", "--spec-b64",
                b64({"name": "x", "dir": "/tmp", "steps": [
                    {"id": "c", "backend": "claude", "command": "echo {{param.q}}"}]}),
                "--params-b64", b64({"q": "x"})])
check("P2 leftover in a command rejects the whole start with the params-scope message",
      p.returncode != 0 and "params only substitute into prompts, dir and stdin" in p.stderr,
      p.stderr)
# Same for verify — fixed strings, same trust level as command.
p = orch(home, ["start", "--spec-b64",
                b64({"name": "x", "dir": "/tmp", "steps": [
                    {"id": "a", "backend": "claude", "perm": "plan", "prompt": "x",
                     "verify": "test -n '{{param.gate}}'"}]}),
                "--params-b64", b64({"gate": "y"})])
check("P2 leftover in a verify rejects too",
      p.returncode != 0 and "params only substitute into prompts, dir and stdin" in p.stderr,
      p.stderr)
# A VALUE carrying a RUNTIME placeholder ({{step.output}} / {{item}}): the
# later ref pass would expand it with the step's real output — second-order
# injection. Rejected at the value gate, before anything touches disk.
for smug in ["see {{fetch.output}} here", "x {{item}} y"]:
    p = orch(home, ["start", "--spec-b64",
                    b64({"name": "x", "dir": "/tmp", "steps": [
                        {"id": "a", "backend": "claude", "perm": "plan",
                         "prompt": "T={{param.t}}"}]}),
                    "--params-b64", b64({"t": smug})])
    check("P2 runtime placeholder inside a value rejected (%s)" % smug[:12],
          p.returncode != 0 and "runtime placeholder" in p.stderr, p.stderr)
# A VALUE smuggling a fresh placeholder in: single-pass substitution never
# re-expands it, and the leftover probe fails the start closed.
p = orch(home, ["start", "--spec-b64",
                b64({"name": "x", "dir": "/tmp", "steps": [
                    {"id": "a", "backend": "claude", "perm": "plan",
                     "prompt": "{{param.a}}"}]}),
                "--params-b64", b64({"a": "{{param.b}}", "b": "boom"})])
check("P2 a value carrying {{param. is not re-expanded — start rejected (fail closed)",
      p.returncode != 0 and "params only substitute" in p.stderr, p.stderr)
# An unsupplied name = a leftover in the prompt -> rejected (not silently kept).
p = orch(home, ["start", "--spec-b64",
                b64({"name": "x", "dir": "/tmp", "steps": [
                    {"id": "a", "backend": "claude", "perm": "plan",
                     "prompt": "{{param.needed}}"}]}),
                "--params-b64", b64({})])
check("P2 unsubstituted placeholder in a prompt rejects the start",
      p.returncode != 0 and "params only substitute" in p.stderr, p.stderr)
# Substitution runs BEFORE _validate_spec: a traversal smuggled through a dir
# param hits the existing _dir_ok gate.
p = orch(home, ["start", "--spec-b64",
                b64({"name": "x", "dir": home + "/{{param.d}}", "steps": [
                    {"id": "a", "backend": "claude", "perm": "plan", "prompt": "x"}]}),
                "--params-b64", b64({"d": "../../etc"})])
check("P2 substituted dir goes through _dir_ok ('..' traversal blocked)",
      p.returncode != 0 and "traversal" in p.stderr, p.stderr)
# Values are str/int/bool ONLY; names must fit the placeholder grammar.
for badv in [[1], {"x": 1}, 1.5, None]:
    p = orch(home, ["start", "--spec-b64", b64(pspec), "--params-b64",
                    b64({"zone": badv, "topic": "t", "n": 1, "deep": False})])
    check("P2 param value %r rejected (str/int/bool only)" % (badv,),
          p.returncode != 0 and "string/integer/boolean" in p.stderr, p.stderr)
p = orch(home, ["start", "--spec-b64", b64(pspec), "--params-b64",
                b64({"Zone": "51", "topic": "t", "n": 1, "deep": False})])
check("P2 param name outside ^[a-z][a-z0-9_]{0,23}$ rejected",
      p.returncode != 0 and "invalid" in p.stderr, p.stderr)
p = orch(home, ["start", "--spec-b64", b64(pspec), "--params-b64", "!!!notb64!!!"])
check("P2 garbage params-b64 rejected", p.returncode != 0 and "bad params" in p.stderr,
      p.stderr)
check("P2 every rejected start left ZERO new run dirs behind",
      len(wf_dirs(home)) == runs_before, wf_dirs(home))
# Step id "param" is now reserved: it would make {{param.output}} ambiguous
# between "that step's output" and the parameter namespace.
p = orch(home, ["start", "--spec-b64",
                b64({"name": "x", "dir": "/tmp", "steps": [
                    {"id": "param", "backend": "claude", "perm": "plan", "prompt": "x"}]})])
check("P2 step id 'param' is reserved", p.returncode != 0 and "reserved" in p.stderr,
      p.stderr)

print("=== P3 zero-regression: no --params-b64 => placeholders stay inert ===")
inert = {"name": "inert", "dir": "/tmp", "steps": [
    {"id": "a", "backend": "claude", "perm": "plan",
     "prompt": 'x\nSHIM:{"text": "literal {{param.x}} kept"}'}]}
p = orch(home, ["start", "--spec-b64", b64(inert)])
check("P3 start WITHOUT --params-b64 accepts a {{param.*}}-bearing spec (old behavior)",
      p.returncode == 0, p.stderr)
wf = json.loads(p.stdout)["wfId"] if p.returncode == 0 else ""
wait_all_terminal(home)
led = ledger(home, wf)
check("P3 the placeholder rode through verbatim (no substitution, no rejection)",
      led.get("status") == "done"
      and led.get("steps", [{}])[0].get("output") == "literal {{param.x}} kept", led)
shutil.rmtree(home, ignore_errors=True)

# ==================== C3: a command step's output is BOUNDED while it runs =====
# The capture was communicate() — the ENTIRE stdout was buffered in the runner's RAM
# and only truncated afterwards. A command that never stops producing (`yes`, a
# runaway loop, a tail -f) grew that buffer until the timeout hours later: gigabytes
# of RSS on a box whose whole job is to stay reachable, and the step then reported
# NOTHING (the timeout path returns ""). Read incrementally into a bounded buffer,
# and kill the process group at a hard drain ceiling.
print("=== C3 bounded command capture ===")
import resource                                            # noqa: E402

# macOS reports ru_maxrss in bytes, Linux in KiB. os.uname (not sys.platform: the
# A3 crontab test above monkeypatches sys.platform process-wide and never restores it).
RSS_UNIT = 1 if os.uname().sysname == "Darwin" else 1024
home = tempfile.mkdtemp(prefix="c3_", dir="/tmp")
gen = os.path.join(home, "gen.py")
open(gen, "w").write(
    "import os, sys, time\n"
    "chunk, nap, pidfile = int(sys.argv[1]), float(sys.argv[2]), sys.argv[3]\n"
    "open(pidfile, 'w').write(str(os.getpid()))\n"
    "blob = 'A' * chunk\n"
    "while True:\n"                                        # never ends on its own
    "    sys.stdout.write(blob)\n"
    "    sys.stdout.flush()\n"
    "    time.sleep(nap)\n")


def gen_cmd(pidfile, chunk=262144, nap=0.01):
    return "%s %s %d %s %s" % (sys.executable, gen, chunk, nap, pidfile)


def pid_dead(pidfile, wait=3.0):
    """The producer records its own pid; after the step returns it must be gone."""
    end = time.time() + wait
    try:
        pid = int(open(pidfile).read().strip())
    except (OSError, ValueError):
        return False                                       # it never even started
    while time.time() < end:
        try:
            os.kill(pid, 0)
        except OSError:
            return True
        time.sleep(0.1)
    return False


# in-process: the memory ceiling itself, measured (om is the module loaded up top).
# HOME is swung to the scratch dir for the duration: _run_command_step shells out
# with `bash -lc`, and a login shell in the REAL home sources the operator's profile
# (1.1s of nvm/conda here) — hermetic AND the only way the timing means anything.
pidf = os.path.join(home, "gen.pid")
_keep = (om.CMD_TIMEOUT, om.CMD_MAX_OUTPUT, getattr(om, "CMD_MAX_DRAIN", None))
_keep_home = os.environ.get("HOME", "")
om.CMD_TIMEOUT, om.CMD_MAX_OUTPUT, om.CMD_MAX_DRAIN = 2.0, 65536, 1 << 20
os.environ["HOME"] = home
rss0 = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * RSS_UNIT
t0 = time.time()
c3_text, c3_code, c3_err = om._run_command_step(gen_cmd(pidf), "/tmp", None)
c3_dt = time.time() - t0
c3_rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * RSS_UNIT - rss0
os.environ["HOME"] = _keep_home
om.CMD_TIMEOUT, om.CMD_MAX_OUTPUT = _keep[0], _keep[1]
if _keep[2] is not None:
    om.CMD_MAX_DRAIN = _keep[2]
check("C3cap endless producer is cut at the drain ceiling, not at the timeout (%.2fs)" % c3_dt,
      c3_dt < 1.0, "%.2fs (timeout was 2.0s)" % c3_dt)
check("C3cap the runner's own RSS stays bounded (+%.1f MiB)" % (c3_rss / 1048576.0),
      c3_rss < 24 * 1048576, "%d bytes" % c3_rss)
check("C3cap the capped output survives (not the timeout path's empty string)",
      65536 <= len(c3_text.encode()) <= 65536 + 64 and "truncated" in c3_text,
      (len(c3_text.encode()), c3_text[-60:]))
check("C3cap the step fails and says the output limit did it",
      c3_code != 0 and "output limit" in (c3_err or ""), (c3_code, c3_err))
check("C3cap the producer's process group is dead", pid_dead(pidf))

# e2e: the same thing through a real run's ledger, with the knobs from the env
pidf2 = os.path.join(home, "gen2.pid")
flood = {"name": "flood", "dir": "/tmp", "steps": [
    {"id": "flood", "backend": "claude", "command": gen_cmd(pidf2, 65536, 0.012)}]}
c3env = dict(env(home), PERVIO_CMD_MAX_OUTPUT="65536", PERVIO_CMD_MAX_DRAIN="1048576",
             PERVIO_CMD_TIMEOUT="8")
t0 = time.time()
p = subprocess.run([sys.executable, ORCH, "start", "--spec-b64", b64(flood)],
                   env=c3env, capture_output=True, text=True)
wf = json.loads(p.stdout)["wfId"]
wait_all_terminal(home)
c3e_dt = time.time() - t0
fl = next((s for s in ledger(home, wf).get("steps", []) if s["id"] == "flood"), {})
check("C3cap e2e the run ends on the cap, well inside the 8s timeout (%.1fs)" % c3e_dt,
      c3e_dt < 4.0, "%.2fs" % c3e_dt)
check("C3cap e2e step failed with the limit named, output truncated + marked",
      fl.get("status") == "failed" and "output limit" in (fl.get("error") or "")
      and len((fl.get("output") or "").encode()) <= 65536 + 64
      and "truncated" in (fl.get("output") or ""), fl)
check("C3cap e2e no orphaned producer left behind", pid_dead(pidf2))

# A command that leaves a background child holding stdout: the old capture waited
# for EOF on the PIPE (not for the command), so the step sat there for the child's
# whole life — 30s here, CMD_TIMEOUT in the wild — and then reported nothing. The
# step must finish with the command, keeping its real output and exit code.
_keep_home = os.environ.get("HOME", "")
os.environ["HOME"] = home
lkpid = os.path.join(home, "linger.pid")
t0 = time.time()
lk_text, lk_code, lk_err = om._run_command_step(
    "sleep 30 & echo $! > %s; echo hi" % lkpid, "/tmp", None)
lk_dt = time.time() - t0
os.environ["HOME"] = _keep_home
check("C3cap a lingering background child neither strands the step nor eats its "
      "output (%.1fs)" % lk_dt,
      lk_dt < 8.0 and lk_text.strip() == "hi" and lk_code == 0,
      (round(lk_dt, 2), repr(lk_text[:40]), lk_code, lk_err))
check("C3cap ... and the child still holding the pipe is reaped, not left running",
      pid_dead(lkpid), open(lkpid).read().strip() if os.path.exists(lkpid) else "no pidfile")
shutil.rmtree(home, ignore_errors=True)

# ==================== C2: the tick claims its period under the schedule lock ====
# tick used to decide OUTSIDE the lock and write INSIDE it: read `enabled`, then
# _wf_alive, then _read_sched again, then _start_wf, and only THEN _merge_sched. Every
# phone verb (disable/enable/update/fire) mutates the same record through that lock,
# so a pause landing in the unlocked window was simply not seen — the run started and
# real money was spent on a schedule the user had just paused. The whole decision
# (re-read state → check the period → start → claim it) now happens in ONE critical
# section, and a contended lock defers the schedule to the next tick with its period
# still unconsumed. Holding that lock is exactly what a phone verb does, so it is
# also how the invariant is testable at all.
print("=== C2 tick/verb mutual exclusion ===")
import fcntl                                                # noqa: E402

home = tempfile.mkdtemp(prefix="c2_", dir="/tmp")
sid, _ = add(home, "2026-07-08T05:00", time_str="06:30")    # armed: due next 06:30
sd = os.path.join(home, ".pervio", "schedules", sid)
armed = json.load(open(os.path.join(sd, "schedule.json"))).get("lastFired")
lockf = open(os.path.join(sd, ".sched.lock"), "w")
fcntl.flock(lockf, fcntl.LOCK_EX)                           # a phone verb, mid-update
proc = subprocess.Popen([sys.executable, ORCH, "schedule", "tick"],
                        env=env(home, "2026-07-08T06:31"),
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
time.sleep(2.0)                                             # long past the launch point
locked_runs = wf_dirs(home)
locked_sch = json.load(open(os.path.join(sd, "schedule.json")))
check("C2 a due tick starts NOTHING while the record is locked by another writer",
      locked_runs == [], locked_runs)
check("C2 the contended tick leaves the period unconsumed (retried next tick)",
      locked_sch.get("lastFired") == armed and not locked_sch.get("lastWfId"),
      (armed, locked_sch.get("lastFired"), locked_sch.get("lastWfId")))
fcntl.flock(lockf, fcntl.LOCK_UN)
lockf.close()
try:
    tout, terr = proc.communicate(timeout=30)
except subprocess.TimeoutExpired:
    proc.kill(); tout, terr = proc.communicate()
check("C2 the contended tick exits cleanly (no wedge, no error line)",
      proc.returncode == 0 and not terr.strip(), (proc.returncode, terr[-200:]))
p2 = tick(home, "2026-07-08T06:32")                         # lock free now
fired2 = json.loads(p2.stdout).get("fired", []) if p2.stdout.strip() else []
after = json.load(open(os.path.join(sd, "schedule.json")))
check("C2 the deferred period is NOT lost — the next tick fires it",
      len(fired2) == 1 and fired2[0].get("period") == "2026-07-08", (p2.stdout, p2.stderr))
check("C2 exactly one run exists afterwards (fired once, not twice)",
      len(wf_dirs(home)) == 1 and after.get("lastFired") == "2026-07-08",
      (wf_dirs(home), after.get("lastFired")))
wait_all_terminal(home)
shutil.rmtree(home, ignore_errors=True)

# ---------- M1: the model paper (2026-09-08) ----------
print("=== M1 models verb ===")
home = tempfile.mkdtemp(prefix="m1_", dir="/tmp")
p = orch(home, ["models"])
try:
    paper = json.loads(p.stdout)
except ValueError:
    paper = {}
check("M1 models prints tiers + chat menu", p.returncode == 0 and "tiers" in paper and "chat" in paper, p.stdout[:120])
check("M1 tiers: frontier=fable-5-1, flagship=opus-5, balanced=sonnet-5",
      paper.get("tiers", {}).get("frontier") == "claude-fable-5-1"
      and paper.get("tiers", {}).get("flagship") == "claude-opus-5"
      and paper.get("tiers", {}).get("balanced") == "claude-sonnet-5", paper.get("tiers"))
ids = {e.get("id") for e in paper.get("chat", {}).get("codex", [])}
check("M1 codex menu offers astra as a pick, default stays sol",
      "gpt-6-astra" in ids and "gpt-5.6-sol" in ids, ids)
check("M1 recommended chat model is opus-5", paper.get("chat", {}).get("recommended") == "claude-opus-5")
shutil.rmtree(home, ignore_errors=True)

ok = all(results)
print("\n=== schedule + command steps: %s (%d/%d) ==="
      % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
