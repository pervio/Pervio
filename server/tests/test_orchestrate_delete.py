#!/usr/bin/env python3
"""Tests for pervio-orchestrate's DESTRUCTIVE verbs — `delete --wf` and
`schedule remove --id` (and only those; the rest of the file is covered by
test_orchestrate_unit / test_schedule / test_fanout).

Both used to end in `shutil.rmtree(..., ignore_errors=True)` followed by an
UNCONDITIONAL success line. ignore_errors=True does exactly what it says: a
denied unlink is swallowed, so a run whose directory survived intact was
reported as deleted, disappeared from the phone's list, and stayed on disk
forever — with its ledger, its transcripts, and (for a schedule) its spec.
There is no undo and no second copy, so "I think I deleted it" is the worst
possible answer.

What this suite pins:
  - happy path unchanged (dir gone, exit 0, the same JSON the App/MCP parse);
  - a teardown that could NOT finish exits non-zero, says on stderr what is
    still on disk, and answers with machine-readable {"deleted": false,
    "remaining": [...]};
  - what `list` does after such a failure — which is the ugly part, and the
    reason the error channel is load-bearing. rmtree(ignore_errors=True) gets to
    ledger.json / schedule.json before it reaches the wedged subtree, so the
    entry DISAPPEARS from `list` while its directory is still sitting on disk.
    The phone shows a clean vanishing; the non-zero exit and the stderr line are
    the only two places where the truth exists. Cases b and e assert exactly that
    (`list == []`), so the day someone makes the store and the report agree,
    this suite goes red and this comment plus the 已知窟窿 section of
    docs/test-plan.md get corrected along with it;
  - the same three promises for `schedule remove`.

Hermetic: a throwaway $HOME per case, PERVIO_SCHED_HOOK=skip so no launchctl /
crontab is ever touched. The real ~/.pervio is never read or written.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.realpath(__file__))
ORCH = os.path.realpath(os.path.join(HERE, "..", "bin", "pervio-orchestrate"))

results = []
_homes = []
_ro_dirs = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name
          + (("  [" + str(detail)[:240] + "]") if (detail and not cond) else ""))


def mkhome():
    h = tempfile.mkdtemp(prefix="orchdel_", dir="/tmp")
    _homes.append(h)
    return h


def orch(home, *args):
    p = subprocess.run([sys.executable, ORCH] + list(args),
                       env=dict(os.environ, HOME=home, PERVIO_SCHED_HOOK="skip"),
                       stdin=subprocess.DEVNULL, capture_output=True, text=True)
    try:
        return json.loads(p.stdout), p
    except ValueError:
        return None, p


def mkrun(home, wf, status="done"):
    """A finished run's directory, shaped like a real one."""
    rd = os.path.join(home, ".pervio", "wf", wf)
    os.makedirs(rd)
    with open(os.path.join(rd, "ledger.json"), "w") as f:
        json.dump({"wfId": wf, "name": "n-" + wf, "status": status,
                   "startedAt": int(time.time()), "dir": home, "steps": []}, f)
    with open(os.path.join(rd, "status"), "w") as f:
        f.write(status + "\n")
    with open(os.path.join(rd, "runner.out"), "w") as f:
        f.write("output the user can never get back\n")
    return rd


def mksched(home, sid, enabled=True):
    sd = os.path.join(home, ".pervio", "schedules", sid)
    os.makedirs(sd)
    with open(os.path.join(sd, "schedule.json"), "w") as f:
        json.dump({"id": sid, "name": "daily-" + sid, "enabled": enabled,
                   "time": "09:00", "days": [], "spec": {"name": "x", "steps": []}}, f)
    return sd


def wedge(d):
    """Make one entry inside `d` impossible to unlink, the way a stray root-owned
    file / a locked subtree does in the field: put it in a read-only subdir. The
    subdir is restored in cleanup() so the temp HOME can still be removed."""
    sub = os.path.join(d, "locked")
    os.makedirs(sub, exist_ok=True)
    with open(os.path.join(sub, "keep.txt"), "w") as f:
        f.write("cannot be unlinked\n")
    os.chmod(sub, 0o555)
    _ro_dirs.append(sub)
    return os.path.join(sub, "keep.txt")


