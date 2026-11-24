#!/usr/bin/env python3
"""Freeze the SERVER half of the report-actions contract (spec B2).

    python3 ios/Tests/Fixtures/reports/make_actions_contract.py           # (re)write actions-contract.json
    python3 ios/Tests/Fixtures/reports/make_actions_contract.py --check   # fail if it drifted

The rating buttons exist on two screens: the phone (RichMessageText.swift, which
hangs a tap-menu off every block whose text hits an action regex) and the Mac
(server/bin/pervio-view, which renders a `<span class="acts">` button group in
the same places). They read ONE contract — the publication spec's `actions` —
so a change on either side that moves, adds or drops a button group is a bug on
the other side's screen.

This file is the server side of that agreement, and it is NOT hand-written: it
imports the REAL server/bin/pervio-view and renders the REAL archived issues in
ios/Tests/Fixtures/reports/*.md through its REAL `parse_blocks` +
`sections_html`, then reads the button groups back out of the HTML it produced
with an HTML parser. What is recorded is therefore what the Mac actually draws.

  * iOS drift  -> ios/Tests/Render/ReportActionContractTests.swift goes red
                  (it recomputes the phone's hits and compares to this file).
  * server drift -> `--check` goes red (re-renders and diffs byte-for-byte),
                  and it is `bash server/tests/run_all.sh` that RUNS it — the
                  CHECKERS list there, guarded by that runner's
                  `no_orphan_checkers` gate.

That last clause is load-bearing, and for a while it was false. This docstring
and ReportActionContractTests.swift (:19 and :319) all three promised that server
drift turned `--check` red, while nothing in the repo ever invoked it. Moving a
button group in pervio-view therefore left BOTH screens green: the phone went on
agreeing with a frozen contract that had quietly expired. A promise about what
goes red has to name the thing that runs it, or it is only a comment.

Importing pervio-view is side-effect free: it is guarded by
`if __name__ == "__main__"`, so no HTTP server is bound, no browser is opened
and no ~/.pervio file is touched. `actions.json` is a verbatim copy of the
`actions` array in the 论文晨报 schedule's own spec (`~/.pervio/schedules/
f0890b1f3f6c/spec.json`, and identically in every run spec it has materialised
under ~/.pervio/wf), so the regex under test is the one that really ships.
"""
import argparse
import importlib.machinery
import importlib.util
import io
import json
import os
import sys
from html.parser import HTMLParser

HERE = os.path.dirname(os.path.realpath(__file__))
REPO = os.path.realpath(os.path.join(HERE, "..", "..", "..", ".."))
VIEW = os.path.join(REPO, "server", "bin", "pervio-view")
CONTRACT = os.path.join(HERE, "actions-contract.json")
ACTIONS_JSON = os.path.join(HERE, "actions.json")

# The issues frozen into this directory, in a stable order. The first four are
# verbatim real archives; the last mirrors the hostile report server/tests/
# test_view.py renders for its C group, so both suites face the same adversary.
REPORTS = [
    "papers-2026-07-18.md",
    "papers-2026-08-04.md",
    "papers-2026-08-06.md",
    "github-2026-08-04.md",
    "hostile-injection.md",
    # Not an archive either: the published issues only ever hang a rating off a
    # heading, a list item or a paragraph, so the agreement about a QUOTE (and
    # about a bare-URL chip line) was never actually tested — a mutation that
    # mislabels a quote left the whole suite green. This one issue carries the
    # same action in every block kind both renderers have.
    "kinds-sampler.md",
]

# Degenerate specs, and what the REAL `_compile_actions` does with each. The
# phone drops bad actions too (CompiledAction.compile) — but not the same ones,
# and an action that survives on one screen only is the worst kind of drift:
# buttons on one device, none on the other, and no error anywhere. Frozen here
# so the difference is a number in a file rather than a guess.
COMPILE_CASES = [
    ("the shipped spec", [{"match": r"https://arxiv\.org/abs/(\d{4}\.\d{4,5})",
                           "menu": ["\U0001F44D"], "run": "cmd --id {1}"}]),
    ("no match", [{"match": "", "menu": ["a"], "run": "cmd"}]),
    ("no menu", [{"match": "x", "menu": [], "run": "cmd"}]),
    ("no run", [{"match": "x", "menu": ["a"], "run": ""}]),
    ("unparsable regex", [{"match": "([", "menu": ["a"], "run": "cmd"}]),
    ("blank-only run", [{"match": "x", "menu": ["a"], "run": "   "}]),
    ("empty label in menu", [{"match": "x", "menu": ["a", ""], "run": "cmd"}]),
    ("run with an unbalanced quote", [{"match": "x", "menu": ["a"], "run": "cmd 'oops"}]),
    ("two good, one broken", [{"match": "x", "menu": ["a"], "run": "cmd"},
                              {"match": "([", "menu": ["a"], "run": "cmd"},
                              {"match": "y", "menu": ["b"], "run": "cmd2"}]),
]

