#!/usr/bin/env python3
"""Long-run convergence for `pervio-orchestrate schedule`: is the state still
CORRECT after the thing has been running for weeks? Every question here is about
day N, not day 1, so the clock is INJECTED (PERVIO_TICK_NOW) and this suite never
waits on a real one — a fortnight replays in seconds.

Four properties, each one a way the product quietly rots in the field:

  C1 steady state. N daily fires later, three independent records must still tell
     the same story: the run directories on disk, `list`, and the schedule record
     (lastFired / lastWfId / attempts / lastError) — plus the publication, which
     must survive keepRuns pruning that deletes the very runs that produced it.
     A digest you can still read a month later is the whole point of the product.

  C2 a runner that DIES. kill -9 leaves no exception for _crash_run to catch, so
     nothing lands the run. What the schedule does next is what matters: the daily
     digest must keep arriving. It does — the overlap guard checks pgid liveness,
     not ledger text — and `schedule list` heals its lastStatus to "failed". Since
     2026-08-22 the ledger heals too: every reader (list/status/tail) and the
     pruner settle a dead run through the same liveness check, so the suite pins
     those as promises.

  C3 disk. The same schedule, run twice as long, must occupy the SAME space: run
     dirs, git worktree registrations, pervio/wf-* branches, ~/.claude conversation
     folders. Measured as two snapshots (day 7 vs day 13) that have to be equal —
     a bound that no amount of product churn can satisfy by accident.

  C4 a clock that lies. Sleep, NTP correction, westward travel and DST all hand
     the tick a `now` that moved backward or jumped forward. One period must
     produce exactly one issue: never twice, and never once per missed day.

Hermetic: a throwaway $HOME per section under /tmp, PERVIO_SCHED_HOOK=skip (no
launchctl/crontab), shim `claude` on PATH (zero model calls; most steps here are
plain command steps, so not even the shim runs). C0 shows where the state went
before any of it is believed, and the Z block at the end reads the USER's real
~/.pervio, ~/.claude and LaunchAgents back and proves this suite put nothing there
— it remembers every wfId it started and looks for each one in the real run dir, so
a HOME leak in any helper lands here instead of in the user's home. Every process
this suite starts is accounted for at the end too.

Reading the day out of a run: the command steps echo $PERVIO_TICK_NOW, which the
detached runner inherits from the tick that launched it, so each run's own output
names the simulated day it belongs to — that is how "the survivors are the newest
three" is checked without trusting file order. `startedAt` is real epoch seconds
and a replayed fortnight lands many runs inside the same second, so after each day
settles the suite back-dates that run's startedAt to its simulated day. Production
spaces them 24h apart; the replay has to say so, or the pruner's newest-first sort
is decided by a uuid tiebreak and the test would be asserting noise.
"""
import base64
import datetime
import glob
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.realpath(__file__))
BIN = os.path.realpath(os.path.join(HERE, "..", "bin"))
ORCH = os.path.join(BIN, "pervio-orchestrate")
SHIM = os.path.join(HERE, "shim")
REAL_HOME = os.path.realpath(os.path.expanduser("~"))

results = []
_homes = []
_pgids = []                    # every runner group we saw, for the leak self-check
_extra_pids = []               # individual processes we learned about (C2's witness)
_created = []                  # (home, wfId) for every run this suite started


def real(*parts):
    return os.path.join(REAL_HOME, *parts)


def name_set(path):
    """Sorted entries of a real directory, or None when it isn't there. Names only:
    the user's own launchd tick rewrites tick.log while this suite runs, and a
    tripwire that fires on that is a tripwire nobody will keep."""
    try:
        return sorted(os.listdir(path))
    except OSError:
        return None


def plist_stamp():
    p = real("Library", "LaunchAgents", "com.pervio.schedule.plist")
    try:
        return (True, os.path.getmtime(p))
    except OSError:
        return (False, 0)


# Taken BEFORE anything runs; re-read at the very end (the Z block). These are the
# marks a HOME leak would leave on the user's machine: one of our runs in their
# ~/.pervio/wf, their schedule list changed, their launchd job registered by a hook
# that was told to skip, or conversation folders swept out from under them.
PROD_SCHEDULES = name_set(real(".pervio", "schedules"))
PROD_PLIST = plist_stamp()
PROD_CONVS = len(name_set(real(".claude", "projects")) or [])


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name
          + (("  [" + str(detail)[:260] + "]") if (detail and not cond) else ""))


def note(text):
    """Measured numbers belong here, NOT in a check's name: a name that carries the
    value it measured changes when the value changes, and then a mutation run can no
    longer tell 'this assertion went red' from 'this assertion is gone'."""
    print("     · " + str(text))


