#!/usr/bin/env python3
"""Shard-mode + dedup + retry-hardening tests for pervio-arxiv-fetch (paper-digest v2).

The v2 workflow fans the fetch output out to one first-pass judge per shard.
The orchestrator's numbered split anchors on ^\\s*\\d+[.)] and DROPS everything
before the first numbered line, so the load-bearing contract is: shard headers
are the ONLY lines matching that anchor, every header carries REPORT_DATE, and
P numbers stay globally sequential. The fixtures deliberately plant an abstract
opening with "2.5 times faster" and a title opening with "3D Gaussian" to prove
body lines can't collide with the anchor. Also pinned: the no-flag output keeps
the v1 byte format (and --shard-size 0 == no flag), the all-seen day emits
exactly one "1) NO_NEW_PAPERS" item, and fetch_xml survives four straight 429s
by honoring an integer Retry-After (needs all 5 attempts — 3 would die).

Sections e/f pin the OTHER half of the dedup contract: what save_seen writes back.
test_schedule.py S12/S13 already drive the round trip (a second run says NO_NEW)
and the two-phase --pending staging, but a save_seen that threw the history away
and wrote only today's ids passes a round trip just as well — and then quietly
forgets every paper older than today, so the digest starts re-recommending them.
So e asserts the seen file BYTE-FOR-BYTE across two days (part-new/part-old day,
history order preserved, one line appended per new paper) and f asserts the
2000-id cap trims the OLDEST end, not the newest (a trim from the wrong end
freezes the file forever and every day becomes a re-run of the same papers).

Sections g/h/i pin the PAGING contract. arXiv answers at most one page per
request, and cs.CL alone runs 65-86 submissions a day, so a 3-day window is
routinely >200 papers: the old single-request fetch silently returned the
newest 200 and printed "last 3d" over a window it had only covered ~2.7 days
of. g proves the fetch now pages until the window is COVERED (not until some
count is reached), h proves every guardrail that can stop it early says so in
the header instead of cutting silently, and i pins the split of --max into
"fetch everything, emit at most cap" plus the expiry-first cut that makes the
held-back papers provably come back on the next run.

Hermetic: --feed fixtures + PERVIO_NOW; the retry and paging tests serve HTTP
from a localhost thread, no real network; every --seen path is under a
throwaway /tmp dir, so the real ~/.pervio is never read or written."""
import http.server
import importlib.machinery
import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.realpath(__file__))
BIN = os.path.realpath(os.path.join(HERE, "..", "bin"))
ARX = os.path.join(BIN, "pervio-arxiv-fetch")
ORCH = os.path.join(BIN, "pervio-orchestrate")

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name
          + (("  [" + str(detail)[:220] + "]") if (detail and not cond) else ""))


def load_module(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader(name, loader))
    loader.exec_module(mod)
    return mod


ENTRY = ("<entry><id>http://arxiv.org/abs/%sv1</id><title>%s</title>"
         "<summary>%s</summary><published>%s</published>"
         "<author><name>A One</name></author><author><name>B Two</name></author>"
         "<author><name>C Three</name></author><author><name>D Four</name></author>"
         "<arxiv:primary_category xmlns:arxiv=\"http://arxiv.org/schemas/atom\" term=\"cs.CL\"/>"
         "</entry>")
# Descending published times pin the output order to fixture order. Paper 1's
# abstract and paper 7's title are the anchor-collision traps.
PAPERS = [
    ("2607.10001", "Paper One Title", "2.5 times faster than the baseline on long-context eval."),
    ("2607.10002", "Paper Two Title", "abs two"),
    ("2607.10003", "Paper Three Title", "abs three"),
    ("2607.10004", "Paper Four Title", "abs four"),
    ("2607.10005", "Paper Five Title", "abs five"),
    ("2607.10006", "Paper Six Title", "abs six"),
    ("2607.10007", "3D Gaussian Splatting Speedup", "abs seven"),
]
FEED_XML = ('<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">'
            + "".join(ENTRY % (pid, title, abst, "2026-07-07T10:%02d:00Z" % (10 - i))
                      for i, (pid, title, abst) in enumerate(PAPERS))
            + "</feed>")

