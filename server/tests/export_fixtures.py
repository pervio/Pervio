#!/usr/bin/env python3
"""Export the iOS decoding fixtures by RUNNING the repo's REAL server scripts.

    python3 server/tests/export_fixtures.py            # (re)write ios/Tests/Fixtures/*.json
    python3 server/tests/export_fixtures.py --check     # fail if the committed fixtures are stale

Every file in ios/Tests/Fixtures is the verbatim stdout of one server command —
nothing here is hand-written JSON. What IS hand-built is the *input state* each
command reads (session .jsonl files, template files, run dirs …), exactly like
server/tests/test_sessions.py and test_run.py build theirs; the fixture is what
the real script makes of that state. ios/Tests/Fixtures/README.md records the
exact command behind every file.

Hermetic: everything happens in a throwaway $HOME under $TMPDIR. The production
~/.pervio and ~/.claude are never read or written (the scripts resolve every path
from $HOME, and nothing here passes an absolute production path).

Two boundaries the sandbox cannot reproduce, both stubbed at the boundary only —
the script's own logic still produces the bytes:
  * `pervio-sessions usage` calls api.anthropic.com. urllib.request.urlopen is
    replaced with one that answers a canned copy of that endpoint's response
    shape; cmd_usage's own reshaping (five_hour/seven_day picking, the
    limits→scoped mapping) is what writes the fixture.
  * nothing else. In particular the fs-browser fixtures run the SAME embedded
    python that ios/Sources/Services/SSHService.swift ships to the server, via
    the SAME `printf … | base64 -d | python3 -` wire command the app builds —
    the script text is EXTRACTED from the Swift source, so a change there
    changes the fixtures.

Determinism (the --check mode diffs byte-for-byte, so every volatile input is
pinned): file mtimes are set explicitly, `now` is injected via PERVIO_TICK_NOW,
TZ=UTC pins the schedule clock and the tz field, and run/schedule ids are fixed.
Only two textual normalizations are applied to raw stdout, both unavoidable and
both applied identically on every run:
  1. the throwaway $HOME path        → /home/pervio
  2. the uuid4 hex of an uploads doc → 32 zeros
"""
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.realpath(os.path.join(HERE, "..", ".."))
BIN = os.path.join(REPO, "server", "bin")
SESSIONS = os.path.join(BIN, "pervio-sessions")
ORCH = os.path.join(BIN, "pervio-orchestrate")
PRUN = os.path.join(BIN, "pervio-run")
SWIFT_SSH = os.path.join(REPO, "ios", "Sources", "Services", "SSHService.swift")
FIXTURES = os.path.join(REPO, "ios", "Tests", "Fixtures")
PY = sys.executable or "python3"

HOME_TOKEN = "/home/pervio"
UUID_TOKEN = "0" * 32
# 2026-08-01T00:00:00Z and friends — every mtime/epoch in a fixture is one of these.
BASE = 1785542400
NOW_ISO = "2026-08-01T09:00"          # PERVIO_TICK_NOW for the schedule clock

PROJECT_ROOT = "/home/pervio"         # the entry's default folder: its own chats + the projects beneath
PROJECT_A = "/home/pervio/app"        # logical cwd keys; they need not exist on disk
PROJECT_B = "/home/pervio/notes"
SESSION_A = "1a2b3c4d-0000-4000-8000-00000000aaaa"
SESSION_B = "1a2b3c4d-0000-4000-8000-00000000bbbb"
CODEX_THREAD = "0199c0de-0000-4000-8000-00000000cccc"

# What every fixture is, in order — mirrored into README.md.
PROVENANCE = []


# ---------------------------------------------------------------- utilities