MYPID = os.getpid()                    # every temp name carries it — see the last check


def mkhome(tag):
    """A throwaway HOME whose NAME carries this process's pid. That is what lets the
    final residue check scan /tmp for real (an unregistered home leaks too) without
    matching the temp dirs of a SECOND copy of run_all.sh running beside us — the
    mistake test_view's J14 made with `pgrep -f sleeper.py`."""
    h = tempfile.mkdtemp(prefix="conv_%d_%s_" % (MYPID, tag), dir="/tmp")
    _homes.append(h)
    return h


def env(home, now=None):
    e = dict(os.environ, HOME=home, PATH=SHIM + ":" + os.environ.get("PATH", ""),
             PERVIO_SCHED_HOOK="skip",
             # git must not read the user's real config (hooks, gpg signing, a
             # global excludesfile) — the isolation section commits for real.
             GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null",
             GIT_AUTHOR_NAME="pervio-test", GIT_AUTHOR_EMAIL="test@invalid",
             GIT_COMMITTER_NAME="pervio-test", GIT_COMMITTER_EMAIL="test@invalid")
    if now:
        e["PERVIO_TICK_NOW"] = now
    return e


def orch(home, args, now=None):
    return subprocess.run([sys.executable, ORCH] + args, env=env(home, now),
                          stdin=subprocess.DEVNULL, capture_output=True, text=True)


def b64(o):
    return base64.b64encode(json.dumps(o).encode()).decode()


def wfroot(home):
    return os.path.join(home, ".pervio", "wf")


def wf_ids(home):
    try:
        return sorted(os.listdir(wfroot(home)))
    except OSError:
        return []