home = tempfile.mkdtemp(prefix="arxshard_", dir="/tmp")
feed = os.path.join(home, "feed.xml")
open(feed, "w").write(FEED_XML)
E = dict(os.environ, PERVIO_NOW="2026-07-08T12:00:00+00:00")


def fetch(*args, **kw):
    return subprocess.run([sys.executable, ARX, "--feed", kw.get("feed", feed),
                           "--days", "3"] + list(args), env=kw.get("env", E),
                          capture_output=True, text=True)


# The orchestrator's split anchor, verbatim (pervio-orchestrate _fanout_split).
ANCHOR = re.compile(r"^\s*\d+[.)]")

# ---------- a: 7 papers, --shard-size 3 → 3 shards, headers are the only anchors ----------
print("=== a: shard format + split invariant ===")
p = fetch("--max", "10", "--shard-size", "3")
out = p.stdout
lines = out.splitlines()
hits = [l for l in lines if ANCHOR.match(l)]
check("a exit 0", p.returncode == 0, p.stderr[:200])
check("a traps really are in the output (fixture not rotted)",
      "摘要: 2.5 times faster" in out and "- P7 · 3D Gaussian" in out, out[:400])
check("a exactly 3 lines match the split anchor, all shard headers",
      len(hits) == 3 and all("分片" in h for h in hits), hits)
check("a headers verbatim: K) 分片 K/T · 论文 range · REPORT_DATE",
      hits == ["1) 分片 1/3 · 论文 1-3 · REPORT_DATE: 2026-07-08",
               "2) 分片 2/3 · 论文 4-6 · REPORT_DATE: 2026-07-08",
               "3) 分片 3/3 · 论文 7-7 · REPORT_DATE: 2026-07-08"], hits)
check("a no NON-header line matches ^\\s*\\d+[.)]",
      not [l for l in lines if ANCHOR.match(l) and "分片" not in l],
      [l for l in lines if ANCHOR.match(l) and "分片" not in l])
check("a P numbers globally sequential across shards",
      re.findall(r"(?m)^- P(\d+) · ", out) == [str(n) for n in range(1, 8)],
      re.findall(r"(?m)^- P(\d+) · ", out))

# Run the REAL orchestrator split over the output — the contract's consumer.
om = load_module("orch_for_shard", ORCH)
items = om._fanout_split("numbered", out)
check("a real _fanout_split yields exactly 3 items",
      len(items) == 3, [it[:60] for it in items])
check("a every item keeps its shard tag + REPORT_DATE (preamble drop survived)",
      all(items[k].startswith("分片 %d/3" % (k + 1)) for k in range(3))
      and all("REPORT_DATE: 2026-07-08" in it for it in items),
      [it[:60] for it in items])
check("a papers landed intact in their shard",
      "摘要: 2.5 times faster" in items[0] and "- P7 · 3D Gaussian" in items[2],
      [it[:60] for it in items])

# ---------- b: all seen + shard mode → exactly one "1) NO_NEW_PAPERS" item ----------
print("=== b: NO_NEW in shard mode ===")
seen = os.path.join(home, "seen.txt")
open(seen, "w").write("".join(pid + "\n" for pid, _, _ in PAPERS))
p = fetch("--max", "10", "--shard-size", "3", "--seen", seen)
check("b NO_NEW day still exits 0 and keeps the human header",
      p.returncode == 0 and "NO_NEW_PAPERS (nothing new" in p.stdout, p.stdout[:200])
check("b output contains '1) NO_NEW_PAPERS' exactly once",
      p.stdout.count("1) NO_NEW_PAPERS") == 1, p.stdout)
check("b real _fanout_split yields exactly one NO_NEW_PAPERS item",
      om._fanout_split("numbered", p.stdout) == ["NO_NEW_PAPERS"],
      om._fanout_split("numbered", p.stdout))

# ---------- c: no flag → v1 byte format; --shard-size 0 == no flag ----------
print("=== c: default-mode regression ===")
p = fetch("--max", "10")
check("c v1 numbered entry format intact (block byte-exact)",
      "1. Paper One Title\n"
      "   arXiv:2607.10001 [cs.CL] · 2026-07-07 · A One, B Two, C Three et al.\n"
      "   https://arxiv.org/abs/2607.10001\n"
      "   2.5 times faster than the baseline on long-context eval.\n" in p.stdout,
      p.stdout[:400])
