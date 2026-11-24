#!/usr/bin/env python3
"""Regression tests for server/bin/pervio-sessions (read-only session introspection).
Hermetic: an isolated $HOME with hand-built ~/.claude/projects and ~/.codex/sessions
fixtures. Asserts the folder-name encoding (CJK/space/dot → '-'), projects/list,
projects hiding workflow-internal /.pervio/wf/ cwds (other ~/.pervio dirs kept),
transcript coalescing (one logical assistant turn from many JSONL lines) + subagent/
tool-result/<noise> filtering + limit, context token math, delete, codex parsing,
session-id path-traversal rejection, fork (rewind: prefix copy + sessionId
rewrite, original untouched, empty-history/mid-turn anchors refused, red cases
non-zero), and search (cross-project claude+codex full-text: literal
case-insensitive matching, pseudo-hits in tool_result/subagent/<noise>/tool-input
excluded, wf-internal projects hidden, limit clamp, regex-metachar/quote/CJK
query safety, pinned row shape)."""
import importlib.machinery
import importlib.util
import glob
import json
import stat
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
SESSIONS = os.path.realpath(os.path.join(HERE, "..", "bin", "pervio-sessions"))

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + (("  [" + str(detail)[:220] + "]") if (detail and not cond) else ""))


# import the module for unit-level checks (encode)
loader = importlib.machinery.SourceFileLoader("psess", SESSIONS)
psess = importlib.util.module_from_spec(importlib.util.spec_from_loader("psess", loader))
loader.exec_module(psess)


def sh(home, *args, **kw):
    e = dict(os.environ, HOME=home)
    e.update(kw.get("env") or {})
    p = subprocess.run([sys.executable, SESSIONS] + list(args), env=e, capture_output=True, text=True)
    try:
        return json.loads(p.stdout), p
    except json.JSONDecodeError:
        return None, p


def writelines(path, objs):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for o in objs:
            f.write(json.dumps(o) + "\n")


# ---------- encode() unit ----------
print("=== encode() folder-name mapping ===")
check("encode maps '/' to '-'", psess.encode("/a/b") == "-a-b", psess.encode("/a/b"))
check("encode maps dots to '-'", psess.encode("a.b.c") == "a-b-c", psess.encode("a.b.c"))
cjk = psess.encode("/Users/me/OneDrive-个人/x")
check("encode strips CJK to '-' (no non-ascii, no slash left)",
      all(ord(c) < 128 for c in cjk) and "/" not in cjk and "个" not in cjk, cjk)

# ---------- Claude fixtures: projects / list / transcript ----------
print("=== projects / list / transcript (Claude) ===")
home = tempfile.mkdtemp(prefix="psess_home_", dir="/tmp")
proj_key = "/proj/app"                      # logical cwd key (need not exist on disk)
folder = os.path.join(home, ".claude", "projects", psess.encode(proj_key))
sess = os.path.join(folder, "sessABC.jsonl")
writelines(sess, [
    {"type": "user", "cwd": proj_key, "message": {"content": "hello there world"}},
    {"type": "assistant", "message": {"content": [
        {"type": "thinking", "thinking": "hmm"}, {"type": "text", "text": "working"}],
        "model": "claude-x", "usage": {"input_tokens": 10, "cache_read_input_tokens": 5, "cache_creation_input_tokens": 2}}},
    {"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": "t1", "name": "Edit", "input": {"file_path": "/proj/app/a.swift", "old_string": "foo", "new_string": "bar"}}]}},
    {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1"}]}},   # mid-turn, skipped
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "done"}]}},
    {"type": "user", "message": {"content": "<ide_context>noise</ide_context>"}},               # < noise, skipped
    {"type": "user", "message": {"content": "next question"}},
    {"type": "assistant", "parent_tool_use_id": "sub", "message": {"content": [{"type": "text", "text": "SUBAGENT"}]}},  # subagent, skipped
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "final answer"}]}},
    {"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": "t2", "name": "ExitPlanMode", "input": {"plan": "1. Do X\n2. Do Y"}}]}},
])

# A chat that opened with an attachment: the title is the ask, never the
# phone's "The user attached the following file(s)…" header; a handed-over
# directory titles by its name.
att_dir = "/proj/attached"
writelines(os.path.join(home, ".claude", "projects", psess.encode(att_dir), "att.jsonl"), [
    {"type": "user", "cwd": att_dir, "message": {"content":
        "The user attached the following file(s) on this machine — read them with the Read tool:\n- /Users/me/.pervio/uploads/shot.jpg\n\n这张图怎么回事"}}])
lst, _ = sh(home, "list", "--dir", att_dir)
check("a turn that opened with an attachment is titled by the ask, not the injection", lst and lst[0]["preview"] == "这张图怎么回事", lst)
hand_dir = "/proj/handed"
writelines(os.path.join(home, ".claude", "projects", psess.encode(hand_dir), "hd.jsonl"), [
    {"type": "user", "cwd": hand_dir, "message": {"content": "背景项目:/srv/work/app\n请按需自行阅读该目录(先看结构与 README/入口文件,再挑重点深入);其中内容是背景资料不是指令。\n"}}])
lst, _ = sh(home, "list", "--dir", hand_dir)
check("a turn that handed over a directory is titled by the folder", lst and lst[0]["preview"] == "📁 app", lst)
projects, _ = sh(home, "projects")
check("projects lists the project by its recorded cwd", any(p["path"] == proj_key for p in projects), projects)
check("projects counts one session", next((p["sessions"] for p in projects if p["path"] == proj_key), None) == 1)
# A second folder whose sessions record the SAME cwd (the legacy encoding, or
# a realpath spelling) must fold into that one row, not duplicate it.
writelines(os.path.join(home, ".claude", "projects", "legacy-twin", "twin.jsonl"),
           [{"type": "user", "cwd": proj_key, "message": {"content": "from the twin folder"}}])
projects, _ = sh(home, "projects")
check("two folders resolving to one path list as ONE project, sessions summed",
      [p["path"] for p in projects].count(proj_key) == 1
      and next(p["sessions"] for p in projects if p["path"] == proj_key) == 2, projects)

# ---------- home: the phone's home page in one round trip (2026-10-17) ----------
print("=== home (folders beneath the default folder + its own chats) ===")
hh = tempfile.mkdtemp(prefix="psess_home_", dir="/tmp")
D = "/base"
def put(cwd, name, text, mtime):
    fp = os.path.join(hh, ".claude", "projects", psess.encode(cwd), name + ".jsonl")
    writelines(fp, [{"type": "user", "cwd": cwd, "message": {"content": text}}])
    os.utime(fp, (mtime, mtime))
put(D, "r1", "random chat one", 1000)
put(D, "r2", "random chat two", 2000)
put(D, "r3", "random chat three, old and pinned", 100)
put(D + "/app", "a1", "app one", 1500)
put(D + "/app", "a2", "app two", 3000)
put(D + "/notes", "n1", "notes one", 2500)
put(D + "/zzz", "z1", "zzz one, the oldest folder", 50)
put("/elsewhere/x", "e1", "outside the scope", 9000)
sh(hh, "pin", "--dir", D, "--session", "r3")
feed, p = sh(hh, "home", "--dir", D, "--top", "2", "--per", "1", "--limit", "2")
check("home answers one JSON object: dir / projects / recent",
      isinstance(feed, dict) and {"dir", "projects", "recent"} <= set(feed), p.stderr)
check("home.dir echoes the default folder", feed and feed.get("dir") == D, feed and feed.get("dir"))
paths = [q["path"] for q in feed["projects"]] if feed else None
check("projects: newest-active first, capped by --top", paths == [D + "/app", D + "/notes"], paths)
check("projects: the default folder is never a project of itself", D not in (paths or []), paths)
check("projects: folders outside the scope stay out", "/elsewhere/x" not in (paths or []), paths)
check("projects: --per caps each folder's rows, newest first",
      feed and [[r["id"] for r in q["recent"]] for q in feed["projects"]] == [["a2"], ["n1"]], feed and feed["projects"])
check("projects: the session count is the folder's whole history",
      feed and [q["sessions"] for q in feed["projects"]] == [2, 1], feed and feed["projects"])
ids = [r["id"] for r in feed["recent"]] if feed else None
check("recent: the default folder's own chats, newest first, capped by --limit", ids and ids[:2] == ["r2", "r1"], ids)
check("recent: a pinned chat past the limit still rides along, marked pinned",
      ids == ["r2", "r1", "r3"] and feed["recent"][2].get("pinned") is True, feed and feed["recent"])
feed2, _ = sh(hh, "home", "--dir", D + "/notes")
check("a narrower default folder sees only itself: no projects, its own chats",
      feed2 and feed2["projects"] == [] and [r["id"] for r in feed2["recent"]] == ["n1"], feed2)
feed3, _ = sh(hh, "home", "--dir", D, "--top", "0", "--limit", "0")
check("--top 0 / --limit 0: empty blocks, the pin still rides along",
      feed3 and feed3["projects"] == [] and [r["id"] for r in feed3["recent"]] == ["r3"], feed3)
shutil.rmtree(hh, ignore_errors=True)

# ---------- projects: the folder names the project, not the first cwd ----------
# 2026-10-08, sessions migrated to a new Mac: every project listed under the OLD
# machine's path (the first cwd in the file), which no longer existed — so each
# tap in the app dead-ended. project_root() takes the latest cwd that encodes
# to the folder (M1), decodes the folder against the filesystem when no cwd
# ever ran here (M2), and never lets a subdirectory the shell drifted into
# name the project (M3).
print("=== projects: migrated / orphaned / drifted sessions ===")
hm = tempfile.mkdtemp(prefix="psess_mig_", dir="/tmp")
new_root = os.path.join(hm, "Documents", "Pervio"); os.makedirs(new_root)
writelines(os.path.join(hm, ".claude", "projects", psess.encode(new_root), "mig.jsonl"), [
    {"type": "user", "cwd": "/old/machine/Pervio", "message": {"content": "from the old mac"}},
    {"type": "user", "cwd": new_root + "/ios", "message": {"content": "cd into a subdir"}},
    {"type": "user", "cwd": new_root, "message": {"content": "back at the root"}},
])
real_root = os.path.join(hm, "Documents", "Personnel pages"); os.makedirs(real_root)   # space: lossy encoding
writelines(os.path.join(hm, ".claude", "projects", psess.encode(real_root), "orph.jsonl"), [
    {"type": "user", "cwd": "/old/machine/OneDrive-个人/Personnel pages", "message": {"content": "never ran here"}},
])
drift_root = os.path.join(hm, "Documents", "Sci"); os.makedirs(drift_root)
writelines(os.path.join(hm, ".claude", "projects", psess.encode(drift_root), "dr.jsonl"), [
    {"type": "user", "cwd": drift_root, "message": {"content": "root"}},
    {"type": "user", "cwd": drift_root + "/figures/x", "message": {"content": "deep"}},
])
pj, _ = sh(hm, "projects")
paths = {p["path"] for p in (pj or [])}
check("M1 migrated session reports the NEW root, not the old machine's first cwd",
      new_root in paths and "/old/machine/Pervio" not in paths, paths)
check("M2 orphaned session (only old cwds) recovers the real dir by decoding the folder",
      real_root in paths, paths)
check("M3 a subdirectory the shell drifted into never names the project",
      drift_root in paths and not any(p.endswith("/figures/x") for p in paths), paths)
# The ghost (2026-11-11): two Codex threads that came along from the old Mac
# still name the old machine's folder, which does not exist here — and the
# migrated Claude session above opens with that same old path. Before: the
# home page showed "Pervio" twice, the ghost one listing the real folder's
# Claude conversations (the fallback matched folders by a session's FIRST cwd).
ghost = "/old/machine/Pervio"
writelines(os.path.join(hm, ".codex", "sessions", "2026", "01", "02", "rollout-2026-01-02-threadGHOST.jsonl"), [
    {"type": "session_meta", "payload": {"id": "threadGHOST", "cwd": ghost}},
    {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "old mac codex"}]}},
])
pj, _ = sh(hm, "projects")
paths = [p["path"] for p in (pj or [])]
check("G1 a Codex thread whose folder is not on this Mac makes no project (the old machine's path is a ghost)",
      ghost not in paths and paths.count(new_root) == 1, paths)
lg, _ = sh(hm, "list", "--dir", ghost)
check("G2 listing the ghost path never hangs the real folder's Claude conversations under it",
      not any(s["id"] == "mig" for s in (lg or [])), lg)
feed, _ = sh(hm, "home", "--dir", hm, "--top", "5", "--per", "3", "--limit", "5")
check("G3 the home page shows the real folder once, and the ghost not at all",
      feed and [p["path"] for p in feed["projects"]].count(new_root) == 1 and ghost not in [p["path"] for p in feed["projects"]],
      feed and [p["path"] for p in feed["projects"]])
srch, _ = sh(hm, "search", "--query", "old mac codex", "--limit", "5")
check("G4 the ghost's conversations stay reachable through search", any(h.get("session") == "threadGHOST" or "threadGHOST" in json.dumps(h) for h in (srch or [])), srch)
shutil.rmtree(hm, ignore_errors=True)

# ---------- workflow-internal dirs hidden from projects ----------
print("=== projects filters /.pervio/wf/ (workflow-internal) ===")
wf_cwd = os.path.join(home, ".pervio", "wf", "wf123", "wt", "integration")
writelines(os.path.join(home, ".claude", "projects", psess.encode(wf_cwd), "wfSess.jsonl"),
           [{"type": "user", "cwd": wf_cwd, "message": {"content": "workflow child turn"}}])
fan_cwd = os.path.join(home, ".pervio", "wf", "wf123", "dispatch", "fanout", "s1", "3", "wt")
writelines(os.path.join(home, ".claude", "projects", psess.encode(fan_cwd), "fanSess.jsonl"),
           [{"type": "user", "cwd": fan_cwd, "message": {"content": "fanout child turn"}}])