def run(cmd, home, extra_env=None, cwd=None):
    """Run a server script in the sandbox and return its stdout, or die loudly."""
    env = dict(os.environ, HOME=home, TZ="UTC")
    env.pop("PERVIO_TICK_NOW", None)
    if extra_env:
        env.update(extra_env)
    p = subprocess.run(cmd, env=env, cwd=cwd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit("FAILED (%d): %s\n%s" % (p.returncode, " ".join(cmd), p.stderr[:2000]))
    return p.stdout


def normalize(text, home):
    text = text.replace(home, HOME_TOKEN)
    # ~/.pervio/uploads/<uuid4 hex>-<name>.md — the only random id in any output.
    return re.sub(r"/uploads/[0-9a-f]{32}-", "/uploads/%s-" % UUID_TOKEN, text)


def emit(name, raw, home, command, note=""):
    """Store one command's stdout as a fixture — VERBATIM, byte for byte (after
    the two documented normalizations). It is only parsed here to fail loudly if
    a script ever prints something that isn't JSON."""
    body = normalize(raw, home)
    json.loads(body)
    PROVENANCE.append((name, command, note))
    return name, body


def writelines(path, objs):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for o in objs:
            f.write((o if isinstance(o, str) else json.dumps(o, ensure_ascii=False)) + "\n")


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, ensure_ascii=False)


def touch(path, when):
    os.utime(path, (when, when))


def encode_proj(directory):
    """pervio-sessions' own project-folder encoding — loaded from the script
    itself, so a change to it can never leave these fixtures pointing at a
    folder the server would no longer look in."""
    import importlib.machinery
    import importlib.util
    loader = importlib.machinery.SourceFileLoader("psess_encode", SESSIONS)
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("psess_encode", loader))
    loader.exec_module(mod)
    return mod.encode(directory)


# ------------------------------------------------------- the embedded fs script

def embedded_fs_script():
    """The python that SSHService.swift ships to the server, extracted verbatim
    from the Swift extended-delimiter literal (so the fixtures track the app)."""
    src = open(SWIFT_SSH, encoding="utf-8").read()
    head = 'private static let serverFsScript = #"""'
    i = src.index(head) + len(head)
    j = src.index('"""#', i)
    body = src[i:j]
    lines = body.split("\n")[1:]              # drop the newline after the opener
    indent = len(lines[-1]) - len(lines[-1].lstrip(" ")) if lines else 0
    return "\n".join(l[indent:] if l.startswith(" " * indent) else l for l in lines)


def fs_command(sub, path):
    """The EXACT wire command SSHService.serverFsCommand(_:path:) builds."""
    b64 = base64.b64encode(embedded_fs_script().encode("utf-8")).decode()
    quoted = "'" + path.replace("'", "'\\''") + "'"
    return "printf '%%s' %s | base64 -d | python3 - %s %s" % (b64, sub, quoted)


def fs_run(sub, path, home):
    return run(["bash", "-c", fs_command(sub, path)], home)


# ------------------------------------------------------------------ the state


