#!/usr/bin/env python3
"""Tests for pervio-view — the desktop reader for one archived issue.

Everything here is driven over HTTP (urllib + raw sockets). NOTHING in this suite
may open a browser, a window, a sound or a focus change — and that is enforced,
not audited: a recording FAKE `open` is planted at the head of PATH before the
first server starts, so `/usr/bin/open` is unreachable for the whole file (K3
fails if anything ever reached it). The static bans on `osascript`/`webbrowser`
stay as a second line. Every server this suite starts is killed and PROVEN gone
(ps) before the file exits.

Contracts pinned here:
  render  — h1/h2/h3, `- ` lists, `> ` quotes, `---` rules, `<details>`/
            `<summary>`, `[t](url)` links, bare-URL chips, `**b**`/`*i*`/
            `` `code` ``, and "data lines" (· separated, digits, short). Those
            are exactly the constructs the REAL archives under ~/.pervio use;
            everything else in the report is untrusted text and comes out
            escaped — a `<script>`, an `onerror=` attribute, a `javascript:`
            link, a forged `<details open onclick=...>` and an orphan
            `</details>` must all render as visible text, never as markup.
  actions — the publication's actions (match/menu/run) come from
            `pervio-orchestrate archives list`; a block whose text hits an
            action regex grows a button group, one button per menu item.
  security— one-shot token on every request (403 without), the browser sends
            only {actionIndex, captureGroups, choiceIndex} and the command is
            REBUILT server-side from the spec's run template: choice must be a
            menu member, capture groups must be groups the action actually
            matched in THIS report, execution is an argv array (never a shell
            string), any smuggled command/argv/run key in the body is ignored,
            and only "/" and "/score" exist (no path reads).
  lifecycle— idle exit really happens (ps confirms the pid is gone), a request
            resets the idle clock, the listener is 127.0.0.1-only, and a fresh
            launch kills the PREVIOUS pervio-view (and only a pervio-view — a
            pid file pointing at an innocent process must not be honoured).
  keepalive— reading is silent, so the PAGE says it is still open: a tokened GET
            /alive every idle/3 seconds, ONLY while the tab is visible. The
            page's own script is executed for real (node supplies a visibility
            state, a toast element and an origin; the fetch and the server are
            the real ones), so "a visible page outlives its idle window" and "a
            hidden one does not" are observations, not greps. The endpoint reads
            nothing, writes nothing and returns eleven bytes; without the token
            it is a 403 that does NOT move the clock; and it loses to the
            absolute ceiling, checked against a copy whose ceiling is 8 seconds.
  raising — `--open` is the path the phone actually drives, so it is EXECUTED —
            and BOTH raise points are, because there are two. The foreground one
            (`--open`) and the DETACHED one (`--detach --open`, which is the argv
            ios/Sources/Services/SSHService.swift really sends) live in different
            branches of main(); with --open the fake records exactly
            ["open","-g",url], without it the fake is never called at all, and
            each claim is asserted separately for each branch.
  mutation— token check off / menu check off / watchdog off / `-g` dropped /
            either opt-in guard removed / a focus stealer planted at the
            detached raise point / the page's ping timer deleted / the
            visibility gate opened / the idle clock moved ahead of the token
            check / the watchdog's ceiling dropped each turn the matching
            assertion RED.
Hermetic: every scenario gets its own $HOME (pid file, archives, memory.md and
the schedule spec all live inside it). The production ~/.pervio is never read.
"""
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.realpath(__file__))
BIN = os.path.realpath(os.path.join(HERE, "..", "bin"))
VIEW = os.path.join(BIN, "pervio-view")
ORCH = os.path.join(BIN, "pervio-orchestrate")
FEEDBACK = os.path.join(BIN, "pervio-feedback")

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name
          + (("  [" + str(detail)[:300] + "]") if (detail and not cond) else ""))


ROOT = tempfile.mkdtemp(prefix="view_", dir="/tmp")
TOOLS = os.path.join(ROOT, "tools")
os.makedirs(TOOLS)
# Sentinels: these files exist only if something reached a SHELL. Nothing in
# this suite may ever create them.
SENT_SHELL = os.path.join(ROOT, "SHELL_RAN")
SENT_CHOICE = os.path.join(ROOT, "CHOICE_RAN")

# --- the fake `open`, and the suite-wide net it hangs on -----------------------
# Nothing in this file may put a window on the user's screen. The rule is enforced
# at the only place that can break it: `open` itself. A recording fake is planted
# at the head of THIS PROCESS's PATH before a single server starts, so every child
# — the product, a mutant of it, anything they spawn — resolves `open` to a script
# that writes a line to a log and exits. /usr/bin/open is unreachable for the rest
# of the run. Measured 2026-08-07: one deliberately broken build raised 22 real
# browser tabs through this suite before the net existed.
FAKE_OPEN_SRC = """#!/usr/bin/env python3
import json, os, sys
# argv[0] as passed by the caller is consumed by the kernel's shebang handling,
# so we record the program NAME we were invoked as (proving it was `open`, not
# `osascript`/`open -a`) followed by the arguments verbatim.
with open(%r, "a", encoding="utf-8") as fh:
    fh.write(json.dumps([os.path.basename(sys.argv[0])] + sys.argv[1:]) + "\\n")
"""
PROBE = "--pervio-preflight-never-a-url"


def open_rows(log):
    if not os.path.exists(log):
        return []
    with open(log, encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]


def plant_fake_open(tag, path_env):
    """(dir, log) whose `open` shadows the Mac's — proven, not assumed.

    A pre-flight invocation must land in the log before the caller is allowed to
    run anything that could raise a window; if it does not, the suite dies here
    rather than on the user's screen. The probe carries no URL, so even the
    failure path cannot open anything.
    """
    d = os.path.join(ROOT, "fakeopen_" + tag)
    os.makedirs(d, exist_ok=True)
    log = os.path.join(d, "open.argv.jsonl")
    p = os.path.join(d, "open")
    with open(p, "w", encoding="utf-8") as f:
        f.write(FAKE_OPEN_SRC % log)
    os.chmod(p, 0o755)
    newpath = d + os.pathsep + path_env
    resolved = shutil.which("open", path=newpath) or ""
    subprocess.run(["open", PROBE], env=dict(os.environ, PATH=newpath),
                   capture_output=True, timeout=20)
    if os.path.realpath(resolved) != os.path.realpath(p) \
            or open_rows(log) != [["open", PROBE]]:
        shutil.rmtree(ROOT, ignore_errors=True)
        raise SystemExit("REFUSING to run: `open` resolves to %r, not the fake at "
                         "%r (log=%r)" % (resolved, p, open_rows(log)))
    with open(log, "w", encoding="utf-8"):     # drop the probe row
        pass
    return d, log


NOOPEN_DIR, NOOPEN_LOG = plant_fake_open("net", os.environ.get("PATH", ""))
os.environ["PATH"] = NOOPEN_DIR + os.pathsep + os.environ.get("PATH", "")

ARGVDUMP = os.path.join(TOOLS, "argvdump.py")
with open(ARGVDUMP, "w", encoding="utf-8") as f:
    f.write(
        "import json, os, sys\n"
        "p = os.path.join(os.environ['HOME'], 'argv.json')\n"
        "rows = json.load(open(p)) if os.path.exists(p) else []\n"
        "rows.append(sys.argv[1:])\n"
        "json.dump(rows, open(p, 'w'))\n"
        "print('argvdump ok')\n")

SLEEPER = os.path.join(TOOLS, "sleeper.py")
with open(SLEEPER, "w", encoding="utf-8") as f:
    f.write(
        "import os, sys, time\n"
        "time.sleep(float(sys.argv[2]))\n"
        "open(os.path.join(os.environ['HOME'], 'slow.done'), 'w').write('ok')\n"
        "print('slept')\n")

# --- the report fixture -------------------------------------------------------
# Top half: only constructs that appear in the REAL ~/.pervio archives.
# Bottom half: the hostile half — every one of these must come out as text.
REPORT = """# 论文晨报 · 2026-08-06 · 3 篇

> 今日一句：三篇最强文章同时盯着 GRPO rollout 这一层。

## 必读

### [不改训练目标，两个 Replay 视图把"脏信号"洗干净](https://arxiv.org/abs/2608.04788)
OCSD — Yi Yang 等 · `★4.5`

把未来真实观测附在 replay 里做 token 级监督是现有方案。**怎么用**：先跑一轮 *ALFWorld* 确认。

![方法图:Overview](https://arxiv.org/html/2608.0006v1/x1.png)

![假图](https://evil.example.com/x.png)
⚠️ 实验最大 8B，更大规模效果未验证。

> *"we identify a confounding issue"*

---

## 值得读

- [免训练 64 位哈希稀疏注意力](https://arxiv.org/abs/2608.04405) `★4.0` — BinaryPC 用秩-1 迭代求解二值主成分
- 没有链接的一条，纯文字条目

## 扫过

<details>
<summary>展开 1 篇扫过</summary>

- [Skill-Use benchmark](https://arxiv.org/abs/2608.04828) `★3.5` — 79 个真实技能 × 177 可执行任务

</details>

## 讨论热点

https://news.ycombinator.com/item?id=49173984

HtTpS://Example.COM/Mixed-Case

Show HN 讨论 · ▲67 · 20 条评论

SLOW:5 一条会跑很久的动作

## 注入区 TAG:$(touch${IFS}__SENT_SHELL__);evil'"&<>

<script>window.__pwned=1</script>
<img src=x onerror="alert(1)">
<details open onclick="alert(2)">
<summary onmouseover="alert(3)">伪装 summary</summary>
[点我](javascript:alert(4))
</details>

---
今日统计：抓取 3 篇
""".replace("__SENT_SHELL__", SENT_SHELL)

# The group the TAG action captures out of that heading — verbatim.
TAG_GROUP = "$(touch${IFS}%s);evil'\"&<>" % SENT_SHELL
OLD_REPORT = "# 昨天的旧报告\n\n只有一行。\n"

MENU_FB = ["👍", "👎", "少看", "多看"]
MENU_TAG = ["记一笔", "b;touch %s" % SENT_CHOICE]


def actions_for(home):
    """The publication's actions. Deliberately mixed: a real one (writes into
    memory.md through pervio-feedback) and two that dump their argv so the
    "argv array, never a shell string" contract can be asserted byte-for-byte."""
    return [
        {"match": r"https://arxiv\.org/abs/(\d{4}\.\d{4,5})",
         "menu": MENU_FB,
         "run": "%s %s --id {1} --verdict {choice} --file ~/.pervio/papers/memory.md"
                % (sys.executable, FEEDBACK)},
        {"match": r"TAG:(\S+)",
         "menu": MENU_TAG,
         "run": "%s %s --tag {1} --pick {choice}" % (sys.executable, ARGVDUMP)},
        {"match": r"▲(\d+)",
         "menu": ["赞"],
         "run": "%s %s --votes {1} --pick {choice}" % (sys.executable, ARGVDUMP)},
        {"match": r"SLOW:(\d)",
         "menu": ["跑"],
         "run": "%s %s --secs {1}" % (sys.executable, SLEEPER)},
    ]


MEM_BEFORE = ("# 论文记忆\n\n"
              "## 反馈(你在聊天里给的反应,近的在上;晨报据此调整,agent 只读不写这一节)\n"
              "(暂无)\n")


def make_home(tag, report=REPORT, actions=None):
    """A fresh hermetic $HOME with one publication (schedule spec + archive dir
    + two issues) and a memory.md for the feedback action to write into."""
    home = tempfile.mkdtemp(prefix="h_%s_" % tag, dir=ROOT)
    arch = os.path.join(home, ".pervio", "archives", "paper-digest")
    os.makedirs(arch)
    os.makedirs(os.path.join(home, ".pervio", "papers"))
    with open(os.path.join(home, ".pervio", "papers", "memory.md"), "w",
              encoding="utf-8") as f:
        f.write(MEM_BEFORE)
    with open(os.path.join(arch, "2026-08-05.md"), "w", encoding="utf-8") as f:
        f.write(OLD_REPORT)
    time.sleep(0.02)
    with open(os.path.join(arch, "2026-08-06.md"), "w", encoding="utf-8") as f:
        f.write(report)
    sd = os.path.join(home, ".pervio", "schedules", "aaaa1111bbbb")
    os.makedirs(sd)
    spec = {"name": "论文晨报", "dir": "~",
            "steps": [{"id": "a", "agent": "claude", "prompt": "x"}],
            "display": {"archiveDir": "~/.pervio/archives/paper-digest"},
            "actions": actions if actions is not None else actions_for(home)}
    with open(os.path.join(sd, "spec.json"), "w", encoding="utf-8") as f:
        json.dump(spec, f, ensure_ascii=False)
    return home, arch


def env_for(home, path_prefix=None, **extra):
    e = dict(os.environ)
    e["HOME"] = home
    e.pop("PERVIO_NOW", None)
    if path_prefix:
        e["PATH"] = path_prefix + os.pathsep + e.get("PATH", "")
    e.update(extra)
    return e


