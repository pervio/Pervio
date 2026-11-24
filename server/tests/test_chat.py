#!/usr/bin/env python3
"""Regression tests for pervio-chat's LIVE-CHANNEL wiring (heartbeats included).
Drives the REAL bash script with the committed claude shim (no model calls) and
PERVIO_HB_IDLE shrunk, so a ~2s silent "tool" draws heartbeats in test time.

Covers the two live paths:
  - plain chat:      claude | pervio-hb
  - approval chat:   pervio-chat-stream (tee events.jsonl) | pervio-hb
and asserts on each: heartbeat lines appear during silence, every stdout line
stays whole JSON (nothing torn by the extra pipe), init/result flow through, and
claude's exit code survives. The approval path additionally checks the branch
was really taken (--permission-prompt-tool in claude's argv), the mid-turn
events tee still works downstream of pervio-hb, and --cleanup removes the
session dir. Guards the D-2 fix: the approval channel used to bypass pervio-hb
entirely, so an approved long-silent tool tripped the phone's 240s watchdog.

Also covers the Pervio attachment states (F design): --pervio-context on the
claude branch mounts the perviotools MCP server (mcp.json + --mcp-config) with
the seven read-only tools allowlisted — the pointer prose is RETIRED there; the
approval path merges perviotools into the SAME mcp.json as the approve server;
PERVIO_WF_ID (machine turn) outranks the flag; and the codex branch mounts the
same server READ-ONLY per invocation (-c mcp_servers.perviotools overrides +
PERVIO_MCP_RO=1 — codex has no approval channel, so the server enforces the
gate) with a per-turn discovery prefix, degrading to the legacy brief pointer
on an old deployment without pervio-mcp."""
import base64
import json
import signal
import os
import shutil
import subprocess
import sys
import tempfile
import time
os.environ.setdefault("PERVIO_RUN_IDLE_GRACE", "1.5")   # a living run ends a beat after its reply here, not 180 s

HERE = os.path.dirname(os.path.realpath(__file__))
CHAT = os.path.realpath(os.path.join(HERE, "..", "bin", "pervio-chat"))
SHIM = os.path.join(HERE, "shim")

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + (("  [" + str(detail)[:200] + "]") if (detail and not cond) else ""))


def b64(s):
    return base64.b64encode(s.encode()).decode()


def env_for(home, **extra):
    e = dict(os.environ, HOME=home, PATH=SHIM + os.pathsep + os.environ.get("PATH", ""),
             PERVIO_HB_IDLE="0.3")
    e.update(extra)
    return e


def parse_lines(text):
    objs, torn = [], []
    for l in text.splitlines():
        if not l.strip():
            continue
        try:
            objs.append(json.loads(l))
        except ValueError:
            torn.append(l)
    return objs, torn


# ---------- plain chat path: claude | pervio-hb ----------
print("=== plain chat (claude | pervio-hb) ===")
home = tempfile.mkdtemp(prefix="pchat_plain_", dir="/tmp")
prompt = 'hi\nSHIM:{"sleep": 2.2, "text": "plain done"}'
p = subprocess.run([CHAT, "--dir", home, "--perm", "default", "--prompt-b64", b64(prompt)],
                   env=env_for(home), capture_output=True, text=True, timeout=60)
objs, torn = parse_lines(p.stdout)
check("every stdout line is whole JSON", objs and not torn, torn or p.stderr)
check("heartbeats injected during the silent gap",
      any(o.get("type") == "heartbeat" for o in objs), [o.get("type") for o in objs])
check("init + result flow through untouched",
      any(o.get("subtype") == "init" for o in objs)
      and any(o.get("type") == "result" and o.get("result") == "plain done" for o in objs),
      objs)
check("exit code passes through the hb pipe", p.returncode == 0, p.returncode)
shutil.rmtree(home, ignore_errors=True)

# ---------- approval path: pervio-chat-stream | pervio-hb ----------
print("=== approval chat (chat-stream tee | pervio-hb) ===")
home = tempfile.mkdtemp(prefix="pchat_appr_", dir="/tmp")
sid = "hbtest1"
argv_log = os.path.join(home, "argv.jsonl")
prompt = 'go\nSHIM:{"sleep": 2.2, "text": "approve done", "rc": 5}'
p = subprocess.Popen([CHAT, "--dir", home, "--perm", "default", "--approve-sid", sid,
                      "--prompt-b64", b64(prompt)],
                     env=env_for(home, SHIM_ARGV_LOG=argv_log),
                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
first = p.stdout.readline()
# First output line ⇒ the session dir + events.jsonl exist and the tee is live.
# Append a pending-approval event mid-turn, like pervio-approve would while blocked.
ev = {"type": "permission_request", "request_id": "r1", "tool_name": "Bash",
      "tool_use_id": "tu1", "input": {"command": "ls"}}
with open(os.path.join(home, ".pervio", "chat", sid, "events.jsonl"), "a") as f:
    f.write(json.dumps(ev) + "\n")
rest = p.stdout.read()
rc = p.wait(timeout=60)

objs, torn = parse_lines(first + rest)
check("every stdout line is whole JSON", objs and not torn, torn)
check("heartbeats injected on the approval channel (the D-2 gap)",
      any(o.get("type") == "heartbeat" for o in objs), [o.get("type") for o in objs])
check("mid-turn events.jsonl line teed through to the channel",
      any(o.get("type") == "permission_request" and o.get("request_id") == "r1" for o in objs), objs)
check("init + result flow through untouched",
      any(o.get("subtype") == "init" for o in objs)
      and any(o.get("type") == "result" and o.get("result") == "approve done" for o in objs),
      objs)
check("claude's exit code survives chat-stream AND the hb pipe", rc == 5, rc)
check("--cleanup removed the session dir",
      not os.path.exists(os.path.join(home, ".pervio", "chat", sid)))
argvs = []
try:
    with open(argv_log) as f:
        argvs = [json.loads(l) for l in f if l.strip()]
except OSError:
    pass
check("approval branch really ran claude with the permission-prompt tool",
      any("--permission-prompt-tool" in a and "mcp__pervio__approve" in a for a in argvs), argvs)
shutil.rmtree(home, ignore_errors=True)

# ---------- approval sid is a security boundary ----------
# The sid becomes a DIRECTORY that gets rmtree'd at the end of the turn and is
# interpolated into mcp.json. Proven 2026-08-06: `--approve-sid ../..` resolved
# the session dir to $HOME and the cleanup deleted the home directory's
# contents. Both the allowlist (pervio-chat) and the cleanup guard
# (pervio-chat-stream) are pinned here, with a canary as the real proof.
print("=== approve-sid allowlist (home-wipe regression) ===")
for bad in ["../..", "a/b", "..", ".", 'x"},"command":"sh","args":["-c","id"],"p":{"b":"',
            "x" * 65, "sid with space"]:
    home = tempfile.mkdtemp(prefix="pchat_sid_", dir="/tmp")
    os.makedirs(os.path.join(home, ".pervio", "chat"), exist_ok=True)
    canary = os.path.join(home, "canary.txt")
    with open(canary, "w") as f:
        f.write("PRECIOUS")
    p = subprocess.run([CHAT, "--dir", home, "--perm", "default", "--approve-sid", bad,
                        "--prompt-b64", b64('hi\nSHIM:{"text": "ok"}')],
                       env=env_for(home), capture_output=True, text=True, timeout=60)
    check("bad sid %r rejected non-zero, canary intact" % (bad[:18],),
          p.returncode != 0 and os.path.exists(canary), (p.returncode, p.stderr[:120]))
    shutil.rmtree(home, ignore_errors=True)

# A well-formed sid still works end to end (the allowlist must not break the feature).
home = tempfile.mkdtemp(prefix="pchat_sid_ok_", dir="/tmp")
canary = os.path.join(home, "canary.txt")
with open(canary, "w") as f:
    f.write("PRECIOUS")
p = subprocess.run([CHAT, "--dir", home, "--perm", "default", "--approve-sid", "good-SID_123",
                    "--prompt-b64", b64('hi\nSHIM:{"text": "ok"}')],
                   env=env_for(home), capture_output=True, text=True, timeout=60)
check("valid sid still runs and cleans only its own dir",
      p.returncode == 0 and os.path.exists(canary)
      and not os.path.exists(os.path.join(home, ".pervio", "chat", "good-SID_123")),
      (p.returncode, p.stderr[:120]))
shutil.rmtree(home, ignore_errors=True)

# ---------- Pervio attachment: five states (F design) ----------
# The claude branch RETIRED the pointer prose: with --pervio-context it mounts
# the perviotools MCP server instead (mcp.json + --mcp-config) and allowlists
# the SEVEN read-only tools; the write/spend tools (pervio_start, pervio_rerun,
# pervio_schedule, pervio_feedback) stay off the allowlist so they take the
# approval flow.
# PERVIO_WF_ID (machine turn) outranks the flag as defense in depth. The codex
# branch mounts the same server read-only via per-invocation -c overrides plus
# a per-turn discovery prefix (state e). SHIM_ARGV_LOG exposes the child's
# real argv.

RO_TOOLS = ["mcp__perviotools__pervio_list_runs",
            "mcp__perviotools__pervio_ledger",
            "mcp__perviotools__pervio_templates",
            "mcp__perviotools__pervio_archives",
            "mcp__perviotools__pervio_schedules",
            "mcp__perviotools__pervio_sessions",
            "mcp__perviotools__pervio_transcript"]
# The write/spend verbs that must NEVER be allowlisted (approval flow instead).
# Checked as exact list members: pervio_schedule (write) is a PREFIX of the
# read-only pervio_schedules, so a substring test would false-positive.
WRITE_TOOLS = ["mcp__perviotools__pervio_start",
               "mcp__perviotools__pervio_rerun",
               "mcp__perviotools__pervio_schedule",
               "mcp__perviotools__pervio_feedback"]

BASE_PROMPT = 'hi\nSHIM:{"text": "ok"}'


def _stub_pervio_mcp(home):
    """The mount gates on pervio-mcp existing (repo server/bin first, then
    ~/.pervio/bin). Stub the hermetic-HOME fallback so these states stay
    deterministic whether or not the repo copy exists on this checkout."""
    d = os.path.join(home, ".pervio", "bin")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "pervio-mcp"), "w") as f:
        f.write("#!/usr/bin/env python3\n")


def _flag_val(a, flag):
    return a[a.index(flag) + 1] if flag in a else None


def _run_ctx_case(prefix, extra_argv, wf_id=None, perm="plan", backend=None,
                  chat_bin=CHAT, stub=True):
    home = tempfile.mkdtemp(prefix=prefix, dir="/tmp")
    if stub:                               # stub=False: the pervio-mcp-missing variant
        _stub_pervio_mcp(home)
    argv_log = os.path.join(home, "argv.jsonl")
    env = env_for(home, SHIM_ARGV_LOG=argv_log, PERVIO_CODEX_EXEC="1")   # argv assertions = the exec path; CXA covers app-server
    env.pop("PERVIO_WF_ID", None)          # a stray outer wf id must not skew states
    if wf_id is not None:
        env["PERVIO_WF_ID"] = wf_id
    cmd = [chat_bin, "--dir", home, "--perm", perm]
    if backend:
        cmd += ["--backend", backend]
    p = subprocess.run(cmd + extra_argv + ["--prompt-b64", b64(BASE_PROMPT)],
                       env=env, capture_output=True, text=True, timeout=60)
    argvs = []
    try:
        with open(argv_log) as f:
            argvs = [json.loads(l) for l in f if l.strip()]
    except OSError:
        pass
    shutil.rmtree(home, ignore_errors=True)
    return p, argvs


# (a) no flag → the default conversation is fully native: no MCP mount, no
# perviotools allowlist, no system-prompt injection. plan perm keeps the
# approval path (which owns its own mcp.json) out of the picture entirely.
print("=== pervio state a: no flag => zero attachment ===")
p, argvs = _run_ctx_case("pchat_mcp_off_", [])
check("shim ran (argv captured)", bool(argvs), p.stderr)
check("no flag: argv has NO --mcp-config",
      argvs and all(_flag_val(a, "--mcp-config") is None for a in argvs), argvs)
check("no flag: NO perviotools in any --allowedTools",
      argvs and all("perviotools" not in (_flag_val(a, "--allowedTools") or "") for a in argvs),
      argvs)
check("no flag: NO --append-system-prompt (fully native default)",
      argvs and all("--append-system-prompt" not in a for a in argvs), argvs)