def seed_sessions(home):
    """~/.claude/projects + ~/.codex/sessions: two Claude projects and one codex
    rollout, with the shapes pervio-sessions parses (thinking/tool_use/tool_result,
    an ai-title line, an <ide_context> wrapper, and one CORRUPT line — a real
    session file that got a half-written line must still list and transcribe)."""
    proj_a = os.path.join(home, ".claude", "projects", encode_proj(PROJECT_A))
    fp_a = os.path.join(proj_a, SESSION_A + ".jsonl")
    writelines(fp_a, [
        {"type": "user", "cwd": PROJECT_A, "uuid": "u-1",
         "message": {"content": "帮我把 Pervio 的登录流程理一遍"}},
        {"type": "assistant", "message": {"content": [
            {"type": "thinking", "thinking": "先看 ServerProfile 再看 Keychain"},
            {"type": "text", "text": "我先读一下相关文件。"}],
            "model": "claude-opus-5",
            "usage": {"input_tokens": 1200, "cache_read_input_tokens": 800,
                      "cache_creation_input_tokens": 64}}},
        {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": "toolu_01", "name": "Edit",
             "input": {"file_path": PROJECT_A + "/Sources/Login.swift",
                       "old_string": "let x = 1", "new_string": "let x = 2"}}]}},
        {"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": "toolu_01", "content": "ok"}]}},
        "{ this line is truncated json",                     # corrupt line, skipped
        {"type": "assistant", "message": {"content": [
            {"type": "text", "text": "登录流程:配置 → Keychain → SSH 连接。"}]}},
        {"type": "user", "message": {"content": "<ide_context>noise</ide_context>"}},
        {"type": "user", "uuid": "u-2", "message": {"content": "再讲讲 pervio 的后台运行"}},
        {"type": "ai-title", "aiTitle": "Pervio login flow"},
    ])
    touch(fp_a, BASE + 7200)

    fp_a2 = os.path.join(proj_a, SESSION_B + ".jsonl")
    writelines(fp_a2, [
        {"type": "user", "cwd": PROJECT_A, "message": {"content": "hi"}},
        {"type": "user", "message": {"content": "跑一下 pervio 的测试套件"}},
        {"type": "assistant", "message": {"content": [{"type": "text", "text": "好的。"}]}},
    ])
    touch(fp_a2, BASE + 3600)

    # A chat held directly in the default folder (the parent of both projects):
    # the home page's "recent" block lists these, never the projects' own.
    proj_root = os.path.join(home, ".claude", "projects", encode_proj(PROJECT_ROOT))
    fp_root = os.path.join(proj_root, "3c3c3c3c-0000-4000-8000-00000000eeee.jsonl")
    writelines(fp_root, [
        {"type": "user", "cwd": PROJECT_ROOT, "message": {"content": "随手问一句:今天天气如何"}},
        {"type": "assistant", "message": {"content": [{"type": "text", "text": "晴。"}]}},
    ])
    touch(fp_root, BASE + 300)

    proj_b = os.path.join(home, ".claude", "projects", encode_proj(PROJECT_B))
    fp_b = os.path.join(proj_b, "2b2b2b2b-0000-4000-8000-00000000dddd.jsonl")
    writelines(fp_b, [
        {"type": "user", "cwd": PROJECT_B, "message": {"content": "整理今天的会议纪要"}},
        {"type": "assistant", "message": {"content": [{"type": "text", "text": "已整理。"}]}},
    ])
    touch(fp_b, BASE + 600)

    roll = os.path.join(home, ".codex", "sessions", "2026", "08", "01",
                        "rollout-2026-08-01T09-00-00-%s.jsonl" % CODEX_THREAD)
    writelines(roll, [
        {"type": "session_meta", "payload": {"id": CODEX_THREAD, "cwd": PROJECT_A}},
        {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [
            {"type": "input_text", "text": "<environment_context>cwd</environment_context>"}]}},
        {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [
            {"type": "input_text", "text": "codex 也看看 pervio 的连接层"}]}},
        {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [
            {"type": "output_text", "text": "看完了,连接层没问题。"}]}},
    ])
    touch(roll, BASE + 1800)
    # Directory mtimes don't feed any output, but pin them anyway so a stray
    # `find`-style change can't leak into a future field.
    for d in (proj_a, proj_b, proj_root, os.path.dirname(roll)):
        touch(d, BASE)


DIGEST_SPEC = {
    "name": "每日晨报",
    "dir": "~",
    "display": {"archiveDir": "~/.pervio/archives/daily-brief",
                "collapseSections": ["原始数据"]},
    "actions": [{"match": r"arXiv:(\d{4}\.\d{5})", "menu": ["精读", "存档"],
                 "run": "pervio-arxiv-fetch --id {1} --mode {choice}"}],
    "steps": [
        {"id": "fetch", "backend": "claude", "prompt": "抓取今天的论文",
         "command": "pervio-arxiv-fetch --since 1d"},
        {"id": "write", "backend": "claude", "prompt": "把 {{fetch.output}} 写成晨报",
         "dependsOn": ["fetch"], "perm": "acceptEdits"},
    ],
}