check("c v1 has all 7 numbered lines and zero shard artifacts",
      len(re.findall(r"(?m)^\d+\. ", p.stdout)) == 7
      and "分片" not in p.stdout and "摘要:" not in p.stdout, p.stdout[:300])
p0 = fetch("--max", "10", "--shard-size", "0")
check("c --shard-size 0 output is byte-identical to no flag",
      p0.stdout == p.stdout and p0.returncode == p.returncode)
pbad = fetch("--max", "10", "--shard-size", "-1")
pbad2 = fetch("--max", "10", "--shard-size", "x")
check("c --shard-size rejects negative and non-integer via die()",
      pbad.returncode != 0 and "--shard-size" in pbad.stderr
      and pbad2.returncode != 0 and "--shard-size" in pbad2.stderr,
      pbad.stderr[:120] + pbad2.stderr[:120])

# ---------- d: retry — four 429s (Retry-After: 1), then 200 with the feed ----------
# Four 429s force ALL five attempts: revert the retry count to 3 and this dies.
# The <15s bound proves the integer Retry-After (4x1s) was honored — falling
# back to exponential backoff would sleep 4+8+16+32 = 60s before succeeding.
print("=== d: 429 retry with Retry-After ===")


class Handler(http.server.BaseHTTPRequestHandler):
    calls = []

    def do_GET(self):
        Handler.calls.append(self.path)
        if len(Handler.calls) <= 4:
            self.send_response(429)
            self.send_header("Retry-After", "1")
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            body = FEED_XML.encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
arx = load_module("arx_for_shard", ARX)
arx.API = "http://127.0.0.1:%d/api" % srv.server_address[1]   # module const = the override point
t0 = time.monotonic()
try:
    data = arx.fetch_xml(["cs.CL"], 10, "", "")
except SystemExit:
    data = b""
elapsed = time.monotonic() - t0
srv.shutdown()
check("d fetch survives four 429s and returns the feed on attempt 5",
      b"2607.10001" in data and len(Handler.calls) == 5,
      "calls=%d len=%d" % (len(Handler.calls), len(data)))
check("d honored integer Retry-After: total >=2s (slept) and <15s (not exp backoff)",
      2.0 <= elapsed < 15.0, "%.1fs" % elapsed)
check("d the fetched feed parses into all 7 entries",
      len(arx.parse_entries(data)) == 7 if data else False)

# ---------- e: the seen file's write-back, byte-for-byte, over two days ----------
# The seen file IS the dedup memory: lose a line and that paper comes back as
# "new" tomorrow. So this pins the file itself, not just "the second run said
# NO_NEW" — the latter survives a save_seen that clobbers the history.
print("=== e: seen write-back on a mixed day ===")
ded = os.path.join(home, "dedup")
os.makedirs(ded)
seen_e = os.path.join(ded, "seen.txt")
# Papers 2/4/6 were recommended on earlier days; 2601.99999 is an older id from a
# day whose papers have long since dropped out of the feed window and which MUST
# still survive the rewrite. The padded and blank lines are the real shape of a
# file the template's commit step has been appending to with `cat >>`.
open(seen_e, "w").write("2601.99999\n  2607.10002  \n\n2607.10004\n2607.10006\n")
p = fetch("--max", "10", "--seen", seen_e)
check("e mixed day: exit 0 and the header counts 4 new / 3 already recommended",
      p.returncode == 0 and "NEW PAPERS (cs.CL,cs.AI,cs.LG · last 3d · "
      "4 new, 3 already recommended earlier)" in p.stdout, p.stdout[:200] + p.stderr[:120])
printed = re.findall(r"(?m)^   arXiv:(\S+) ", p.stdout)
check("e exactly the 4 unseen papers are printed, newest first",
      printed == ["2607.10001", "2607.10003", "2607.10005", "2607.10007"], printed)
day1 = ("2601.99999\n2607.10002\n2607.10004\n2607.10006\n"
        "2607.10001\n2607.10003\n2607.10005\n2607.10007\n")
