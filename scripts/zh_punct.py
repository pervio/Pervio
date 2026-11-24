#!/usr/bin/env python3
"""zh_punct — full-width punctuation in the Chinese prose of the pages that ship.

    python3 scripts/zh_punct.py FILE…           rewrite in place
    python3 scripts/zh_punct.py --check FILE…   list what is still half-width; exit 1 if any

A Chinese sentence takes ，：；？！（）. A half-width comma between two hanzi
is set tight against the next word and reads as typed on the wrong keyboard.
Left alone: code (<code>, <pre>, `…`, fenced blocks), markup and URLs, a mark
between two digits (07:30), a button's name quoted as the app shows
it (<span class="ui">, 「…」), and any line with no Chinese in it (the English
half of a page). Works on .html and .md; `convert()` is what make-web-en.py's
table is kept in step with."""
import re, sys

CJK = "㐀-䶿一-鿿"
HAS_CJK = re.compile("[%s]" % CJK)
FW = {",": "，", ":": "：", ";": "；", "?": "？", "!": "！", "(": "（", ")": "）"}
HTML_GUARD = re.compile(
    r"<!--.*?-->|<style\b.*?</style>|<script\b.*?</script>|<pre\b.*?</pre>|<code\b.*?</code>"
    r'|<span class="ui">.*?</span>|「[^」]*」|<[^>]+>|&#?\w+;', re.S)
MD_GUARD = re.compile(r"```.*?```|`[^`\n]*`|!(?=\[)|\]\([^)\n]*\)|<[^>\n]+>|https?://[^\s)）]+|「[^」]*」", re.S)
ATTR = re.compile(r'\b(alt|aria-label|content|title)="([^"]*)"')
DIGIT = re.compile(r"[0-9]")


def _marks(s, on):
    """The offsets in `s` to convert: a half-width mark where on(i) says the
    place is Chinese prose, unless it sits between two digits or opens a
    URL's ://."""
    out = []
    for i, ch in enumerate(s):
        if ch not in FW or not on(i):
            continue
        a, b = s[i - 1:i], s[i + 1:i + 2]
        if DIGIT.match(a or " ") and DIGIT.match(b or " "):
            continue
        if ch == ":" and s[i + 1:i + 3] == "//":
            continue
        out.append(i)
    return out


def _tidy(s):
    """No space on the inside of a full-width mark: the mark carries its own."""
    s = re.sub(r"(?<=\S)[ \t]+(?=[，：；？！）（])", "", s)
    return re.sub(r"(?<=[，：；？！（）])[ \t]+(?=\S)", "", s)


def convert(text, markdown=False, whole=False):
    """`whole`: the text is one fragment of a Chinese page (a table entry), so
    its context is the fragment itself and not the line."""
    guard = MD_GUARD if markdown else HTML_GUARD
    free = [True] * len(text)
    tags = []
    for m in guard.finditer(text):
        for i in range(m.start(), m.end()):
            free[i] = False
        if not markdown and m.group().startswith("<") and not re.match(r"<(!--|style|script|pre|code|span class=\"ui\")", m.group()):
            tags.append(m)
    # which lines read as Chinese, going by what is not markup or code on them
    chinese, pos = {}, 0
    for n, line in enumerate(text.split("\n")):
        seen = "".join(c for i, c in enumerate(line, pos) if free[i])
        chinese[n] = bool(HAS_CJK.search(seen))
        pos += len(line) + 1
    if whole:
        every = bool(HAS_CJK.search(text))
        chinese = {n: every for n in chinese}
    line_of, n = [], 0
    for c in text:
        line_of.append(n)
        if c == "\n":
            n += 1
    hits = set(_marks(text, lambda i: free[i] and chinese[line_of[i]]))
    # a picture's description, a page's summary: prose kept in an attribute
    for m in tags:
        for a in ATTR.finditer(m.group()):
            if HAS_CJK.search(a.group(2)):
                base = m.start() + a.start(2)
                hits.update(base + i for i in _marks(a.group(2), lambda i: True))
    if whole and not markdown:                  # a bare attribute handed over as a fragment
        for a in ATTR.finditer(text):
            if HAS_CJK.search(a.group(2)):
                hits.update(a.start(2) + i for i in _marks(a.group(2), lambda i: True))
    out = "".join(FW[c] if i in hits else c for i, c in enumerate(text))
    return _tidy(out) if hits else out, sorted(hits)


def main(argv):
    check = "--check" in argv
    files = [a for a in argv if not a.startswith("--")]
    if not files:
        sys.exit(__doc__)
    left = 0
    for path in files:
        text = open(path, encoding="utf-8").read()
        new, hits = convert(text, markdown=path.endswith(".md"))
        if check:
            for i in hits[:8]:
                line = text.count("\n", 0, i) + 1
                print("%s:%d: %s" % (path, line, text[max(0, i - 12):i + 12].replace("\n", " ")))
            if len(hits) > 8:
                print("%s: … and %d more" % (path, len(hits) - 8))
            left += len(hits)
        elif hits:
            open(path, "w", encoding="utf-8").write(new)
            print("%s: %d marks" % (path, len(hits)))
        else:
            print("%s: nothing to change" % path)
    if check:
        print("zh_punct: %s" % ("clean" if not left else "%d half-width marks in Chinese prose" % left))
        sys.exit(1 if left else 0)


if __name__ == "__main__":
    main(sys.argv[1:])
