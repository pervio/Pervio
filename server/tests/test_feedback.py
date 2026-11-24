#!/usr/bin/env python3
"""Tests for pervio-feedback — the write half of the paper-digest scoring loop.

Load-bearing contracts pinned here: the new entry lands at the SECTION TOP
(after the header + <!-- 格式 --> comment run), (暂无) placeholder is cleared,
re-scoring an id keeps only the new line (and never bleeds onto a longer id
sharing the prefix), everything outside the 反馈 section survives BYTE-FOR-BYTE
(the fixture plants a decoy arXiv:<same id> line and a second (暂无) in OTHER
sections to prove it), the 50-entry cap trims from the bottom (oldest), missing
file / missing section creation is idempotent, bad id / verdict die with rc!=0,
notes are flattened to one bounded line, stdout is one parseable JSON line, no
.tmp residue. The four verdict tokens are asserted verbatim — they must match
the App's action menu byte-for-byte. Hermetic: temp --file + PERVIO_NOW."""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
FB = os.path.realpath(os.path.join(HERE, "..", "bin", "pervio-feedback"))

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name
          + (("  [" + str(detail)[:220] + "]") if (detail and not cond) else ""))


HEADER = "## 反馈(你在聊天里给的反应,近的在上;晨报据此调整,agent 只读不写这一节)"
COMMENT = "<!-- 格式:- YYYY-MM-DD | 👍/👎/多看/少看 | arXiv:ID 或主题 | 一句话。聊天里说「把这条记进论文反馈:…」即可。 -->"
# Byte-for-byte the WorkflowMarket paper-digest action menu (A2 contract).
MENU = ["👍", "👎", "少看", "多看"]

# Production-shaped fixture. Traps: the 最近推荐 section carries a DECOY line
# containing arXiv:2607.15610 (must survive — only 节内 lines are replaced),
# and 兴趣信号 has its own (暂无) (must survive — only the 反馈 one is cleared).
BEFORE = ("# 论文记忆\n\n"
          "## 最近推荐(滚动 14 天,上限 40 条)\n"
          "- 2026-07-18 | arXiv:2607.15610 | 必读 | Decoy Title | A One | 理由\n"
          "- 2026-07-17 | arXiv:2607.00001 | 值得读 | Other | B Two | 理由\n\n")
AFTER = ("\n## 兴趣信号(机器猜测,上限 8 条;永不写进 interests.md)\n"
         "<!-- 格式:- YYYY-MM-DD | 猜测:… -->\n"
         "(暂无)\n\n"
         "## 运行状态\n"
         "- 上次运行:2026-07-19 06:30\n")
FIXTURE = BEFORE + HEADER + "\n" + COMMENT + "\n(暂无)\n" + AFTER

home = tempfile.mkdtemp(prefix="fb_", dir="/tmp")
E = dict(os.environ, PERVIO_NOW="2026-07-20T06:30:00Z")


def fb(*args, **kw):
    return subprocess.run([sys.executable, FB] + list(args),
                          env=kw.get("env", E), capture_output=True, text=True)


def mkfile(name, content=FIXTURE):
    p = os.path.join(home, name)
    with open(p, "w", encoding="utf-8") as f:
        f.write(content)
    return p


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def section(text):
    """Body of the 反馈 section (after the header line, to the next ## )."""
    m = re.search(r"(?m)^## 反馈.*\n", text)
    nxt = re.search(r"(?m)^## ", text[m.end():])
    return text[m.end():m.end() + nxt.start() if nxt else len(text)]

# ---------- a: append into production-shaped file ----------
print("=== a: append format + position + placeholder + byte preservation ===")
fa = mkfile("a.md")
p = fb("--id", "2607.15610", "--verdict", "👍", "--file", fa)
out = rd(fa)
line = "- 2026-07-20 | 👍 | arXiv:2607.15610 | (无备注)"
check("a exit 0", p.returncode == 0, p.stderr[:200])
j = None
try:
    j = json.loads(p.stdout)
except ValueError:
    pass
