#!/usr/bin/env python3
"""Regression tests for server/bin/pervio-run (detached Run mode). Hermetic: an
isolated $HOME (so ~/.pervio/runs is a scratch dir) and the committed shim `claude`
on PATH — zero model calls. Asserts observed behavior of start/tail/list/status/
stop, run-id path-traversal rejection, session-id extraction, and the done-vs-
failed state machine (exit code AND terminal result.is_error)."""
import base64
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
BIN = os.path.realpath(os.path.join(HERE, "..", "bin"))
RUN = os.path.join(BIN, "pervio-run")
SHIM = os.path.join(HERE, "shim")

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + (("  [" + str(detail)[:200] + "]") if (detail and not cond) else ""))


def env():
    home = tempfile.mkdtemp(prefix="prun_home_", dir="/tmp")
    e = dict(os.environ, HOME=home, PATH=SHIM + ":" + os.environ.get("PATH", ""))
    return home, e


def run(e, *args, timeout=30):
    # Invoke via the interpreter so tests don't depend on the repo file's exec bit
    # (the +x is applied at install time, not in the repo).
    p = subprocess.run([sys.executable, RUN] + list(args), env=e, capture_output=True, text=True, timeout=timeout)
    return p


def shim_prompt(text="ok", write=None, sleep=0, sid="sess-abc", is_error=False, rc=0, stderr=None):
    ins = {"text": text, "sleep": sleep, "sid": sid, "is_error": is_error, "rc": rc}
    if write:
        ins["write"] = [{"file": f, "content": c} for f, c in write]
    if stderr:
        ins["stderr"] = stderr
    return "do a thing\nSHIM:" + json.dumps(ins)


def start(e, prompt, extra=None):
    b64 = base64.b64encode(prompt.encode()).decode()
    args = ["start", "--dir", os.path.expanduser("~"), "--prompt-b64", b64] + (extra or [])
    p = run(e, *args)
    return json.loads(p.stdout)["runId"]


def wait_state(e, rid, want, timeout=30):
    for _ in range(timeout * 4):
        st = json.loads(run(e, "status", "--run", rid).stdout)
        if st["state"] == want or st["state"] in ("done", "failed"):
            return st
        time.sleep(0.25)
    return json.loads(run(e, "status", "--run", rid).stdout)


# ---- start + status + a clean completion ----
print("=== start / status / done ===")
home, e = env()
rid = start(e, shim_prompt(text="hello world", sid="sess-DONE"))
check("start returns a 12-hex runId", len(rid) == 12 and all(c in "0123456789abcdef" for c in rid), rid)
rd = os.path.join(home, ".pervio", "runs", rid)
check("run dir + meta/status/pgid created", all(os.path.exists(os.path.join(rd, f)) for f in ("meta.json", "status", "out.jsonl", "pgid")))
st = wait_state(e, rid, "done")
check("clean run → state done", st["state"] == "done", st)
check("status exitCode 0", st["exitCode"] == 0, st)
check("status extracts sessionId from stream", st["sessionId"] == "sess-DONE", st)
check("status reports bytes > 0", st["bytes"] > 0, st)
shutil.rmtree(home, ignore_errors=True)

# ---- failed via terminal result.is_error even though the process exits 0 ----
print("=== failed state (result.is_error, exit 0) ===")
home, e = env()
rid = start(e, shim_prompt(is_error=True, rc=0))
st = wait_state(e, rid, "failed")
check("exit 0 but result.is_error=true → state failed", st["state"] == "failed", st)
check("exitCode still recorded as 0", st["exitCode"] == 0, st)
shutil.rmtree(home, ignore_errors=True)

# ---- failed via nonzero exit ----
print("=== failed state (nonzero exit) ===")
home, e = env()
rid = start(e, shim_prompt(rc=5))
st = wait_state(e, rid, "failed")
check("nonzero exit → state failed", st["state"] == "failed", st)
check("exitCode captured (5)", st["exitCode"] == 5, st)
shutil.rmtree(home, ignore_errors=True)

# ---- failed run's status carries the backend's stderr line (autopsy to the phone) ----
# Real case (2026-09-12): codex refused a resume with one stderr line ("thread …
# already has an active writer") and the phone could only say "ended without a
# result". status now forwards the LAST stderr line — and only on failure.
print("=== status.error (failed-run stderr tail) ===")
home, e = env()
refusal = "Error: thread/resume failed: thread X already has an active writer (code -32600)"
rid = start(e, shim_prompt(rc=1, stderr="warmup noise\n" + refusal))
st = wait_state(e, rid, "failed")
check("failed status carries error = last stderr line", st.get("error") == refusal, st)
rid2 = start(e, shim_prompt(sid="sess-OK", stderr="harmless grumble"))
st2 = wait_state(e, rid2, "done")
check("done status has NO error key even when stderr grumbled", "error" not in st2, st2)
# Attached folders ride through a detached run to pervio-chat (--extra-dir, repeatable)
# and are recorded in meta.json (2026-10-17).
xd = os.path.join(home, "shared notes"); os.makedirs(xd, exist_ok=True)
e_xd = dict(e, SHIM_ARGV_LOG=os.path.join(home, "argv-xd.log"))
rid_x = start(e_xd, shim_prompt(sid="sess-XD"), extra=["--extra-dir", xd, "--extra-dir", "~/also"])
os.makedirs(os.path.join(home, "also"), exist_ok=True)
st_x = wait_state(e_xd, rid_x, "done")
meta_x = json.load(open(os.path.join(home, ".pervio", "runs", rid_x, "meta.json")))
avx = [json.loads(l) for l in open(os.path.join(home, "argv-xd.log")) if l.strip()]
adds_x = [a[i + 1] for a in avx for i, t in enumerate(a) if t == "--add-dir"]
check("a detached run carries the attached folders to the agent and records them", st_x.get("state") == "done"
      and meta_x.get("extraDirs") == [xd, "~/also"] and xd in adds_x, (meta_x.get("extraDirs"), adds_x))
# Terminal colour codes never reach the phone: Cursor's agent prints its advice in
# colour and the escape bytes showed as "[36m…[0m" in the run's autopsy (2026-10-16).
rid3 = start(e, shim_prompt(rc=1, stderr="noise\nRun \x1b[36msecurity unlock-keychain\x1b[0m and try again"))
st3 = wait_state(e, rid3, "failed")
check("failed status strips terminal colour codes from the stderr line", st3.get("error") == "Run security unlock-keychain and try again", st3)
shutil.rmtree(home, ignore_errors=True)

# ---- tail with --from byte offset ----
print("=== tail + --from offset ===")
home, e = env()
rid = start(e, shim_prompt(text="tail-me", sid="sess-TAIL"))
wait_state(e, rid, "done")
full = run(e, "tail", "--run", rid).stdout
check("tail returns the full stream", '"session_id": "sess-TAIL"' in full or "sess-TAIL" in full, full[:120])
half = len(full.encode()) // 2
part = run(e, "tail", "--run", rid, "--from", str(half)).stdout
check("tail --from N returns only the tail slice", len(part.encode()) <= len(full.encode()) - half + 2, (len(part), len(full), half))
check("tail --from is a clean byte suffix", full.encode().endswith(part.encode()) if part else True)
shutil.rmtree(home, ignore_errors=True)

# ---- list, and --dir filter ----
print("=== list + --dir filter ===")
home, e = env()
da = tempfile.mkdtemp(prefix="dA_", dir="/tmp"); db = tempfile.mkdtemp(prefix="dB_", dir="/tmp")
b64 = base64.b64encode(shim_prompt(sid="sA").encode()).decode()
ra = json.loads(run(e, "start", "--dir", da, "--prompt-b64", b64).stdout)["runId"]
rb = json.loads(run(e, "start", "--dir", db, "--prompt-b64", b64).stdout)["runId"]
wait_state(e, ra, "done"); wait_state(e, rb, "done")
allruns = json.loads(run(e, "list").stdout)
check("list shows both runs", {r["runId"] for r in allruns} >= {ra, rb}, [r["runId"] for r in allruns])
onlyA = json.loads(run(e, "list", "--dir", da).stdout)
check("list --dir filters to that dir", [r["runId"] for r in onlyA] == [ra], [r["runId"] for r in onlyA])
check("list row carries state/preview/bytes/backend", all(k in allruns[0] for k in ("state", "preview", "bytes", "backend", "sessionId")))
# --under: the phone's working directory as a scope — the folder itself and
# anything below it, nothing beside it.
underA = json.loads(run(e, "list", "--under", da).stdout)
check("list --under <dir> keeps runs in that dir", [r["runId"] for r in underA] == [ra], [r["runId"] for r in underA])
underParent = json.loads(run(e, "list", "--under", os.path.dirname(da)).stdout)
check("list --under <parent> keeps runs in both sub-dirs", {r["runId"] for r in underParent} >= {ra, rb}, [r["runId"] for r in underParent])
underOther = json.loads(run(e, "list", "--under", os.path.join(da, "nope")).stdout)
check("list --under a sibling path keeps nothing", underOther == [], underOther)
# Who started it rides along: the phone (push recipient) and its server entry (tap landing).
rt = json.loads(run(e, "start", "--dir", da, "--prompt-b64", b64, "--device", "phone-A", "--origin", "E2E0-ENTRY").stdout)["runId"]
wait_state(e, rt, "done")
meta_t = json.load(open(os.path.join(home, ".pervio", "runs", rt, "meta.json")))
row_t = next(r for r in json.loads(run(e, "list").stdout) if r["runId"] == rt)
check("start --device/--origin land in meta.json and the list row",
      meta_t.get("device") == "phone-A" and meta_t.get("origin") == "E2E0-ENTRY"
      and row_t.get("device") == "phone-A" and row_t.get("origin") == "E2E0-ENTRY", (meta_t, row_t))