check("no flag: NO background --add-dir (native read surface untouched)",
      argvs and all(not any(a[i + 1].endswith(("/.claude/projects", "/.pervio/memory"))
                            for i, x in enumerate(a) if x == "--add-dir")
                    for a in argvs), argvs)

# (b) --pervio-context (plan perm) → the MCP mount rides EVERY invocation
# (structurally compaction-immune, same argument as the old pointer), the
# mcp.json declares perviotools -> pervio-mcp, the seven read-only tools are
# allowlisted verbatim, and the pointer prose is GONE from the claude branch.
print("=== pervio state b: --pervio-context => MCP mount on every call ===")
p, argvs = _run_ctx_case("pchat_mcp_on_", ["--pervio-context"])
cfgs = [_flag_val(a, "--mcp-config") for a in argvs]
check("--mcp-config rides every invocation", argvs and all(cfgs), argvs or p.stderr)
cfg_obj = {}
try:
    with open(cfgs[0]) as f:
        cfg_obj = json.load(f)
except (OSError, ValueError, IndexError, TypeError):
    pass
_srv = (cfg_obj.get("mcpServers") or {}).get("perviotools") or {}
check("mcp.json declares perviotools -> python3 .../pervio-mcp",
      _srv.get("command") == "python3" and _srv.get("args")
      and _srv["args"][0].endswith("/pervio-mcp"), cfg_obj)
check("the tools are told the conversation's permission mode and its directory (the ceiling a model-written workflow is held to, 2026-11-21)",
      (_srv.get("env") or {}).get("PERVIO_MCP_CEILING") in ("plan", "default", "acceptEdits", "auto", "bypassPermissions")
      and os.path.isabs((_srv.get("env") or {}).get("PERVIO_MCP_DIR", "")), _srv)
_allows = [(_flag_val(a, "--allowedTools") or "").split(",") for a in argvs]
check("all seven read-only tools allowlisted (exact names, comma list) on every call",
      argvs and all(all(t in al for t in RO_TOOLS) for al in _allows), _allows)
check("write/spend tools NOT allowlisted (they take the approval flow)",
      _allows and all(all(w not in al for w in WRITE_TOOLS) for al in _allows), _allows)
# F3 named template tools (mcp__perviotools__pervio_run_<slug>) spend model
# quota like pervio_start — the allowlist must stay EXACTLY the seven read-only
# names, so every named tool falls into the approval flow by construction.
check("allowlist is EXACTLY the seven read-only names (no pervio_run_* mixed in)",
      _allows and all(al == RO_TOOLS for al in _allows), _allows)
# The brief-length prose stays retired, but a one-line DISCOVERY pointer is
# load-bearing: claude defers MCP tools behind ToolSearch (probed 2026-08-04 —
# init lists only native tools, mcp_servers "pending"), so without the line
# the mounted verbs are invisible to implicit asks ("跑一下xx工作流" went
# hunting ~/.claude/workflows instead).
_ptrs = [_flag_val(a, "--append-system-prompt") or "" for a in argvs]
check("discovery pointer rides every invocation (perviotools + ToolSearch hint)",
      argvs and all("mcp__perviotools__" in pt and "ToolSearch" in pt for pt in _ptrs),
      _ptrs)
check("discovery pointer keeps the narration suppressor and stays one-line short",
      _ptrs and all("不要主动提及" in pt and len(pt) < 500 for pt in _ptrs),
      [len(pt) for pt in _ptrs])
# The chip must NOT widen the file read surface. The background-dir grant
# (~/.claude/projects + ~/.pervio/memory) existed only for the retired 取背景
# playbook; leaving it would mean "opt into workflow tools" silently bought
# approval-free reads of every past conversation. Only the uploads dir — the
# attachment precedent, present on every claude call — may appear.
def _bg_dirs(a):
    return [a[i + 1] for i, x in enumerate(a) if x == "--add-dir"
            and not a[i + 1].endswith("/.pervio/uploads")]
check("flagged call adds NO background dirs beyond uploads (chip ≠ read surface)",
      argvs and all(_bg_dirs(a) == [] for a in argvs), argvs)
for c in set(c for c in cfgs if c):     # the per-invocation cfg lives in TMPDIR
    try:
        os.unlink(c)
    except OSError:
        pass

# (c) flag AND PERVIO_WF_ID → the machine gate outranks the flag: a workflow
# step that leaked the flag still runs clean — no MCP, no allowlist, no prose
# (unattended runs must not grow user-facing tool surface).
print("=== pervio state c: flag + PERVIO_WF_ID => machine gate wins ===")
p, argvs = _run_ctx_case("pchat_mcp_wf_", ["--pervio-context"], wf_id="x")
check("shim ran (argv captured)", bool(argvs), p.stderr)
check("machine turn: NO --mcp-config despite the flag",
      argvs and all(_flag_val(a, "--mcp-config") is None for a in argvs), argvs)
check("machine turn: NO perviotools allowlist, NO --append-system-prompt",
      argvs and all("perviotools" not in (_flag_val(a, "--allowedTools") or "")
                    and "--append-system-prompt" not in a for a in argvs), argvs)
check("machine turn: NO background --add-dir either",
      argvs and all(not any(a[i + 1].endswith(("/.claude/projects", "/.pervio/memory"))
                            for i, x in enumerate(a) if x == "--add-dir")
                    for a in argvs), argvs)