# ---------- a: delete --wf, happy path (must stay exactly as it was) ----------
print("=== a: delete --wf removes the run ===")
home = mkhome()
rd = mkrun(home, "wfhappy")
out, p = orch(home, "delete", "--wf", "wfhappy")
check("a exit 0", p.returncode == 0, (p.returncode, p.stderr[:200]))
check("a answers {'deleted': '<wfId>'} as before", out == {"deleted": "wfhappy"}, p.stdout[:160])
check("a the run directory is gone", not os.path.exists(rd), rd)
lst, _ = orch(home, "list")
check("a the run is gone from list", lst == [], lst)

# ---------- b: delete --wf that could not finish must not claim success ----------
print("=== b: delete --wf with an undeletable leftover ===")
home = mkhome()
rd = mkrun(home, "wfstuck")
stuck = wedge(rd)
out, p = orch(home, "delete", "--wf", "wfstuck")
check("b a teardown that left the run on disk exits NON-ZERO",
      p.returncode != 0, (p.returncode, p.stdout[:120], p.stderr[:200]))
check("b ...and answers deleted:false with a machine-readable reason",
      out is not None and out.get("deleted") is False and out.get("reason") == "residue",
      (p.stdout[:200],))
check("b ...and names the leftover paths in the JSON",
      out is not None and any("keep.txt" in r for r in (out.get("remaining") or [])),
      (out or {}).get("remaining"))
check("b ...and says on stderr what is still on disk",
      "wfstuck" in p.stderr and "keep.txt" in p.stderr, p.stderr[:240])
check("b the leftover really is still there", os.path.exists(stuck), stuck)
check("b the run directory itself also survived", os.path.isdir(rd), rd)
# rmtree gets to ledger.json before it hits the locked subtree, so `list` goes
# blind to the residue: the non-zero exit and the stderr line are the ONLY
# warning anyone gets that a run directory is still occupying the disk.
lst, _ = orch(home, "list")
check("b `list` can no longer see the residue, so the error channel is all there is",
      lst == [], lst)

# ---------- c: delete --wf of an unknown id is still a clean 'no such' ----------
print("=== c: delete --wf of an unknown run ===")
home = mkhome()
out, p = orch(home, "delete", "--wf", "nosuchrun")
check("c exits 3 with 'no such workflow' on stderr",
      p.returncode == 3 and "no such workflow" in p.stderr, (p.returncode, p.stderr[:160]))

# ---------- d: schedule remove, happy path ----------
print("=== d: schedule remove ===")
home = mkhome()
sd = mksched(home, "schappy")
out, p = orch(home, "schedule", "remove", "--id", "schappy")
check("d exit 0", p.returncode == 0, (p.returncode, p.stderr[:200]))
check("d answers removed:<id> and a hook report, as before",
      out is not None and out.get("removed") == "schappy" and "hook" in out, p.stdout[:160])
check("d the schedule directory is gone", not os.path.exists(sd), sd)
lst, _ = orch(home, "schedule", "list")
check("d the schedule is gone from schedule list", lst == [], lst)

# ---------- e: schedule remove that could not finish ----------
print("=== e: schedule remove with an undeletable leftover ===")
home = mkhome()
sd = mksched(home, "schstuck")
stuck = wedge(sd)
out, p = orch(home, "schedule", "remove", "--id", "schstuck")
check("e a removal that left the schedule dir on disk exits NON-ZERO",
      p.returncode != 0, (p.returncode, p.stdout[:120], p.stderr[:200]))
check("e ...and answers removed:false with a machine-readable reason",
      out is not None and out.get("removed") is False and out.get("reason") == "residue",
      (p.stdout[:200],))
check("e ...and names the leftover paths in the JSON",
      out is not None and any("keep.txt" in r for r in (out.get("remaining") or [])),
      (out or {}).get("remaining"))
