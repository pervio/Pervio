#!/usr/bin/env python3
"""Drive the REAL parsers with the REAL agent event corpus in server/tests/corpus.

    python3 server/tests/test_event_corpus.py             # zero cost, zero network
    python3 server/tests/test_event_corpus.py --refresh    # ALSO re-capture live (spends quota)

Parsers under test — the shipping ones, imported/executed, never re-implemented:
  * pervio-orchestrate `_step_output`  — what a workflow step's text/error/session
    id/token count is distilled from.
  * pervio-sessions `transcript`        — what the phone renders when it reopens a
    conversation, run as a subprocess against a throwaway $HOME seeded with the
    frozen session files (the production ~/.claude and ~/.codex are never touched).

Plus a DRIFT SENTINEL. Values in a real stream change every run, so the sentinel
compares the *field set per event type* instead: values may change, structure may
not. With --refresh it re-captures both backends and diffs the fresh shape against
the frozen one. Without --refresh it spends nothing — and still proves it works, by
mutating a COPY of the frozen corpus three ways (add a field, drop a field, drop a
whole event type) and asserting every mutation is caught and named.
"""
import argparse
import copy
import datetime as dt
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
CORPUS = os.path.join(HERE, "corpus")
ORCH = os.path.realpath(os.path.join(HERE, "..", "bin", "pervio-orchestrate"))
SESSIONS = os.path.realpath(os.path.join(HERE, "..", "bin", "pervio-sessions"))
WORKDIR = "/home/pervio/work"                 # the redacted cwd every capture records
SID = "00000000-0000-4000-8000-000000000001"  # every capture's redacted session/thread id

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name +
          (("  [" + str(detail)[:400] + "]") if (detail and not cond) else ""))


def _load(path, name):
    loader = importlib.machinery.SourceFileLoader(name, path)
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader(name, loader))
    loader.exec_module(mod)
    return mod


orch = _load(ORCH, "orch")
cap = _load(os.path.join(HERE, "capture_corpus.py"), "capture_corpus")


def stream_path(name):
    return os.path.join(CORPUS, name + ".jsonl")


def session_path(name):
    return os.path.join(CORPUS, name + ".session.jsonl")


def lines_of(path):
    with open(path, "r", errors="replace") as f:
        return [l for l in f if l.strip()]


def objs_of(path):
    return [json.loads(l) for l in lines_of(path)]


# --------------------------------------------------------------------------- #
# 1. the corpus is real, complete, and honest about its twins
# --------------------------------------------------------------------------- #
print("=== corpus integrity ===")

for sc in cap.SCENARIOS:
    p, m = stream_path(sc.name), os.path.join(CORPUS, sc.name + ".meta.json")
    ok = os.path.isfile(p) and os.path.isfile(m)
    check("%s: stream + sidecar frozen" % sc.name, ok)
    if not ok:
        continue
    try:
        objs_of(p)
        parses, bad = True, ""
    except ValueError as e:
        parses, bad = False, str(e)
    check("%s: every line is valid JSON" % sc.name, parses, bad)
    meta = json.load(open(m))
    check("%s: sidecar records the capture command, CLI version and date" % sc.name,
          meta.get("command", "").startswith("server/bin/pervio-chat")
          and bool(meta.get("cliVersion")) and bool(meta.get("capturedUTC")), meta.get("command"))
    # A real turn's sidecar cannot be faked into existence by hand: it carries the
    # backend's own accounting (or, for the two free scenarios, an explicit exit != 0).
    usage = meta.get("usage") or {}
    real = (sc.free and meta.get("exitCode") not in (0, None)) or \
           (usage.get("inputTokens") is not None and usage.get("outputTokens") is not None)
    check("%s: sidecar carries real turn accounting" % sc.name, real, meta)

# The strongest cheap evidence that this corpus was RECORDED, not typed: the session
# file's own clock. Its timestamps must be non-decreasing and must span roughly the
# wall-clock duration the sidecar independently measured for that turn — two
# artefacts, written by different processes, agreeing about one real event in time.
print("=== the corpus was recorded, not written ===")


def _stamps(path, conversation_only=False):
    """Top-level ISO timestamps. `conversation_only` keeps just the message lines:
    claude stamps a turn's `attachment` bookkeeping with the PROMPT's time, ~1 ms
    before the `user` line it follows, so a whole-file monotonicity claim would be
    false — a real property of real files, found by this very check."""
    out = []
    for o in objs_of(path):
        t = o.get("timestamp")
        if not (isinstance(t, str) and t.endswith("Z")):
            continue
        if conversation_only and o.get("type") not in ("user", "assistant", "response_item"):
            continue
        out.append(t)
    return out