# (d) flag + default perm + --approve-sid → APPROVAL mode: perviotools merges
# into the SAME mcp.json as the approve server (one file, one --mcp-config),
# and the approval wiring is untouched — zero regression.
print("=== pervio state d: flag + default perm => merged mcp.json, approve intact ===")
home = tempfile.mkdtemp(prefix="pchat_mcp_appr_", dir="/tmp")
_stub_pervio_mcp(home)
sid = "mcpmerge1"
argv_log = os.path.join(home, "argv.jsonl")
env = env_for(home, SHIM_ARGV_LOG=argv_log)
env.pop("PERVIO_WF_ID", None)
p = subprocess.Popen([CHAT, "--dir", home, "--perm", "default", "--approve-sid", sid,
                      "--pervio-context",
                      "--prompt-b64", b64('go\nSHIM:{"sleep": 1.5, "text": "merged done"}')],
                     env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
first = p.stdout.readline()             # output flowing ⇒ mcp.json already written
sess_cfg = os.path.join(home, ".pervio", "chat", sid, "mcp.json")
merged = {}
try:
    with open(sess_cfg) as f:
        merged = json.load(f)
except (OSError, ValueError):
    pass
rest = p.stdout.read()
rc = p.wait(timeout=60)
_servers = merged.get("mcpServers") or {}
check("merged mcp.json still carries the approve server (sid intact)",
      (_servers.get("pervio") or {}).get("env", {}).get("PERVIO_SID") == sid
      and (_servers.get("pervio") or {}).get("args", [""])[0].endswith("/pervio-approve"),
      merged)
check("merged mcp.json also carries perviotools",
      (_servers.get("perviotools") or {}).get("command") == "python3"
      and (_servers.get("perviotools") or {}).get("args", [""])[0].endswith("/pervio-mcp"),
      merged)
check("…with the ceiling of the asking mode this conversation runs in, next to the approve server's own env",
      (_servers.get("perviotools") or {}).get("env", {}).get("PERVIO_MCP_CEILING") in ("default", "acceptEdits")
      and os.path.isabs((_servers.get("perviotools") or {}).get("env", {}).get("PERVIO_MCP_DIR", "")), merged)
argvs = []
try:
    with open(argv_log) as f:
        argvs = [json.loads(l) for l in f if l.strip()]
except OSError:
    pass
check("approval wiring zero-regression: --permission-prompt-tool mcp__pervio__approve",
      argvs and any("--permission-prompt-tool" in a and "mcp__pervio__approve" in a for a in argvs),
      argvs)
check("--mcp-config passed exactly ONCE, pointing at the MERGED session file",
      argvs and all(a.count("--mcp-config") == 1 and _flag_val(a, "--mcp-config") == sess_cfg
                    for a in argvs), argvs)
check("read-only allowlist rides the approval path too",
      argvs and all(all(t in (_flag_val(a, "--allowedTools") or "").split(",") for t in RO_TOOLS)
                    for a in argvs), argvs)
check("approval turn completed cleanly", rc == 0, rc)
shutil.rmtree(home, ignore_errors=True)

# (e) codex branch: with the flag, every invocation carries the three
# -c mcp_servers.perviotools overrides (command / args / env.PERVIO_MCP_RO=1 —
# codex has no approval channel, so the READ-ONLY gate lives in the server, not
# here) and the per-turn prefix becomes the codex discovery pointer (codex
# lists MCP tools at init — no ToolSearch hint, routing + suppression only).
# Same opt-in + machine gates as before; an old deployment without pervio-mcp
# anywhere degrades to the legacy brief pointer with no mount.
print("=== pervio state e: codex flag => RO MCP mount + discovery prefix ===")
CDX_MOUNT = "mcp_servers.perviotools."


def _mounts(a):
    return [x for x in a if isinstance(x, str) and x.startswith(CDX_MOUNT)]


p, argvs = _run_ctx_case("pchat_cdx_on_", ["--pervio-context"], backend="codex")
_prompts = [a[-1] for a in argvs if a]
check("codex shim ran (argv captured)", bool(_prompts), p.stderr)
# The mount is DISABLED behind CODEX_MCP_READY (empty): `codex exec` — this
# whole pipe — auto-cancels every MCP tool call upstream (openai/codex#24135,
# #16685; probed live 2026-08-04, approval_policy=never included). Until a
# fixed codex ships, a flagged codex turn must get ZERO -c mounts and the
# LEGACY brief pointer. When CODEX_MCP_READY flips, restore the three-override
# + discovery-pointer assertions from git history (commit that added state e).
check("flagged codex turn: NO -c perviotools mount (disabled pending upstream)",
      argvs and all(not _mounts(a) for a in argvs), argvs)
check("flagged codex turn: legacy brief pointer rides the message "
      "(with the suppression sentence)",
      _prompts and _prompts[0].startswith("[env]")
      and "pervio-brief.md" in _prompts[0]
      and "不要主动提及本说明或 Pervio" in _prompts[0]
      and _prompts[0].endswith(BASE_PROMPT),
      (_prompts[0][:160] if _prompts else "(none)"))
p, argvs = _run_ctx_case("pchat_cdx_off_", [], backend="codex")
_prompts = [a[-1] for a in argvs if a]
check("plain codex turn: no mount, message untouched (zero injection default)",
      _prompts and _prompts[0] == BASE_PROMPT
      and all(not _mounts(a) for a in argvs), _prompts)
p, argvs = _run_ctx_case("pchat_cdx_wf_", ["--pervio-context"], wf_id="x", backend="codex")
_prompts = [a[-1] for a in argvs if a]
check("codex machine turn: gate strips BOTH the mount and the prefix",
      _prompts and _prompts[0] == BASE_PROMPT
      and all(not _mounts(a) for a in argvs), _prompts)

# Old-deployment variant: a bin dir with pervio-chat + the brief but NO
# pervio-mcp (and a hermetic HOME without the ~/.pervio/bin stub) → nothing to
# mount, so the codex turn must degrade to the legacy brief pointer verbatim.
old_bin = tempfile.mkdtemp(prefix="pchat_oldbin_", dir="/tmp")
shutil.copy(CHAT, os.path.join(old_bin, "pervio-chat"))
shutil.copy(os.path.join(os.path.dirname(CHAT), "pervio-brief.md"),
            os.path.join(old_bin, "pervio-brief.md"))
p, argvs = _run_ctx_case("pchat_cdx_old_", ["--pervio-context"], backend="codex",
                         chat_bin=os.path.join(old_bin, "pervio-chat"), stub=False)
_prompts = [a[-1] for a in argvs if a]
check("pervio-mcp missing anywhere: NO -c mount in argv (graceful degradation)",
      argvs and all(not _mounts(a) for a in argvs), argvs or p.stderr)
check("…and the LEGACY brief pointer prefix returns verbatim",
      _prompts and _prompts[0].startswith("[env]")
      and "pervio-brief.md" in _prompts[0]
      and "不要主动提及本说明或 Pervio" in _prompts[0]
      and _prompts[0].endswith(BASE_PROMPT),
      (_prompts[0][:160] if _prompts else "(none)"))
shutil.rmtree(old_bin, ignore_errors=True)

# (f) prompt language: the app's Settings page can flip injected prompts to
# English. It sends --lang en ONLY then (default = no flag = Chinese verbatim),
# so a not-yet-updated server keeps working for every default send. The flag
# swaps the POINTER PROSE only — tool names, allowlists and mounts are
# language-free and must not move.


def _has_cjk(s):
    return any(0x4E00 <= ord(ch) <= 0x9FFF or 0x3000 <= ord(ch) <= 0x303F
               or 0xFF00 <= ord(ch) <= 0xFFEF for ch in s)


print("=== pervio state f: --lang en => English pointer prose ===")
p, argvs = _run_ctx_case("pchat_lang_en_", ["--pervio-context", "--lang", "en"])
check("--lang en is accepted (shim ran)", bool(argvs), (p.returncode, p.stderr[:160]))
_ptrs = [_flag_val(a, "--append-system-prompt") or "" for a in argvs]
check("English pointer rides every invocation (no CJK, perviotools + ToolSearch kept)",
      argvs and all(pt and not _has_cjk(pt) and "mcp__perviotools__" in pt
                    and "ToolSearch" in pt for pt in _ptrs),
      [pt[:120] for pt in _ptrs])
_allows = [(_flag_val(a, "--allowedTools") or "").split(",") for a in argvs]
check("--lang en leaves the read-only allowlist untouched",
      _allows and all(al == RO_TOOLS for al in _allows), _allows)

p, argvs = _run_ctx_case("pchat_lang_zh_", ["--pervio-context", "--lang", "zh"])
_ptrs = [_flag_val(a, "--append-system-prompt") or "" for a in argvs]
check("explicit --lang zh matches the default Chinese pointer",
      argvs and all(pt and _has_cjk(pt) and "mcp__perviotools__" in pt for pt in _ptrs),
      [pt[:120] for pt in _ptrs])

p, argvs = _run_ctx_case("pchat_lang_cdx_", ["--pervio-context", "--lang", "en"],
                         backend="codex")
_prompts = [a[-1] for a in argvs if a]
check("codex + --lang en: English [env] pointer prefix, user prompt intact",
      _prompts and _prompts[0].startswith("[env]") and not _has_cjk(_prompts[0][:len(_prompts[0]) - len(BASE_PROMPT)])
      and _prompts[0].endswith(BASE_PROMPT),
      (_prompts[0][:160] if _prompts else "(none)"))

# ---------- codex-only host: the claude gate must not brick codex ----------
# 2026-08-22 audit P1: an unconditional claude lookup sat ABOVE the codex
# branch, so --backend codex exited 4 on any host without claude installed.
print("=== codex-only host ===")
home_cx = tempfile.mkdtemp(prefix="chat_cx_", dir="/tmp")
bin_cx = os.path.join(home_cx, "bin")
os.makedirs(bin_cx)
os.symlink(os.path.join(SHIM, "codex"), os.path.join(bin_cx, "codex"))
env_cx = dict(os.environ, HOME=home_cx, PATH=bin_cx + ":/usr/bin:/bin",
              PERVIO_CHAT_PATH_ONLY="1")
p = subprocess.run([CHAT, "--text", "--backend", "codex", "--dir", home_cx,
                    "--prompt-b64", b64("hi\nSHIM:" + json.dumps({"text": "cx ok"}))],
                   env=env_cx, capture_output=True, text=True, timeout=60)
check("codex-only PATH: --backend codex runs (no claude gate in the way)",
      p.returncode == 0 and "cx ok" in p.stdout,
      (p.returncode, p.stderr[-200:]))
p = subprocess.run([CHAT, "--text", "--backend", "claude", "--dir", home_cx,
                    "--prompt-b64", b64("hi")],
                   env=env_cx, capture_output=True, text=True, timeout=60)
check("codex-only PATH: the claude backend still fails loudly (exit 4)",
      p.returncode == 4 and "claude not found" in p.stderr, (p.returncode, p.stderr[:150]))
# `engines` on the same codex-only host
p = subprocess.run([CHAT, "engines"], env=env_cx, capture_output=True, text=True, timeout=30)
try:
    eng = json.loads(p.stdout)
except ValueError:
    eng = {}
check("engines: reports what this host has — codex found, claude empty, tmux probed",
      p.returncode == 0 and eng.get("codex", "").endswith("/codex") and eng.get("claude") == "" and "tmux" in eng,
      (p.returncode, p.stdout[:200]))
shutil.rmtree(home_cx, ignore_errors=True)

# ---------- --stop-tag: the app's real-stop handle ----------
# Hanging up does NOT stop a turn (deliberate walk-away semantics, empirically
# pinned 2026-08-22). An explicit stop therefore needs an explicit handle: the
# turn records its pid under the tag; the app resolves pid -> process group and
# TERMs it — group-kill ONLY when the pid leads its own group (never a shared
# sshd group), else pid + direct children.
# ---------- Cursor (agent -p): one more engine, zero new vocabulary ----------
# The shim `agent` emits CURSOR-shaped events (probed on agent 2026.10.14);
# pervio-chat pipes them through pervio-cursor-stream so what reaches the channel
# is Claude's shape. Also the provider overlay: a third-party endpoint for
# claude (ANTHROPIC_* env) and codex (-c model_provider overrides).
# ---------- attached folders are WRITABLE for the agent (--extra-dir → --add-dir, 2026-10-17) ----------
print("=== extra dirs (attached folders, writable) ===")
home_xd = tempfile.mkdtemp(prefix="chat_xd_", dir="/tmp")
argv_xd = os.path.join(home_xd, "argv.log")
env_xd = env_for(home_xd, SHIM_ARGV_LOG=argv_xd, PERVIO_CODEX_EXEC="1")   # argv assertions = the exec path
d_ok = os.path.join(home_xd, "notes dir"); os.makedirs(d_ok)
d_home = os.path.join(home_xd, "tilde"); os.makedirs(d_home)
def _xd_argv():
    try:
        return [json.loads(l) for l in open(argv_xd) if l.strip()]
    except OSError:
        return []
p = subprocess.run([CHAT, "--text", "--dir", home_xd, "--prompt-b64", b64("hi"), "--extra-dir", d_ok, "--extra-dir", "~/tilde",
                    "--extra-dir", os.path.join(home_xd, "nope")], env=env_xd, capture_output=True, text=True, timeout=60)
av = _xd_argv()[-1] if _xd_argv() else []
adds = [av[i + 1] for i, a in enumerate(av) if a == "--add-dir"]
check("XD1 claude gets every attached folder as --add-dir (uploads too), ~ expanded, a non-directory dropped with a note",
      p.returncode == 0 and d_ok in adds and d_home in adds and not any(a.endswith("/nope") for a in adds)
      and "not a directory, skipped" in p.stderr, (p.returncode, adds, p.stderr[-200:]))
p = subprocess.run([CHAT, "--text", "--backend", "codex", "--dir", home_xd, "--prompt-b64", b64("hi"), "--extra-dir", d_ok],
                   env=env_xd, capture_output=True, text=True, timeout=60)
av = _xd_argv()[-1] if _xd_argv() else []
check("XD2 codex gets the folder as --add-dir (its own flag, present on this codex), resolved to its real path",
      p.returncode == 0 and "--add-dir" in av and av[av.index("--add-dir") + 1] == os.path.realpath(d_ok), (p.returncode, av, p.stderr[-200:]))
p = subprocess.run([CHAT, "--text", "--dir", home_xd, "--prompt-b64", b64("hi")], env=env_xd, capture_output=True, text=True, timeout=60)
av = _xd_argv()[-1] if _xd_argv() else []
check("XD3 no attached folder: nothing but the uploads dir is added", p.returncode == 0 and [a for a in av if a == "--add-dir"] == ["--add-dir"], av)
# OneDrive's mechanism: ~/Documents is a symlink into ~/Library/CloudStorage; codex's sandbox refuses
# symlinked writable roots, so codex gets the RESOLVED paths (and a note), claude keeps the spelling.
cs = os.path.join(home_xd, "Library", "CloudStorage", "OneDrive-Co", "Documents"); os.makedirs(os.path.join(cs, "proj", "ppt"))
os.symlink(cs, os.path.join(home_xd, "Documents"))
link_proj = os.path.join(home_xd, "Documents", "proj")
p = subprocess.run([CHAT, "--text", "--backend", "codex", "--dir", link_proj, "--extra-dir", os.path.join(link_proj, "ppt"), "--prompt-b64", b64("hi")],
                   env=env_xd, capture_output=True, text=True, timeout=60)
av = _xd_argv()[-1] if _xd_argv() else []
real_proj = os.path.realpath(link_proj)
check("XD4 codex is launched on the resolved real path (-C and --add-dir), never through the symlink, with a cloud-sync note",
      p.returncode == 0 and av[av.index("-C") + 1] == real_proj and av[av.index("--add-dir") + 1] == os.path.join(real_proj, "ppt")
      and "cloud-synced" in p.stderr, (p.returncode, av, p.stderr[-300:]))
p = subprocess.run([CHAT, "--text", "--dir", link_proj, "--extra-dir", os.path.join(link_proj, "ppt"), "--prompt-b64", b64("hi")],
                   env=env_xd, capture_output=True, text=True, timeout=60)
av = _xd_argv()[-1] if _xd_argv() else []
check("XD5 claude keeps the person's spelling (its project folder is named after the cwd as typed)",
      p.returncode == 0 and os.path.join(link_proj, "ppt") in av, (p.returncode, av))
shutil.rmtree(home_xd, ignore_errors=True)

print("=== cursor engine ===")
RUN = os.path.realpath(os.path.join(HERE, "..", "bin", "pervio-run"))
home_cu = tempfile.mkdtemp(prefix="chat_cu_", dir="/tmp")
argv_log = os.path.join(home_cu, "argv.log")
env_cu = env_for(home_cu, SHIM_ARGV_LOG=argv_log, PERVIO_CHAT_PATH_ONLY="1")
def _argv():
    try:
        return [json.loads(l) for l in open(argv_log) if l.strip()]
    except OSError:
        return []
def _cursor(perm, *extra, text="hi\nSHIM:" + json.dumps({"text": "cursor says hi", "sid": "cur-sess-1",
                                                           "trace": [{"tool": "Bash", "command": "ls", "out": "a b"}, {"say": "mid"}]})):
    return subprocess.run([CHAT, "--text", "--backend", "cursor", "--perm", perm, "--dir", home_cu,
                           "--prompt-b64", b64(text)] + list(extra), env=env_cu, capture_output=True, text=True, timeout=60)
p = _cursor("plan")
objs = parse_lines(p.stdout)[0]
types = [(o.get("type"), (o.get("event") or {}).get("type") or o.get("subtype")) for o in objs if isinstance(o, dict)]
check("CU1 a cursor turn runs the shim and exits 0", p.returncode == 0, (p.returncode, p.stderr[-200:]))
av = _argv()[-1] if _argv() else []
check("CU1a plan → `-p --output-format stream-json --trust --mode plan`, prompt last, no --force",
      av[1:4] == ["-p", "--output-format", "stream-json"] and "--trust" in av and "--mode" in av and av[av.index("--mode") + 1] == "plan"
      and "--force" not in av and av[-1].startswith("hi"), av)
check("CU2 the channel carries Claude's shape: init with session_id, text deltas, a tool_use, its tool_result, a result",
      any(o.get("type") == "system" and o.get("subtype") == "init" and o.get("session_id") == "cur-sess-1" for o in objs)
      and any(o.get("type") == "stream_event" and (o.get("event") or {}).get("delta", {}).get("type") == "text_delta" for o in objs)
      and any(o.get("type") == "assistant" and any(b.get("type") == "tool_use" and b.get("name") == "Bash"
                                                    and b.get("input", {}).get("command") == "ls"
                                                    for b in (o.get("message") or {}).get("content", [])) for o in objs)
      and any(o.get("type") == "user" and any(b.get("type") == "tool_result" and "a b" in str(b.get("content"))
                                               for b in (o.get("message") or {}).get("content", [])) for o in objs)
      and any(o.get("type") == "result" and o.get("result") == "cursor says hi" for o in objs), types)
check("CU2a the prompt echo never reaches the channel; thinking rides as thinking_delta",
      not any(o.get("type") == "user" and any(b.get("type") == "text" for b in (o.get("message") or {}).get("content", [])) for o in objs)
      and any((o.get("event") or {}).get("delta", {}).get("type") == "thinking_delta" for o in objs), types)
p = _cursor("bypassPermissions", "--resume", "cur-sess-1", "--model", "gpt-5.3-codex")
av = _argv()[-1]
check("CU3 bypassPermissions → --force; --resume and --model pass straight through",
      p.returncode == 0 and "--force" in av and "--mode" not in av and av[av.index("--resume") + 1] == "cur-sess-1"
      and av[av.index("--model") + 1] == "gpt-5.3-codex", av)
p = _cursor("acceptEdits", "--model", "auto")
av = _argv()[-1]
check("CU4 acceptEdits = Cursor's own default (no mode, no force); the model is always explicit — auto says --model auto (else the agent's persisted pick applies)",
      "--force" not in av and "--mode" not in av and av[av.index("--model") + 1] == "auto", av)
p = _cursor("plan")
av = _argv()[-1]
check("CU4b no model at all also says --model auto", av[av.index("--model") + 1] == "auto", av)
p = _cursor("default", text="hi\nSHIM:" + json.dumps({"text": "boom", "is_error": True, "rc": 1}))
check("CU5 a failing cursor turn surfaces an is_error result and a non-zero exit",
      p.returncode != 0 and any(o.get("type") == "result" and o.get("is_error") is True for o in parse_lines(p.stdout)[0] if isinstance(o, dict)),
      (p.returncode, p.stdout[-200:]))
p = subprocess.run([CHAT, "--text", "--backend", "cursor", "--provider", "glm", "--dir", home_cu, "--prompt-b64", b64("hi")],
                   env=env_cu, capture_output=True, text=True, timeout=30)
check("CU6 cursor + a provider is refused (it only speaks to its own account)", p.returncode == 4 and "provider" in p.stderr, (p.returncode, p.stderr))
p = subprocess.run([CHAT, "engines"], env=env_cu, capture_output=True, text=True, timeout=30)
eng = json.loads(p.stdout) if p.returncode == 0 else {}
p = _cursor("default", text="hi\nSHIM:" + json.dumps({"die": "Run \u001b[36msecurity unlock-keychain\u001b[0m and try again", "rc": 1}))
res = [o for o in parse_lines(p.stdout)[0] if isinstance(o, dict) and o.get("type") == "result"]
check("CU8 an agent that dies before answering (keychain locked) leaves its reason on the channel as an error result, colour codes stripped",
      p.returncode != 0 and len(res) == 1 and res[0].get("is_error") is True
      and res[0].get("result") == "Run security unlock-keychain and try again", (p.returncode, p.stdout[-300:], res))
check("CU8b … and the reason still reaches stderr for a detached run's err file", "unlock-keychain" in p.stderr, p.stderr[-200:])
p = _cursor("default", text="hi\nSHIM:" + json.dumps({"text": "boom", "is_error": True, "rc": 1}))
check("CU8c an agent that answered with its own error result gets no second one",
      sum(1 for o in parse_lines(p.stdout)[0] if isinstance(o, dict) and o.get("type") == "result") == 1, p.stdout[-300:])
# the model menu: `agent models` is asked with credentials.env in its env
ORCH = os.path.realpath(os.path.join(HERE, "..", "bin", "pervio-orchestrate"))
env_nk = dict(env_cu, SHIM_CURSOR_NEED_KEY="1")
p = subprocess.run([ORCH, "models"], env=env_nk, capture_output=True, text=True, timeout=30)
menu = json.loads(p.stdout) if p.returncode == 0 else {}
ids = [m.get("id") for m in (menu.get("chat") or {}).get("cursor") or []]
check("CU9 with the keychain locked and no key the Cursor menu is the fixed fallback", "gpt-5.6-sol-high" in ids and "auto" in ids, (p.returncode, ids, p.stderr[-200:]))
os.makedirs(os.path.join(home_cu, ".pervio"), exist_ok=True)
with open(os.path.join(home_cu, ".pervio", "credentials.env"), "w") as f:
    f.write("CURSOR_API_KEY='key_cursor_x'\n")
p = subprocess.run([ORCH, "models"], env=env_nk, capture_output=True, text=True, timeout=30)
menu = json.loads(p.stdout) if p.returncode == 0 else {}
ids = [m.get("id") for m in (menu.get("chat") or {}).get("cursor") or []]
check("CU9b a CURSOR_API_KEY in credentials.env reaches `agent models`: the menu is the account's own", ids == ["auto", "gpt-5.3-codex", "composer-2.5"], (p.returncode, ids, p.stderr[-200:]))
os.remove(os.path.join(home_cu, ".pervio", "credentials.env"))
shutil.rmtree(os.path.join(home_cu, ".pervio", "cache"), ignore_errors=True)

# ---- the Codex menu is codex's OWN model table (2026-10-18) ----
# Cursor's sub-agents (2026-11-22): calls of its Task tool, each waited for by the
# turn. The shapes are a real cursor-agent turn's (args.subagentType {"<type>": {}},
# a result that is the sub-agent's steps and a durationMs string). They reach the
# phone as tool rows as before AND as the task events its task line reads.
p = _cursor("default", text="go\nSHIM:" + json.dumps({"text": "both done", "sid": "cur-sess-2", "trace": [
    {"tool": "Task", "description": "Count the entries", "out": "entries: 4", "ms": 16581},
    {"tool": "Task", "description": "Read the note", "type": "explore", "fail": "the note is gone"}]}))
objs = parse_lines(p.stdout)[0]
cut_tasks = [o for o in objs if o.get("type") == "system" and str(o.get("subtype", "")).startswith("task_")]
cut_uses = [b for o in objs if o.get("type") == "assistant" for b in (o.get("message") or {}).get("content", []) if b.get("type") == "tool_use"]
cut_results = [b for o in objs if o.get("type") == "user" for b in (o.get("message") or {}).get("content", []) if b.get("type") == "tool_result"]
check("CUT1 each Task call is announced as a sub-agent the turn waits for, under the call's own id, with its type when it has one",
      p.returncode == 0 and [(o["subtype"], o["task_id"]) for o in cut_tasks] == [("task_started", "call-0"), ("task_notification", "call-0"),
                                                                             ("task_started", "call-1"), ("task_notification", "call-1")]
      and cut_tasks[0]["description"] == "Count the entries" and cut_tasks[0]["task_type"] == "local_agent" and cut_tasks[0]["is_backgrounded"] is False
      and "subagent_type" not in cut_tasks[0] and cut_tasks[2].get("subagent_type") == "explore", (p.returncode, cut_tasks, p.stderr[-200:]))
check("CUT2 its ending says how it ended, its last words, and the time Cursor itself gives (a string there, a number here)",
      cut_tasks[1]["status"] == "completed" and cut_tasks[1]["summary"] == "entries: 4" and cut_tasks[1]["usage"]["duration_ms"] == 16581
      and cut_tasks[3]["status"] == "failed" and "the note is gone" in cut_tasks[3]["summary"], cut_tasks)
check("CUT3 the tool row is still there, and its result is the sub-agent's answer — not the JSON of its whole record",
      [u["name"] for u in cut_uses] == ["Task", "Task"] and cut_results[0]["content"] == "entries: 4" and "conversationSteps" not in json.dumps(cut_results),
      (cut_uses, cut_results))

print("=== CX models: the menu comes from ~/.codex/models_cache.json ===")
os.makedirs(os.path.join(home_cu, ".codex"), exist_ok=True)
with open(os.path.join(home_cu, ".codex", "models_cache.json"), "w") as f:
    json.dump({"models": [
        {"slug": "gpt-9-luna", "display_name": "GPT-9-Luna", "visibility": "list", "priority": 2,
         "default_reasoning_level": "medium",
         "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"}, {"effort": "xhigh"}, {"effort": "max"}]},
        {"slug": "gpt-9-sol", "display_name": "GPT-9-Sol", "visibility": "list", "priority": 1,
         "default_reasoning_level": "low",
         "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"}, {"effort": "xhigh"}, {"effort": "max"}, {"effort": "ultra"}]},
        {"slug": "codex-auto-review", "display_name": "Codex Auto Review", "visibility": "hide", "priority": 43,
         "default_reasoning_level": "medium", "supported_reasoning_levels": [{"effort": "low"}]},
    ]}, f)