def ledger(home, wid):
    try:
        with open(os.path.join(wfroot(home), wid, "ledger.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def pgid_of(home, wid):
    try:
        with open(os.path.join(wfroot(home), wid, "pgid")) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return 0


def alive(pgid):
    if not pgid:
        return False
    try:
        os.killpg(pgid, 0)
        return True
    except OSError:
        return False


def alive_pid(pid):
    """One PROCESS, not a group — used for the command child C2 kills, whose pid the
    test learns from the command itself rather than from the product."""
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def settle(home, timeout=40):
    """Wait until no run in this HOME has a LIVE process group. Ledger text alone
    is not enough — a killed runner keeps saying 'running' forever, which is the
    very defect C2 is about, so liveness is decided by the group, not the file."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not any(alive(pgid_of(home, w)) for w in wf_ids(home)):
            return True
        time.sleep(0.05)
    return False


def backdate(home, wid, iso):
    """Give a settled run the startedAt its simulated day would have had."""
    p = os.path.join(wfroot(home), wid, "ledger.json")
    try:
        with open(p) as f:
            led = json.load(f)
    except (OSError, ValueError):
        return
    led["startedAt"] = int(datetime.datetime.fromisoformat(iso).timestamp())
    with open(p, "w") as f:
        json.dump(led, f)


def tick_day(home, iso):
    """One OS-clock tick at `iso`; returns (fired wfId or "", period or "")."""
    p = orch(home, ["schedule", "tick"], now=iso)
    for w in wf_ids(home):                 # remember every group we ever spawn
        g = pgid_of(home, w)
        if g and g not in _pgids:
            _pgids.append(g)
    if not (p.stdout or "").strip():
        return "", ""
    try:
        f = json.loads(p.stdout)["fired"][0]
        _created.append((home, f["wfId"]))
        return f["wfId"], f["period"]
    except (ValueError, KeyError, IndexError):
        return "", ""


def day_run(home, iso):
    """Tick, wait for the run to really end, then back-date it. Returns wfId."""
    wid, period = tick_day(home, iso)
    settle(home)
    if wid:
        backdate(home, wid, iso)
    return wid, period


def sched_row(home, now):
    try:
        rows = json.loads(orch(home, ["schedule", "list"], now=now).stdout)
        return rows[0] if rows else {}
    except (ValueError, IndexError):
        return {}


def listing(home):
    try:
        return json.loads(orch(home, ["list"]).stdout)
    except ValueError:
        return []


def day_of(led):
    """The simulated day a run belongs to, read out of its own step output."""
    for s in led.get("steps", []):
        out = s.get("output") or ""
        if out.startswith("day-"):
            return out[4:14]
    return ""


def status_file(home, wid):
    """The run's terminal `status` file — written by the runner independently of
    the ledger, which is what makes it a real cross-check rather than an echo."""
    try:
        with open(os.path.join(wfroot(home), wid, "status")) as f:
            return f.read().strip()
    except OSError:
        return ""


def read_text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


CMD = "printf day-$PERVIO_TICK_NOW"
DAY = "2026-07-%02dT07:00"                 # 07:00 local, schedule fires at 06:30


# ---------- C0: prove the hermetic claim before believing anything else ----------
print("=== C0: hermetic — the state lives in a throwaway HOME ===")
h0 = mkhome("c0")
spec0 = {"name": "probe", "dir": h0, "steps": [
    {"id": "a", "backend": "claude", "command": CMD}]}
p = orch(h0, ["schedule", "add", "--b64",
              b64({"name": "probe", "time": "06:30", "keepRuns": 2, "spec": spec0})],
         now=DAY % 1)
sid0 = json.loads(p.stdout)["id"] if p.returncode == 0 else ""
w0, _ = day_run(h0, DAY % 2)
check("C0 the schedule and its run landed under the temp HOME, not the real one",
      bool(sid0) and bool(w0)
      and os.path.isdir(os.path.join(h0, ".pervio", "wf", w0))
      and not os.path.realpath(wfroot(h0)).startswith(REAL_HOME + os.sep),
      (h0, sid0, w0))
check("C0 the schedule dir the tick reads is the temp one, and it has the record",
      os.path.isfile(os.path.join(h0, ".pervio", "schedules", sid0 or "x",
                                  "schedule.json")),
      os.path.join(h0, ".pervio", "schedules", sid0 or "x"))


# ---------- C1: N days of steady state ----------
# 12 daily fires, keepRuns=3. What has to be true on day 12 is not "it ran" but
# that the three places a user can look — the disk, `list`, the schedule record —
# and the publication they actually read still agree with each other.
print("=== C1: 12 daily fires, keepRuns=3 — disk, list, schedule record, archive ===")
h1 = mkhome("c1")
PUB = os.path.join(h1, "digest")
os.makedirs(PUB)
# A year-old archive that accumulated before this suite existed: pruning runs must
# never reach it. Dated names, exactly as _publish_output writes them.
seeded = ["2026-06-%02d.md" % d for d in range(1, 21)]
for fn in seeded:
    with open(os.path.join(PUB, fn), "w") as f:
        f.write("old issue " + fn + "\n")

spec1 = {"name": "morning digest", "dir": h1, "steps": [
    {"id": "gen", "backend": "claude", "command": CMD, "publish": PUB}]}
p = orch(h1, ["schedule", "add", "--b64",
              b64({"name": "digest", "time": "06:30", "keepRuns": 3, "spec": spec1})],
         now=DAY % 1)
check("C1 schedule added", p.returncode == 0, p.stderr[:200])
try:
    sid1 = json.loads(p.stdout)["id"]
except (ValueError, KeyError):
    sid1 = ""

fired_days, fired_ids = [], []
for d in range(2, 14):                     # days 2..13 = 12 consecutive fires
    wid, period = day_run(h1, DAY % d)
    if wid:
        fired_days.append(period)
        fired_ids.append(wid)
LAST_DAY = 13

note("fires: %d  periods: %s" % (len(fired_days), ",".join(fired_days)))
check("C1a every one of the 12 days fired exactly once, in order",
      fired_days == ["2026-07-%02d" % d for d in range(2, 14)], fired_days)
check("C1a the 12 fires were 12 distinct runs",
      len(set(fired_ids)) == 12, len(set(fired_ids)))

survivors = wf_ids(h1)
led_by_day = {day_of(ledger(h1, w)): w for w in survivors}
note("run dirs after 12 fires with keepRuns=3: %d %s" % (len(survivors), survivors))
check("C1b after 12 fires the disk holds exactly keepRuns=3 run dirs",
      len(survivors) == 3, survivors)
check("C1b the 3 survivors are the NEWEST three days (11, 12, 13)",
      sorted(led_by_day) == ["2026-07-11", "2026-07-12", "2026-07-13"],
      sorted(led_by_day))
check("C1b every survivor finished (no run left mid-flight by the pruner)",
      all(ledger(h1, w).get("status") == "done" for w in survivors),
      [(w, ledger(h1, w).get("status")) for w in survivors])

lst = listing(h1)
check("C1c `list` shows exactly the dirs on disk — no ghost rows, none missing",
      sorted(i["wfId"] for i in lst) == sorted(survivors),
      ([i["wfId"] for i in lst], survivors))
check("C1c every row in `list` carries the scheduleId that owns it",
      bool(sid1) and all(i.get("scheduleId") == sid1 for i in lst),
      [i.get("scheduleId") for i in lst])
# `list` copies the ledger's status verbatim, so comparing the two would assert
# nothing. The runner writes the terminal `status` FILE separately — that is the
# independent record, and the two must not disagree.
check("C1c `list`'s status agrees with the run's own terminal status file",
      bool(lst) and all((i["status"] == "done") == (status_file(h1, i["wfId"]) == "exited:0")
                        and status_file(h1, i["wfId"]) in ("exited:0", "exited:1")
                        for i in lst),
      [(i["wfId"], i["status"], status_file(h1, i["wfId"])) for i in lst])

ROW_NOW = "2026-07-13T08:00"               # an hour after day 13's fire
row = sched_row(h1, ROW_NOW)
newest = led_by_day.get("2026-07-13", "")
check("C1d the schedule record's lastFired is day 13's period",
      row.get("lastFired") == "2026-07-13", row.get("lastFired"))
check("C1d lastWfId points at a run that still EXISTS (the pruner kept it)",
      row.get("lastWfId") == newest and newest in survivors,
      (row.get("lastWfId"), newest, survivors))
check("C1d 12 clean days left no error and no retry debt",
      row.get("attempts") == 0 and not row.get("lastError"),
      (row.get("attempts"), row.get("lastError")))
check("C1d lastStatus reflects the last run: done",
      row.get("lastStatus") == "done", row.get("lastStatus"))
check("C1d nextDue is tomorrow 06:30, not a date left behind 12 days ago",
      row.get("nextDue") == int(datetime.datetime(2026, 7, 14, 6, 30).timestamp()),
      (row.get("nextDue"), int(datetime.datetime(2026, 7, 14, 6, 30).timestamp())))

# The publication. The issue FILENAME follows the issue's OWN dated first line
# (_publish_output parses it; the real digest titles itself with the fetch's
# UTC-cycle date), so a replayed fortnight files one issue PER COVERED DAY.
# This replaced the local-now rule — which squashed a catch-up's eleven days
# into the one file of the day it happened to run, and misfiled a
# midnight-side run's issue under the NEXT local day (the empty「2026-08-14」
# that was really 08-13's papers). The no-dated-title fallback (local date)
# is pinned in test_orchestrate_unit U15, not here — this step's output
# carries its day, like the digest's does.
issues = sorted(f for f in os.listdir(PUB) if f.endswith(".md"))
new_issues = [f for f in issues if f not in seeded]
note("archive: %d seeded + %d new = %d issues; new = %s"
     % (len(seeded), len(new_issues), len(issues), new_issues))
check("C1e the 20 pre-existing issues survived 9 prunes untouched",
      [f for f in issues if f in seeded] == seeded, len(seeded))
check("C1e the replay filed one issue per covered day, named by the issue itself",
      new_issues == ["2026-07-%02d.md" % d for d in range(2, 14)], new_issues)
body = read_text(os.path.join(PUB, "2026-07-%02d.md" % LAST_DAY))
check("C1e each issue holds its own day's output",
      body == "day-" + (DAY % LAST_DAY), (body or "<missing>")[:60])
check("C1e no half-written issue left behind (no .tmp residue in the archive)",
      [f for f in os.listdir(PUB) if ".tmp." in f] == [],
      [f for f in os.listdir(PUB) if ".tmp." in f])

try:
    arc = json.loads(orch(h1, ["archives", "list"], now=ROW_NOW).stdout)
except ValueError:
    arc = []
entry = next((e for e in arc
              if os.path.realpath(e.get("dir", "")) == os.path.realpath(PUB)), {})
check("C1f archives lists the publication with every issue on disk",
      len(entry.get("files", [])) == len(issues),
      (len(entry.get("files", [])), len(issues)))
check("C1f the archive entry joins the schedule that feeds it",
      entry.get("scheduleId") == sid1 and entry.get("scheduleEnabled") is True,
      (entry.get("scheduleId"), sid1))
check("C1f the archive's vitals match the schedule record (one story, two readers)",
      entry.get("lastStatus") == row.get("lastStatus")
      and entry.get("nextDue") == row.get("nextDue"),
      (entry.get("lastStatus"), row.get("lastStatus"),
       entry.get("nextDue"), row.get("nextDue")))


# ---------- C2: the runner is killed outright ----------
# kill -9 the whole runner group: no exception, no atexit, nothing for _crash_run
# to catch. This is the reboot / OOM-killer / `killall python3` case.
print("=== C2: kill -9 mid-run — does the schedule converge? ===")
h2 = mkhome("c2")
# The slow command reports its OWN pid before it sleeps. That file is the test's
# independent witness: the runner spawns command steps in their own session, so
# killing the runner's group does not touch them, and the only other way to find
# the child is the product's own live/ registry. Asserting on THAT would mean a
# regression that stops registering children turns C2a from a real check into a
# vacuous one (`any([])` is False) — green, while a 20-second `sleep` outlives the
# suite. With the witness, the same regression is a plain red instead of a leak.
ZPID = os.path.join(h2, "zpid")
slow = {"name": "slow", "dir": h2, "steps": [
    {"id": "a", "backend": "claude",
     "command": "echo $$ > '%s'; sleep 20" % ZPID}]}
fast = {"name": "fast", "dir": h2, "steps": [
    {"id": "a", "backend": "claude", "command": CMD}]}
p = orch(h2, ["schedule", "add", "--b64",
              b64({"name": "daily", "time": "06:30", "keepRuns": 2, "spec": slow})],
         now=DAY % 1)
try:
    sid2 = json.loads(p.stdout)["id"]
except (ValueError, KeyError):
    sid2 = ""

zombie, _ = tick_day(h2, DAY % 2)


def witness():
    """The sleeping command's own pid, straight from the command's mouth."""
    try:
        with open(ZPID) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return 0


zpgid = wpid = 0
for _ in range(200):                       # let the runner reach the sleep step
    zpgid = pgid_of(h2, zombie)
    wpid = witness()
    steps = ledger(h2, zombie).get("steps") or [{}]
    if zpgid and wpid and steps[0].get("status") == "running":
        break
    time.sleep(0.05)
_extra_pids.append(wpid)                   # counted by the leak self-check at the end
check("C2 precondition: the runner group AND the command it spawned were alive "
      "before the kill (the command's pid came from the command itself)",
      alive(zpgid) and alive_pid(wpid), (zpgid, wpid))
# A reboot takes the command's own session down with the runner; kill both, so this
# suite leaves nothing running either (the orphan would outlive the test by 20s).
live_dir = os.path.join(wfroot(h2), zombie, "live")
children = []
for n in (os.listdir(live_dir) if os.path.isdir(live_dir) else []):
    try:
        children.append(int(n))
    except ValueError:
        pass
# NEVER killpg(0): pgid_of() answers 0 when the pgid file is missing or unreadable,
# and process group 0 means MY OWN — so the day a regression stops the runner from
# recording its pgid, an unguarded kill here does not turn one assertion red, it
# SIGKILLs the process group this suite is running in: run_all.sh, the CI shell, the
# developer's terminal, all gone with no output and no failure report. (Reproduced:
# the parent died having printed nothing at all.) Guarded, the same regression prints
# a plain red C2 precondition and the run continues. Same reasoning for the children,
# whose pgids are parsed out of directory names.
if zpgid > 1:
    try:
        os.killpg(zpgid, signal.SIGKILL)
    except OSError:
        pass
for c in children:
    if c <= 1:
        continue
    try:
        os.killpg(c, signal.SIGKILL)
    except OSError:
        pass
# And the witness, whether or not the product remembered to register it. Its group
# is signalled only after CONFIRMING it leads one; otherwise just the process. A
# pgid this suite did not verify is never a signal target — same rule as above.
if wpid > 1:
    try:
        if os.getpgid(wpid) == wpid:
            os.killpg(wpid, signal.SIGKILL)
        else:
            os.kill(wpid, signal.SIGKILL)
    except OSError:
        pass
for _ in range(100):
    if not alive(zpgid) and not alive_pid(wpid) and not any(alive(c) for c in children):
        break
    time.sleep(0.05)
check("C2a the runner group and the command it spawned are really gone",
      not alive(zpgid) and wpid and not alive_pid(wpid)
      and not any(alive(c) for c in children),
      (zpgid, wpid, children))
# The crash is day 2's; give it day 2's clock like every other run, so the pruner
# sees a six-day-old corpse rather than the newest thing on disk.
backdate(h2, zombie, DAY % 2)

zombie_sched_status = sched_row(h2, DAY % 2).get("lastStatus")
check("C2b `schedule list` heals: the last run reads failed, not running",
      zombie_sched_status == "failed", zombie_sched_status)

# The property with the money attached: tomorrow's digest still arrives.
p = orch(h2, ["schedule", "update", "--b64", b64({"id": sid2, "spec": fast})],
         now=DAY % 2)
check("C2 spec swapped to a fast step for the remaining days", p.returncode == 0,
      p.stderr[:200])
after = []
for d in range(3, 9):
    wid, period = day_run(h2, DAY % d)
    if wid:
        after.append(period)
note("days that fired after the crash: %s" % ",".join(after))
check("C2c a dead 'running' run does NOT wedge the schedule — all 6 later days fired",
      after == ["2026-07-%02d" % d for d in range(3, 9)], after)
row2 = sched_row(h2, DAY % 9)
check("C2d the schedule record moved on: lastFired is day 8, no error, no retry debt",
      row2.get("lastFired") == "2026-07-08" and not row2.get("lastError")
      and row2.get("attempts") == 0,
      (row2.get("lastFired"), row2.get("lastError"), row2.get("attempts")))
check("C2d and lastStatus follows the LIVE run, not the corpse",
      row2.get("lastStatus") == "done" and row2.get("lastWfId") != zombie,
      (row2.get("lastStatus"), row2.get("lastWfId"), zombie))

# ---- Formerly the KNOWN HOLES block: three inverted pins on a real defect (a
# kill -9'd run's ledger said "running" forever; list/status/tail believed it and
# the pruner skipped the corpse). Fixed 2026-08-22 exactly as the old comment
# prescribed — cmd_list / cmd_status / cmd_tail / _prune_sched_runs now settle a
# dead run through the same _wf_alive liveness check _last_status always used
# (_reconcile_dead flips the record once, atomically). The pins below are now
# PROMISES: no reader may ever call a dead run running, the readers must agree,
# the pruner must collect the corpse, and tail must return.
zled = ledger(h2, zombie)
try:
    zstatus_verb = json.loads(orch(h2, ["status", "--wf", zombie]).stdout).get("status")
except (ValueError, AttributeError):
    zstatus_verb = None
zlist = next((i["status"] for i in listing(h2) if i["wfId"] == zombie), None)
note("the corpse reads: ledger=%s status-file=%s list=%s status-verb=%s "
     "schedule-list=%s" % (zled.get("status"), status_file(h2, zombie), zlist,
                           zstatus_verb, zombie_sched_status))
note("run dirs with keepRuns=2, six days after the crash: %d %s"
     % (len(wf_ids(h2)), wf_ids(h2)))
check("C2e no reader ever calls the dead run running (list/status/ledger/file)",
      "running" not in (zled.get("status"), zlist, zstatus_verb,
                        status_file(h2, zombie)),
      (zled.get("status"), zlist, zstatus_verb, status_file(h2, zombie)))
check("C2e the readers AGREE: schedule list says failed, and the run itself "
      "either reads failed or has already been reclaimed",
      zombie_sched_status == "failed"
      and (zled.get("status") in (None, "failed")),
      (zombie_sched_status, zled.get("status")))
check("C2f the corpse is COLLECTED: keepRuns=2 holds exactly two dirs, "
      "and the crashed run is not among them",
      zombie not in wf_ids(h2) and len(wf_ids(h2)) == 2,
      (zombie, wf_ids(h2)))
# The consequence a USER meets: open the crashed run on the phone and the spinner
# never stops. `tail` streams until the ledger turns terminal, and this one never
# will — so the stream is still open when the timeout fires. Pinned with a hard 4s
# bound (the verb's own heartbeat is every 10s, so 4s is unambiguous) and the child
# is killed either way, so this measures the product's behaviour, not our patience.
tailed_out = None
try:
    subprocess.run([sys.executable, ORCH, "tail", "--wf", zombie], env=env(h2),
                   stdin=subprocess.DEVNULL, capture_output=True, timeout=4)
    tailed_out = False                     # it RETURNED: the run reads terminal now
except subprocess.TimeoutExpired:
    tailed_out = True                      # still streaming a run that died days ago
except OSError:
    tailed_out = None
check("C2g `tail` on the killed run RETURNS (terminal snapshot or clean "
      "refusal) — the phone's spinner has an end",
      tailed_out is False, tailed_out)


# ---------- C3: run it twice as long, occupy the same space ----------
# Worktree isolation on (a real git repo as the spec dir, two independent writer
# steps), so each day creates worktrees, branches and conversation folders — the
# things that actually pile up. Snapshot at day 7, run 6 more days, snapshot again.
print("=== C3: disk does not grow with N (day 7 vs day 13, keepRuns=2) ===")
h3 = mkhome("c3")
repo = os.path.join(h3, "proj")
os.makedirs(repo)


def git(*a):
    return subprocess.run(["git"] + list(a), cwd=repo, env=env(h3),
                          stdin=subprocess.DEVNULL, capture_output=True, text=True)


git("init", "-q", "-b", "main")
with open(os.path.join(repo, "README"), "w") as f:
    f.write("seed\n")
git("add", "-A")
git("commit", "-qm", "init")
spec3 = {"name": "iso", "dir": repo, "steps": [
    {"id": "one", "backend": "claude",
     "command": "printf day-$PERVIO_TICK_NOW > one.txt; " + CMD},
    {"id": "two", "backend": "claude",
     "command": "printf day-$PERVIO_TICK_NOW > two.txt; printf two"}]}
p = orch(h3, ["schedule", "add", "--b64",
              b64({"name": "iso", "time": "06:30", "keepRuns": 2, "spec": spec3})],
         now=DAY % 1)
check("C3 isolated schedule added", p.returncode == 0, p.stderr[:200])


def footprint():
    """Everything that could grow without bound, counted."""
    files = sum(len(fs) for _, _, fs in os.walk(os.path.join(h3, ".pervio")))
    wt = [l for l in git("worktree", "list").stdout.splitlines() if l.strip()]
    br = [l for l in git("for-each-ref", "--format=%(refname:short)",
                         "refs/heads/pervio/").stdout.splitlines() if l.strip()]
    proj = os.path.join(h3, ".claude", "projects")
    convs = sorted(os.listdir(proj)) if os.path.isdir(proj) else []
    stray = []
    for root, _, fs in os.walk(os.path.join(h3, ".pervio")):
        stray += [os.path.join(root, f) for f in fs if ".tmp." in f]
    return {"runs": len(wf_ids(h3)), "files": files, "worktrees": len(wt),
            "wfBranches": len(br), "conversations": len(convs), "stray": stray}


def fake_conversation(wid):
    """A run's agent turn leaves a ~/.claude/projects folder named after the cwd it
    ran in. The shim never creates one, so plant it exactly where the real CLI
    would (the encoding _sweep_conversations mirrors) and let the pruner prove it
    sweeps the pruned runs' folders and only those."""
    enc = "".join(c if c.isalnum() else "-"
                  for c in os.path.realpath(os.path.join(wfroot(h3), wid)))
    d = os.path.join(h3, ".claude", "projects", enc + "-wt-steps-one")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "session.jsonl"), "w") as f:
        f.write('{"type":"user"}\n')