check("a stdout is ONE parseable JSON line {ok, line}",
      p.stdout.count("\n") == 1 and j == {"ok": True, "line": line}, p.stdout)
check("a new line sits at section top, right after the 格式 comment",
      section(out).startswith(COMMENT + "\n" + line + "\n"), section(out)[:300])
check("a (暂无) cleared from 反馈 section only",
      "(暂无)" not in section(out), section(out))
check("a bytes BEFORE the section unchanged", out.startswith(BEFORE), out[:120])
check("a bytes AFTER the section unchanged (decoy (暂无) intact)",
      out.endswith(AFTER), out[-200:])
check("a decoy arXiv:2607.15610 line in 最近推荐 untouched",
      "Decoy Title" in out)
check("a no .tmp residue", not [f for f in os.listdir(home) if f.endswith(".tmp")],
      os.listdir(home))

# ---------- b: all four menu verdicts accepted, byte-for-byte ----------
print("=== b: verdict whitelist == App menu ===")
fbv = mkfile("b.md")
rcs = [fb("--id", "2607.0000%d" % i, "--verdict", v, "--file", fbv).returncode
       for i, v in enumerate(MENU, 1)]
check("b all of 👍/👎/少看/多看 accepted", rcs == [0, 0, 0, 0], rcs)
got = re.findall(r"(?m)^- 2026-07-20 \| (\S+) \|", section(rd(fbv)))
check("b verdicts round-trip verbatim into the file (newest first)",
      got == list(reversed(MENU)), got)

# ---------- c: same-id re-score replaces the old line ----------
print("=== c: re-score overwrites ===")
fc = mkfile("c.md")
fb("--id", "2607.15610", "--verdict", "👍", "--file", fc)
fb("--id", "2607.15619", "--verdict", "👎", "--file", fc)   # longer-prefix sibling
p = fb("--id", "2607.15610", "--verdict", "少看", "--note", "换个评价", "--file", fc,
       env=dict(E, PERVIO_NOW="2026-07-21T06:30:00Z"))
sec = section(rd(fc))
hits = [l for l in sec.split("\n") if "arXiv:2607.15610" in l]
check("c exactly ONE line for the re-scored id, the new one",
      hits == ["- 2026-07-21 | 少看 | arXiv:2607.15610 | 换个评价"], hits)
check("c prefix-sharing id 2607.15619 NOT deleted by 2607.1561x re-score",
      "arXiv:2607.15619" in sec, sec)

# id 2607.1561 (one digit shorter) must not clobber 2607.15610 either
fb("--id", "2607.1561", "--verdict", "👍", "--file", fc)
sec = section(rd(fc))
check("c shorter id 2607.1561 coexists with 2607.15610",
      "arXiv:2607.1561 |" in sec and "arXiv:2607.15610 |" in sec, sec)

# ---------- d: missing file / missing section, idempotent ----------
print("=== d: creation paths ===")
fd = os.path.join(home, "d_missing.md")
p = fb("--id", "2607.11111", "--verdict", "多看", "--file", fd)
out = rd(fd)
check("d missing file created with verbatim header + comment + entry",
      p.returncode == 0 and out ==
      HEADER + "\n" + COMMENT + "\n- 2026-07-20 | 多看 | arXiv:2607.11111 | (无备注)\n",
      out)
check("d created file is 0600", oct(os.stat(fd).st_mode & 0o777) == "0o600",
      oct(os.stat(fd).st_mode))
fb("--id", "2607.22222", "--verdict", "👍", "--file", fd)
check("d second run reuses the section (idempotent: ONE header)",
      rd(fd).count("## 反馈") == 1, rd(fd))

fe = mkfile("d_nosec.md", "# 手记\n\n## 别的节\n- 内容\n")
p = fb("--id", "2607.33333", "--verdict", "👎", "--file", fe)
out = rd(fe)
check("d headerless file: section appended at EOF, prefix bytes intact",
      out.startswith("# 手记\n\n## 别的节\n- 内容\n")
      and out.count("## 反馈") == 1
      and section(out).startswith(
          COMMENT + "\n- 2026-07-20 | 👎 | arXiv:2607.33333 | (无备注)\n"), out)
