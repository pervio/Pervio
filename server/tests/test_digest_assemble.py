#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pervio-digest-assemble `issue` — the three properties that are this tool's
reason to exist, and nothing else (the render layer is inherited verbatim from
the bake-off-accepted assemble.py and was accepted by eye):

  G1 verify gate    — an entry whose verify verdict is pass=false, and whose
                      ONE revision then fails verify2 as well, must NOT be
                      assembled, and the issue's tail must name it (with why)
                      on the 「本期未过核查」 line (the fixture carries the
                      full two-round path: revise + verify2 children)
  G2 link uniqueness— links appear ONLY on each block's meta line; a URL the
                      model smuggled into prose is stripped
  G3 count reproducibility — the printed 正文汉字 number must be re-derivable
                      from the finished document alone (independent recount
                      here, plus counts.json agreement)

Hermetic: a fabricated $PERVIO_WF_DIR under a throwaway /tmp dir — ledger.json
plus dispatch/fanout/{read,decompose,verify}/<i>/out.jsonl in claude
stream-json shape, exactly what a real run leaves behind. No real ~/.pervio,
no network, no agents."""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
BIN = os.path.realpath(os.path.join(HERE, "..", "bin"))
TOOL = os.path.join(BIN, "pervio-digest-assemble")

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name
          + (("  [" + str(detail)[:300] + "]") if (detail and not cond) else ""))


FETCH = """REPORT_DATE: 2026-08-06
NEW PAPERS (cs.CL · last 3d · 2 new)

1) 分片 1/1 · 论文 1-2 · REPORT_DATE: 2026-08-06
- P1 · Alpha Paper Title
  arXiv:2608.00001 [cs.CL] · 2026-08-05 · A One
  https://arxiv.org/abs/2608.00001
  摘要: alpha abstract text.
- P2 · Beta Paper Title
  arXiv:2608.00002 [cs.CL] · 2026-08-05 · B Two
  https://arxiv.org/abs/2608.00002
  摘要: beta abstract text.
"""

PICK = ("1. arXiv:2608.00001 初筛★4.5 https://arxiv.org/html/2608.00001v1\n"
        "2. arXiv:2608.00002 初筛★4 https://arxiv.org/html/2608.00002v1\n")

CARDS = {
    0: "arXiv:2608.00001 深读卡片\n问题:甲问题描述。\n做法:甲做法描述。",
    1: "arXiv:2608.00002 深读卡片\n问题:乙问题描述。\n做法:乙做法描述。",
}


def entry(pid, title, move):
    return {
        "id": pid, "title": title,
        "meta_number": "基线从五十分升到七十分",
        "stuck": "大家卡在训练信号太稀疏这一步。",
        "move": move,
        "evidence": "对照基线提升了二十分,消融后回落到基线。",
        "act": {"verdict": "观望", "line": "等复现结果再动手。"},
        "artifact": "无", "artifact_url": "",
        "ledger": [{"claim": "基线五十分", "source": "五十分"}],
    }


ENTRIES = {
    # G2 bait: a bare URL smuggled into prose — must be stripped, never rendered
    0: entry("2608.00001", "把稀疏信号补密的一手",
             "它先建对照组再相减,所以噪声被抵消。详见 https://example.com/leak 页面。"),
    1: entry("2608.00002", "乙篇不该出现的标题",
             "乙的做法描述,因此有效。"),
}

VERDICTS = {
    0: {"pass": True, "fixes": [],
        "counts": {"stuck": 10, "move": 20, "evidence": 15, "act_line": 8,
                   "total": 53, "ledger": 1, "ledger_bad": 0}},
    1: {"pass": False, "fixes": ["meta_number 的数字在台账里找不到出处"],
        "counts": {"stuck": 10, "move": 8, "evidence": 15, "act_line": 8,
                   "total": 41, "ledger": 1, "ledger_bad": 1}},
}

# the failed entry's ONE revision (revise child 0 ↔ failed[0]) …
REVISED = {0: entry("2608.00002", "乙篇重写后的标题也不该出现", "乙重写后的做法,因此有效。")}
# … which verify2 rejects again — the gate must hold across both rounds.
VERDICTS2 = {0: {"pass": False, "fixes": ["数字仍然没有台账出处"],
                 "counts": {"stuck": 10, "move": 9, "evidence": 15, "act_line": 8,
                            "total": 42, "ledger": 1, "ledger_bad": 1}}}

TRENDS = ("两篇都在给稀疏奖励补密这条线上使劲,前提是补密不会引入新偏差。\n"
          "如果接下来出现补密后成绩反降的对照实验,这条判断就被推翻。\n")


def claude_jsonl(text):
    return json.dumps({"type": "result", "result": text,
                       "is_error": False}, ensure_ascii=False) + "\n"


def make_wf(root):
    wf = os.path.join(root, "wf")
    os.makedirs(wf)
    ledger = {"wfId": "t", "status": "running", "steps": [
        {"id": "fetch", "status": "done", "output": FETCH},
        {"id": "pick", "status": "done", "output": PICK},
        {"id": "trends", "status": "done", "output": TRENDS},
    ]}
    with open(os.path.join(wf, "ledger.json"), "w", encoding="utf-8") as f:
        json.dump(ledger, f, ensure_ascii=False)
    for sid, payload in (("read", CARDS),
                         ("decompose", {i: json.dumps(e, ensure_ascii=False)
                                        for i, e in ENTRIES.items()}),
                         ("verify", {i: json.dumps(v, ensure_ascii=False)
                                     for i, v in VERDICTS.items()}),
                         ("revise", {i: json.dumps(e, ensure_ascii=False)
                                     for i, e in REVISED.items()}),
                         ("verify2", {i: json.dumps(v, ensure_ascii=False)
                                      for i, v in VERDICTS2.items()})):
        for i, text in payload.items():
            d = os.path.join(wf, "dispatch", "fanout", sid, str(i))
            os.makedirs(d)
            with open(os.path.join(d, "out.jsonl"), "w", encoding="utf-8") as f:
                f.write(claude_jsonl(text))
    return wf


def recount(doc):
    """Independent (third) implementation of the stats-line caliber: prose
    lines only — '**label** text' minus the label, and 'N. trend' minus the
    number — counting U+4E00..U+9FFF."""
    total = 0
    for line in doc.split("\n"):
        if line.startswith("**"):
            close = line.find("**", 2)
            text = line[close + 2:] if close != -1 else line
        elif re.match(r"\d+\. ", line):
            text = line[line.index(". ") + 2:]
        else:
            continue
        total += sum(1 for ch in text if 0x4E00 <= ord(ch) <= 0x9FFF)
    return total


SCORE5 = ("arXiv:2608.00091 | ★3 | 命中:方向1 | 初筛评语甲 | 亮点\n"
          "arXiv:2608.00092 | ★3.5 | 命中:无 | 这行不该进扫过 | 亮点\n"
          "arXiv:2608.00093 | ★3 | 命中:无 | 初筛评语乙 | 亮点\n")

# 一句 40 汉字装不下的 move:整句超限,所以「完整句」这一档取不到东西。
# 2026-08-11 真跑就是这个形状 —— 于是今日一句掉到「标题——判断词」兜底,
# 与紧跟其下的 ### 标题一字不差。
LONG_MOVE = ("它先把每一条轨迹复制成两份,一份附上未来真实观测,一份不附,"
             "再把两份的对数概率相减得到只跟真实反馈有关的残差,"
             "最后只在最难的两成步骤上施加这个残差。")

# 一个全角标点的 move:没有一句 <=40 汉字(整段是一句 60 汉字),于是今日一句
# 掉到 tier-2「取最长的整子句头」。而那个整子句头恰好停在一个全角逗号「，」
# 上——tier-2 收尾要把行尾这个标点剪掉。剪标点用的字符集若只含半角+全角「、」
# 而漏了全角「，；：」,今日一句就会以一个吊着的「,」结尾(读者看得见的排版毛刺)。
FW_TAIL_MOVE = ("它先把每条轨迹复制成两份对照甲乙丙丁戊，"
                "再把两份的对数概率统统相减去掉，"
                "最后只在最难的那两成步骤之上施加这个校正后的残差数值")


def raw_with_bare_quote(pid, title, move, needle, replacement):
    """A decompose child's reply with an UNESCAPED English double quote inside a
    string value — serialize first, then inject the raw quotes, so the text really
    is invalid JSON (json.dumps would have escaped them). This is what killed the
    day's top-scoring paper on 2026-08-11."""
    s = json.dumps(entry(pid, title, move), ensure_ascii=False)
    assert needle in s and '\\"' not in replacement
    return s.replace(needle, replacement)