def memory(home):
    with open(os.path.join(home, ".pervio", "papers", "memory.md"),
              encoding="utf-8") as f:
        return f.read()


def argv_rows(home):
    p = os.path.join(home, "argv.json")
    if not os.path.exists(p):
        return []
    with open(p, encoding="utf-8") as f:
        return json.load(f)


# Every per-scenario fake `open`, as [tag, log, rows_the_scenario_asserted_on].
# A scenario's own fake sits IN FRONT of the suite-wide one, so its rows never
# reach NOOPEN_LOG — which is precisely where a late or extra window used to be
# able to hide: each scenario read its log once and nothing ever looked again.
# K3b re-reads every entry here after teardown, so these logs are inside the net.
OPEN_LOGS = []


def open_env(home, tag, **extra):
    """(env, argv_log) for ONE scenario, with its own fake `open` in front of the
    suite-wide one — so the assertions read a log that only this scenario wrote.

    Registered in OPEN_LOGS the moment it exists, expecting NOTHING: a log that
    is planted and then never sampled must still be watched, or "I forgot to
    assert on it" becomes a way to open a window unseen.
    """
    d, log = plant_fake_open(tag, os.environ.get("PATH", ""))
    OPEN_LOGS.append([tag, log, []])
    return env_for(home, path_prefix=d, **extra), log


def settle_open_rows(log, expect=0, quiet=1.2, timeout=15):
    """The fake's log, read only AFTER it has stopped growing.

    Sampling at the instant the JSON line arrives is a race that fails OPEN. The
    product prints that line and keeps living: in the foreground the server runs
    on, and with --detach the launcher exits while the SERVER survives — so there
    is always a process still able to raise a window a millisecond after the read
    said "nothing was invoked". This waits for `expect` rows AND for a quiet
    stretch with no new ones, so a late window shows up as a row rather than as a
    gap, and an EXTRA window cannot slip in behind an assertion that already
    counted one.

    The reading is also recorded as this log's expected FINAL content, which is
    what K3b re-checks once every process is dead.
    """
    t0 = time.time()
    rows = open_rows(log)
    stable = time.time()
    while time.time() - t0 < timeout:
        time.sleep(0.1)
        now = open_rows(log)
        if now != rows:
            rows, stable = now, time.time()
            continue
        if len(rows) >= expect and time.time() - stable >= quiet:
            break
    for e in OPEN_LOGS:
        if e[1] == log:
            e[2] = rows
            break
    else:
        OPEN_LOGS.append(["(unregistered)", log, rows])
    return rows


# --- process helpers ----------------------------------------------------------
STARTED = []            # every pid this suite ever launched — swept at the end
PROCS = []              # Popen handles we still own


def ps_alive(pid):
    """True iff pid is a live (non-zombie) process. os.kill(pid, 0) is not
    enough: a reaped-but-unwaited child of ours stays killable as a zombie."""
    try:
        r = subprocess.run(["ps", "-p", str(pid), "-o", "state="],
                           capture_output=True, text=True, timeout=10)
    except Exception:
        return False
    st = (r.stdout or "").strip()
    return bool(st) and not st.startswith("Z")


def ps_cmd(pid):
    try:
        r = subprocess.run(["ps", "-p", str(pid), "-o", "command="],
                           capture_output=True, text=True, timeout=10)
        return (r.stdout or "").strip()
    except Exception:
        return ""


def wait_gone(pid, timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        if not ps_alive(pid):
            return True
        time.sleep(0.15)
    return not ps_alive(pid)


def launch(home, args, detach=False, timeout=25, env=None, binpath=None):
    """Start pervio-view; return (info_dict_or_None, proc, stderr_text).

    Foreground: the process keeps running, so the JSON line is read off the pipe
    by a helper thread. --detach: the launcher itself exits once the server is
    up, so a plain communicate() gets the line.
    """
    cmd = [sys.executable, binpath or VIEW] + list(args) + (["--detach"] if detach else [])
    p = subprocess.Popen(cmd, env=env or env_for(home), stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True)
    PROCS.append(p)
    if detach:
        try:
            out, err = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            return None, p, "launcher did not exit"
    else:
        box = {}

        def rd():
            box["out"] = p.stdout.readline()
        t = threading.Thread(target=rd, daemon=True)
        t.start()
        t.join(timeout)
        out, err = box.get("out", ""), ""
        if not out and p.poll() is not None:
            err = p.stderr.read()
    info = None
    try:
        info = json.loads((out or "").strip().splitlines()[0])
    except Exception:
        pass
    if isinstance(info, dict) and isinstance(info.get("pid"), int):
        STARTED.append(info["pid"])
    STARTED.append(p.pid)
    return info, p, err or ""


def reap(pid, proc=None):
    """Kill one server for good and confirm it. Used by teardown AND by every
    scenario that finishes with a live server — X2: nothing is left behind."""
    if pid:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            if not ps_alive(pid):
                break
            try:
                os.kill(pid, sig)
            except OSError:
                break
            wait_gone(pid, 3)
    if proc is not None:
        try:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=5)
        except Exception:
            pass