fperm = mkfile("d_perm.md", "# x\n")
os.chmod(fperm, 0o644)
fb("--id", "2607.44444", "--verdict", "👍", "--file", fperm)
check("d existing file keeps its own mode (0644)",
      oct(os.stat(fperm).st_mode & 0o777) == "0o644", oct(os.stat(fperm).st_mode))

# ---------- e: 50-entry cap trims oldest (bottom) ----------
print("=== e: 50 cap ===")
entries = "".join("- 2026-06-%02d | 👍 | arXiv:2606.%05d | 旧%d\n" % (i % 28 + 1, i, i)
                  for i in range(50, 0, -1))
ff = mkfile("e.md", HEADER + "\n" + COMMENT + "\n" + entries)
fb("--id", "2607.55555", "--verdict", "👍", "--file", ff)
sec = section(rd(ff))
got = [l for l in sec.split("\n") if l.startswith("- ")]
check("e capped at 50 entries", len(got) == 50, len(got))
check("e newest at top, oldest (arXiv:2606.00001) dropped from bottom",
      got[0].endswith("arXiv:2607.55555 | (无备注)")
      and "arXiv:2606.00001" not in sec and "arXiv:2606.00002" in sec,
      got[0] + " … " + got[-1])

# ---------- f: rejection paths ----------
print("=== f: bad id / verdict die ===")
fg = mkfile("f.md")
bad = [("--id", "cs/0701001"), ("--id", "2607.156"), ("--id", "12607.15610"),
       ("--id", "2607.15610v2"), ("--id", "")]
rcs = [fb(b[0], b[1], "--verdict", "👍", "--file", fg).returncode for b in bad]
check("f old-style / malformed ids all rejected rc!=0",
      all(rc != 0 for rc in rcs), rcs)
p1 = fb("--id", "2607.15610", "--verdict", "赞", "--file", fg)
p2 = fb("--id", "2607.15610", "--verdict", "", "--file", fg)
check("f off-menu verdict rejected rc!=0, names the flag",
      p1.returncode != 0 and "--verdict" in p1.stderr and p2.returncode != 0,
      p1.stderr[:120])
check("f rejected runs left the file byte-identical", rd(fg) == FIXTURE)

# ---------- g: note hygiene ----------
print("=== g: note flattening + truncation ===")
fh = mkfile("g.md")
p = fb("--id", "2607.66666", "--verdict", "👍",
       "--note", "第一行\n第二行\t  多空格", "--file", fh)
check("g newlines/tabs folded to single spaces",
      json.loads(p.stdout)["line"].endswith("| 第一行 第二行 多空格"), p.stdout)
long_note = "长" * 200
p = fb("--id", "2607.77777", "--verdict", "👎", "--note", long_note, "--file", fh)
check("g 200-char note truncated to 120",
      json.loads(p.stdout)["line"].endswith("| " + "长" * 120), p.stdout)
check("g flattened notes really are one line in the file",
      all(l.count("arXiv:") <= 1 for l in rd(fh).split("\n")))

# ---------- h: PERVIO_NOW respected ----------
print("=== h: PERVIO_NOW pins the date ===")
fi = mkfile("h.md")
p = fb("--id", "2607.88888", "--verdict", "多看", "--file", fi,
       env=dict(os.environ, PERVIO_NOW="2025-12-31T23:59:00Z"))
check("h injected date lands in the line",
      json.loads(p.stdout)["line"].startswith("- 2025-12-31 |"), p.stdout)
p = fb("--id", "2607.88888", "--verdict", "多看", "--file", fi,
       env=dict(os.environ, PERVIO_NOW="not-a-date"))
check("h unparseable PERVIO_NOW dies rc!=0", p.returncode != 0, p.stdout)