REVIEW_SPEC = {
    "name": "code review",
    "dir": "~/app",
    "steps": [
        {"id": "scan", "backend": "codex", "prompt": "扫一遍改动", "sandbox": "read-only",
         "model": "gpt-5.6-codex", "effort": "high"},
        {"id": "report", "backend": "claude", "prompt": "汇总 {{scan.output}}",
         "dependsOn": ["scan"], "publish": "~/.pervio/archives/reviews",
         "verify": "bash server/tests/run_all.sh"},
    ],
}


def seed_templates(home):
    """~/.pervio/templates: a bare spec, a market wrapper, a playbook, and a
    broken file (listed WITH its error, never hidden)."""
    tpl = os.path.join(home, ".pervio", "templates")
    os.makedirs(tpl, exist_ok=True)
    write_json(os.path.join(tpl, "daily-brief.json"), DIGEST_SPEC)
    write_json(os.path.join(tpl, "code-review.json"),
               {"name": "代码评审", "summary": "codex 扫 + claude 汇总,结果归档。",
                "spec": REVIEW_SPEC})
    write_json(os.path.join(tpl, "debug-playbook.json"), {
        "kind": "playbook", "name": "抓虫剧本",
        "summary": "先证红再修绿的固定流程。",
        "body": "# 抓虫\n\n1. 先写出让缺陷失败的测试\n2. 粘红\n3. 最小修复\n4. 粘绿\n",
    })
    with open(os.path.join(tpl, "broken.json"), "w") as f:
        f.write("{ this is not valid json")
    for name, when in (("daily-brief.json", BASE + 5000),
                       ("code-review.json", BASE + 4000),
                       ("debug-playbook.json", BASE + 3000),
                       ("broken.json", BASE + 2000)):
        touch(os.path.join(tpl, name), when)


def seed_schedule(home):
    """One REAL `schedule add` (its arming/nextDue math is the point), then the
    two volatile fields the record keeps — the uuid id and createdAt — are pinned
    so the listing is byte-stable. The archive dir gets two dated issues and the
    schedule is pointed at a finished workflow ledger, so `archives list` has a
    complete schedule join to report."""
    payload = {"name": "每日晨报", "time": "06:30", "keepRuns": 7, "spec": DIGEST_SPEC}
    b64 = base64.b64encode(json.dumps(payload).encode()).decode()
    out = run([PY, ORCH, "schedule", "add", "--b64", b64], home,
              {"PERVIO_TICK_NOW": NOW_ISO, "PERVIO_SCHED_HOOK": "skip"})
    sid = json.loads(out)["id"]
    sched_root = os.path.join(home, ".pervio", "schedules")
    fixed = "5ced0000a11e"
    os.rename(os.path.join(sched_root, sid), os.path.join(sched_root, fixed))
    rec_path = os.path.join(sched_root, fixed, "schedule.json")
    rec = json.load(open(rec_path))
    rec.update({"id": fixed, "createdAt": BASE, "lastFiredAt": BASE + 23400,
                "lastWfId": "wf0000000001"})
    write_json(rec_path, rec)

    # The workflow that schedule last fired — _last_status reads its ledger.
    write_json(os.path.join(home, ".pervio", "wf", "wf0000000001", "ledger.json"), {
        "wfId": "wf0000000001", "name": "每日晨报", "dir": "~", "status": "done",
        "startedAt": BASE + 23400, "scheduleId": fixed,
        "steps": [{"id": "fetch", "backend": "claude", "status": "done",
                   "output": "3 篇", "error": "", "bytes": 4, "command": True,
                   "dependsOn": [], "inputs": []},
                  {"id": "write", "backend": "claude", "status": "done",
                   "output": "# 晨报\n\n## 原始数据\narXiv:2508.01234", "error": "",
                   "bytes": 36, "dependsOn": ["fetch"], "inputs": ["fetch"]}],
    })

    arch = os.path.join(home, ".pervio", "archives", "daily-brief")
    os.makedirs(arch, exist_ok=True)
    for name, when in (("2026-08-01.md", BASE + 23400), ("2026-07-31.md", BASE - 63000)):
        p = os.path.join(arch, name)
        with open(p, "w") as f:
            f.write("# 晨报 %s\n\n## 原始数据\narXiv:2508.01234\n" % name[:-3])
        touch(p, when)
    reviews = os.path.join(home, ".pervio", "archives", "reviews")
    os.makedirs(reviews, exist_ok=True)
    p = os.path.join(reviews, "2026-07-30.md")
    with open(p, "w") as f:
        f.write("# 评审 2026-07-30\n")
    touch(p, BASE - 150000)