# --- http helpers -------------------------------------------------------------
def http(url, data=None, headers=None, timeout=30):
    req = urllib.request.Request(url, data=data, headers=headers or {},
                                 method="POST" if data is not None else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace"), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), dict(e.headers)
    except Exception as e:
        return 0, "TRANSPORT: %s" % e, {}


def post_json(base, token, obj, timeout=40):
    body = json.dumps(obj).encode("utf-8")
    return http("%s/score?t=%s" % (base, token), data=body,
                headers={"Content-Type": "application/json"}, timeout=timeout)


def raw_request(port, line, host="127.0.0.1", timeout=10):
    """A literal request line — urllib would normalise '/../' away before it
    ever hit the server, which is exactly the thing under test."""
    s = socket.create_connection((host, port), timeout=timeout)
    try:
        s.sendall((line + "\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
                  .encode("utf-8"))
        buf = b""
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    except Exception:
        pass
    finally:
        s.close()
    return buf.decode("utf-8", "replace")


def base_of(info):
    u = info["url"]
    return u.split("?")[0].rstrip("/") or u


def token_of(info):
    m = re.search(r"[?&]t=([^&]+)", info["url"])
    return m.group(1) if m else ""


def local_ipv4s():
    """Every non-loopback IPv4 this host answers to. Read off the interfaces —
    no packet is sent anywhere."""
    out = []
    for cmd in (["ifconfig", "-a"], ["ip", "-4", "addr"]):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        except Exception:
            continue
        out = re.findall(r"\binet (?:addr:)?(\d+\.\d+\.\d+\.\d+)", r.stdout or "")
        if out:
            break
    return [ip for ip in dict.fromkeys(out) if not ip.startswith("127.")]


def listen_addrs(pid, port):
    """What the OS says this pid is listening on — the direct observation of the
    bind, immune to whatever a VPN/proxy on the box does to connect()."""
    for cmd in (["lsof", "-nP", "-a", "-p", str(pid), "-iTCP", "-sTCP:LISTEN"],
                ["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid),
                 "-iTCP", "-sTCP:LISTEN"]):
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        except Exception:
            continue
        hits = re.findall(r"(\S+):%d \(LISTEN\)" % port, r.stdout or "")
        if hits:
            return hits
    return []


def mutant(target, replacement, tag, also=()):
    """A copy of pervio-view with one line disabled, plus a sibling symlink to
    the real pervio-orchestrate so the copy still resolves the publication.

    `also` carries extra (target, replacement) pairs that are not the mutation
    under test but are needed for the mutation to be REACHABLE at all — see
    UNGATE. Every target, the mutation's included, must appear exactly once or
    `ok` is False and the scenario's J-check goes red instead of quietly testing
    an unmodified copy.
    """
    src = open(VIEW, encoding="utf-8").read()
    ok = True
    out = src
    for t, r in [(target, replacement)] + list(also):
        ok = ok and out.count(t) == 1
        out = out.replace(t, r)
    d = tempfile.mkdtemp(prefix="mut_%s_" % tag, dir=ROOT)
    path = os.path.join(d, "pervio-view")
    with open(path, "w", encoding="utf-8") as f:
        f.write(out)
    os.chmod(path, 0o700)
    try:
        os.symlink(ORCH, os.path.join(d, "pervio-orchestrate"))
    except OSError:
        pass
    return path, ok and out != src


def launch_bin(binpath, home, args, timeout=25):
    cmd = [sys.executable, binpath] + list(args)
    p = subprocess.Popen(cmd, env=env_for(home), stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True)
    PROCS.append(p)
    box = {}

    def rd():
        box["out"] = p.stdout.readline()
    t = threading.Thread(target=rd, daemon=True)
    t.start()
    t.join(timeout)
    info = None
    try:
        info = json.loads((box.get("out") or "").strip().splitlines()[0])
    except Exception:
        pass
    if isinstance(info, dict) and isinstance(info.get("pid"), int):
        STARTED.append(info["pid"])
    STARTED.append(p.pid)
    return info, p


# =============================================================================
print("=== A: launch contract — one JSON line, loopback only, no window ===")
homeA, archA = make_home("A")
infoA, procA, errA = launch(homeA, ["--dir", archA, "--file", "2026-08-06.md",
                                    "--idle", "300"])
check("A1 startup prints one parseable JSON line",
      isinstance(infoA, dict), (infoA, errA[:300]))
if not isinstance(infoA, dict):
    print("!! no server — the rest of the suite cannot run")
    reap(None, procA)
    shutil.rmtree(ROOT, ignore_errors=True)
    print("\n=== pervio-view: FAILURES ❌ (%d/%d) ===" % (sum(results), len(results)))
    sys.exit(1)

check("A2 the JSON line carries url + pid + expiresIn",
      set(infoA) >= {"url", "pid", "expiresIn"}
      and isinstance(infoA["pid"], int) and isinstance(infoA["expiresIn"], int),
      infoA)
check("A3 the url is loopback-only and carries the token",
      infoA["url"].startswith("http://127.0.0.1:") and "?t=" in infoA["url"], infoA)
check("A4 expiresIn is the requested idle window", infoA["expiresIn"] == 300, infoA)
check("A5 the pid is the live server", ps_alive(infoA["pid"])
      and "pervio-view" in ps_cmd(infoA["pid"]), ps_cmd(infoA["pid"]))

BASE = base_of(infoA)
TOK = token_of(infoA)
PORT = int(re.search(r":(\d+)", BASE).group(1))

st, page, hdrs = http(infoA["url"])
check("A6 the tokened url serves the report", st == 200 and "论文晨报" in page,
      (st, page[:200]))
# 2026-08-27 起「自包含」有一个白名单例外:方法图。<img> 只许指向自身的
# /fig 路由或 arxiv 直连兜底,其余任何外链 src 仍然违约。
_ext_srcs = [m for m in re.findall(r'src="([^"]+)"', page)
             if m.startswith("http") and not m.startswith("https://arxiv.org/")]
check("A7 the page is self-contained HTML (styles inline; only whitelisted figure srcs)",
      "<style" in page and "http://" not in page.split("</head>")[0]
      and not _ext_srcs and "link rel=\"stylesheet\"" not in page,
      _ext_srcs[:3] or page[:200])
check("A8 security headers: CSP nonce + nosniff",
      "nonce-" in (hdrs.get("Content-Security-Policy") or "")
      and (hdrs.get("X-Content-Type-Options") or "") == "nosniff", hdrs)
# The token rides in the query string, so a click on any arxiv/HN link would
# hand it to that site in the Referer unless referrers are off three ways over.
anchors = re.findall(r"<a\s[^>]*>", page)
# 方法图(2026-08-27):整行 arxiv 图片渲染成 <img>;本地缓存命中走 /fig 路由
# (秒开),缺席回退 arxiv 直连;非 arxiv 域名保持可见文字,绝不成为标签。
figA = os.path.join(homeA, ".pervio", "papers", "figures")
os.makedirs(figA, exist_ok=True)
with open(os.path.join(figA, "2608.0006.png"), "wb") as f:
    f.write(b"\x89PNG\r\n\x1a\n" + b"0" * 64)
st_f, page_f, _ = http(infoA["url"])   # 重新渲染?页面在启动时定稿——直接验当前页
check("V-img1 合法图片行渲染为 <img>(figure.mfig)",
      '<figure class="mfig">' in page and "<img" in page, page[:0] or "no figure")
check("V-img2 非 arxiv 图片行绝不成为 <img>(按 prose 处理,URL 至多是普通链接)",
      "evil.example.com" in page
      and not re.search(r'<img[^>]*evil\.example\.com', page),
      [m for m in re.findall(r"<img[^>]*>", page) if "evil" in m])
check("V-img3 CSP 放行了自身与 arxiv 的图片",
      "img-src 'self' https://arxiv.org" in (hdrs.get("Content-Security-Policy") or ""),
      hdrs.get("Content-Security-Policy"))
st_fig, body_fig, hdr_fig = http(BASE + "/fig/2608.0006?t=" + TOK, binary=True) \
    if "binary" in http.__code__.co_varnames else (None, None, None)
if st_fig is None:
    import urllib.request as _ur
    req = _ur.Request(BASE + "/fig/2608.0006?t=" + TOK)
    with _ur.urlopen(req, timeout=10) as r:
        st_fig = r.status
        body_fig = r.read()
        hdr_fig = dict(r.headers)
check("V-img4 /fig 路由端出本地缓存的图(PNG 字节 + content-type)",
      st_fig == 200 and body_fig.startswith(b"\x89PNG")
      and (hdr_fig.get("Content-Type") or "").startswith("image/png"),
      (st_fig, (hdr_fig or {}).get("Content-Type")))
import urllib.error as _ue
try:
    _ur.urlopen(BASE + "/fig/../../etc/passwd?t=" + TOK, timeout=10)
    trav = "opened"
except _ue.HTTPError as e:
    trav = e.code
except Exception as e:
    trav = type(e).__name__
check("V-img5 /fig 拒绝路径穿越与坏编号", trav == 404, trav)

check("A8b the token cannot leak in a Referer (header + meta + every rel)",
      (hdrs.get("Referrer-Policy") or "") == "no-referrer"
      and '<meta name="referrer" content="no-referrer">' in page
      and anchors and all("noreferrer" in a for a in anchors),
      [a for a in anchors if "noreferrer" not in a][:3])

addrs = listen_addrs(infoA["pid"], PORT)
check("A9 the OS reports the socket bound to 127.0.0.1 and nothing else",
      addrs == ["127.0.0.1"], addrs)
# ...and no non-loopback address on this host can actually reach the report. A
# connect() may still SUCCEED here — a VPN/proxy can intercept a whole range —
# so the assertion is on who answers, not on whether the socket opened.
served = []
for ip in local_ipv4s():
    try:
        s = socket.create_connection((ip, PORT), timeout=3)
    except Exception:
        continue
    try:
        s.sendall(("GET /?t=%s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"
                   % (TOK, ip)).encode())
        s.settimeout(3)
        buf = b""
        while len(buf) < 4096:
            c = s.recv(4096)
            if not c:
                break
            buf += c
    except Exception:
        buf = b""
    finally:
        s.close()
    if "论文晨报".encode() in buf:
        served.append(ip)
check("A9b no non-loopback address on this host serves the report",
      not served, served)

src_view = open(VIEW, encoding="utf-8").read()
# Raising the page IS the feature (one tap on the phone, the report appears on
# the Mac) — verified 2026-08-07 through a real non-interactive ssh channel. What
# the incident actually taught us is narrower and still enforced here: it must be
# OPT-IN (--open), it must not steal focus (`open -g`), and no other way of
# grabbing the screen or making noise is allowed.
banned = [t for t in ("webbrowser", "osascript", "NSWorkspace", "afplay",
                      '"say"', "open -a")
          if t in src_view]
check("A10 pervio-view raises nothing except via the opt-in background open",
      not banned, banned)
check("A10b the only opener is `open -g` (background, never steals focus)",
      '"open", "-g"' in src_view or "'open', '-g'" in src_view,
      [l for l in src_view.splitlines() if '"open"' in l][:2])
# Opt-in, structurally: every call site must sit inside an `if o["open"]:`
# block. Walking the lines backwards to the nearest line at a shallower indent
# is what "inside that if" means, and it does not care how many comment lines
# the author put in between.
_vlines = src_view.splitlines()
_calls = [i for i, l in enumerate(_vlines) if "_raise_on_desktop(line[" in l]
_guarded = []
for i in _calls:
    ind = len(_vlines[i]) - len(_vlines[i].lstrip())
    j, found = i - 1, False
    while j >= 0:
        l = _vlines[j]
        if l.strip() and (len(l) - len(l.lstrip())) < ind:
            found = l.strip() == 'if o["open"]:'
            break
        j -= 1
    _guarded.append(found)
check("A10c opening is opt-in: every call sits inside `if o[\"open\"]`",
      len(_calls) == 2 and all(_guarded), (len(_calls), _guarded))

# --- and now the same claims BEHAVIOURALLY, through the fake `open` ------------
# The three checks above are grep. Grep cannot see a new `subprocess.run(["open",
# url])` added somewhere else, and — worse — the shipped default path (iOS passes
# --open) had never executed once in this suite. These run it for real, in BOTH
# branches: foreground (A10d–A10h) and detached (A10i–A10m).
IS_MAC = sys.platform == "darwin"
# Off a Mac, `_raise_on_desktop` returns at its platform gate and never reaches
# `open` — so a mutant of WHAT it hands to `open` writes the same empty log as the
# unmodified product, and the J19b/J20b/J22b reading `rows == []` passed whether
# the mutation was there or not: an always-true assertion wearing the words "goes
# RED" (audited 2026-08-08). The mutants that live below the gate therefore lift
# it in the same scratch copy when this is not a Mac, so the raise path really
# runs and each J-check is the identical assertion macOS makes. What the SHIPPED
# gate does off a Mac is not lost with it: A10d/e/f and A10i/j/k above assert that
# on the real product, unmutated — nothing invoked, opened=false, "not macOS".
# Nothing can escape either: the fake `open` is still the only `open` on PATH,
# this is a copy under ROOT and never the product, and on a Mac the pair is empty
# — the copies are byte-for-byte what they were.
DESKTOP_GATE = ('    if sys.platform != "darwin":\n'
                '        return False, "not macOS"\n')
UNGATE = () if IS_MAC else (
    (DESKTOP_GATE,
     '    if False:  # UNGATED (not a Mac): execute the raise path under test\n'
     '        return False, "not macOS"\n'),)
homeOP, archOP = make_home("OP")
envOP, logOP = open_env(homeOP, "on")
infoOP, procOP, errOP = launch(homeOP, ["--dir", archOP, "--latest", "--idle", "60",
                                        "--open"], env=envOP)
rowsOP = settle_open_rows(logOP, expect=1 if IS_MAC else 0)
if IS_MAC:
    check("A10d --open really invokes `open` exactly once",
          len(rowsOP) == 1, rowsOP)
    check("A10e ...with argv exactly ['open', '-g', <the tokened loopback url>] "
          "— background (-g), no -a, no extra target",
          isinstance(infoOP, dict) and rowsOP == [["open", "-g", infoOP["url"]]],
          (rowsOP, (infoOP or {}).get("url")))
    check("A10f the JSON line reports the raise succeeded",
          isinstance(infoOP, dict) and infoOP.get("opened") is True
          and "openError" not in infoOP, infoOP)
else:
    # Not a Mac: the product refuses to raise anything and says why. Still an
    # assertion on observed behaviour, never a free pass.
    check("A10d/e off macOS: nothing is invoked", rowsOP == [], rowsOP)
    check("A10f off macOS: the JSON line reports opened=false, 'not macOS'",
          isinstance(infoOP, dict) and infoOP.get("opened") is False
          and infoOP.get("openError") == "not macOS", infoOP)
reap((infoOP or {}).get("pid"), procOP)

homeNO, archNO = make_home("NO")
envNO, logNO = open_env(homeNO, "off")
infoNO, procNO, errNO = launch(homeNO, ["--dir", archNO, "--latest", "--idle", "60"],
                               env=envNO)
rowsNO = settle_open_rows(logNO, expect=0)
check("A10g WITHOUT --open the fake `open` is never called at all",
      rowsNO == [], rowsNO)
check("A10h ...and the JSON line carries no opened/openError key",
      isinstance(infoNO, dict) and "opened" not in infoNO
      and "openError" not in infoNO, infoNO)
reap((infoNO or {}).get("pid"), procNO)

# --- the DETACHED raise point: the one the phone actually reaches --------------
# A10d–A10h above drive the FOREGROUND branch. The phone does not use it: SSHService
# sends `--detach --open` (ios/Sources/Services/SSHService.swift), and --detach
# raises from a completely different place in main() — the parent, after the child
# has signalled the listener is up. That line had never been executed by any test,
# and it showed: a focus-stealing `subprocess.run(["open", url])` planted there
# passed this suite 154/154. J21/J22 keep these four honest.
homeDO, archDO = make_home("DO")
envDO, logDO = open_env(homeDO, "det_on")
infoDO, procDO, errDO = launch(homeDO, ["--dir", archDO, "--latest", "--idle", "60",
                                        "--open"], detach=True, env=envDO)
rowsDO = settle_open_rows(logDO, expect=1 if IS_MAC else 0)
if IS_MAC:
    check("A10i --detach --open (the argv the phone really sends) invokes `open` "
          "exactly once — not zero, not twice", len(rowsDO) == 1, rowsDO)
    check("A10j ...with argv exactly ['open', '-g', <the tokened loopback url>] "
          "— background (-g), no -a, no extra target",
          isinstance(infoDO, dict) and rowsDO == [["open", "-g", infoDO["url"]]],
          (rowsDO, (infoDO or {}).get("url")))
    check("A10k the detached JSON line reports the raise succeeded, and its pid is "
          "the SURVIVING server (the launcher is gone)",
          isinstance(infoDO, dict) and infoDO.get("opened") is True
          and "openError" not in infoDO and ps_alive(infoDO["pid"])
          and procDO.poll() is not None, (infoDO, procDO.poll()))
else:
    check("A10i/j off macOS: --detach --open invokes nothing", rowsDO == [], rowsDO)
    check("A10k off macOS: the detached JSON line reports opened=false, 'not macOS'",
          isinstance(infoDO, dict) and infoDO.get("opened") is False
          and infoDO.get("openError") == "not macOS", infoDO)
reap((infoDO or {}).get("pid"), procDO)

homeDN, archDN = make_home("DN")
envDN, logDN = open_env(homeDN, "det_off")
infoDN, procDN, errDN = launch(homeDN, ["--dir", archDN, "--latest", "--idle", "60"],
                               detach=True, env=envDN)
rowsDN = settle_open_rows(logDN, expect=0)
check("A10l --detach WITHOUT --open never invokes `open` — and the log is read "
      "after the launcher has exited, so a window raised LATE still counts",
      rowsDN == [], rowsDN)
check("A10m ...and the detached JSON line carries no opened/openError key",
      isinstance(infoDN, dict) and "opened" not in infoDN
      and "openError" not in infoDN, infoDN)
reap((infoDN or {}).get("pid"), procDN)

# A11 is an in-repo test: server/tests and ios/ ship in the same checkout, so a
# missing ArchiveReaderView.swift means the path moved (or the assertion was
# silently retired), not that "there is no ios here". It used to record a PASS
# for that — a green that meant nothing.
READER = os.path.realpath(os.path.join(HERE, "..", "..", "ios", "Sources",
                                       "Views", "ArchiveReaderView.swift"))
check("A11 pre: ArchiveReaderView.swift is where this suite expects it",
      os.path.exists(READER), READER)
swift = open(READER, encoding="utf-8").read() if os.path.exists(READER) else ""
# A launch is `openURL(…)` CALLED, `UIApplication.shared.open`, or Safari. An
# `.environment(\.openURL, OpenURLAction { … })` is the opposite — an
# interceptor that routes pervio-file links to the on-phone preview and hands
# everything else back to the system (2026-10-12) — so it is not a launch.
launches = [t for t in ("UIApplication.shared.open", "SFSafariViewController") if t in swift]
if re.search(r"openURL\s*\(", swift):
    launches.append("openURL(")
check("A11 the phone shows the address, it never launches it "
      "(no UIApplication.open / openURL( call / Safari)",
      bool(swift) and not launches, launches or "file not read")

# =============================================================================
print("=== B: rendering — only the constructs the real archives use ===")
check("B1 h1 title", re.search(r"<h1[^>]*>[^<]*论文晨报", page) is not None)
check("B2 h2 sections become cards",
      page.count('class="card"') >= 4 and re.search(r"<h2[^>]*>\s*必读", page)
      is not None, page.count('class="card"'))
check("B3 h3 item heading", re.search(r"<h3[^>]*>", page) is not None)
check("B4 markdown link renders as an anchor to the arxiv abs page",
      '<a href="https://arxiv.org/abs/2608.04788"' in page)
check("B5 bullet list items",
      "<ul>" in page and page.count("<li>") >= 3, page.count("<li>"))
check("B6 blockquote", "<blockquote>" in page and "confounding issue" in page)
check("B7 `code` spans (the ★ ratings)",
      "<code>★4.5</code>" in page, re.findall(r"<code>[^<]*</code>", page)[:5])
check("B8 **bold** and *italic*",
      "<strong>怎么用</strong>" in page and "<em>ALFWorld</em>" in page)
check("B9 <details>/<summary> survives as real disclosure markup",
      "<details" in page and "<summary" in page
      and "展开 1 篇扫过" in page)
check("B10 every <details> is closed",
      page.count("<details") == page.count("</details>"),
      (page.count("<details"), page.count("</details>")))
check("B11 a whole-line bare URL becomes a link chip",
      re.search(r'class="chip"[^>]*href="https://news\.ycombinator\.com/item\?id=49173984"',
                page) is not None
      or re.search(r'href="https://news\.ycombinator\.com/item\?id=49173984"[^>]*class="chip"',
                   page) is not None,
      re.findall(r"<a[^>]*ycombinator[^>]*>", page)[:3])
check("B12 a data line renders small, not as prose",
      re.search(r'class="data"[^>]*>[^<]*▲67', page) is not None,
      re.findall(r'<div class="data">.{0,40}', page)[:3])
check("B13 the `---` rules survive as separators", "<hr" in page)
check("B14 the OTHER issue in the same dir is not served",
      "昨天的旧报告" not in page)

# =============================================================================
print("=== C: the report is untrusted input — everything else is escaped ===")
check("C1 a <script> in the report is text, not a script tag",
      "window.__pwned" in page and "<script>window.__pwned" not in page
      and "&lt;script&gt;" in page)
check("C2 the only executable script is ours (nonce-tagged)",
      len(re.findall(r"<script(?![^>]*nonce=)", page)) == 0,
      re.findall(r"<script[^>]*>", page))
_imgs = re.findall(r"<img[^>]*>", page)
check("C3 an onerror= img is escaped (only whitelisted figure <img> exist, none scriptable)",
      all("onerror" not in t_ and ('src="/fig/' in t_ or 'src="https://arxiv.org/' in t_)
          for t_ in _imgs),
      _imgs[:3])
# The strings "onclick=" / "onerror=" DO survive as visible characters — that is
# the point. What must not exist is a TAG carrying one as an attribute.
inline_handlers = re.findall(r"<[a-zA-Z][^>]*\son[a-z]+\s*=", page)
check("C4 no rendered tag carries an on*= handler attribute",
      not inline_handlers, inline_handlers[:3])
check("C4b the forged <details open onclick=...> is visible text",
      "&lt;details open onclick=" in page)
check("C5 an orphan </details> is text, not a stray close tag",
      "&lt;/details&gt;" in page)
check("C6 a javascript: link is not linkified",
      'href="javascript:' not in page and "javascript:alert(4)" in page)
# The contract is _safe_url's: the SCHEME is compared case-insensitively, so
# `HtTpS://…` is a legitimately accepted href and the assertion must read the
# scheme the same way the product does (a lowercase-only test false-reds on any
# report that mixes case).
check("C6b no href leaves the http(s) scheme (scheme is case-insensitive)",
      all(h.lower().startswith(("http://", "https://"))
          for h in re.findall(r'href="([^"]*)"', page)),
      [h for h in re.findall(r'href="([^"]*)"', page)
       if not h.lower().startswith(("http://", "https://"))])
check("C6c ...and a mixed-case URL really is served as a link",
      'href="HtTpS://Example.COM/Mixed-Case"' in page,
      re.findall(r'href="[^"]*Mixed-Case[^"]*"', page))
check("C7 raw < > & from the report survive as entities in the heading",
      "&amp;&lt;&gt;" in page, page[page.find("注入区"):][:200] if "注入区" in page else "")

# =============================================================================
print("=== D: action button groups ===")
groups = re.findall(r'data-action="(\d+)" data-groups="([^"]*)"', page)
check("D1 the arxiv action produced button groups",
      any(g[0] == "0" for g in groups), groups[:4])
check("D2 one button per menu item, labels verbatim",
      all(('data-choice="%d">%s</button>' % (i, m)) in page
          for i, m in enumerate(MENU_FB)), MENU_FB)
check("D3 the TAG action matched the hostile heading and escaped its group",
      any(g[0] == "1" for g in groups) and "$(touch" in page
      and "<script" not in page.split("data-groups")[0][-200:],
      [g for g in groups if g[0] == "1"][:2])
check("D4 button carries only an index, never a command",
      re.search(r'<button[^>]*class="act"[^>]*data-choice="\d+"', page) is not None
      and "pervio-feedback" not in page and sys.executable not in page,
      re.findall(r"<button[^>]*>", page)[:3])
check("D5 the run template never reaches the browser",
      "--verdict" not in page and "argvdump" not in page)

# =============================================================================
print("=== E: token ===")
st, body, _ = http("%s/" % BASE)
check("E1 no token -> 403", st == 403, (st, body[:120]))
st, body, _ = http("%s/?t=%s" % (BASE, "x" * 40))
check("E2 wrong token -> 403", st == 403, (st, body[:120]))
st, body, _ = post_json(BASE, "x" * 40, {"actionIndex": 0, "captureGroups": ["2608.04788"],
                                         "choiceIndex": 0})
check("E3 POST /score with a wrong token -> 403", st == 403, (st, body[:120]))
check("E4 ...and it did not run", "(暂无)" in memory(homeA))
txt = raw_request(PORT, "POST /score HTTP/1.1")
check("E5 POST /score with no token at all -> 403", " 403 " in txt.split("\r\n")[0],
      txt.split("\r\n")[0])

# =============================================================================
print("=== F: scoring — the command is rebuilt server-side ===")
st, body, _ = post_json(BASE, TOK, {"actionIndex": 0,
                                    "captureGroups": ["2608.04788"],
                                    "choiceIndex": 0})
j = {}
try:
    j = json.loads(body)
except Exception:
    pass
mem = memory(homeA)
check("F1 a legal score returns ok", st == 200 and j.get("ok") is True, (st, body[:200]))
check("F2 ...and really landed in memory.md",
      "| 👍 | arXiv:2608.04788 |" in mem, mem[:400])
check("F3 ...and cleared the placeholder", "(暂无)" not in mem, mem[:400])

st, body, _ = post_json(BASE, TOK, {"actionIndex": 0,
                                    "captureGroups": ["2608.04788"],
                                    "choiceIndex": 99})
check("F4 choiceIndex outside the menu -> 400", st == 400, (st, body[:160]))
check("F5 ...and nothing new was written", memory(homeA) == mem)

st, body, _ = post_json(BASE, TOK, {"actionIndex": 0,
                                    "captureGroups": ["2608.04788"],
                                    "choiceIndex": -1})
check("F6 a negative choiceIndex -> 400", st == 400, (st, body[:160]))

st, body, _ = post_json(BASE, TOK, {"actionIndex": 0,
                                    "captureGroups": ["9999.99999"],
                                    "choiceIndex": 0})
check("F7 capture groups the action never matched in THIS report -> 400",
      st == 400, (st, body[:160]))
check("F8 ...and nothing was written", memory(homeA) == mem)

st, body, _ = post_json(BASE, TOK, {"actionIndex": 0,
                                    "captureGroups": ["; rm -rf ~"],
                                    "choiceIndex": 0})
check("F9 capture groups that don't even fit the regex -> 400", st == 400,
      (st, body[:160]))

st, body, _ = post_json(BASE, TOK, {"actionIndex": 0,
                                    "captureGroups": ["2608.04788", "extra"],
                                    "choiceIndex": 0})
check("F10 the wrong NUMBER of capture groups -> 400", st == 400, (st, body[:160]))

st, body, _ = post_json(BASE, TOK, {"actionIndex": 77,
                                    "captureGroups": ["2608.04788"],
                                    "choiceIndex": 0})
check("F11 actionIndex out of range -> 400", st == 400, (st, body[:160]))

st, body, _ = post_json(BASE, TOK, {"actionIndex": 0,
                                    "captureGroups": ["2608.04788"],
                                    "choiceIndex": 1,
                                    "command": "rm -rf /tmp/nope",
                                    "run": "touch " + SENT_SHELL,
                                    "argv": ["touch", SENT_SHELL]})
check("F12 a body smuggling command/run/argv still runs the SPEC's command",
      st == 200 and "| 👎 | arXiv:2608.04788 |" in memory(homeA), (st, body[:200]))
check("F13 ...and the smuggled command did not run", not os.path.exists(SENT_SHELL))

st, body, _ = http("%s/score?t=%s" % (BASE, TOK), data=b"not json",
                   headers={"Content-Type": "application/json"})
check("F14 a non-JSON body -> 400", st == 400, (st, body[:160]))
st, body, _ = post_json(BASE, TOK, {"actionIndex": "0", "captureGroups": "x",
                                    "choiceIndex": None})
check("F15 wrong-typed fields -> 400", st == 400, (st, body[:160]))
st, body, _ = http("%s/score?t=%s" % (BASE, TOK), data=b"{" + b"x" * 300000,
                   headers={"Content-Type": "application/json"})
# 413 SPECIFICALLY: with the MAX_BODY guard gone the server happily buffers the
# whole thing and then answers 400 for the malformed JSON, so accepting 400 here
# would pin nothing (see J15/J16).
check("F16 an oversized body is refused BEFORE it is buffered (413, not 400)",
      st == 413, st)

# the hostile capture group: it must arrive at the child as ONE literal argv
st, body, _ = post_json(BASE, TOK, {"actionIndex": 1,
                                    "captureGroups": [TAG_GROUP],
                                    "choiceIndex": 1})
rows = argv_rows(homeA)
check("F17 the shell-metacharacter capture group is accepted (it IS in the report)",
      st == 200, (st, body[:200]))
check("F18 ...and reached the child as one literal argv element",
      rows and rows[-1] == ["--tag", TAG_GROUP, "--pick", MENU_TAG[1]], rows[-1:])
check("F19 ...with no shell anywhere: neither sentinel exists",
      not os.path.exists(SENT_SHELL) and not os.path.exists(SENT_CHOICE))

# A capture group becomes an ARGV ELEMENT of whatever the run template names, so
# a group that starts with '-' can be read by that program as a FLAG. There is no
# `--` escape available: pervio-feedback (the real target of the paper-digest
# action) dies on a bare `--` — its parse_args only accepts `--<known-key> value`
# pairs — so the reader refuses the shape instead: no buttons, and /score says no.
FLAGGY = """# 旗子报告

FLAG:ok-value 一条正常的

FLAG:--file=/etc/passwd 一条看起来像参数的
"""
homeFL, archFL = make_home(
    "FL", report=FLAGGY,
    actions=[{"match": r"FLAG:(\S+)", "menu": ["记一笔"],
              "run": "%s %s --tag {1}" % (sys.executable, ARGVDUMP)}])
infoFL, procFL, errFL = launch(homeFL, ["--dir", archFL, "--latest", "--idle", "30"])
if isinstance(infoFL, dict):
    _, pageFL, _ = http(infoFL["url"])
    gFL = re.findall(r'data-groups="([^"]*)"', pageFL)
    check("F20 an ordinary capture group still gets its button group",
          any("ok-value" in g for g in gFL), gFL)
    check("F21 a capture group starting with '-' gets NO button group",
          not any("--file" in g for g in gFL), gFL)
    stFL, bodyFL, _ = post_json(base_of(infoFL), token_of(infoFL),
                                {"actionIndex": 0,
                                 "captureGroups": ["--file=/etc/passwd"],
                                 "choiceIndex": 0})
    check("F22 ...and /score refuses it rather than handing it over as argv",
          stFL == 400, (stFL, bodyFL[:200]))
    check("F23 ...so the child never ran at all", not argv_rows(homeFL),
          argv_rows(homeFL)[:2])
    reap(infoFL["pid"], procFL)
else:
    check("F20 flag-shaped-group server started", False, errFL[:200])
    reap(None, procFL)

# =============================================================================
print("=== G: only this report is served — no path reads ===")
for path in ("/etc/passwd", "/../../../../etc/passwd", "/2026-08-05.md",
             "/score/../../etc/passwd", "/..%2f..%2fetc/passwd",
             "/./../.pervio/papers/memory.md"):
    txt = raw_request(PORT, "GET %s?t=%s HTTP/1.1" % (path, TOK))
    first = txt.split("\r\n")[0] if txt else ""
    check("G %s -> 404/403" % path,
          (" 404 " in first or " 403 " in first) and "root:" not in txt
          and "论文记忆" not in txt, first)
st, body, _ = http("%s/report.md?t=%s" % (BASE, TOK))
check("G7 /report.md -> 404", st == 404, st)

# scenario A is done — kill it and prove it
reap(infoA["pid"], procA)
check("G8 scenario A's server is gone after SIGTERM", not ps_alive(infoA["pid"]))

# =============================================================================
print("=== H: lifecycle — self-owned watchdog, detached and not ===")
homeH, archH = make_home("H")
infoH, procH, errH = launch(homeH, ["--dir", archH, "--latest", "--idle", "4"],
                            detach=True)
check("H1 --detach returns immediately with the JSON line",
      isinstance(infoH, dict) and procH.poll() == 0, (infoH, errH[:200]))
if isinstance(infoH, dict):
    check("H2 the detached server is alive and is a pervio-view",
          ps_alive(infoH["pid"]) and "pervio-view" in ps_cmd(infoH["pid"]),
          ps_cmd(infoH["pid"]))
    check("H3 --latest picked the newest issue",
          "论文晨报" in http(infoH["url"])[1])
    check("H4 the detached server outlived its launcher (parent is gone)",
          procH.poll() == 0 and ps_alive(infoH["pid"]))
    # a request at t≈1.5s must RESET the idle clock
    time.sleep(1.5)
    http(infoH["url"])
    time.sleep(3.0)          # t≈4.5s: dead already if the poke didn't reset
    check("H5 a request resets the idle clock", ps_alive(infoH["pid"]))
    check("H6 the orphan kills ITSELF when idle (no parent, no caller)",
          wait_gone(infoH["pid"], 12))
    reap(infoH["pid"], procH)

homeI, archI = make_home("I")
infoI1, procI1, _ = launch(homeI, ["--dir", archI, "--latest", "--idle", "300"],
                           detach=True)
check("H7 first instance up", isinstance(infoI1, dict) and ps_alive(infoI1["pid"]))
infoI2, procI2, _ = launch(homeI, ["--dir", archI, "--latest", "--idle", "300"],
                           detach=True)
check("H8 second instance up on a different port",
      isinstance(infoI2, dict) and ps_alive(infoI2["pid"])
      and infoI2.get("url") != (infoI1 or {}).get("url"), (infoI1, infoI2))
if isinstance(infoI1, dict):
    check("H9 launching again killed the previous instance",
          wait_gone(infoI1["pid"], 10), ps_cmd(infoI1["pid"]))
if isinstance(infoI2, dict):
    check("H10 ...and the new one still answers", http(infoI2["url"])[0] == 200)
    reap(infoI2["pid"], procI2)
reap((infoI1 or {}).get("pid"), procI1)

# "only kill your own": a pid file pointing at an innocent process
homeJ, archJ = make_home("J")
victim = subprocess.Popen(["sleep", "45"])
PROCS.append(victim)
STARTED.append(victim.pid)
pidfile = os.path.join(homeJ, ".pervio", "view.json")
os.makedirs(os.path.dirname(pidfile), exist_ok=True)
with open(pidfile, "w", encoding="utf-8") as f:
    json.dump({"pid": victim.pid, "port": 1, "started": time.time()}, f)
infoJ, procJ, _ = launch(homeJ, ["--dir", archJ, "--latest", "--idle", "60"])
time.sleep(0.6)
check("H11 a pid file naming a NON-pervio-view process does not kill it",
      ps_alive(victim.pid) and victim.poll() is None, victim.poll())
check("H12 ...and the new instance still started",
      isinstance(infoJ, dict) and ps_alive(infoJ["pid"]))
victim.kill()
victim.wait(timeout=5)
check("H13 the innocent process is cleaned up by the TEST", not ps_alive(victim.pid))

# "only a pervio-view" has to mean the process NAME, not a substring of its
# command line: pids get recycled, and the recycler may well be an editor, a
# grep or another agent that merely MENTIONS pervio-view in its argv.
IDLER = os.path.join(TOOLS, "idler.py")
with open(IDLER, "w", encoding="utf-8") as f:
    f.write("import time\ntime.sleep(45)\n")
decoy = subprocess.Popen([sys.executable, IDLER, "--about", "pervio-view"])
PROCS.append(decoy)
STARTED.append(decoy.pid)
with open(pidfile, "w", encoding="utf-8") as f:
    json.dump({"pid": decoy.pid, "port": 1, "started": time.time()}, f)
infoJ2, procJ2, errJ2 = launch(homeJ, ["--dir", archJ, "--latest", "--idle", "60"])
time.sleep(0.6)
check("H13b a pid file naming a process whose argv merely MENTIONS pervio-view "
      "does not kill it", ps_alive(decoy.pid) and decoy.poll() is None,
      (decoy.poll(), ps_cmd(decoy.pid)))
check("H13c ...and the new instance still started",
      isinstance(infoJ2, dict) and ps_alive(infoJ2["pid"]), errJ2[:200])
decoy.kill()
decoy.wait(timeout=5)
check("H13d the decoy is cleaned up by the TEST", not ps_alive(decoy.pid))
reap((infoJ2 or {}).get("pid"), procJ2)

for bogus in ("1", "-1", "0", "999999999"):
    with open(pidfile, "w", encoding="utf-8") as f:
        json.dump({"pid": int(bogus)}, f)
    infoK, procK, errK = launch(homeJ, ["--dir", archJ, "--latest", "--idle", "20"])
    check("H14 pid file with pid=%s is survivable (server still starts)" % bogus,
          isinstance(infoK, dict), errK[:200])
    if isinstance(infoK, dict):
        reap(infoK["pid"], procK)
    else:
        reap(None, procK)
reap((infoJ or {}).get("pid"), procJ)

# Sweep-then-record must be ONE atomic step. Otherwise simultaneous launches all
# read the same empty pid file, all survive, and only the last one is recorded —
# the others are then unreachable forever: no later launch can ever reap them.
homeR2, archR2 = make_home("R2")
race_out = []
race_lock = threading.Lock()


def _race():
    r = launch(homeR2, ["--dir", archR2, "--latest", "--idle", "45"], detach=True)
    with race_lock:
        race_out.append(r)


_ths = [threading.Thread(target=_race) for _ in range(3)]
for _t in _ths:
    _t.start()
for _t in _ths:
    _t.join(90)
race_pids = [r[0]["pid"] for r in race_out if isinstance(r[0], dict)]
check("H14b three simultaneous launches all came up", len(race_pids) == 3,
      [(r[0], r[2][:120]) for r in race_out])
time.sleep(0.5)
race_alive = [p for p in race_pids if ps_alive(p)]
check("H14c ...and exactly ONE of them survives (sweep+record is atomic)",
      len(race_alive) == 1, [(p, ps_cmd(p)) for p in race_alive])
try:
    with open(os.path.join(homeR2, ".pervio", "view.json"), encoding="utf-8") as f:
        _rec = json.load(f)
except Exception:
    _rec = {}
check("H14d ...and the pid file names that survivor, so it stays reapable",
      len(race_alive) == 1 and _rec.get("pid") == race_alive[0], (_rec, race_alive))
for r in race_out:
    reap((r[0] or {}).get("pid"), r[1])

# a command in flight is not idleness — the click must not be killed halfway
homeS, archS = make_home("S")
infoS, procS, errS = launch(homeS, ["--dir", archS, "--latest", "--idle", "3"])
if isinstance(infoS, dict):
    t0 = time.time()
    st, body, _ = post_json(base_of(infoS), token_of(infoS),
                            {"actionIndex": 3, "captureGroups": ["5"],
                             "choiceIndex": 0})
    took = time.time() - t0
    check("H16 a 5s command outlives a 3s idle window instead of being killed "
          "mid-write", st == 200 and took > 4.5
          and os.path.exists(os.path.join(homeS, "slow.done")),
          (st, round(took, 1), body[:160]))
    check("H17 ...and the idle clock restarts from the command's END",
          ps_alive(infoS["pid"]))
    check("H18 ...then the server still exits on its own",
          wait_gone(infoS["pid"], 12))
else:
    check("H16 slow-command server started", False, errS[:200])
reap((infoS or {}).get("pid"), procS)

# idle clamp: --idle above the 60-minute ceiling is clamped, not honoured
homeL, archL = make_home("L")
infoL, procL, _ = launch(homeL, ["--dir", archL, "--latest", "--idle", "99999"])
check("H15 --idle is clamped to the 60-minute absolute ceiling",
      isinstance(infoL, dict) and infoL.get("expiresIn") == 3600, infoL)
reap((infoL or {}).get("pid"), procL)

# =============================================================================
print("=== KA: the reader stays up while somebody is quietly reading ===")
# The idle clock can only see HTTP requests, and reading a long report produces
# exactly ONE — the GET that fetched it. Ten minutes of careful reading therefore
# looked identical to ten minutes of an empty desk, and the page died under the
# most attentive reader: the better you read, the sooner you were declared gone.
#
# The fix is a keepalive the PAGE sends while it is visible. Four things have to
# be true of it, and each is asserted below against a real server:
#   1. while somebody is looking, the reader outlives its idle window (KA5–KA9);
#   2. the moment nobody is, the pings stop and it dies on schedule (KA6, KA10)
#      — otherwise the fix is just "the server never exits";
#   3. it is not a new way in: no token, no effect, no body, no report, no write
#      (KA1–KA4, KA7);
#   4. it cannot push past the 60-minute ceiling (KA11).


class Pinger(threading.Thread):
    """The keepalive, driven from Python — for the scenarios where the browser
    is not the thing under test. One GET every `every` seconds until stop(),
    recording the status of each so a scenario can say "the pings were still
    being answered when it died" rather than just "it died"."""

    def __init__(self, base, token, every=0.5, path="/alive"):
        threading.Thread.__init__(self, daemon=True)
        self.url = "%s%s?t=%s" % (base, path, token) if token \
            else "%s%s" % (base, path)
        self.every = every
        self.codes = []
        self._halt = threading.Event()

    def run(self):
        while not self._halt.is_set():
            self.codes.append(http(self.url, timeout=5)[0])
            self._halt.wait(self.every)

    def stop(self):
        self._halt.set()
        self.join(timeout=8)


def page_script(pg):
    """The page's ONE nonce-tagged script, verbatim (C2 pins that there is only
    one)."""
    m = re.search(r'<script nonce="[^"]*">(.*?)</script>', pg, re.S)
    return m.group(1) if m is not None else ""


# The browser stand-in. Everything the page's script needs and NOTHING else:
# document.visibilityState, addEventListener, a toast element, location.search.
# `fetch` is node's REAL one — the only thing added is the origin a browser would
# have supplied for the relative '/alive?t=' the page writes — so every request in
# the log below really hit the real server on its real port. Phases like
# "visible:8,hidden:6" flip visibilityState and fire visibilitychange exactly the
# way switching tabs does, which is the only way to test "only while visible"
# without putting a window on anybody's screen.
KA_NODE = os.path.join(TOOLS, "kapage.js")
with open(KA_NODE, "w", encoding="utf-8") as f:
    f.write("""// argv: <origin> <location.search> <script-file> <phases> <out-file>
const fs = require('fs');
const [ORIGIN, SEARCH, SRC, PHASES, OUT] = process.argv.slice(2);
const calls = [], listeners = {};
globalThis.document = {
  visibilityState: 'visible',
  addEventListener: (ev, fn) => { (listeners[ev] = listeners[ev] || []).push(fn); },
  getElementById: () => ({ textContent: '', className: '' })
};
globalThis.location = { search: SEARCH };
const realFetch = globalThis.fetch;
globalThis.fetch = function (u, o) {
  calls.push({ url: String(u), method: (o && o.method) || 'GET',
               body: (o && o.body) || null,
               vis: document.visibilityState });
  return realFetch(ORIGIN + u, o || {});
};
const phases = PHASES.split(',').map(s => {
  const p = s.split(':');
  return { vis: p[0], ms: Math.round(parseFloat(p[1]) * 1000) };
});
function done() { fs.writeFileSync(OUT, JSON.stringify(calls)); process.exit(0); }
function phase(i) {
  if (i >= phases.length) return done();
  if (document.visibilityState !== phases[i].vis) {
    document.visibilityState = phases[i].vis;
    (listeners['visibilitychange'] || []).forEach(f => f());
  }
  setTimeout(() => phase(i + 1), phases[i].ms);
}
document.visibilityState = phases[0].vis;
(0, eval)(fs.readFileSync(SRC, 'utf8'));
setTimeout(() => phase(1), phases[0].ms);
""")

NODE = shutil.which("node") or ""


def drive_page(tag, info, pg, phases, timeout=120):
    """Run the served page's script under node for `phases`; return the fetch log
    it recorded. The server is untouched by the harness — node talks to it over
    the same loopback port everything else in this file uses."""
    d = tempfile.mkdtemp(prefix="ka_%s_" % tag, dir=ROOT)
    src = os.path.join(d, "page.js")
    with open(src, "w", encoding="utf-8") as fh:
        fh.write(page_script(pg))
    out = os.path.join(d, "calls.json")
    p = subprocess.Popen([NODE, KA_NODE, base_of(info), "?t=" + token_of(info),
                          src, phases, out],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    PROCS.append(p)
    STARTED.append(p.pid)
    try:
        _, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill()
        return None, "node did not finish"
    if not os.path.exists(out):
        return None, (err or "")[:300]
    with open(out, encoding="utf-8") as fh:
        return json.load(fh), (err or "")[:300]


# --- KA1–KA4: the endpoint itself ---------------------------------------------
homeKA, archKA = make_home("KA")
infoKA, procKA, errKA = launch(homeKA, ["--dir", archKA, "--latest", "--idle", "60"])
check("KA0 keepalive scenario server started", isinstance(infoKA, dict), errKA[:200])
if isinstance(infoKA, dict):
    baseKA, tokKA = base_of(infoKA), token_of(infoKA)
    portKA = int(re.search(r":(\d+)", baseKA).group(1))
    st, body, hdrs = http("%s/alive?t=%s" % (baseKA, tokKA))
    check("KA1 GET /alive with the token answers 200 {\"ok\": true}",
          st == 200 and json.loads(body or "{}") == {"ok": True}, (st, body[:120]))
    check("KA2 ...and returns none of the report, in a few dozen unstored bytes",
          st == 200 and len(body) < 64 and "论文晨报" not in body
          and "arxiv" not in body.lower()
          and "no-store" in (hdrs.get("Cache-Control") or "")
          and (hdrs.get("X-Content-Type-Options") or "") == "nosniff",
          (st, len(body), body[:120], hdrs.get("Cache-Control")))
    st, body, _ = http("%s/alive" % baseKA)
    check("KA3 a keepalive with NO token -> 403", st == 403, (st, body[:120]))
    st, body, _ = http("%s/alive?t=%s" % (baseKA, "x" * 40))
    check("KA3b ...and with a wrong token -> 403", st == 403, (st, body[:120]))
    # It is a read of one boolean and nothing else: no body is accepted, and the
    # path is compared exactly, so it opens no second way to name a file.
    st, body, _ = http("%s/alive?t=%s" % (baseKA, tokKA), data=b"{}",
                       headers={"Content-Type": "application/json"})
    check("KA4 POST /alive -> 404: the keepalive is not a write of any kind",
          st == 404, (st, body[:160]))
    for pth in ("/alive/", "/alive/x", "/ALIVE", "/alive/../score",
                "/alive/../../etc/passwd"):
        txt = raw_request(portKA, "GET %s?t=%s HTTP/1.1" % (pth, tokKA))
        first = txt.split("\r\n")[0] if txt else ""
        # The path is compared EXACTLY, so "/alive" does not become a prefix that
        # names other things. The body check is for the SUCCESS shape — a 404's
        # own body legitimately says {"ok": false}.
        check("KA4b %s is not the keepalive (404/403)" % pth,
              (" 404 " in first or " 403 " in first) and "root:" not in txt
              and not re.search(r'"ok"\s*:\s*true', txt), first)
    # The interval the page is told to use is DERIVED from the window it has to
    # beat — a fixed timer would never fire inside a short --idle, and the
    # feature would silently do nothing for whoever asked for the shortest one.
    _, pgKA, _ = http(infoKA["url"])
    check("KA4c the JSON line advertises the keepalive interval, and the page "
          "really ticks at it",
          infoKA.get("keepalive") == 20
          and ("setInterval(ping, 20 * 1000)" in page_script(pgKA)),
          (infoKA.get("keepalive"),
           re.findall(r"setInterval\([^)]*\)", page_script(pgKA))))
    check("KA4d ...and the page pings /alive with the token, nothing else",
          "'/alive?t=' + encodeURIComponent(t)" in page_script(pgKA),
          [l for l in page_script(pgKA).splitlines() if "alive" in l])
    reap(infoKA["pid"], procKA)

for _idle, _want in ((600, 60), (99999, 60), (30, 10), (6, 2), (1, 1)):
    _h, _a = make_home("kai%d" % _idle)
    _i, _p, _e = launch(_h, ["--dir", _a, "--latest", "--idle", str(_idle)])
    check("KA4e --idle %d -> a keepalive every %ds (idle/3, capped at 60, never 0)"
          % (_idle, _want),
          isinstance(_i, dict) and _i.get("keepalive") == _want, (_i, _e[:160]))
    reap((_i or {}).get("pid"), _p)

# --- KA5–KA7: the idle clock, driven from Python ------------------------------
# Through --detach, deliberately: that is the argv the phone sends, it raises the
# watchdog from a DIFFERENT branch of main() than everything the node scenarios
# below drive, and this file has been bitten once already by a branch no test
# ever executed (see J21). The two together cover both.
homeKB, archKB = make_home("KB")
infoKB, procKB, errKB = launch(homeKB, ["--dir", archKB, "--latest", "--idle", "4"],
                               detach=True)
if isinstance(infoKB, dict):
    pKB = Pinger(base_of(infoKB), token_of(infoKB), every=0.5)
    pKB.start()
    time.sleep(9)                     # 2.25x the idle window, all of it silent
    aliveKB = ps_alive(infoKB["pid"])
    codesKB = list(pKB.codes)
    pKB.stop()
    check("KA5 a DETACHED reader who only pings outlives its idle window twice "
          "over (the phone's own path: launcher gone, server pinged)",
          aliveKB and procKB.poll() == 0 and len(codesKB) >= 12
          and set(codesKB) == {200},
          (aliveKB, procKB.poll(), len(codesKB), sorted(set(codesKB))))
    check("KA6 ...and once the pings stop it dies on schedule anyway",
          wait_gone(infoKB["pid"], 12))
else:
    check("KA5 keepalive lifecycle server started", False, errKB[:200])
reap((infoKB or {}).get("pid"), procKB)

# The one that decides whether this is a feature or a hole: a keepalive from
# something that does NOT hold the token must not move the clock. Anything on
# this box can knock on the port, and a page on any website can make a browser
# send a no-cors GET to 127.0.0.1 — it never reads the answer, but it would not
# need to if the KNOCK alone kept the reader alive.
homeKC, archKC = make_home("KC")
infoKC, procKC, errKC = launch(homeKC, ["--dir", archKC, "--latest", "--idle", "4"])
if isinstance(infoKC, dict):
    pKC = Pinger(base_of(infoKC), "", every=0.4)
    pKC.start()
    goneKC = wait_gone(infoKC["pid"], 12)
    codesKC = list(pKC.codes)
    pKC.stop()
    check("KA7 unauthenticated keepalives are refused AND do not touch the idle "
          "clock — the reader still dies under a constant knock",
          goneKC and codesKC and set(codesKC) <= {403, 0},
          (goneKC, len(codesKC), sorted(set(codesKC))))
else:
    check("KA7 unauthenticated-knock server started", False, errKC[:200])
reap((infoKC or {}).get("pid"), procKC)

# --- KA8–KA10: the PAGE's own script, run for real ----------------------------
# KA5 proves the server honours a keepalive. It says nothing about whether the
# page SENDS one — which is the whole user-visible bug. These drive the served
# script itself.
if NODE:
    homeKD, archKD = make_home("KD")
    infoKD, procKD, errKD = launch(homeKD, ["--dir", archKD, "--latest", "--idle", "6"])
    if isinstance(infoKD, dict):
        _, pgKD, _ = http(infoKD["url"])
        callsKD, errN = drive_page("vis", infoKD, pgKD, "visible:8")
        check("KA8 the page, left VISIBLE and untouched, keeps the reader alive "
              "past its idle window with nothing but keepalives",
              ps_alive(infoKD["pid"]) and callsKD is not None and len(callsKD) >= 3
              and all(c["url"] == "/alive?t=" + token_of(infoKD)
                      and c["method"] == "GET" and c["body"] is None
                      for c in (callsKD or [])),
              (ps_alive(infoKD["pid"]), callsKD, errN))
        reap(infoKD["pid"], procKD)
    else:
        check("KA8 visible-page server started", False, errKD[:200])
        reap(None, procKD)

    homeKE, archKE = make_home("KE")
    infoKE, procKE, errKE = launch(homeKE, ["--dir", archKE, "--latest", "--idle", "4"])
    if isinstance(infoKE, dict):
        _, pgKE, _ = http(infoKE["url"])
        callsKE, errN = drive_page("hid", infoKE, pgKE, "hidden:8")
        check("KA9 a HIDDEN page sends nothing at all...", callsKE == [],
              (callsKE, errN))
        check("KA10 ...so the idle clock runs and the reader still exits — the "
              "keepalive cannot become 'the server never dies'",
              not ps_alive(infoKE["pid"]), ps_cmd(infoKE["pid"]))
        reap(infoKE["pid"], procKE)
    else:
        check("KA9 hidden-page server started", False, errKE[:200])
        reap(None, procKE)

    homeKF, archKF = make_home("KF")
    infoKF, procKF, errKF = launch(homeKF, ["--dir", archKF, "--latest", "--idle", "60"])
    if isinstance(infoKF, dict):
        _, pgKF, _ = http(infoKF["url"])
        callsKF, errN = drive_page("flip", infoKF, pgKF, "hidden:3,visible:0.6")
        check("KA10b coming back to the tab pings immediately (visibilitychange), "
              "and nothing was sent while it was hidden",
              callsKF is not None and len(callsKF) >= 1
              and all(c["vis"] == "visible" for c in (callsKF or [])),
              (callsKF, errN))
        reap(infoKF["pid"], procKF)
    else:
        check("KA10b visibility-flip server started", False, errKF[:200])
        reap(None, procKF)

    # A tab left open after its server exited must go QUIET. Loopback ports get
    # recycled, and this page's token rides in the query string — a keepalive
    # that knocks forever eventually hands it to whatever unrelated local
    # service inherited the port.
    homeKH, archKH = make_home("KH")
    infoKH, procKH, errKH = launch(homeKH, ["--dir", archKH, "--latest", "--idle", "3"])
    if isinstance(infoKH, dict):
        _, pgKH, _ = http(infoKH["url"])
        reap(infoKH["pid"], procKH)          # the server is gone BEFORE the page runs
        callsKH, errN = drive_page("dead", infoKH, pgKH, "visible:8")
        check("KA10c a page whose server has already exited gives up after three "
              "failures instead of knocking on a recycled port forever "
              "(8s / 1s interval = 8 chances, 3 taken)",
              callsKH is not None and 3 <= len(callsKH) <= 4, (callsKH, errN))
    else:
        check("KA10c dead-server page scenario started", False, errKH[:200])
        reap(None, procKH)
else:
    # No node on this box: the behavioural harness cannot run, so the page half is
    # pinned structurally instead. Weaker (it cannot see logic reordered around
    # the gate) but not free: deleting either line turns it red, which is exactly
    # what J23/J24 mutate.
    check("KA8/KA9/KA10c (no node: structural) the page ships a visibility-gated "
          "pinger that gives up on a dead server",
          src_view.count("    if (document.visibilityState !== 'visible') return;\n") == 1
          and src_view.count("  kaTimer = setInterval(ping, __KA__ * 1000);\n") == 1
          and src_view.count("  function kaMissed(){ if (++kaMiss >= 3) kaStop(); }\n") == 1,
          [l for l in src_view.splitlines() if "visibilityState" in l or "ka" in l][:8])

# --- KA11: the 60-minute ceiling is still not negotiable ----------------------
# Waiting an hour is not a test, so the CEILING is shrunk in a scratch COPY (the
# real script is never edited) and the reader is pinged without pause for longer
# than it. The pings must visibly work first — the copy has to outlive its idle
# window — and then lose to the ceiling anyway.
homeKG, archKG = make_home("KG")
mpath, ok = mutant("HARD_CAP = 3600", "HARD_CAP = 8", "cap")
check("KA11 the hard ceiling is one line in pervio-view", ok)
infoKG, procKG = launch_bin(mpath, homeKG, ["--dir", archKG, "--latest", "--idle", "3"])
if isinstance(infoKG, dict):
    t0 = time.time()
    pKG = Pinger(base_of(infoKG), token_of(infoKG), every=0.4)
    pKG.start()
    time.sleep(5.5)                   # past the 3s idle window, kept alive by pings
    aliveKG = ps_alive(infoKG["pid"])
    goneKG = wait_gone(infoKG["pid"], 12)
    tookKG = time.time() - t0
    codesKG = list(pKG.codes)
    pKG.stop()
    check("KA12 an unbroken keepalive beats the idle window...",
          aliveKG and codesKG.count(200) >= 8, (aliveKG, codesKG.count(200)))
    check("KA13 ...and loses to the absolute ceiling regardless (died at %.1fs "
          "with the pings still being answered)" % tookKG,
          goneKG and tookKG < 20, (goneKG, round(tookKG, 1)))
else:
    check("KA12 shrunk-ceiling copy started", False, "copy did not start")
reap((infoKG or {}).get("pid"), procKG)

# =============================================================================
print("=== I: bad arguments and a huge report ===")
homeM, archM = make_home("M")
for args, why in (
        (["--dir", archM, "--file", "../../../../etc/passwd"], "traversal --file"),
        (["--dir", archM, "--file", "no-such.md"], "missing --file"),
        (["--dir", os.path.join(ROOT, "nope")], "missing --dir"),
        (["--latest"], "no --dir"),
        (["--dir", archM, "--file", "x.md", "--latest"], "--file with --latest")):
    p = subprocess.run([sys.executable, VIEW] + args, env=env_for(homeM),
                       capture_output=True, text=True, timeout=30)
    check("I %s exits non-zero without starting a server" % why,
          p.returncode != 0 and not p.stdout.strip().startswith("{"),
          (p.returncode, p.stdout[:120], p.stderr[:160]))

homeN, archN = make_home("N")
with open(os.path.join(archN, "2026-08-06.md"), "w", encoding="utf-8") as f:
    f.write("# 超大报告\n\n")
    for i in range(3000):
        f.write("## 段 %d\n\n%s\n\n- [x](https://arxiv.org/abs/2608.%05d)\n\n"
                % (i, "内容" * 200, i))
sz = os.path.getsize(os.path.join(archN, "2026-08-06.md"))
t0 = time.time()
infoN, procN, errN = launch(homeN, ["--dir", archN, "--latest", "--idle", "120"],
                            timeout=60)
check("I6 a %.1f MB report still starts" % (sz / 1e6), isinstance(infoN, dict),
      errN[:200])
if isinstance(infoN, dict):
    st, big_page, _ = http(infoN["url"], timeout=60)
    check("I7 ...and serves in bounded time (%.1fs)" % (time.time() - t0),
          st == 200 and time.time() - t0 < 45, st)
    check("I8 ...truncated with a visible notice rather than served whole",
          len(big_page) < 40_000_000 and "截断" in big_page,
          (len(big_page), sz))
    reap(infoN["pid"], procN)

# --latest must honour the SAME containment gate as --file. A symlink dropped in
# the archive dir is a file from OUTSIDE it wearing an issue's name; whoever can
# write that dir must not thereby get the reader to serve /etc/... on a port.
homeP, archP = make_home("P")
OUTSIDE = os.path.join(ROOT, "outside-secret.md")
with open(OUTSIDE, "w", encoding="utf-8") as f:
    f.write("# 归档目录之外的机密\n\n这一行绝不该被端出去。\n")
os.symlink(OUTSIDE, os.path.join(archP, "2026-08-07.md"))   # newest by mtime
infoP, procP, errP = launch(homeP, ["--dir", archP, "--latest", "--idle", "30"])
check("I9 --latest still starts with a symlink in the dir", isinstance(infoP, dict),
      errP[:200])
if isinstance(infoP, dict):
    stP, pageP, _ = http(infoP["url"])
    check("I10 --latest does NOT follow a symlink out of the archive dir",
          stP == 200 and "归档目录之外的机密" not in pageP and "论文晨报" in pageP,
          (stP, pageP[:200]))
    reap(infoP["pid"], procP)
pF = subprocess.run([sys.executable, VIEW, "--dir", archP, "--file", "2026-08-07.md"],
                    env=env_for(homeP), capture_output=True, text=True, timeout=30)
check("I11 ...and --file refuses that same symlink by name",
      pF.returncode != 0 and not pF.stdout.strip().startswith("{"),
      (pF.returncode, pF.stdout[:120], pF.stderr[:160]))

# Nesting is untrusted like every other byte of the report: a 2000-deep <details>
# must render (capped), never blow the interpreter's stack.
DEEP = ("# 深套娃\n\n" + "<details>\n<summary>层</summary>\n\n" * 2000
        + "最里面一行\n\n" + "</details>\n\n" * 2000)
homeD, archD = make_home("D", report=DEEP)
infoD, procD, errD = launch(homeD, ["--dir", archD, "--latest", "--idle", "30"],
                            timeout=40)
check("I12 a 2000-deep <details> report still starts (no RecursionError)",
      isinstance(infoD, dict), errD[-300:])
if isinstance(infoD, dict):
    stD, pageD, _ = http(infoD["url"], timeout=40)
    check("I13 ...and serves a balanced page with the innermost line intact",
          stD == 200 and pageD.count("<details") == pageD.count("</details>")
          and "最里面一行" in pageD,
          (stD, pageD.count("<details"), pageD.count("</details>")))
    check("I14 ...with the nesting capped: levels past the cap are TEXT, not markup",
          pageD.count("<details") <= 32 and "&lt;details&gt;" in pageD,
          pageD.count("<details"))
    reap(infoD["pid"], procD)

# =============================================================================
print("=== J: mutation — each guard, when disabled, turns its assertion RED ===")
homeT, archT = make_home("T")
mpath, ok = mutant("if not hmac.compare_digest(got, TOKEN):",
                   "if False:  # MUTATED: token check off", "tok")
check("J1 the token-check line exists exactly once in pervio-view", ok)
infoT, procT = launch_bin(mpath, homeT, ["--dir", archT, "--latest", "--idle", "60"])
if isinstance(infoT, dict):
    st, _, _ = http("%s/" % base_of(infoT))
    check("J2 token mutant serves without a token (E1's assertion goes RED)",
          st == 200, st)
    reap(infoT["pid"], procT)
else:
    check("J2 token mutant started", False, "mutant did not start")
    reap(None, procT)

homeU, archU = make_home("U")
mpath, ok = mutant("if not (isinstance(ci, int) and 0 <= ci < len(menu)):",
                   "if False:  # MUTATED: menu check off", "menu")
check("J3 the menu-check line exists exactly once in pervio-view", ok)
infoU, procU = launch_bin(mpath, homeU, ["--dir", archU, "--latest", "--idle", "60"])
if isinstance(infoU, dict):
    st, body, _ = post_json(base_of(infoU), token_of(infoU),
                            {"actionIndex": 0, "captureGroups": ["2608.04788"],
                             "choiceIndex": 99})
    check("J4 menu mutant no longer answers 400 (F4's assertion goes RED)",
          st != 400, (st, body[:160]))
    reap(infoU["pid"], procU)
else:
    check("J4 menu mutant started", False, "mutant did not start")
    reap(None, procU)

homeV, archV = make_home("V")
mpath, ok = mutant("_wd.start()", "pass  # MUTATED: watchdog off", "wd")
check("J5 the watchdog start line exists exactly once in pervio-view", ok)
infoV, procV = launch_bin(mpath, homeV, ["--dir", archV, "--latest", "--idle", "3"])
if isinstance(infoV, dict):
    time.sleep(9)
    check("J6 watchdog mutant is STILL alive past its idle window "
          "(H6's assertion goes RED)", ps_alive(infoV["pid"]), ps_cmd(infoV["pid"]))
    reap(infoV["pid"], procV)
    check("J7 ...and the mutant is killed by the test", not ps_alive(infoV["pid"]))
else:
    check("J6 watchdog mutant started", False, "mutant did not start")
    reap(None, procV)

homeW, archW = make_home("W")
mpath, ok = mutant("    return html.escape(s, quote=True)",
                   "    return s  # MUTATED: escaping off", "esc")
check("J8 the escape line exists exactly once in pervio-view", ok)
infoW, procW = launch_bin(mpath, homeW, ["--dir", archW, "--latest", "--idle", "60"])
if isinstance(infoW, dict):
    bad_page = http(infoW["url"])[1]
    check("J9 escaping mutant lets the report's <script> through "
          "(C1/C2's assertions go RED)",
          "<script>window.__pwned" in bad_page
          and len(re.findall(r"<script(?![^>]*nonce=)", bad_page)) > 0,
          bad_page[-400:])
    reap(infoW["pid"], procW)
else:
    check("J9 escaping mutant started", False, "mutant did not start")
    reap(None, procW)

homeY, archY = make_home("Y")
mpath, ok = mutant(
    "if now >= deadline or (INFLIGHT[0] == 0 and now - LAST[0] >= idle):",
    "if now >= deadline or now - LAST[0] >= idle:  # MUTATED: in-flight ignored",
    "flight")
check("J12 the in-flight guard exists exactly once in pervio-view", ok)
infoY, procY = launch_bin(mpath, homeY, ["--dir", archY, "--latest", "--idle", "3"])
if isinstance(infoY, dict):
    st, body, _ = post_json(base_of(infoY), token_of(infoY),
                            {"actionIndex": 3, "captureGroups": ["5"],
                             "choiceIndex": 0}, timeout=20)
    check("J13 in-flight mutant dies under the running command "
          "(H16's assertion goes RED)",
          st != 200 and not ps_alive(infoY["pid"]), (st, body[:160]))
    reap(infoY["pid"], procY)
else:
    check("J13 in-flight mutant started", False, "mutant did not start")
    reap(None, procY)
time.sleep(6)   # let the orphaned 5s helper finish on its own, then prove it did
# Scoped to THIS run's SLEEPER (an absolute path under a fresh mkdtemp), never to
# the bare basename. `pgrep -f sleeper.py` was machine-global: a second run_all.sh,
# another agent's checkout, or any process that merely mentions the name turned
# this green assertion red — a false red that says nothing about pervio-view.
# Same rule K2 states below; J14 was the one place that broke it.
_slp = subprocess.run(["pgrep", "-f", SLEEPER], capture_output=True, text=True)
check("J14 the command the mutant orphaned is gone too",
      not (_slp.stdout or "").strip(), _slp.stdout)
# J14b: and the scan must stay blind to everything that is not ours. A second
# run_all.sh looks EXACTLY like this decoy — a live process whose argv ends in
# "sleeper.py", in a directory this run has never heard of. With the old
# machine-global pattern J14 went red on it (verified 2026-08-07), which is a
# false red: it says nothing about pervio-view, only that the box is busy.
_decoy_dir = tempfile.mkdtemp(prefix="otherrun_", dir="/tmp")
_decoy_py = os.path.join(_decoy_dir, "sleeper.py")
with open(_decoy_py, "w", encoding="utf-8") as f:
    f.write("import time\ntime.sleep(120)\n")
_decoy = subprocess.Popen([sys.executable, _decoy_py, "--secs", "120"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    time.sleep(0.5)
    _bare = subprocess.run(["pgrep", "-f", "sleeper.py"], capture_output=True, text=True)
    _mine = subprocess.run(["pgrep", "-f", SLEEPER], capture_output=True, text=True)
    check("J14b a concurrent run's sleeper is visible to the bare-name scan "
          "(so the decoy is real)",
          str(_decoy.pid) in (_bare.stdout or "").split(), (_bare.stdout, _decoy.pid))
    check("J14b ...and INVISIBLE to J14's scan, which is scoped to this run",
          not (_mine.stdout or "").strip(), _mine.stdout)
finally:
    _decoy.kill()
    _decoy.wait(timeout=5)
    shutil.rmtree(_decoy_dir, ignore_errors=True)

homeX, archX = make_home("X")
mpath, ok = mutant("\n        _kill_leftover()\n",
                   "\n        pass  # MUTATED: no sweep\n", "sweep")
check("J10 the leftover sweep is called exactly once in pervio-view", ok)
infoX1, procX1 = launch_bin(mpath, homeX, ["--dir", archX, "--latest", "--idle", "30"])
infoX2, procX2 = launch_bin(mpath, homeX, ["--dir", archX, "--latest", "--idle", "30"])
if isinstance(infoX1, dict) and isinstance(infoX2, dict):
    time.sleep(1.0)
    check("J11 sweep mutant leaves the previous instance running "
          "(H9's assertion goes RED)",
          ps_alive(infoX1["pid"]) and ps_alive(infoX2["pid"]),
          (ps_cmd(infoX1["pid"]), ps_cmd(infoX2["pid"])))
else:
    check("J11 sweep mutants started", False, (infoX1, infoX2))
reap((infoX1 or {}).get("pid"), procX1)
reap((infoX2 or {}).get("pid"), procX2)

# The MAX_BODY refusal: without the guard the server reads all 300 KB and only
# THEN fails on the JSON — a 400. That is why F16 pins 413 and not "400 or 413".
homeAA, archAA = make_home("AA")
mpath, ok = mutant("if length < 0 or length > MAX_BODY:",
                   "if length < 0:  # MUTATED: body size guard off", "body")
check("J15 the MAX_BODY guard exists exactly once in pervio-view", ok)
infoAA, procAA = launch_bin(mpath, homeAA, ["--dir", archAA, "--latest", "--idle", "60"])
if isinstance(infoAA, dict):
    st, body, _ = http("%s/score?t=%s" % (base_of(infoAA), token_of(infoAA)),
                       data=b"{" + b"x" * 300000,
                       headers={"Content-Type": "application/json"})
    check("J16 size-guard mutant buffers it all and answers 400, not 413 "
          "(F16's assertion goes RED)", st == 400, st)
    reap(infoAA["pid"], procAA)
else:
    check("J16 size-guard mutant started", False, "mutant did not start")
    reap(None, procAA)

# The other half of the command-rebuild safety: the choice must be on the menu
# (J3/J4) AND the capture groups must be groups this report really produced.
homeAB, archAB = make_home("AB")
mpath, ok = mutant("if (ai, tuple(cg)) not in HITS:",
                   "if False:  # MUTATED: capture-group guard off", "hits")
check("J17 the capture-group guard exists exactly once in pervio-view", ok)
infoAB, procAB = launch_bin(mpath, homeAB, ["--dir", archAB, "--latest", "--idle", "60"])
if isinstance(infoAB, dict):
    st, body, _ = post_json(base_of(infoAB), token_of(infoAB),
                            {"actionIndex": 0, "captureGroups": ["9999.99999"],
                             "choiceIndex": 0})
    check("J18 capture-group mutant scores a paper THIS report never carried "
          "(F7/F8's assertions go RED)",
          st == 200 and "arXiv:9999.99999" in memory(homeAB), (st, body[:200]))
    reap(infoAB["pid"], procAB)
else:
    check("J18 capture-group mutant started", False, "mutant did not start")
    reap(None, procAB)

# --- the four mutants that prove A10d–A10m have teeth -------------------------
# All of them run against the fake `open`, so the mutants themselves cannot reach
# a browser either: the only thing that changes is what lands in the argv log.
homeAC, archAC = make_home("AC")
mpath, ok = mutant('subprocess.run(["open", "-g", url]',
                   'subprocess.run(["open", url]', "nog",   # MUTATED: focus stealer
                   also=UNGATE)
check("J19 the `open -g` call exists exactly once in pervio-view", ok)
envAC, logAC = open_env(homeAC, "nog")
infoAC, procAC, _ = launch(homeAC, ["--dir", archAC, "--latest", "--idle", "60",
                                    "--open"], env=envAC, binpath=mpath)
rowsAC = settle_open_rows(logAC, expect=1)
check("J19b dropping -g makes the browser steal focus (A10e's assertion goes RED)",
      rowsAC == [["open", (infoAC or {}).get("url")]], rowsAC)
reap((infoAC or {}).get("pid"), procAC)

homeAD, archAD = make_home("AD")
mpath, ok = mutant('        if o["open"]:\n            ok, why = _raise_on_desktop(line["url"])',
                   '        if True:  # MUTATED: opt-in guard off\n'
                   '            ok, why = _raise_on_desktop(line["url"])', "optin",
                   also=UNGATE)
check("J20 the foreground opt-in guard exists exactly once in pervio-view", ok)
envAD, logAD = open_env(homeAD, "optin")
infoAD, procAD, _ = launch(homeAD, ["--dir", archAD, "--latest", "--idle", "60"],
                           env=envAD, binpath=mpath)   # NOTE: no --open
rowsAD = settle_open_rows(logAD, expect=1)
check("J20b without the guard a plain run raises a window anyway "
      "(A10g's assertion goes RED)",
      [r[:1] for r in rowsAD] == [["open"]], rowsAD)
reap((infoAD or {}).get("pid"), procAD)

# J21 is LITERALLY the mutation an audit used to prove this suite was blind: a
# focus-stealing `open` (no -g) planted at the DETACHED raise point, which passed
# 154/154 because nothing here had ever executed that branch. It must now be seen.
homeAE, archAE = make_home("AE")
mpath, ok = mutant('\n        ok, why = _raise_on_desktop(line["url"])\n'
                   '        line["opened"] = ok',
                   '\n        subprocess.run(["open", line["url"]])'
                   '   # MUTATED: focus stealer at the detached raise point\n'
                   '        ok, why = _raise_on_desktop(line["url"])\n'
                   '        line["opened"] = ok', "detsteal")
check("J21 the detached raise point exists exactly once in pervio-view", ok)
envAE, logAE = open_env(homeAE, "detsteal")
infoAE, procAE, _ = launch(homeAE, ["--dir", archAE, "--latest", "--idle", "60",
                                    "--open"], detach=True, env=envAE, binpath=mpath)
rowsAE = settle_open_rows(logAE, expect=2 if IS_MAC else 1)
check("J21b a focus stealer at the DETACHED raise point is seen "
      "(A10i/A10j go RED)" if IS_MAC else
      "J21b off macOS only the unguarded stealer runs; the guarded call refuses",
      (len(rowsAE) == 2 and ["open", (infoAE or {}).get("url")] in rowsAE) if IS_MAC
      else rowsAE == [["open", (infoAE or {}).get("url")]], rowsAE)
reap((infoAE or {}).get("pid"), procAE)

homeAF, archAF = make_home("AF")
mpath, ok = mutant('    if o["open"]:\n        # After readiness',
                   '    if True:  # MUTATED: detached opt-in guard off\n'
                   '        # After readiness', "detoptin",
                   also=UNGATE)
check("J22 the detached opt-in guard exists exactly once in pervio-view", ok)
envAF, logAF = open_env(homeAF, "detoptin")
infoAF, procAF, _ = launch(homeAF, ["--dir", archAF, "--latest", "--idle", "60"],
                           detach=True, env=envAF, binpath=mpath)   # NOTE: no --open
rowsAF = settle_open_rows(logAF, expect=1)
check("J22b without the detached guard a plain --detach raises a window anyway "
      "(A10l's assertion goes RED)",
      [r[:1] for r in rowsAF] == [["open"]], rowsAF)
reap((infoAF or {}).get("pid"), procAF)

# --- the four mutants that give the KA section teeth --------------------------
# The keepalive is two halves that fail in opposite directions: without the page
# half the reader dies under a reader, and without the visibility gate it never
# dies at all. Each half is turned off here and the matching KA check must flip.
homeAG, archAG = make_home("AG")
mpath, ok = mutant("  kaTimer = setInterval(ping, __KA__ * 1000);\n",
                   "  // MUTATED: the page never pings\n", "noping")
check("J23 the page's keepalive timer is one line in pervio-view", ok)
if NODE:
    infoAG, procAG = launch_bin(mpath, homeAG, ["--dir", archAG, "--latest",
                                                "--idle", "4"])
    if isinstance(infoAG, dict):
        _, pgAG, _ = http(infoAG["url"])
        callsAG, errAG = drive_page("noping", infoAG, pgAG, "visible:8")
        check("J23b without the page's timer a VISIBLE page sends nothing and the "
              "reader dies under the reader again (KA8's assertion goes RED)",
              callsAG == [] and not ps_alive(infoAG["pid"]), (callsAG, errAG))
        reap(infoAG["pid"], procAG)
    else:
        check("J23b no-ping mutant started", False, "mutant did not start")
        reap(None, procAG)

homeAH, archAH = make_home("AH")
mpath, ok = mutant("    if (document.visibilityState !== 'visible') return;\n",
                   "    if (false) return;  // MUTATED: visibility gate off\n",
                   "novis")
check("J24 the visibility gate is one line in pervio-view", ok)
if NODE:
    infoAH, procAH = launch_bin(mpath, homeAH, ["--dir", archAH, "--latest",
                                                "--idle", "4"])
    if isinstance(infoAH, dict):
        _, pgAH, _ = http(infoAH["url"])
        callsAH, errAH = drive_page("novis", infoAH, pgAH, "hidden:8")
        check("J24b without the gate a HIDDEN page keeps pinging and the reader "
              "never exits (KA9/KA10's assertions go RED)",
              callsAH and ps_alive(infoAH["pid"]), (callsAH, errAH))
        reap(infoAH["pid"], procAH)
    else:
        check("J24b no-visibility-gate mutant started", False, "mutant did not start")
        reap(None, procAH)

# The keepalive is only safe because the clock is moved AFTER the token is
# checked. Move it one line earlier and a knock from anything on the box — or
# from any website, through a browser's no-cors GET — keeps the reader alive.
homeAI, archAI = make_home("AI")
mpath, ok = mutant('        if not hmac.compare_digest(got, TOKEN):\n'
                   '            self._err(403, "forbidden")\n'
                   '            return False\n'
                   '        LAST[0] = time.time()\n',
                   '        LAST[0] = time.time()  # MUTATED: clock before token\n'
                   '        if not hmac.compare_digest(got, TOKEN):\n'
                   '            self._err(403, "forbidden")\n'
                   '            return False\n', "clockfirst")
check("J25 the idle clock is touched in exactly one place, after the token", ok)
infoAI, procAI = launch_bin(mpath, homeAI, ["--dir", archAI, "--latest", "--idle", "4"])
if isinstance(infoAI, dict):
    pAI = Pinger(base_of(infoAI), "", every=0.4)
    pAI.start()
    time.sleep(9)
    aliveAI = ps_alive(infoAI["pid"])
    codesAI = list(pAI.codes)
    pAI.stop()
    check("J25b with the clock moved first, tokenless knocks keep the reader "
          "alive forever (KA7's assertion goes RED)",
          aliveAI and set(codesAI) == {403}, (aliveAI, sorted(set(codesAI))))
    reap(infoAI["pid"], procAI)
else:
    check("J25b clock-before-token mutant started", False, "mutant did not start")
    reap(None, procAI)

# And the ceiling: with the deadline dropped from the watchdog, the same unbroken
# keepalive that KA13 watched lose to it now wins.
homeAJ, archAJ = make_home("AJ")
mpath, ok = mutant(
    "if now >= deadline or (INFLIGHT[0] == 0 and now - LAST[0] >= idle):",
    "if INFLIGHT[0] == 0 and now - LAST[0] >= idle:  # MUTATED: no ceiling",
    "nocap", also=(("HARD_CAP = 3600", "HARD_CAP = 8"),))
check("J26 the watchdog's ceiling check is one line in pervio-view", ok)
infoAJ, procAJ = launch_bin(mpath, homeAJ, ["--dir", archAJ, "--latest", "--idle", "3"])
if isinstance(infoAJ, dict):
    pAJ = Pinger(base_of(infoAJ), token_of(infoAJ), every=0.4)
    pAJ.start()
    time.sleep(12)                    # 1.5x the shrunk ceiling KA13 died at
    aliveAJ = ps_alive(infoAJ["pid"])
    codesAJ = list(pAJ.codes)
    pAJ.stop()
    check("J26b without the ceiling the keepalive really would run forever "
          "(KA13's assertion goes RED)",
          aliveAJ and codesAJ.count(200) >= 20, (aliveAJ, codesAJ.count(200)))
    reap(infoAJ["pid"], procAJ)
else:
    check("J26b no-ceiling mutant started", False, "mutant did not start")
    reap(None, procAJ)

homeAL, archAL = make_home("AL")
mpath, ok = mutant("  function kaMissed(){ if (++kaMiss >= 3) kaStop(); }\n",
                   "  function kaMissed(){ }  // MUTATED: never gives up\n", "nogiveup")
check("J28 the keepalive's give-up is one line in pervio-view", ok)
if NODE:
    infoAL, procAL = launch_bin(mpath, homeAL, ["--dir", archAL, "--latest",
                                                "--idle", "3"])
    if isinstance(infoAL, dict):
        _, pgAL, _ = http(infoAL["url"])
        reap(infoAL["pid"], procAL)
        callsAL, errAL = drive_page("nogiveup", infoAL, pgAL, "visible:8")
        check("J28b without it the orphaned tab keeps knocking on the dead port "
              "for as long as it is open (KA10c's assertion goes RED)",
              callsAL is not None and len(callsAL) >= 6, (callsAL, errAL))
    else:
        check("J28b never-gives-up mutant started", False, "mutant did not start")
        reap(None, procAL)

homeAK, archAK = make_home("AK")
mpath, ok = mutant('        if path == "/alive":\n',
                   '        if False:  # MUTATED: no keepalive route\n', "noroute")
check("J27 the keepalive route is one line in pervio-view", ok)
infoAK, procAK = launch_bin(mpath, homeAK, ["--dir", archAK, "--latest", "--idle", "60"])
if isinstance(infoAK, dict):
    st, body, _ = http("%s/alive?t=%s" % (base_of(infoAK), token_of(infoAK)))
    check("J27b with the route gone the keepalive is a 404 (KA1's assertion goes "
          "RED)", st == 404, (st, body[:160]))
    reap(infoAK["pid"], procAK)
else:
    check("J27b no-route mutant started", False, "mutant did not start")
    reap(None, procAK)

# =============================================================================
print("=== K: teardown — nothing this suite started may survive it ===")
for p in PROCS:
    try:
        if p.poll() is None:
            p.kill()
            p.wait(timeout=5)
    except Exception:
        pass
for pid in set(STARTED):
    if ps_alive(pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        wait_gone(pid, 5)
leftovers = [pid for pid in set(STARTED) if ps_alive(pid)]
check("K1 every pid this suite launched is gone", not leftovers,
      [(pid, ps_cmd(pid)) for pid in leftovers])
# Scoped to THIS run, never machine-global: every process this suite starts has
# ROOT (a fresh mkdtemp path) somewhere in its argv — the server through --dir,
# the mutants through their own path, the helper tools through theirs. A global
# `pgrep -f pervio-view` would instead turn red for an editor, a grep or another
# agent that merely has the string on its command line.
sweep = subprocess.run(["pgrep", "-f", ROOT], capture_output=True, text=True)
stray = [ln for ln in (sweep.stdout or "").split()
         if ln.strip().isdigit() and int(ln) != os.getpid()]
check("K2 no process carrying this run's marker (%s) survives the suite" % ROOT,
      not stray, [(s, ps_cmd(int(s))) for s in stray])
# X1: the net, in two halves, both read HERE — after every process this suite
# started is dead, so nothing can still be raising while we look.
#   K3  the suite-wide fake: a row means something opened a window where no
#       assertion was watching at all — the exact shape of the 2026-08-07 incident.
#   K3b the per-scenario fakes. Those sit in FRONT of the suite-wide one, so their
#       rows never reach K3, and each scenario read its log exactly once, early.
#       Anything raised after that read — a second window, a raise queued behind
#       the JSON line, an idle-exit that opens something — was invisible to the
#       whole file. Now every scenario's log must still equal what its scenario
#       asserted on, re-read at the end of the run.
check("K3 nothing fell through to the suite-wide `open` net "
      "(no unaudited window, ever)", open_rows(NOOPEN_LOG) == [],
      open_rows(NOOPEN_LOG))
late = [(tag, "asserted=%r" % (seen,), "now=%r" % (open_rows(log),))
        for tag, log, seen in OPEN_LOGS if open_rows(log) != seen]
check("K3b every per-scenario `open` log is inside the net too — none grew a row "
      "after its assertion (%d logs re-read post-teardown)" % len(OPEN_LOGS),
      not late, late)

shutil.rmtree(ROOT, ignore_errors=True)
ok = all(results)
print("\n=== pervio-view: %s (%d/%d) ==="
      % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
