#!/usr/bin/env python3
"""Security suite for the implemented server features (pervio-orchestrate worktree
isolation + pervio-chat). Real scripts, shim agents (no model calls). Attacks:
injection, path traversal, containment (agent can't clobber the user's real tree
mid-run), ref-namespace blast radius on cleanup, two-workflow isolation, and the
on-disk permission posture. Fact-based: every claim is an observed file/exit/ref."""
import base64
import importlib.machinery
import importlib.util
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
os.environ.setdefault("PERVIO_RUN_IDLE_GRACE", "1.5")   # a living run ends a beat after its reply here, not 180 s

HERE = os.path.dirname(os.path.realpath(__file__))
BIN = os.path.realpath(os.path.join(HERE, "..", "bin"))
ORCH = os.path.join(BIN, "pervio-orchestrate")
CHAT = os.path.join(BIN, "pervio-chat")
SHIM = os.path.join(HERE, "shim")

# --- hermetic $HOME -----------------------------------------------------------
# A security suite that writes the user's own ~/.pervio and ~/.pervio is not a
# security suite. Aimed at the real home this file put live workflow state under
# ~/.pervio/wf and a session directory under ~/.pervio/chat for the length of the
# run (observed 2026-08-07), and shared both with any other copy of itself. It
# now gets a throwaway home; the real one is neither read nor written.
REAL_HOME = os.path.realpath(os.path.expanduser("~"))
HOME = tempfile.mkdtemp(prefix="p3sec_home_", dir="/tmp")
os.environ["HOME"] = HOME
ENV = dict(os.environ, PATH=SHIM + ":" + os.environ.get("PATH", ""))
WFROOT = os.path.join(HOME, ".pervio", "wf")

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + (("  [" + str(detail)[:200] + "]") if (detail and not cond) else ""))