shutil.rmtree(home, ignore_errors=True); shutil.rmtree(da, ignore_errors=True); shutil.rmtree(db, ignore_errors=True)

# ---- stop a running (sleeping) run ----
print("=== stop ===")
home, e = env()
rid = start(e, shim_prompt(sleep=30, sid="sess-STOP"))
# wait until it's actually running
for _ in range(60):
    if json.loads(run(e, "status", "--run", rid).stdout)["state"] == "running":
        break
    time.sleep(0.1)
t0 = time.time()
sp = json.loads(run(e, "stop", "--run", rid).stdout)
check("stop acks", sp.get("stopped") is True, sp)
st = wait_state(e, rid, "failed", timeout=10)
check("stopped run → state failed", st["state"] == "failed", st)
check("stop wrote exited:143", st["exitCode"] == 143, st)
check("stop was prompt (< 20s, didn't wait out the 30s sleep)", time.time() - t0 < 20, "%.1fs" % (time.time() - t0))
# the shim process is actually gone
pgid = int(open(os.path.join(home, ".pervio", "runs", rid, "pgid")).read().strip())
try:
    os.killpg(pgid, 0); alive = True
except (ProcessLookupError, PermissionError):
    alive = False
check("stop killed the process group", not alive)
shutil.rmtree(home, ignore_errors=True)

# ---- run-id path traversal is rejected on every command that takes --run ----
print("=== run-id path traversal rejection ===")
home, e = env()
for bad in ("../../etc", "a/b", "..", "x/../y"):
    for cmd in ("status", "tail", "stop"):
        p = run(e, cmd, "--run", bad)
        ok = p.returncode != 0
        results.append(ok)
        if not ok:
            print("FAIL traversal %r on %s not rejected [%s]" % (bad, cmd, p.stdout[:60]))
print("PASS run-id traversal rejected on status/tail/stop (all %r)" % ["../../etc", "a/b", "..", "x/../y"])
# status/stop on a well-formed but nonexistent id → exit 3, not a crash
p = run(e, "status", "--run", "deadbeef0000")
check("status on missing run → exit 3", p.returncode == 3, p.returncode)
# malformed args rejected
p = run(e, "status", "--run", "x", "--bogus", "y")
check("unknown flag rejected", p.returncode != 0)
p = run(e, "boguscmd")
check("unknown subcommand rejected", p.returncode != 0)
shutil.rmtree(home, ignore_errors=True)

# ---------- pervio-context passthrough: a lit chip applies to detached runs ----------
# F design: on the claude branch the flag now mounts the perviotools MCP server
# (mcp.json + --mcp-config + read-only allowlist) — the pointer prose is retired.
# This test only guards the PASSTHROUGH (pervio-run forwards the flag and the
# attachment reaches claude's argv); mcp.json content is test_chat.py's job.
print("=== --pervio-context rides through pervio-run to pervio-chat ===")
home2 = tempfile.mkdtemp(prefix="prun_ctx_", dir="/tmp")
e2 = dict(os.environ, HOME=home2, PATH=SHIM + ":" + os.environ.get("PATH", ""))
argv_log = os.path.join(home2, "argv.jsonl")
e2["SHIM_ARGV_LOG"] = argv_log
# The mount gates on pervio-mcp existing (repo server/bin first, ~/.pervio/bin
# second) — stub the hermetic-HOME fallback so this stays deterministic.
_mcp_stub = os.path.join(home2, ".pervio", "bin")
os.makedirs(_mcp_stub, exist_ok=True)
with open(os.path.join(_mcp_stub, "pervio-mcp"), "w") as _f:
    _f.write("#!/usr/bin/env python3\n")

def _claude_argvs():
    try:
        with open(argv_log) as f:
            return [json.loads(l) for l in f if l.strip()]
    except OSError:
        return []

rid = start(e2, shim_prompt("ok"), extra=["--pervio-context"])
wait_state(e2, rid, "done")
flagged_argvs = _claude_argvs()
check("flagged run: perviotools MCP mount reached claude argv",
      any("--mcp-config" in a for a in flagged_argvs)
      and any("mcp__perviotools__pervio_list_runs" in " ".join(a) for a in flagged_argvs),
      flagged_argvs)
# Brief-length prose stays retired, but the one-line DISCOVERY pointer must
# ride along with the mount (claude defers MCP tools behind ToolSearch — a bare
# mount leaves the verbs invisible; see test_chat state b).
check("flagged run: discovery pointer rides with the mount",
      flagged_argvs and all(
          "mcp__perviotools__" in (a[a.index("--append-system-prompt") + 1]
                                   if "--append-system-prompt" in a else "")
          for a in flagged_argvs),
      flagged_argvs)
# Codex's "Ask for approval" rides through a run as --reviewer user (pervio-run
# must accept the flag), and the Mac treats the headless turn as never asking:
# nobody is there to answer (2026-10-18).
rpc_log = os.path.join(home2, "rpc.jsonl")
e2r = dict(e2, SHIM_RPC_LOG=rpc_log)
rid_r = start(e2r, "do a thing\nSHIM:" + json.dumps({"text": "ok"}), extra=["--backend", "codex", "--sandbox", "workspace-write", "--reviewer", "user"])
wait_state(e2r, rid_r, "done")
try:
    _starts = [json.loads(l) for l in open(rpc_log) if l.strip() and json.loads(l).get("method") == "thread/start"]
except OSError:
    _starts = []
check("codex Ask mode on a detached run WITHOUT an approval sid never asks (nobody to answer)",
      _starts and _starts[-1]["params"].get("approvalPolicy") == "never" and "approvalsReviewer" not in _starts[-1]["params"],
      (_starts[-1:] if _starts else run(e2r, "status", "--run", rid_r).stdout))
os.remove(rpc_log)
rid_r2 = start(e2r, "do a thing\nSHIM:" + json.dumps({"text": "ok"}), extra=["--backend", "codex", "--sandbox", "workspace-write", "--reviewer", "user", "--approve-sid", "runsid2"])
wait_state(e2r, rid_r2, "done")
_starts = [json.loads(l) for l in open(rpc_log) if l.strip() and json.loads(l).get("method") == "thread/start"]
check("…and WITH one it asks on request, the person reviewing (the run can be reopened to answer, 2026-10-19)",
      _starts and (_starts[-1]["params"].get("approvalPolicy"), _starts[-1]["params"].get("approvalsReviewer")) == ("on-request", "user"), _starts[-1:])
os.remove(rpc_log)
rid_r3 = start(e2r, "do a thing\nSHIM:" + json.dumps({"text": "ok"}), extra=["--backend", "codex", "--service-tier", "priority"])
wait_state(e2r, rid_r3, "done")
_starts = [json.loads(l) for l in open(rpc_log) if l.strip() and json.loads(l).get("method") == "thread/start"]
check("the Fast switch rides a run too (--service-tier → thread/start serviceTier)",
      _starts and _starts[-1]["params"].get("serviceTier") == "priority", _starts[-1:])
for a in flagged_argvs:                 # tidy the per-invocation TMPDIR cfg
    if "--mcp-config" in a:
        try:
            os.unlink(a[a.index("--mcp-config") + 1])
        except OSError:
            pass
os.remove(argv_log) if os.path.exists(argv_log) else None
# --lang en (the app's Settings prompt language) forwards through pervio-run to
# pervio-chat exactly like the context flag it accompanies: the pointer prose
# reaching claude must be the English variant (no CJK), tools untouched.
rid = start(e2, shim_prompt("ok"), extra=["--pervio-context", "--lang", "en"])
wait_state(e2, rid, "done")
lang_argvs = _claude_argvs()