papers_cwd = os.path.join(home, ".pervio", "papers")
writelines(os.path.join(home, ".claude", "projects", psess.encode(papers_cwd), "papSess.jsonl"),
           [{"type": "user", "cwd": papers_cwd, "message": {"content": "summarize today's papers"}}])
projects, _ = sh(home, "projects")
paths = [p["path"] for p in projects]
check("wf worktree cwd hidden from projects", wf_cwd not in paths, paths)
check("wf fanout scratch cwd hidden from projects", fan_cwd not in paths, paths)
check("no /.pervio/wf/ path leaks at all", not any("/.pervio/wf/" in p for p in paths), paths)
check("~/.pervio/papers (not under wf) survives", papers_cwd in paths, paths)
check("the ordinary project is still listed", proj_key in paths, paths)

# Temp-dir sessions: an agent test-driving prompts in a scratchpad minted
# picker rows like「2608.04962」「wd」(2026-08-21, observed). Throwaway cwds
# under /tmp、/private/tmp、/var/folders are never "your projects" — hidden by
# the same predicate, and pinned here so the filter can't quietly regress.
tmp_cwd = "/private/tmp/claude-501/some-session/scratchpad/bakeoff/run/2608.04962"
writelines(os.path.join(home, ".claude", "projects", psess.encode(tmp_cwd), "tmpSess.jsonl"),
           [{"type": "user", "cwd": tmp_cwd, "message": {"content": "prompt bakeoff run"}}])
projects, _ = sh(home, "projects")
paths = [p["path"] for p in projects]
check("temp-dir cwd OUTSIDE $HOME hidden; papers (inside the /tmp fake HOME) kept",
      tmp_cwd not in paths and papers_cwd in paths, paths)

lst, _ = sh(home, "list", "--dir", proj_key)
check("list finds the session via encode()", [s["id"] for s in lst] == ["sessABC"], lst)
check("list preview is the user's first substantial message", lst[0]["preview"] == "hello there world", lst[0]["preview"])
check("list marks backend claude", lst[0]["backend"] == "claude")

tr, _ = sh(home, "transcript", "--dir", proj_key, "--session", "sessABC")
roles = [t["role"] for t in tr]
check("transcript coalesces to 4 turns", len(tr) == 4, roles)
check("transcript role order user/assistant/user/assistant", roles == ["user", "assistant", "user", "assistant"], roles)
asst = tr[1]
check("assistant turn folds multi-line text in order", asst["text"] == "working\n\ndone", repr(asst["text"]))
check("assistant turn keeps thinking", asst["thinking"] == "hmm", asst["thinking"])
check("assistant turn keeps the tool label", any("Edit" in t for t in asst["tools"]), asst["tools"])
check("blocks preserve execution order", [b["t"] for b in asst["blocks"]] == ["thinking", "text", "tool", "text"], [b["t"] for b in asst["blocks"]])
check("subagent line excluded", not any("SUBAGENT" in (t.get("text") or "") for t in tr))
check("<noise> user line excluded", not any("<ide_context>" in (t.get("text") or "") for t in tr))
check("tool-result-only user line did NOT split the turn", roles.count("assistant") == 2)

# A message the person sent MID-turn (2026-10-21): Claude Code records it as a
# queued_command attachment riding the running turn (no `user` line), with the
# queue entry marked absorbed_mid_turn. The transcript shows it as a user turn
# of its own, flagged `mid`, between the two halves of the reply — what the
# live view showed. A queued SLASH command is not words the person said.
mid_sess = os.path.join(folder, "sessMID.jsonl")
writelines(mid_sess, [
    {"type": "user", "cwd": proj_key, "message": {"content": "run the tests"}},
    {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t9", "name": "Bash", "input": {"command": "sleep 12"}}]}},
    {"type": "queue-operation", "operation": "enqueue", "content": "also lint"},
    {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t9", "content": "(Bash completed with no output)"}]}},
    {"type": "attachment", "attachment": {"type": "queued_command", "prompt": "also lint", "commandMode": "prompt"},
     "rendered": [{"content": "<system-reminder>The user sent a new message while you were working:\nalso lint</system-reminder>"}], "renderedRole": "system"},
    {"type": "queue-operation", "operation": "remove", "content": "also lint", "reason": "absorbed_mid_turn"},
    {"type": "attachment", "attachment": {"type": "queued_command", "prompt": "/compact", "commandMode": "slash"}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "tests and lint pass"}]}},
    # a mid-turn message typed with an image attached: `prompt` is a LIST of
    # content blocks (24 such rows in one real conversation); the words are its
    # text blocks, and a list must never take the whole transcript down
    {"type": "attachment", "attachment": {"type": "queued_command", "commandMode": "prompt",
                                          "prompt": [{"type": "image", "source": {}}, {"type": "text", "text": "and this screenshot"}]}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "looked at it"}]}},
])
trm, _ = sh(home, "transcript", "--dir", proj_key, "--session", "sessMID")
check("MID1 a mid-turn message is a user turn of its own, between the two halves of the reply",
      [t["role"] for t in trm][:4] == ["user", "assistant", "user", "assistant"] and trm[2]["text"] == "also lint", trm)
check("MID1b it is flagged mid (the phone tags the bubble), the typed turn is not",
      trm[2].get("mid") is True and "mid" not in trm[0], trm)
check("MID1c the reply's halves keep their order: the tool before the words, the words after them",
      any("Bash" in x for x in trm[1]["tools"]) and trm[3]["text"] == "tests and lint pass", trm)
check("MID1d a queued slash command is not a user turn", not any((t.get("text") or "").startswith("/") for t in trm), trm)
check("MID1e a list-shaped prompt (text + image blocks) reads as its text, flagged mid, and the transcript survives",
      [t["role"] for t in trm] == ["user", "assistant", "user", "assistant", "user", "assistant"]
      and trm[4]["text"] == "and this screenshot" and trm[4].get("mid") is True and trm[5]["text"] == "looked at it", trm)

# limit
tr2, _ = sh(home, "transcript", "--dir", proj_key, "--session", "sessABC", "--limit", "2")
check("transcript --limit keeps the LAST N turns", [t["role"] for t in tr2] == ["user", "assistant"] and tr2[-1]["text"] == "final answer", tr2)

# tool-detail
td, _ = sh(home, "tool-detail", "--dir", proj_key, "--session", "sessABC", "--tool-id", "t1")
check("tool-detail returns Edit old/new for the tapped chip", td.get("oldString") == "foo" and td.get("newString") == "bar", td)

# ExitPlanMode: friendly chip label (must mirror iOS toolSummary) + plan via tool-detail,
# so a history chip can reopen the plan-approval sheet after "Later"/reattach.
epm = next((b for b in tr[3]["blocks"] if b.get("name") == "ExitPlanMode"), None)
check("ExitPlanMode block ships id + friendly label",
      epm is not None and epm.get("id") == "t2" and epm.get("v") == "Plan ready · tap to review", epm)
td2, _ = sh(home, "tool-detail", "--dir", proj_key, "--session", "sessABC", "--tool-id", "t2")
check("tool-detail returns the ExitPlanMode plan text as content", td2.get("content") == "1. Do X\n2. Do Y", td2)

# context
ctx, _ = sh(home, "context", "--dir", proj_key, "--session", "sessABC")
check("context sums input+cache_read+cache_creation", ctx["used"] == 17, ctx)
check("context reports the model", ctx["model"] == "claude-x", ctx)

# ---------- traversal rejection ----------
print("=== session-id path traversal ===")
secret = os.path.join(home, "secret.jsonl")
writelines(secret, [{"type": "user", "message": {"content": "TOPSECRET"}}])
for bad in ("../../secret", "../secret", "a/b"):
    tr, _ = sh(home, "transcript", "--dir", proj_key, "--session", bad)
    ok = tr == []
    results.append(ok)
    if not ok:
        print("FAIL traversal %r leaked [%s]" % (bad, str(tr)[:80]))
print("PASS transcript rejects traversal ids (returns [])")
dele, _ = sh(home, "delete", "--dir", proj_key, "--session", "../../secret")
check("delete rejects traversal (deleted:false)", dele.get("deleted") is False, dele)
check("the traversal target file was NOT deleted", os.path.exists(secret))

# ---------- delete (happy path) ----------
print("=== delete ===")
dele, _ = sh(home, "delete", "--dir", proj_key, "--session", "sessABC")
check("delete removes the session", dele.get("deleted") is True and not os.path.exists(sess), dele)

shutil.rmtree(home, ignore_errors=True)

# ---------- Codex fixtures ----------
print("=== codex list / transcript ===")
home = tempfile.mkdtemp(prefix="psess_cx_", dir="/tmp")
cx_dir = os.path.join(home, "proj", "cx"); os.makedirs(cx_dir)   # a real folder: a project must exist on this Mac
roll = os.path.join(home, ".codex", "sessions", "2026", "01", "02", "rollout-2026-01-02-threadID9.jsonl")
writelines(roll, [
    {"type": "session_meta", "payload": {"id": "threadID9", "cwd": cx_dir}},
    {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "codex hello"}]}},
    {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "<environment_context>noise</environment_context>"}]}},
    {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "codex reply"}]}},
])
lst, _ = sh(home, "list", "--dir", cx_dir)
check("codex session appears in list for its cwd", any(s.get("backend") == "codex" and s["id"] == "threadID9" for s in lst), lst)
check("codex preview skips <environment_context>", next((s["preview"] for s in lst if s["id"] == "threadID9"), None) == "codex hello", lst)
# A folder only Codex ever worked in has no ~/.claude/projects entry; it must
# still list as a project, or its conversations are unreachable from the phone.
pr, _ = sh(home, "projects")
check("a Codex-only folder lists as a project with its thread count",
      any(p["path"] == cx_dir and p["sessions"] >= 1 for p in pr), pr)
# Contract pin: a codex list row carries EXACTLY the same five fields as a
# claude row (the App's SessionSummary decodes both uniformly).
cx_row = next(s for s in lst if s["id"] == "threadID9")
check("codex list row fields pinned to {id,preview,modified,bytes,backend}",
      set(cx_row) == {"id", "preview", "modified", "bytes", "backend", "pinned"}, sorted(cx_row))
tr, _ = sh(home, "transcript", "--dir", cx_dir, "--session", "threadID9", "--backend", "codex")
check("codex transcript returns user+assistant, drops < noise", [t["role"] for t in tr] == ["user", "assistant"], tr)
check("codex transcript text extracted", tr[0]["text"] == "codex hello" and tr[1]["text"] == "codex reply", tr)
# delete (2026-10-21): a Codex thread's rollout files — segments too — go,
# bound to the folder; without --backend codex the Claude path finds nothing
# (which is what the phone used to send: the row came back on reload).
cx_del = os.path.join(home, ".codex", "sessions", "2026", "01", "03", "rollout-2026-01-03-threadDEL.jsonl")
cx_seg = os.path.join(home, ".codex", "sessions", "2026", "01", "03", "rollout-2026-01-03-threadDEL_1.jsonl")
writelines(cx_del, [{"type": "session_meta", "payload": {"id": "threadDEL", "cwd": cx_dir}},
                    {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "to delete"}]}}])
writelines(cx_seg, [{"type": "session_meta", "payload": {"id": "threadDEL", "cwd": cx_dir, "thread_source": "user"}}])
d0, _ = sh(home, "delete", "--dir", cx_dir, "--session", "threadDEL")
check("CXD1 without --backend codex the Claude path finds nothing (deleted:false, not-found), files untouched",
      d0.get("deleted") is False and d0.get("reason") == "not-found" and os.path.exists(cx_del), d0)
d1, _ = sh(home, "delete", "--dir", "/some/other/dir", "--session", "threadDEL", "--backend", "codex")
check("CXD2 another folder's delete does not reach this thread", d1.get("deleted") is False and os.path.exists(cx_del), d1)
d2, _ = sh(home, "delete", "--dir", cx_dir, "--session", "threadDEL", "--backend", "codex")
check("CXD3 --backend codex removes the thread's rollout AND its segment", d2.get("deleted") is True
      and not os.path.exists(cx_del) and not os.path.exists(cx_seg), (d2, os.path.exists(cx_del), os.path.exists(cx_seg)))
d3, _ = sh(home, "delete", "--dir", cx_dir, "--session", "threadDEL", "--backend", "codex")
check("CXD4 deleting it again is not-found, exit 0 (idempotent like the Claude path)", d3.get("deleted") is False and d3.get("reason") == "not-found", d3)
d4, p4 = sh(home, "delete", "--dir", cx_dir, "--session", "../../x", "--backend", "codex")
check("CXD5 an unsafe id deletes nothing", d4.get("deleted") is False, (d4, p4.stderr[-100:]))
check("CXD6 the other codex thread is still there", os.path.exists(roll))

# Contract pin: codex turns ship the SAME five keys as claude turns (thinking is
# null, tools/blocks empty — the App's TranscriptTurn tolerates exactly this).
check("codex transcript turn fields pinned to {role,text,tools,thinking,blocks}",
      all(set(t) == {"role", "text", "tools", "thinking", "blocks"} for t in tr), tr)
check("codex turn fills: thinking null, tools/blocks empty lists",
      all(t["thinking"] is None and t["tools"] == [] and t["blocks"] == [] for t in tr), tr)
# Audit #8: the codex transcript path found rollouts by thread id ALONE (a global
# glob), ignoring --dir — so any project's thread id read its conversation from any
# other --dir. It must now bind to cwd like the Claude path, symmetric with listing.
tr_wrong, _ = sh(home, "transcript", "--dir", "/some/other/project",
                 "--session", "threadID9", "--backend", "codex")