RUN_STREAM = [
    {"type": "system", "subtype": "init", "session_id": SESSION_A},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "在跑了。"}]}},
    {"type": "result", "subtype": "success", "is_error": False,
     "session_id": SESSION_A, "result": "跑完了。"},
]


def seed_runs(home):
    """~/.pervio/runs: one finished, one live, one failed — seeded like
    server/tests/test_run.py seeds its runs, then listed by the real script.
    The live row's pgid is THIS process, which is what makes `list` report
    "running" without leaving a stray child behind."""
    root = os.path.join(home, ".pervio", "runs")
    rows = [
        ("a10000000001", "exited:0", RUN_STREAM, BASE + 23400, "整理今天的论文", "", 0),
        ("a10000000002", "running", RUN_STREAM[:2], BASE + 25200, "跑一遍回归测试", "codex",
         os.getpid()),
        ("a10000000003", "exited:1", RUN_STREAM[:1], BASE + 21600, "重构连接层", "", 0),
    ]
    for rid, status, stream, started, preview, backend, pgid in rows:
        rd = os.path.join(root, rid)
        os.makedirs(rd, exist_ok=True)
        write_json(os.path.join(rd, "meta.json"), {
            "runId": rid, "dir": "~", "resume": "", "perm": "default", "model": "",
            "effort": "", "backend": backend, "started": started, "preview": preview})
        with open(os.path.join(rd, "status"), "w") as f:
            f.write(status)
        writelines(os.path.join(rd, "out.jsonl"), stream)
        with open(os.path.join(rd, "pgid"), "w") as f:
            f.write(str(pgid))
        touch(rd, started)


# The api.anthropic.com/api/oauth/usage response SHAPE (values are made up; the
# `limits` entry mirrors the model-scoped pool observed live on 2026-08-06 —
# see cmd_usage's own comment). pervio-sessions turns this into the fixture.
USAGE_ENDPOINT_PAYLOAD = {
    "five_hour": {"utilization": 37.5, "resets_at": "2026-08-01T12:00:00Z"},
    "seven_day": {"utilization": 51.0, "resets_at": "2026-08-05T00:00:00Z"},
    "limits": [
        {"type": "weekly_scoped", "percent": 91.0, "severity": "critical",
         "resets_at": "2026-08-04T00:00:00Z",
         "scope": {"model": {"display_name": "Fable"}}},
        {"type": "weekly", "percent": 51.0, "severity": "ok"},
    ],
}

USAGE_DRIVER = '''\
import importlib.machinery, importlib.util, json, sys, urllib.request
sessions, payload = sys.argv[1], json.loads(sys.argv[2])
loader = importlib.machinery.SourceFileLoader("psess", sessions)
psess = importlib.util.module_from_spec(importlib.util.spec_from_loader("psess", loader))
loader.exec_module(psess)


class Resp:                       # just enough of http.client.HTTPResponse
    def __init__(self, body):
        self.body = body

    def read(self, *a):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


urllib.request.urlopen = lambda req, timeout=None: Resp(json.dumps(payload).encode())
psess.cmd_usage()
'''


