#!/usr/bin/env python3
"""Tests for server/bin/pervio-codex-index — the ONLY code in Pervio that rewrites
a Codex rollout in place. A rollout is the sole copy of a conversation; a botched
rewrite is unrecoverable, so this suite pins the three promises the script makes:

  1. BYTE PRESERVATION — only the first line (session_meta) changes; every byte
     after the first newline round-trips exactly (raw non-UTF-8 payload bytes and
     CRLF line endings included), and the file's permission bits survive.
  2. NEVER RAISES / NEVER ABORTS THE SWEEP — a malformed first line (null, [],
     a bare number/string, empty, non-JSON) is skipped quietly; one bad rollout
     must not stop the other rollouts in the tree from being made visible.
  3. NO DAMAGE ON FAILURE — a read-only directory or a full disk (injected with
     RLIMIT_FSIZE) leaves the original intact and no .rollout.*.tmp residue.

Plus: idempotence (a second sync is a no-op, byte-identical), and an already
`source == "cli"` rollout is left alone.

Hermetic: every case runs against a throwaway $HOME under /tmp. The real
~/.codex is never read or written.
"""
import json
import os
import resource
import shutil
import signal
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
IDX = os.path.realpath(os.path.join(HERE, "..", "bin", "pervio-codex-index"))

results = []
_homes = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name
          + (("  [" + str(detail)[:220] + "]") if (detail and not cond) else ""))


def mkhome():
    h = tempfile.mkdtemp(prefix="cxidx_", dir="/tmp")
    _homes.append(h)
    return h


def sessdir(home, *parts):
    d = os.path.join(home, ".codex", "sessions", *(parts or ("2026", "01", "02")))
    os.makedirs(d, exist_ok=True)
    return d


def meta(source="exec", **extra):
    p = {"id": "0199-abc", "timestamp": "2026-01-02T03:04:05Z", "source": source,
         "originator": "codex_exec" if source == "exec" else "codex-tui",
         "cwd": "/proj/app"}
    p.update(extra)
    return {"type": "session_meta", "payload": p}


def roll(home, name, head, tail=b"", parts=None):
    """Write a rollout with an exact byte layout. `head` is the first line
    (newline included by the caller), `tail` every byte after it."""
    d = sessdir(home, *(parts or ()))
    fp = os.path.join(d, name)
    with open(fp, "wb") as f:
        f.write(head if isinstance(head, bytes) else head.encode("utf-8"))
        f.write(tail if isinstance(tail, bytes) else tail.encode("utf-8"))
    return fp


def rb(fp):
    with open(fp, "rb") as f:
        return f.read()


def sync(home, preexec=None):
    return subprocess.run([sys.executable, IDX, "sync"],
                          env=dict(os.environ, HOME=home),
                          stdin=subprocess.DEVNULL, capture_output=True, text=True,
                          preexec_fn=preexec)


def made(p):
    try:
        return json.loads(p.stdout).get("madeVisible")
    except ValueError:
        return None


def residue(d):
    return [n for n in os.listdir(d) if n.startswith(".rollout.") or n.endswith(".tmp")]


# ---------- a: happy path — the flip itself ----------
print("=== a: exec -> cli flip ===")
home = mkhome()
TAIL = (b'{"type":"response_item","payload":{"role":"user","text":"hi"}}\n'
        b'{"type":"response_item","payload":{"role":"assistant","text":"yo"}}\n')
fa = roll(home, "rollout-a.jsonl", json.dumps(meta()) + "\n", TAIL)
p = sync(home)
check("a exit 0", p.returncode == 0, (p.returncode, p.stderr[:200]))
check("a reports one rollout made visible", made(p) == 1, p.stdout)
first, _, rest = rb(fa).partition(b"\n")
o = json.loads(first.decode("utf-8"))
check("a source flipped to cli", o["payload"]["source"] == "cli", o)
check("a originator flipped to codex-tui", o["payload"]["originator"] == "codex-tui", o)
check("a unrelated session_meta fields survive",
      o["payload"]["id"] == "0199-abc" and o["payload"]["cwd"] == "/proj/app", o)
check("a conversation lines are byte-identical", rest == TAIL, rest[:120])

# ---------- b: byte preservation of the conversation tail ----------
print("=== b: every byte after the first line round-trips ===")
home = mkhome()
# A tool result can carry raw bytes that are not valid UTF-8 (0xe9 here). Reading
# the file with errors='replace' silently rewrites them as U+FFFD — the original
# bytes are then gone for good.
RAW = b'{"type":"response_item","raw":"caf\xe9 \x80\xff"}\n{"type":"x"}\n'
fb = roll(home, "rollout-b.jsonl", json.dumps(meta()) + "\n", RAW)
p = sync(home)
check("b non-UTF-8 conversation bytes survive the rewrite",
      rb(fb).partition(b"\n")[2] == RAW, rb(fb).partition(b"\n")[2][:80])

home = mkhome()
CRLF = b'{"type":"response_item","t":"one"}\r\n{"type":"response_item","t":"two"}\r\n'
fc = roll(home, "rollout-c.jsonl", json.dumps(meta()) + "\r\n", CRLF)
p = sync(home)
tail_c = rb(fc).split(b"\n", 1)[1]
check("b CRLF line endings survive the rewrite", tail_c == CRLF, tail_c[:80])