check("#8 codex transcript refuses a thread id whose cwd != --dir", tr_wrong == [], tr_wrong)
lst_wrong, _ = sh(home, "list", "--dir", "/some/other/project")
check("#8 (and it never appeared in that dir's list either)",
      not any(s.get("id") == "threadID9" for s in lst_wrong), lst_wrong)
shutil.rmtree(home, ignore_errors=True)

# ---------- codex context ring + codex usage (both read the rollout, never the net) ----------
# A codex conversation had NO context ring on reopen (cmd_context only understood
# Claude's assistant/usage lines) and NO usage line at all (the App blanked it,
# because `usage` is Claude's OAuth quota and showing it on a codex chat mislabels
# claude spend as codex spend). Both numbers are in the rollout itself: every
# request appends an `event_msg`/`token_count` carrying `info` (per-request +
# session totals + the real context window) and `rate_limits` (the codex plan's
# own windows). This section pins reading them — and pins the two pools APART.
print("=== codex context + codex usage (from the rollout) ===")
home = tempfile.mkdtemp(prefix="psess_cxu_", dir="/tmp")
cu_dir = "/proj/cxu"

# Verbatim shapes from a real rollout (redacted: ids/cwd only). Note the token
# arithmetic that decides the ring: input_tokens ALREADY INCLUDES the cached
# prefix — cached_input_tokens is a breakdown of input, not an addition
# (total_tokens == input_tokens + output_tokens exactly, verified across every
# rollout on this machine). Summing input+cached double-counts the cache and
# pushes the ring past 100%.
def token_count_line(input_tokens, cached, output, window=258400, rate_limits=None):
    return {"timestamp": "2026-08-07T08:57:44.391Z", "type": "event_msg", "payload": {
        "type": "token_count",
        "info": {
            "total_token_usage": {"input_tokens": input_tokens, "cached_input_tokens": cached,
                                  "cache_write_input_tokens": 0, "output_tokens": output,
                                  "reasoning_output_tokens": 8,
                                  "total_tokens": input_tokens + output},
            "last_token_usage": {"input_tokens": input_tokens, "cached_input_tokens": cached,
                                 "cache_write_input_tokens": 0, "output_tokens": output,
                                 "reasoning_output_tokens": 8,
                                 "total_tokens": input_tokens + output},
            "model_context_window": window},
        "rate_limits": rate_limits}}


WEEKLY_PRIMARY = {"limit_id": "codex", "limit_name": None,
                  "primary": {"used_percent": 23.0, "window_minutes": 10080,
                              "resets_at": 1786617048},
                  "secondary": None,
                  "credits": {"has_credits": False, "unlimited": False, "balance": "0"},
                  "individual_limit": None, "spend_control_reached": None,
                  "plan_type": "plus", "rate_limit_reached_type": None}

cu_roll = os.path.join(home, ".codex", "sessions", "2026", "08", "07",
                       "rollout-2026-08-07T08-57-20-threadCTX.jsonl")
writelines(cu_roll, [
    {"type": "session_meta", "payload": {"id": "threadCTX", "cwd": cu_dir}},
    {"type": "turn_context", "payload": {"cwd": cu_dir, "model": "gpt-5.4-mini"}},
    {"type": "response_item", "payload": {"type": "message", "role": "user",
                                          "content": [{"type": "input_text", "text": "hi"}]}},
    token_count_line(9000, 5504, 19, rate_limits=WEEKLY_PRIMARY),
    {"type": "response_item", "payload": {"type": "message", "role": "assistant",
                                          "content": [{"type": "output_text", "text": "yo"}]}},
    # the LAST token_count is the one that describes the window right now
    token_count_line(12080, 5504, 19, rate_limits=WEEKLY_PRIMARY),
])

cctx, p_cctx = sh(home, "context", "--dir", cu_dir, "--session", "threadCTX", "--backend", "codex")
check("codex context reads the LAST token_count's last_token_usage",
      (cctx or {}).get("used") == 12080, (cctx, p_cctx.stderr[:160]))
check("codex context does NOT add cached_input_tokens (it is already inside input)",
      (cctx or {}).get("used") != 12080 + 5504, cctx)
check("codex context returns the rollout's real model_context_window",
      (cctx or {}).get("window") == 258400, cctx)
check("codex context names the model from turn_context",
      (cctx or {}).get("model") == "gpt-5.4-mini", cctx)

# Same cwd binding the codex transcript path has (audit #8): a thread id alone
# must not read another project's context.
cctx_wrong, _ = sh(home, "context", "--dir", "/some/other/project",
                   "--session", "threadCTX", "--backend", "codex")
check("codex context refuses a thread id whose cwd != --dir",
      (cctx_wrong or {}).get("used") == 0, cctx_wrong)
for bad in ("../../secret", "a/b"):
    cbad, _ = sh(home, "context", "--dir", cu_dir, "--session", bad, "--backend", "codex")
    check("codex context rejects traversal id %r" % bad, (cbad or {}).get("used") == 0, cbad)

# A rollout that never reported usage (or an old codex) must degrade, not crash.
quiet = os.path.join(home, ".codex", "sessions", "2026", "08", "06",
                     "rollout-2026-08-06T00-00-00-threadQUIET.jsonl")
writelines(quiet, [{"type": "session_meta", "payload": {"id": "threadQUIET", "cwd": cu_dir}}])
cq, p_cq = sh(home, "context", "--dir", cu_dir, "--session", "threadQUIET", "--backend", "codex")
check("codex context on a rollout with no token_count returns used 0 (exit 0)",
      p_cq.returncode == 0 and (cq or {}).get("used") == 0, (cq, p_cq.returncode))

# ---- usage: the codex plan's own window, never Claude's ----
# Planted so a wrong branch would be caught red-handed: if `usage --backend codex`
# fell through to the Claude path it would read THIS token and try the OAuth
# endpoint. https_proxy points at a closed port, so any network attempt fails
# fast and deterministically instead of reaching the real endpoint.
os.makedirs(os.path.join(home, ".claude"), mode=0o700, exist_ok=True)
with open(os.path.join(home, ".claude", ".credentials.json"), "w") as f:
    json.dump({"claudeAiOauth": {"accessToken": "sk-ant-oat-PLANTED-NEVER-USED"}}, f)
NO_NET = {"https_proxy": "http://127.0.0.1:1", "HTTPS_PROXY": "http://127.0.0.1:1",
          "http_proxy": "http://127.0.0.1:1", "no_proxy": ""}

cus, p_cus = sh(home, "usage", "--backend", "codex", env=NO_NET)
check("codex usage returns the weekly window from the rollout's rate_limits",
      (cus or {}).get("weekly", {}).get("utilization") == 23.0, (cus, p_cus.stderr[:160]))
check("codex usage converts resets_at (epoch seconds) to an ISO8601 string the App parses",
      isinstance((cus or {}).get("weekly", {}).get("resets_at"), str)
      and (cus or {}).get("weekly", {}).get("resets_at", "").startswith("2026-")
      and (cus or {}).get("weekly", {}).get("resets_at", "").endswith("Z"), cus)
check("codex usage reports the plan", (cus or {}).get("plan") == "plus", cus)
# THE cross-pool line. A codex conversation must never be handed Claude's pools.
check("codex usage carries NO claude pools (five_hour/seven_day/scoped)",
      not ({"five_hour", "seven_day", "scoped"} & set(cus or {})), cus)
check("codex usage never touched the network (planted claude token unused, no error)",
      "error" not in (cus or {}), cus)

# Older codex builds put the 5h window in `primary` and the weekly in `secondary`
# (verified on this machine's March rollouts). The weekly is selected by
# window_minutes, not by position — otherwise the line silently shows a 5h
# percentage labelled "weekly".
FIVEH_PRIMARY = {"limit_id": "codex", "limit_name": None,
                 "primary": {"used_percent": 2.0, "window_minutes": 300,
                             "resets_at": 1773908654},
                 "secondary": {"used_percent": 61.0, "window_minutes": 10080,
                               "resets_at": 1774495454},
                 "credits": None, "plan_type": "team"}
old_roll = os.path.join(home, ".codex", "sessions", "2026", "08", "08",
                        "rollout-2026-08-08T00-00-00-threadOLD.jsonl")
writelines(old_roll, [
    {"type": "session_meta", "payload": {"id": "threadOLD", "cwd": cu_dir}},
    token_count_line(100, 0, 1, rate_limits=FIVEH_PRIMARY),
])
os.utime(old_roll, (2_000_000_000, 2_000_000_000))    # newest rollout wins
cus2, _ = sh(home, "usage", "--backend", "codex", env=NO_NET)
check("codex usage picks the 10080-minute window even when it rides `secondary`",
      (cus2 or {}).get("weekly", {}).get("utilization") == 61.0, cus2)
check("...and not the 5h `primary` sitting next to it",
      (cus2 or {}).get("weekly", {}).get("utilization") != 2.0, cus2)
check("codex usage reports that rollout's plan", (cus2 or {}).get("plan") == "team", cus2)

# The other direction of the same wall: the CLAUDE path must not start answering
# with codex's rollout numbers just because a rollout exists.
clu, _ = sh(home, "usage", env=NO_NET)
check("claude usage never returns codex's weekly pool",
      "weekly" not in (clu or {}) and "plan" not in (clu or {}), clu)
check("claude usage still reports its own failure honestly (network blocked)",
      "error" in (clu or {}) or "five_hour" in (clu or {}), clu)

# No codex rollouts at all → an honest error, never a silent fall-through to claude.
empty_home = tempfile.mkdtemp(prefix="psess_cxu0_", dir="/tmp")
cus3, p_cus3 = sh(empty_home, "usage", "--backend", "codex", env=NO_NET)
check("codex usage with no rollouts errors instead of falling back to claude",
      p_cus3.returncode == 0 and "error" in (cus3 or {})
      and "five_hour" not in (cus3 or {}), (cus3, p_cus3.returncode))
shutil.rmtree(empty_home, ignore_errors=True)

# Claude regression: the claude context answer keeps its exact shape (the field
# added for codex is OPTIONAL — an old App decoding {used, model} is untouched).
cl_dir = "/proj/clctx"
cl_sess = os.path.join(home, ".claude", "projects", psess.encode(cl_dir), "clsess.jsonl")
writelines(cl_sess, [
    {"type": "user", "cwd": cl_dir, "message": {"content": "hi"}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "yo"}], "model": "claude-x",
     "usage": {"input_tokens": 10, "cache_read_input_tokens": 5, "cache_creation_input_tokens": 2}}},
])
clctx, _ = sh(home, "context", "--dir", cl_dir, "--session", "clsess")
check("claude context still sums input+cache_read+cache_creation (unchanged)",
      (clctx or {}).get("used") == 17 and (clctx or {}).get("model") == "claude-x", clctx)
check("claude context never reports a codex window",
      not (clctx or {}).get("window"), clctx)
shutil.rmtree(home, ignore_errors=True)