# ---------- i: review P2/P3 regressions ----------
print("=== i: note citing another id must not delete that entry ===")
fi = mkfile("i.md")
fb("--id", "2607.22222", "--verdict", "👍", "--note", "对比 arXiv:2607.33333 更好", "--file", fi)
fb("--id", "2607.33333", "--verdict", "👎", "--file", fi)
body = open(fi).read()
check("i cross-citing entry survives a re-score of the cited id",
      "arXiv:2607.22222" in body and "对比 arXiv:2607.33333 更好" in body, body)
check("i cited id got its own entry", "| arXiv:2607.33333 |" in body, body)
fb("--id", "2607.33333", "--verdict", "多看", "--file", fi)
body = open(fi).read()
check("i re-scoring the cited id still keeps the citing entry",
      "arXiv:2607.22222" in body and body.count("| arXiv:2607.33333 |") == 1, body)

print("=== i2: ## 反馈历史 decoy section must not be claimed ===")
fi = os.path.join(home, "i2.md")
open(fi, "w").write("# 记忆\n\n## 反馈历史(旧档案)\n- 旧行\n")
fb("--id", "2607.44444", "--verdict", "👍", "--file", fi)
body = open(fi).read()
check("i2 real 反馈 section was created (decoy untouched)",
      HEADER in body and "- 旧行\n" in body, body)
sec = body[body.index(HEADER):]
check("i2 entry lives in the REAL section, not the decoy",
      "arXiv:2607.44444" in sec and "arXiv:2607.44444" not in body[:body.index(HEADER)], body)

check("final: no .tmp residue anywhere",
      not [f for f in os.listdir(home) if f.endswith(".tmp")], os.listdir(home))

# ---------- j: B4 — interrupt safety of the memory-file write ----------
# memory.md is the accumulated judgement of every paper the user ever scored.
# There is no backup and no undo, so the two things that matter are: a write
# that cannot finish must leave the OLD file exactly as it was, and two writes
# racing must not eat each other. Each verdict is a read-modify-write of the
# whole file, so overlapping runs both read the same "before", both rewrite the
# whole thing, and the loser's entry is gone — every one of them still printing
# {"ok": true}. The App fires these from a long-press menu; two taps, or a tap
# while the 晨报 records one, is an ordinary Tuesday.
print("=== j: concurrent scoring must not lose entries ===")
jhome = tempfile.mkdtemp(prefix="fb_race_", dir="/tmp")
jmem = os.path.join(jhome, "memory.md")
with open(jmem, "w", encoding="utf-8") as f:
    f.write(BEFORE + HEADER + "\n" + COMMENT + "\n(暂无)\n" + AFTER)
