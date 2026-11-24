#!/usr/bin/env python3
"""Regression tests for server/bin/pervio-group (a project's group: one primary
conversation + partners answering in parallel, the primary synthesising, the
synthesis relayed back). Hermetic: isolated $HOME, the committed shim claude /
codex on PATH — zero model calls. Covers create/list, a full round through the
state machine (answering → synthesizing → relaying → done), the pervio-run
finish hook advancing a round on its own, refusal of a second `say` mid-round,
learning a new partner's session id, and the transcript stripping the hidden
group header while keeping a `via` label."""
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
SESSIONS = os.path.join(BIN, "pervio-sessions")
SHIM = os.path.join(HERE, "shim")
results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + (("  [" + str(detail)[:220] + "]") if (detail and not cond) else ""))


def env():
    home = tempfile.mkdtemp(prefix="pgrp_home_", dir="/tmp")
    # PERVIO_CODEX_EXEC: a member's session id is scripted through the prompt here
    # (the exec shim's `sid`), which the app-server face cannot do — the id exists
    # before the prompt. The app-server path has its own suite in test_chat.py.
    return home, dict(os.environ, HOME=home, PATH=SHIM + ":" + os.environ.get("PATH", ""), PERVIO_CODEX_EXEC="1",
                      SHIM_PROMPT_LOG=os.path.join(home, "prompts.log"))


def grp(e, *args):
    return subprocess.run([sys.executable, GROUP] + list(args), env=e, capture_output=True, text=True, timeout=60)


def b64(o):
    return base64.b64encode(json.dumps(o).encode()).decode()


def gstate(home, gid):
    with open(os.path.join(home, ".pervio", "groups", gid + ".json")) as f:
        return json.load(f)


def wait_state(e, gid, want, timeout=30):
    """Poll `tick` until the round reaches `want` (or settles)."""
    for _ in range(timeout * 4):
        g = json.loads(grp(e, "tick", "--id", gid).stdout)
        if g["round"]["state"] == want or g["round"]["state"] == "done":
            return g
        time.sleep(0.25)
    return g


print("=== create / list ===")
home, e = env()
proj = os.path.join(home, "proj"); os.makedirs(proj)
payload = {"mode": "parallel", "autoSynth": True,
           "primary": {"session": "sess-P", "backend": "claude", "perm": "auto"},
           "members": [{"session": "", "backend": "codex", "sandbox": "read-only"}]}
p = grp(e, "create", "--dir", proj, "--b64", b64(payload))
check("G1 create answers with the group (exit 0)", p.returncode == 0, p.stderr[:200])
g = json.loads(p.stdout)
gid = g["id"]
check("G1 group file lives under ~/.pervio/groups", os.path.isfile(os.path.join(home, ".pervio", "groups", gid + ".json")))
check("G1 round starts idle at 0", g["round"]["state"] == "idle" and g["round"]["n"] == 0, g["round"])
lst = json.loads(grp(e, "list", "--dir", proj).stdout)
check("G1 list --dir finds it; another dir does not",
      [x["id"] for x in lst] == [gid] and json.loads(grp(e, "list", "--dir", "/elsewhere").stdout) == [], lst)
check("G1d a group made without a device is everyone's (older app): no --device on its pushes", g.get("device", "") == "", g)
pd = json.loads(grp(e, "create", "--dir", proj, "--b64", b64(dict(payload, device="phone-G"))).stdout)
check("G1e the phone that made the group is recorded, so its round/critique pushes go there alone (2026-10-19)",
      pd.get("device") == "phone-G", pd)
grp(e, "delete", "--id", pd["id"])