iso_ok = True
for d in range(2, 9):                      # days 2..8
    wid, _ = day_run(h3, DAY % d)
    if not wid:
        iso_ok = False
    else:
        fake_conversation(wid)
        st = ledger(h3, wid).get("steps", [])
        if not all(s.get("isolation") == "worktree" for s in st):
            iso_ok = False
snap_a = footprint()
check("C3 precondition: every day really ran under worktree isolation", iso_ok,
      [(s.get("id"), s.get("isolation")) for s in ledger(h3, wid).get("steps", [])])
for d in range(9, 15):                     # 6 more days
    wid, _ = day_run(h3, DAY % d)
    if wid:
        fake_conversation(wid)
snap_b = footprint()

MEASURED = ("runs", "files", "worktrees", "wfBranches", "conversations")
note("footprint after  7 days: " + json.dumps({k: snap_a[k] for k in MEASURED}))
note("footprint after 13 days: " + json.dumps({k: snap_b[k] for k in MEASURED}))
check("C3a run dirs converged to keepRuns=2 and stayed there",
      snap_a["runs"] == 2 and snap_b["runs"] == 2, (snap_a, snap_b))
check("C3b twice the days, byte-for-byte the same footprint",
      {k: snap_a[k] for k in MEASURED} == {k: snap_b[k] for k in MEASURED},
      (snap_a, snap_b))
