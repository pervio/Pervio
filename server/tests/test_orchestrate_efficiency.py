#!/usr/bin/env python3
"""Efficiency/perf suite. Measures wall-clock (shim agents with controlled sleeps)
to prove: independent steps run in parallel, MAX_PARALLEL caps concurrency, the
serialized merge does NOT serialize agent turns, worktree isolation's git overhead
is small vs an agent turn, shared mode adds ZERO git overhead, and pervio-hb is a
high-throughput passthrough that injects heartbeats only when idle."""
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
ORCH = os.path.join(BIN, "pervio-orchestrate")
HB = os.path.join(BIN, "pervio-hb")
SHIM = os.path.join(HERE, "shim")

# --- hermetic $HOME -----------------------------------------------------------
# Every run this file starts used to land in the USER's ~/.pervio/wf — live state
# in a production directory, and a directory shared with any other copy of the
# suite running at the same moment. Throwaway home instead; the real one is
# neither read nor written (the agents are shims, so there is nothing to inherit).
REAL_HOME = os.path.realpath(os.path.expanduser("~"))
HOME = tempfile.mkdtemp(prefix="p3perf_home_", dir="/tmp")
os.environ["HOME"] = HOME
ENV = dict(os.environ, PATH=SHIM + ":" + os.environ.get("PATH", ""))
# The cap under test is the DEFAULT one. Inheriting a developer's override would
# quietly change what E1c/E1d measure.
ENV.pop("PERVIO_MAX_PARALLEL", None)
CAP = 4
WFROOT = os.path.join(HOME, ".pervio", "wf")

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + ("  " + str(detail) if detail else ""))