check("e ...and says on stderr what is still on disk",
      "schstuck" in p.stderr and "keep.txt" in p.stderr, p.stderr[:240])
check("e the leftover really is still there", os.path.exists(stuck), stuck)
# Same blindness as case b: schedule.json is unlinked before rmtree reaches the
# wedged subtree, so the schedule is gone from `schedule list` while its directory
# (and, on a real box, whatever the hook left behind) is still on disk.
lst, _ = orch(home, "schedule", "list")
check("e `schedule list` is blind to the residue too — same ghost as b",
      lst == [], lst)

# ---------- f: schedule remove of an unknown id ----------
print("=== f: schedule remove of an unknown id ===")
home = mkhome()
out, p = orch(home, "schedule", "remove", "--id", "nosuchsched")
check("f exits 3 with 'no such schedule' on stderr",
      p.returncode == 3 and "no such schedule" in p.stderr, (p.returncode, p.stderr[:160]))


def cleanup():
    for d in _ro_dirs:
        try:
            os.chmod(d, 0o755)
        except OSError:
            pass
    for h in _homes:
        shutil.rmtree(h, ignore_errors=True)


cleanup()
leaked = [h for h in _homes if os.path.exists(h)]
check("cleanup left no temp HOME behind", leaked == [], leaked)
# ---------- D-codex: delete sweeps CODEX sessions too (the 21-ghost hole) ----------
# Claude children were reaped precisely (pervio-sessions delete) and wholesale
# (~/.claude/projects prefix); codex children lived FOREVER in their own store —
# 21 month-old audit jurors were still haunting the project list on 2026-08-24.
# Pins: a codex top-level step's sessionId (+ retried/prior ids) and every codex
# fan-out child's thread id (parsed from its stream) take their rollout files
# with them; NON-listed rollouts survive untouched.
print("=== D-codex: codex session sweep ===")
home = mkhome()
wf = "cxsweep000001"
rd = mkrun(home, wf)
sess = os.path.join(home, ".codex", "sessions", "2026", "08", "24")
os.makedirs(sess)


def rollout(tid):
    p = os.path.join(sess, "rollout-2026-08-24T01-00-00-%s.jsonl" % tid)
    with open(p, "w") as f:
        f.write(json.dumps({"type": "thread.started", "thread_id": tid}) + "\n")
    return p


keep = rollout("019f0000-keep-7000-a000-000000000001")
top = rollout("019f0000-top0-7000-a000-000000000002")
prior = rollout("019f0000-prio-7000-a000-000000000003")
child = rollout("019f0000-chld-7000-a000-000000000004")
with open(os.path.join(rd, "ledger.json"), "w") as f:
    json.dump({"wfId": wf, "name": "n", "status": "done", "dir": home,
               "startedAt": int(time.time()),
               "steps": [{"id": "take", "backend": "codex", "status": "done",
                          "sessionId": "019f0000-top0-7000-a000-000000000002",
                          "priorSessionIds": ["019f0000-prio-7000-a000-000000000003"],
                          "sessionDir": home}]}, f)
cdir = os.path.join(rd, "dispatch", "fanout", "audit", "0")
os.makedirs(cdir)
with open(os.path.join(cdir, "out.jsonl"), "w") as f:
    f.write(json.dumps({"type": "thread.started",
                        "thread_id": "019f0000-chld-7000-a000-000000000004"}) + "\n")
    f.write(json.dumps({"type": "turn.completed"}) + "\n")
out, p = orch(home, "delete", "--wf", wf)
check("D-codex delete succeeds and the run dir is gone",
      p.returncode == 0 and not os.path.isdir(rd), (p.returncode, p.stderr[:150]))
check("D-codex top-level codex session + prior attempt reaped",
      not os.path.exists(top) and not os.path.exists(prior))
check("D-codex fan-out child's rollout reaped (thread id from its stream)",
      not os.path.exists(child))
check("D-codex unrelated rollout untouched", os.path.exists(keep))

ok = all(results)
print("\n=== pervio-orchestrate delete/sweep: %s (%d/%d) ==="
      % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