for sc in cap.SCENARIOS:
    sp = session_path(sc.name)
    if not os.path.isfile(sp):
        continue
    stamps = _stamps(sp)
    talk = _stamps(sp, conversation_only=True)
    secs = (json.load(open(os.path.join(CORPUS, sc.name + ".meta.json"))) or {}).get("seconds", 0)
    check("%s: the session file carries a real clock" % sc.name, len(stamps) >= 3, len(stamps))
    check("%s: the CONVERSATION's timestamps never go backwards" % sc.name,
          bool(talk) and talk == sorted(talk), (talk[:2], talk[-2:]))
    if len(stamps) >= 2:
        span = (dt.datetime.strptime(stamps[-1][:19], "%Y-%m-%dT%H:%M:%S")
                - dt.datetime.strptime(stamps[0][:19], "%Y-%m-%dT%H:%M:%S")).total_seconds()
        check("%s: that clock agrees with the sidecar's measured duration (%.1fs)"
              % (sc.name, secs), 0 <= span <= secs + 10, (span, secs))

print("=== twin coverage (every claude scenario needs a codex one, or a reason) ===")
for sc in cap.SCENARIOS:
    if sc.twin:
        check("%s <-> %s twinned" % (sc.name, sc.twin), sc.twin in cap.BY_NAME
              and cap.BY_NAME[sc.twin].twin == sc.name, sc.twin)
    else:
        check("%s: no twin, and the reason is documented" % sc.name,
              bool(sc.no_twin) and len(sc.no_twin) > 60, sc.no_twin)
readme = open(os.path.join(CORPUS, "README.md")).read()
check("README documents every un-twinned scenario",
      all(sc.name in readme for sc in cap.SCENARIOS if not sc.twin))

print("=== iOS mirror is the SAME bytes (not a stale second copy) ===")
for sc in cap.SCENARIOS:
    ios = os.path.join(cap.IOS_EVENTS, sc.name + ".jsonl")
    same = os.path.isfile(ios) and \
        open(ios, "rb").read() == open(stream_path(sc.name), "rb").read()
    check("%s: ios/Tests/Fixtures/events copy is identical" % sc.name, same,
          "re-sync: python3 server/tests/capture_corpus.py --rescrub")

print("=== redaction held ===")
for sc in cap.SCENARIOS:
    for p in (stream_path(sc.name), session_path(sc.name)):
        if not os.path.isfile(p):
            continue
        bad = cap.leak_scan(open(p, errors="replace").read(), os.path.basename(p))
        check("%s: no leaked identity" % os.path.basename(p), not bad, bad)


# --------------------------------------------------------------------------- #
# 2. the event kinds we PAID to record are actually in there
# --------------------------------------------------------------------------- #
print("=== the corpus really covers every event kind the batch asked for ===")

def keys_of(name):
    return set(cap.event_key(o) for o in objs_of(stream_path(name)))


def deltas_of(name):
    out = set()
    for o in objs_of(stream_path(name)):
        if o.get("type") == "stream_event":
            d = ((o.get("event") or {}).get("delta") or {})
            if d.get("type"):
                out.add(d["type"])
    return out


def tool_names(name):
    out = []
    for o in objs_of(stream_path(name)):
        if o.get("type") == "assistant":
            out += [b.get("name") for b in (o["message"].get("content") or [])
                    if b.get("type") == "tool_use"]
    return out


check("claude: plain text + a final result with usage",
      {"system/init", "assistant", "result/success"} <= keys_of("claude-text"))
check("claude: stream-json really is SHARDED (text_delta arrives in pieces)",
      "text_delta" in deltas_of("claude-text"))
check("claude: thinking shards + their signature",
      {"thinking_delta", "signature_delta"} <= deltas_of("claude-think"))
check("claude: tool_use and tool_result both present",
      "Write" in tool_names("claude-tools") and "Read" in tool_names("claude-tools")
      and any(b.get("type") == "tool_result"
              for o in objs_of(stream_path("claude-tools")) if o.get("type") == "user"
              for b in (o["message"].get("content") or [])), tool_names("claude-tools"))
check("claude: a real ExitPlanMode plan", "ExitPlanMode" in tool_names("claude-plan"))
check("claude: a real permission_request answered with a real Deny",
      "permission_request" in keys_of("claude-approval")
      and any(o.get("type") == "permission_resolved" and o.get("behavior") == "deny"
              for o in objs_of(stream_path("claude-approval"))))
check("claude: an error/aborted turn", "result/success" in keys_of("claude-error")
      and any(o.get("type") == "result" and o.get("is_error")
              for o in objs_of(stream_path("claude-error"))))
