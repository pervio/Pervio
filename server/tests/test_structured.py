#!/usr/bin/env python3
"""Structured data channel for pervio-orchestrate (WF-1 of the pipeline redesign).

The old world moved ONE STRING between steps; every pipeline grew a private
parser toolkit to survive it. This suite pins the new contract:

  * outputSchema on an agent step: the step's text must parse as JSON and match
    a SMALL schema subset; a wrong answer earns exactly ONE corrective re-run
    (the complaint + the bad head appended to the prompt); a second wrong
    answer fails the step. Parsed value lands at <rd>/json/<sid>.json.
  * {{id.json}} refs: canonical JSON of a step's structured value, usable in
    prompts and in the new command-step `stdin` field. NEVER in a command line.
  * command steps gain `stdin`: upstream output flows in on fd 0, the command
    line stays a fixed string (the injection stance is unchanged).
  * fanout can iterate a structured array directly (over {{id.json}}, no
    numbered-list parsing), with {{item.key}} substitution for object items;
    with outputSchema it validates EACH CHILD and collects parsed values.
  * validation refuses the shapes that can only be authoring mistakes.

Hermetic: isolated $HOME, scratch git repo, committed shim claude on PATH.
"""
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
    d = tempfile.mkdtemp(prefix="struct_", dir="/tmp")
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


def start(spec, home):
    b64 = base64.b64encode(json.dumps(spec).encode()).decode()
    return subprocess.run([sys.executable, ORCH, "start", "--spec-b64", b64],
                          env=env(home), capture_output=True, text=True, timeout=60)


def wait_done(home, wf, timeout=90):
    rd = os.path.join(home, ".pervio", "wf", wf)
    deadline = time.time() + timeout
    while time.time() < deadline:
        led = {}
        try:
            led = json.load(open(os.path.join(rd, "ledger.json")))
        except (OSError, ValueError):
            pass
        if led.get("status") in ("done", "failed"):
            return led
        time.sleep(0.15)
    return {"status": "TIMEOUT"}


def run_spec(spec, home):
    p = start(spec, home)
    if p.returncode != 0:
        return None, p.stderr.strip()
    wf = json.loads(p.stdout)["wfId"]
    return wait_done(home, wf), wf


def led_step(led, sid):
    return next(s for s in led["steps"] if s["id"] == sid)


def jart(home, wf, sid):
    p = os.path.join(home, ".pervio", "wf", wf, "json", "%s.json" % sid)
    if not os.path.exists(p):
        return None
    return json.load(open(p))


def agent(sid, shim, extra=None):
    s = {"id": sid, "backend": "claude", "perm": "plan",
         "prompt": "%s work\nSHIM:%s" % (sid, json.dumps(shim))}
    s.update(extra or {})
    return s


home = tempfile.mkdtemp(prefix="struct_home_", dir="/tmp")
repo = mkrepo()

# ---------- S0: the schema-subset validator itself (unit, direct import) ----------
loader = importlib.machinery.SourceFileLoader("orch_mod", ORCH)
orch = importlib.util.module_from_spec(importlib.util.spec_from_loader("orch_mod", loader))
loader.exec_module(orch)

SCH = {"type": "array", "items": {"type": "object",
                                  "properties": {"id": {"type": "string"},
                                                 "stars": {"type": "number"},
                                                 "tag": {"enum": ["a", "b"]}},
                                  "required": ["id", "stars"]}}
ok_val = [{"id": "x", "stars": 4.5, "tag": "a"}, {"id": "y", "stars": 2}]
check("S0a validator accepts a conforming array", orch._schema_check(SCH, ok_val) == "",
      orch._schema_check(SCH, ok_val))
bad = orch._schema_check(SCH, [{"id": "x"}])
check("S0b missing required key is named in the complaint", "stars" in bad, bad)
bad = orch._schema_check(SCH, [{"id": 1, "stars": 2}])
check("S0c wrong type is refused with a path", "id" in bad and "string" in bad, bad)
bad = orch._schema_check(SCH, [{"id": "x", "stars": 2, "tag": "z"}])
check("S0d enum violation refused", "tag" in bad, bad)
check("S0e not-an-array refused", orch._schema_check(SCH, {"id": "x"}) != "")
check("S0f integer schema rejects 1.5 but takes 3",
      orch._schema_check({"type": "integer"}, 1.5) != ""
      and orch._schema_check({"type": "integer"}, 3) == ""
      and orch._schema_check({"type": "integer"}, True) != "")