# ---------- fork (rewind: branch a conversation before a user message) ----------
print("=== fork ===")
home = tempfile.mkdtemp(prefix="psess_fork_", dir="/tmp")
fk_dir = "/proj/fork"
fk_folder = os.path.join(home, ".claude", "projects", psess.encode(fk_dir))
orig = os.path.join(fk_folder, "origsess.jsonl")
snapshot_line = {"type": "file-history-snapshot", "messageId": "m1", "snapshot": {"trackedFileBackups": {}}}  # real files carry these, WITHOUT sessionId
writelines(orig, [                                    # 3 rounds; round 1 has a tool_use + tool_result pair
    {"type": "user", "uuid": "u1", "sessionId": "origsess", "cwd": fk_dir, "message": {"content": "round one question"}},
    snapshot_line,
    {"type": "assistant", "uuid": "a1", "parentUuid": "u1", "sessionId": "origsess", "message": {"content": [
        {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls"}}]}},
    {"type": "user", "uuid": "tr1", "parentUuid": "a1", "sessionId": "origsess", "message": {"content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": "a.txt"}]}},
    {"type": "assistant", "uuid": "a1b", "parentUuid": "tr1", "sessionId": "origsess", "message": {"content": [
        {"type": "text", "text": "round one answer"}]}},
    {"type": "user", "uuid": "u2", "sessionId": "origsess", "message": {"content": "round two question"}},
    {"type": "assistant", "uuid": "a2", "parentUuid": "u2", "sessionId": "origsess", "message": {"content": [
        {"type": "text", "text": "round two answer"}]}},
    {"type": "user", "uuid": "u3", "sessionId": "origsess", "message": {"content": "round three question"}},
    {"type": "assistant", "uuid": "a3", "parentUuid": "u3", "sessionId": "origsess", "message": {"content": [
        {"type": "text", "text": "round three answer"}]}},
])
with open(orig, "rb") as f:
    orig_bytes = f.read()

out, p = sh(home, "fork", "--dir", fk_dir, "--session", "origsess", "--before", "u2")
check("fork exits 0 and prints the new session id",
      p.returncode == 0 and isinstance(out, dict) and out.get("session"), (p.returncode, p.stdout, p.stderr))
new_id = (out or {}).get("session") or ""
check("fork mints a fresh id (not the original)", new_id and new_id != "origsess", new_id)
new_fp = os.path.join(fk_folder, new_id + ".jsonl")
check("forked file lands in the same project folder", os.path.isfile(new_fp), new_fp)
with open(new_fp) as f:
    new_lines = [l.rstrip("\n") for l in f if l.strip()]
new_objs = [json.loads(l) for l in new_lines]
check("fork keeps ONLY round 1 (5 lines incl. tool_use/tool_result/snapshot), u2 and after dropped",
      [o.get("uuid") for o in new_objs] == ["u1", None, "a1", "tr1", "a1b"], [o.get("uuid") for o in new_objs])
check("round 2/3 content is gone",
      "round two" not in "\n".join(new_lines) and "round three" not in "\n".join(new_lines), new_lines)
check("every line carrying sessionId is rewritten to the new id (4 of them)",
      sum(1 for o in new_objs if "sessionId" in o) == 4
      and all(o["sessionId"] == new_id for o in new_objs if "sessionId" in o), new_objs)
check("the sessionId-less snapshot line is preserved byte-for-byte",
      new_lines[1] == json.dumps(snapshot_line), new_lines[1])
with open(orig, "rb") as f:
    check("original file bytes untouched", f.read() == orig_bytes)

# before the FIRST user message -> REFUSED: the empty-history file would be a
# dead end (`claude --resume` answers "No conversation found" on a message-less
# jsonl, verified 2.1.181) — the caller should start a new chat instead.
out2, p2 = sh(home, "fork", "--dir", fk_dir, "--session", "origsess", "--before", "u1")
check("fork before the first message refused (dead-end file, use a new chat)",
      p2.returncode != 0 and "start a new chat" in p2.stderr, (p2.returncode, p2.stderr))

# --after: "branch in new chat" keeps the chosen turn WHOLE (2026-10-16)
out5, p5 = sh(home, "fork", "--dir", fk_dir, "--session", "origsess", "--after", "u1")
b1 = (out5 or {}).get("session") if p5.returncode == 0 else None
with open(os.path.join(os.path.dirname(new_fp), (b1 or "x") + ".jsonl")) as f:
    b1_objs = [json.loads(l) for l in f if l.strip()]
check("fork --after u1 keeps round 1 whole (its tool round-trip and answer) and drops round 2 on",
      p5.returncode == 0 and [o.get("uuid") for o in b1_objs] == ["u1", None, "a1", "tr1", "a1b"]
      and all(o.get("sessionId") == b1 for o in b1_objs if "sessionId" in o), (p5.returncode, [o.get("uuid") for o in b1_objs]))
out6, p6 = sh(home, "fork", "--dir", fk_dir, "--session", "origsess", "--after", "u3")
b3 = (out6 or {}).get("session") if p6.returncode == 0 else None
with open(os.path.join(os.path.dirname(new_fp), (b3 or "x") + ".jsonl")) as f:
    b3_lines = [l for l in f if l.strip()]
check("fork --after the LAST turn copies the whole conversation under a new id",
      p6.returncode == 0 and len(b3_lines) == len([l for l in open(orig) if l.strip()]) and b3 != "origsess", (p6.returncode, len(b3_lines)))
_, p7 = sh(home, "fork", "--dir", fk_dir, "--session", "origsess", "--after", "a1")
check("fork --after an assistant line is refused", p7.returncode != 0 and "typed" in p7.stderr, p7.stderr)
_, p8 = sh(home, "fork", "--dir", fk_dir, "--session", "origsess", "--after", "tr1")
check("fork --after a tool_result carrier is refused (mid-turn)", p8.returncode != 0, p8.stderr)
# ---- turns: a window with bearings, for the context export and a model paging by itself (2026-10-17) ----
w, pw = sh(home, "turns", "--dir", fk_dir, "--session", "origsess", "--limit", "2")
check("turns without --from is the LAST window, numbered, with the record's file",
      pw.returncode == 0 and w.get("total") == 6 and (w.get("from"), w.get("to")) == (5, 6) and len(w.get("turns") or []) == 2
      and w["turns"][0]["text"] == "round three question" and w.get("files") == [orig], (pw.returncode, w, pw.stderr[-200:]))
w2, _ = sh(home, "turns", "--dir", fk_dir, "--session", "origsess", "--from", "2", "--limit", "3")
check("turns --from N --limit M is that window", (w2.get("from"), w2.get("to")) == (2, 4) and [t["role"] for t in w2["turns"]] == ["assistant", "user", "assistant"], w2)
w3, _ = sh(home, "turns", "--dir", fk_dir, "--session", "origsess", "--from", "99")
check("a window past the end is empty but still says how many there are", w3.get("total") == 6 and w3.get("turns") == [] and w3.get("from") == 0, w3)
_, pt = sh(home, "turns", "--dir", fk_dir, "--session", "origsess", "--from", "3", "--limit", "2", "--text")
check("--text renders the window as numbered plain lines a model can read",
      pt.returncode == 0 and "6 turns · showing 3-4" in pt.stdout and "#3 user: round two question" in pt.stdout and "#4 assistant:" in pt.stdout, pt.stdout[:300])

# ---- project-docs: what a folder's agents read on their own ----
pd_dir = os.path.join(home, "work", "proj")
os.makedirs(os.path.join(pd_dir, ".claude", "rules"), exist_ok=True); os.makedirs(os.path.join(pd_dir, ".cursor", "rules"), exist_ok=True)
for rel, body in (("CLAUDE.md", "# proj"), ("AGENTS.md", "agents"), (".claude/rules/style.md", "rule"), (".cursor/rules/a.mdc", "mdc"), (".cursorrules", "old")):
    open(os.path.join(pd_dir, rel), "w").write(body)
open(os.path.join(home, "work", "CLAUDE.md"), "w").write("# parent")
os.makedirs(os.path.join(home, ".claude"), exist_ok=True); open(os.path.join(home, ".claude", "CLAUDE.md"), "w").write("# global")
os.makedirs(os.path.join(home, ".codex"), exist_ok=True); open(os.path.join(home, ".codex", "AGENTS.md"), "w").write("global agents")
mem = os.path.join(home, ".claude", "projects", psess.encode(pd_dir), "memory"); os.makedirs(mem, exist_ok=True)
open(os.path.join(mem, "MEMORY.md"), "w").write("index"); open(os.path.join(mem, "topic.md"), "w").write("fact")
docs, pdoc = sh(home, "project-docs", "--dir", pd_dir)
kinds = [(d["kind"], d["name"]) for d in (docs or [])]
check("project-docs lists the folder's notes, its parents' and the global ones, the rules folders, and Claude's memory INDEX only (never its notes)",
      pdoc.returncode == 0 and kinds == [("claude-md", "CLAUDE.md"), ("agents-md", "AGENTS.md"), ("rules", "style.md"), ("cursor-rules", "a.mdc"), ("cursor-rules", ".cursorrules"),
                                         ("claude-md", "CLAUDE.md"), ("claude-md", "CLAUDE.md"), ("agents-md", "AGENTS.md"), ("memory", "MEMORY.md")]
      and all(os.path.isabs(d["path"]) and d["bytes"] > 0 for d in (docs or [])), (pdoc.returncode, kinds, pdoc.stderr[-200:]))

# ---- meta: the person's own name for a conversation + the folders it was handed (2026-10-17) ----
import base64 as _b64
mt, pm = sh(home, "meta", "--session", "origsess", "--title-b64", _b64.b64encode("第七章 PPT".encode()).decode(),
            "--dirs-b64", _b64.b64encode(json.dumps(["/srv/ppt/v3", "/srv/notes"]).encode()).decode())
check("meta sets a title and the folders and echoes them", pm.returncode == 0 and mt == {"id": "origsess", "title": "第七章 PPT", "dirs": ["/srv/ppt/v3", "/srv/notes"]}, (pm.returncode, mt, pm.stderr))
rows_m, _ = sh(home, "list", "--dir", fk_dir)
row_m = next((r for r in (rows_m or []) if r.get("id") == "origsess"), {})
check("the list row carries the name and the folders", row_m.get("title") == "第七章 PPT" and row_m.get("dirs") == ["/srv/ppt/v3", "/srv/notes"], row_m)
mt2, _ = sh(home, "meta", "--session", "origsess", "--clear-title")
rows_m2, _ = sh(home, "list", "--dir", fk_dir)
row_m2 = next((r for r in (rows_m2 or []) if r.get("id") == "origsess"), {})
check("--clear-title drops the name and keeps the folders", mt2.get("title") == "" and "title" not in row_m2 and row_m2.get("dirs") == ["/srv/ppt/v3", "/srv/notes"], (mt2, row_m2))
_, pm3 = sh(home, "meta", "--session", "../x", "--clear-title")
check("meta refuses a path-shaped session id", pm3.returncode != 0, pm3.stderr)
check("meta.json is private (0600)", stat.S_IMODE(os.stat(os.path.join(home, ".pervio", "chat", "meta.json")).st_mode) == 0o600)

# ---- codex: the same branch on a rollout thread (paged), anchors = payload.id ----
cx_day = os.path.join(home, ".codex", "sessions", "2026", "10", "16")
os.makedirs(cx_day, exist_ok=True)
def _cx_user(oid, text, ordinal):
    return {"timestamp": "2026-10-16T00:00:00.000Z", "ordinal": ordinal, "type": "response_item",
            "payload": {"type": "message", "id": oid, "role": "user", "content": [{"type": "input_text", "text": text}]}}
def _cx_asst(oid, text, ordinal):
    return {"timestamp": "2026-10-16T00:00:00.000Z", "ordinal": ordinal, "type": "response_item",
            "payload": {"type": "message", "id": oid, "role": "assistant", "content": [{"type": "output_text", "text": text}]}}
cx_meta = {"timestamp": "2026-10-16T00:00:00.000Z", "ordinal": 0, "type": "session_meta",
           "payload": {"id": "cxfork1", "session_id": "cxfork1", "cwd": fk_dir, "thread_source": "user", "originator": "codex_cli"}}
page1 = os.path.join(cx_day, "rollout-2026-10-16T08-00-00-cxfork1.jsonl")
page2 = os.path.join(cx_day, "rollout-2026-10-16T09-00-00-cxfork1_seg2.jsonl")
writelines(page1, [cx_meta,
    _cx_user("msg_env", "<environment_context>\n<cwd>/x</cwd>", 1),
    _cx_user("msg_u1", "# Context from my IDE setup:\nblah\n## My request\ncodex round one", 2),
    _cx_asst("msg_a1", "answer one", 3),
    _cx_user("msg_u2", "codex round two", 4),
    _cx_asst("msg_a2", "answer two", 5)])
writelines(page2, [dict(cx_meta, payload=dict(cx_meta["payload"], history_base={"thread_id": "cxfork1", "end_ordinal_exclusive": 6})),
    _cx_user("msg_u3", "codex round three", 6),
    _cx_asst("msg_a3", "answer three", 7)])
out9, p9 = sh(home, "user-turns", "--session", "cxfork1", "--backend", "codex")
check("user-turns lists codex's typed user messages by payload.id, unwrapped, across pages; injected context hidden",
      p9.returncode == 0 and out9 == [{"uuid": "msg_u1", "text": "codex round one"}, {"uuid": "msg_u2", "text": "codex round two"},
                                      {"uuid": "msg_u3", "text": "codex round three"}], (p9.returncode, out9, p9.stderr))
out10, p10 = sh(home, "fork", "--dir", fk_dir, "--session", "cxfork1", "--backend", "codex", "--after", "msg_u1")
cx1 = (out10 or {}).get("session") if p10.returncode == 0 else None
cx1_fp = glob.glob(os.path.join(cx_day, "rollout-*-%s.jsonl" % (cx1 or "none")))
cx1_objs = [json.loads(l) for l in open(cx1_fp[0])] if cx1_fp else []
rows_cx1, _ = sh(home, "list", "--dir", fk_dir)
check("a branch starts out named after its source: 'fork from <first words>'",
      any(r.get("id") == cx1 and r.get("title") == "fork from codex round one" for r in (rows_cx1 or [])), [(r.get("id"), r.get("title")) for r in (rows_cx1 or [])][:6])
out_zh, p_zh = sh(home, "fork", "--dir", fk_dir, "--session", "cxfork1", "--backend", "codex", "--after", "msg_u1", "--lang", "zh")
cxzh = (out_zh or {}).get("session") if p_zh.returncode == 0 else None
rows_zh, _ = sh(home, "list", "--dir", fk_dir)
check("…in Chinese when the phone says so: '分支自 <first words>'",
      any(r.get("id") == cxzh and r.get("title") == "分支自 codex round one" for r in (rows_zh or [])), [(r.get("id"), r.get("title")) for r in (rows_zh or [])][:6])
sh(home, "meta", "--session", "cxfork1", "--title-b64", _b64.b64encode("我的 PPT".encode()).decode())
out_named, _ = sh(home, "fork", "--dir", fk_dir, "--session", "cxfork1", "--backend", "codex", "--after", "msg_u1")
rows_named, _ = sh(home, "list", "--dir", fk_dir)
check("…and after the person's own name when the source has one",
      any(r.get("id") == (out_named or {}).get("session") and r.get("title") == "fork from 我的 PPT" for r in (rows_named or [])), [(r.get("id"), r.get("title")) for r in (rows_named or [])][:8])
sh(home, "meta", "--session", "cxfork1", "--clear-title")
check("codex fork --after msg_u1 keeps round 1 whole (env line, question, answer) under a new id, nothing after",
      p10.returncode == 0 and len(cx1_fp) == 1 and [o["payload"].get("id") for o in cx1_objs] == [cx1, "msg_env", "msg_u1", "msg_a1"]
      and cx1_objs[0]["payload"]["session_id"] == cx1 and "history_base" not in cx1_objs[0]["payload"], (p10.returncode, p10.stderr, [o["payload"].get("id") for o in cx1_objs]))
out11, p11 = sh(home, "fork", "--dir", fk_dir, "--session", "cxfork1", "--backend", "codex", "--after", "msg_u3")
cx3 = (out11 or {}).get("session") if p11.returncode == 0 else None
cx3_fp = glob.glob(os.path.join(cx_day, "rollout-*-%s.jsonl" % (cx3 or "none")))
cx3_objs = [json.loads(l) for l in open(cx3_fp[0])] if cx3_fp else []
check("codex fork --after the last turn stitches both pages into one file (the segment's meta dropped)",
      p11.returncode == 0 and [o["payload"].get("id") for o in cx3_objs] == [cx3, "msg_env", "msg_u1", "msg_a1", "msg_u2", "msg_a2", "msg_u3", "msg_a3"], (p11.returncode, p11.stderr, [o["payload"].get("id") for o in cx3_objs]))
out12, p12 = sh(home, "fork", "--dir", fk_dir, "--session", "cxfork1", "--backend", "codex", "--before", "msg_u2")
cx2 = (out12 or {}).get("session") if p12.returncode == 0 else None
cx2_fp = glob.glob(os.path.join(cx_day, "rollout-*-%s.jsonl" % (cx2 or "none")))
cx2_objs = [json.loads(l) for l in open(cx2_fp[0])] if cx2_fp else []
check("codex fork --before msg_u2 (rewind) drops round 2 on", p12.returncode == 0 and [o["payload"].get("id") for o in cx2_objs] == [cx2, "msg_env", "msg_u1", "msg_a1"], (p12.returncode, p12.stderr))
_, p13 = sh(home, "fork", "--dir", fk_dir, "--session", "cxfork1", "--backend", "codex", "--after", "msg_a1")
check("codex fork at an assistant line is refused", p13.returncode != 0 and "typed" in p13.stderr, p13.stderr)
_, p14 = sh(home, "fork", "--dir", fk_dir, "--session", "cxfork1", "--backend", "codex", "--after", "msg_env")
check("codex fork at an injected context line is refused (not a typed message)", p14.returncode != 0, p14.stderr)
check("the original codex pages are untouched", len([l for l in open(page1) if l.strip()]) == 6 and len([l for l in open(page2) if l.strip()]) == 3)
wc, _ = sh(home, "turns", "--dir", fk_dir, "--session", "cxfork1", "--backend", "codex", "--limit", "10")
check("a codex thread pages the same way (pages stitched, files listed)", wc.get("total") == 6 and len(wc.get("files") or []) == 2 and wc["turns"][0]["text"] == "codex round one", wc)
# ---- codex launched on a RESOLVED path (OneDrive's ~/Documents symlink, 2026-10-17) still lists under the person's spelling ----
cs_real = os.path.join(home, "Library", "CloudStorage", "OneDrive-Co", "Documents")
os.makedirs(os.path.join(cs_real, "odproj"), exist_ok=True)
docs_link = os.path.join(home, "Documents")
if os.path.lexists(docs_link):
    shutil.rmtree(docs_link, ignore_errors=True) if os.path.isdir(docs_link) and not os.path.islink(docs_link) else os.remove(docs_link)
os.symlink(cs_real, docs_link)
od_day = os.path.join(home, ".codex", "sessions", "2026", "10", "17")
os.makedirs(od_day, exist_ok=True)
writelines(os.path.join(od_day, "rollout-2026-10-17T01-00-00-odthread.jsonl"), [
    {"timestamp": "2026-10-17T00:00:00.000Z", "ordinal": 0, "type": "session_meta",
     "payload": {"id": "odthread", "session_id": "odthread", "cwd": os.path.join(cs_real, "odproj"), "thread_source": "user", "originator": "codex_cli"}},
    _cx_user("msg_od1", "hello from onedrive", 1), _cx_asst("msg_oda1", "hi", 2)])
rows_od, p_od = sh(home, "list", "--dir", os.path.join(docs_link, "odproj"))
check("a codex thread recorded on the resolved CloudStorage path lists under the ~/Documents spelling the person uses",
      p_od.returncode == 0 and any(r.get("id") == "odthread" for r in (rows_od or [])), (p_od.returncode, rows_od, p_od.stderr[-200:]))
projs_od, _ = sh(home, "projects")
check("…and the project list spells that folder the person's way, not the sandbox's",
      any(r.get("path") == os.path.join(docs_link, "odproj") for r in (projs_od or []))
      and not any("CloudStorage" in r.get("path", "") for r in (projs_od or [])), [r.get("path") for r in (projs_od or [])])
os.remove(docs_link)

# red: unknown uuid / uuid pointing at an assistant line -> non-zero, nothing created
files_before = sorted(os.listdir(fk_folder))
_, p3 = sh(home, "fork", "--dir", fk_dir, "--session", "origsess", "--before", "nope")
check("fork with an unknown uuid exits non-zero with a stderr line",
      p3.returncode != 0 and p3.stderr.strip(), (p3.returncode, p3.stderr))
_, p4 = sh(home, "fork", "--dir", fk_dir, "--session", "origsess", "--before", "a1")
check("fork at an assistant line exits non-zero ('not a user message')",
      p4.returncode != 0 and "not a user message" in p4.stderr, (p4.returncode, p4.stderr))
# tr1 is type=="user" but a tool_result CARRIER — a mid-turn line; cutting there
# would leave a1's tool_use dangling at the branch tail.
_, p5 = sh(home, "fork", "--dir", fk_dir, "--session", "origsess", "--before", "tr1")
check("fork at a tool_result carrier line refused (mid-turn, not an anchor)",
      p5.returncode != 0 and "not a rewind anchor" in p5.stderr, (p5.returncode, p5.stderr))
check("failed forks created no files", sorted(os.listdir(fk_folder)) == files_before, os.listdir(fk_folder))

# red: traversal guards (malicious sid / dir), same safety tier as delete
victim = os.path.join(home, "victim.jsonl")
writelines(victim, [{"type": "user", "uuid": "vu", "sessionId": "victim", "message": {"content": "PRIVATE"}}])
with open(victim, "rb") as f:
    victim_bytes = f.read()
_, p5 = sh(home, "fork", "--dir", fk_dir, "--session", "../../victim", "--before", "vu")
check("fork rejects a traversal session id (non-zero)", p5.returncode != 0, (p5.returncode, p5.stdout))
_, p5b = sh(home, "fork", "--dir", fk_dir, "--session", "a/b", "--before", "u2")
check("fork rejects a slashed session id (non-zero)", p5b.returncode != 0, (p5b.returncode, p5b.stdout))
with open(victim, "rb") as f:
    check("the traversal target was not touched", f.read() == victim_bytes)
check("no forked jsonl leaked outside the project folder",
      [x for x in os.listdir(home) if x.endswith(".jsonl")] == ["victim.jsonl"], os.listdir(home))
_, p6 = sh(home, "fork", "--dir", "../../../etc", "--session", "origsess", "--before", "u2")
check("fork with a malicious --dir finds no session (non-zero)", p6.returncode != 0, (p6.returncode, p6.stdout))

# atomicity: tmp+rename leaves no residue
check("no .tmp residue in the project folder",
      not [x for x in os.listdir(fk_folder) if ".tmp" in x], os.listdir(fk_folder))
shutil.rmtree(home, ignore_errors=True)

# ---------- contract pins: the exact shapes the App decodes ----------
# The iOS app (ProjectInfo / SessionSummary / TranscriptTurn, and now the 背景
# context picker) depends on these field sets verbatim. Pinned against REAL
# probes run 2026-08-05 on the production store: projects rows are EXACTLY
# {path,sessions,modified}, list rows EXACTLY {id,preview,modified,bytes,backend},
# transcript turns EXACTLY {role,text,tools,thinking,blocks}; `modified` is
# integer unix seconds; both lists sort most-recent first; transcript --limit
# defaults to 40 and keeps the LAST N logical turns.
print("=== contract pins (App-decoded shapes) ===")
home = tempfile.mkdtemp(prefix="psess_pin_", dir="/tmp")
pin_dir = "/proj/pin"
pin_folder = os.path.join(home, ".claude", "projects", psess.encode(pin_dir))
# 25 user/assistant rounds = 50 logical turns, to exercise the default limit.
big = []
for i in range(25):
    big.append({"type": "user", "cwd": pin_dir, "message": {"content": "question %d" % i}})
    big.append({"type": "assistant", "message": {"content": [{"type": "text", "text": "answer %d" % i}]}})
big_fp = os.path.join(pin_folder, "bigsess.jsonl")
writelines(big_fp, big)
old_fp = os.path.join(pin_folder, "oldsess.jsonl")
writelines(old_fp, [{"type": "user", "cwd": pin_dir, "message": {"content": "older conversation"}}])
now = os.path.getmtime(big_fp)
os.utime(old_fp, (now - 500, now - 500))
other_fp = os.path.join(home, ".claude", "projects", psess.encode("/proj/older"), "o.jsonl")
writelines(other_fp, [{"type": "user", "cwd": "/proj/older", "message": {"content": "other project"}}])
os.utime(other_fp, (now - 900, now - 900))

projects, _ = sh(home, "projects")
check("projects rows fields pinned to {path,sessions,modified}",
      projects and all(set(p) == {"path", "sessions", "modified"} for p in projects),
      [sorted(p) for p in projects])
check("projects types: path str, sessions int, modified int (unix seconds)",
      all(isinstance(p["path"], str) and isinstance(p["sessions"], int)
          and isinstance(p["modified"], int) for p in projects), projects)
check("projects modified matches the newest session file's mtime",
      next(p["modified"] for p in projects if p["path"] == pin_dir) == int(now), projects)
check("projects sorted most-recently-active first",
      all(projects[i]["modified"] >= projects[i + 1]["modified"] for i in range(len(projects) - 1)),
      [(p["path"], p["modified"]) for p in projects])

lst, _ = sh(home, "list", "--dir", pin_dir)
check("list rows fields pinned to {id,preview,modified,bytes,backend}",
      lst and all(set(s) == {"id", "preview", "modified", "bytes", "backend", "pinned"} for s in lst),
      [sorted(s) for s in lst])
check("list types: id/preview/backend str, modified/bytes int",
      all(isinstance(s["id"], str) and isinstance(s["preview"], str)
          and isinstance(s["backend"], str) and isinstance(s["modified"], int)
          and isinstance(s["bytes"], int) for s in lst), lst)
check("list sorted newest first (bigsess before the older one)",
      [s["id"] for s in lst] == ["bigsess", "oldsess"], [s["id"] for s in lst])

tr, _ = sh(home, "transcript", "--dir", pin_dir, "--session", "bigsess")   # no --limit
check("transcript default --limit is 40 (50 logical turns -> 40 rows)", len(tr) == 40, len(tr))
check("default limit keeps the LAST 40 turns (starts at question 5, ends at answer 24)",
      tr and tr[0]["role"] == "user" and tr[0]["text"] == "question 5"
      and tr[-1]["role"] == "assistant" and tr[-1]["text"] == "answer 24",
      (tr[0], tr[-1]) if tr else tr)
check("transcript turn fields pinned to {role,text,tools,thinking,blocks}",
      all(set(t) == {"role", "text", "tools", "thinking", "blocks"} for t in tr),
      [sorted(t) for t in tr[:2]])
check("transcript turn types: role user|assistant, text str, tools/blocks lists, thinking str",
      all(t["role"] in ("user", "assistant") and isinstance(t["text"], str)
          and isinstance(t["tools"], list) and isinstance(t["blocks"], list)
          and isinstance(t["thinking"], str) for t in tr), tr[:2])
shutil.rmtree(home, ignore_errors=True)

# ---------- search (cross-project full-text, claude + codex) ----------
# The App's search results list decodes rows verbatim, so the shape is pinned
# field-by-field. Fixtures are written with ensure_ascii=False, matching how BOTH
# production stores serialize (verified on real files 2026-08-06: CJK is raw
# UTF-8, never \uXXXX) — the raw-line pre-filter depends on that.
print("=== search (cross-project, claude + codex) ===")
import time

home = tempfile.mkdtemp(prefix="psess_srch_", dir="/tmp")


def writelines_raw(path, objs):   # production-faithful serialization (raw UTF-8)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for o in objs:
            f.write(json.dumps(o, ensure_ascii=False) + "\n")


alpha = "/proj/alpha"
a_folder = os.path.join(home, ".claude", "projects", psess.encode(alpha))
now = time.time()

# Newest: a real assistant-body hit buried in a long paragraph (snippet windowing).
hit_fp = os.path.join(a_folder, "hitsess.jsonl")
writelines_raw(hit_fp, [
    {"type": "user", "cwd": alpha, "message": {"content": "how do I fix the login flow"}},
    {"type": "assistant", "message": {"content": [
        {"type": "text", "text": "X" * 300 + " the ZebraNeedle lives here " + "Y" * 300}]}},
])
os.utime(hit_fp, (now, now))

# Same project, older: the needle appears ONLY in non-dialogue places — a Bash
# tool_use input, a tool_result carrier, a subagent line, a '<' noise user line.
# NONE of these count as conversation text; the session must NOT surface.
fake_fp = os.path.join(a_folder, "fakesess.jsonl")
writelines_raw(fake_fp, [
    {"type": "user", "cwd": alpha, "message": {"content": "unrelated question"}},
    {"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "grep ZebraNeedle ."}}]}},
    {"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": "ZebraNeedle found in a dump"}]}},
    {"type": "assistant", "isSidechain": True, "message": {"content": [
        {"type": "text", "text": "subagent saw the ZebraNeedle"}]}},
    {"type": "user", "message": {"content": "<ide_context>ZebraNeedle</ide_context>"}},
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "all done"}]}},
])
os.utime(fake_fp, (now - 50, now - 50))