def g(cwd, *a):
    p = subprocess.run(["git", "-C", cwd] + list(a), capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def mkrepo():
    d = tempfile.mkdtemp(prefix="p3perf_", dir="/tmp")
    g(d, "init", "-q", "-b", "main"); g(d, "config", "user.email", "t@t"); g(d, "config", "user.name", "t")
    open(os.path.join(d, "base.txt"), "w").write("base\n"); g(d, "add", "-A"); g(d, "commit", "-qm", "base")
    return d


def step(sid, write=None, perm="acceptEdits", sleep=0):
    ins = {"write": ([{"file": write, "content": "x\n"}] if write else []), "sleep": sleep, "text": "d"}
    return {"id": sid, "backend": "claude", "perm": perm, "prompt": "t\nSHIM:" + json.dumps(ins)}


def run(spec):
    t0 = time.time()
    b64 = base64.b64encode(json.dumps(spec).encode()).decode()
    p = subprocess.run([sys.executable, ORCH, "start", "--spec-b64", b64], env=ENV, capture_output=True, text=True)
    wf = json.loads(p.stdout)["wfId"]
    led = {}
    for _ in range(600):
        q = subprocess.run([sys.executable, ORCH, "status", "--wf", wf], env=ENV, capture_output=True, text=True)
        led = json.loads(q.stdout) if q.returncode == 0 else {}
        if led.get("status") in ("done", "failed"):
            break
        time.sleep(0.1)
    dt = time.time() - t0
    return wf, led, dt


def delete(wf):
    subprocess.run([sys.executable, ORCH, "delete", "--wf", wf], env=ENV, capture_output=True, text=True)


SLEEP = 2.0


# --- how this file measures concurrency ---------------------------------------
# From the steps' OWN [startedAt, endedAt] stamps, never from a stopwatch on the
# whole run. A wall-clock threshold measures the MACHINE as much as the code: two
# copies of run_all.sh (or any other load) push the wall clock past the bound
# while the scheduler is behaving perfectly, and the suite goes red for a reason
# that has nothing to do with pervio-orchestrate. Intervals cannot be fooled by
# load — serialized turns simply cannot overlap, and a cap of N cannot show N+1
# open intervals however slow the box is. E1b already worked this way after a
# 4.27s-against-a-4.00s-limit false red; E1a and E1c were the two that did not.
def _ivals(steps):
    return [(s["startedAt"], s["endedAt"]) for s in steps
            if s.get("startedAt") and s.get("endedAt")]


def _max_concurrency(steps):
    """The largest number of agent turns that were open at the same instant."""
    edges = []
    for a, b in _ivals(steps):
        edges.append((a, 1))
        edges.append((b, -1))
    edges.sort(key=lambda e: (e[0], e[1]))   # a close at t sorts before an open at t
    cur = best = 0
    for _, d in edges:
        cur += d
        best = max(best, cur)
    return best


# ---------- E1a: pure scheduler parallelism (readers → shared, zero git) ----------
print("=== E1a parallelism, shared mode (4 independent readers, %.0fs each) ===" % SLEEP)
repo = mkrepo()
wf, led, dt = run({"name": "e1a", "dir": repo, "steps": [step("r%d" % i, perm="plan", sleep=SLEEP) for i in range(4)]})
check("E1a all done", led.get("status") == "done")
_c = _max_concurrency(led.get("steps") or [])
check("E1a all 4 readers were open at the same instant (%d concurrent; serial would be 1)" % _c,
      _c == 4, "concurrency=%d intervals=%s wall=%.2fs" % (_c, _ivals(led.get("steps") or []), dt))
check("E1a shared: zero git overhead (no git key)", "git" not in led)
delete(wf); shutil.rmtree(repo, ignore_errors=True)

# ---------- E1b: isolated parallelism — merges serialized but agent turns overlap ----------
print("=== E1b parallelism, ISOLATED mode (4 concurrent writers, %.0fs each) ===" % SLEEP)
repo = mkrepo()
wf, led, dt = run({"name": "e1b", "dir": repo, "steps": [step("w%d" % i, write="w%d.txt" % i, sleep=SLEEP) for i in range(4)]})
check("E1b all done + merged", led.get("status") == "done" and (led.get("git") or {}).get("merged") is True)
# Overlap is proven from the steps' OWN intervals (see _max_concurrency above).
def _overlaps(steps):
    iv = _ivals(steps)
    return sum(1 for i, a in enumerate(iv) for b in iv[i + 1:]
               if a[0] < b[1] and b[0] < a[1])


_pairs = _overlaps(led.get("steps") or [])
# The `dt < 4*SLEEP` half of this assertion was the last stopwatch left in it and
# is gone: it added nothing the interval count does not already prove, and it was
# the half that a second run_all.sh could turn red. The wall clock stays in the
# message as information.
check("E1b agent turns overlapped despite serialized merges (%d overlapping pairs, wall=%.2fs)"
      % (_pairs, dt),
      _pairs >= 3, "pairs=%d wall=%.2fs" % (_pairs, dt))
delete(wf); shutil.rmtree(repo, ignore_errors=True)

# ---------- E1c: MAX_PARALLEL cap (8 readers, 1.5s each → ~2 waves) ----------
W = 1.5
print("=== E1c MAX_PARALLEL cap (8 readers, %.1fs each) ===" % W)
repo = mkrepo()
wf, led, dt = run({"name": "e1c", "dir": repo, "steps": [step("r%d" % i, perm="plan", sleep=W) for i in range(8)]})
check("E1c 8 steps done", led.get("status") == "done")
_c = _max_concurrency(led.get("steps") or [])
# Both halves of the contract, read off the intervals: the cap really caps
# (never a 5th open turn) and it really parallelises (not silently serialized).
check("E1c the cap held: never more than %d turns open at once (peak %d over 8 steps)" % (CAP, _c),
      _c <= CAP, "concurrency=%d wall=%.2fs" % (_c, dt))
check("E1c ...and it was actually used: the peak reached %d" % CAP,
      _c == CAP, "concurrency=%d wall=%.2fs" % (_c, dt))
delete(wf); shutil.rmtree(repo, ignore_errors=True)

# ---------- E1d: the cap is a knob, and the interval measurement can see it ----
print("=== E1d PERVIO_MAX_PARALLEL=2 (6 readers, %.1fs each) ===" % W)
repo = mkrepo()
_env_keep = ENV.copy()
ENV["PERVIO_MAX_PARALLEL"] = "2"
wf, led, dt = run({"name": "e1d", "dir": repo, "steps": [step("r%d" % i, perm="plan", sleep=W) for i in range(6)]})
ENV.clear(); ENV.update(_env_keep)
_c = _max_concurrency(led.get("steps") or [])
check("E1d lowering the cap to 2 lowers the observed peak to 2 "
      "(so E1a/E1c's peaks are a real measurement, not an artefact)",
      led.get("status") == "done" and _c == 2, "concurrency=%d wall=%.2fs" % (_c, dt))
delete(wf); shutil.rmtree(repo, ignore_errors=True)

# ---------- E2: worktree isolation git overhead (sleep=0 agents) ----------
print("=== E2 isolation git overhead (2 instant writers) ===")
repo = mkrepo()
wf, led, dt_iso = run({"name": "e2iso", "dir": repo, "steps": [step("a", write="a.txt"), step("b", write="b.txt")]})
delete(wf); shutil.rmtree(repo, ignore_errors=True)
repo = mkrepo()
wf, led2, dt_sh = run({"name": "e2sh", "dir": repo, "steps": [step("a", perm="plan"), step("b", perm="plan")]})
delete(wf); shutil.rmtree(repo, ignore_errors=True)
overhead = dt_iso - dt_sh
per_step = overhead / 2.0
# Not an assertion, and it no longer pretends to be one. `check(..., True)` put a
# line reading PASS into the results — one no behaviour of pervio-orchestrate could
# ever turn red, because the condition was the literal True. The measurement is
# worth PRINTING; the assertion with teeth is the next line.
print("     E2 isolation overhead: 2-writer isolated=%.2fs  2-reader shared=%.2fs  "
      "Δ=%.2fs (~%.0fms/step of git)" % (dt_iso, dt_sh, overhead, per_step * 1000))
# git worktree add+commit+merge+remove per step should be well under a second on a tiny repo
check("E2 per-step git overhead < 1.0s (tiny vs any real agent turn)", per_step < 1.0, "%.0fms/step" % (per_step * 1000))

# ---------- E3: shared mode is byte-for-byte overhead-free ----------
print("=== E3 shared mode adds no artifacts ===")
repo = mkrepo()
wf, led, dt = run({"name": "e3", "dir": repo, "steps": [step("look", perm="plan"), step("edit", write="z.txt")]})
# 1 writer only → shared. No wt/, no refs, no git key.
rd = os.path.join(WFROOT, wf)
_, refs, _ = g(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/pervio/")
check("E3 no git key on a single-writer run", "git" not in led)
check("E3 no wt/ dir created", not os.path.isdir(os.path.join(rd, "wt")))
check("E3 no pervio refs created", refs == "")
delete(wf); shutil.rmtree(repo, ignore_errors=True)

# ---------- E4: pervio-hb throughput + no heartbeat under load ----------
print("=== E4 pervio-hb passthrough throughput ===")
# 5 MB of newline-terminated lines fed as fast as possible → out == in, no heartbeats.
line = (json.dumps({"type": "stream_event", "x": "y" * 80}) + "\n").encode()
n = (5 * 1024 * 1024) // len(line)
payload = line * n
t0 = time.time()
p = subprocess.run([HB], input=payload, capture_output=True)
dt = time.time() - t0
mb = len(payload) / 1024 / 1024
thru = mb / dt if dt > 0 else 0
hb_count = p.stdout.count(b'{"type":"heartbeat"}')
check("E4 output preserved byte-for-byte under load", p.stdout == payload, "in=%dB out=%dB" % (len(payload), len(p.stdout)))
check("E4 zero heartbeats injected while data flowed", hb_count == 0, "hb=%d" % hb_count)
check("E4 throughput healthy", thru > 20, "%.1f MB/s (%.0f MB in %.2fs)" % (thru, mb, dt))

# ---------- E4b: pervio-hb is idle-cheap (no busy-spin) ----------
print("=== E4b pervio-hb idle cost (heartbeat WHEN the interval is up, low CPU) ===")
# Read the heartbeat's ARRIVAL TIME, not how many arrive in a fixed window.
#   `hb == 1` over an 11s sleep measured the machine as much as pervio-hb: one
#   busy box delays this process past the 11s mark, the count reads 0 and the
#   suite goes red about the load. Widening it to 1..2 bought that back by
#   letting a real regression through — an interval cut in half emits at 5s and
#   10s, i.e. exactly the 2 the bound now permits.
#   A timestamp is asymmetric in our favour: scheduling delay can only make a
#   heartbeat arrive LATE, never EARLY. So the lower bound (nothing before 9s)
#   is immune to load and is what pins the interval, while the upper bound gets
#   5s of slack instead of 1s. Both directions have teeth: too early = shortened
#   interval or a spin, too late/absent = the keep-alive is gone.
IDLE = 10.0                        # the DEFAULT contract, in seconds
HBENV = {k: v for k, v in os.environ.items() if k != "PERVIO_HB_IDLE"}
try:
    import resource
    import select
    base = resource.getrusage(resource.RUSAGE_CHILDREN)
    proc = subprocess.Popen([HB], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=HBENV)
    proc.stdin.write(b'{"type":"init"}\n'); proc.stdin.flush()
    t0 = time.time()
    stamps, buf = [], b""

    def drain(until, stop_on_hit):
        """Collect heartbeat arrival times (seconds since t0) until `until`."""
        global buf
        while time.time() < until:
            r, _, _ = select.select([proc.stdout], [], [], 0.2)
            if not r:
                continue
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                return
            now = time.time() - t0
            buf += chunk
            hit = False
            while b"\n" in buf:
                ln, buf = buf.split(b"\n", 1)
                if ln == b'{"type":"heartbeat"}':
                    stamps.append(now)
                    hit = True
            if hit and stop_on_hit:
                return

    drain(t0 + IDLE * 2, True)     # generous deadline: the contract is one at 10s
    first = stamps[0] if stamps else None
    if first is not None:
        drain(time.time() + 2.0, False)   # 2s more: at a 10s interval nothing may follow
    proc.stdin.close()             # EOF → pervio-hb exits (no double-close via communicate)
    proc.stdout.read()
    proc.wait(timeout=5)
    ru = resource.getrusage(resource.RUSAGE_CHILDREN)
    cpu = (ru.ru_utime + ru.ru_stime) - (base.ru_utime + base.ru_stime)
    check("E4b the idle heartbeat fires, and not one tick before the %.0fs interval "
          "is up (arrived at %s)" % (IDLE, "NEVER" if first is None else "%.2fs" % first),
          first is not None and IDLE - 1.0 <= first <= IDLE + 5.0, "stamps=%s" % (stamps,))
    check("E4b ...and only one per interval — nothing follows it for 2s",
          len(stamps) == 1, "stamps=%s" % (stamps,))
    check("E4b idle CPU negligible (select-based, not spinning)", cpu < 1.0,
          "cpu=%.3fs over a %.0fs idle window" % (cpu, IDLE))
except Exception as e:
    check("E4b idle test ran", False, repr(e))

# ---------- E5: hermetic — prove where the state went, then take it away ------
check("E5 every run lived in the throwaway home, not the user's",
      os.path.isdir(WFROOT) and not os.path.realpath(WFROOT).startswith(REAL_HOME + os.sep),
      (WFROOT, REAL_HOME))
shutil.rmtree(HOME, ignore_errors=True)

ok = all(results)
print("\n=== P3 EFFICIENCY: %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