check("C3c no stale worktree registrations left in the repo (just the repo itself)",
      snap_b["worktrees"] == 1, snap_b)
check("C3d no pervio/wf-* branches survive their runs",
      snap_b["wfBranches"] == 0, snap_b)
check("C3e conversation folders track the surviving runs only",
      snap_b["conversations"] == snap_b["runs"] and snap_b["runs"] > 0, snap_b)
check("C3f no half-written temp files anywhere under .pervio", snap_b["stray"] == [],
      snap_b["stray"])
check("C3g the run dirs themselves are gone, not just delisted",
      sorted(i["wfId"] for i in listing(h3)) == wf_ids(h3),
      ([i["wfId"] for i in listing(h3)], wf_ids(h3)))


# ---------- C4: the clock lies ----------
# keepRuns is deliberately large here: nothing is pruned, so the number of run
# directories IS the number of times the user was billed for a digest.
print("=== C4: backward / repeated / jumped clock — one period, one issue ===")
h4 = mkhome("c4")
spec4 = {"name": "clock", "dir": h4, "steps": [
    {"id": "a", "backend": "claude", "command": CMD}]}
p = orch(h4, ["schedule", "add", "--b64",
              b64({"name": "clock", "time": "06:30", "keepRuns": 50, "spec": spec4})],
         now="2026-09-01T07:00")