print("=== a full round: say → answering → synthesizing → relaying → done ===")
# The shim reads a SHIM:{…} line anywhere in the prompt; both members (and the
# synthesis run, whose prompt quotes the question) will answer with this text.
text = "这题怎么解?\nSHIM:" + json.dumps({"text": "组的答案", "sid": "sess-NEW"})
p = grp(e, "say", "--id", gid, "--text-b64", base64.b64encode(text.encode()).decode())
check("G2 say starts a round", p.returncode == 0, p.stderr[:200])
g = json.loads(p.stdout)
check("G2 round 1 is answering with one run per member",
      g["round"]["n"] == 1 and g["round"]["state"] == "answering"
      and set(g["round"]["runs"]) == {"p", "m0"} and all(g["round"]["runs"].values()), g["round"])
p2 = grp(e, "say", "--id", gid, "--text-b64", base64.b64encode(b"again").decode())
check("G3 a second say mid-round is refused (exit 4)", p2.returncode == 4, (p2.returncode, p2.stderr[:120]))
g = wait_state(e, gid, "synthesizing")
check("G4 both answers collected, synthesis started on the primary",
      g["round"]["answers"].get("p") == "组的答案" and g["round"]["answers"].get("m0") == "组的答案"
      and g["round"]["state"] in ("synthesizing", "relaying", "done") and g["round"]["synthRun"], g["round"])
check("G4 the new partner learned its session id from its first run",
      g["members"][0]["session"] not in ("", None), g["members"][0])
g = wait_state(e, gid, "done")
check("G5 synthesis recorded, round ends done WITHOUT a relay run (no useless partner reply)",
      g["round"]["synth"] == "组的答案" and g["round"]["state"] == "done" and not g["round"]["relayRuns"], g["round"])
check("G6 the conclusion is kept for the next round", g.get("lastSynth") == "组的答案", g.get("lastSynth"))
runs_before = set(os.listdir(os.path.join(home, ".pervio", "runs")))
p3 = grp(e, "say", "--id", gid, "--text-b64", base64.b64encode(b"next").decode())
check("G7 after done, say opens round 2", p3.returncode == 0 and json.loads(p3.stdout)["round"]["n"] == 2, p3.stderr[:120])
g2 = json.loads(p3.stdout)
def _meta(rid):
    return json.load(open(os.path.join(home, ".pervio", "runs", rid, "meta.json")))
wait_state(e, gid, "done")
prompts = open(os.path.join(home, "prompts.log"), encoding="utf-8").read().split("===PROMPT-END===")
r2_m0 = [x for x in prompts if 'round="2"' in x and 'to="m0"' in x]
r2_p = [x for x in prompts if 'round="2"' in x and 'to="p"' in x and 'from="human"' in x]
check("G7a round-2 partner prompt carries last round's conclusion in its header; the primary's does not",
      r2_m0 and "上一轮主对话的结论" in r2_m0[0] and "组的答案" in r2_m0[0]
      and r2_p and "上一轮主对话的结论" not in r2_p[0], (len(r2_m0), len(r2_p)))
check("G7c every group run is marked with the group id (one push per round, not per run)",
      all(_meta(r)["group"] == gid for r in g2["round"]["runs"].values()), [_meta(r).get("group") for r in g2["round"]["runs"].values()])
# The phone may be asleep: the round must advance on its own. pervio-run's
# finish wrapper calls `pervio-group tick-run`; watch the group FILE (no tick
# from here) leave "answering" by itself.
advanced = False
for _ in range(80):
    if gstate(home, gid)["round"]["state"] != "answering":
        advanced = True; break
    time.sleep(0.25)
check("G7b the finish hook advances the round without anyone ticking", advanced, gstate(home, gid)["round"]["state"])
wait_state(e, gid, "done")

print("=== the hidden header: what the models see, what the phone shows ===")
# Inspect the prompt the primary actually received (pervio-run keeps a preview;
# the shim got the full prompt via stdin — check the run's meta preview head).
runs = sorted(os.listdir(os.path.join(home, ".pervio", "runs")))
previews = [json.load(open(os.path.join(home, ".pervio", "runs", r, "meta.json"))).get("preview", "") for r in runs]
full = [x for x in open(os.path.join(home, "prompts.log"), encoding="utf-8").read().split("===PROMPT-END===") if x.strip()]
check("G8 every group prompt opens with the hidden <pervio-group header",
      full and all(x.lstrip("\n").startswith("<pervio-group") for x in full), [x[:60] for x in full[:2]])