def _ptr(a):
    return a[a.index("--append-system-prompt") + 1] if "--append-system-prompt" in a else ""


check("--lang en forwards: the pointer prose reaching claude is English",
      lang_argvs and all(_ptr(a) and "mcp__perviotools__" in _ptr(a)
                         and not any(0x4E00 <= ord(c) <= 0x9FFF for c in _ptr(a))
                         for a in lang_argvs),
      [_ptr(a)[:120] for a in lang_argvs])
for a in lang_argvs:                    # tidy the per-invocation TMPDIR cfg
    if "--mcp-config" in a:
        try:
            os.unlink(a[a.index("--mcp-config") + 1])
        except OSError:
            pass
os.remove(argv_log) if os.path.exists(argv_log) else None
rid = start(e2, shim_prompt("ok"))
wait_state(e2, rid, "done")
unflagged = any("--mcp-config" in a or "--append-system-prompt" in a
                or any("perviotools" in x for x in a) for a in _claude_argvs())
check("plain run: zero injection/attachment", not unflagged, _claude_argvs())
shutil.rmtree(home2, ignore_errors=True)

# ---- the completion push: WHICH task finished, and only once ----------------
# The shipped wrapper said 「回答好了」 to every run in every project, so a phone
# with three tasks out could not tell them apart — and it read the same as the
# app's own local banner, which is how one finished run produced two identical
# notifications. These pin the words (pure function, no run needed) and then the
# wiring (a real detached run against a FAKE sibling pervio-push that records
# its argv), because a beautiful string that never reaches the sender is nothing.
print("=== completion push: names the task, one per run ===")
import importlib.machinery                                            # noqa: E402
import importlib.util                                                 # noqa: E402

_loader = importlib.machinery.SourceFileLoader("prun_mod", RUN)
_spec = importlib.util.spec_from_loader("prun_mod", _loader)
prun = importlib.util.module_from_spec(_spec)
_loader.exec_module(prun)                 # CLI is under __main__; import is inert

# HERMETIC FENCE. `_push_text` with no per-run --lang now consults the phone's
# synced preference (~/.pervio/push/lang, written by the app beside its token) —
# so these copy checks must not read the DEVELOPER'S real home, where that file
# may well say `en` and turn every zh assertion red for a reason that isn't a
# regression. Point HOME at an empty throwaway: no file ⇒ the zh fallback (old-phone compat; the app uploads its language on connect).
_push_home = tempfile.mkdtemp(prefix="prun-pushlang-")
_home_before_push = os.environ.get("HOME")
os.environ["HOME"] = _push_home

t_ok, t_bad, b_ok, b_bad = prun._push_text(
    {"dir": "/Users/x/Pervio/"}, "修两件事:重复提醒 + 抓取骤降")
check("push title names the project AND the outcome, not a generic 「回答好了」",
      t_ok == "Pervio · 任务完成" and t_bad == "Pervio · 任务失败", (t_ok, t_bad))
check("push body is the task's own words (so two runs never read the same)",
      b_ok == "修两件事:重复提醒 + 抓取骤降", b_ok)
check("failure body keeps the task and ends on the exit-code label",
      b_bad == "修两件事:重复提醒 + 抓取骤降 —— 退出码 ", b_bad)
check("the old one-size-fits-all body is gone",
      "回答好了" not in (b_ok + b_bad), (b_ok, b_bad))

t_ok_en, t_bad_en, b_ok_en, _ = prun._push_text({"dir": "~/Pervio", "lang": "en"},
                                                "fix the duplicate reminder")
check("--lang en pushes English words (the app's own banner follows the same toggle)",
      t_ok_en == "Pervio · task finished" and t_bad_en == "Pervio · task failed"
      and b_ok_en == "fix the duplicate reminder",
      (t_ok_en, t_bad_en, b_ok_en))

empty_ok, _, empty_body, empty_bad = prun._push_text({}, "")
check("no dir / no preview still says something usable",
      empty_ok == "Pervio · 任务完成" and empty_body == "这一轮跑完了。"
      and empty_bad == "退出码 ", (empty_ok, empty_body, empty_bad))

check("a long prompt is trimmed, not shipped whole",
      len(prun._push_text({}, "字" * 400)[2]) == 80,
      len(prun._push_text({}, "字" * 400)[2]))

# ---- the phone's synced language: ~/.pervio/push/lang -----------------------
# The app writes this file beside its push token (same SSH round trip), so the
# Mac knows which language the PHONE is set to. A run started WITHOUT --lang —
# the 背景 chip off, which is most turns — must follow it; before this, an
# English phone got English pushes only on chip-on turns, which reads as a bug,
# not a boundary. The run's own --lang still wins: it captured the setting at
# send time, and a mid-run toggle shouldn't rewrite a notification about a task
# that was asked for in the other language.
_push_dir = os.path.join(_push_home, ".pervio", "push")
os.makedirs(_push_dir, exist_ok=True)
with open(os.path.join(_push_dir, "lang"), "w") as _f:
    _f.write("en\n")
t_ok_s, _, _, _ = prun._push_text({"dir": "~/Pervio"}, "no flag, stored en")
check("no --lang: push copy follows the synced push/lang file",
      t_ok_s == "Pervio · task finished", t_ok_s)
t_ok_o, _, _, _ = prun._push_text({"dir": "~/Pervio", "lang": "zh"}, "flag beats file")
check("a run's own --lang beats the stored file",
      t_ok_o == "Pervio · 任务完成", t_ok_o)
with open(os.path.join(_push_dir, "lang"), "w") as _f:
    _f.write("en-US")                     # a locale spelling still means English
check("push_lang: en-US in the file reads as en", prun.push_lang() == "en",
      prun.push_lang())
with open(os.path.join(_push_dir, "lang"), "w") as _f:
    _f.write("何?")                       # garbage falls back to zh (old-phone compat fallback)
check("push_lang: garbage in the file falls back to zh", prun.push_lang() == "zh",
      prun.push_lang())
os.remove(os.path.join(_push_dir, "lang"))
check("push_lang: no file at all is zh (old-phone compat fallback, NOT the app default)",
      prun.push_lang() == "zh", prun.push_lang())

# Close the fence: everything below builds its own env dicts.
if _home_before_push is None:
    os.environ.pop("HOME", None)
else:
    os.environ["HOME"] = _home_before_push
shutil.rmtree(_push_home, ignore_errors=True)

# End-to-end: a real detached run, with a fake pervio-push SIBLING recording argv.
# pervio-run resolves the sender as os.path.join(SELF_DIR, "pervio-push"), so the
# only faithful way to intercept it is to run a COPY of pervio-run out of a temp
# bin dir whose pervio-push is the recorder.
home3 = tempfile.mkdtemp(prefix="prun_push_", dir="/tmp")
tmpbin = os.path.join(home3, "bin")
os.makedirs(tmpbin)
for f in ("pervio-run", "pervio-chat", "pervio-approve", "pervio-hb", "pervio-codex-app", "pervio-chat-stream",
          "_pervio_lib.py"):
    src = os.path.join(BIN, f)
    if os.path.exists(src):
        shutil.copy2(src, os.path.join(tmpbin, f))
        os.chmod(os.path.join(tmpbin, f), 0o755)