check("C4 schedule added and armed to the current period", p.returncode == 0,
      p.stderr[:200])
periods = []


def at(iso):
    wid, period = day_run(h4, iso)
    if period:
        periods.append(period)
    return wid


at("2026-09-02T06:31")
check("C4a a due tick fires once", periods == ["2026-09-02"], periods)
for t in ("2026-09-02T06:35", "2026-09-02T09:00", "2026-09-02T23:59"):
    at(t)
check("C4a three more ticks inside the SAME period fire nothing",
      periods == ["2026-09-02"] and len(wf_ids(h4)) == 1, (periods, wf_ids(h4)))

at("2026-09-03T06:29")
check("C4b one minute BEFORE the hour is still yesterday's period — no fire",
      periods == ["2026-09-02"], periods)
at("2026-09-03T06:30")
check("C4b the tick exactly ON 06:30 fires day 3",
      periods[-1:] == ["2026-09-03"], periods)

at("2026-09-01T12:00")                     # NTP correction / flying west
check("C4c the clock jumping two days BACKWARD refires nothing",
      periods == ["2026-09-02", "2026-09-03"] and len(wf_ids(h4)) == 2,
      (periods, wf_ids(h4)))
at("2026-09-03T06:00")                     # backward inside the same day
check("C4c a backward jump inside the day refires nothing either",
      periods == ["2026-09-02", "2026-09-03"] and len(wf_ids(h4)) == 2,
      (periods, wf_ids(h4)))