check("G8a the run's title (meta preview) is the words AFTER the header, never the header",
      previews and not any(pv.startswith("<pervio-group") for pv in previews)
      and any(pv.startswith("这题怎么解") for pv in previews), previews[:3])
check("G8b the header names the roster file, so a member can look up the others' ids later",
      full and all(("名册" in x and gid + ".json" in x) for x in full), full[0][:400] if full else "")
# A transcript with a wrapped user message: header stripped, via kept.
proj_key = proj
import importlib.util, importlib.machinery
import importlib.machinery
loader = importlib.machinery.SourceFileLoader("psess", SESSIONS)
psess = importlib.util.module_from_spec(importlib.util.spec_from_loader("psess", loader)); loader.exec_module(psess)
folder = os.path.join(home, ".claude", "projects", psess.encode(proj_key)); os.makedirs(folder, exist_ok=True)
wrapped = '<pervio-group id="%s" from="human" role="主对话" round="1" to="p">\n规则略\n</pervio-group>\n真正的问题' % gid
with open(os.path.join(folder, "sess-P.jsonl"), "w") as f:
    f.write(json.dumps({"type": "user", "cwd": proj_key, "message": {"role": "user", "content": wrapped}}, ensure_ascii=False) + "\n")
    f.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "答"}]}}, ensure_ascii=False) + "\n")
tr = json.loads(subprocess.run([sys.executable, SESSIONS, "transcript", "--dir", proj_key, "--session", "sess-P"],
                               env=e, capture_output=True, text=True).stdout)
check("G9 transcript shows the words after the header, with via=human",
      len(tr) == 2 and tr[0]["text"] == "真正的问题" and tr[0].get("via") == "human", tr)
srch = json.loads(subprocess.run([sys.executable, SESSIONS, "search", "--query", "规则略"],
                                 env=e, capture_output=True, text=True).stdout)
check("G10 the header never becomes a search hit", srch == [], srch)

print("=== a word to one member ===")
p = grp(e, "say", "--id", gid, "--to", "m0", "--text-b64", base64.b64encode("只问你:再说一遍".encode()).decode())
gd = json.loads(p.stdout)
check("G12 say --to m0 starts ONE run on that member, outside the round, and bumps rev",
      p.returncode == 0 and gd.get("lastDirect", {}).get("to") == "m0" and gd["lastDirect"].get("run")
      and gd["round"]["state"] == "done" and gd.get("rev", 0) >= 1, (p.returncode, gd.get("lastDirect"), gd.get("rev")))
check("G12b the direct run resumes the member's own conversation",
      _meta(gd["lastDirect"]["run"])["resume"] == gd["members"][0]["session"], _meta(gd["lastDirect"]["run"]).get("resume"))
p = grp(e, "say", "--id", gid, "--to", "zz", "--text-b64", base64.b64encode(b"x").decode())
check("G12c an unknown member key is refused", p.returncode != 0, p.returncode)
lst = json.loads(subprocess.run([sys.executable, SESSIONS, "list", "--dir", proj_key], env=e, capture_output=True, text=True).stdout)
check("G13 the primary's conversation lists with its group id",
      any(r["id"] == "sess-P" and r.get("group") == gid for r in lst), [(r["id"][:8], r.get("group")) for r in lst][:4])
print("=== set + context ===")
p = grp(e, "set", "--id", gid, "--to", "m0", "--b64", base64.b64encode(json.dumps({"model": "gpt-test-9", "sandbox": ""}).encode()).decode())
gs = json.loads(p.stdout) if p.returncode == 0 else {}
check("G15 set changes one member's model and clears its sandbox, bumps rev",
      p.returncode == 0 and gs["members"][0].get("model") == "gpt-test-9" and "sandbox" not in gs["members"][0]
      and gs.get("rev", 0) > gd.get("rev", 0), (p.returncode, gs.get("members"), gs.get("rev")))