p, perr = orch._parse_structured("```json\n[1, 2]\n```")
check("S0g fenced JSON parses", p == [1, 2], (p, perr))
p, perr = orch._parse_structured("Sure! Here you go:\n[1, 2]\nHope that helps.")
check("S0h chatter around a bracket span parses", p == [1, 2], (p, perr))

# ---------- S1: outputSchema happy path -> json artifact ----------
payload = [{"id": "2608.11111", "stars": 4.5}, {"id": "2608.22222", "stars": 3}]
spec = {"name": "s1", "dir": repo, "steps": [
    agent("a", {"text": "```json\n%s\n```" % json.dumps(payload)},
          {"outputSchema": SCH}),
]}
led, wf = run_spec(spec, home)
check("S1 schema'd step done, parsed value at json/<sid>.json",
      led["status"] == "done" and jart(home, wf, "a") == payload,
      (led["status"], jart(home, wf, "a")))

# ---------- S2: one corrective retry fixes a wrong answer ----------
flag = os.path.join(home, "s2.flag")
spec = {"name": "s2", "dir": repo, "steps": [
    agent("a", {"text": json.dumps(payload), "sid": "good-sid",
                "text_once": {"flag": flag, "text": "oops, not json", "sid": "bad-sid"}},
          {"outputSchema": SCH}),
]}
led, wf = run_spec(spec, home)
st = led_step(led, "a")
check("S2a wrong answer then corrective retry -> done, artifact = attempt 2",
      led["status"] == "done" and jart(home, wf, "a") == payload
      and st.get("schemaRetry") is True, (led["status"], st.get("schemaRetry")))
check("S2b attempt 1's conversation stays sweepable (priorSessionIds)",
      "bad-sid" in (st.get("priorSessionIds") or []) and st.get("sessionId") == "good-sid",
      st)
check("S2c attempt 1's stream archived beside the final one",
      os.path.exists(os.path.join(home, ".pervio", "wf", wf, "a.jsonl.badjson1")))

# ---------- S3: two wrong answers fail the step; dependents skip ----------
spec = {"name": "s3", "dir": repo, "steps": [
    agent("a", {"text": "never json"}, {"outputSchema": SCH}),
    agent("b", {"text": "downstream"}, {"dependsOn": ["a"]}),
]}
led, wf = run_spec(spec, home)
check("S3 unfixable output fails the step with the complaint; dependent skipped",
      led["status"] == "failed"
      and "JSON" in led_step(led, "a")["error"]
      and led_step(led, "b")["status"] == "skipped",
      (led_step(led, "a")["error"], led_step(led, "b")["status"]))

# ---------- S4/S5: stdin on command steps ({{id.json}} and {{id.output}}) ----------
spec = {"name": "s4", "dir": repo, "steps": [
    agent("a", {"text": json.dumps(payload)}, {"outputSchema": SCH}),
    {"id": "c", "backend": "claude", "dependsOn": ["a"],
     "command": "cat -", "stdin": "{{a.json}}"},
]}
led, wf = run_spec(spec, home)
got = led_step(led, "c")["output"].strip() if led["status"] == "done" else ""
check("S4 command stdin carries canonical JSON of {{a.json}}",
      led["status"] == "done" and json.loads(got or "null") == payload, (led["status"], got[:120]))

spec = {"name": "s5", "dir": repo, "steps": [
    agent("a", {"text": "plain words, not json"}),
    {"id": "c", "backend": "claude", "dependsOn": ["a"],
     "command": "cat -", "stdin": "{{a.output}}"},
]}
led, wf = run_spec(spec, home)
check("S5 command stdin carries {{a.output}} text verbatim",
      led["status"] == "done"
      and led_step(led, "c")["output"].strip() == "plain words, not json",
      led_step(led, "c") if led.get("steps") else led)