def make_wf_tiered(root, name="wf5", score=SCORE5, moves=None, raw=None,
                   trends=TRENDS, midpick=None, midread=None, pick=None):
    """Five passing entries + a score step with two ★3 lines — the tier split.
    `moves` overrides entry i's move; `raw` overrides decompose child i's reply
    text verbatim (for the malformed-JSON fixtures); `trends` overrides the
    trends step's output (for the numbering-strip fixture); `midpick`/`midread`
    add the second tier (引言级速读): the midpick list text plus one midread
    fan-out child reply per index; `pick` overrides the deep-read shortlist
    (pass NO_CANDIDATES to model a day where nothing cleared the ★3.5 bar while
    the second tier still picked something up)."""
    moves, raw = moves or {}, raw or {}
    wf = os.path.join(root, name)
    os.makedirs(wf)
    ids = ["2608.0001%d" % i for i in range(5)]
    pick = pick or "".join("%d. arXiv:%s 初筛★4 https://arxiv.org/html/%sv1\n"
                           % (n, pid, pid) for n, pid in enumerate(ids, 1))
    fetch5 = ("REPORT_DATE: 2026-08-06\nNEW PAPERS (cs.CL · last 3d · 5 new)\n\n"
              + "".join("- P%d · Paper %d\n  arXiv:%s [cs.CL] · 2026-08-05 · A\n"
                        "  https://arxiv.org/abs/%s\n  摘要: text %d.\n"
                        % (n, n, pid, pid, n) for n, pid in enumerate(ids, 1)))
    ledger = {"wfId": "t5", "status": "running", "steps": [
        {"id": "fetch", "status": "done", "output": fetch5},
        {"id": "pick", "status": "done", "output": pick},
        {"id": "score", "status": "done", "output": score},
        {"id": "trends", "status": "done", "output": trends},
    ]}
    if midpick is not None:
        ledger["steps"].append({"id": "midpick", "status": "done", "output": midpick})
    with open(os.path.join(wf, "ledger.json"), "w", encoding="utf-8") as f:
        json.dump(ledger, f, ensure_ascii=False)
    for i, text in (midread or {}).items():
        d = os.path.join(wf, "dispatch", "fanout", "midread", str(i))
        os.makedirs(d)
        with open(os.path.join(d, "out.jsonl"), "w", encoding="utf-8") as f:
            f.write(claude_jsonl(text))
    for i, pid in enumerate(ids):
        mv = moves.get(i, "先量再改,因此第%d篇有效。" % i)
        dec = raw.get(i) or json.dumps(entry(pid, "第%d篇的标题带动词" % i, mv),
                                       ensure_ascii=False)
        for sid, text in (("read", "arXiv:%s 深读卡片\n问题:第%d篇。" % (pid, i)),
                          ("decompose", dec),
                          ("verify", json.dumps({"pass": True, "fixes": []},
                                                ensure_ascii=False))):
            d = os.path.join(wf, "dispatch", "fanout", sid, str(i))
            os.makedirs(d)
            with open(os.path.join(d, "out.jsonl"), "w", encoding="utf-8") as f:
                f.write(claude_jsonl(text))
    return wf


def run_issue(wf):
    return run_cmd(wf, "issue")


def run_cmd(wf, *argv):
    return subprocess.run([sys.executable, TOOL, *argv],
                          env=dict(os.environ, PERVIO_WF_DIR=wf),
                          capture_output=True, text=True, timeout=60)