check("e write-back: history kept in its old order, today's 4 appended, "
      "padding/blank lines normalized away",
      open(seen_e).read() == day1, repr(open(seen_e).read()[:200]))
check("e no .tmp turd beside the seen file (os.replace finished)",
      sorted(os.listdir(ded)) == ["seen.txt"], os.listdir(ded))

# Day 2: the same feed plus one genuinely new paper. Yesterday's file must be a
# PREFIX of today's — one line longer, nothing rewritten, nothing dropped.
feed2 = os.path.join(ded, "feed2.xml")
open(feed2, "w").write(FEED_XML.replace(
    "</feed>", ENTRY % ("2607.10008", "Paper Eight Title", "abs eight",
                        "2026-07-07T10:20:00Z") + "</feed>"))
p = fetch("--max", "10", "--seen", seen_e, feed=feed2)
check("e day 2: only the genuinely new paper is printed (1 new, 7 already)",
      p.returncode == 0 and "1 new, 7 already recommended earlier" in p.stdout
      and re.findall(r"(?m)^   arXiv:(\S+) ", p.stdout) == ["2607.10008"], p.stdout[:220])
check("e day 2 appends exactly one line and keeps day 1 as a prefix",
      open(seen_e).read() == day1 + "2607.10008\n", repr(open(seen_e).read()[:240]))

# A fresh install has no ~/.pervio/papers yet: the fetcher creates it, and 0700
# because what you read is nobody else's business on a shared box. The umask has
# to be pinned permissive first — section a's load_module(ORCH) executed
# pervio-orchestrate's top-level os.umask(0o077), which is inherited by every
# child from here on and would mask the dir down to 0700 no matter what save_seen
# asked for: the assertion would pass with `mode=0o700` deleted from the source.
nest = os.path.join(ded, "fresh-install", "papers", "seen.txt")
prev_umask = os.umask(0o022)
try:
    p = fetch("--max", "10", "--seen", nest)
finally:
    os.umask(prev_umask)
check("e a missing --seen parent is created 0700, with the file inside it",
      p.returncode == 0 and os.path.isfile(nest)
      and (os.stat(os.path.dirname(nest)).st_mode & 0o777) == 0o700,
      oct(os.stat(os.path.dirname(nest)).st_mode & 0o777)
      if os.path.isdir(os.path.dirname(nest)) else "no dir")

# ---------- f: the 2000-id cap trims the OLDEST end ----------
# The cap keeps the file from growing forever. Trimming the wrong end would be
# invisible for exactly one day and then permanent: the file freezes at 2000 old
# ids, today's papers are never recorded, and every morning re-recommends them.
print("=== f: seen file cap ===")
capdir = os.path.join(home, "cap")
os.makedirs(capdir)
seen_f = os.path.join(capdir, "seen.txt")
open(seen_f, "w").write("".join("old%04d\n" % n for n in range(2000)))
p = fetch("--max", "10", "--seen", seen_f)
kept = open(seen_f).read().splitlines()
check("f exit 0 and still exactly 2000 ids after 7 more were recommended",
      p.returncode == 0 and len(kept) == 2000, len(kept))
check("f the 7 OLDEST ids fell off the front",
      kept[0] == "old0007" and "old0006" not in kept, kept[:2])
check("f today's 7 are the tail, in output order (newest end survives)",
      kept[-7:] == [pid for pid, _, _ in PAPERS], kept[-7:])

# ---------- g: paging — the fetch covers the WINDOW, not the first page ----------
# The bug this pins: one request returns at most one page, so a 3-day cs.CL
# window (~221 papers) came back as its newest 200 while the header still said
# "last 3d". The fixture is deliberately built so the window boundary falls in
# the SECOND page: 250 papers 20 minutes apart, 214 of them inside a 3d window.
print("=== g: paging covers the window ===")

FEED_HEAD = ('<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom" '
             'xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/">')


def mk_feed(entries, total=None):
    tot = ("<opensearch:totalResults>%d</opensearch:totalResults>" % total) if total else ""
    return FEED_HEAD + tot + "".join(entries) + "</feed>"