def g(cwd, *args):
    p = subprocess.run(["git", "-C", cwd] + list(args), capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def mkrepo(files=(("base.txt", "base\n"),)):
    d = tempfile.mkdtemp(prefix="p3sec_", dir="/tmp")
    g(d, "init", "-q", "-b", "main"); g(d, "config", "user.email", "t@t"); g(d, "config", "user.name", "t")
    for f, c in files:
        with open(os.path.join(d, f), "w") as fh:
            fh.write(c)
    g(d, "add", "-A"); g(d, "commit", "-qm", "base")
    return d


def shim_step(sid, writes=(), perm="acceptEdits", sleep=0, deps=None, prompt_extra="", raw_id=None):
    ins = {"write": [{"file": f, "content": c} for f, c in writes], "sleep": sleep, "text": "done " + sid}
    s = {"id": raw_id if raw_id is not None else sid, "backend": "claude", "perm": perm,
         "prompt": prompt_extra + "task %s\nSHIM:%s" % (sid, json.dumps(ins))}
    if deps:
        s["dependsOn"] = deps
    return s


def start(spec):
    b64 = base64.b64encode(json.dumps(spec).encode()).decode()
    p = subprocess.run([sys.executable, ORCH, "start", "--spec-b64", b64], env=ENV, capture_output=True, text=True)
    return p


def start_ok(spec):
    p = start(spec)
    if p.returncode != 0:
        raise RuntimeError("start rejected: " + p.stderr.strip())
    return json.loads(p.stdout)["wfId"]


def status(wf):
    p = subprocess.run([sys.executable, ORCH, "status", "--wf", wf], env=ENV, capture_output=True, text=True)
    return json.loads(p.stdout) if p.returncode == 0 else {}


def wait(wf, timeout=90):
    for _ in range(timeout * 4):
        led = status(wf)
        if led.get("status") in ("done", "failed"):
            return led
        time.sleep(0.25)
    raise TimeoutError(wf)


def delete(wf):
    subprocess.run([sys.executable, ORCH, "delete", "--wf", wf], env=ENV, capture_output=True, text=True)


def pervio_refs(repo):
    _, out, _ = g(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/")
    return [l for l in out.splitlines() if l.strip()]


# ============ S1: workflow-id path traversal is rejected ============
print("=== S1 path traversal / id validation ===")
loader = importlib.machinery.SourceFileLoader("orch", ORCH)
orch = importlib.util.module_from_spec(importlib.util.spec_from_loader("orch", loader))
loader.exec_module(orch)
for bad in ("../etc", "..", "a/b", "a b", "$(id)", "wf;rm", ".."):
    p = subprocess.run([sys.executable, ORCH, "status", "--wf", bad], env=ENV, capture_output=True, text=True)
    check("S1 status rejects id %r" % bad, p.returncode != 0 and "ledger" not in p.stdout, p.stdout[:80])
p = subprocess.run([sys.executable, ORCH, "delete", "--wf", "../../tmp"], env=ENV, capture_output=True, text=True)
check("S1 delete rejects traversal id", p.returncode != 0)
# unknown/malformed args rejected (no silent arg injection)
p = subprocess.run([sys.executable, ORCH, "status", "--wf", "x", "--evil", "y"], env=ENV, capture_output=True, text=True)
check("S1 unknown flag rejected", p.returncode != 0)

# ============ S2: step id can't escape the git ref namespace ============
print("=== S2 step-id namespace safety ===")
repo = mkrepo()
for bad in ("../evil", "a/b", "a b", "..", "he;llo"):
    p = start({"name": "s2", "dir": repo, "steps": [shim_step("ok", [("a.txt", "1")]),
                                                     shim_step("x", [("b.txt", "2")], raw_id=bad)]})
    check("S2 rejects step id %r at start" % bad, p.returncode != 0, p.stdout[:80])
# duplicate ids rejected (would race one branch/path under isolation)
p = start({"name": "s2dup", "dir": repo, "steps": [shim_step("dup", [("a.txt", "1")]),
                                                   shim_step("dup2", [("b.txt", "2")], raw_id="dup")]})
check("S2 rejects duplicate step ids", p.returncode != 0, p.stdout[:80])
shutil.rmtree(repo, ignore_errors=True)

# ============ S3: prompt injection does NOT reach a shell ============
print("=== S3 prompt injection (base64 path never eval'd) ===")
repo = mkrepo()
marker = "/tmp/PWNED_S3_%d" % os.getpid()
if os.path.exists(marker):
    os.remove(marker)
inj = "$(touch %s)\n`touch %s`\n; touch %s\n" % (marker, marker, marker)
wf = start_ok({"name": "s3", "dir": repo, "steps": [
    shim_step("a", [("a.txt", "1")], prompt_extra=inj),
    shim_step("b", [("b.txt", "2")], prompt_extra=inj),
]})
wait(wf)
check("S3 shell metachars in prompt did NOT execute", not os.path.exists(marker), marker)
delete(wf)
shutil.rmtree(repo, ignore_errors=True)
if os.path.exists(marker):
    os.remove(marker)

# ============ S4: dir injection does NOT reach a shell ============
print("=== S4 dir injection ===")
marker = "/tmp/PWNED_S4_%d" % os.getpid()
if os.path.exists(marker):
    os.remove(marker)
# via pervio-chat directly: a --dir with shell metacharacters must not execute
b64 = base64.b64encode(b"hi\nSHIM:{}").decode()
p = subprocess.run([CHAT, "--text", "--backend", "claude",
                    "--dir", "/tmp/nope; touch %s" % marker, "--prompt-b64", b64],
                   env=ENV, capture_output=True, text=True)
check("S4 pervio-chat dir metachars did NOT execute", not os.path.exists(marker), marker)
check("S4 pervio-chat rejected the bogus dir", p.returncode != 0)
if os.path.exists(marker):
    os.remove(marker)

# ============ S5: containment — agent can't touch the user's real tree mid-run ============
print("=== S5 containment (isolated step writes stay in its worktree until merge) ===")
repo = mkrepo([("greeting.txt", "ORIGINAL\n")])
_, base_head, _ = g(repo, "rev-parse", "HEAD")
wf = start_ok({"name": "s5", "dir": repo, "steps": [
    shim_step("slow", [("greeting.txt", "MUTATED\n")], sleep=6),
    shim_step("other", [("z.txt", "z\n")], sleep=6),
]})
# while the steps run, the user's real working tree must be UNCHANGED
seen_running = False
mid_ok = True
for _ in range(80):
    led = status(wf)
    st = {s["id"]: s["status"] for s in led.get("steps", [])}
    if "running" in st.values():
        seen_running = True
        live = open(os.path.join(repo, "greeting.txt")).read()
        _, h, _ = g(repo, "rev-parse", "HEAD")
        if live != "ORIGINAL\n" or h != base_head:
            mid_ok = False
            break
    if led.get("status") in ("done", "failed"):
        break
    time.sleep(0.25)
check("S5 saw steps running", seen_running)
check("S5 user's real tree untouched WHILE steps ran", mid_ok)
led = wait(wf)
check("S5 result merged atomically at end", (led.get("git") or {}).get("merged") is True and
      open(os.path.join(repo, "greeting.txt")).read() == "MUTATED\n")
delete(wf)
shutil.rmtree(repo, ignore_errors=True)

# ============ S6: cleanup blast radius — only THIS run's refs are deleted ============
print("=== S6 cleanup only touches pervio/wf-<thisId>/* ===")
repo = mkrepo()
# decoy branches that must SURVIVE a delete
g(repo, "branch", "pervio/keep-me")               # user branch under pervio/
g(repo, "branch", "feature/x")
wf = start_ok({"name": "s6", "dir": repo, "steps": [
    shim_step("east", [("c.txt", "east\n")]),
    shim_step("west", [("c.txt", "west\n")]),      # conflict → refs kept until delete
]})
led = wait(wf)
# fabricate a decoy from ANOTHER (fake) workflow id — must also survive
g(repo, "branch", "pervio/wf-DECOYOTHER/integration")
before = set(pervio_refs(repo))
check("S6 this run left its refs (conflict kept them)", any(("wf-" + wf) in r for r in before), before)
delete(wf)
after = set(pervio_refs(repo))
check("S6 delete removed THIS run's refs", not any(("wf-" + wf) in r for r in after), after)
check("S6 user branch pervio/keep-me survived", "pervio/keep-me" in after)
check("S6 feature/x survived", "feature/x" in after)
check("S6 main survived", "main" in after)
check("S6 other workflow's refs survived", "pervio/wf-DECOYOTHER/integration" in after, after)
rc, _, ferr = g(repo, "fsck", "--no-dangling")
check("S6 repo fsck clean after delete (exit 0, no reported errors)",
      rc == 0 and "error" not in (ferr or "").lower(), ferr[:200])
shutil.rmtree(repo, ignore_errors=True)

# ============ S7: two concurrent isolated workflows on the SAME repo ============
print("=== S7 two concurrent workflows, same repo, no corruption ===")
repo = mkrepo()
_, base_head, _ = g(repo, "rev-parse", "HEAD")
specs = [
    {"name": "s7a", "dir": repo, "steps": [shim_step("a1", [("a1.txt", "1"), ], sleep=2),
                                            shim_step("a2", [("a2.txt", "2")], sleep=2)]},
    {"name": "s7b", "dir": repo, "steps": [shim_step("b1", [("b1.txt", "1")], sleep=2),
                                            shim_step("b2", [("b2.txt", "2")], sleep=2)]},
]
wfa = start_ok(specs[0]); wfb = start_ok(specs[1])
la = wait(wfa); lb = wait(wfb)
check("S7 both runs completed", la.get("status") in ("done", "failed") and lb.get("status") in ("done", "failed"))
# ref namespaces are disjoint (keyed by wfId)
refs = pervio_refs(repo)
check("S7 no ref-namespace collision", not (("wf-" + wfa) in " ".join(refs) and ("wf-" + wfb) in " ".join(refs) and wfa == wfb))
rc, _, _ = g(repo, "fsck", "--no-dangling")
check("S7 repo fsck clean after two concurrent runs", rc == 0)
# at most one merged back to main (the other sees HEAD moved / non-ff → branch kept)
merged = [(la.get("git") or {}).get("merged"), (lb.get("git") or {}).get("merged")]
check("S7 at least one landed, none corrupted the tree", merged.count(True) >= 1, merged)
_, porc, _ = g(repo, "status", "--porcelain")
check("S7 user tree not left dirty", porc == "", porc)
delete(wfa); delete(wfb)
check("S7 both deletes clean all refs", [r for r in pervio_refs(repo) if r.startswith("pervio/")] == [])
shutil.rmtree(repo, ignore_errors=True)

# ============ S8: on-disk permission posture ============
print("=== S8 permissions (umask 077) ===")
repo = mkrepo()
wf = start_ok({"name": "s8", "dir": repo, "steps": [shim_step("a", [("a.txt", "1")], sleep=3),
                                                    shim_step("b", [("b.txt", "2")], sleep=3)]})
time.sleep(1.0)
rd = os.path.join(WFROOT, wf)
def mode(p): return stat.S_IMODE(os.stat(p).st_mode)
check("S8 wf run dir is 0700", mode(rd) == 0o700, oct(mode(rd)))
led_mode = mode(os.path.join(rd, "ledger.json"))
check("S8 ledger.json is owner-only (no o/g)", (led_mode & 0o077) == 0, oct(led_mode))
wt = os.path.join(rd, "wt")
if os.path.isdir(wt):
    check("S8 worktree parent not world-accessible", (mode(wt) & 0o007) == 0, oct(mode(wt)))
wait(wf)
delete(wf)
shutil.rmtree(repo, ignore_errors=True)

# ============ S9: approval-channel perms (pervio-approve session dir) ============
print("=== S9 approval channel file perms (driven by the REAL pervio-chat) ===")
# This used to be a self-fulfilling loop: the test built the session layout with
# its own makedirs(0700)/chmod(600)/mkfifo(600) and then asserted the modes it had
# just set. Loosening pervio-chat's own 700/600 to 755/644 left it fully green —
# it never executed a line of the product. Now it drives the REAL pervio-chat
# approval turn (shim claude, zero model calls, the same way test_chat.py does)
# and reads the modes the SCRIPT created, mid-turn: the turn's --cleanup deletes
# the session dir when it ends, so the observation has to happen while it lives.


def chat_session_facts(chat_bin, home, sid, sleep=2.5):
    """Run one real approval turn and report what it actually put on disk."""
    ins = json.dumps({"sleep": sleep, "text": "ok"})
    prompt = base64.b64encode(("go\nSHIM:" + ins).encode()).decode()
    p = subprocess.Popen([chat_bin, "--dir", home, "--perm", "default",
                          "--approve-sid", sid, "--prompt-b64", prompt],
                         env=dict(ENV, HOME=home), stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True)
    sess = os.path.join(home, ".pervio", "chat", sid)
    first = p.stdout.readline()      # the first event ⇒ the layout exists on disk
    f = {"sess": sess, "first": first}
    for key, rel in (("dir", ""), ("events", "events.jsonl"),
                     ("fifo", "control.fifo"), ("mcp", "mcp.json")):
        path = os.path.join(sess, rel) if rel else sess
        try:
            st = os.stat(path)               # stat, never open: the fifo would block
            f[key] = (stat.S_IMODE(st.st_mode), stat.S_ISFIFO(st.st_mode))
        except OSError:
            f[key] = (None, False)
    try:
        with open(os.path.join(sess, "mcp.json")) as fh:
            f["mcp_text"] = fh.read()
    except OSError:
        f["mcp_text"] = ""
    p.stdout.read()
    f["rc"] = p.wait(timeout=90)
    f["cleaned"] = not os.path.exists(sess)
    return f


shome = tempfile.mkdtemp(prefix="p3sec_chat_", dir="/tmp")
sid = "sectest%d" % os.getpid()
S9 = chat_session_facts(CHAT, shome, sid)
check("S9 the real pervio-chat approval turn ran (a first event, exit 0)",
      bool(S9["first"].strip()) and S9["rc"] == 0, (S9["first"][:120], S9["rc"]))
check("S9 the session dir pervio-chat created is 0700",
      S9["dir"][0] == 0o700, oct(S9["dir"][0] or 0))
check("S9 events.jsonl it created is owner-only",
      S9["events"][0] is not None and (S9["events"][0] & 0o077) == 0,
      oct(S9["events"][0] or 0))
check("S9 control.fifo it created is a fifo, owner-only",
      S9["fifo"][1] and (S9["fifo"][0] & 0o077) == 0,
      (S9["fifo"][1], oct(S9["fifo"][0] or 0)))
check("S9 mcp.json it wrote is owner-only (it carries the per-turn sid)",
      S9["mcp"][0] is not None and (S9["mcp"][0] & 0o077) == 0, oct(S9["mcp"][0] or 0))
_m = S9["mcp_text"].lower()
check("S9 that mcp.json really is the approval wiring, and carries NO secret",
      "pervio-approve" in _m and sid.lower() in _m
      and "token" not in _m and "secret" not in _m and "oauth" not in _m,
      S9["mcp_text"][:200])
check("S9 the turn cleaned its session dir up afterwards", S9["cleaned"], S9["sess"])

# --- and the proof that those five assertions have teeth ----------------------
# Three mutants of pervio-chat, each a COPY in its own directory (the real script
# is never edited), each loosening exactly one mode line. Every one must turn the
# matching assertion RED. `umask 077` at the top of pervio-chat is belt-and-braces
# over the explicit chmods, so the fifo mutant has to remove both — which is
# itself worth knowing: either layer alone still protects the channel.
def chat_mutant(pairs, tag):
    """A copy of pervio-chat with one or more lines changed, in a directory where
    every sibling it needs (pervio-chat-stream, pervio-approve, pervio-hb…) is
    symlinked, so SELF_DIR still resolves."""
    with open(CHAT) as fh:
        src = fh.read()
    ok = True
    for old, new in pairs:
        if src.count(old) != 1:
            ok = False
        src = src.replace(old, new)
    d = tempfile.mkdtemp(prefix="chatmut_%s_" % tag, dir="/tmp")
    for name in os.listdir(BIN):
        if name != "pervio-chat":
            try:
                os.symlink(os.path.join(BIN, name), os.path.join(d, name))
            except OSError:
                pass
    path = os.path.join(d, "pervio-chat")
    with open(path, "w") as fh:
        fh.write(src)
    os.chmod(path, 0o700)
    return path, ok, d


for tag, pairs, key, want in (
        ("dir", [('mkdir -p "$sess"; chmod 700 "$sess"',
                  'mkdir -p "$sess"; chmod 755 "$sess"')], "dir", 0o755),
        ("events", [(': > "$sess/events.jsonl"; chmod 600 "$sess/events.jsonl"',
                     ': > "$sess/events.jsonl"; chmod 644 "$sess/events.jsonl"')],
         "events", 0o644),
        ("fifo", [("\numask 077\n", "\numask 000\n"),
                  ('mkfifo -m 600 "$sess/control.fifo"',
                   'mkfifo -m 666 "$sess/control.fifo"')], "fifo", 0o666)):
    mpath, found, mdir = chat_mutant(pairs, tag)
    check("S9m %s: the line this mutant loosens exists exactly once in pervio-chat"
          % tag, found)
    mhome = tempfile.mkdtemp(prefix="p3sec_chatm_", dir="/tmp")
    M = chat_session_facts(mpath, mhome, "mut%s%d" % (tag, os.getpid()))
    check("S9m %s: loosening it really loosens the channel (S9's assertion goes RED)"
          % tag, M[key][0] == want, (oct(M[key][0] or 0), oct(want)))
    shutil.rmtree(mdir, ignore_errors=True)
    shutil.rmtree(mhome, ignore_errors=True)
shutil.rmtree(shome, ignore_errors=True)

# ============ S10: a KILLED run never leaves the user's checkout dirty/moved ============
print("=== S10 crash safety for the user's real repo ===")
repo = mkrepo([("greeting.txt", "ORIGINAL\n")])
_, base_head, _ = g(repo, "rev-parse", "HEAD")
_, base_ref, _ = g(repo, "symbolic-ref", "-q", "HEAD")
wf = start_ok({"name": "s10", "dir": repo, "steps": [
    shim_step("slow", [("greeting.txt", "X\n")], sleep=25),
    shim_step("other", [("z.txt", "z\n")], sleep=25),
]})
for _ in range(80):
    if "running" in {s["status"] for s in status(wf).get("steps", [])}:
        break
    time.sleep(0.25)
try:
    with open(os.path.join(rd if False else os.path.join(WFROOT, wf), "pgid")) as f:
        os.killpg(int(f.read().strip()), signal.SIGKILL)
except OSError:
    pass
time.sleep(0.6)
_, h, _ = g(repo, "rev-parse", "HEAD")
_, ref, _ = g(repo, "symbolic-ref", "-q", "HEAD")
_, porc, _ = g(repo, "status", "--porcelain")
check("S10 after SIGKILL: user HEAD unchanged", h == base_head, (h, base_head))
check("S10 after SIGKILL: still on the same branch", ref == base_ref, (ref, base_ref))
check("S10 after SIGKILL: greeting.txt still ORIGINAL", open(os.path.join(repo, "greeting.txt")).read() == "ORIGINAL\n")
check("S10 after SIGKILL: real tree not left dirty by the runner", porc == "", porc)
delete(wf)
shutil.rmtree(repo, ignore_errors=True)

# ============ S11: hermetic — the user's own tree was never the test bed =======
check("S11 every run and every session lived in the throwaway home",
      os.path.isdir(WFROOT)
      and not os.path.realpath(WFROOT).startswith(REAL_HOME + os.sep),
      (WFROOT, REAL_HOME))
shutil.rmtree(HOME, ignore_errors=True)

ok = all(results)
print("\n=== P3 SECURITY: %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