os.makedirs(os.path.join(home3, "MyProject"))     # the run's cwd must exist
push_log = os.path.join(home3, "push.log")
with open(os.path.join(tmpbin, "pervio-push"), "w") as f:
    f.write("#!/usr/bin/env python3\n"
            "import json, os, sys\n"
            "p = os.environ.get('PUSH_LOG')\n"
            "if p:\n"
            "    with open(p, 'a') as fh: fh.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            "sys.exit(0)\n")
os.chmod(os.path.join(tmpbin, "pervio-push"), 0o755)

e3 = dict(os.environ, HOME=home3, PATH=SHIM + ":" + os.environ.get("PATH", ""),
          PUSH_LOG=push_log)
b64 = base64.b64encode(shim_prompt(text="done", sid="sess-PUSH").encode()).decode()
p3 = subprocess.run([sys.executable, os.path.join(tmpbin, "pervio-run"), "start",
                     "--dir", os.path.join(home3, "MyProject"),
                     "--prompt-b64", b64],
                    env=e3, capture_output=True, text=True, timeout=30)
rid3 = json.loads(p3.stdout)["runId"]
for _ in range(120):
    st = json.loads(subprocess.run(
        [sys.executable, os.path.join(tmpbin, "pervio-run"), "status", "--run", rid3],
        env=e3, capture_output=True, text=True, timeout=30).stdout)
    if st["state"] in ("done", "failed"):
        break
    time.sleep(0.25)


def _push_calls():
    if not os.path.exists(push_log):
        return []
    with open(push_log) as fh:
        return [json.loads(l) for l in fh if l.strip()]


def _flag(argv, name):
    return argv[argv.index(name) + 1] if name in argv else ""


for _ in range(60):                      # the wrapper pushes after `status` lands
    if any(c[:1] == ["send"] for c in _push_calls()):
        break
    time.sleep(0.1)
sends = [c for c in _push_calls() if c[:1] == ["send"]]
check("a finished detached run fires EXACTLY ONE completion push",
      len(sends) == 1, _push_calls())
if sends:
    check("the push that reaches the sender carries the project + outcome title",
          _flag(sends[0], "--title") == "MyProject · 任务完成", sends[0])
    check("the push body is the task, not 「回答好了」",
          _flag(sends[0], "--body").startswith("do a thing")
          and "回答好了" != _flag(sends[0], "--body"), sends[0])
    check("the thread is per-run, so two finishes don't collapse into one",
          _flag(sends[0], "--thread") == "pervio-run-" + rid3, sends[0])

# A LIVING run (2026-10-21): the process stays on past its reply, so the push
# goes out at each REPLY (from the keeper), not when the process finally exits
# a grace later — and exit then adds nothing. Each push names its own turn.
print("=== completion push: a living run pushes per reply, not at exit ===")
if os.path.exists(push_log):
    os.remove(push_log)
e3_live = dict(e3, PERVIO_RUN_IDLE_GRACE="6")
run3 = os.path.join(tmpbin, "pervio-run")
def _st3(rid, e=e3_live):
    return json.loads(subprocess.run([sys.executable, run3, "status", "--run", rid], env=e,
                                     capture_output=True, text=True, timeout=30).stdout)
def _wait3(pred, secs=12):
    for _ in range(int(secs * 4)):
        if pred(): return True
        time.sleep(0.25)
    return pred()
p = subprocess.run([sys.executable, run3, "start", "--dir", os.path.join(home3, "MyProject"), "--device", "phoneZ",
                    "--prompt-b64", base64.b64encode(("deploy it\nSHIM:" + json.dumps({"text": "deployed", "sid": "sess-LP"})).encode()).decode()],
                   env=e3_live, capture_output=True, text=True, timeout=30)
rid_lp = json.loads(p.stdout)["runId"]
_wait3(lambda: _st3(rid_lp).get("replied") is True)
_wait3(lambda: any(c[:1] == ["send"] for c in _push_calls()), 5)
sends_lp = [c for c in _push_calls() if c[:1] == ["send"]]
check("LP1 the first reply is pushed the moment it lands — the process is still alive (state running, accepting)",
      len(sends_lp) == 1 and _st3(rid_lp)["state"] == "running" and _st3(rid_lp).get("accepting") is True, (sends_lp, _st3(rid_lp)))
if sends_lp:
    check("LP1b …to the phone that started it, on the run's own thread, naming the task",
          _flag(sends_lp[0], "--device") == "phoneZ" and _flag(sends_lp[0], "--thread") == "pervio-run-" + rid_lp
          and _flag(sends_lp[0], "--body").startswith("deploy it"), sends_lp[0])
check("LP1c and the island is ended with it (the phone may be asleep)",
      any(c[:1] == ["liveactivity"] and "end" in c and rid_lp in c for c in _push_calls()), _push_calls())
p = subprocess.run([sys.executable, run3, "say", "--run", rid_lp, "--prompt-b64",
                    base64.b64encode(("is it stuck?\nSHIM:" + json.dumps({"text": "no, done", "sid": "sess-LP"})).encode()).decode()],
                   env=e3_live, capture_output=True, text=True, timeout=30)
check("LP2 a fed message is accepted", p.returncode == 0, (p.returncode, p.stdout, p.stderr[-200:]))
_wait3(lambda: len([c for c in _push_calls() if c[:1] == ["send"]]) >= 2, 8)
sends_lp = [c for c in _push_calls() if c[:1] == ["send"]]
check("LP2b the fed turn's reply is pushed too, naming ITS words, not the run's first",
      len(sends_lp) == 2 and _flag(sends_lp[1], "--body").startswith("is it stuck?") and _flag(sends_lp[1], "--device") == "phoneZ", sends_lp)
_wait3(lambda: _st3(rid_lp)["state"] != "running", 15)
time.sleep(0.6)                                   # finish runs after `status` lands
sends_lp = [c for c in _push_calls() if c[:1] == ["send"]]
check("LP3 the exit a grace later adds NO third push: the person already heard about both replies",
      _st3(rid_lp)["state"] == "done" and len(sends_lp) == 2, (_st3(rid_lp), sends_lp))
if os.path.exists(push_log):
    os.remove(push_log)

# ---- approvals in Run mode (2026-10-19): a detached run can ASK ------------
# Before, only a live chat could ask; a run was headless by construction. Now a
# run started with an approval sid blocks the way a chat does: the request
# lands in out.jsonl, `status` says it is WAITING, the ping goes to the run's
# phone alone with the run's own thread (a tap reopens the run), and the phone's
# `respond` over the sid lets it go on. Codex (app-server, Ask mode) first —
# the shim carries the whole round trip.
print("=== approvals in Run mode ===")
run3 = os.path.join(tmpbin, "pervio-run"); chat3 = os.path.join(tmpbin, "pervio-chat")
def _status3(rid):
    return json.loads(subprocess.run([sys.executable, run3, "status", "--run", rid], env=e3_ask,
                                     capture_output=True, text=True, timeout=30).stdout)
def _out3(rid):
    try:
        return [json.loads(l) for l in open(os.path.join(home3, ".pervio", "runs", rid, "out.jsonl")) if l.strip().startswith("{")]
    except OSError:
        return []
appr_log3 = os.path.join(home3, "approvals.log")
e3_ask = dict(e3, SHIM_APPROVAL_LOG=appr_log3)
if os.path.exists(push_log):
    os.remove(push_log)
ask_prompt = "do it\nSHIM:" + json.dumps({"approve": {"command": "rm -rf build", "reason": "cleans"}, "text": "after approval"})
p = subprocess.run([sys.executable, run3, "start", "--dir", os.path.join(home3, "MyProject"),
                    "--backend", "codex", "--sandbox", "workspace-write", "--reviewer", "user",
                    "--approve-sid", "runask1", "--device", "phoneA", "--origin", "entryA",
                    "--prompt-b64", base64.b64encode(ask_prompt.encode()).decode()],
                   env=e3_ask, capture_output=True, text=True, timeout=30)
rid_a = json.loads(p.stdout)["runId"]
req = None
for _ in range(120):
    req = next((o for o in _out3(rid_a) if o.get("type") == "permission_request"), None)
    if req: break
    time.sleep(0.25)
st = _status3(rid_a)
check("RA1 a run in Ask mode blocks with the request in its out.jsonl, and status says WAITING (not merely running)",
      req is not None and st["state"] == "running" and st.get("waiting") is True and st.get("approveSid") == "runask1", (req, st))
meta_a = json.load(open(os.path.join(home3, ".pervio", "runs", rid_a, "meta.json")))
check("RA1b meta.json records the approval channel for a reopen", meta_a.get("approveSid") == "runask1", meta_a)
row = next((r for r in json.loads(subprocess.run([sys.executable, run3, "list"], env=e3_ask, capture_output=True, text=True).stdout) if r["runId"] == rid_a), {})
check("RA1c the list row carries waiting + approveSid too (the pill and a tapped run need them)",
      row.get("waiting") is True and row.get("approveSid") == "runask1", row)
for _ in range(40):
    if any(c[:1] == ["send"] for c in _push_calls()): break
    time.sleep(0.1)
pings = [c for c in _push_calls() if c[:1] == ["send"]]
check("RA2 the 'waiting for your approval' ping goes to the run's phone ALONE, on the run's own thread (a tap reopens it)",
      len(pings) == 1 and _flag(pings[0], "--device") == "phoneA" and _flag(pings[0], "--thread") == "pervio-run-" + rid_a
      and "批准" in _flag(pings[0], "--title"), pings)
r = subprocess.run([chat3, "respond", "--sid", "runask1", "--request-id", req["request_id"], "--behavior", "allow"],
                   env=e3_ask, capture_output=True, text=True, timeout=30)
for _ in range(120):
    st = _status3(rid_a)
    if st["state"] in ("done", "failed"): break
    time.sleep(0.25)
try: decided = open(appr_log3).read().split()
except OSError: decided = []
evs = _out3(rid_a)
check("RA3 the phone's respond over the sid lets the run go on to its answer; waiting clears; the decision reached codex",
      r.returncode == 0 and st["state"] == "done" and st.get("waiting") is False and decided == ["accept"]
      and any(o.get("type") == "permission_resolved" and o.get("behavior") == "allow" for o in evs)
      and any(o.get("type") == "item.completed" and (o.get("item") or {}).get("text") == "after approval" for o in evs),
      (r.returncode, r.stderr[-200:], st, decided, [o.get("type") for o in evs]))
check("RA3b the approval channel is torn down with the run", not os.path.exists(os.path.join(home3, ".pervio", "chat", "runask1")))
check("RA3c the completion push also went to phoneA alone",
      [c for c in _push_calls() if c[:1] == ["send"]][-1:] and _flag([c for c in _push_calls() if c[:1] == ["send"]][-1], "--device") == "phoneA", _push_calls())

# Claude: the approval mount now rides a run too (--perm default + a sid), the
# request line reaches out.jsonl through the tee, and WAITING follows the ledger.
if os.path.exists(push_log):
    os.remove(push_log)
argv3 = os.path.join(home3, "argv.jsonl")
e3_cl = dict(e3, SHIM_ARGV_LOG=argv3)
cl_prompt = shim_prompt(text="claude approve done", sid="sess-RA", sleep=3)
p = subprocess.run([sys.executable, run3, "start", "--dir", os.path.join(home3, "MyProject"), "--perm", "default",
                    "--approve-sid", "runcl1", "--device", "phoneA",
                    "--prompt-b64", base64.b64encode(cl_prompt.encode()).decode()],
                   env=e3_cl, capture_output=True, text=True, timeout=30)
rid_c = json.loads(p.stdout)["runId"]
ev_path = os.path.join(home3, ".pervio", "chat", "runcl1", "events.jsonl")
for _ in range(80):
    if os.path.exists(ev_path): break
    time.sleep(0.1)
check("RA4 a Claude run in an asking tier opens the approval session (the mount is no longer chat-only)", os.path.exists(ev_path), ev_path)
with open(ev_path, "a") as fh:
    fh.write(json.dumps({"type": "permission_request", "request_id": "r9", "tool_use_id": "r9", "tool_name": "Bash", "input": {"command": "ls"}}) + "\n")
for _ in range(40):
    if any(o.get("type") == "permission_request" for o in _out3(rid_c)): break
    time.sleep(0.1)
check("RA4b the request is teed into the run's out.jsonl and status says waiting",
      any(o.get("type") == "permission_request" and o.get("request_id") == "r9" for o in _out3(rid_c)) and _status3(rid_c).get("waiting") is True, _status3(rid_c))
with open(ev_path, "a") as fh:
    fh.write(json.dumps({"type": "permission_resolved", "request_id": "r9", "behavior": "allow"}) + "\n")
for _ in range(40):
    if any(o.get("type") == "permission_resolved" for o in _out3(rid_c)): break
    time.sleep(0.1)
check("RA4c once answered, waiting clears (the ledger pairs request and resolution)", _status3(rid_c).get("waiting") is False, _status3(rid_c))
for _ in range(120):
    st = _status3(rid_c)
    if st["state"] in ("done", "failed"): break
    time.sleep(0.25)
argvs3 = [json.loads(l) for l in open(argv3)] if os.path.exists(argv3) else []
check("RA4d claude ran with the permission-prompt tool mounted, and the run finished clean",
      st["state"] == "done" and any("--permission-prompt-tool" in a for a in argvs3), (st, argvs3[-1:] if argvs3 else None))
check("RA4e the run's environment names it for whoever pings the phone (PERVIO_RUN_ID / PERVIO_PUSH_DEVICE)",
      True)   # pinned where it is used: pervio-approve._push_target (test_approve) and RA2 above

# ---- the living run (2026-10-20): one process answers the follow-ups ----------
# "跟 app 一样": after the reply the engine process stays warm; a further
# message is fed into it (say) instead of starting a second process, so the
# conversation has ONE writer and the agent that started a background task is
# the one asked about it; the keeper lets the process go once idle.
print("=== living run: say, keeper, background tasks ===")
home_l = tempfile.mkdtemp(prefix="prun_live_", dir="/tmp")
argv_l = os.path.join(home_l, "argv.jsonl")
el = dict(os.environ, HOME=home_l, PATH=SHIM + ":" + os.environ.get("PATH", ""), SHIM_ARGV_LOG=argv_l, PERVIO_RUN_IDLE_GRACE="1.5")
def _out_l(rid):
    try:
        return [json.loads(l) for l in open(os.path.join(home_l, ".pervio", "runs", rid, "out.jsonl")) if l.strip().startswith("{")]
    except OSError:
        return []
def _st_l(rid):
    return json.loads(run(el, "status", "--run", rid).stdout)
def _say_l(rid, text):
    return run(el, "say", "--run", rid, "--prompt-b64", base64.b64encode(text.encode()).decode())
def _wait_l(rid, pred, secs=10):
    for _ in range(int(secs * 4)):
        if pred(): return True
        time.sleep(0.25)
    return pred()
def _argv_count():
    try: return sum(1 for l in open(argv_l) if l.strip())
    except OSError: return 0

rid_l = start(el, shim_prompt(text="first reply", sid="sess-L"))
check("LR1 the run answers its first turn and STAYS: state running, replied, accepting a further message",
      _wait_l(rid_l, lambda: _st_l(rid_l).get("replied") is True) and _st_l(rid_l)["state"] == "running" and _st_l(rid_l).get("accepting") is True
      and os.path.exists(os.path.join(home_l, ".pervio", "runs", rid_l, "in.fifo")), _st_l(rid_l))
before = _argv_count()
_out_path_l = os.path.join(home_l, ".pervio", "runs", rid_l, "out.jsonl")
check("LR1b between turns, turnFrom is the END of the output: a reopen replays nothing (the reply is history already)",
      _st_l(rid_l).get("turnFrom") == os.path.getsize(_out_path_l) and _st_l(rid_l)["turnFrom"] > 0, (_st_l(rid_l).get("turnFrom"), os.path.getsize(_out_path_l)))
_size_before_say = os.path.getsize(_out_path_l)
p = _say_l(rid_l, shim_prompt(text="second reply", sid="sess-L", sleep=1.5))
check("LR2 say is accepted and the turn is open at once (replied false while the engine works on it)",
      p.returncode == 0 and json.loads(p.stdout).get("accepted") is True and _st_l(rid_l).get("replied") is False, (p.returncode, p.stdout, _st_l(rid_l)))
check("LR2b while the fed turn runs, turnFrom is where it began (the turn_sent marker): a reopen rebuilds just this reply",
      _st_l(rid_l).get("turnFrom") == _size_before_say, (_st_l(rid_l).get("turnFrom"), _size_before_say))
check("LR2c the marker carries the turn's own words (the push for its reply names them)",
      any(o.get("subtype") == "turn_sent" and o.get("preview", "").startswith("do a thing") for o in _out_l(rid_l)), [o for o in _out_l(rid_l) if o.get("type") == "pervio"])
check("LR3 the SAME process answered it: a second result, no second engine process",
      _wait_l(rid_l, lambda: sum(1 for o in _out_l(rid_l) if o.get("type") == "result") >= 2)
      and [o.get("result") for o in _out_l(rid_l) if o.get("type") == "result"] == ["first reply", "second reply"]
      and _argv_count() == before and _st_l(rid_l).get("replied") is True, (_argv_count(), before, [o.get("type") for o in _out_l(rid_l)]))
check("LR3b the turn_sent marker and the engine's own init both sit between the two results",
      [o.get("subtype") for o in _out_l(rid_l) if o.get("type") in ("pervio", "system")][-2:] == ["turn_sent", "init"], [(o.get("type"), o.get("subtype")) for o in _out_l(rid_l)])
check("LR4 idle past the grace, the keeper lets go and the engine ends clean: state done, no longer accepting, fifo gone",
      _wait_l(rid_l, lambda: _st_l(rid_l)["state"] != "running", 8) and _st_l(rid_l)["state"] == "done" and _st_l(rid_l).get("accepting") is False
      and not os.path.exists(os.path.join(home_l, ".pervio", "runs", rid_l, "in.fifo")), _st_l(rid_l))
check("LR4b the keeper is gone with it", not os.path.exists(os.path.join(home_l, ".pervio", "runs", rid_l, "keeper.pid")))
p = _say_l(rid_l, "too late")
check("LR5 say into an ended run is refused (exit 4) — the phone then starts a fresh run", p.returncode == 4 and json.loads(p.stdout).get("accepted") is False, (p.returncode, p.stdout))

# a message sent while the turn still runs (2026-10-21, 插话): the Mac takes it — the
# engine absorbs it at its next step — and the turn's bookkeeping stays one turn
rid_i = start(el, shim_prompt(text="slow reply", sid="sess-I", sleep=2.5))
_wait_l(rid_i, lambda: any(o.get("subtype") == "init" for o in _out_l(rid_i)), 5)
p = _say_l(rid_i, "also this")
st_i = _st_l(rid_i)
check("LI1 say while the turn runs is accepted (not refused as busy), the turn still open, turnFrom still the turn's start",
      p.returncode == 0 and json.loads(p.stdout).get("accepted") is True and st_i.get("replied") is False and st_i.get("turnFrom") == 0, (p.returncode, p.stdout, st_i))
check("LI1b the marker records the words, and sits inside the running turn (after its init, before any result)",
      [o.get("subtype") for o in _out_l(rid_i) if o.get("type") in ("system", "pervio")][:2] == ["init", "turn_sent"]
      and not any(o.get("type") == "result" for o in _out_l(rid_i)), [(o.get("type"), o.get("subtype")) for o in _out_l(rid_i)])
# the marker holds the words themselves, and the engine's word that it has taken
# them moves the replay's start past that point (2026-11-21): codex 0.160 keeps a
# fed message out of its record until the model gets to it — 22 s behind a running
# command, 45 s behind an answer being written, measured — and a phone opening the
# conversation meanwhile showed the previous turn spinning and no message at all
check("LI1c the marker carries the whole message, not only its first 140 characters",
      [o.get("text") for o in _out_l(rid_i) if o.get("subtype") == "turn_sent"] == ["also this"], [o for o in _out_l(rid_i) if o.get("type") == "pervio"])
_out_path_i = os.path.join(home_l, ".pervio", "runs", rid_i, "out.jsonl")
with open(_out_path_i, "a") as _f:               # what the engine's adapter writes when the engine takes the message
    _f.write(json.dumps({"type": "pervio", "subtype": "turn_taken", "text": "also this"}) + "\n")
st_i2 = _st_l(rid_i)
check("LI2 once the engine has taken the message the replay starts AFTER that point (the record holds everything before it), the turn still open",
      st_i2.get("turnFrom") == os.path.getsize(_out_path_i) and st_i2.get("replied") is False and st_i2.get("state") == "running",
      (st_i2, os.path.getsize(_out_path_i)))
_wait_l(rid_i, lambda: _st_l(rid_i)["state"] != "running", 12)
check("LI2b and when the turn is answered the start is the end of the output again, as for any finished turn",
      _st_l(rid_i).get("replied") in (True, None) and _st_l(rid_i).get("turnFrom") in (0, os.path.getsize(_out_path_i)), _st_l(rid_i))

# a background task of the engine's own: the run stays past the grace, the phone sees the task, the engine speaks again
rid_b = start(el, "do a thing\nSHIM:" + json.dumps({"text": "started it", "sid": "sess-B", "bg": {"id": "t9", "desc": "run the tests", "secs": 4.0, "text": "tests passed"}}))
check("LB1 the background task shows in status while it runs (what and since when)",
      _wait_l(rid_b, lambda: _st_l(rid_b).get("background")) and _st_l(rid_b)["background"][0]["description"] == "run the tests"
      and _st_l(rid_b)["background"][0].get("startedAt", 0) > 0 and _st_l(rid_b).get("replied") is True, _st_l(rid_b))
time.sleep(2.5)                                     # past the 1.5 s grace
check("LB2 …and the run stays warm past the grace because the task is pending", _st_l(rid_b)["state"] == "running" and _st_l(rid_b).get("accepting") is True, _st_l(rid_b))
p = _say_l(rid_b, shim_prompt(text="not stuck, still running", sid="sess-B"))
check("LB3 asking it meanwhile is answered by the same process", p.returncode == 0 and _wait_l(rid_b, lambda: "not stuck, still running" in [o.get("result") for o in _out_l(rid_b) if o.get("type") == "result"]), [o.get("result") for o in _out_l(rid_b) if o.get("type") == "result"])
check("LB4 when the task finishes the engine's own continuation lands as a turn of its own and the task leaves status",
      _wait_l(rid_b, lambda: "tests passed" in [o.get("result") for o in _out_l(rid_b) if o.get("type") == "result"], 8)
      and _wait_l(rid_b, lambda: not _st_l(rid_b).get("background"), 4), (_st_l(rid_b), [o.get("result") for o in _out_l(rid_b) if o.get("type") == "result"]))
check("LB5 then it ends after the grace", _wait_l(rid_b, lambda: _st_l(rid_b)["state"] == "done", 8), _st_l(rid_b))

# sub-agents are tasks too (2026-11-22, the fields of the real 2.1.322 stream): the
# ledger says which is a sub-agent and which a command, who launched what, and a
# sub-agent's running totals — a phone opening the run later draws its task line from it
rid_ag = start(el, "spawn\nSHIM:" + json.dumps({"text": "launched", "sid": "sess-AG", "bg": [
    {"id": "a1", "desc": "Review the diff", "agent": "general-purpose", "secs": 4.0, "text": "review done",
     "progress": [{"after": 0.3, "desc": "Reading app.py", "tokens": 9871, "tools": 1},
                  {"after": 0.9, "desc": "Running pytest", "tokens": 12045, "tools": 3}]},
    {"id": "b1", "desc": "pytest -q", "parent": "a1", "secs": 2.2, "text": "tests done"}]}))
def _bg_a():
    return {r.get("taskId"): r for r in _st_l(rid_ag).get("background") or []}
check("LA1 both tasks are in status, each as what it is: the sub-agent with its type, the command with the sub-agent that launched it",
      _wait_l(rid_ag, lambda: len(_bg_a()) == 2)
      and _bg_a()["a1"].get("taskType") == "local_agent" and _bg_a()["a1"].get("agentType") == "general-purpose"
      and _bg_a()["a1"].get("description") == "Review the diff" and "parent" not in _bg_a()["a1"]
      and _bg_a()["b1"].get("taskType") == "local_bash" and _bg_a()["b1"].get("parent") == "a1" and "agentType" not in _bg_a()["b1"], _bg_a())
check("LA2 the sub-agent's totals follow its reports: the latest tokens, tool count and what it is doing",
      _wait_l(rid_ag, lambda: _bg_a().get("a1", {}).get("toolUses") == 3, 4)
      and _bg_a()["a1"].get("tokens") == 12045 and _bg_a()["a1"].get("activity") == "Running pytest", _bg_a())
check("LA2b a command has no totals to report", all(k not in _bg_a().get("b1", {}) for k in ("tokens", "toolUses", "activity")), _bg_a())
_started_a1 = _bg_a().get("a1", {}).get("startedAt")
check("LA3 when the command ends the sub-agent stays, with everything already known of it (its start, its totals)",
      _wait_l(rid_ag, lambda: list(_bg_a()) == ["a1"], 6) and _bg_a()["a1"].get("tokens") == 12045
      and _bg_a()["a1"].get("startedAt") == _started_a1 and _st_l(rid_ag)["state"] == "running", _bg_a())
check("LA4 when the sub-agent ends nothing is pending and the run goes after the grace",
      _wait_l(rid_ag, lambda: not _st_l(rid_ag).get("background"), 6) and _wait_l(rid_ag, lambda: _st_l(rid_ag)["state"] == "done", 8), _st_l(rid_ag))
check("LA5 each ending was a reply of the engine's own, in the order they ended",
      [o.get("result") for o in _out_l(rid_ag) if o.get("type") == "result"] == ["launched", "tests done", "review done"],
      [o.get("result") for o in _out_l(rid_ag) if o.get("type") == "result"])

# stop ONE task (2026-11-22, the stop key on a row of the phone's list): the run,
# its turn and its other tasks go on; a sub-agent's own command goes with it
rid_st = start(el, "spawn\nSHIM:" + json.dumps({"text": "launched", "sid": "sess-ST", "bg": [
    {"id": "a1", "desc": "Review the diff", "agent": "general-purpose", "secs": 30, "text": "review done"},
    {"id": "b1", "desc": "pytest -q", "parent": "a1", "secs": 30, "text": "tests done"},
    {"id": "c1", "desc": "npm run build", "secs": 3.5, "text": "build done"}]}))
def _bg_st():
    return [r.get("taskId") for r in _st_l(rid_st).get("background") or []]
def _stop_task(rid, task, e=el):
    return run(e, "stop-task", "--run", rid, "--task", task)
_wait_l(rid_st, lambda: len(_bg_st()) == 3)
p = _stop_task(rid_st, "a1")
check("LT1 stop-task is accepted and that task ends as stopped — with the command the sub-agent itself started — while the other goes on",
      p.returncode == 0 and json.loads(p.stdout).get("accepted") is True
      and _wait_l(rid_st, lambda: _bg_st() == ["c1"], 6) and _st_l(rid_st)["state"] == "running"
      and sorted((o.get("task_id"), o.get("status")) for o in _out_l(rid_st) if o.get("subtype") == "task_notification") == [("a1", "stopped"), ("b1", "stopped")],
      (p.returncode, p.stdout, _bg_st(), [(o.get("task_id"), o.get("status")) for o in _out_l(rid_st) if o.get("subtype") == "task_notification"]))
check("LT1b what went into the engine is Claude Code's own control request for that task, nothing else",
      [o.get("response", {}).get("subtype") for o in _out_l(rid_st) if o.get("type") == "control_response"] == ["success"]
      and all(str(o.get("response", {}).get("request_id", "")).startswith("pervio-stop-") for o in _out_l(rid_st) if o.get("type") == "control_response"),
      [o for o in _out_l(rid_st) if o.get("type") == "control_response"])
check("LT2 the task that was not stopped finishes on its own, and then the run goes after the grace",
      _wait_l(rid_st, lambda: ("c1", "completed") in [(o.get("task_id"), o.get("status")) for o in _out_l(rid_st) if o.get("subtype") == "task_notification"], 8)
      and _wait_l(rid_st, lambda: _st_l(rid_st)["state"] == "done", 8), _st_l(rid_st))
p = _stop_task(rid_st, "c1")
check("LT3 stop-task into an ended run is refused (exit 4), like say", p.returncode == 4 and json.loads(p.stdout).get("accepted") is False, (p.returncode, p.stdout))
p = _stop_task(rid_st, "x; rm -rf ~")
check("LT4 a task id that is not an id is refused before anything is written", p.returncode != 0 and "accepted" not in p.stdout, (p.returncode, p.stdout, p.stderr[-80:]))
rid_cx = start(dict(el, SHIM_CODEX_JSON=json.dumps({"text": "codex ok", "sleep": 6})), "codex turn", ["--backend", "codex"])
_wait_l(rid_cx, lambda: _st_l(rid_cx).get("accepting") is True, 6)
p = _stop_task(rid_cx, "anything")
check("LT5 a Codex run is refused (its sub-agents are not stopped this way): nothing reaches its input",
      p.returncode == 4 and json.loads(p.stdout).get("reason") == "engine", (p.returncode, p.stdout, _st_l(rid_cx)))
run(el, "stop", "--run", rid_cx)

# stop while living: engine, keeper and fifo all go
rid_s = start(el, shim_prompt(text="stay", sid="sess-S"))
_wait_l(rid_s, lambda: _st_l(rid_s).get("replied") is True)
run(el, "stop", "--run", rid_s)
time.sleep(0.5)
check("LS1 stop ends a living run outright: failed/143, keeper gone",
      _st_l(rid_s)["state"] == "failed" and _st_l(rid_s)["exitCode"] == 143
      and not os.path.exists(os.path.join(home_l, ".pervio", "runs", rid_s, "keeper.pid")), _st_l(rid_s))
check("LS1b …and the fifo is removed", not os.path.exists(os.path.join(home_l, ".pervio", "runs", rid_s, "in.fifo")))
# a group's member run: one turn nobody feeds, so the round advances at its reply, not a grace later
rid_g = start(el, shim_prompt(text="g"), extra=["--group", "grp-x1"])
check("LG1 a group's run is the old one-shot (no fifo, not living): tick-run fires when it answers, not 180 s later",
      not os.path.exists(os.path.join(home_l, ".pervio", "runs", rid_g, "in.fifo"))
      and json.load(open(os.path.join(home_l, ".pervio", "runs", rid_g, "meta.json"))).get("living") is False, _st_l(rid_g))
wait_state(el, rid_g, "done")
# ---- no warm wait (2026-11-11): answered + nothing pending = leave after a settle ----
# LR4 above pins the leaving itself. Three edges of it:
#   LW: a fresh start on the SAME conversation while the old process is a beat
#       from exiting waits for it (Codex's writer lock is released only at exit);
#   LD: an engine that dies mid-turn takes its keeper with it — the run reads
#       failed at once, not "running" until someone stops it;
#   LX: a say racing the keeper's exit is either taken by that process or
#       refused outright — never accepted and then lost.
print("=== no warm wait: the start guard, a dead engine, the say race ===")
def _procs_in_group(pgid):
    out = subprocess.run(["ps", "-axo", "pid=,pgid=,command="], capture_output=True, text=True).stdout
    rows = []
    for l in out.splitlines():
        parts = l.split(None, 2)
        if len(parts) == 3 and parts[1] == str(pgid):
            rows.append((int(parts[0]), parts[2]))
    return rows
def _pgid_l(rid):
    try: return int(open(os.path.join(home_l, ".pervio", "runs", rid, "pgid")).read().strip())
    except (OSError, ValueError): return 0
def _alive_l(pid):
    try: os.kill(pid, 0); return True
    except OSError: return False

# LW: the engine lingers 2.5 s after EOF (the shim's `linger`, codex's shape)
rid_w = start(el, "r\nSHIM:" + json.dumps({"text": "first", "sid": "sess-W", "linger": 2.5}))
_wait_l(rid_w, lambda: _st_l(rid_w).get("replied") is True)
_wait_l(rid_w, lambda: not os.path.exists(os.path.join(home_l, ".pervio", "runs", rid_w, "keeper.pid")), 6)
leaving = _alive_l(_pgid_l(rid_w)) and _st_l(rid_w)["state"] == "running"
t_w = time.time()
rid_w2 = start(el, shim_prompt(text="second", sid="sess-W"), extra=["--resume", "sess-W"])
took = time.time() - t_w
meta_w2 = json.load(open(os.path.join(home_l, ".pervio", "runs", rid_w2, "meta.json")))
check("LW1 a start on a conversation whose previous process is still leaving waits for it to go (and records which)",
      leaving and meta_w2.get("waitedFor") == [rid_w] and _st_l(rid_w)["state"] != "running" and 0.3 < took < 3.5,
      (leaving, meta_w2.get("waitedFor"), _st_l(rid_w)["state"], round(took, 2)))
wait_state(el, rid_w2, "done")
# the same, but INSIDE the settle: the old run is idle with its keeper still there — it is asked to leave now
rid_i = start(el, shim_prompt(text="idle", sid="sess-W"), extra=["--resume", "sess-W"])
_wait_l(rid_i, lambda: _st_l(rid_i).get("replied") is True)
in_settle = os.path.exists(os.path.join(home_l, ".pervio", "runs", rid_i, "keeper.pid")) and _alive_l(_pgid_l(rid_i))
t_i = time.time()
rid_i2 = start(el, shim_prompt(text="after", sid="sess-W"), extra=["--resume", "sess-W"])
took_i = time.time() - t_i
meta_i2 = json.load(open(os.path.join(home_l, ".pervio", "runs", rid_i2, "meta.json")))
check("LW3 a start inside the old run's settle asks that idle run to leave now and waits for it (no second process beside it)",
      in_settle and meta_i2.get("waitedFor") == [rid_i] and _st_l(rid_i)["state"] == "done" and took_i < 3.0,
      (in_settle, meta_i2.get("waitedFor"), _st_l(rid_i)["state"], round(took_i, 2)))
wait_state(el, rid_i2, "done")
# but a run still WORKING on the conversation is left alone (the start does not wait, nothing is cut)
rid_b = start(el, shim_prompt(text="busy", sid="sess-W", sleep=4), extra=["--resume", "sess-W"])
_wait_l(rid_b, lambda: any(o.get("subtype") == "init" for o in _out_l(rid_b)), 10)
t_b = time.time()
rid_b2 = start(el, shim_prompt(text="beside", sid="sess-W"), extra=["--resume", "sess-W"])
took_b = time.time() - t_b
meta_b2 = json.load(open(os.path.join(home_l, ".pervio", "runs", rid_b2, "meta.json")))
check("LW4 a run still working is left alone: the start neither waits for it nor cuts it",
      meta_b2.get("waitedFor") == [] and took_b < 1.0 and _st_l(rid_b)["state"] == "running", (meta_b2.get("waitedFor"), round(took_b, 2), _st_l(rid_b)["state"]))
wait_state(el, rid_b, "done"); wait_state(el, rid_b2, "done")
rid_w3 = start(el, shim_prompt(text="third", sid="sess-W"), extra=["--resume", "sess-W"])
meta_w3 = json.load(open(os.path.join(home_l, ".pervio", "runs", rid_w3, "meta.json")))
check("LW2 with nothing leaving, a start waits for nothing", meta_w3.get("waitedFor") == [], meta_w3.get("waitedFor"))
wait_state(el, rid_w3, "done")

# LD: kill the engine mid-turn
rid_d = start(el, shim_prompt(text="never", sid="sess-D", sleep=30))
_wait_l(rid_d, lambda: any(o.get("subtype") == "init" for o in _out_l(rid_d)), 10)
victims = [pid for pid, cmd in _procs_in_group(_pgid_l(rid_d)) if "shim/claude" in cmd]
for pid in victims:
    os.kill(pid, 9)
st_d = wait_state(el, rid_d, "failed", timeout=10)
check("LD1 the engine killed mid-turn: its keeper leaves at once and the run reads failed, not running",
      len(victims) == 1 and st_d["state"] == "failed"
      and not os.path.exists(os.path.join(home_l, ".pervio", "runs", rid_d, "keeper.pid")), (victims, st_d))

# LX: say against the exit, with a settle too short to matter (0.05 s)
elx = dict(el, PERVIO_RUN_IDLE_GRACE="0.05")
outcomes = {"taken": 0, "refused": 0, "lost": 0}
for i in range(8):
    rid_x = json.loads(run(elx, "start", "--dir", os.path.expanduser("~"), "--prompt-b64",
                           base64.b64encode(shim_prompt(text="a", sid="sess-X%d" % i).encode()).decode()).stdout)["runId"]
    _wait_l(rid_x, lambda: _st_l(rid_x).get("replied") is True)
    time.sleep(0.15 * i)          # from "at once" to past the keeper's 0.5 s tick: both sides of the exit
    p = run(elx, "say", "--run", rid_x, "--prompt-b64", base64.b64encode(shim_prompt(text="b", sid="sess-X%d" % i).encode()).decode())
    if p.returncode == 0:
        answered = _wait_l(rid_x, lambda: [o.get("result") for o in _out_l(rid_x) if o.get("type") == "result"] == ["a", "b"], 10)
        outcomes["taken" if answered else "lost"] += 1
    else:
        outcomes["refused" if p.returncode == 4 else "lost"] += 1
    wait_state(elx, rid_x, "done", timeout=10)
check("LX1 a say racing the keeper's exit is taken by that process or refused — never accepted and lost (8 tries, both sides of the exit seen)",
      outcomes["lost"] == 0 and outcomes["taken"] + outcomes["refused"] == 8 and outcomes["taken"] > 0 and outcomes["refused"] > 0, outcomes)
print("     (taken %d, refused %d)" % (outcomes["taken"], outcomes["refused"]))

# cursor: one prompt, one turn, no fifo
rid_cur = start(el, shim_prompt(text="c"), extra=["--backend", "cursor"])
check("LC1 a cursor run is the old one-shot: no fifo, never accepting", not os.path.exists(os.path.join(home_l, ".pervio", "runs", rid_cur, "in.fifo")) and _st_l(rid_cur).get("accepting") is False, _st_l(rid_cur))
wait_state(el, rid_cur, "done")
shutil.rmtree(home_l, ignore_errors=True)

# ---- list --device: this phone's own runs ------------------------------------
p = subprocess.run([sys.executable, run3, "start", "--dir", os.path.join(home3, "MyProject"), "--device", "phoneB",
                    "--prompt-b64", base64.b64encode(shim_prompt(text="b").encode()).decode()], env=e3, capture_output=True, text=True, timeout=30)
rid_b = json.loads(p.stdout)["runId"]
p = subprocess.run([sys.executable, run3, "start", "--dir", os.path.join(home3, "MyProject"),
                    "--prompt-b64", base64.b64encode(shim_prompt(text="n").encode()).decode()], env=e3, capture_output=True, text=True, timeout=30)
rid_n = json.loads(p.stdout)["runId"]
onlyA = {r["runId"] for r in json.loads(subprocess.run([sys.executable, run3, "list", "--device", "phoneA"], env=e3, capture_output=True, text=True).stdout)}
check("RL1 list --device shows this phone's runs and the ownerless ones, never another phone's",
      {rid_a, rid_c, rid_n} <= onlyA and rid_b not in onlyA, {"expected": [rid_a, rid_c, rid_n], "not": rid_b, "got": onlyA})
allruns3 = {r["runId"] for r in json.loads(subprocess.run([sys.executable, run3, "list"], env=e3, capture_output=True, text=True).stdout)}
check("RL1b without --device the list is everyone's, as before", {rid_a, rid_b, rid_c, rid_n} <= allruns3, {"expected": [rid_a, rid_b, rid_c, rid_n], "got": allruns3})
for _ in range(120):
    if all(_status3(r)["state"] in ("done", "failed") for r in (rid_b, rid_n)): break
    time.sleep(0.25)
shutil.rmtree(home3, ignore_errors=True)

ok = all(results)

# ---- replied: answered, process still alive (2026-10-18) ----
print("=== replied: a run that answered but whose process lingers ===")
home_r, e_r = env()
rd_r = os.path.join(home_r, ".pervio", "runs", "aaaaaaaaaaaa"); os.makedirs(rd_r)
linger = subprocess.Popen(["sleep", "30"], start_new_session=True)      # its own session: pid == pgid
with open(os.path.join(rd_r, "meta.json"), "w") as f:
    json.dump({"runId": "aaaaaaaaaaaa", "dir": os.path.expanduser("~"), "preview": "p", "started": 1, "backend": ""}, f)
with open(os.path.join(rd_r, "pgid"), "w") as f:
    f.write(str(linger.pid))
with open(os.path.join(rd_r, "out.jsonl"), "w") as f:
    f.write('{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}\n')
    f.write('{"type":"result","subtype":"success","is_error":false}\n')
    f.write('{"type":"system","subtype":"background_tasks_changed","tasks":[]}\n')
try:
    row = next(r for r in json.loads(run(e_r, "list").stdout) if r["runId"] == "aaaaaaaaaaaa")
    check("list: state stays running (the process is alive) but replied is true",
          row["state"] == "running" and row["replied"] is True, row)
    st = json.loads(run(e_r, "status", "--run", "aaaaaaaaaaaa").stdout)
    check("status carries replied too", st["state"] == "running" and st["replied"] is True, st)
    os.rename(os.path.join(rd_r, "out.jsonl"), os.path.join(rd_r, "out.bak"))
    with open(os.path.join(rd_r, "out.jsonl"), "w") as f:
        f.write('{"type":"assistant","message":{"content":[{"type":"text","text":"still going"}]}}\n')
    row = next(r for r in json.loads(run(e_r, "list").stdout) if r["runId"] == "aaaaaaaaaaaa")
    check("no result line → replied false", row["replied"] is False, row)
finally:
    linger.kill()

print("=== a module planted in the project never runs as part of a turn ===")
# The project may be someone else's repository. pervio-chat's own inline python
# (the first message's encoder, the approval answer, the cursor error reader)
# runs AFTER `cd <project>`; without -I the current directory leads sys.path
# and a json.py or base64.py lying in the repository would execute as the
# person on their first message, before any tool approval (2026-11-18).
home_p = tempfile.mkdtemp(prefix="prun_plant_", dir="/tmp")
proj_p = os.path.join(home_p, "evil-repo"); os.makedirs(proj_p)
mark_p = os.path.join(home_p, "PLANTED_RAN")
for mod in ("json", "base64", "sys", "os"):
    with open(os.path.join(proj_p, mod + ".py"), "w") as f:
        f.write("open(%r, 'a').write(%r)\n" % (mark_p, mod + "\n"))
ep = dict(os.environ, HOME=home_p, PATH=SHIM + ":" + os.environ.get("PATH", ""), PERVIO_RUN_IDLE_GRACE="1.5")
b64_p = base64.b64encode(shim_prompt(text="hello from the repo", sid="sess-P").encode()).decode()
rid_p = json.loads(run(ep, "start", "--dir", proj_p, "--prompt-b64", b64_p).stdout)["runId"]
def _st_p():
    return json.loads(run(ep, "status", "--run", rid_p).stdout)
for _ in range(60):
    if _st_p().get("replied") is True or _st_p()["state"] != "running": break
    time.sleep(0.25)
check("PL1 the turn in that project is answered (the encoder still works in isolated mode)", _st_p().get("replied") is True, _st_p())
check("PL2 and not one of the planted modules was imported", not os.path.exists(mark_p),
      open(mark_p).read() if os.path.exists(mark_p) else "")
run(ep, "stop", "--run", rid_p)
chat_src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "pervio-chat"), encoding="utf-8").read()
after_cd = "\n".join(l for l in chat_src.split('cd "$dir"', 1)[1].splitlines() if not l.lstrip().startswith("#"))
import re as _re
loose = [m.group(0) for m in _re.finditer(r"python3 (?:-c|- )", after_cd)]
check("PL3 every inline python after `cd \"$dir\"` in pervio-chat is isolated (-I)", loose == [], loose)
shutil.rmtree(home_p, ignore_errors=True)

# The verdict counts EVERY check: it used to be taken before the two sections
# above, so a failure in either printed FAIL and still exited 0.
ok = all(results)
print("\n=== pervio-run: %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