import datetime as _dt
BASE = _dt.datetime(2026, 7, 8, 11, 0, 0)
# 250 papers, newest first, 20 min apart => the oldest is 2026-07-04T22:00Z.
# PERVIO_NOW is 2026-07-08T12:00Z and --days 3 => cutoff 2026-07-05T12:00Z, so
# papers 0..213 are inside the window and 214..249 are not.
BIG = [ENTRY % ("2607.2%04d" % i, "Big Paper %d" % i, "abs %d" % i,
                (BASE - _dt.timedelta(minutes=20 * i)).strftime("%Y-%m-%dT%H:%M:%SZ"))
       for i in range(250)]
IN_WINDOW = 214
pagedir = os.path.join(home, "pages")
os.makedirs(pagedir)
pg0 = os.path.join(pagedir, "p0.xml")
pg1 = os.path.join(pagedir, "p1.xml")
open(pg0, "w").write(mk_feed(BIG[:200], total=250))
open(pg1, "w").write(mk_feed(BIG[200:], total=250))

p = fetch("--max", "300", feed=pg0 + "," + pg1)
ids = re.findall(r"(?m)^   arXiv:(\S+) ", p.stdout)
check("g every in-window paper across BOTH pages is returned (214, not 200)",
      p.returncode == 0 and len(ids) == IN_WINDOW, "%d ids, rc=%d %s"
      % (len(ids), p.returncode, p.stderr[:150]))
check("g the page-2 tail is present and the out-of-window paper right after it is not",
      "2607.20213" in ids and "2607.20214" not in ids,
      ids[-3:] if ids else "none")
check("g header counts the full window, and says 3d without a truncation note",
      "· last 3d · %d new, 0 already recommended earlier)" % IN_WINDOW in p.stdout
      and "TRUNCATED" not in p.stdout, p.stdout.splitlines()[1:3])
# Sanity: with only page 1 on disk the old single-page behaviour reappears, so a
# green assertion above really is paging and not a fixture that fits in one page.
p1only = fetch("--max", "300", feed=pg0)
check("g control: a single page alone yields only 200 (fixture really spans pages)",
      len(re.findall(r"(?m)^   arXiv:(\S+) ", p1only.stdout)) == 200,
      len(re.findall(r"(?m)^   arXiv:(\S+) ", p1only.stdout)))

# The real loop against a server that honours start/max_results: proves the URL
# carries a growing &start= and that we stop once the window is behind us.
arx2 = load_module("arx_for_paging", ARX)


class PageHandler(http.server.BaseHTTPRequestHandler):
    urls = []

    def do_GET(self):
        import urllib.parse as up
        PageHandler.urls.append(self.path)
        qs = up.parse_qs(up.urlparse(self.path).query)
        st = int(qs.get("start", ["0"])[0])
        mx = int(qs.get("max_results", ["100"])[0])
        body = mk_feed(BIG[st:st + mx], total=len(BIG)).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


psrv = http.server.HTTPServer(("127.0.0.1", 0), PageHandler)
threading.Thread(target=psrv.serve_forever, daemon=True).start()
arx2.API = "http://127.0.0.1:%d/api" % psrv.server_address[1]
check("g PAGE_DELAY defaults to arXiv's >=3s politeness gap",
      getattr(arx2, "PAGE_DELAY", 0) >= 3.0, getattr(arx2, "PAGE_DELAY", None))
arx2.PAGE_DELAY = 0.05                     # keep the suite fast; the gap itself is checked above
cut = _dt.datetime(2026, 7, 5, 12, 0, tzinfo=_dt.timezone.utc)
got, trunc = arx2.fetch_window(["cs.CL"], cut, "", "")
psrv.shutdown()
check("g the network loop pages until the cutoff is passed, then stops",
      len(got) == 250 and trunc == "", "%d entries trunc=%r" % (len(got), trunc))
starts = [re.search(r"start=(\d+)", u).group(1) for u in PageHandler.urls
          if re.search(r"start=(\d+)", u)]
check("g exactly two requests, at start=0 then start=200 (page size 200)",
      starts == ["0", "200"], PageHandler.urls)