# 第二档(引言级速读)的选文窗口 [2.5, 3.5):三行故意贴着两个边界,一行在窗外。
SCORE_MID = ("arXiv:2608.00030 | ★2.4 | 命中:无 | 差 0.1 分,不该进速读 | 亮点\n"
             "arXiv:2608.00031 | ★2.5 | 命中:无 | 下边界闭区间,要进 | 亮点\n"
             "arXiv:2608.00032 | ★3.4 | 命中:无 | 上边界内,要进 | 亮点\n"
             "arXiv:2608.00033 | ★3.5 | 命中:无 | 已是深读线,不该进速读 | 亮点\n")

# 速读名单 + 两个 midread 子项。00021 同时出现在初筛 ★3.2 的行里:同一篇不能
# 既进「速读」又进「扫过」(两节相邻,读者会看见同一个编号出现两次)。
MIDPICK = ("1. arXiv:2608.00021 初筛★3.2 https://arxiv.org/html/2608.00021v1\n"
           "2. arXiv:2608.00022 初筛★2.6 https://arxiv.org/html/2608.00022v1\n")
MIDREAD = {
    0: json.dumps({"id": "2608.00021", "title": "让检索器自己判断该不该检索",
                   "summary": "模型每次提问都去检索,一半的检索其实白花时间。"
                              "这篇让模型先估一下自己会不会答错,只在没把握时才去检索,"
                              "在同样准确率下检索次数降了四成。",
                   "source": "intro"}, ensure_ascii=False),
    1: json.dumps({"id": "2608.00022", "title": "把长上下文按段落打分再丢",
                   "summary": "长文喂进模型时,前面的段落常常挤掉后面的关键句。"
                              "这篇按段落算一个保留分,低分段落直接丢掉再拼回去,"
                              "省下三成显存。",
                   "source": "abstract"}, ensure_ascii=False),
}
SCORE_MID_DUP = SCORE5 + "arXiv:2608.00021 | ★3.2 | 命中:无 | 这条应被速读接走 | 亮点\n"


def quote_of(doc):
    """今日一句 as printed, without its label."""
    for line in doc.split("\n"):
        if line.startswith("> 今日一句:"):
            return line[len("> 今日一句:"):]
    return ""


def stats_of(doc):
    return next((l for l in doc.split("\n") if l.startswith("——")), "")


def hanzi(s):
    return sum(1 for ch in s if 0x4E00 <= ord(ch) <= 0x9FFF)