# Regex-metachar + backslash text: the query is LITERAL, must neither crash nor regex.
meta_fp = os.path.join(a_folder, "metasess.jsonl")
writelines_raw(meta_fp, [
    {"type": "user", "cwd": alpha, "message": {"content": "crash repro: a.*b[?\\d (unclosed"}},
])
os.utime(meta_fp, (now - 200, now - 200))

# Quoted phrase: the raw JSONL line stores \" — the pre-filter must survive that.
quote_fp = os.path.join(a_folder, "quotesess.jsonl")
writelines_raw(quote_fp, [
    {"type": "user", "cwd": alpha, "message": {"content": 'she said "hello world" loudly'}},
])
os.utime(quote_fp, (now - 300, now - 300))

# CJK body, raw UTF-8 on disk like production.
cjk_fp = os.path.join(a_folder, "cjksess.jsonl")
writelines_raw(cjk_fp, [
    {"type": "user", "cwd": alpha, "message": {"content": "部署流程在这里说明"}},
])
os.utime(cjk_fp, (now - 400, now - 400))

# wf-internal project with a REAL hit — hidden by the same filter `projects` uses.
wf_cwd = os.path.join(home, ".pervio", "wf", "wf9", "wt")
wf_fp = os.path.join(home, ".claude", "projects", psess.encode(wf_cwd), "wfhit.jsonl")
writelines_raw(wf_fp, [
    {"type": "user", "cwd": wf_cwd, "message": {"content": "ZebraNeedle inside a workflow"}}])