# ---------- h: guardrails are announced, never silent ----------
print("=== h: guardrails announce themselves ===")
gd = os.path.join(home, "guard")
os.makedirs(gd)
# MAX_PAGES: 26 one-entry pages, all inside the window, so only the page cap can
# stop the sweep. Driven through the CLI so the HEADER wording is pinned too.
onepage = []
for i in range(26):
    fp = os.path.join(gd, "g%02d.xml" % i)
    open(fp, "w").write(mk_feed([ENTRY % ("2607.3%04d" % i, "Guard %d" % i, "abs",
                                          "2026-07-07T10:00:00Z")]))
    onepage.append(fp)
p = fetch("--max", "300", feed=",".join(onepage))
check("h page guardrail: exit 0 but the header says TRUNCATED",
      p.returncode == 0 and "TRUNCATED" in p.stdout, p.stdout[:300] + p.stderr[:150])
check("h the truncation note names the page guardrail",
      re.search(r"TRUNCATED: [^)\n]*page", p.stdout) is not None,
      [l for l in p.stdout.splitlines() if "TRUNCATED" in l])
check("h a truncated sweep still prints the papers it did get",
      len(re.findall(r"(?m)^   arXiv:(\S+) ", p.stdout)) == 25,
      len(re.findall(r"(?m)^   arXiv:(\S+) ", p.stdout)))
# A truncated fetch where everything happens to be seen must NOT read as a quiet
# day: NO_NEW_PAPERS has to carry the note too, or the reader is misled.
seen_h = os.path.join(gd, "seen.txt")
open(seen_h, "w").write("".join("2607.3%04d\n" % i for i in range(26)))
p = fetch("--max", "300", "--seen", seen_h, feed=",".join(onepage))
check("h NO_NEW_PAPERS on a truncated sweep still carries the note",
      "NO_NEW_PAPERS (nothing new" in p.stdout and "TRUNCATED" in p.stdout,
      p.stdout[:300])

arx3 = load_module("arx_for_guards", ARX)
gp = [os.path.join(gd, "e%d.xml" % k) for k in range(3)]
for k, fp in enumerate(gp):
    open(fp, "w").write(mk_feed([ENTRY % ("2607.4%03d" % (k * 10 + j), "E", "abs",
                                          "2026-07-07T10:00:00Z") for j in range(3)]))
arx3.MAX_ENTRIES = 3
got, trunc = arx3.fetch_window(["cs.CL"], cut, ",".join(gp), "")
check("h entry guardrail trips and reports the entry cap",
      len(got) == 3 and "entr" in trunc, "%d %r" % (len(got), trunc))
arx3.MAX_ENTRIES = 5000
# Deadline already blown before the call. Every page this server serves is fully
# inside the window, so nothing BUT the clock can stop the sweep: page 1 must
# still be attempted (some data beats none), page 2 must not, and the reason
# must name the time budget. Without a deadline this request loop would run all
# 25 pages, which is exactly the runaway the budget exists to prevent.
class EndlessHandler(http.server.BaseHTTPRequestHandler):
    hits = []

    def do_GET(self):
        EndlessHandler.hits.append(self.path)
        # A FULL page, all in-window, with a totalResults far beyond it: neither
        # the short-page nor the totalResults exit can fire, so only the clock
        # is left. A one-entry reply would have been a legitimate end-of-results.
        n = len(EndlessHandler.hits)
        body = mk_feed([ENTRY % ("2607.8%03d" % (n * 300 + j), "Endless", "abs",
                                 "2026-07-07T10:00:00Z")
                        for j in range(arx3.PAGE)], total=99999).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


esrv = http.server.HTTPServer(("127.0.0.1", 0), EndlessHandler)
threading.Thread(target=esrv.serve_forever, daemon=True).start()
arx3.API = "http://127.0.0.1:%d/api" % esrv.server_address[1]
got, trunc = arx3.fetch_window(["cs.CL"], cut, "", "",
                               started=time.monotonic() - arx3.DEADLINE_S - 1)
esrv.shutdown()
check("h a blown deadline stops the sweep after ONE page, not 25",
      len(EndlessHandler.hits) == 1 and len(got) == arx3.PAGE, "%d requests, %d entries"
      % (len(EndlessHandler.hits), len(got)))
check("h the truncation note names the time budget",
      "time budget" in trunc, repr(trunc))