with open(os.path.join(home_cu, ".codex", "config.toml"), "w") as f:
    f.write('model = "gpt-9-sol"\nmodel_reasoning_effort = "ultra"\n')
p = subprocess.run([ORCH, "models"], env=env_nk, capture_output=True, text=True, timeout=30)
menu = json.loads(p.stdout) if p.returncode == 0 else {}
cx = (menu.get("chat") or {}).get("codex") or []
check("CX1 the menu lists codex's own pickable models in codex's order, hidden ones left out",
      [m.get("id") for m in cx] == ["gpt-9-sol", "gpt-9-luna"], (p.returncode, cx, p.stderr[-200:]))
check("CX2 each model carries its own reasoning levels and default",
      bool(cx) and cx[0].get("efforts") == ["low", "medium", "high", "xhigh", "max", "ultra"] and cx[0].get("defaultEffort") == "low"
      and cx[1].get("efforts") == ["low", "medium", "high", "xhigh", "max"] and cx[1].get("defaultEffort") == "medium", cx)
check("CX3 the config's model is marked as the config default, by display name",
      bool(cx) and cx[0].get("note") == "GPT-9-Sol · the config default" and cx[1].get("note") == "GPT-9-Luna", cx)
# ---- speed tiers + Claude's own levels and extras (2026-10-19)
with open(os.path.join(home_cu, ".codex", "models_cache.json")) as f:
    _mc = json.load(f)
_mc["models"][1]["service_tiers"] = [{"id": "priority", "name": "Fast", "description": "2x speed, increased usage"}]   # gpt-9-sol
with open(os.path.join(home_cu, ".codex", "models_cache.json"), "w") as f:
    json.dump(_mc, f)
with open(os.path.join(home_cu, ".codex", "config.toml"), "w") as f:
    f.write('model = "gpt-9-sol"\nservice_tier = "priority"\n[sandbox_workspace_write]\nservice_tier = "not-this-one"\n')
with open(os.path.join(home_cu, ".claude.json"), "w") as f:
    json.dump({"additionalModelOptionsCache": [
        {"value": "claude-fable-5-1[1m]", "label": "Fable", "description": "Fable 5.1 · Most capable"},
        {"value": "claude-opus-5", "label": "dup", "description": "already shipped"}]}, f)
_fakebin = os.path.join(home_cu, "fakebin"); os.makedirs(_fakebin, exist_ok=True)
with open(os.path.join(_fakebin, "claude"), "w") as f:
    f.write("#!/bin/sh\necho 'Usage: claude [options]'\necho '  --effort <level>                      Effort level for the current session'\necho '                                        (low, medium, high, xhigh, max, turbo)'\n")
os.chmod(os.path.join(_fakebin, "claude"), 0o755)
p = subprocess.run([ORCH, "models"], env=dict(env_nk, PATH=_fakebin + ":" + env_nk["PATH"]), capture_output=True, text=True, timeout=30)
menu = json.loads(p.stdout) if p.returncode == 0 else {}
chat_m = menu.get("chat") or {}
cx = chat_m.get("codex") or []
check("CX5 a model's faster service tier rides the paper as codex's table describes it; a model without one has none",
      bool(cx) and cx[0].get("fast") == {"id": "priority", "name": "Fast", "description": "2x speed, increased usage"} and "fast" not in cx[1], cx)
check("CX5b the Mac's own speed setting (config.toml service_tier, top level only) is in the paper",
      chat_m.get("codexServiceTier") == "priority", chat_m.get("codexServiceTier"))
check("CX5c …and the config's model by id, so the phone knows which row an unset model means",
      chat_m.get("codexDefaultModel") == "gpt-9-sol", chat_m.get("codexDefaultModel"))
check("CX6 Claude's effort levels come from `claude --help` itself (a level the CLI adds shows up)",
      chat_m.get("claudeEfforts") == ["low", "medium", "high", "xhigh", "max", "turbo"], chat_m.get("claudeEfforts"))
check("CX7 Claude's extra models (what Claude Code learned the account can use, ~/.claude.json) join the menu, shipped rows first, no duplicates",
      [m["id"] for m in chat_m.get("claude") or []][-1] == "claude-fable-5-1[1m]"
      and [m["id"] for m in chat_m.get("claude") or []].count("claude-opus-5") == 1
      and next(m for m in chat_m["claude"] if m["id"] == "claude-fable-5-1[1m]")["note"] == "Fable · Fable 5.1 · Most capable", chat_m.get("claude"))