# The HTML elements pervio-view can hang a button group off, mapped to the name
# the phone's test uses for the same place. `_acts_html` is called from exactly
# these branches of blocks_html (h/p/ul>li/quote/data/chip).
ELEMENT_KIND = {
    "h1": "heading", "h2": "heading", "h3": "heading", "h4": "heading",
    "p": "paragraph",
    "li": "listItem",
    "blockquote": "quote",
    "div": "paragraph",      # class="data" / class="chipline" — prose on the phone
}


def load_view():
    """Import server/bin/pervio-view as a module (it has no .py suffix)."""
    spec = importlib.util.spec_from_loader(
        "pervio_view", importlib.machinery.SourceFileLoader("pervio_view", VIEW))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class ActsReader(HTMLParser):
    """Pulls the rendered button groups out of pervio-view's HTML, in document
    order, each tagged with the element that encloses it and that element's
    visible text — so the contract pins WHERE a group is, not just how many."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []          # open elements: (tag, class)
        self.groups = []         # finished records
        self.cur = None          # button group being read
        self.text = {}           # id(frame) -> visible text collected so far
        self.frames = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        cls = a.get("class", "")
        if tag == "span" and cls == "acts":
            owner_tag, owner_cls, owner_text = self._owner()
            self.cur = {
                "element": owner_tag,
                "elementClass": owner_cls,
                "kind": ELEMENT_KIND.get(owner_tag, owner_tag),
                "action": int(a.get("data-action", -1)),
                "groups": json.loads(a.get("data-groups", "[]")),
                "buttons": [],
                "ownerTextPrefix": owner_text.strip()[:70],
            }
        elif tag == "button" and cls == "act" and self.cur is not None:
            self.cur["buttons"].append(None)      # label arrives as data
        self.stack.append((tag, cls))
        self.frames.append([])

    def handle_endtag(self, tag):
        while self.stack:
            t, _ = self.stack.pop()
            frame = self.frames.pop() if self.frames else []
            if self.frames:
                self.frames[-1].extend(frame)
            if t == tag:
                break
        if tag == "span" and self.cur is not None:
            self.groups.append(self.cur)
            self.cur = None

    def handle_data(self, data):
        if self.cur is not None and self.cur["buttons"] and self.cur["buttons"][-1] is None:
            self.cur["buttons"][-1] = data
        elif self.frames:
            self.frames[-1].append(data)

    def _owner(self):
        """Nearest enclosing block element + the text it has shown so far."""
        for i in range(len(self.stack) - 1, -1, -1):
            tag, cls = self.stack[i]
            if tag in ELEMENT_KIND:
                return tag, cls, "".join(self.frames[i]) if i < len(self.frames) else ""
        return "", "", ""


def render(mod, actions, markdown):
    """The Mac's rendering of one issue, with the publication's real actions."""
    mod.ACTIONS = mod._compile_actions(actions)
    mod.HITS = set()
    blocks, _ = mod.parse_blocks(markdown.split("\n"))
    return mod.sections_html(blocks)


# --------------------------------------------------------------------- argv --
# pervio-view refuses to draw a button group whose capture group starts with
# `-` (`_argv_safe`): that group is substituted into the run template as an ARGV
# ELEMENT, so `--force` would be read as a FLAG by whatever program the template
# names. The phone has no such rule. Today the published spec's regex captures
# `\d{4}\.\d{4,5}`, so no group can start with `-` and the two screens agree by
# luck of the pattern — not by agreement. This case pins the gap with an action
# whose regex CAN capture a dash, so the day a publication ships such a pattern
# the phone's test says exactly what the Mac will do differently.
ARGV_ACTIONS = [{
    "match": r"\[([\w.-]+)\]",
    "menu": ["\U0001F44D", "\U0001F44E"],
    "run": "pervio-feedback --id {1}",
}]
ARGV_MARKDOWN = "### 甲 [--force] 一\n\n### 乙 [ok123] 二\n"


def block_texts(mod, blocks):
    """Every text pervio-view offers to the action regexes, in document order —
    the server's counterpart of MarkdownBlock.actionTargets on the phone."""
    out = []
    for b in blocks:
        k = b["k"]
        if k == "ul":
            out += list(b["items"])
        elif k == "details":
            out += block_texts(mod, b["blocks"])
        elif k in ("h", "p", "quote", "data", "chip"):
            out.append(b["t"])
    return out


# The phone parses a markdown table into its own block (a SwiftUI Grid) and
# offers ONE rating menu for the whole table; pervio-view has no table block at
# all — the pipe rows fall through as one paragraph, which also carries exactly
# one button group. Same behaviour, different internal name, so the phone's
# `table` kind is one the contract can never contain. Frozen so that stays true:
# teach either side real tables and the counts move.
TABLE_MARKDOWN = ("## 表格\n\n| 论文 | 评分 |\n|---|---|\n"
                  "| [甲](https://arxiv.org/abs/2608.04788) | 4.5 |\n"
                  "| [乙](https://arxiv.org/abs/2608.04962) | 4.0 |\n")