# ---------- S6: fanout over {{a.json}} with {{item.key}} ----------
names = [{"name": "alpha", "n": 1}, {"name": "beta", "n": 2}]
spec = {"name": "s6", "dir": repo, "steps": [
    agent("a", {"text": json.dumps(names)},
          {"outputSchema": {"type": "array"}}),
    {"id": "work", "backend": "claude", "perm": "plan",
     "fanout": {"over": "{{a.json}}", "max": 10, "maxParallel": 2},
     "prompt": "process\nSHIM:{\"text\": \"got {{item.name}}/{{item.n}}\"}"},
]}
led, wf = run_spec(spec, home)
out = led_step(led, "work")["output"] if led.get("steps") else ""
check("S6 fanout iterates the structured array, {{item.key}} substituted",
      led["status"] == "done" and "got alpha/1" in out and "got beta/2" in out,
      (led["status"], out[:200]))

# ---------- S7: fanout + per-child outputSchema collects parsed values ----------
child_sch = {"type": "object", "properties": {"v": {"type": "integer"}}, "required": ["v"]}
mk = {"text": "1. " + json.dumps({"text": "{\"v\": 10}"})
              + "\n2. " + json.dumps({"text": "{\"v\": 20}"})
              + "\n3. " + json.dumps({"text": "garbage forever"})}
spec = {"name": "s7", "dir": repo, "steps": [
    agent("mk", mk),
    {"id": "work", "backend": "claude", "perm": "plan",
     "outputSchema": child_sch,
     "fanout": {"over": "{{mk.output}}", "split": "numbered", "max": 10,
                "maxParallel": 2, "tolerateAllFail": True},
     "prompt": "process\nSHIM:{{item}}"},
]}
led, wf = run_spec(spec, home)
st = led_step(led, "work")
arr = jart(home, wf, "work")
check("S7a good children's parsed values collected in order; bad child excluded",
      led["status"] == "done" and arr == [{"v": 10}, {"v": 20}],
      (led["status"], arr))
check("S7b the schema-refusing child counts as a FAILED child",
      st.get("fanoutOk") == 2 and st.get("fanoutFail") == 1
      and ("契约" in st["output"] or "schema" in st["output"].lower()),
      st.get("output", "")[:200])

# ---------- S8: fanout WITHOUT schema still writes a text array artifact ----------
spec = {"name": "s8", "dir": repo, "steps": [
    agent("mk", {"text": "1. %s\n2. %s" % (json.dumps({"text": "one"}),
                                           json.dumps({"text": "two"}))}),
    {"id": "work", "backend": "claude", "perm": "plan",
     "fanout": {"over": "{{mk.output}}", "split": "numbered", "max": 10},
     "prompt": "p\nSHIM:{{item}}"},
    {"id": "c", "backend": "claude", "dependsOn": ["work"],
     "command": "cat -", "stdin": "{{work.json}}"},
]}
led, wf = run_spec(spec, home)
got = led_step(led, "c")["output"].strip() if led["status"] == "done" else ""
check("S8 plain fanout: {{work.json}} is the ok-children text array",
      led["status"] == "done" and json.loads(got or "null") == ["one", "two"],
      (led["status"], got[:120]))

# ---------- S9: validation refusals (each must reject the START) ----------
def refused(spec, needle):
    p = start(spec, home)
    return p.returncode != 0 and needle in (p.stderr or "")

check("S9a outputSchema on a command step refused",
      refused({"name": "x", "dir": repo, "steps": [
          {"id": "c", "backend": "claude", "command": "true",
           "outputSchema": {"type": "array"}}]}, "outputSchema"))
check("S9b stdin on an agent step refused",
      refused({"name": "x", "dir": repo, "steps": [
          agent("a", {"text": "t"}, {"stdin": "{{a.output}}"})]}, "stdin"))