home = mkhome()
fd_ = roll(home, "rollout-d.jsonl", json.dumps(meta()) + "\n", TAIL)
os.chmod(fd_, 0o644)
p = sync(home)
check("b permission bits are preserved (0644 stays 0644)",
      (os.stat(fd_).st_mode & 0o777) == 0o644, oct(os.stat(fd_).st_mode & 0o777))

# ---------- c: malformed first lines are skipped, never raise ----------
print("=== c: malformed / empty / non-JSON first line ===")
CASES = [
    ("null", b'null\n{"type":"response_item"}\n'),
    ("json array", b'[]\n{"type":"response_item"}\n'),
    ("bare number", b'123\n{"type":"response_item"}\n'),
    ("bare string", b'"session"\n{"type":"response_item"}\n'),
    ("empty file", b""),
    ("non-JSON garbage", b"not json at all\n{\"type\":\"x\"}\n"),
    ("truncated json", b'{"type": "session_\n'),
    ("wrong type", b'{"type":"other","payload":{"source":"exec"}}\n'),
    ("payload not a dict", b'{"type":"session_meta","payload":[1,2]}\n'),
    ("payload missing", b'{"type":"session_meta"}\n'),
]
for label, blob in CASES:
    home = mkhome()
    fp = roll(home, "rollout-bad.jsonl", blob)
    p = sync(home)
    ok = (p.returncode == 0 and p.stderr == "" and made(p) == 0 and rb(fp) == blob)
    check("c %s: skipped quietly, file untouched" % label, ok,
          (p.returncode, p.stderr[:160], p.stdout[:60], rb(fp)[:40]))

# ---------- d: one bad rollout must not abort the whole sweep ----------
print("=== d: sweep survives a malformed rollout ===")
home = mkhome()
bad = roll(home, "rollout-0-bad.jsonl", b'null\n{"type":"x"}\n')
good = [roll(home, "rollout-%d-good.jsonl" % i, json.dumps(meta()) + "\n", TAIL)
        for i in range(1, 4)]
p = sync(home)
flipped = [json.loads(rb(g).partition(b"\n")[0])["payload"]["source"] for g in good]
check("d every valid exec rollout after the bad one is still made visible",
      made(p) == 3 and flipped == ["cli"] * 3, (p.stdout, p.stderr[:160], flipped))
check("d the malformed rollout is left untouched", rb(bad) == b'null\n{"type":"x"}\n')

# ---------- e: idempotence ----------
print("=== e: idempotence ===")
home = mkhome()
fe = roll(home, "rollout-e.jsonl", json.dumps(meta()) + "\n", TAIL)
p1 = sync(home)
after1 = rb(fe)
p2 = sync(home)
after2 = rb(fe)
check("e first sync flips it", made(p1) == 1, p1.stdout)
check("e second sync is a no-op", made(p2) == 0, p2.stdout)
check("e file is byte-identical after the second sync", after1 == after2)
home = mkhome()
fcli = roll(home, "rollout-cli.jsonl", json.dumps(meta("cli")) + "\n", TAIL)
before = rb(fcli)
p = sync(home)
check("e an already-cli rollout is never rewritten",
      made(p) == 0 and rb(fcli) == before, p.stdout)

# ---------- f: failure paths leave nothing behind ----------
print("=== f: read-only directory ===")
home = mkhome()
ff = roll(home, "rollout-f.jsonl", json.dumps(meta()) + "\n", TAIL)
d = os.path.dirname(ff)
before = rb(ff)
os.chmod(d, 0o555)
try:
    p = sync(home)
    check("f read-only dir: exits 0 and reports nothing made visible",
          p.returncode == 0 and made(p) == 0, (p.returncode, p.stdout, p.stderr[:160]))
    check("f read-only dir: the rollout is byte-identical", rb(ff) == before)
    check("f read-only dir: no .tmp residue", residue(d) == [], residue(d))
finally:
    os.chmod(d, 0o755)

print("=== f: disk full (RLIMIT_FSIZE) ===")
home = mkhome()
BIG = TAIL * 4000                                   # ~250 KB of conversation
fg = roll(home, "rollout-g.jsonl", json.dumps(meta()) + "\n", BIG)
d = os.path.dirname(fg)
before = rb(fg)


def _cap():                                          # child-side: ENOSPC-alike
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)    # EFBIG instead of death
    resource.setrlimit(resource.RLIMIT_FSIZE, (65536, 65536))


p = sync(home, preexec=_cap)
check("f disk full: still exits 0, reports nothing made visible",
      p.returncode == 0 and made(p) == 0, (p.returncode, p.stdout, p.stderr[:160]))
check("f disk full: the original rollout is byte-identical", rb(fg) == before,
      len(rb(fg)))
check("f disk full: no half-written .tmp left behind", residue(d) == [], residue(d))

# ---------- g: usage ----------
print("=== g: cli surface ===")
p = subprocess.run([sys.executable, IDX, "bogus"], env=dict(os.environ, HOME=mkhome()),
                   stdin=subprocess.DEVNULL, capture_output=True, text=True)
check("g an unknown verb exits 2 with usage", p.returncode == 2 and "usage" in p.stderr,
      (p.returncode, p.stderr[:120]))

for h in _homes:
    shutil.rmtree(h, ignore_errors=True)
ok = all(results)
print("\n=== pervio-codex-index: %s (%d/%d) ==="
      % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