# the lib itself, with no claude findable anywhere (the finder also looks in
# fixed dirs, where this Mac's own claude lives — so it is stubbed, not PATH)
import importlib.machinery as _im, importlib.util as _iu
_ll = _im.SourceFileLoader("plib_cx", os.path.join(os.path.dirname(CHAT), "_pervio_lib.py"))
_plib = _iu.module_from_spec(_iu.spec_from_loader("plib_cx", _ll)); _ll.exec_module(_plib)
_home_was = os.environ.get("HOME"); os.environ["HOME"] = home_cu
try:
    _plib._find_claude = lambda: ""
    check("CX6b …cached for a day on the Mac: no claude now, the cached levels still serve",
          _plib.claude_efforts() == ["low", "medium", "high", "xhigh", "max", "turbo"], _plib.claude_efforts())
    os.remove(os.path.join(home_cu, ".pervio", "cache", "claude-efforts.json"))
    check("CX6c no claude, no cache: the shipped levels are the floor", _plib.claude_efforts() == ["low", "medium", "high", "xhigh", "max"], _plib.claude_efforts())
finally:
    if _home_was is None: os.environ.pop("HOME", None)
    else: os.environ["HOME"] = _home_was
os.remove(os.path.join(home_cu, ".codex", "models_cache.json"))
p = subprocess.run([ORCH, "models"], env=env_nk, capture_output=True, text=True, timeout=30)
cx = ((json.loads(p.stdout) if p.returncode == 0 else {}).get("chat") or {}).get("codex") or []
check("CX4 no cache (codex never run) → the static floor, no levels claimed",
      len(cx) >= 4 and all("efforts" not in m for m in cx) and any(m.get("id") == "gpt-6-astra" for m in cx), cx)
# the file credential store: chosen when ~/.cursor/auth.json exists (a login made
# through the phone's link), left alone otherwise — on a turn AND on `agent models`
env_log = os.path.join(home_cu, "env.log")
env_fs = dict(env_cu, SHIM_ENV_LOG=env_log, SHIM_CURSOR_NEED_FILESTORE="1")
p = subprocess.run([CHAT, "--text", "--backend", "cursor", "--perm", "plan", "--dir", home_cu, "--prompt-b64", b64("hi")],
                   env=env_fs, capture_output=True, text=True, timeout=60)
res = [o for o in parse_lines(p.stdout)[0] if isinstance(o, dict) and o.get("type") == "result"]
check("CU11 with no file-store login the agent runs on its default store (and a locked keychain is reported as such)",
      p.returncode != 0 and res and "unlock-keychain" in res[0].get("result", "") and json.loads(open(env_log).read().splitlines()[-1])["store"] == "",
      (p.returncode, res, open(env_log).read()[-200:]))
os.makedirs(os.path.join(home_cu, ".cursor"), exist_ok=True)
with open(os.path.join(home_cu, ".cursor", "auth.json"), "w") as f:
    f.write('{"accessToken": "x", "refreshToken": "y"}')
p = subprocess.run([CHAT, "--text", "--backend", "cursor", "--perm", "plan", "--dir", home_cu, "--prompt-b64", b64("hi")],
                   env=env_fs, capture_output=True, text=True, timeout=60)
check("CU11b with ~/.cursor/auth.json the turn runs on the file store and answers",
      p.returncode == 0 and json.loads(open(env_log).read().splitlines()[-1])["store"] == "file"
      and any(o.get("type") == "result" and not o.get("is_error") for o in parse_lines(p.stdout)[0] if isinstance(o, dict)),
      (p.returncode, p.stdout[-200:], p.stderr[-200:]))
shutil.rmtree(os.path.join(home_cu, ".pervio", "cache"), ignore_errors=True)
p = subprocess.run([ORCH, "models"], env=env_fs, capture_output=True, text=True, timeout=30)
ids = [m.get("id") for m in (json.loads(p.stdout).get("chat") or {}).get("cursor") or []] if p.returncode == 0 else []
check("CU11c `agent models` runs on the file store too: the menu is the account's own", ids == ["auto", "gpt-5.3-codex", "composer-2.5"], (p.returncode, ids, p.stderr[-200:]))
p = subprocess.run([CHAT, "engines"], env=env_fs, capture_output=True, text=True, timeout=30)
check("CU11d engines reports the file-store login", (json.loads(p.stdout) if p.returncode == 0 else {}).get("cursorLogin") is True, p.stdout[:200])
shutil.rmtree(os.path.join(home_cu, ".cursor"), ignore_errors=True)
shutil.rmtree(os.path.join(home_cu, ".pervio", "cache"), ignore_errors=True)
# the per-family cut itself, on a list shaped like the real one (265 ids, 2026-10-16)
import importlib.util as _ilu
_spec = _ilu.spec_from_file_location("_plib", os.path.join(HERE, "..", "bin", "_pervio_lib.py")); _plib = _ilu.module_from_spec(_spec); _spec.loader.exec_module(_plib)
_raw = [{"id": i, "note": i} for i in [
    "auto", "gpt-5.3-codex-low", "gpt-5.3-codex-low-fast", "gpt-5.3-codex", "gpt-5.3-codex-high", "composer-2.5", "composer-2.5-fast",
    "grok-4.7-low", "grok-4.7-low-fast", "grok-4.7-medium", "grok-4.7-high", "grok-4.7-xhigh",
    "claude-opus-5-5-low", "claude-opus-5-5-high", "claude-opus-5-5-max", "claude-opus-5-5-max-fast",
    "kimi-k3-low", "kimi-k3-high", "glm-5.2-high", "glm-5.2-max", "claude-4.5-sonnet", "gemini-3.6-flash-minimal"]]
_cut = [m["id"] for m in _plib._cursor_menu_cut(_raw)]
check("CU10 the Cursor menu is one entry per family, in Cursor's order: the plain id when there is one, else the -high variant; -fast twins and -max folded in; every family kept",
      _cut == ["auto", "gpt-5.3-codex", "composer-2.5", "grok-4.7-high", "claude-opus-5-5-high", "kimi-k3-high", "glm-5.2-high", "claude-4.5-sonnet", "gemini-3.6-flash-minimal"], _cut)
check("CU10b auto leads even when the list has none", [m["id"] for m in _plib._cursor_menu_cut(_raw[1:3])][0] == "auto", _plib._cursor_menu_cut(_raw[1:3]))
check("CU7b engines says no Cursor API key is on file yet", eng.get("cursorKey") is False, eng)
os.makedirs(os.path.join(home_cu, ".pervio"), exist_ok=True)
with open(os.path.join(home_cu, ".pervio", "credentials.env"), "w") as f:
    f.write("CURSOR_API_KEY=key_cursor_x\n")
p2 = subprocess.run([CHAT, "engines"], env=env_cu, capture_output=True, text=True, timeout=30)
eng2 = json.loads(p2.stdout) if p2.returncode == 0 else {}
check("CU7c engines reports the Cursor API key once credentials.env has it", eng2.get("cursorKey") is True, eng2)
os.remove(os.path.join(home_cu, ".pervio", "credentials.env"))
check("CU7 engines reports cursor's path and an (empty) provider roster",
      eng.get("cursor", "").endswith("/agent") and eng.get("providers") == [], (p.returncode, p.stdout[:200]))
# a detached run learns the cursor session id from the translated init
p = subprocess.run([sys.executable, RUN, "start", "--dir", home_cu, "--backend", "cursor", "--perm", "plan",
                    "--prompt-b64", b64("hi\nSHIM:" + json.dumps({"text": "run ok", "sid": "cur-run-7"}))],
                   env=env_cu, capture_output=True, text=True, timeout=60)
rid = json.loads(p.stdout).get("runId") if p.returncode == 0 else ""
st = {}
for _ in range(40):
    q = subprocess.run([sys.executable, RUN, "status", "--run", rid], env=env_cu, capture_output=True, text=True, timeout=20)
    st = json.loads(q.stdout) if q.returncode == 0 else {}
    if st.get("state") in ("done", "failed"):
        break
    time.sleep(0.25)
check("CU8 pervio-run drives a cursor turn and learns its session id from the stream",
      st.get("state") == "done" and st.get("sessionId") == "cur-run-7", st)

print("=== provider overlay ===")
PROV = os.path.realpath(os.path.join(HERE, "..", "bin", "pervio-provider"))
env_log = os.path.join(home_cu, "env.log")
env_pv = env_for(home_cu, SHIM_ARGV_LOG=argv_log, SHIM_ENV_LOG=env_log, PERVIO_CHAT_PATH_ONLY="1", PERVIO_CODEX_EXEC="1")
def _b64j(o):
    return base64.b64encode(json.dumps(o).encode()).decode()
subprocess.run([sys.executable, PROV, "add", "--b64", _b64j({"name": "glm", "engine": "claude", "baseUrl": "https://open.bigmodel.cn/api/anthropic",
                                                             "apiKey": "sk-glm", "models": ["glm-5", "glm-5-air"]})], env=env_pv, capture_output=True, timeout=30)
subprocess.run([sys.executable, PROV, "add", "--b64", _b64j({"name": "kimi", "engine": "codex", "baseUrl": "https://api.moonshot.cn/v1",
                                                             "apiKey": "sk-kimi", "models": ["kimi-k2"]})], env=env_pv, capture_output=True, timeout=30)
p = subprocess.run([CHAT, "--text", "--backend", "claude", "--provider", "glm", "--dir", home_cu,
                    "--prompt-b64", b64("hi\nSHIM:" + json.dumps({"text": "via glm"}))], env=env_pv, capture_output=True, text=True, timeout=60)
envs = [json.loads(l) for l in open(env_log)] if os.path.exists(env_log) else []
av = _argv()[-1] if _argv() else []
check("PV1 claude + provider: the child sees ANTHROPIC_BASE_URL/AUTH_TOKEN and runs the provider's default model",
      p.returncode == 0 and envs and envs[-1].get("ANTHROPIC_BASE_URL") == "https://open.bigmodel.cn/api/anthropic"
      and envs[-1].get("ANTHROPIC_AUTH_TOKEN") == "sk-glm" and av[av.index("--model") + 1] == "glm-5",
      (p.returncode, p.stderr[-200:], envs[-1:] , av))
p = subprocess.run([CHAT, "--text", "--backend", "claude", "--provider", "glm", "--model", "glm-5-air", "--dir", home_cu,
                    "--prompt-b64", b64("hi")], env=env_pv, capture_output=True, text=True, timeout=60)
av = _argv()[-1]
check("PV1a an explicit model beats the provider's default", av[av.index("--model") + 1] == "glm-5-air", av)
p = subprocess.run([CHAT, "--text", "--backend", "codex", "--provider", "kimi", "--dir", home_cu,
                    "--prompt-b64", b64("hi\nSHIM:" + json.dumps({"text": "via kimi"}))], env=env_pv, capture_output=True, text=True, timeout=60)
av = _argv()[-1]
envs = [json.loads(l) for l in open(env_log)]
check("PV2 codex + provider: -c model_provider overrides on the argv, the key in its env var, the default model",
      p.returncode == 0 and 'model_provider="pervio_kimi"' in av and any("base_url=\"https://api.moonshot.cn/v1\"" in a for a in av)
      and envs[-1].get("PERVIO_PROVIDER_KEY_KIMI") == "sk-kimi" and av[av.index("--model") + 1] == "kimi-k2",
      (p.returncode, p.stderr[-200:], av))
p = subprocess.run([CHAT, "--text", "--backend", "claude", "--provider", "nope", "--dir", home_cu, "--prompt-b64", b64("hi")],
                   env=env_pv, capture_output=True, text=True, timeout=30)
check("PV3 an unknown provider fails loudly (exit 4) before any engine runs", p.returncode == 4 and "not found" in p.stderr, (p.returncode, p.stderr))
p = subprocess.run([CHAT, "--text", "--backend", "claude", "--dir", home_cu, "--prompt-b64", b64("hi")],
                   env=env_pv, capture_output=True, text=True, timeout=60)
envs = [json.loads(l) for l in open(env_log)]
check("PV4 without --provider nothing is overlaid (no ANTHROPIC_BASE_URL in the child's env)",
      p.returncode == 0 and "ANTHROPIC_BASE_URL" not in envs[-1], envs[-1])
p = subprocess.run([CHAT, "engines"], env=env_pv, capture_output=True, text=True, timeout=30)
eng = json.loads(p.stdout) if p.returncode == 0 else {}
check("PV5 engines lists the roster by name/engine, never a key",
      sorted(x["name"] for x in eng.get("providers", [])) == ["glm", "kimi"] and "sk-" not in p.stdout, p.stdout[:300])
shutil.rmtree(home_cu, ignore_errors=True)

print("=== stop-tag ===")
home_st = tempfile.mkdtemp(prefix="chat_st_", dir="/tmp")
env_st = env_for(home_st) if "env_for" in dir() else dict(
    os.environ, HOME=home_st, PATH=SHIM + ":" + os.environ.get("PATH", ""))