def usage_fixture(home):
    """`pervio-sessions usage` with ONLY the network boundary stubbed."""
    write_json(os.path.join(home, ".claude", ".credentials.json"),
               {"claudeAiOauth": {"accessToken": "sk-ant-oat-FAKE-SANDBOX-TOKEN"}})
    driver = os.path.join(home, "usage_driver.py")
    with open(driver, "w") as f:
        f.write(USAGE_DRIVER)
    return run([PY, driver, SESSIONS, json.dumps(USAGE_ENDPOINT_PAYLOAD)], home)


def seed_browse(home):
    """$HOME/browse for the fs-browser fixtures: a directory, ordinary text, a
    hidden file, and names that are hostile to a JSON/markdown pipeline — CJK +
    spaces, a quote/bracket name, a name with an embedded newline, and one whose
    real name CONTAINS U+FFFD (a legal filename character — proof the listing's
    replacement char is not by itself a marker of a mangled name)."""
    d = os.path.join(home, "browse")
    sub = os.path.join(d, "docs")
    os.makedirs(sub, exist_ok=True)
    files = [
        ("notes.md", "# 笔记\n\n这是一份普通的 UTF-8 文本。\n", BASE + 20000),
        (".hidden.env", "TOKEN=xxx\n", BASE + 19000),
        ("设计 稿 v2.md", "# 设计稿\n", BASE + 18000),
        ("it's [a] tricky.md", "tricky\n", BASE + 17000),
        ("two\nline.md", "newline in the name\n", BASE + 16000),
        ("replacement-�-name.md", "the name really contains U+FFFD\n", BASE + 15000),
    ]
    for name, body, when in files:
        p = os.path.join(d, name)
        with open(p, "w", encoding="utf-8") as f:
            f.write(body)
        touch(p, when)
    p = os.path.join(sub, "readme.md")
    with open(p, "w") as f:
        f.write("nested\n")
    touch(p, BASE + 14000)
    with open(os.path.join(d, "photo.bin"), "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n\x00\x00\x00binary")
    touch(os.path.join(d, "photo.bin"), BASE + 13000)
    touch(sub, BASE + 14000)
    touch(d, BASE + 20000)
    return d


# ------------------------------------------------------------------- the export