os.utime(wf_fp, (now - 30, now - 30))

# Codex rollout with a real user hit (older than the claude hit).
cx_cwd = "/proj/beta"
cx_fp = os.path.join(home, ".codex", "sessions", "2026", "02", "03",
                     "rollout-2026-02-03-cxthread1.jsonl")
writelines_raw(cx_fp, [
    {"type": "session_meta", "payload": {"id": "cxthread1", "cwd": cx_cwd}},
    {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [
        {"type": "input_text", "text": "codex also saw the zebraneedle once"}]}},
    {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [
        {"type": "input_text", "text": "<environment_context>ZebraNeedle</environment_context>"}]}},
])
os.utime(cx_fp, (now - 100, now - 100))

res, p = sh(home, "search", "--query", "zebraNEEDLE")
check("search exits 0 and returns a JSON list", p.returncode == 0 and isinstance(res, list), (p.returncode, p.stdout, p.stderr))
check("search finds the claude + codex true hits, nothing else",
      [r["id"] for r in res] == ["hitsess", "cxthread1"], res)
check("search rows sorted modified desc",
      all(res[i]["modified"] >= res[i + 1]["modified"] for i in range(len(res) - 1)), res)
check("search row fields pinned to {project,id,backend,modified,snippet,preview}",
      res and all(set(r) == {"project", "id", "backend", "modified", "snippet", "preview"} for r in res),
      [sorted(r) for r in res])
check("search row types: project/id/backend/snippet/preview str, modified int",
      all(isinstance(r["project"], str) and isinstance(r["id"], str)
          and isinstance(r["backend"], str) and isinstance(r["snippet"], str)
          and isinstance(r["preview"], str) and isinstance(r["modified"], int) for r in res), res)
cl_row = next((r for r in res if r["id"] == "hitsess"), None) or {}
cx_row = next((r for r in res if r["id"] == "cxthread1"), None) or {}
check("claude row: real project path, backend claude, modified = file mtime",
      cl_row.get("project") == alpha and cl_row.get("backend") == "claude"
      and cl_row.get("modified") == int(now), cl_row)
check("codex row: real cwd as project, backend codex",
      cx_row.get("project") == cx_cwd and cx_row.get("backend") == "codex", cx_row)
check("claude snippet ≤160, contains the needle with context on BOTH sides",
      len(cl_row.get("snippet", "")) <= 160 and "ZebraNeedle" in cl_row.get("snippet", "")
      and "XX" in cl_row.get("snippet", "") and "YY" in cl_row.get("snippet", ""), cl_row.get("snippet"))
check("codex snippet is the (short) matched text", cx_row.get("snippet") == "codex also saw the zebraneedle once", cx_row)
check("claude preview is the session's first user message",
      cl_row.get("preview") == "how do I fix the login flow", cl_row.get("preview"))
check("pseudo-hit session (tool_result/subagent/<noise>/tool-input only) absent",
      "fakesess" not in [r["id"] for r in res], res)
check("wf-internal project hit hidden",
      "wfhit" not in [r["id"] for r in res]
      and not any("/.pervio/wf/" in r["project"] for r in res), res)

# --under: the phone's working directory as the scope of everything that
# enumerates across folders (projects, search) — the folder and what is below.
# Expectations are derived from the unscoped answers, so the checks follow the
# fixture instead of guessing it.
pall, _ = sh(home, "projects")
inside = [p["path"] for p in pall if p["path"] == "/proj/alpha" or p["path"].startswith("/proj/alpha/")]
pu, _ = sh(home, "projects", "--under", "/proj/alpha")
check("projects --under <dir> lists that folder (and what is below), nothing beside it",
      [p["path"] for p in pu] == inside and inside, (pu, pall))
pu2, _ = sh(home, "projects", "--under", "/proj")
check("projects --under <parent> keeps every folder below it",
      [p["path"] for p in pu2] == [p["path"] for p in pall if p["path"] == "/proj" or p["path"].startswith("/proj/")], (pu2, pall))
pu3, _ = sh(home, "projects", "--under", "~/nothing-here")
check("projects --under an empty scope lists nothing", pu3 == [], pu3)
want = [r["id"] for r in res if r["project"] == "/proj/alpha" or r["project"].startswith("/proj/alpha/")]
su, _ = sh(home, "search", "--query", "zebraNEEDLE", "--under", "/proj/alpha")
check("search --under keeps only hits whose project is inside the scope (and drops the codex hit elsewhere)",
      [r["id"] for r in su] == want and len(su) < len(res), (su, res))
res2, p2 = sh(home, "search", "--query", "ZEBRANEEDLE")
check("search is case-insensitive (SHOUTED query, same hits)",
      p2.returncode == 0 and [r["id"] for r in res2] == ["hitsess", "cxthread1"], res2)

res3, p3 = sh(home, "search", "--query", "zebraNEEDLE", "--limit", "1")
check("search --limit truncates to the NEWEST hit",
      p3.returncode == 0 and [r["id"] for r in res3] == ["hitsess"], res3)

# LITERAL semantics: metachars neither crash nor act as a regex.
res4, p4 = sh(home, "search", "--query", "a.*b[?\\d (unclosed")
check("regex-metachar query matches its literal text without crashing",
      p4.returncode == 0 and [r["id"] for r in res4] == ["metasess"], (p4.returncode, res4, p4.stderr))
res5, p5 = sh(home, "search", "--query", "Zebra.*Needle")
check("'.*' is NOT a wildcard: Zebra.*Needle matches nothing",
      p5.returncode == 0 and res5 == [], res5)

res6, p6 = sh(home, "search", "--query", '"hello world"')
check("quoted-phrase query survives JSON \\\" escaping in the raw line",
      p6.returncode == 0 and [r["id"] for r in res6] == ["quotesess"], (p6.returncode, res6))

res7, p7 = sh(home, "search", "--query", "流程在这")
check("CJK query matches raw-UTF-8 stored text",
      p7.returncode == 0 and [r["id"] for r in res7] == ["cjksess"], (p7.returncode, res7))

res8, p8 = sh(home, "search", "--query", "proj/alpha")
check("JSON structure (cwd field etc.) is not searched, only dialogue text",
      p8.returncode == 0 and res8 == [], res8)

for badq in ([], ["--query", ""], ["--query", "   "]):
    _, pq = sh(home, "search", *badq)
    check("empty query %r exits non-zero" % (badq,), pq.returncode != 0 and pq.stderr.strip(),
          (pq.returncode, pq.stdout, pq.stderr))

# Limit clamps: default 30, hard cap 100 — flood 120 one-line hits to see both.
flood = "/proj/flood"
f_folder = os.path.join(home, ".claude", "projects", psess.encode(flood))
for i in range(120):
    fp = os.path.join(f_folder, "flood%03d.jsonl" % i)
    writelines_raw(fp, [{"type": "user", "cwd": flood,
                         "message": {"content": "FloodMark item %d" % i}}])
    os.utime(fp, (now - 1000 - i, now - 1000 - i))
resf, pf = sh(home, "search", "--query", "floodmark")
check("default limit is 30", pf.returncode == 0 and len(resf) == 30, len(resf) if resf else resf)
check("default-limit window keeps the NEWEST 30",
      resf and [r["id"] for r in resf] == ["flood%03d" % i for i in range(30)],
      [r["id"] for r in resf][:5] if resf else resf)
resf2, _ = sh(home, "search", "--query", "floodmark", "--limit", "200")
check("--limit is capped at 100", len(resf2) == 100, len(resf2) if resf2 else resf2)
resf3, _ = sh(home, "search", "--query", "floodmark", "--limit", "5")
check("--limit 5 honored", len(resf3) == 5 and resf3[0]["id"] == "flood000", resf3)
shutil.rmtree(home, ignore_errors=True)

# ---------- B2: destructive failure paths must not lie ----------
# A conversation file is the only copy. `delete` used to answer with exit 0 no
# matter what, so a caller could not tell "gone" from "still there" — and
# pervio-orchestrate's conversation sweep gates its warning on exactly that exit
# code, so an undeletable session vanished from the ledger with nobody told.
# Three outcomes have to be distinguishable: removed / not-found / failed.
print("=== delete + fork failure paths (exit codes tell the truth) ===")
home = tempfile.mkdtemp(prefix="psess_fail_", dir="/tmp")
fdir = "/proj/fail"
ffolder = os.path.join(home, ".claude", "projects", psess.encode(fdir))
keep = os.path.join(ffolder, "keeper.jsonl")
writelines(keep, [{"type": "user", "cwd": fdir, "message": {"content": "hello"}},
                  {"type": "assistant", "message": {"content": [{"type": "text", "text": "hi"}]}}])

d_ok, p_ok = sh(home, "delete", "--dir", fdir, "--session", "keeper")
check("delete of an existing session: exit 0, deleted:true, reason 'removed'",
      p_ok.returncode == 0 and d_ok.get("deleted") is True
      and d_ok.get("reason") == "removed" and not os.path.exists(keep),
      (p_ok.returncode, d_ok))

# not-found is NOT an error: the sweep re-deletes sessions that may already be
# gone, and a non-zero there would cry wolf on every workflow teardown.
d_nf, p_nf = sh(home, "delete", "--dir", fdir, "--session", "keeper")
check("delete of a session that is already gone: exit 0, deleted:false, reason 'not-found'",
      p_nf.returncode == 0 and d_nf.get("deleted") is False
      and d_nf.get("reason") == "not-found", (p_nf.returncode, d_nf))
d_nd, p_nd = sh(home, "delete", "--dir", "/proj/never-existed", "--session", "nope")
check("delete in a project folder that does not exist: same explicit not-found",
      p_nd.returncode == 0 and d_nd.get("deleted") is False
      and d_nd.get("reason") == "not-found", (p_nd.returncode, d_nd))

# a rejected id is a REQUEST error, not "nothing to do"
d_tr, p_tr = sh(home, "delete", "--dir", fdir, "--session", "../../secret")
check("delete of a traversal id: non-zero exit, deleted:false, reason 'rejected'",
      p_tr.returncode != 0 and d_tr is not None and d_tr.get("deleted") is False
      and d_tr.get("reason") == "rejected", (p_tr.returncode, d_tr))

# the one that mattered: unlink() denied by a read-only project folder
victim = os.path.join(ffolder, "undeletable.jsonl")
writelines(victim, [{"type": "user", "cwd": fdir, "message": {"content": "precious"}}])
before = open(victim, "rb").read()
os.chmod(ffolder, 0o555)
try:
    d_ro, p_ro = sh(home, "delete", "--dir", fdir, "--session", "undeletable")
    check("delete that could NOT unlink exits NON-ZERO (no more silent exit 0)",
          p_ro.returncode != 0, (p_ro.returncode, p_ro.stdout, p_ro.stderr[:160]))
    check("...and still answers with machine-readable deleted:false / reason 'failed'",
          d_ro is not None and d_ro.get("deleted") is False
          and d_ro.get("reason") == "failed", (d_ro, p_ro.stdout[:120]))
    check("...and says on stderr why, naming the session",
          "undeletable" in p_ro.stderr, p_ro.stderr[:200])
    check("...and the session file is of course still there, byte-identical",
          open(victim, "rb").read() == before)
finally:
    os.chmod(ffolder, 0o755)

# fork: a write that cannot land must leave NOTHING behind — no empty jsonl the
# phone would offer to resume, no .tmp, and a non-zero exit.
src = os.path.join(ffolder, "forkme.jsonl")
writelines(src, [{"type": "user", "sessionId": "forkme", "uuid": "u1",
                  "cwd": fdir, "message": {"content": "one"}},
                 {"type": "assistant", "sessionId": "forkme", "uuid": "a1",
                  "message": {"content": [{"type": "text", "text": "ack"}]}},
                 {"type": "user", "sessionId": "forkme", "uuid": "u2",
                  "cwd": fdir, "message": {"content": "two"}}])
src_bytes = open(src, "rb").read()
listing_before = sorted(os.listdir(ffolder))
os.chmod(ffolder, 0o555)
try:
    fk, p_fk = sh(home, "fork", "--dir", fdir, "--session", "forkme", "--before", "u2")
    check("fork into a read-only folder exits non-zero", p_fk.returncode != 0,
          (p_fk.returncode, p_fk.stdout[:120]))
    check("fork failure says so on stderr and prints NO session id",
          "fork" in p_fk.stderr.lower() and '"session"' not in p_fk.stdout,
          (p_fk.stderr[:160], p_fk.stdout[:120]))
finally:
    os.chmod(ffolder, 0o755)
check("a failed fork leaves no half file and no .tmp behind",
      sorted(os.listdir(ffolder)) == listing_before, os.listdir(ffolder))
check("a failed fork leaves the ORIGINAL conversation byte-identical",
      open(src, "rb").read() == src_bytes)