p = subprocess.run([CHAT, "--text", "--backend", "claude", "--dir", home_st,
                    "--stop-tag", "../evil", "--prompt-b64", b64("hi")],
                   env=env_st, capture_output=True, text=True, timeout=30)
check("stop-tag: traversal charset rejected (exit 2)",
      p.returncode == 2 and "invalid --stop-tag" in p.stderr, (p.returncode, p.stderr[:120]))

marker = os.path.join(home_st, "turn-finished")
prompt = "hi\nSHIM:" + json.dumps({"sleep": 8, "write": [{"file": marker, "content": "x"}],
                                    "text": "done"})
t0_st = time.time()
turn = subprocess.Popen([CHAT, "--text", "--backend", "claude", "--dir", home_st,
                         "--stop-tag", "t1", "--prompt-b64", b64(prompt)],
                        env=env_st, stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        start_new_session=True)          # own group, like sshd exec
pidfile = os.path.join(home_st, ".pervio", "chat-live", "t1.pid")
deadline = time.time() + 5
while time.time() < deadline and not os.path.exists(pidfile):
    time.sleep(0.05)
check("stop-tag: pidfile appears under ~/.pervio/chat-live", os.path.exists(pidfile))
STOP_LINE = ('t="$HOME/.pervio/chat-live/t1.pid"; if [ -f "$t" ]; then '
             'pid=$(cat "$t"); pg=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d " "); '
             'if [ "$pg" = "$pid" ]; then kill -TERM -- -"$pg" 2>/dev/null; '
             'else pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; fi; '
             'rm -f "$t"; fi')
subprocess.run(["bash", "-lc", STOP_LINE], env=env_st, capture_output=True, timeout=15)
try:
    turn.wait(timeout=4)
    stopped = True
except subprocess.TimeoutExpired:
    stopped = False
    turn.kill()
elapsed_st = time.time() - t0_st
# The shim writes its files BEFORE its 8s sleep, so the marker proves nothing
# about the kill — the clock does: a turn that dies well under the 8s sleep
# was TERMed mid-nap, not finished.
check("stop-tag: the stop line kills the live turn mid-sleep",
      stopped and elapsed_st < 7.0, (stopped, round(elapsed_st, 2)))
check("stop-tag: pidfile removed by the stop", not os.path.exists(pidfile))
shutil.rmtree(home_st, ignore_errors=True)

print("=== find_cli: a CLI installed through nvm, off the SSH PATH ===")
home_nvm = tempfile.mkdtemp(prefix="pchat_nvm_", dir="/tmp")
nvm_bin = os.path.join(home_nvm, ".nvm", "versions", "node", "v22.1.0", "bin")
os.makedirs(nvm_bin)
shutil.copy(os.path.join(SHIM, "codex"), os.path.join(nvm_bin, "codex"))
os.chmod(os.path.join(nvm_bin, "codex"), 0o755)
# No shim dir, no Homebrew on PATH — the bare PATH an SSH exec channel gets.
env_nvm = dict(os.environ, HOME=home_nvm, PATH="/usr/bin:/bin:/usr/sbin:/sbin", SHELL="/bin/sh")
p = subprocess.run([CHAT, "engines"], env=env_nvm, capture_output=True, text=True, timeout=60)
try:
    eng = json.loads(p.stdout)
except ValueError:
    eng = {}
check("engines finds codex under ~/.nvm/versions/node/*/bin when PATH has none",
      eng.get("codex") == os.path.join(nvm_bin, "codex"), (p.returncode, p.stdout[:200], p.stderr[:200]))
# …and LAUNCHES it: an npm-installed codex is `#!/usr/bin/env node`, and node
# lives next to it in that same folder — which must be on PATH at launch, or
# the turn dies with "env: node: No such file or directory" (a tester's second
# Codex turn, 2026-10-15). The fake node here execs the committed shim.
with open(os.path.join(nvm_bin, "codex"), "w") as f:
    f.write("#!/usr/bin/env node\n// npm's codex launcher stand-in\n")
with open(os.path.join(nvm_bin, "node"), "w") as f:
    f.write('#!/bin/sh\nshift\nexec python3 "%s" "$@"\n' % os.path.join(SHIM, "codex"))
os.chmod(os.path.join(nvm_bin, "codex"), 0o755)
os.chmod(os.path.join(nvm_bin, "node"), 0o755)
p = subprocess.run([CHAT, "--text", "--backend", "codex", "--dir", home_nvm,
                    "--prompt-b64", b64("hi\nSHIM:" + json.dumps({"text": "nvm ok"}))],
                   env=env_nvm, capture_output=True, text=True, timeout=60)
check("a node-script codex found under nvm runs: its folder is put on PATH so `env node` resolves",
      p.returncode == 0 and "nvm ok" in p.stdout, (p.returncode, p.stdout[-120:], p.stderr[-200:]))
shutil.rmtree(home_nvm, ignore_errors=True)

print("=== the login shell's PATH is borrowed: wherever their Terminal finds codex, we do ===")
home_lp = tempfile.mkdtemp(prefix="pchat_lp_", dir="/tmp")
tools = os.path.join(home_lp, "my-tools"); os.makedirs(tools)
os.symlink(os.path.join(SHIM, "codex"), os.path.join(tools, "codex"))
# /bin/sh -l reads ~/.profile — the stand-in for a .zshrc that extends PATH.
with open(os.path.join(home_lp, ".profile"), "w") as f:
    f.write('export PATH="%s:$PATH"\n' % tools)
env_lp = dict(os.environ, HOME=home_lp, PATH="/usr/bin:/bin:/usr/sbin:/sbin", SHELL="/bin/sh")
env_lp.pop("PERVIO_CHAT_PATH_ONLY", None); env_lp.pop("PERVIO_E2E", None)
p = subprocess.run([CHAT, "engines"], env=env_lp, capture_output=True, text=True, timeout=60)
try:
    eng = json.loads(p.stdout)
except ValueError:
    eng = {}
check("engines finds a codex that only the login shell's PATH knows about",
      eng.get("codex") == os.path.join(tools, "codex"), (p.returncode, p.stdout[:200], p.stderr[:200]))
check("the borrowed PATH is cached under ~/.pervio/cache/login-path",
      os.path.isfile(os.path.join(home_lp, ".pervio", "cache", "login-path")))
p = subprocess.run([CHAT, "--text", "--backend", "codex", "--dir", home_lp,
                    "--prompt-b64", b64("hi\nSHIM:" + json.dumps({"text": "lp ok"}))],
                   env=env_lp, capture_output=True, text=True, timeout=60)
check("…and a turn on it runs", p.returncode == 0 and "lp ok" in p.stdout, (p.returncode, p.stderr[-200:]))
shutil.rmtree(home_lp, ignore_errors=True)

# ---------- Codex over app-server (pervio-codex-app), compared with exec (2026-10-18) ----------
# The codex that has `app-server` runs the turn through pervio-codex-app; the
# phone must not be able to tell — same event stream, same prompt assembly,
# same folders, same provider — and it gains what exec never had: approvals
# answered from the phone, a real interrupt, resume by thread id.
print("=== CXA codex app-server vs exec ===")
home_ca = tempfile.mkdtemp(prefix="pchat_cxa_", dir="/tmp")
rpc_log = os.path.join(home_ca, "rpc.jsonl"); prompt_log = os.path.join(home_ca, "prompts.log")
argv_ca = os.path.join(home_ca, "argv.jsonl"); appr_log = os.path.join(home_ca, "approvals.log")
def _cxa_env(**extra):
    for f in (rpc_log, prompt_log, argv_ca, appr_log):
        try: os.remove(f)
        except OSError: pass
    return env_for(home_ca, SHIM_RPC_LOG=rpc_log, SHIM_PROMPT_LOG=prompt_log, SHIM_ARGV_LOG=argv_ca,
                   SHIM_APPROVAL_LOG=appr_log, **extra)
def _rpc(method):
    try:
        return [json.loads(l) for l in open(rpc_log) if l.strip() and json.loads(l).get("method") == method]
    except OSError:
        return []
def _argv_last():
    try:
        return [json.loads(l) for l in open(argv_ca) if l.strip()][-1][1:]   # [0] is the shim itself
    except (OSError, IndexError):
        return []
def _shape(objs):
    """The phone-facing shape of a stream: what it would render, ids and timing aside."""
    out = []
    for o in objs:
        t = o.get("type")
        if t in ("heartbeat", "item.started"):   # starts are app-server's extra (CXA2b)
            continue
        if t == "item.completed":
            it = o.get("item") or {}
            out.append((t, it.get("type"), it.get("text") or it.get("command")))
        elif t == "turn.completed":
            out.append((t, json.dumps(o.get("usage"), sort_keys=True)))
        elif t == "thread.started":
            out.append((t,))
        else:
            out.append((t, o.get("message") or (o.get("error") or {}).get("message")))
    return out
trace = {"trace": [{"tool": "Bash", "command": "ls"}, {"say": "halfway"}], "text": "cxa done",
         "usage": {"input_tokens": 1200, "cached_input_tokens": 1000, "output_tokens": 30, "reasoning_output_tokens": 5}}
runs = {}
for label, extra in (("exec", {"PERVIO_CODEX_EXEC": "1"}), ("app", {})):
    p = subprocess.run([CHAT, "--text", "--backend", "codex", "--dir", home_ca,
                        "--prompt-b64", b64("compare me\nSHIM:" + json.dumps(trace))],
                       env=_cxa_env(**extra), capture_output=True, text=True, timeout=60)
    objs, torn = parse_lines(p.stdout)
    runs[label] = (p, objs, torn, _argv_last())
check("CXA0 exec run went through codex exec (argv), app-server run through pervio-codex-app (app-server argv)",
      runs["exec"][3][:1] == ["exec"] and runs["app"][3] == ["app-server"], (runs["exec"][3][:2], runs["app"][3]))
check("CXA1 both paths exit 0 with whole JSON lines", all(r[0].returncode == 0 and r[1] and not r[2] for r in runs.values()),
      {k: (v[0].returncode, v[2][:1], v[0].stderr[-150:]) for k, v in runs.items()})
check("CXA2 the phone-facing stream is the SAME shape on both paths (items, texts, commands, usage)",
      _shape(runs["exec"][1]) == _shape(runs["app"][1]), (_shape(runs["exec"][1]), _shape(runs["app"][1])))
check("CXA2b app-server also shows a command row STARTING (exec reported it only when done), the same command",
      ("command_execution", "ls") in [(o["item"].get("type"), o["item"].get("command")) for o in runs["app"][1] if o.get("type") == "item.started"]
      and not any(o.get("type") == "item.started" for o in runs["exec"][1]), [o.get("type") for o in runs["app"][1]])

# prompt assembly is shared: the [env] pointer rides the turn's text on app-server too
p = subprocess.run([CHAT, "--text", "--backend", "codex", "--pervio-context", "--lang", "en", "--dir", home_ca,
                    "--prompt-b64", b64("hello there")], env=_cxa_env(), capture_output=True, text=True, timeout=60)
_pt = open(prompt_log).read().split("===PROMPT-END===")[0] if os.path.exists(prompt_log) else ""
check("CXA3 --pervio-context: the English [env] pointer prefixes the turn text, the user's words intact",
      p.returncode == 0 and _pt.startswith("[env]") and _pt.rstrip().endswith("hello there"), _pt[:160])
turns = _rpc("turn/start")
check("CXA3b the prompt travels as turn/start input text, nothing on the argv",
      turns and "hello there" in json.dumps(turns[-1]["params"]) and _argv_last() == ["app-server"], (len(turns), _argv_last()))

# attached folders → the thread's writable roots (exec's --add-dir); resolved like exec
d_ok = os.path.join(home_ca, "notes"); os.makedirs(d_ok, exist_ok=True)
p = subprocess.run([CHAT, "--text", "--backend", "codex", "--dir", home_ca, "--prompt-b64", b64("hi"), "--extra-dir", d_ok],
                   env=_cxa_env(), capture_output=True, text=True, timeout=60)
starts = _rpc("thread/start")
roots = ((((starts[-1]["params"] if starts else {}).get("config") or {}).get("sandbox_workspace_write") or {}).get("writable_roots"))
check("CXA4 an attached folder becomes the thread's writable root, spelled resolved",
      p.returncode == 0 and roots == [os.path.realpath(d_ok)], (roots, p.stderr[-150:]))