check("C4c the record was not rolled back by the backward clock",
      sched_row(h4, "2026-09-03T12:00").get("lastFired") == "2026-09-03",
      sched_row(h4, "2026-09-03T12:00").get("lastFired"))

at("2026-09-10T08:00")                     # a week of sleep/downtime
check("C4d a 7-day gap catches up with ONE issue, the most recent",
      periods == ["2026-09-02", "2026-09-03", "2026-09-10"] and len(wf_ids(h4)) == 3,
      (periods, wf_ids(h4)))
at("2026-09-11T07:00")
check("C4e the clock behaving again resumes normal daily service",
      periods[-1:] == ["2026-09-11"] and len(wf_ids(h4)) == 4, (periods, wf_ids(h4)))
at("2026-09-11T07:00")                     # the identical instant, twice
check("C4e replaying the identical instant does not double-bill",
      len(wf_ids(h4)) == 4 and len(periods) == 4, (periods, wf_ids(h4)))
note("12 ticks across a lying clock produced %d runs for periods %s"
     % (len(wf_ids(h4)), ",".join(periods)))
check("C4f every run that exists belongs to a period that was billed exactly once",
      sorted(day_of(ledger(h4, w)) for w in wf_ids(h4)) == sorted(periods)
      and len(set(periods)) == len(periods),
      (sorted(day_of(ledger(h4, w)) for w in wf_ids(h4)), sorted(periods)))