N = 8
gate = os.path.join(jhome, "GO")
kids = []
for i in range(N):
    # Busy-wait on a gate file so all N enter their read-modify-write together;
    # without the barrier the processes would mostly serialize by luck.
    kids.append(subprocess.Popen(
        ["sh", "-c", "while [ ! -f %s ]; do :; done; exec %s %s --id 2607.1%04d "
                     "--verdict 👍 --note note%d --file %s"
                     % (gate, sys.executable, FB, i, i, jmem)],
        env=E, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
import time as _t
_t.sleep(0.25)
with open(gate, "w") as f:
    f.write("go")
rcs = [(k.wait(), k.communicate()) for k in kids]
jbody = rd(jmem)
missing = [i for i in range(N) if ("arXiv:2607.1%04d" % i) not in jbody]
claimed_ok = sum(1 for rc, (o, _e) in rcs if rc == 0 and '"ok": true' in o)
check("j every concurrent verdict that reported ok:true is actually in the file",
      not missing, "lost %d of %d: %s (all %d runs claimed success)"
      % (len(missing), N, missing, claimed_ok))
check("j the file is still one well-formed 反馈 section (no interleaved rewrite)",
      jbody.count(HEADER) == 1 and "\x00" not in jbody
      and jbody.startswith(BEFORE) and jbody.endswith(AFTER),
      (jbody.count(HEADER), "\x00" in jbody, jbody[:80], jbody[-60:]))
check("j the placeholder is gone exactly once, entries are one per line",
      len([l for l in section(jbody).split("\n") if l.startswith("- ")]) == N,
      section(jbody)[:400])
check("j no .tmp residue after the storm",
      not [f for f in os.listdir(jhome) if f.endswith(".tmp")], os.listdir(jhome))

# A write that runs out of room must lose NOTHING: old bytes intact, non-zero
# exit, no partial file the 晨报 would then read as the whole memory.
print("=== j: a write that cannot finish keeps the old file ===")
jbig = os.path.join(jhome, "big.md")
with open(jbig, "w", encoding="utf-8") as f:
    f.write(BEFORE + HEADER + "\n" + COMMENT + "\n"
            + "".join("- 2026-07-%02d | 👍 | arXiv:2607.2%04d | %s\n"
                      % (i % 28 + 1, i, "pad " * 200) for i in range(40))
            + AFTER)
jbig_before = open(jbig, "rb").read()


def _fsize_cap():
    import resource as _r
    import signal as _s
    _s.signal(_s.SIGXFSZ, _s.SIG_IGN)       # EFBIG instead of dying on the signal
    _r.setrlimit(_r.RLIMIT_FSIZE, (8192, 8192))


pj = subprocess.run([sys.executable, FB, "--id", "2607.99999", "--verdict", "👍",
                     "--file", jbig], env=E, capture_output=True, text=True,
                    stdin=subprocess.DEVNULL, preexec_fn=_fsize_cap)
check("j a write that ran out of room exits non-zero", pj.returncode != 0,
      (pj.returncode, pj.stdout[:120], pj.stderr[:160]))
check("j ...and never claims ok", '"ok": true' not in pj.stdout, pj.stdout[:160])
check("j ...and leaves memory.md byte-identical", open(jbig, "rb").read() == jbig_before,
      len(open(jbig, "rb").read()))
check("j ...and leaves no partial temp file behind",
      not [f for f in os.listdir(jhome) if f.endswith(".tmp")], os.listdir(jhome))

# A read-only directory is the other half: nothing can be written at all.
print("=== j: an unwritable directory keeps the old file ===")
jro = os.path.join(jhome, "ro")
os.makedirs(jro)
jrom = os.path.join(jro, "memory.md")
with open(jrom, "w", encoding="utf-8") as f:
    f.write(FIXTURE)
jro_before = open(jrom, "rb").read()
os.chmod(jro, 0o555)
try:
    pr = fb("--id", "2607.88888", "--verdict", "👎", "--file", jrom)
    check("j an unwritable directory exits non-zero and says so",
          pr.returncode != 0 and "pervio-feedback" in pr.stderr,
          (pr.returncode, pr.stdout[:120], pr.stderr[:160]))
    check("j ...and the old memory.md is byte-identical",
          open(jrom, "rb").read() == jro_before)
finally:
    os.chmod(jro, 0o755)

shutil.rmtree(jhome, ignore_errors=True)
shutil.rmtree(home, ignore_errors=True)

# ---------- taste v2: content-carrying verdicts + the permanent journal ----------
# docs/taste.md, 2026-08-21. Contracts pinned:
#  ① no user note → the ledger line carries《resolved title》(the mute-id era is
#     over); unknown id degrades to the old (无备注) byte-for-byte;
#  ② a user note still wins the visible slot; the title rides the journal;
#  ③ the journal is append-only: re-rating an id = ONE ledger line, TWO journal
#     lines; nothing ever rewrites journal history;
#  ④ title resolution covers all issue shapes: 必读 block (### + meta line),
#     速读/值得看 list line (+ indented gist), 扫过 line (★ badge stripped);
#  ⑤ migrate fills titles into existing (无备注) lines, seeds the journal from
#     history, and is idempotent (second run seeds nothing new).
print("=== taste v2: title resolution + journal + migrate ===")
troot = tempfile.mkdtemp(prefix="fb_taste_", dir="/tmp")
tmem = os.path.join(troot, "memory.md")
os.makedirs(os.path.join(troot, "archive"))
with open(os.path.join(troot, "archive", "2026-08-19.md"), "w", encoding="utf-8") as f:
    f.write("# 论文晨报 2026-08-19 · 扫了 80 篇\n> 今日一句:x\n\n"
            "### 用超图给智能体装技能记忆\n"
            "[arXiv:2608.16114](https://arxiv.org/abs/2608.16114) · 一作 某某\n"
            "**问题** 略。\n\n"
            "## 速读\n\n"
            "- [arXiv:2608.15787](https://arxiv.org/abs/2608.15787) MoE路由偏差的拆解量化 ·仅摘要\n"
            "  MoE模型后训练时路由会漂移,这篇把它单独量化。\n\n"
            "## 扫过(初筛评语)\n\n"
            "- [arXiv:2608.16707](https://arxiv.org/abs/2608.16707) `★3` 语义先验偏置探索行为\n")
tenv = dict(os.environ, PERVIO_NOW="2026-08-21T10:00:00Z")

# ① 必读 block 标题进账;journal 带 title
r = fb("--id", "2608.16114", "--verdict", "👍", "--file", tmem, env=tenv)
mem = open(tmem, encoding="utf-8").read()
check("t1 no-note verdict carries the resolved 必读 title",
      r.returncode == 0 and "| 《用超图给智能体装技能记忆》" in mem, mem[-300:])
jpath = os.path.join(troot, "taste-journal.jsonl")
j = [json.loads(l) for l in open(jpath, encoding="utf-8")]
check("t2 journal line: act/id/title/src, empty note",
      len(j) == 1 and j[0]["act"] == "👍" and j[0]["id"] == "2608.16114"
      and j[0]["title"] == "用超图给智能体装技能记忆" and j[0]["note"] == ""
      and j[0]["src"] == "rate", j)

# ② 速读行:标题 + 缩进 gist;用户备注占可见位
r = fb("--id", "2608.15787", "--verdict", "少看", "--note", "路由这块我不跟",
       "--file", tmem, env=tenv)
mem = open(tmem, encoding="utf-8").read()
j = [json.loads(l) for l in open(jpath, encoding="utf-8")]
check("t3 user note wins the ledger slot; title+gist still ride the journal",
      "| 路由这块我不跟" in mem and j[-1]["title"] == "MoE路由偏差的拆解量化"
      and j[-1]["gist"].startswith("MoE模型后训练") and j[-1]["note"] == "路由这块我不跟",
      (mem[-200:], j[-1]))

# ③ 扫过行:★徽章剥掉;未知 id 退回旧行为
r = fb("--id", "2608.16707", "--verdict", "👎", "--file", tmem, env=tenv)
j = [json.loads(l) for l in open(jpath, encoding="utf-8")]
check("t4 skim line title resolves with the badge stripped",
      j[-1]["title"] == "语义先验偏置探索行为", j[-1])
r = fb("--id", "2608.99999", "--verdict", "👎", "--file", tmem, env=tenv)
mem = open(tmem, encoding="utf-8").read()
check("t5 unknown id degrades to (无备注), exactly the old behavior",
      "arXiv:2608.99999 | (无备注)" in mem, mem[-200:])

# ④ journal 只增:同 id 重打 = 账一行,journal 两行
fb("--id", "2608.16114", "--verdict", "👎", "--file", tmem, env=tenv)
mem = open(tmem, encoding="utf-8").read()
j = [json.loads(l) for l in open(jpath, encoding="utf-8")]
check("t6 re-rating: one ledger line, but BOTH journal events remain",
      mem.count("arXiv:2608.16114") == 1
      and sum(1 for e in j if e["id"] == "2608.16114") == 2
      and [e["act"] for e in j if e["id"] == "2608.16114"] == ["👍", "👎"], j)

# ⑤ migrate:哑谜补标题 + 播种 journal + 幂等
mroot = tempfile.mkdtemp(prefix="fb_migr_", dir="/tmp")
mmem = os.path.join(mroot, "memory.md")
shutil.copytree(os.path.join(troot, "archive"), os.path.join(mroot, "archive"))
with open(mmem, "w", encoding="utf-8") as f:
    f.write(HEADER + "\n" + COMMENT + "\n"
            "- 2026-08-12 | 少看 | arXiv:2608.15787 | (无备注)\n"
            "- 2026-08-12 | 多看 | arXiv:2608.16114 | 保持关注\n")
r = subprocess.run([sys.executable, FB, "migrate", "--file", mmem],
                   env=tenv, capture_output=True, text=True)
mem = open(mmem, encoding="utf-8").read()
mj = [json.loads(l) for l in open(os.path.join(mroot, "taste-journal.jsonl"), encoding="utf-8")]
check("t7 migrate fills the mute line's title and keeps the noted one",
      r.returncode == 0 and "| 《MoE路由偏差的拆解量化》" in mem
      and "| 保持关注" in mem, mem)
check("t8 migrate seeds the journal from history (with titles)",
      len(mj) == 2 and {e["src"] for e in mj} == {"migrate"}
      and any(e["id"] == "2608.16114" and e["note"] == "保持关注" for e in mj), mj)
r2 = subprocess.run([sys.executable, FB, "migrate", "--file", mmem],
                    env=tenv, capture_output=True, text=True)
mj2 = [json.loads(l) for l in open(os.path.join(mroot, "taste-journal.jsonl"), encoding="utf-8")]
check("t9 migrate is idempotent: second run seeds nothing",
      r2.returncode == 0 and len(mj2) == 2 and json.loads(r2.stdout)["seeded"] == 0,
      r2.stdout)
shutil.rmtree(troot, ignore_errors=True)
shutil.rmtree(mroot, ignore_errors=True)

# ---------- profile 子命令:画像区的唯一合法写入口 ----------
# 契约:整段替换「## 口味画像」区(无则建),区外字节原样;验证是信任边界——
# 非 "- " 行、超 12 条、拒收时 rc!=0 且文件一字不动。
print("=== profile: the one legal writer of the 口味画像 section ===")
import base64 as _b64
proot = tempfile.mkdtemp(prefix="fb_prof_", dir="/tmp")
pmem = os.path.join(proot, "memory.md")
with open(pmem, "w", encoding="utf-8") as f:
    f.write("# 头\n\n## 口味画像(旧头)\n- 旧规则一条\n\n" + HEADER + "\n(暂无)\n")


def prof(body, mem=pmem):
    return subprocess.run([sys.executable, FB, "profile",
                           "--b64", _b64.b64encode(body.encode()).decode(),
                           "--file", mem], capture_output=True, text=True)


r = prof("- 纯刷榜无分析:降档(证据 3 次,最近 08-20)\n- 推理效率:升温(证据 2 次,最近 08-19)")
mem = open(pmem, encoding="utf-8").read()
check("p1 profile replaces the whole section and keeps bytes outside it",
      r.returncode == 0 and "旧规则一条" not in mem
      and "- 纯刷榜无分析:降档(证据 3 次,最近 08-20)" in mem
      and mem.startswith("# 头\n") and HEADER in mem, mem)
before = mem
r = prof("这不是清单行")
check("p2 non-bullet content refused, file byte-identical",
      r.returncode != 0 and open(pmem, encoding="utf-8").read() == before,
      r.stderr[:120])
r = prof("\n".join("- 规则%d" % i for i in range(13)))
check("p3 13 rules > cap refused", r.returncode != 0
      and open(pmem, encoding="utf-8").read() == before, r.stderr[:120])
r = prof("- 只有一条", mem=os.path.join(proot, "fresh.md"))
check("p4 missing file/section: created from scratch",
      r.returncode == 0
      and "## 口味画像" in open(os.path.join(proot, "fresh.md"), encoding="utf-8").read(),
      r.stdout)
shutil.rmtree(proot, ignore_errors=True)

ok = all(results)
print("\n=== pervio-feedback: %s (%d/%d) ==="
      % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