check("S9c {{id.json}} pointing at a plain text step refused",
      refused({"name": "x", "dir": repo, "steps": [
          agent("a", {"text": "t"}),
          {"id": "c", "backend": "claude", "command": "cat -",
           "stdin": "{{a.json}}", "dependsOn": ["a"]}]}, "json"))
check("S9d fanout over {{id.json}} with an explicit split refused",
      refused({"name": "x", "dir": repo, "steps": [
          agent("a", {"text": "[]"}, {"outputSchema": {"type": "array"}}),
          {"id": "w", "backend": "claude", "perm": "plan",
           "fanout": {"over": "{{a.json}}", "split": "numbered"},
           "prompt": "p {{item}}\nSHIM:{}"}]}, "split"))
check("S9e stdin ref to a missing step refused (ordering edge, checked at the door)",
      refused({"name": "x", "dir": repo, "steps": [
          {"id": "c", "backend": "claude", "command": "cat -",
           "stdin": "{{ghost.output}}"}]}, "ghost"))
check("S9f outputSchema that is not an object refused",
      refused({"name": "x", "dir": repo, "steps": [
          agent("a", {"text": "t"}, {"outputSchema": "array"})]}, "outputSchema"))

# ---------- S10: stdin ref is an ordering edge (consumer waits for producer) ----------
spec = {"name": "s10", "dir": repo, "steps": [
    {"id": "c", "backend": "claude", "command": "cat -", "stdin": "{{slow.output}}"},
    agent("slow", {"text": "late words", "sleep": 1.0}),
]}
led, wf = run_spec(spec, home)
check("S10 stdin consumer ran AFTER its producer (no empty race)",
      led["status"] == "done" and led_step(led, "c")["output"].strip() == "late words",
      led_step(led, "c") if led.get("steps") else led)

# ---------- S12: a TOP-LEVEL plan step gets ExitPlanMode stripped ----------
# run_child sealed this door for fan-out children on 2026-08-20; merge/trends
# style top-level plan steps ran unprotected until the same seal landed in
# _run_agent_turn. The shim's argv log shows what pervio-chat passed to the CLI.
argv12 = os.path.join(home, "argv12.log")
os.environ["SHIM_ARGV_LOG"] = argv12
spec = {"name": "s12", "dir": repo, "steps": [
    agent("planner", {"text": "the report"}),          # perm plan (agent() default)
    agent("writer", {"text": "w"}, {"perm": "acceptEdits", "dependsOn": ["planner"]}),
]}
led, wf = run_spec(spec, home)
os.environ.pop("SHIM_ARGV_LOG", None)
calls = [json.loads(l) for l in open(argv12)] if os.path.exists(argv12) else []
plan_calls = [c for c in calls if "plan" in " ".join(c)]
other_calls = [c for c in calls if c not in plan_calls]
check("S12 top-level plan turn carries --disallowedTools ExitPlanMode; others don't",
      led["status"] == "done" and plan_calls
      and all("ExitPlanMode" in " ".join(c) for c in plan_calls)
      and all("ExitPlanMode" not in " ".join(c) for c in other_calls),
      calls)

# ---------- S11: model TIERS resolve at spawn, raw ids pass through ----------
argv_log = os.path.join(home, "argv.log")
os.environ["SHIM_ARGV_LOG"] = argv_log          # env() copies os.environ
spec = {"name": "s11", "dir": repo, "steps": [
    agent("a", {"text": "t"}, {"model": "flagship"}),
    agent("b", {"text": "t"}, {"model": "my-exotic-model", "dependsOn": ["a"]}),
]}
led, wf = run_spec(spec, home)
os.environ.pop("SHIM_ARGV_LOG", None)
logged = open(argv_log).read() if os.path.exists(argv_log) else ""
check("S11 'flagship' reaches the CLI as today's model id; raw ids untouched",
      led["status"] == "done" and "claude-opus-5" in logged
      and "flagship" not in logged and "my-exotic-model" in logged,
      logged[:300])

shutil.rmtree(home, ignore_errors=True)
shutil.rmtree(repo, ignore_errors=True)

ok = all(results)
print("\n=== test_structured: %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌",
                                                 sum(results), len(results)))
sys.exit(0 if ok else 1)