# ---------- Z: the production tripwire, read back at the end ----------
# Every run this suite started, checked against the USER's real state. A HOME leak
# anywhere above (a helper that forgot env=, a hard-coded expanduser) puts one of
# these ids into ~/.pervio/wf, and this is where that shows up.
leaked_runs = [w for _, w in _created if os.path.exists(real(".pervio", "wf", w))]
note("runs started by this suite: %d; found in the real ~/.pervio/wf: %d"
     % (len(_created), len(leaked_runs)))
check("Z not one run this suite started exists in the real ~/.pervio/wf",
      bool(_created) and leaked_runs == [], leaked_runs[:5])
check("Z the user's own schedules were neither added to nor removed",
      name_set(real(".pervio", "schedules")) == PROD_SCHEDULES,
      (PROD_SCHEDULES, name_set(real(".pervio", "schedules"))))
check("Z the real launchd job was not registered or rewritten (hook stayed skipped)",
      plist_stamp() == PROD_PLIST, (PROD_PLIST, plist_stamp()))
check("Z the conversation sweep never reached the real ~/.claude/projects",
      len(name_set(real(".claude", "projects")) or []) >= PROD_CONVS,
      (PROD_CONVS, len(name_set(real(".claude", "projects")) or [])))

# ---------- cleanup + leak self-check ----------
leftover = ([g for g in _pgids if alive(g)]
            + [p for p in _extra_pids if alive_pid(p)])
check("no process this suite started is still alive — runner groups and the "
      "command child C2 killed", leftover == [], leftover)
for h in _homes:
    shutil.rmtree(h, ignore_errors=True)
# NOT `[h for h in _homes if exists(h)] == []`: that asks the filesystem about the
# effect of the rmtree on the line above and can only ever confirm it — a check whose
# subject is the line before it. The honest question is the one a reader has: did this
# suite leave anything in /tmp? So ASK /TMP, not the list. A home some helper made
# without going through mkhome() is invisible to the list and visible here. Scoped by
# pid, because a second copy of run_all.sh has conv_* dirs of its own, live, right now.
residue = sorted(glob.glob("/tmp/conv_%d_*" % MYPID))
note("temp dirs made: %d; still in /tmp after cleanup: %d" % (len(_homes), len(residue)))
check("nothing this suite created is left in /tmp (asked /tmp, not our own list)",
      residue == [], residue[:5])

ok = all(results)
print("\n=== LONG-RUN CONVERGENCE: %s (%d/%d) ==="
      % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