check("codex: thread/turn/item envelope + turn.completed usage",
      {"thread.started", "turn.started", "item.completed/agent_message", "turn.completed"}
      <= keys_of("codex-text"))
check("codex: usage reports reasoning tokens (its only trace of thinking)",
      any(o.get("type") == "turn.completed" and "reasoning_output_tokens" in (o.get("usage") or {})
          for o in objs_of(stream_path("codex-text"))))
check("codex: command_execution AND file_change items",
      {"item.started/command_execution", "item.completed/command_execution",
       "item.completed/file_change"} <= keys_of("codex-tools"))
check("codex: a failed turn (error + turn.failed)",
      {"error", "turn.failed"} <= keys_of("codex-error"))


# --------------------------------------------------------------------------- #
# 3. pervio-orchestrate._step_output on the real streams
# --------------------------------------------------------------------------- #
print("=== pervio-orchestrate _step_output (the real workflow-step parser) ===")

# want_text: an exact string, or None for "some output, content not pinned", or ""
# for "there is genuinely no agent text" (a codex turn that died never emits an
# agent_message, so the failure lives ONLY in err — that asymmetry is the point).
STEP_EXPECT = [
    # name,             backend,  text,                    err?,  tokens?
    ("claude-text",     "claude", "The corpus is alive.",   False, True),
    ("claude-think",    "claude", "28",                     False, True),
    ("claude-tools",    "claude", "done",                   False, True),
    ("claude-approval", "claude", None,                     False, True),
    ("claude-plan",     "claude", None,                     False, True),
    ("claude-error",    "claude", None,                     True,  True),
    ("codex-text",      "codex",  "The corpus is alive.",   False, True),
    ("codex-tools",     "codex",  "done",                   False, True),
    ("codex-error",     "codex",  "",                       True,  False),
]

for name, backend, want_text, want_err, want_tok in STEP_EXPECT:
    text, err, sid, tok = orch._step_output(stream_path(name), backend)
    if want_text:
        check("%s: step output text" % name, text.strip() == want_text, repr(text[:120]))
    elif want_text == "":
        check("%s: no agent text at all — the failure rides err alone" % name,
              text == "", repr(text[:120]))
    else:
        check("%s: step produced some output" % name, bool(text.strip()), repr(text[:120]))
    check("%s: error flagged=%s" % (name, want_err), bool(err) == want_err, repr(err[:120]))
    check("%s: session/thread id recovered (delete can reap the conversation)" % name,
          sid == SID, sid)
    if want_tok:
        check("%s: token accounting present" % name,
              isinstance(tok.get("tokensIn"), int) and isinstance(tok.get("tokensOut"), int), tok)
    else:
        check("%s: no usage reported, and _step_output says so honestly" % name, tok == {}, tok)

# The two backends disagree about where the failure text lives (claude: result.result
# with is_error; codex: turn.failed.error.message). Both must surface as `err`.
_, cerr, _, _ = orch._step_output(stream_path("claude-error"), "claude")
_, xerr, _, _ = orch._step_output(stream_path("codex-error"), "codex")
check("both backends' failures surface through the SAME err channel",
      "claude-nope-9" in cerr and "gpt-nope-9" in xerr, (cerr[:60], xerr[:60]))

# Parsing a claude stream as codex (and vice versa) must degrade, not explode.
check("cross-backend misparse degrades quietly",
      orch._step_output(stream_path("claude-text"), "codex")[0] == ""
      and orch._step_output(stream_path("codex-text"), "claude")[0] == "")


# --------------------------------------------------------------------------- #
# 4. pervio-sessions transcript on the real session files
# --------------------------------------------------------------------------- #
print("=== pervio-sessions transcript (the real reload parser) ===")


def transcript(name, backend):
    """Run the REAL pervio-sessions against a throwaway $HOME seeded with this
    scenario's frozen session file. Never reads or writes the production home."""
    home = tempfile.mkdtemp(prefix="corpushome_", dir="/tmp")
    try:
        if backend == "codex":
            d = os.path.join(home, ".codex", "sessions", "2026", "08", "07")
            os.makedirs(d)
            shutil.copy(session_path(name),
                        os.path.join(d, "rollout-2026-08-07T00-00-00-%s.jsonl" % SID))
        else:
            d = os.path.join(home, ".claude", "projects", "-home-pervio-work")
            os.makedirs(d)
            shutil.copy(session_path(name), os.path.join(d, SID + ".jsonl"))
        argv = [sys.executable, SESSIONS, "transcript", "--dir", WORKDIR, "--session", SID]
        if backend == "codex":
            argv += ["--backend", "codex"]
        p = subprocess.run(argv, env=dict(os.environ, HOME=home),
                           capture_output=True, text=True)
        try:
            return json.loads(p.stdout), p
        except ValueError:
            return None, p
    finally:
        shutil.rmtree(home, ignore_errors=True)