p = grp(e, "set", "--id", gid, "--to", "p", "--b64", base64.b64encode(b"[]").decode())
check("G15b set without an object is refused", p.returncode != 0, p.returncode)
p = grp(e, "set", "--id", gid, "--to", "p", "--b64", base64.b64encode(json.dumps({"provider": "glm"}).encode()).decode())
gs = json.loads(p.stdout) if p.returncode == 0 else {}
check("G15d a member can be put on a provider; it rides to that member's next run",
      p.returncode == 0 and gs["primary"].get("provider") == "glm", (p.returncode, gs.get("primary")))
grp(e, "set", "--id", gid, "--to", "p", "--b64", base64.b64encode(json.dumps({"provider": ""}).encode()).decode())
wait_state(e, gid, "done")
p = grp(e, "say", "--id", gid, "--pervio-context", "--text-b64", base64.b64encode("第三轮".encode()).decode())
g3 = json.loads(p.stdout) if p.returncode == 0 else {}
r3 = g3.get("round", {})
check("G14 say --pervio-context flags the round and every run of it",
      p.returncode == 0 and r3.get("ctx") is True and r3.get("runs", {}).get("p") and r3.get("runs", {}).get("m0")
      and all(_meta(x).get("ctx") is True for x in r3["runs"].values()), (p.returncode, r3.get("ctx"), r3.get("runs")))
check("G15c the next run on that member carries the new model",
      r3.get("runs", {}).get("m0") and _meta(r3["runs"]["m0"]).get("model") == "gpt-test-9", _meta(r3["runs"]["m0"]).get("model") if r3.get("runs", {}).get("m0") else None)
wait_state(e, gid, "done")
print("=== duo (双窗): two windows, no round, context pulled, critique pushed once ===")
home2, e2 = env()
proj2 = os.path.join(home2, "proj"); os.makedirs(proj2)
def tb(s_):
    return base64.b64encode(s_.encode()).decode()
def duo_wait(gid_, timeout=30):
    for _ in range(timeout * 4):
        g_ = json.loads(grp(e2, "tick", "--id", gid_).stdout)
        if not g_["duo"]["live"]:
            return g_
        time.sleep(0.25)
    return g_
p = grp(e2, "create", "--dir", proj2, "--b64", b64({"mode": "duo",
      "primary": {"session": "sess-P", "backend": "claude"}, "members": [{"session": "", "backend": "codex"}]}))
check("D1 create a duo group: no synthesis, an empty live/last ledger", p.returncode == 0 and (lambda g_: g_["mode"] == "duo"
      and g_["autoSynth"] is False and g_["duo"] == {"live": {}, "last": {}})(json.loads(p.stdout)), p.stderr[:200])
gid2 = json.loads(p.stdout)["id"]
p = grp(e2, "create", "--dir", proj2, "--b64", b64({"mode": "duo", "primary": {"session": "x", "backend": "claude"}}))
check("D1b duo needs a second window", p.returncode != 0, p.returncode)
p = grp(e2, "say", "--id", gid2, "--to", "p", "--text-b64", tb("主,你先说\nSHIM:" + json.dumps({"text": "主的答案", "sid": "sess-P"})))
gd = json.loads(p.stdout) if p.returncode == 0 else {}
check("D2 a word to the primary window starts ONE run there and opens no round",
      p.returncode == 0 and gd["duo"]["live"].get("p") and "m0" not in gd["duo"]["live"] and gd["round"]["state"] == "idle",
      (p.returncode, p.stderr[:120], gd.get("duo")))
p = grp(e2, "say", "--id", gid2, "--to", "p", "--text-b64", tb("再说一句"))
check("D3 the same window refuses a second word while it is still answering (exit 4)",
      p.returncode == 4 and "busy" in p.stderr, (p.returncode, p.stderr[:120]))