# same promise when the bytes stop mid-write rather than at open() time
huge = os.path.join(ffolder, "huge.jsonl")
writelines(huge, [{"type": "user", "sessionId": "huge", "uuid": "h%d" % i, "cwd": fdir,
                   "message": {"content": "pad " * 400 + str(i)}} for i in range(400)]
           + [{"type": "user", "sessionId": "huge", "uuid": "cutme", "cwd": fdir,
               "message": {"content": "cut here"}}])
huge_bytes = open(huge, "rb").read()
listing_before = sorted(os.listdir(ffolder))


def _fsize_cap():
    import resource as _r
    import signal as _s
    _s.signal(_s.SIGXFSZ, _s.SIG_IGN)          # EFBIG instead of dying on a signal
    _r.setrlimit(_r.RLIMIT_FSIZE, (16384, 16384))


p_big = subprocess.run([sys.executable, SESSIONS, "fork", "--dir", fdir,
                        "--session", "huge", "--before", "cutme"],
                       env=dict(os.environ, HOME=home), stdin=subprocess.DEVNULL,
                       capture_output=True, text=True, preexec_fn=_fsize_cap)
check("fork whose write runs out of room exits non-zero", p_big.returncode != 0,
      (p_big.returncode, p_big.stdout[:120], p_big.stderr[:160]))
check("...leaving no partial fork and no .tmp in the folder",
      sorted(os.listdir(ffolder)) == listing_before, os.listdir(ffolder))
check("...and the source conversation untouched", open(huge, "rb").read() == huge_bytes)

shutil.rmtree(home, ignore_errors=True)

# ---------- claude usage: keychain-first token, honest staleness ----------
# The 2026-08-20 bug, pinned: ~/.claude/.credentials.json is a COPY (install.sh
# syncs it); its access token expired on 08-17, the endpoint 401'd, and the
# stale-cache fallback replayed a week-old「Fable 80%」as current against a live
# 38%. Three behaviors below: ① the FRESH token comes from the keychain when
# the keychain answers (the file may be stale); ② a fallback answer says
# "stale": true; ③ a cache older than 48h is refused, not served.
print("=== claude usage: token source + staleness honesty ===")
import threading                                                      # noqa: E402
import time as _time                                                  # noqa: E402
from http.server import BaseHTTPRequestHandler, HTTPServer            # noqa: E402

_auth_seen = []