check("h DEADLINE_S leaves room for one in-flight request inside the 480s budget",
      arx3.DEADLINE_S + 30 <= 480, arx3.DEADLINE_S)

# ---------- i: --max is an EMIT bound, and its cut is expiry-first ----------
print("=== i: --max no longer limits the fetch, and cuts the right end ===")
capd = os.path.join(home, "capsem")
os.makedirs(capd)
# i-1: a tiny --max must not shrink the sweep. All 214 in-window papers are
# already seen, so the "already recommended earlier" count is a direct readout
# of how many entries the fetch actually looked at.
seen_i = os.path.join(capd, "seen-all.txt")
open(seen_i, "w").write("".join("2607.2%04d\n" % i for i in range(IN_WINDOW)))
p = fetch("--max", "4", "--seen", seen_i, feed=pg0 + "," + pg1)
check("i --max 4 still sweeps the whole window (214 already recommended, not 16)",
      "%d already recommended earlier" % IN_WINDOW in p.stdout, p.stdout[:250])

# i-2: when the cap bites, it must keep the OLDEST cap papers — those are the
# ones about to fall out of the window. Ten papers, 40 min apart, cap 4.
ten = [ENTRY % ("2607.5%03d" % i, "Ten %d" % i, "abs %d" % i,
                (BASE - _dt.timedelta(minutes=40 * i)).strftime("%Y-%m-%dT%H:%M:%SZ"))
       for i in range(10)]
f10 = os.path.join(capd, "ten.xml")
open(f10, "w").write(mk_feed(ten))
seen_j = os.path.join(capd, "seen.txt")
p = fetch("--max", "4", "--seen", seen_j, feed=f10)
d1 = re.findall(r"(?m)^   arXiv:(\S+) ", p.stdout)
check("i the cap keeps the 4 OLDEST papers, still printed newest-first",
      d1 == ["2607.5006", "2607.5007", "2607.5008", "2607.5009"], d1)
check("i the header says how many were held back and why",
      re.search(r"6 held for the next run \(--max 4\)", p.stdout) is not None,
      [l for l in p.stdout.splitlines() if "NEW PAPERS" in l])
check("i only the emitted papers go into the seen ledger (held-back stay unseen)",
      open(seen_j).read().splitlines() == d1, open(seen_j).read().splitlines())

# i-3: the whole point — the held-back six come back on the next run, oldest
# first. Same feed, same seen file: nothing evaporated.
p = fetch("--max", "4", "--seen", seen_j, feed=f10)
d2 = re.findall(r"(?m)^   arXiv:(\S+) ", p.stdout)
check("i next run resurfaces the held-back papers, oldest of them first",
      d2 == ["2607.5002", "2607.5003", "2607.5004", "2607.5005"], d2)
p = fetch("--max", "4", "--seen", seen_j, feed=f10)
d3 = re.findall(r"(?m)^   arXiv:(\S+) ", p.stdout)
check("i third run drains the rest — all 10 shown, none lost",
      sorted(d1 + d2 + d3) == sorted("2607.5%03d" % i for i in range(10)),
      sorted(d1 + d2 + d3))

# i-4: if the cap is smaller than the daily arrival rate the backlog CANNOT be
# drained and some held-back papers really will age out. That residual loss has
# to be loud, not silent.
doomed_feed = os.path.join(capd, "doomed.xml")
open(doomed_feed, "w").write(mk_feed(
    [ENTRY % ("2607.6%03d" % i, "Fresh %d" % i, "abs", "2026-07-08T09:00:00Z")
     for i in range(2)]
    + [ENTRY % ("2607.7%03d" % i, "Stale %d" % i, "abs", "2026-07-05T20:0%d:00Z" % i)
       for i in range(5)]))
p = fetch("--max", "3", feed=doomed_feed)
check("i papers held back that fall out of the window before the next run are called out",
      re.search(r"WARNING: 2 .*age out", p.stdout) is not None,
      [l for l in p.stdout.splitlines() if "NEW PAPERS" in l])

import shutil
shutil.rmtree(home, ignore_errors=True)
ok = all(results)
print("\n=== arxiv shard + retry: %s (%d/%d) ==="
      % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