turns, p = transcript("claude-tools", "claude")
check("claude transcript decodes", turns is not None, p.stderr[-200:] if p else "")
if turns:
    check("claude transcript: one user turn + ONE coalesced assistant turn",
          [t["role"] for t in turns] == ["user", "assistant"], [t["role"] for t in turns])
    a = turns[-1]
    check("claude transcript: both real tool calls survived the coalesce",
          [t.split("  ")[0] for t in a["tools"]] == ["Write", "Read"], a["tools"])
    check("claude transcript: blocks keep their real order",
          [b["t"] for b in a["blocks"]] == ["thinking", "tool", "thinking", "tool",
                                            "thinking", "text"], [b["t"] for b in a["blocks"]])
    check("claude transcript: the tool block carries the real path + tool_use id",
          a["blocks"][1].get("filePath") == "/home/pervio/work/note.txt"
          and str(a["blocks"][1].get("id", "")).startswith("toolu_"), a["blocks"][1])
    check("claude transcript: the model's real thinking is preserved",
          "note.txt" in (a.get("thinking") or ""), (a.get("thinking") or "")[:80])
    check("claude transcript: bookkeeping lines never become turns "
          "(attachment / queue-operation / ai-title / last-prompt)",
          len(turns) == 2 and all("<redacted" not in t["text"] for t in turns))

turns, p = transcript("claude-plan", "claude")
check("claude plan transcript decodes", turns is not None, p.stderr[-200:] if p else "")
if turns:
    plan = [b for t in turns for b in (t.get("blocks") or [])
            if b.get("name") == "ExitPlanMode"]
    check("claude transcript: an ExitPlanMode block is rebuilt on reload", bool(plan), plan)
    check("claude transcript: the plan chip is labelled exactly like the live stream",
          bool(plan) and plan[0]["v"] == "Plan ready · tap to review", plan[:1])

turns, p = transcript("claude-approval", "claude")
check("claude approval transcript decodes", turns is not None, p.stderr[-200:] if p else "")
if turns:
    check("claude transcript: a DENIED tool still shows as a chip on reload",
          any(b.get("name") == "Write" for t in turns for b in (t.get("blocks") or [])),
          [b.get("name") for t in turns for b in (t.get("blocks") or [])])

turns, p = transcript("codex-tools", "codex")
check("codex transcript decodes", turns is not None, p.stderr[-200:] if p else "")
if turns:
    check("codex transcript: the user prompt and the agent's replies survive",
          [t["role"] for t in turns][:1] == ["user"]
          and any(t["text"].strip() == "done" for t in turns), [t["role"] for t in turns])
    check("codex transcript: codex's injected <…> blocks are NOT turns",
          not any(t["text"].lstrip().startswith("<") for t in turns),
          [t["text"][:40] for t in turns])

turns, p = transcript("codex-text", "codex")
check("codex transcript (plain turn) decodes and keeps the reply", bool(turns)
      and any("corpus is alive" in t["text"] for t in turns), turns)

# A codex rollout is only readable through the cwd it was recorded in — the guard
# that stops a known thread id from being read out of any other project.
home = tempfile.mkdtemp(prefix="corpushome_", dir="/tmp")
try:
    d = os.path.join(home, ".codex", "sessions", "2026", "08", "07")
    os.makedirs(d)
    shutil.copy(session_path("codex-text"),
                os.path.join(d, "rollout-2026-08-07T00-00-00-%s.jsonl" % SID))
    q = subprocess.run([sys.executable, SESSIONS, "transcript", "--dir", "/home/pervio/elsewhere",
                        "--session", SID, "--backend", "codex"],
                       env=dict(os.environ, HOME=home), capture_output=True, text=True)
    check("codex transcript refuses a mismatched --dir", q.stdout.strip() == "[]", q.stdout[:80])
finally:
    shutil.rmtree(home, ignore_errors=True)


# --------------------------------------------------------------------------- #
# 5. drift sentinel — and proof that it actually bites
# --------------------------------------------------------------------------- #
print("=== drift sentinel: field sets, values free ===")

FROZEN = dict((sc.name, cap.shape_of_file(stream_path(sc.name))) for sc in cap.SCENARIOS)

check("a corpus compared with itself reports zero drift",
      all(not cap.shape_diff(FROZEN[n], FROZEN[n]) for n in FROZEN))