p = grp(e2, "say", "--id", gid2, "--to", "m0", "--text-b64", tb("伙伴,你说\nSHIM:" + json.dumps({"text": "伙伴的答案", "sid": "sess-M"})))
gd = json.loads(p.stdout) if p.returncode == 0 else {}
check("D4 the OTHER window takes a word meanwhile (independent conversations)",
      p.returncode == 0 and set(gd["duo"]["live"]) >= {"m0"}, (p.returncode, p.stderr[:120]))
gd = duo_wait(gid2)
check("D5 finished replies retire from live into last; the new window learned its session id",
      gd["duo"]["live"] == {} and set(gd["duo"]["last"]) == {"p", "m0"} and gd["members"][0]["session"] == "sess-M"
      and gd.get("rev", 0) >= 3, gd.get("duo"))
full2 = [x for x in open(os.path.join(home2, "prompts.log"), encoding="utf-8").read().split("===PROMPT-END===") if x.strip()]
check("D6 a duo header says it is the two-window mode and that nothing crosses by itself",
      full2 and all("双窗模式" in x and "名册" in x for x in full2), full2[0][:300] if full2 else "")
check("D6b no synthesis, no relay: exactly the two runs the person asked for", len(full2) == 2, len(full2))
p = grp(e2, "say", "--id", gid2, "--to", "p", "--critique", "m0", "--text-b64", tb(""))
gd = json.loads(p.stdout) if p.returncode == 0 else {}
check("D7 critique: the primary gets the partner's LAST reply with a request to judge it (from=critique), no text needed",
      p.returncode == 0 and gd["duo"]["live"].get("p"), (p.returncode, p.stderr[:160]))
duo_wait(gid2)
full2 = [x for x in open(os.path.join(home2, "prompts.log"), encoding="utf-8").read().split("===PROMPT-END===") if x.strip()]
crit = [x for x in full2 if 'from="critique"' in x]
check("D7b the critique message quotes the partner's reply verbatim and asks for a judgement, not a fix",
      len(crit) == 1 and "伙伴的答案" in crit[0] and "请点评" in crit[0] and 'to="p"' in crit[0], crit[0][:300] if crit else full2[-1][:200])
p = grp(e2, "say", "--id", gid2, "--to", "p", "--critique", "p", "--text-b64", tb(""))
check("D7c a window cannot critique itself", p.returncode == 4, (p.returncode, p.stderr[:100]))
p = grp(e2, "say", "--id", gid2, "--to", "all", "--critique", "m0", "--text-b64", tb(""))
check("D7d critique needs one window, not everyone", p.returncode == 4, (p.returncode, p.stderr[:100]))
p = grp(e2, "say", "--id", gid2, "--to", "all", "--text-b64", tb("两位都说说\nSHIM:" + json.dumps({"text": "都答", "sleep": 3})))
gd = json.loads(p.stdout) if p.returncode == 0 else {}
check("D8 a word to everyone is one run per window, still no round", p.returncode == 0 and set(gd["duo"]["live"]) == {"p", "m0"}
      and gd["round"]["state"] == "idle", (p.returncode, p.stderr[:120], gd.get("duo")))
p = grp(e2, "stop", "--id", gid2)
gd = json.loads(p.stdout) if p.returncode == 0 else {}
check("D9 stop kills both windows' runs and clears live", p.returncode == 0 and gd["duo"]["live"] == {}, (p.returncode, p.stderr[:120]))
p = grp(e2, "stop", "--id", gid2)
check("D9b stop with nothing running is refused", p.returncode == 4, p.returncode)
p = grp(e2, "say", "--id", gid2, "--to", "m0", "--text-b64", tb("x"), "--critique", "zz")
check("D10 critique of an unknown window is refused", p.returncode != 0, p.returncode)
shutil.rmtree(home2, ignore_errors=True)

print("=== delete ===")
p = grp(e, "delete", "--id", gid)
check("G11 delete removes the group file",
      json.loads(p.stdout).get("deleted") is True and not os.path.exists(os.path.join(home, ".pervio", "groups", gid + ".json")))
shutil.rmtree(home, ignore_errors=True)

ok = all(results)
print("\n=== pervio-group: %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