def main():
    root = tempfile.mkdtemp(prefix="pervio-digest-asm-")
    try:
        wf = make_wf(root)
        env = dict(os.environ, PERVIO_WF_DIR=wf)
        p = subprocess.run([sys.executable, TOOL, "issue"], env=env,
                           capture_output=True, text=True, timeout=60)
        doc = p.stdout
        ok_run = (p.returncode == 0 and doc.startswith("# 论文晨报 2026-08-06"))

        # G1: the pass=false entry is gated out of the BODY — no ### block, no
        # prose — but it is not erased: it gets ONE fact-brief line (its own
        # title + link, program-assembled) plus the named reason at the tail.
        # An all-reject day therefore still ships a usable briefing, never an
        # empty issue (2026-08-11 shipped 430 bytes of nothing; this pins the
        # floor that prevents it).
        tail = next((l for l in doc.split("\n") if l.startswith("本期未过核查:")), "")
        # 2026-08-20 用户裁定:复核(verify2)只留意见不毙人;2026-08-22 进一步
        # 裁撤——每天 15 个旗舰子代理只为写没人读的意见,纯成本。重写后的条目
        # 直接全文发布,review_notes 字段保留但恒空(counts.json 读者无感)。
        # round-1 的核查门与重写环节原样保留。夹具里的 verify2 子项仍在,用来
        # 证明"就算老运行里有复核意见,也没人再去读它"。
        try:
            with open(os.path.join(wf, "counts.json"), encoding="utf-8") as f:
                counts1 = json.load(f)
        except (OSError, ValueError):
            counts1 = {}
        notes1 = counts1.get("review_notes") or []
        check("G1 review is advisory: revised entry publishes in full, notes archived",
              ok_run
              and "[arXiv:2608.00001]" in doc                 # the round-1 passer
              and "### 乙篇重写后的标题也不该出现" in doc     # revised entry now PUBLISHES
              and "### 乙篇不该出现的标题" not in doc         # …as its REVISED text only
              and tail == ""                                   # nobody was rejected
              and notes1 == [],                                # verify2 retired: 意见不再收集
              "rc=%s tail=%r notes=%r stderr=%r"
              % (p.returncode, tail[:80], notes1, p.stderr[-200:]))

        # G1b the gate that REMAINS: a revise child that produced garbage (not
        # JSON) has nothing publishable — that paper is still rejected, housed
        # in 扫过 as a one-liner (round-1 title, ·未过核查 marker), and named
        # at the tail with the structural reason. Style opinions stopped
        # killing papers; structural corpses still do.
        wfb = make_wf(tempfile.mkdtemp(dir=root))   # make_wf hardcodes its dir name
        rj = os.path.join(wfb, "dispatch", "fanout", "revise", "0", "out.jsonl")
        with open(rj, "w", encoding="utf-8") as f:
            f.write(claude_jsonl("抱歉,这篇我重写不出来。")
                    .replace('"result": "', '"result": "垃圾非JSON '))
        pb = subprocess.run([sys.executable, TOOL, "issue"],
                            env=dict(os.environ, PERVIO_WF_DIR=wfb),
                            capture_output=True, text=True, timeout=60)
        docb = pb.stdout
        tailb = next((l for l in docb.split("\n") if l.startswith("本期未过核查:")), "")
        briefb = [l for l in docb.split("\n") if l.startswith("- [arXiv:2608.00002]")]
        check("G1b structural failure still rejects: housed in 扫过, named at tail",
              pb.returncode == 0
              and "### 乙篇不该出现的标题" not in docb
              and "### 乙篇重写后的标题也不该出现" not in docb
              and len(briefb) == 1
              and briefb[0].rstrip().endswith("·未过核查")
              and "## 扫过" in docb
              and "arXiv:2608.00002" in tailb and "重写" in tailb,
              "rc=%s tail=%r briefs=%d stderr=%r"
              % (pb.returncode, tailb[:120], len(briefb), (pb.stderr or "")[-200:]))

        # G2: links live ONLY on meta lines and fact-brief lines — the prose
        # URL was stripped. One meta link (passing block) + one brief link.
        meta_links = sum(l.count("](") for l in doc.split("\n")
                         if l.startswith("[arXiv:"))
        brief_links = sum(l.count("](") for l in doc.split("\n")
                          if l.startswith("- [arXiv:"))
        check("G2 link uniqueness: every link sits on a meta line; prose URL stripped",
              ok_run and doc.count("](") == meta_links + brief_links
              and meta_links == 2 and brief_links == 0    # both entries publish now
              and "example.com" not in doc,
              "total=%d meta=%d brief=%d" % (doc.count("]("), meta_links, brief_links))

        # G3: the printed 正文汉字 number is re-derivable from the doc alone,
        # and counts.json agrees.
        m = re.search(r"正文 (\d+) 汉字\(程序测量\)", doc)
        try:
            with open(os.path.join(wf, "counts.json"), encoding="utf-8") as f:
                counts = json.load(f)
        except (OSError, ValueError):
            counts = {}
        check("G3 count reproducibility: stats line == independent recount == counts.json",
              ok_run and m is not None
              and int(m.group(1)) == recount(doc) == counts.get("body_hanzi_total"),
              "line=%s recount=%s counts=%s" % (m and m.group(1), recount(doc),
                                                counts.get("body_hanzi_total")))

        # G4 merged tiers (2026-08-20 用户裁定): every verify-passer renders a
        # FULL block in score order — no top-3 cut, no 值得看 section; the skim
        # layer is the catch-all, so even the ★3.5 row that never made the
        # deep-read shortlist gets a home there (before, it vanished — counted
        # in the header, listed nowhere; that gap is what confused the user).
        wf5 = make_wf_tiered(root)
        p5 = run_issue(wf5)
        doc5 = p5.stdout
        lines5 = doc5.split("\n")
        skim = [l for l in lines5 if l.startswith("- [arXiv:2608.0009")]
        stats5 = stats_of(doc5)
        check("G4 merged tiers: 5 full blocks, no 值得看, every scored row housed",
              p5.returncode == 0
              and doc5.count("### ") == 5
              and "## 值得看" not in doc5
              and len(skim) == 3 and "## 扫过" in doc5
              and "这行不该进扫过" in doc5      # unpicked ★3.5 now HAS a home
              and "`★3.5`" in doc5 and "`★3`" in doc5
              and "本期必读 5 篇 · 速读 0 篇 · 扫过 3 篇" in stats5
              and "合计 8 篇" in stats5,
              "rc=%s blocks=%d skim=%d stats=%r stderr=%r"
              % (p5.returncode, doc5.count("### "), len(skim),
                 stats5[:110], (p5.stderr or "")[-150:]))

        # G5 the catch-all's own manners: rows sort by ★ descending (the reader
        # scans best-first), and NO paper id appears on two different lines of
        # the issue — one home each, that is the whole 2026-08-20 contract.
        skim_stars = [float(re.search(r"`★([\d.]+)`", l).group(1))
                      for l in skim if re.search(r"`★([\d.]+)`", l)]
        all_ids = re.findall(r"- \[arXiv:(\d+\.\d+)\]", doc5)
        check("G5 扫过 sorts by star desc and no id is listed twice",
              p5.returncode == 0
              and skim_stars == sorted(skim_stars, reverse=True)
              and len(all_ids) == len(set(all_ids)),
              "stars=%r dup=%r" % (skim_stars,
                                   [i for i in all_ids if all_ids.count(i) > 1]))

        # G6 扫过 is honest about its own source: when the score step's rows do
        # not parse, the section is OMITTED and the stats line SAYS SO — never a
        # silent "扫过 0 篇" that reads like "nothing scored 3 stars today".
        wf6 = make_wf_tiered(root, "wf6", score="6/6 done\n\n[1] OK\n评委没按格式输出\n")
        p6 = run_issue(wf6)
        doc6, stats6 = p6.stdout, stats_of(p6.stdout)
        check("G6 unparseable score: 扫过 section dropped AND the stats line says why",
              p6.returncode == 0
              and "## 扫过" not in doc6
              and "扫过 0 篇(初筛输出没解析出评分行)" in stats6
              and "没解析出" not in stats5          # …and no such note when rows parsed
              and "必读 5 篇" in stats6,
              "stats6=%r stats5=%r" % (stats6[:120], stats5[:120]))

        # G7 the 2026-08-11 killer: a decompose child writes an unescaped English
        # double quote inside a JSON string value. Strict parsing fails, and the
        # whole paper — that day the highest-scoring one — was dropped. A single
        # repair-and-retry keeps it, and says on stderr that it had to.
        wf7 = make_wf_tiered(root, "wf7", raw={
            0: raw_with_bare_quote("2608.00010", "带裸引号的第0篇",
                                   "先量再改,因此第0篇有效。",
                                   "先量再改", '先用 "对照组" 量再改')})
        p7 = run_issue(wf7)
        doc7 = p7.stdout
        check("G7 bare-quote salvage: unescaped \" inside a value is repaired, paper kept",
              p7.returncode == 0
              and "### 带裸引号的第0篇" in doc7            # kept, not dropped
              and '先用 "对照组" 量再改' in doc7           # the repaired text, verbatim
              and "本期未过核查" not in doc7
              and "裸英文双引号" in (p7.stderr or ""),     # and it left a trace
              "rc=%s kept=%s stderr=%r"
              % (p7.returncode, "### 带裸引号的第0篇" in doc7, (p7.stderr or "")[-200:]))

        # G8 今日一句 must not be the headline it sits above. When the first
        # must-read's move has no complete sentence inside the 40-汉字 budget,
        # the old code fell straight through to 「标题——判断词」 — which on a
        # one-must-read day printed the title twice, two lines apart.
        wf8 = make_wf_tiered(root, "wf8", moves={0: LONG_MOVE})
        p8 = run_issue(wf8)
        doc8, q8 = p8.stdout, quote_of(p8.stdout)
        title8 = "第0篇的标题带动词"
        check("G8 今日一句 ≠ 标题: quote comes from move, within budget, no title echo",
              p8.returncode == 0
              and q8 and title8 not in q8 and "——" not in q8
              and q8 in LONG_MOVE                      # verbatim, from the move
              and hanzi(q8) <= 40,
              "quote=%r hanzi=%d" % (q8, hanzi(q8)))

        # …and the ordinary case still takes the whole sentence it always took.
        q5 = quote_of(doc5)
        check("G8b 今日一句 unchanged when a complete sentence fits",
              q5 == "先量再改,因此第0篇有效。", "quote=%r" % (q5,))

        # G9 FULL-WIDTH punctuation. The papers are Chinese and the models type
        # ，；：, not ,;: — but every fixture above (and the repo's own prose)
        # uses half-width, so a character class that lost its full-width half
        # stayed green forever while production silently degraded:
        #   * SENT_SPLIT/CLAUSE_SPLIT couldn't split a real move at all, so
        #     today's line fell through to 「标题——判断词」 every single day;
        #   * norm_id couldn't strip an "arXiv：" prefix, so a paper whose entry
        #     id carried a full-width colon was dropped as a pairing failure.
        # Both are one root cause, so they are pinned together.
        fw_move = ("它先把每条轨迹复制成两份对照，一份附上真实观测，一份不附；"
                   "两份相减得到只跟真实反馈有关的残差，最后只在最难的两成步骤上施加这个残差。")
        wf9 = make_wf_tiered(root, "wf9", moves={0: fw_move}, raw={
            1: json.dumps(dict(entry("2608.00011", "全角冒号编号的第1篇", "先量再改,因此有效。"),
                               id="arXiv：2608.00011"), ensure_ascii=False)})
        p9 = run_issue(wf9)
        doc9, q9 = p9.stdout, quote_of(p9.stdout)
        check("G9 full-width punctuation: move splits, and an arXiv：id still pairs",
              p9.returncode == 0
              and q9 == "它先把每条轨迹复制成两份对照，一份附上真实观测，一份不附；"
              and "### 全角冒号编号的第1篇" in doc9
              and "本期未过核查" not in doc9,
              "quote=%r paired=%s tail=%r"
              % (q9, "### 全角冒号编号的第1篇" in doc9,
                 next((l for l in doc9.split("\n") if l.startswith("本期未过核查")), "")[:90]))

        # G10 今日一句 tier-2 must not end in a dangling full-width clause mark.
        # When no whole sentence fits the 40-汉字 budget, the line falls to the
        # longest whole-clause head; clause_prefix trims trailing clause marks so
        # the head reads clean. That trim set was half-width-only (,;: plus 、),
        # so a head ending in a full-width ，；： kept the mark — a Chinese move
        # (which is what production always has) would print "…相减去掉，" with a
        # comma hanging off the end of 今日一句, every day it hit tier-2.
        wf10 = make_wf_tiered(root, "wf10", moves={0: FW_TAIL_MOVE})
        p10 = run_issue(wf10)
        doc10, q10 = p10.stdout, quote_of(p10.stdout)
        check("G10 tier-2 今日一句: trailing full-width clause mark trimmed",
              p10.returncode == 0
              and q10 == "它先把每条轨迹复制成两份对照甲乙丙丁戊，再把两份的对数概率统统相减去掉"
              and q10 and q10[-1] not in "，；：、,;:"      # no dangling clause mark
              and "——" not in q10                          # tier-2 fired, not the title fallback
              and hanzi(q10) <= 40,
              "quote=%r last=%r hanzi=%d" % (q10, q10[-1:], hanzi(q10)))

        # G11 趋势 numbering strip must cover full-width numerals/delimiters. The
        # trends step is model-written, so it may number items "1)" OR "1）" OR
        # "１.". LIST_PREFIX stripped only half-width "\d[.、)]", so a full-width
        # "1）第一条…" shipped WITH its "1）" prefix baked into the 趋势 line.
        fw_trends = "1）第一条趋势用全角编号写成。\n2）第二条也用全角编号。\n"
        wf11 = make_wf_tiered(root, "wf11", trends=fw_trends)
        p11 = run_issue(wf11)
        doc11 = p11.stdout
        lines11 = doc11.split("\n")
        trend_body = [l for l in lines11
                      if re.match(r"^\d+\. ", l) and "趋势用全角" in l or "也用全角" in l]
        # 2026-08-14: 趋势一节按用户要求撤出成品(它每天在拼三篇不相干的论文)。
        # 断言随之翻面——不再检查编号剥得对不对,而是检查这一节**根本不出现**:
        # 没有 "## 趋势" 标题、模型写的趋势正文一个字都不上版、统计行也不再报条数。
        # render_trends 本身保留(产物仍进 counts.json 备查),所以恢复只需改回渲染。
        check("G11 趋势一节不进成品(标题/正文/统计行三处都不出现)",
              p11.returncode == 0
              and "## 趋势" not in doc11
              and "全角编号" not in doc11
              and "趋势" not in [l for l in lines11 if l.startswith("—— 本期")][0],
              "trend_lines=%r stats=%r stderr=%r"
              % ([l for l in lines11 if "全角编号" in l],
                 [l for l in lines11 if l.startswith("—— 本期")][:1],
                 (p11.stderr or "")[-150:]))

        # G12 midpick 的分数窗口是这一档存在的边界:★2.5 进(闭下界)、★3.4 进、
        # ★3.5 不进(那是深读的地盘,重复读一遍等于白花一次 opus 流水线)、
        # ★2.4 不进。窗口写错一头,要么和深读撞车,要么把噪声抬进出刊。
        wf12 = make_wf_tiered(root, "wf12", score=SCORE_MID)
        p12 = run_cmd(wf12, "midpick")
        # 2026-08-22 JSON 车道:名单从编号行换成 JSON 数组(read/midread 的
        # split:json 源),窗口边界与降序契约原样搬家。
        mid_arr = json.loads(p12.stdout)
        picked = [r["id"] for r in mid_arr]
        check("G12 midpick 窗口: 2.5 进 / 3.4 进 / 3.5 不进 / 2.4 不进,按分降序(JSON)",
              p12.returncode == 0
              and picked == ["2608.00032", "2608.00031"]
              and "2608.00030" not in p12.stdout
              and "2608.00033" not in p12.stdout
              and mid_arr[0]["id"] == "2608.00032" and mid_arr[0]["stars"] == 3.4
              and mid_arr[0]["url"].startswith("https://arxiv.org/html/"),
              "out=%r stderr=%r" % (p12.stdout, (p12.stderr or "")[-150:]))

        # G13 速读节:每篇两行(标题+链接 / 2–3 句速读),source=abstract 的那篇
        # 行尾带「·仅摘要」,统计行报出篇数,链接自检不误报(这一节的标题行与
        # 值得看/简报同形,brief_links 必须把它数进去,否则 issue 直接退 3 不出报),
        # 并且被速读接走的那篇不再重复出现在「扫过」里。
        wf13 = make_wf_tiered(root, "wf13", score=SCORE_MID_DUP,
                              midpick=MIDPICK, midread=MIDREAD)
        p13 = run_issue(wf13)
        doc13 = p13.stdout
        lines13 = doc13.split("\n")
        n13 = lines13.index("## 速读") if "## 速读" in lines13 else -1
        sec13 = lines13[n13:n13 + 6] if n13 >= 0 else []
        check("G13 速读节: 两行一篇,仅摘要标记,统计行计数,链接自检不报,扫过不重出",
              p13.returncode == 0
              and n13 >= 0
              and sec13[2] == ("- [arXiv:2608.00021](https://arxiv.org/abs/2608.00021)"
                               " 让检索器自己判断该不该检索")
              and sec13[3].startswith("  模型每次提问都去检索")
              and sec13[4].endswith("·仅摘要")           # 只有 source=abstract 的那篇
              and "·仅摘要" not in sec13[2]
              and "速读 2 篇" in stats_of(doc13)
              and n13 < next(k for k, l in enumerate(lines13) if l.startswith("## 扫过"))
              and sum(1 for l in lines13 if l.startswith("- [arXiv:2608.00021")) == 1
              and "这条应被速读接走" not in doc13,
              "rc=%s sec=%r stats=%r stderr=%r"
              % (p13.returncode, sec13, stats_of(doc13)[:120], (p13.stderr or "")[-200:]))

        # G14 一个 midread 子项写坏了(道歉句,不是 JSON)只该赔掉那一篇的速读卡:
        # 整期照出,另一篇照常渲染,stderr 点名,而那一篇退回「扫过」拿回初筛评语
        # (读者仍看得见它)。整期因为一个便宜档的子项崩掉,是拿最贵的那三篇给
        # 最便宜的一档陪葬。
        bad = {**MIDREAD, 0: "抱歉,这篇的 HTML 我打不开,没法给你速读。"}
        wf14 = make_wf_tiered(root, "wf14", score=SCORE_MID_DUP,
                              midpick=MIDPICK, midread=bad)
        p14 = run_issue(wf14)
        doc14 = p14.stdout
        check("G14 midread 子项解析失败: 只跳过那一篇的速读卡,整期照出并退回扫过",
              p14.returncode == 0
              and "## 速读" in doc14
              and "让检索器自己判断该不该检索" not in doc14   # 坏的那篇没有速读卡
              and "这条应被速读接走" in doc14                 # …但退回扫过,没丢
              and "把长上下文按段落打分再丢" in doc14         # 好的那篇照常
              and "速读 1 篇" in stats_of(doc14)
              and doc14.count("### ") == 5                   # 必读(过审全体)一篇没少
              and "2608.00021" in (p14.stderr or ""),
              "rc=%s stats=%r stderr=%r"
              % (p14.returncode, stats_of(doc14)[:120], (p14.stderr or "")[-200:]))

        # G15 「今天没有值得读的」只有在真的什么都没有时才准说。深读名单空
        # (没有一篇够 ★3.5)但第二档捞到了两篇速读的那一天,一期里同时印着
        # 「今天没有值得读的——休息一天也是判断」和下面两篇速读卡,自相矛盾
        # (2026-08-14 真出过这一期)。今日一句和正文兜底句都必须先看速读。
        wf15 = make_wf_tiered(root, "wf15", pick="1. NO_CANDIDATES\n",
                              midpick=MIDPICK, midread=MIDREAD)
        p15 = run_issue(wf15)
        doc15 = p15.stdout
        q15 = quote_of(doc15)
        check("G15 空必读 + 有速读: 今日一句与兜底句都不说「没有值得读的」,且点出速读",
              p15.returncode == 0
              and "## 速读" in doc15
              and "速读 2 篇" in stats_of(doc15)
              and "没有值得读的" not in doc15          # 兜底句 + 今日一句都不许说
              and "休息一天" not in doc15
              and "速读" in q15,                       # 今日一句自己点出今天有什么
              "rc=%s quote=%r stats=%r stderr=%r"
              % (p15.returncode, q15, stats_of(doc15)[:120], (p15.stderr or "")[-200:]))

        # G18 JSON 车道(2026-08-22 瘦身):score 的引擎产物 json/score.json 是
        # pick/midpick/扫过车道的第一数据源——正则抠作文的年代结束。夹具直接
        # 铺 artifact:两个分片、一篇跨分片重复(取最高分)、边界各站一头。
        wf18 = os.path.join(root, "wf18")
        os.makedirs(os.path.join(wf18, "json"))
        with open(os.path.join(wf18, "ledger.json"), "w") as f:
            json.dump({"steps": []}, f)
        with open(os.path.join(wf18, "json", "score.json"), "w", encoding="utf-8") as f:
            json.dump([
                [{"id": "2608.00050", "stars": 4.2, "hit": "方向1", "reason": "机制新"},
                 {"id": "2608.00051", "stars": 3.5, "hit": "无", "reason": "达标线上"},
                 {"id": "2608.00052", "stars": 3.4, "hit": "无", "reason": "中档"}],
                [{"id": "2608.00050", "stars": 3.0, "hit": "无", "reason": "另一评委低分"},
                 {"id": "2608.00053", "stars": 2.4, "hit": "无", "reason": "线下"}],
            ], f, ensure_ascii=False)
        p18 = run_cmd(wf18, "pick")
        arr18 = json.loads(p18.stdout)
        check("G18a pick 读引擎产物: ≥3.5 入选,跨分片取最高分,降序,带 url",
              p18.returncode == 0
              and [r["id"] for r in arr18] == ["2608.00050", "2608.00051"]
              and arr18[0]["stars"] == 4.2
              and arr18[0]["url"] == "https://arxiv.org/html/2608.00050v1",
              p18.stdout)
        p18m = run_cmd(wf18, "midpick")
        check("G18b midpick 同源: 只有 3.4 那篇落进 2.5-3.4 窗口",
              p18m.returncode == 0
              and [r["id"] for r in json.loads(p18m.stdout)] == ["2608.00052"],
              p18m.stdout)
        with open(os.path.join(wf18, "json", "score.json"), "w") as f:
            json.dump([[]], f)
        p18e = run_cmd(wf18, "pick")
        check("G18c 空日: pick 输出 NO_CANDIDATES 哨兵数组(fan-out 不空转)",
              p18e.returncode == 0 and json.loads(p18e.stdout) == ["NO_CANDIDATES"],
              p18e.stdout)

        # G19 配对协议在 JSON 名单下不变形:把老夹具的 pick 产出换成 JSON 数组,
        # 深读卡仍按"数组次序 = 子项目录名"配对,整刊照出。
        wf19 = make_wf(tempfile.mkdtemp(dir=root))
        led19 = json.load(open(os.path.join(wf19, "ledger.json")))
        for st in led19["steps"]:
            if st["id"] == "pick":
                ids19 = re.findall(r"arXiv:(\d+\.\d+)", st["output"])
                st["output"] = json.dumps(
                    [{"id": i, "stars": 4.0,
                      "url": "https://arxiv.org/html/%sv1" % i} for i in ids19])
        with open(os.path.join(wf19, "ledger.json"), "w") as f:
            json.dump(led19, f, ensure_ascii=False)
        p19 = run_issue(wf19)
        check("G19 JSON 名单下配对协议不变: 必读区照常成刊",
              p19.returncode == 0 and "[arXiv:2608.00001]" in p19.stdout,
              (p19.returncode, (p19.stderr or "")[-150:]))

        # G20 流程行与方法图(2026-08-24 定稿):flow 由拆解步随条目携带,渲染成
        # 非加粗普通行(两套汉字计数器都跳过,自检不炸);方法图由 figs 步程序化
        # 抽取,渲染成嵌入式图片行(行首 "!",同样不进汉字口径;"](" 计入链接
        # 自检)。域名白名单 arxiv.org:figs 里的恶意域名不渲染,模型侧 entry
        # 若夹带 figure_url 一律无视——图的唯一来源是程序抽取。
        wf20 = make_wf(tempfile.mkdtemp(dir=root))
        for i, flow in enumerate(["输入 → 打分 → 选路 → 验收", ""]):
            cp = os.path.join(wf20, "dispatch", "fanout", "decompose", str(i), "out.jsonl")
            if not os.path.exists(cp):
                continue
            lines20 = [json.loads(l) for l in open(cp, encoding="utf-8") if l.strip()]
            for o in lines20:
                if o.get("type") == "result" and o.get("result"):
                    e = json.loads(o["result"])
                    e["flow"] = flow
                    e["figure_url"] = "https://evil.example.com/entry-smuggled.png"
                    o["result"] = json.dumps(e, ensure_ascii=False)
            with open(cp, "w", encoding="utf-8") as f:
                for o in lines20:
                    f.write(json.dumps(o, ensure_ascii=False) + "\n")
        led20 = json.load(open(os.path.join(wf20, "ledger.json")))
        led20["steps"].append({"id": "figs", "status": "done", "output": json.dumps([
            {"id": "2608.00001", "figure_url": "https://arxiv.org/html/2608.00001v1/x1.png",
             "caption": "Overview of the method"},
            {"id": "2608.00002", "figure_url": "https://evil.example.com/x.png"}])})
        with open(os.path.join(wf20, "ledger.json"), "w") as f:
            json.dump(led20, f, ensure_ascii=False)
        p20 = run_issue(wf20)
        check("G20a 流程行上刊:非加粗普通行,自检(链接数+汉字复算)全过",
              p20.returncode == 0
              and "\n流程:输入 → 打分 → 选路 → 验收\n" in p20.stdout
              and "**流程**" not in p20.stdout,
              (p20.returncode, (p20.stderr or "")[-150:]))
        check("G20b 方法图嵌成图片行(figs 步来源+白名单);恶意域名与 entry 夹带全部不渲染",
              "![方法图:Overview of the method](https://arxiv.org/html/2608.00001v1/x1.png)" in p20.stdout
              and "evil.example.com" not in p20.stdout,
              [l for l in p20.stdout.split("\n") if "方法图" in l][:2])

        # G21 figs 纯解析半边(网络无关):相对地址按浏览器规则解析(基准=页面
        # URL,不手工加斜杠——加了会把论文号拼两遍,实战咬过两口);data:、
        # 站点装饰、arxiv 之外的域名全滤掉;图注剥标签截 60 字。
        import importlib.machinery, importlib.util
        _l = importlib.machinery.SourceFileLoader("asm21", TOOL)
        asm21 = importlib.util.module_from_spec(importlib.util.spec_from_loader("asm21", _l))
        _l.exec_module(asm21)
        html21 = ('<figure><img src="2608.9v1/figures/a.png">'
                  '<figcaption>Figure 1: <b>Neat</b> method [overview] (long) that is '
                  + 'x' * 300 +
                  '</figcaption></figure>'
                  '<figure><img src="data:image/png;base64,xx"></figure>'
                  '<img src="/static/logo.png">'
                  '<figure><img src="https://evil.example.com/x.png"></figure>')
        cands = asm21.figs_candidates("https://arxiv.org/html/2608.9v1", html21)
        check("G21 figs 解析:单倍路径 + 三类脏源全滤 + 图注剥标签、200 字封顶、半角括号洗全角(alt 槽里一个 ] 就毁整行)",
              len(cands) == 1
              and cands[0][0] == "https://arxiv.org/html/2608.9v1/figures/a.png"
              and cands[0][1].startswith("Figure 1: Neat method \u3014overview\u3015 \uff08long\uff09")
              and len(cands[0][1]) <= 200
              and "[" not in cands[0][1] and "(" not in cands[0][1],
              cands)

        # G22 方案乙(2026-08-27):深读员指认方法图编号,程序按图注「Figure N」
        # 对号入座;Table 候选永不入选;编号缺席退回启发式第一张;编号超界按
        # 序数兜底。纯函数,零网络。
        cands22 = [("https://arxiv.org/h/t1.png", "Table 1: setup"),
                   ("https://arxiv.org/h/f1.png", "Figure 1: teaser results"),
                   ("https://arxiv.org/h/f2.png", "Figure 2: overview of the method"),
                   ("https://arxiv.org/h/f3.png", "Figure 3: ablations")]
        check("G22a 编号对号: fig_no=2 → 图注 Figure 2 那张",
              asm21._choose_figure(cands22, 2)[0].endswith("f2.png"))
        check("G22b 无编号 → 第一张非 Table",
              asm21._choose_figure(cands22, None)[0].endswith("f1.png"))
        check("G22c Table 永不入选 + 超界编号按序数兜底(第 3 张非 Table)",
              asm21._choose_figure(cands22, 99)[0].endswith("f1.png")
              and asm21._choose_figure([("u", "Table 1: x")], 1) is None)
        wf22 = make_wf(tempfile.mkdtemp(dir=root))
        cp22 = os.path.join(wf22, "dispatch", "fanout", "decompose", "0", "out.jsonl")
        lines22 = [json.loads(l) for l in open(cp22, encoding="utf-8") if l.strip()]
        for o in lines22:
            if o.get("type") == "result" and o.get("result"):
                e = json.loads(o["result"]); e["fig_no"] = "2"
                o["result"] = json.dumps(e, ensure_ascii=False)
        with open(cp22, "w", encoding="utf-8") as f:
            for o in lines22:
                f.write(json.dumps(o, ensure_ascii=False) + "\n")
        env22 = dict(os.environ, PERVIO_WF_DIR=wf22)
        import importlib as _il
        nos22 = asm21._entry_fig_nos(wf22)
        check("G22d 拆解条目里的编号被取出 {id: n}",
              nos22.get("2608.00001") == 2, nos22)

        # G17 tasteapply: the profile lands, and every failure mode degrades to
        # "yesterday's profile stands" with exit 0 — this step must be unable
        # to block the issue (docs/taste.md). Four paths pinned: valid bullets
        # write the section; NO_CHANGE and garbage and a missing child all
        # leave memory.md byte-identical and still exit 0.
        wf17 = os.path.join(root, "wf17")
        os.makedirs(os.path.join(wf17, "dispatch", "fanout", "taste", "0"))
        with open(os.path.join(wf17, "ledger.json"), "w") as f:
            json.dump({"steps": []}, f)
        mem17 = os.path.join(root, "memory17.md")
        with open(mem17, "w", encoding="utf-8") as f:
            f.write("# 头\n")

        def taste_out(text):
            with open(os.path.join(wf17, "dispatch", "fanout", "taste", "0",
                                   "out.jsonl"), "w", encoding="utf-8") as f:
                f.write(claude_jsonl(text))

        def run_taste():
            return subprocess.run([sys.executable, TOOL, "tasteapply", "--file", mem17],
                                  env=dict(os.environ, PERVIO_WF_DIR=wf17),
                                  capture_output=True, text=True, timeout=60)

        taste_out("- 纯刷榜无分析:降档(证据 3 次,最近 08-20)")
        p17 = run_taste()
        m17 = open(mem17, encoding="utf-8").read()
        check("G17 valid profile bullets land in memory.md",
              p17.returncode == 0 and "画像已更新" in p17.stdout
              and "## 口味画像" in m17 and "纯刷榜无分析" in m17, (p17.stdout, m17[-120:]))
        frozen = m17
        taste_out(json.dumps(["评估体系类:降温(证据 2 次,最近 08-12)",
                              "- 推理效率:升温(证据 2 次,最近 08-19)"], ensure_ascii=False))
        p17 = run_taste()
        m17b = open(mem17, encoding="utf-8").read()
        check("G17 JSON-array answer converts to bullets (dash-prefixed item tolerated)",
              p17.returncode == 0 and "- 评估体系类:降温(证据 2 次,最近 08-12)" in m17b
              and "- 推理效率:升温(证据 2 次,最近 08-19)" in m17b
              and "- - " not in m17b, (p17.stdout, m17b[-160:]))
        frozen = m17b
        taste_out("[]")
        p17 = run_taste()
        check("G17 empty array = nothing new: untouched, exit 0",
              p17.returncode == 0 and "画像不变" in p17.stdout
              and open(mem17, encoding="utf-8").read() == frozen, p17.stdout)
        taste_out("NO_CHANGE")
        p17 = run_taste()
        check("G17 NO_CHANGE: untouched, exit 0",
              p17.returncode == 0 and "画像不变" in p17.stdout
              and open(mem17, encoding="utf-8").read() == frozen, p17.stdout)
        taste_out("抱歉,我整理不出画像。")
        p17 = run_taste()
        check("G17 garbage output: refused by the validator, untouched, exit 0",
              p17.returncode == 0 and "拒收" in p17.stdout
              and open(mem17, encoding="utf-8").read() == frozen, p17.stdout)
        os.remove(os.path.join(wf17, "dispatch", "fanout", "taste", "0", "out.jsonl"))
        p17 = run_taste()
        check("G17 missing child: 沿用昨日, untouched, exit 0",
              p17.returncode == 0 and "沿用昨日" in p17.stdout
              and open(mem17, encoding="utf-8").read() == frozen, p17.stdout)

        # G16 真空刊(深读名单空,第二档也空)那一句不能被 G15 改坏:
        # 什么都没捞到的日子,还是要敢说「今天没有值得读的」。
        wf16 = make_wf_tiered(root, "wf16", pick="1. NO_CANDIDATES\n")
        p16 = run_issue(wf16)
        check("G16 真空刊: 仍旧说「今天没有值得读的——休息一天也是判断」",
              p16.returncode == 0
              and quote_of(p16.stdout) == "今天没有值得读的——休息一天也是判断"
              and "## 速读" not in p16.stdout,
              "rc=%s quote=%r" % (p16.returncode, quote_of(p16.stdout)))

    finally:
        shutil.rmtree(root, ignore_errors=True)

    print("%d/%d passed" % (sum(results), len(results)))
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