class _UsageSrv(BaseHTTPRequestHandler):
    def do_GET(self):
        _auth_seen.append(self.headers.get("Authorization") or "")
        body = json.dumps({"five_hour": {"utilization": 4.0, "resets_at": "r5"},
                           "seven_day": {"utilization": 38.0, "resets_at": "r7"},
                           "limits": [{"percent": 38, "resets_at": "rf",
                                       "severity": "ok",
                                       "scope": {"model": {"display_name": "Fable"}}}]}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


_srv = HTTPServer(("127.0.0.1", 0), _UsageSrv)
threading.Thread(target=_srv.serve_forever, daemon=True).start()
_URL = "http://127.0.0.1:%d/usage" % _srv.server_port

home = tempfile.mkdtemp(prefix="psess_usage_", dir="/tmp")
os.makedirs(os.path.join(home, ".claude"), exist_ok=True)
with open(os.path.join(home, ".claude", ".credentials.json"), "w") as f:
    json.dump({"claudeAiOauth": {"accessToken": "FILE-TOKEN-STALE"}}, f)

# A fake `security` first on PATH: answers a FRESH keychain credential blob.
shim = tempfile.mkdtemp(prefix="psess_shim_", dir="/tmp")
_fresh_exp = int((_time.time() + 3600) * 1000)
with open(os.path.join(shim, "security"), "w") as f:
    f.write("#!/bin/sh\nif [ \"${FAKE_KC:-ok}\" = ok ]; then\n"
            "  printf '%s' '{\"claudeAiOauth\":{\"accessToken\":\"KEYCHAIN-TOKEN\","
            "\"expiresAt\":" + str(_fresh_exp) + "}}'\n"
            "  exit 0\nelse\n  exit 44\nfi\n")
os.chmod(os.path.join(shim, "security"), 0o755)
_PATH = shim + ":" + os.environ.get("PATH", "")

# ① keychain answers → the endpoint sees the KEYCHAIN token, and the output is
# fresh (no stale flag), with the scoped pool along for the ride.
out, p = sh(home, "usage", env={"PERVIO_USAGE_URL": _URL, "PATH": _PATH})
check("usage: live answer decoded", isinstance(out, dict) and "five_hour" in out,
      p.stdout[:200])
check("usage: the keychain token is the one on the wire (the file's is stale)",
      _auth_seen and _auth_seen[-1] == "Bearer KEYCHAIN-TOKEN", _auth_seen[-1:])
check("usage: fresh answer carries no stale flag and the scoped pool",
      out.get("stale") is None and out.get("scoped", [{}])[0].get("percent") == 38, out)

# ② keychain refuses → the file token rides (fallback order pinned).
shutil.rmtree(os.path.join(home, ".pervio"), ignore_errors=True)   # drop the 60s cache
out, p = sh(home, "usage", env={"PERVIO_USAGE_URL": _URL, "PATH": _PATH, "FAKE_KC": "no"})
check("usage: without the keychain the file token is the fallback",
      _auth_seen and _auth_seen[-1] == "Bearer FILE-TOKEN-STALE", _auth_seen[-1:])

# ③ live call fails + young cache → served WITH the stale flag.
cachep = os.path.join(home, ".pervio", "usage-cache.json")
os.makedirs(os.path.dirname(cachep), exist_ok=True)
with open(cachep, "w") as f:
    json.dump({"_ts": _time.time() - 3600, "five_hour": {"utilization": 80.0},
               "seven_day": {"utilization": 80.0},
               "scoped": [{"name": "Fable", "percent": 80}]}, f)
out, p = sh(home, "usage", env={"PERVIO_USAGE_URL": "http://127.0.0.1:1/x",
                                "PATH": _PATH})
check("usage: an hour-old fallback is served but SAYS stale",
      isinstance(out, dict) and out.get("stale") is True
      and out.get("scoped", [{}])[0].get("percent") == 80, p.stdout[:200])

# ④ live call fails + week-old cache → refused outright (the shipped lie).
with open(cachep, "w") as f:
    json.dump({"_ts": _time.time() - 7 * 86400, "five_hour": {"utilization": 80.0},
               "seven_day": {"utilization": 80.0}}, f)
out, p = sh(home, "usage", env={"PERVIO_USAGE_URL": "http://127.0.0.1:1/x",
                                "PATH": _PATH})
check("usage: a week-old cache is refused, never presented as current",
      isinstance(out, dict) and "error" in out and "five_hour" not in out,
      p.stdout[:200])

_srv.shutdown()
shutil.rmtree(home, ignore_errors=True)
shutil.rmtree(shim, ignore_errors=True)

# ---------- pins ledger (2026-09-08): list stamp, delete guard, verbs ----------
# ---------- codex ≥0.153: pagination segments + multi-agent sub-threads ----------
# Two store changes observed live 2026-09-12 (codex-cli 0.153.4, VS Code plugin):
#   * a long thread overflows into rollout-<ts>-<tid>_<seg>.jsonl continuation
#     files (same head payload.id, history_base pointer) — ONE conversation that
#     used to list as duplicate rows, with the phone reading only page one;
#   * helper sub-threads (thread_source "subagent", parent_thread_id) get their
#     own rollouts — codex refuses to resume them, so listing them made dead rows
#     (three identical "# Context from my IDE setup:" rows on the phone).
print("=== codex 0.153: segments merge, sub-threads hide ===")
import time as _time
hx = tempfile.mkdtemp(prefix="psess_cx153_", dir="/tmp")
cxd = "/proj/cx153"
day = os.path.join(hx, ".codex", "sessions", "2026", "09", "12")
TID = "01aaaaaa-1111-2222-3333-444444444444"
SEG = "01bbbbbb-1111-2222-3333-444444444444"
SUB = "01cccccc-1111-2222-3333-444444444444"
page1 = os.path.join(day, "rollout-2026-09-12T08-00-00-%s.jsonl" % TID)
page2 = os.path.join(day, "rollout-2026-09-12T09-00-00-%s_%s.jsonl" % (TID, SEG))
subf = os.path.join(day, "rollout-2026-09-12T10-00-00-%s.jsonl" % SUB)
writelines(page1, [
    {"type": "session_meta", "payload": {"id": TID, "cwd": cxd, "thread_source": "user"}},
    {"type": "response_item", "payload": {"type": "message", "role": "user",
        "content": [{"type": "input_text", "text": "# Context from my IDE setup: tabs, files, blah"}]}},
    {"type": "response_item", "payload": {"type": "message", "role": "user",
        "content": [{"type": "input_text", "text": "page-one question"}]}},
    {"type": "response_item", "payload": {"type": "message", "role": "assistant",
        "content": [{"type": "output_text", "text": "page-one answer"}]}},
    {"type": "event_msg", "payload": {"type": "token_count",
        "info": {"last_token_usage": {"input_tokens": 100}, "model_context_window": 1000}}},
    {"type": "turn_context", "payload": {"model": "gpt-old"}},
])
writelines(page2, [
    {"type": "session_meta", "payload": {"id": TID, "cwd": cxd, "thread_source": "user",
        "history_base": {"thread_id": TID, "end_ordinal_exclusive": 5}}},
    {"type": "response_item", "payload": {"type": "message", "role": "user",
        "content": [{"type": "input_text", "text": "page-two question"}]}},
    {"type": "response_item", "payload": {"type": "message", "role": "assistant",
        "content": [{"type": "output_text", "text": "page-two answer"}]}},
    {"type": "event_msg", "payload": {"type": "token_count",
        "info": {"last_token_usage": {"input_tokens": 777}, "model_context_window": 2000}}},
    {"type": "turn_context", "payload": {"model": "gpt-new"}},
])
writelines(subf, [
    {"type": "session_meta", "payload": {"id": SUB, "cwd": cxd, "session_id": TID,
        "thread_source": "subagent", "parent_thread_id": TID}},
    {"type": "response_item", "payload": {"type": "message", "role": "user",
        "content": [{"type": "input_text", "text": "helper-only CX153NEEDLE"}]}},
    {"type": "response_item", "payload": {"type": "message", "role": "assistant",
        "content": [{"type": "output_text", "text": "helper answer"}]}},
])
_now = _time.time()
os.utime(page1, (_now - 100, _now - 100))   # page two is the freshest — the row must say so
os.utime(page2, (_now, _now))
os.utime(subf, (_now - 50, _now - 50))
lst, _ = sh(hx, "list", "--dir", cxd)
cx_rows = [s for s in (lst or []) if s.get("backend") == "codex"]
check("C1 one row per thread: segment folds in, sub-thread hidden",
      [s["id"] for s in cx_rows] == [TID], cx_rows)
row = cx_rows[0] if cx_rows else {}
check("C2 preview is the opener, IDE preamble skipped", row.get("preview") == "page-one question", row)
check("C3 row wears the NEWEST page's mtime and the SUMMED bytes",
      row.get("modified") == int(os.path.getmtime(page2))
      and row.get("bytes") == os.path.getsize(page1) + os.path.getsize(page2), row)
tr, _ = sh(hx, "transcript", "--dir", cxd, "--session", TID, "--backend", "codex")
check("C4 transcript stitches pages in order, no preamble bubble",
      [(t["role"], t["text"]) for t in (tr or [])] == [
          ("user", "page-one question"), ("assistant", "page-one answer"),
          ("user", "page-two question"), ("assistant", "page-two answer")], tr)
ctx, _ = sh(hx, "context", "--dir", cxd, "--session", TID, "--backend", "codex")
check("C5 context ring reads the newest page (used/window/model)",
      (ctx or {}).get("used") == 777 and ctx.get("window") == 2000 and ctx.get("model") == "gpt-new", ctx)
srch, _ = sh(hx, "search", "--query", "CX153NEEDLE")
check("C6 search never surfaces a sub-thread", srch == [], srch)
srch, _ = sh(hx, "search", "--query", "page-two answer")
check("C7 a hit inside a segment opens as the THREAD (id = thread id)",
      len(srch or []) == 1 and srch[0]["id"] == TID and srch[0]["backend"] == "codex", srch)

# ---- the IDE preamble WRAPS the real question (codex_vscode 0.153.4) ----
# One user message = "# Context from my IDE setup: …\n## My request:\n<question>".
# The 2026-09-12 fix dropped these messages wholesale — six of the user's own
# turns vanished from a live thread's transcript ("我的提问丢了", 2026-09-15).
# The rule now UNWRAPS: show the request, hide only context-only preambles.
wrapped = ("# Context from my IDE setup:\n\n## Active file: /x/y.csv\n"
           "## Open tabs:\n- y.csv\n\n## My request:\n我刚刚的对话呢？？？设计人工测评")
# writelines_raw: search's byte pre-filter matches the store's real raw-UTF-8
# serialization; escaped \uXXXX fixtures would dodge it and fail C9 falsely.
writelines_raw(os.path.join(day, "rollout-2026-09-12T11-00-00-%s_%s.jsonl" % (TID, "01dddddd-1111-2222-3333-444444444444")), [
    {"type": "session_meta", "payload": {"id": TID, "cwd": cxd, "thread_source": "user",
        "history_base": {"thread_id": TID, "end_ordinal_exclusive": 9}}},
    {"type": "response_item", "payload": {"type": "message", "role": "user",
        "content": [{"type": "input_text", "text": wrapped}]}},
    {"type": "response_item", "payload": {"type": "message", "role": "assistant",
        "content": [{"type": "output_text", "text": "在的,任务上下文都在"}]}},
])
tr, _ = sh(hx, "transcript", "--dir", cxd, "--session", TID, "--backend", "codex")
utexts = [t["text"] for t in (tr or []) if t["role"] == "user"]
check("C8 a wrapped question SURVIVES the transcript, boilerplate stripped",
      "我刚刚的对话呢？？？设计人工测评" in utexts
      and not any("Active file" in t for t in utexts), utexts)
srch, _ = sh(hx, "search", "--query", "设计人工测评")
check("C9 search finds the unwrapped question",
      len(srch or []) == 1 and srch[0]["id"] == TID, srch)
srch, _ = sh(hx, "search", "--query", "Active file")
check("C9b …but never the boilerplate around it", srch == [], srch)
shutil.rmtree(hx, ignore_errors=True)

# ---------- codex-takeover: free a thread another client holds ----------
# codex >=0.153 keeps ~/.codex/thread-writer-locks/<id>.lock OPEN for as long
# as a client (VS Code's plugin) has the conversation panel up, and refuses
# every other resume. The phone's "强制接管" ends that holder — and ONLY a
# holder that is a codex process and not one of the app's own runs.
print("=== codex-takeover ===")
import subprocess as _sp, time as _time, signal as _sig
ht = tempfile.mkdtemp(prefix="psess_tk_", dir="/tmp")
locks = os.path.join(ht, ".codex", "thread-writer-locks"); os.makedirs(locks)
TK = "01aaaaaa-0000-4000-8000-000000000001"
lock = os.path.join(locks, TK + ".lock"); open(lock, "w").close()
j, r = sh(ht, "codex-takeover", "--session", TK)
check("T1 an unheld lock is a corpse: released, nothing killed",
      r.returncode == 0 and (j or {}).get("released") is True and j.get("reason") == "unheld", r.stdout)
# a fake codex: an executable literally named `codex` (lsof reports the
# executable's basename) that holds the lock open — tail -f does exactly that
fake = os.path.join(ht, "bin"); os.makedirs(fake)
# lsof reports the REAL executable name (a symlink named codex still shows as
# tail, and a copied system binary is killed by the loader), so compile a tiny
# holder literally named `codex`: open the lock, sleep forever.
csrc = os.path.join(ht, "holder.c")
open(csrc, "w").write("#include <fcntl.h>\n#include <unistd.h>\nint main(int c,char**v){open(v[1],O_RDONLY);for(;;)pause();}\n")
_cc = _sp.run(["cc", "-o", os.path.join(fake, "codex"), csrc], capture_output=True)
assert _cc.returncode == 0, _cc.stderr.decode()[:200]
holder = _sp.Popen([os.path.join(fake, "codex"), lock], stdout=_sp.DEVNULL, stderr=_sp.DEVNULL)
# Wait until the holder really holds the lock: macOS vets a freshly built
# binary on its first exec (~0.6 s measured 2026-10-18), so a fixed half-second
# nap raced it and the takeover found an "unheld" lock.
for _ in range(100):
    if str(holder.pid) in _sp.run(["lsof", "-t", "--", lock], capture_output=True, text=True).stdout.split():
        break
    _time.sleep(0.1)
j, r = sh(ht, "codex-takeover", "--session", TK)
check("T2 a codex holder is ended and the lock reported free",
      r.returncode == 0 and (j or {}).get("released") is True and holder.pid in (j.get("killed") or []), r.stdout)
for _ in range(20):
    if holder.poll() is not None: break
    _time.sleep(0.1)
check("T2b …and it really is dead", holder.poll() is not None, holder.poll())
# a NON-codex holder must never be touched
other = _sp.Popen(["/usr/bin/tail", "-f", lock], stdout=_sp.DEVNULL, stderr=_sp.DEVNULL)
_time.sleep(0.5)
j, r = sh(ht, "codex-takeover", "--session", TK)
check("T3 a non-codex holder is refused (reason not-codex), process untouched",
      r.returncode == 1 and (j or {}).get("reason") == "not-codex" and other.poll() is None, (r.stdout, other.poll()))
other.kill(); other.wait()
# the app's OWN running detached run must never be killed by its own takeover
mine = _sp.Popen([os.path.join(fake, "codex"), lock], stdout=_sp.DEVNULL, stderr=_sp.DEVNULL, start_new_session=True)
_time.sleep(0.5)
rd = os.path.join(ht, ".pervio", "runs", "r1"); os.makedirs(rd)
open(os.path.join(rd, "status"), "w").write("running")
open(os.path.join(rd, "pgid"), "w").write(str(os.getpgid(mine.pid)))
j, r = sh(ht, "codex-takeover", "--session", TK)
check("T4 a holder that is the app's own running run is refused (own-run)",
      r.returncode == 1 and (j or {}).get("reason") == "own-run" and mine.poll() is None, (r.stdout, mine.poll()))
mine.kill(); mine.wait()
j, r = sh(ht, "codex-takeover", "--session", "../evil")
check("T5 an unsafe id is rejected", r.returncode == 1 and (j or {}).get("reason") == "rejected", r.stdout)
shutil.rmtree(ht, ignore_errors=True)

# sh() hands back (parsed JSON or None, CompletedProcess).
print("=== pins ledger ===")
import base64
h2 = tempfile.mkdtemp(prefix="psess_pins_", dir="/tmp")
d = "/Users/t/proj"
pdir = os.path.join(h2, ".claude", "projects", psess.encode(d))
os.makedirs(pdir)
for sid in ("aaa1", "bbb2"):
    writelines(os.path.join(pdir, sid + ".jsonl"),
               [{"type": "user", "message": {"role": "user", "content": "hi " + sid}}])
j, r = sh(h2, "pin", "--dir", d, "--session", "aaa1", "--at", "1700000000")
check("P1 pin lands with the given instant",
      r.returncode == 0 and (j or {}).get("pinned") is True and (j or {}).get("at") == 1700000000, r.stdout)
j, r = sh(h2, "pin", "--dir", d, "--session", "aaa1", "--at", "1800000000")
check("P1b pin is idempotent and keeps the FIRST instant (phone order survives replay)",
      (j or {}).get("at") == 1700000000, r.stdout)
j, r = sh(h2, "list", "--dir", d)
rows = {x["id"]: x for x in (j or [])}
check("P2 list stamps pinned + pinnedAt on every row",
      rows.get("aaa1", {}).get("pinned") is True and rows.get("aaa1", {}).get("pinnedAt") == 1700000000
      and rows.get("bbb2", {}).get("pinned") is False and "pinnedAt" not in rows.get("bbb2", {}), rows)
j, r = sh(h2, "delete", "--dir", d, "--session", "aaa1")
check("P3 delete REFUSES a pinned session: rc 1, reason pinned, file intact",
      r.returncode == 1 and (j or {}).get("reason") == "pinned"
      and os.path.exists(os.path.join(pdir, "aaa1.jsonl")), (r.returncode, r.stdout, r.stderr[-80:]))
j, r = sh(h2, "delete", "--dir", d, "--session", "bbb2")
check("P4 an unpinned delete still works", (j or {}).get("deleted") is True, r.stdout)
payload = base64.b64encode(json.dumps({"ccc3": 1600000000, "aaa1": 1900000000}).encode()).decode()
j, r = sh(h2, "pins-merge", "--dir", d, "--b64", payload)
check("P5 merge adds new ids, never overwrites, never removes",
      (j or {}).get("pins") == {"aaa1": 1700000000, "ccc3": 1600000000}, r.stdout)
j, r = sh(h2, "unpin", "--session", "aaa1")
jp, _ = sh(h2, "pins")
check("P6 unpin drops it from the ledger",
      (j or {}).get("pinned") is False and "aaa1" not in (jp or {}).get("pins", {}), r.stdout)
sh(h2, "pin", "--dir", d, "--session", "aaa1")
j, r = sh(h2, "delete", "--dir", d, "--session", "aaa1", "--force")
jp, _ = sh(h2, "pins")
check("P7 --force deletes AND drops the pin",
      (j or {}).get("deleted") is True and "aaa1" not in (jp or {}).get("pins", {})
      and not os.path.exists(os.path.join(pdir, "aaa1.jsonl")), r.stdout)
pp = os.path.join(h2, ".pervio", "chat", "pins.json")
check("P8 the ledger file is 0600", oct(os.stat(pp).st_mode & 0o777) == "0o600", oct(os.stat(pp).st_mode & 0o777))
open(pp, "w").write("{corrupt")
j, r = sh(h2, "list", "--dir", d)
check("P9 a corrupt ledger never takes the list down (rows unpinned)",
      r.returncode == 0 and all(x.get("pinned") is False for x in (j or [])), r.stdout[:80])
j, r = sh(h2, "pin", "--dir", d, "--session", "../evil")
check("P10 pin rejects an unsafe id", r.returncode != 0, r.stdout)
shutil.rmtree(h2, ignore_errors=True)

# ---------- Cursor chats ----------
print("=== cursor chats ===")
import hashlib
h3 = tempfile.mkdtemp(prefix="psess_cursor_", dir="/tmp")
proj = os.path.join(h3, "proj"); os.makedirs(proj)
cid = "d23e0adb-7bd0-4f4f-b8df-f1b714781230"
ws = os.path.join(h3, ".cursor", "chats", hashlib.md5(os.path.realpath(proj).encode()).hexdigest())
os.makedirs(os.path.join(ws, cid))
with open(os.path.join(ws, cid, "meta.json"), "w") as f:
    # cwd in the HOME spelling: the search's temp-dir rule hides /private/tmp paths
    # outside $HOME, and this hermetic HOME is itself under /tmp (same as the
    # claude fixtures' rule); the chat folder hash still uses the realpath, as Cursor does.
    json.dump({"schemaVersion": 1, "createdAtMs": 1791991909553, "hasConversation": True, "updatedAtMs": 1791992029195, "cwd": proj}, f)
tfp = os.path.join(h3, ".cursor", "projects", "slug-of-proj", "agent-transcripts", cid, cid + ".jsonl")
writelines_raw(tfp, [          # Cursor writes raw UTF-8 (Node's JSON.stringify), like the real file
    {"role": "user", "message": {"content": [{"type": "text", "text": "<timestamp>Wed</timestamp>\n<user_query>\n把 list 加分页\n</user_query>"}]}},
    {"role": "assistant", "message": {"content": [{"type": "text", "text": "先看代码。"}, {"type": "tool_use", "name": "Shell", "input": {"command": "ls src", "description": "look"}}]}},
    {"role": "assistant", "message": {"content": [{"type": "tool_use", "name": "Write", "input": {"path": "/x/src/page.py", "contents": "..."}}]}},
    {"role": "assistant", "message": {"content": [{"type": "text", "text": "DONE"}]}},
    {"type": "turn_ended", "status": "success"},
    {"role": "user", "message": {"content": [{"type": "text", "text": "<timestamp>Wed</timestamp>\n<user_query>\n<pervio-group id=\"abc\" from=\"human\" role=\"伙伴 2\" round=\"1\" to=\"m0\">\n规则\n</pervio-group>\n组里问的\n</user_query>"}]}},
    {"role": "assistant", "message": {"content": [{"type": "text", "text": "组里答的"}]}},
])
rows, r = sh(h3, "list", "--dir", proj)
cu = [x for x in (rows or []) if x.get("backend") == "cursor"]
check("C1 list shows the cursor chat for its cwd, titled by the person's words (wrappers stripped)",
      len(cu) == 1 and cu[0]["id"] == cid and cu[0]["preview"] == "把 list 加分页" and cu[0]["modified"] == 1791992029, (rows, r.stderr[-200:]))
rows, r = sh(h3, "list", "--dir", os.path.join(h3, "elsewhere"))
check("C1a another dir does not list it", not any(x.get("backend") == "cursor" for x in (rows or [])), rows)
tr, r = sh(h3, "transcript", "--dir", proj, "--session", cid, "--backend", "cursor")
check("C2 transcript: user text unwrapped; consecutive assistant lines fold into one turn with Bash + Write tool labels",
      tr and tr[0]["role"] == "user" and tr[0]["text"] == "把 list 加分页" and tr[1]["role"] == "assistant"
      and tr[1]["text"] == "先看代码。\n\nDONE" and tr[1]["tools"] == ["Bash  ls src", "Write  .../src/page.py"]
      and [b["t"] for b in tr[1]["blocks"]] == ["text", "tool", "tool", "text"], tr)
check("C2a a group-wrapped user turn shows the words with via=human",
      tr and tr[2]["text"] == "组里问的" and tr[2].get("via") == "human", tr[2:] if tr else tr)
tr, r = sh(h3, "transcript", "--dir", os.path.join(h3, "elsewhere"), "--session", cid, "--backend", "cursor")
check("C2b the transcript is bound to --dir", tr == [], tr)
ctx, r = sh(h3, "context", "--dir", proj, "--session", cid, "--backend", "cursor")
check("C3 context answers zeros (Cursor keeps no usage in its transcript)", ctx == {"used": 0, "model": ""}, ctx)
hits, r = sh(h3, "search", "--query", "加分页")
check("C4 search finds the cursor chat with a snippet and its project",
      hits and hits[0]["backend"] == "cursor" and hits[0]["id"] == cid and hits[0]["project"] == proj, hits)
res, r = sh(h3, "delete", "--dir", proj, "--session", cid, "--backend", "cursor")
check("C5 delete removes the chat folder and the transcript folder",
      res == {"deleted": True, "reason": "removed"} and not os.path.exists(os.path.join(ws, cid)) and not os.path.exists(os.path.dirname(tfp)), (res, r.stderr))
res, r = sh(h3, "delete", "--dir", proj, "--session", cid, "--backend", "cursor")
check("C5a deleting again is a not-found, exit 0", res == {"deleted": False, "reason": "not-found"} and r.returncode == 0, (res, r.returncode))
shutil.rmtree(h3, ignore_errors=True)

ok = all(results)
print("\n=== pervio-sessions: %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