def export(home):
    """Build the state, run every command, return [(fixture name, bytes)]."""
    seed_sessions(home)
    seed_templates(home)
    seed_schedule(home)
    seed_runs(home)
    browse = seed_browse(home)
    sched_env = {"PERVIO_TICK_NOW": NOW_ISO, "PERVIO_SCHED_HOOK": "skip"}
    out = []

    def add(name, raw, command, note=""):
        out.append(emit(name, raw, home, command, note))

    add("projects", run([PY, SESSIONS, "projects"], home),
        "pervio-sessions projects")
    add("home", run([PY, SESSIONS, "home", "--dir", PROJECT_ROOT, "--top", "3", "--per", "3", "--limit", "10"], home),
        "pervio-sessions home --dir %s --top 3 --per 3 --limit 10" % PROJECT_ROOT,
        "the folders under the default folder (itself excluded), each with its newest rows, + the default folder's own chats")
    add("sessions-list", run([PY, SESSIONS, "list", "--dir", PROJECT_A], home),
        "pervio-sessions list --dir %s" % PROJECT_A,
        "two claude sessions + one codex thread for the same cwd")
    add("transcript", run([PY, SESSIONS, "transcript", "--dir", PROJECT_A,
                           "--session", SESSION_A], home),
        "pervio-sessions transcript --dir %s --session %s" % (PROJECT_A, SESSION_A))
    add("search", run([PY, SESSIONS, "search", "--query", "pervio", "--limit", "30"], home),
        "pervio-sessions search --query pervio --limit 30",
        "cross-project, claude + codex")
    add("usage", usage_fixture(home),
        "pervio-sessions usage",
        "urlopen stubbed with the endpoint's response shape; scoped pool included")
    add("templates", run([PY, ORCH, "templates", "list"], home),
        "pervio-orchestrate templates list",
        "bare spec + market wrapper + playbook + a broken file")
    add("archives", run([PY, ORCH, "archives", "list"], home, sched_env),
        "pervio-orchestrate archives list",
        "schedule-sourced publication (with the schedule join) + a publish-step one")
    add("schedules", run([PY, ORCH, "schedule", "list"], home, sched_env),
        "pervio-orchestrate schedule list",
        "PERVIO_TICK_NOW=%s, TZ=UTC" % NOW_ISO)
    add("runs-list", run([PY, PRUN, "list"], home),
        "pervio-run list",
        "one done, one running, one failed")
    add("serverfs-ls", fs_run("ls", browse, home),
        "SSHService.serverFsScript: ls <dir>",
        "the app's own wire command over the embedded script")
    add("serverfs-ls-missing", fs_run("ls", os.path.join(browse, "nope"), home),
        "SSHService.serverFsScript: ls <missing path>",
        "in-band {\"error\": …}, not a thrown connection failure")
    add("serverfs-file", fs_run("file", os.path.join(browse, "notes.md"), home),
        "SSHService.serverFsScript: file <text file>")
    add("serverfs-file-fffd", fs_run("file", os.path.join(browse, "replacement-�-name.md"), home),
        "SSHService.serverFsScript: file <name containing U+FFFD>",
        "a REAL U+FFFD in the name — addressable; see the R12 note in DecodingTests")
    add("serverfs-file-binary", fs_run("file", os.path.join(browse, "photo.bin"), home),
        "SSHService.serverFsScript: file <binary file>",
        "in-band {\"error\": \"binary\"}")
    return out


README_HEAD = """# ios/Tests/Fixtures

Generated — do NOT edit by hand.

    python3 server/tests/export_fixtures.py

Every *.json here is the verbatim stdout of one real server command, run against
a throwaway $HOME built by that script (see its header for the two normalizations
and the single stubbed boundary). `bash server/tests/run_all.sh` re-exports and
fails if anything drifted, so a server-side shape change shows up as a red test
instead of a silently stale fixture.

| fixture | produced by | notes |
| --- | --- | --- |
"""


def readme(files):
    import datetime
    rows = "".join("| `%s.json` | `%s` | %s |\n" % (n, c, note) for n, c, note in PROVENANCE)
    return README_HEAD + rows + (
        "\nLast regenerated: %s (informational — the freshness check compares the "
        "*.json fixtures only).\n" % datetime.date.today().isoformat())


def main():
    check = "--check" in sys.argv[1:]
    home = os.path.realpath(tempfile.mkdtemp(prefix="pervio-fixtures-"))
    try:
        files = export(home)
    finally:
        shutil.rmtree(home, ignore_errors=True)

    if check:
        stale = []
        for name, body in files:
            path = os.path.join(FIXTURES, name + ".json")
            try:
                have = open(path, encoding="utf-8").read()
            except OSError:
                have = None
            if have != body:
                stale.append(name + ".json" + ("" if have is not None else " (missing)"))
        if stale:
            print("FAIL fixtures are stale (server output no longer matches):")
            for s in stale:
                print("   - ios/Tests/Fixtures/" + s)
            print("Re-run:  python3 server/tests/export_fixtures.py"
                  "   then re-run the iOS decoding tests.")
            return 1
        print("PASS %d fixtures match the live server output" % len(files))
        return 0

    os.makedirs(FIXTURES, exist_ok=True)
    for name, body in files:
        with open(os.path.join(FIXTURES, name + ".json"), "w", encoding="utf-8") as f:
            f.write(body)
    with open(os.path.join(FIXTURES, "README.md"), "w", encoding="utf-8") as f:
        f.write(readme(files))
    print("wrote %d fixtures to %s" % (len(files), os.path.relpath(FIXTURES, REPO)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