# Two whole-line arxiv URLs on ADJACENT lines. pervio-view lifts each into its
# own `chip` block, so each gets its own button group; the phone keeps the run as
# ONE paragraph and `firstHit` fires once, so the second paper is unreachable
# there. That gap is the subject of
# ReportActionContractTests.testKnownDivergence_adjacentBareURLsCollapseToOneMenu…
# and it used to be recorded as a COMMENT saying "the Mac renders two" — a claim
# no run could check, so the day pervio-view merged the run instead (or grew a
# third group), the phone-only assertion stayed green and the note quietly became
# a lie. Rendered here by the real module, both sides of the gap are numbers.
BARE_URL_RUN_MARKDOWN = ("## 讨论\n\nhttps://arxiv.org/abs/2608.04788\n"
                         "https://arxiv.org/abs/2608.04962\n")


def synthetic_case(mod, actions, markdown):
    """One hand-built report rendered by the REAL pervio-view: its block kinds,
    and every button group it drew. Used for the constructs no archived issue
    happens to contain — a markdown table, and a run of adjacent bare URLs."""
    html = render(mod, actions, markdown)
    reader = ActsReader()
    reader.feed(html)
    blocks, _ = mod.parse_blocks(markdown.split("\n"))
    return {
        "markdown": markdown,
        "blockKinds": [b["k"] for b in blocks],
        "buttonGroups": reader.groups,
        "buttonGroupCount": len(reader.groups),
        "rawSpanCount": html.count('<span class="acts"'),
    }


def argv_safety(mod):
    """What the Mac draws for a report whose capture groups can start with `-`."""
    html = render(mod, ARGV_ACTIONS, ARGV_MARKDOWN)
    reader = ActsReader()
    reader.feed(html)
    blocks, _ = mod.parse_blocks(ARGV_MARKDOWN.split("\n"))
    texts = block_texts(mod, blocks)
    return {
        "markdown": ARGV_MARKDOWN,
        "actions": ARGV_ACTIONS,
        # Blocks whose text the regex HITS — both screens must agree on this.
        "regexHitCount": sum(1 for t in texts if mod._first_hit(t) is not None),
        "regexHitGroups": [mod._first_hit(t)[1] for t in texts
                           if mod._first_hit(t) is not None],
        # …of which the Mac actually renders buttons for. The difference IS the
        # divergence: `_argv_safe` drops the rest.
        "buttonGroups": reader.groups,
        "buttonGroupCount": len(reader.groups),
        "rawSpanCount": html.count('<span class="acts"'),
    }


def build():
    mod = load_view()
    actions = json.load(open(ACTIONS_JSON, encoding="utf-8"))
    compiled = mod._compile_actions(actions)
    out = {
        "_comment": ("Generated by ios/Tests/Fixtures/reports/make_actions_contract.py "
                     "from the REAL server/bin/pervio-view rendering the REAL archived "
                     "issues in this directory. Do not hand-edit: run the generator."),
        "actions": actions,
        "compiledActionCount": len(compiled),
        "argvSafety": argv_safety(mod),
        "tableCase": synthetic_case(mod, actions, TABLE_MARKDOWN),
        "bareURLRunCase": synthetic_case(mod, actions, BARE_URL_RUN_MARKDOWN),
        "compileCases": [{"label": label, "actions": acts,
                          "keptCount": len(mod._compile_actions(acts))}
                         for label, acts in COMPILE_CASES],
        "reports": {},
    }
    for name in REPORTS:
        md = open(os.path.join(HERE, name), encoding="utf-8").read()
        html = render(mod, actions, md)
        reader = ActsReader()
        reader.feed(html)
        out["reports"][name] = {
            "buttonGroups": reader.groups,
            "buttonGroupCount": len(reader.groups),
            # The raw count of the marker pervio-view emits per group — an
            # independent check on the HTML walk above.
            "rawSpanCount": html.count('<span class="acts"'),
        }
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    fresh = build()
    text = json.dumps(fresh, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.check:
        if not os.path.exists(CONTRACT):
            print("actions-contract.json is missing — run this script without --check")
            return 1
        old = open(CONTRACT, encoding="utf-8").read()
        if old != text:
            print("DRIFT: server/bin/pervio-view no longer renders the button groups "
                  "frozen in actions-contract.json.\n"
                  "Either the server regressed, or the contract moved on purpose — in "
                  "which case regenerate this file AND make the phone agree "
                  "(ios/Tests/Render/ReportActionContractTests.swift).")
            import difflib
            for line in list(difflib.unified_diff(
                    old.split("\n"), text.split("\n"),
                    "committed", "just-rendered", lineterm=""))[:60]:
                print(line)
            return 1
        print("ok: %d issues, button groups match the committed contract"
              % len(fresh["reports"]))
        return 0
    with open(CONTRACT, "w", encoding="utf-8") as f:
        f.write(text)
    for name, r in fresh["reports"].items():
        print("%-24s %3d button groups" % (name, r["buttonGroupCount"]))
    print("wrote", CONTRACT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