check("CXA4b the sandbox and cwd go in as thread/start params",
      starts and starts[-1]["params"].get("sandbox") == "workspace-write" and starts[-1]["params"].get("cwd") == os.path.realpath(home_ca), starts[-1]["params"] if starts else None)

# the speed tier (the phone's Fast switch): thread/start serviceTier on app-server, -c service_tier on exec
p = subprocess.run([CHAT, "--text", "--backend", "codex", "--dir", home_ca, "--service-tier", "priority", "--prompt-b64", b64("hi")],
                   env=_cxa_env(), capture_output=True, text=True, timeout=60)
_st = _rpc("thread/start")
check("CXA4c --service-tier priority starts the thread on codex's Fast tier", p.returncode == 0 and _st and _st[-1]["params"].get("serviceTier") == "priority", (_st[-1:] if _st else p.stderr[-200:]))
p = subprocess.run([CHAT, "--text", "--backend", "codex", "--dir", home_ca, "--prompt-b64", b64("hi")], env=_cxa_env(), capture_output=True, text=True, timeout=60)
_st = _rpc("thread/start")
check("CXA4d without it the thread says nothing and codex follows the Mac's config.toml", _st and "serviceTier" not in _st[-1]["params"], _st[-1:])
p = subprocess.run([CHAT, "--text", "--backend", "codex", "--dir", home_ca, "--service-tier", "priority", "--prompt-b64", b64("hi")],
                   env=_cxa_env(PERVIO_CODEX_EXEC="1"), capture_output=True, text=True, timeout=60)
check("CXA4e on the exec path the same switch is a -c service_tier override", p.returncode == 0 and any(a.startswith("service_tier=") and "priority" in a for a in _argv_last()), _argv_last())
p = subprocess.run([CHAT, "--text", "--backend", "codex", "--dir", home_ca, "--service-tier", "pri ority; rm", "--prompt-b64", b64("hi")],
                   env=_cxa_env(), capture_output=True, text=True, timeout=60)
check("CXA4f a tier that is not a plain token is refused before anything runs", p.returncode == 2 and not _rpc("thread/start"), (p.returncode, p.stderr[-120:]))

# resume by thread id
p = subprocess.run([CHAT, "--text", "--backend", "codex", "--dir", home_ca, "--resume", "thread-77", "--prompt-b64", b64("again")],
                   env=_cxa_env(), capture_output=True, text=True, timeout=60)
objs, _ = parse_lines(p.stdout)
res = _rpc("thread/resume")
check("CXA5 --resume is thread/resume with that id, and the stream names the same thread",
      p.returncode == 0 and res and res[-1]["params"].get("threadId") == "thread-77"
      and any(o.get("type") == "thread.started" and o.get("thread_id") == "thread-77" for o in objs), (res[-1]["params"] if res else None, objs[:1]))

# who settles approvals: the default is the desktop's "Approve for me" (codex's own
# reviewer), chat and run alike; "Ask" (--reviewer user) puts them on the phone and
# only where a phone is listening; full access has nothing to ask
def _policy():
    s = _rpc("thread/start") + _rpc("thread/resume")
    return (s[-1]["params"].get("approvalPolicy"), s[-1]["params"].get("approvalsReviewer")) if s else None
ask = "do it\nSHIM:" + json.dumps({"approve": {"command": "rm -rf build", "reason": "cleans"}, "text": "after"})
p = subprocess.run([CHAT, "--text", "--backend", "codex", "--dir", home_ca, "--prompt-b64", b64(ask)], env=_cxa_env(), capture_output=True, text=True, timeout=60)
objs, _ = parse_lines(p.stdout)
try: decided = open(appr_log).read().split()
except OSError: decided = []
check("CXA6 default = Approve for me: a headless (--text) turn is on-request with codex's auto_review reviewer",
      _policy() == ("on-request", "auto_review"), _policy())
check("CXA6a …and whatever codex still insists on asking is declined, nobody being there (no permission_request on the stream)",
      p.returncode == 0 and decided == ["decline"] and not any(o.get("type") == "permission_request" for o in objs), (p.returncode, decided, [o.get("type") for o in objs]))