def mutate(objs):
    return [json.dumps(o) + "\n" for o in objs]


def _first(objs, key):
    for o in objs:
        if cap.event_key(o) == key:
            return o
    return None


# (a) VALUES may drift freely — that must NOT be reported.
objs = copy.deepcopy(objs_of(stream_path("claude-text")))
for o in objs:
    if o.get("type") == "result":
        o["result"] = "something completely different"
        o["total_cost_usd"] = 999.0
        (o.get("usage") or {})["output_tokens"] = 123456
check("changed VALUES are not drift",
      not cap.shape_diff(FROZEN["claude-text"], cap.shape(mutate(objs))))

# (b) a NEW field appears (the CLI grew one).
objs = copy.deepcopy(objs_of(stream_path("claude-text")))
_first(objs, "result/success")["brand_new_field_from_a_future_cli"] = 1
d = cap.shape_diff(FROZEN["claude-text"], cap.shape(mutate(objs)))
check("an ADDED field is caught and named",
      any("brand_new_field_from_a_future_cli" in x and "NEW" in x for x in d), d)

# (c) a field DISAPPEARS (the shape our parser depends on quietly went away).
objs = copy.deepcopy(objs_of(stream_path("claude-text")))
for o in objs:
    if o.get("type") == "result":
        o.pop("total_cost_usd", None)
d = cap.shape_diff(FROZEN["claude-text"], cap.shape(mutate(objs)))
check("a REMOVED field is caught and named",
      any("total_cost_usd" in x and "GONE" in x for x in d), d)

# (d) a nested field deep inside an array element.
objs = copy.deepcopy(objs_of(stream_path("claude-tools")))
for o in objs:
    if o.get("type") == "assistant":
        for b in (o["message"].get("content") or []):
            b.pop("id", None)
d = cap.shape_diff(FROZEN["claude-tools"], cap.shape(mutate(objs)))
check("a field GONE from inside an array element is caught",
      any("message.content[].id" in x and "GONE" in x for x in d), d)

# (e) a whole event type vanishes.
objs = [o for o in copy.deepcopy(objs_of(stream_path("codex-tools")))
        if cap.event_key(o) != "item.completed/file_change"]
d = cap.shape_diff(FROZEN["codex-tools"], cap.shape(mutate(objs)))
check("a VANISHED event type is caught",
      any("item.completed/file_change" in x and "GONE" in x for x in d), d)

# (f) item kinds must not be smeared into one bucket: dropping a field from
#     file_change must not be masked by command_execution still having it.
objs = copy.deepcopy(objs_of(stream_path("codex-tools")))
for o in objs:
    it = o.get("item") or {}
    if it.get("type") == "file_change":
        it.pop("changes", None)
d = cap.shape_diff(FROZEN["codex-tools"], cap.shape(mutate(objs)))
check("drift in ONE item kind isn't hidden by its siblings",
      any("item.completed/file_change" in x and "item.changes" in x for x in d), d)


# --------------------------------------------------------------------------- #
# 6. --refresh: the sentinel against a genuinely fresh capture (spends quota)
# --------------------------------------------------------------------------- #
ap = argparse.ArgumentParser(add_help=False)
ap.add_argument("--refresh", action="store_true")
args, _ = ap.parse_known_args()

if args.refresh:
    print("=== --refresh: re-capturing BOTH backends live (this spends real quota) ===")
    tmp = tempfile.mkdtemp(prefix="corpusfresh_", dir="/tmp")
    try:
        # Shell out to capture_corpus.py so ITS turn caps are the ones enforced.
        r = subprocess.run([sys.executable, os.path.join(HERE, "capture_corpus.py"),
                            "--out", tmp], text=True)
        check("fresh capture completed", r.returncode == 0)
        for sc in cap.SCENARIOS:
            fresh = os.path.join(tmp, sc.name + ".jsonl")
            if not os.path.isfile(fresh):
                check("%s: re-captured" % sc.name, False, "no file")
                continue
            d = cap.shape_diff(FROZEN[sc.name], cap.shape_of_file(fresh))
            check("%s: no field drift vs the frozen corpus" % sc.name, not d,
                  "\n     " + "\n     ".join(d))
        print("\nIf a drift check failed: read the diff, decide whether the parsers need to "
              "change, then re-freeze with `python3 server/tests/capture_corpus.py`.")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
else:
    print("=== --refresh not given: nothing was captured, nothing was spent ===")
    print("    (run `python3 server/tests/test_event_corpus.py --refresh` after upgrading "
          "claude or codex)")

ok = all(results)
print("\n=== event corpus: %s (%d/%d) ===" %
      ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