p = subprocess.Popen([CHAT, "--backend", "codex", "--dir", home_ca, "--approve-sid", "cxasid0", "--prompt-b64", b64("hi")],
                     env=_cxa_env(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
p.communicate(timeout=60)
check("CXA6b a live chat with a sid is Approve for me too by default (the phone is not asked first)", _policy() == ("on-request", "auto_review"), _policy())
p = subprocess.Popen([CHAT, "--backend", "codex", "--dir", home_ca, "--approve-sid", "cxasid1", "--sandbox", "danger-full-access", "--prompt-b64", b64("hi")],
                     env=_cxa_env(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
p.communicate(timeout=60)
check("CXA6c full access never asks under either reviewer (nothing to ask)", _policy() == ("never", None), _policy())
p = subprocess.Popen([CHAT, "--backend", "codex", "--dir", home_ca, "--approve-sid", "cxasid3", "--sandbox", "read-only", "--prompt-b64", b64("hi")],
                     env=_cxa_env(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
p.communicate(timeout=60)
check("CXA6c2 read-only never asks either: the person's hard line is not for a reviewer to lift", _policy() == ("never", None), _policy())
p = subprocess.Popen([CHAT, "--backend", "codex", "--dir", home_ca, "--approve-sid", "cxasid2", "--reviewer", "user", "--prompt-b64", b64("hi")],
                     env=_cxa_env(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
p.communicate(timeout=60)
check("CXA6d Ask (--reviewer user) with a live phone: on-request, the person reviews", _policy() == ("on-request", "user"), _policy())
p = subprocess.run([CHAT, "--text", "--backend", "codex", "--dir", home_ca, "--reviewer", "user", "--prompt-b64", b64("hi")], env=_cxa_env(), capture_output=True, text=True, timeout=60)
check("CXA6e Ask with nobody listening (a headless run) never asks, as exec never did", _policy() == ("never", None), _policy())
p = subprocess.run([CHAT, "--text", "--backend", "codex", "--dir", home_ca, "--resume", "thread-78", "--prompt-b64", b64("hi")], env=_cxa_env(), capture_output=True, text=True, timeout=60)
check("CXA6f a resumed thread gets the reviewer too (the mode is per turn, not per thread)", _policy() == ("on-request", "auto_review"), _policy())

# the approval round trip in Ask mode: the request reaches the stream, the phone's answer reaches codex
for behavior, expect in (("allow", "accept"), ("deny", "decline")):
    sid = "cxa" + behavior
    prompt = "do it\nSHIM:" + json.dumps({"approve": {"command": "rm -rf build", "reason": "cleans the tree"}, "text": "after approval"})
    p = subprocess.Popen([CHAT, "--backend", "codex", "--dir", home_ca, "--approve-sid", sid, "--reviewer", "user", "--prompt-b64", b64(prompt)],
                         env=_cxa_env(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    seen, req = [], None
    deadline = time.time() + 30
    while time.time() < deadline:
        line = p.stdout.readline()
        if not line:
            break
        seen.append(line)
        try: o = json.loads(line)
        except ValueError: continue
        if o.get("type") == "permission_request":
            req = o; break
    check("CXA7 (%s) the approval request reaches the phone as a permission_request with the command" % behavior,
          req is not None and req.get("tool_name") == "Bash" and req.get("input", {}).get("command") == "rm -rf build" and req.get("request_id"),
          seen[-3:])
    if req:
        subprocess.run([CHAT, "respond", "--sid", sid, "--request-id", req["request_id"], "--behavior", behavior],
                       env=_cxa_env.__globals__["env_for"](home_ca), capture_output=True, timeout=10)
    rest = p.stdout.read(); rc = p.wait(timeout=60)
    objs, _ = parse_lines("".join(seen) + rest)
    try: decided = open(appr_log).read().split()
    except OSError: decided = []
    check("CXA7b (%s) codex got the decision and the turn ran on to its answer" % behavior,
          rc == 0 and decided == [expect] and any(o.get("type") == "item.completed" and (o.get("item") or {}).get("text") == "after approval" for o in objs)
          and any(o.get("type") == "permission_resolved" and o.get("behavior") == behavior for o in objs),
          (rc, decided, [o.get("type") for o in objs]))

# a stop while an approval waits on the phone: the interrupt goes first, the wait is released as a cancel
prompt = "ask then wait\nSHIM:" + json.dumps({"approve": {"command": "rm -rf build", "reason": "x"}, "text": "never"})
p = subprocess.Popen([CHAT, "--backend", "codex", "--dir", home_ca, "--approve-sid", "cxastopask", "--reviewer", "user", "--prompt-b64", b64(prompt)],
                     env=_cxa_env(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, start_new_session=True)
seen = []
while True:
    line = p.stdout.readline()
    if not line: break
    seen.append(line)
    if '"permission_request"' in line: break
os.killpg(os.getpgid(p.pid), signal.SIGTERM)
rest = p.stdout.read(); rc = p.wait(timeout=30)
objs, _ = parse_lines("".join(seen) + rest)
try: decided = open(appr_log).read().split()
except OSError: decided = []
check("CXA7c a stop while the phone is being asked: codex got the interrupt first, the request was released as a cancel, exit 143",
      rc == 143 and decided == ["interrupted"] and any(o.get("type") == "permission_resolved" and o.get("behavior") == "cancel" for o in objs)
      and any(o.get("type") == "turn.failed" for o in objs), (rc, decided, [o.get("type") for o in objs]))

# stop is a real interrupt: TERM → turn/interrupt → the stream says interrupted
prompt = "slow\nSHIM:" + json.dumps({"sleep": 8, "text": "never"})
p = subprocess.Popen([CHAT, "--backend", "codex", "--dir", home_ca, "--stop-tag", "cxastop", "--prompt-b64", b64(prompt)],
                     env=_cxa_env(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, start_new_session=True)
first = p.stdout.readline()
time.sleep(1.0)
os.killpg(os.getpgid(p.pid), signal.SIGTERM)
rest = p.stdout.read(); rc = p.wait(timeout=30)
objs, _ = parse_lines(first + rest)
check("CXA8 a stop (TERM to the turn's group, as the phone sends it) becomes turn/interrupt to codex; the stream ends as interrupted, exit 143",
      len(_rpc("turn/interrupt")) == 1 and any(o.get("type") == "turn.failed" and "interrupt" in json.dumps(o) for o in objs) and rc == 143,
      (rc, [o.get("type") for o in objs], len(_rpc("turn/interrupt"))))
check("CXA8b codex itself was not in the group that got the TERM (it answered the interrupt, then left on its own)",
      _rpc("turn/interrupt") and _rpc("turn/interrupt")[-1]["params"].get("threadId") == "shimthread", _rpc("turn/interrupt")[-1:])

# the living run (2026-10-20): further user messages arrive on --input-fifo as stream-json
# lines and become turns on the SAME thread; EOF on the fifo ends the process clean
fifo = os.path.join(home_ca, "in.fifo")
if os.path.exists(fifo): os.remove(fifo)
os.mkfifo(fifo, 0o600)
keeper_fd = os.open(fifo, os.O_RDWR)            # what pervio-run's keeper does: hold the writing end
p = subprocess.Popen([CHAT, "--text", "--backend", "codex", "--dir", home_ca, "--input-fifo", fifo,
                      "--prompt-b64", b64("first\nSHIM:" + json.dumps({"text": "first done"}))],
                     env=_cxa_env(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
got = []
deadline = time.time() + 20
while time.time() < deadline:
    line = p.stdout.readline()
    if not line: break
    got.append(line)
    if '"turn.completed"' in line: break
check("CXA11 the first turn completes and the process STAYS (it has a fifo to listen to)", any('"turn.completed"' in l for l in got) and p.poll() is None, (got[-1:] if got else None, p.poll()))
os.write(keeper_fd, (json.dumps({"type": "user", "message": {"role": "user", "content": "second\nSHIM:" + json.dumps({"text": "second done"})}}) + "\n").encode())
got2 = []
deadline = time.time() + 20
while time.time() < deadline:
    line = p.stdout.readline()
    if not line: break
    got2.append(line)
    if '"turn.completed"' in line: break
_turns = _rpc("turn/start")
check("CXA11b a message dropped into the fifo is a second turn/start on the same thread, answered by the same process",
      len(_turns) == 2 and _turns[-1]["params"].get("threadId") == _turns[0]["params"].get("threadId") and "second" in json.dumps(_turns[-1]["params"])
      and any('"second done"' in l for l in got2) and any('"turn.completed"' in l for l in got2) and p.poll() is None, (len(_turns), [l[:80] for l in got2][-3:], p.poll()))
check("CXA11c the second turn announced itself (turn.started) so the run's status knows a turn is open", any('"turn.started"' in l for l in got2), [l[:60] for l in got2])
os.close(keeper_fd)                              # the keeper lets go: EOF
rest = p.stdout.read(); rc = p.wait(timeout=20)
check("CXA11d EOF on the fifo ends the process clean (exit 0), nothing more emitted", rc == 0 and rest.strip() == "", (rc, rest[:120]))
os.remove(fifo)

# a message arriving while the turn RUNS is steered into it (turn/steer, 2026-10-21):
# the shim's sleeping turn takes the words, one turn, one turn/completed, the
# answer carrying both; no second turn/start.
fifo2 = os.path.join(home_ca, "in2.fifo")
if os.path.exists(fifo2): os.remove(fifo2)
os.mkfifo(fifo2, 0o600)
keeper_fd2 = os.open(fifo2, os.O_RDWR)
p = subprocess.Popen([CHAT, "--text", "--backend", "codex", "--dir", home_ca, "--input-fifo", fifo2,
                      "--prompt-b64", b64("slow\nSHIM:" + json.dumps({"text": "slow done", "sleep": 2.5}))],
                     env=_cxa_env(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
got3 = []
deadline = time.time() + 20
while time.time() < deadline:
    line = p.stdout.readline()
    if not line: break
    got3.append(line)
    if '"thread.started"' in line: break
time.sleep(0.6)                                   # the shim is "working" now
os.write(keeper_fd2, (json.dumps({"type": "user", "message": {"role": "user", "content": "also SECOND"}}) + "\n").encode())
deadline = time.time() + 20
while time.time() < deadline:
    line = p.stdout.readline()
    if not line: break
    got3.append(line)
    if '"turn.completed"' in line: break
_steers = _rpc("turn/steer")
check("CXA12 a message during the turn is turn/steer on the active turn (its id as the precondition), not a second turn/start",
      len(_steers) == 1 and _steers[0]["params"].get("expectedTurnId") == "turn-1" and _steers[0]["params"].get("threadId") == "shimthread"
      and "also SECOND" in json.dumps(_steers[0]["params"]) and len(_rpc("turn/start")) == 1, (_steers, len(_rpc("turn/start"))))   # the shim's rpc log is this process's own
check("CXA12b one turn: a single turn.completed, the answer carrying both the turn's words and the steered ones, no turn.started",
      sum(1 for l in got3 if '"turn.completed"' in l) == 1 and any('"slow done' in l and 'also SECOND' in l for l in got3)
      and not any('"turn.started"' in l for l in got3) and p.poll() is None, ([l[:90] for l in got3][-3:], p.poll()))
# the moment codex makes the fed words part of the turn is announced on the
# stream (2026-11-21): until then they are in nobody's record, and a phone
# opening the conversation has only this to place them by
def _taken(lines):
    out = []
    for l in lines:
        try:
            o = json.loads(l)
        except ValueError:
            continue
        if o.get("type") == "pervio" and o.get("subtype") == "turn_taken":
            out.append(o.get("text"))
    return out
check("CXA12e codex taking the steered words is announced once, with the words, before the turn completes",
      _taken(got3) == ["also SECOND"]
      and [i for i, l in enumerate(got3) if '"turn_taken"' in l][0] < [i for i, l in enumerate(got3) if '"turn.completed"' in l][0],
      [l[:100] for l in got3])
check("CXA12f the run's own first prompt is not announced — nobody waits to hear about it",
      not any("slow" in (t or "") for t in _taken(got3)), _taken(got3))
# and a message once the turn is over is a new turn, as before
os.write(keeper_fd2, (json.dumps({"type": "user", "message": {"role": "user", "content": "after\nSHIM:" + json.dumps({"text": "after done"})}}) + "\n").encode())
got4 = []
deadline = time.time() + 20
while time.time() < deadline:
    line = p.stdout.readline()
    if not line: break
    got4.append(line)
    if '"turn.completed"' in line: break
check("CXA12c a message after the turn ended is a turn/start of its own (steer only steers a running turn)",
      len(_rpc("turn/start")) == 2 and len(_rpc("turn/steer")) == 1 and any('"after done"' in l for l in got4), (len(_rpc("turn/start")), [l[:80] for l in got4][-2:]))
check("CXA12g a fed message that starts a turn of its own is announced too, after that turn started",
      len(_taken(got4)) == 1 and _taken(got4)[0].startswith("after")
      and [i for i, l in enumerate(got4) if '"turn.started"' in l][:1] < [i for i, l in enumerate(got4) if '"turn_taken"' in l][:1],
      [l[:100] for l in got4])
os.close(keeper_fd2)
rc = p.wait(timeout=20)
check("CXA12d EOF then ends it clean", rc == 0, rc)
os.remove(fifo2)

# an older codex without app-server takes the exec path untouched
p = subprocess.run([CHAT, "--text", "--backend", "codex", "--dir", home_ca, "--prompt-b64", b64("hi\nSHIM:" + json.dumps({"text": "old ok"}))],
                   env=_cxa_env(SHIM_CODEX_NO_APPSERVER="1"), capture_output=True, text=True, timeout=60)
check("CXA9 an older codex (no app-server) runs through exec as before", p.returncode == 0 and "old ok" in p.stdout and _argv_last()[:1] == ["exec"], (p.returncode, _argv_last()[:2]))

# ---------- Codex sub-agents (2026-11-22): a sub-agent is a thread of its own ----------
# The stream is a REAL one: what codex 0.169's app-server sent for a turn that
# spawned two sub-agents (server/tests/tasks, recorded by capture_tasks.py),
# played back by the shim. Each sub-agent's turns, items and token usage arrive
# on the same connection under its own threadId. Read as the conversation's own
# — as they were — the first sub-agent to finish ended the whole turn: the
# answer never reached the phone and the sub-agent's last words stood in its
# place (found by running it, the person's "你不是可以试试看么").
print("=== CXS codex sub-agents: their threads are not the conversation's ===")
REPLAY = os.path.join(HERE, "tasks", "codex-subagents.appserver.jsonl")
raw = [json.loads(l) for l in open(REPLAY, encoding="utf-8") if l.strip()]
main_thread = next(m["params"]["threadId"] for m in raw if m["method"] == "turn/started")
sub_threads = sorted({m["params"]["threadId"] for m in raw if m["params"].get("threadId") != main_thread})
def _texts(thread, kind="agentMessage"):
    return [m["params"]["item"].get("text") for m in raw if m["method"] == "item/completed" and m["params"]["threadId"] == thread
            and m["params"]["item"].get("type") == kind and m["params"]["item"].get("text")]
sub_said = [t for th in sub_threads for t in _texts(th)]
# What the recording itself says of each sub-agent (a re-recording names and
# words things anew: the checks below read them from the file, not from here).
sub_paths = []
for m in raw:
    it = m["params"].get("item") or {}
    if m["method"] == "item/started" and it.get("type") == "subAgentActivity" and it.get("kind") == "started":
        sub_paths.append((it["agentThreadId"], it["agentPath"], " · ".join(x for x in (it.get("model"), it.get("reasoningEffort")) if x)))
sub_cmds = [m["params"]["item"]["command"] for m in raw if m["method"] == "item/started" and m["params"]["threadId"] in sub_threads
            and m["params"]["item"].get("type") == "commandExecution"]
def _said_of(cmd):
    """`/bin/zsh -lc '<lines>'` → the lines, joined the way a person would say them."""
    inner = cmd[cmd.index("'") + 1:cmd.rindex("'")] if cmd.count("'") >= 2 else cmd
    return "Running " + "; ".join(" ".join(l.split()) for l in inner.splitlines() if l.strip())
main_said = _texts(main_thread)
check("CXS0 the recording is what it is used as: two sub-agent threads, each with a turn of its own that completes BEFORE the conversation's",
      len(sub_threads) == 2 and len(sub_said) == 2 and main_said
      and [m["params"]["threadId"] == main_thread for m in raw if m["method"] == "turn/completed"] == [False, False, True],
      (sub_threads, sub_said, main_said))
p = subprocess.run([CHAT, "--text", "--backend", "codex", "--dir", home_ca, "--prompt-b64", b64("spawn two")],
                   env=_cxa_env(SHIM_CODEX_REPLAY=REPLAY), capture_output=True, text=True, timeout=60)
objs, torn = parse_lines(p.stdout)
objs = [o for o in objs if o.get("type") != "heartbeat"]
kinds = [o.get("type") for o in objs]
said = [o["item"].get("text") for o in objs if o.get("type") == "item.completed" and o["item"].get("type") == "agent_message"]
check("CXS1 the turn ends once, at the conversation's own turn/completed — after the answer, not at a sub-agent's",
      p.returncode == 0 and not torn and kinds.count("turn.completed") == 1 and kinds[-1] == "turn.completed"
      and said and said[-1] == main_said[-1], (p.returncode, kinds[-4:], said, p.stderr[-200:]))
check("CXS2 nothing a sub-agent said or ran is shown as the conversation's: its messages and commands are not items of the stream",
      said == main_said and not any(t in said for t in sub_said)
      and not any(o.get("type") in ("item.started", "item.completed") and o["item"].get("type") == "command_execution" for o in objs),
      (said, [o["item"].get("type") for o in objs if o.get("type", "").startswith("item.")]))
main_usage = [m["params"]["tokenUsage"]["last"] for m in raw if m["method"] == "thread/tokenUsage/updated" and m["params"]["threadId"] == main_thread][-1]
done = next(o for o in objs if o.get("type") == "turn.completed")
check("CXS3 the turn's usage is the conversation's own last request, not a sub-agent's",
      (done.get("usage") or {}).get("input_tokens") == main_usage["inputTokens"], (done.get("usage"), main_usage))
tasks = [o for o in objs if o.get("type") == "system"]
sets = [[t["task_id"] for t in o["tasks"]] for o in tasks if o.get("subtype") == "background_tasks_changed"]
started = [o for o in tasks if o.get("subtype") == "task_started"]
check("CXS4 each sub-agent is announced as a task the way Claude Code announces its own: by its thread id, named by its path, typed by its model",
      len(sets) > 1 and [o["task_id"] for o in started] == sets[1] and sorted(o["task_id"] for o in started) == sub_threads
      and [(o["task_id"], "/root/" + o["description"], o.get("subagent_type")) for o in started] == sub_paths
      and all(o.get("task_type") == "local_agent" and o.get("is_backgrounded") is True and o.get("subagent_type") for o in started),
      [(o.get("task_id"), o.get("description"), o.get("subagent_type")) for o in started])
check("CXS5 the pending set follows them: one, two, one, none",
      [len(x) for x in sets] == [1, 2, 1, 0] and all(set(x) <= set(sub_threads) for x in sets), sets)
prog = [o for o in tasks if o.get("subtype") == "task_progress"]
check("CXS6 a sub-agent's progress says what it runs (the command itself, not the login shell around it) and how much context it holds",
      bool(prog) and bool(sub_cmds) and all("zsh -lc" in c for c in sub_cmds) and {_said_of(c) for c in sub_cmds} <= {o["description"] for o in prog}
      and all("zsh" not in o["description"] for o in prog)
      and max([o["usage"]["total_tokens"] for o in prog] or [0]) > 10000 and all(o["usage"]["tool_uses"] >= 1 for o in prog),
      [(o["description"], o["usage"]) for o in prog])
notes = [o for o in tasks if o.get("subtype") == "task_notification"]
check("CXS7 each ends once, completed, with its own last words as what it came back with",
      len(notes) == 2 and all(o["status"] == "completed" for o in notes) and sorted(o["summary"] for o in notes) == sorted(sub_said)
      and all(o["usage"]["total_tokens"] > 10000 for o in notes), [(o["task_id"], o["status"], o["summary"]) for o in notes])
check("CXS8 the order the phone sees: both announced, both ended, the set empty, THEN the answer",
      len(notes) == 2 and bool(sets) and "turn.completed" in kinds
      and kinds.index("turn.completed") > max(i for i, o in enumerate(objs) if o.get("subtype") == "task_notification")
      and [i for i, o in enumerate(objs) if o.get("type") == "item.completed" and o["item"].get("text") == main_said[-1]][:1]
          > [max(i for i, o in enumerate(objs) if o.get("subtype") == "background_tasks_changed")], kinds)
shutil.rmtree(home_ca, ignore_errors=True)


ok = all(results)
print("\n=== pervio-chat live channels: %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
