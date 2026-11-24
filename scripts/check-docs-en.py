#!/usr/bin/env python3
"""check-docs-en — the English guide keeps the shape of the Chinese one.

    python3 scripts/check-docs-en.py [web/docs.html web/docs-en.html]

web/docs-en.html is written by hand, sentence for sentence after web/docs.html.
Nothing ties the two together except this: the same stylesheet, the same
elements in the same order with the same classes and ids, the same commands in
every <pre> and <code>, and no link to an anchor the page does not have. A
paragraph added to one page and not the other stops here, with the place.
What it cannot see is whether the words still say the same thing."""
import re, sys
from html.parser import HTMLParser

zh_path, en_path = (sys.argv[1:3] if len(sys.argv) >= 3 else ("web/docs.html", "web/docs-en.html"))
CJK = re.compile("[㐀-䶿一-鿿]")
VOID = {"img", "meta", "link", "br", "hr", "input"}


class Shape(HTMLParser):
    """The body as a list of (depth, tag.class#id), plus what sits in code."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.rows, self.code, self.ids, self.anchors = [], [], set(), []
        self.depth, self.inside, self.buf, self.in_body, self.mute = 0, None, [], False, 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "body":
            self.in_body = True
            return
        if not self.in_body:
            return
        if a.get("id"):
            self.ids.add(a["id"])
        if tag == "a" and (a.get("href") or "").startswith("#"):
            self.anchors.append(a["href"][1:])
        name = tag + ("." + ".".join(a["class"].split()) if a.get("class") else "") + ("#" + a["id"] if a.get("id") else "")
        self.rows.append((self.depth, name, self.getpos()[0]))
        if tag not in VOID:
            self.depth += 1
        if tag in ("pre", "code") and self.inside is None:
            self.inside, self.buf = tag, []
        elif tag == "i" and self.inside == "pre":
            self.mute += 1                       # a comment in a command box is prose, and translated

    def handle_endtag(self, tag):
        if not self.in_body or tag in VOID:
            return
        self.depth -= 1
        if tag == "i" and self.inside == "pre":
            self.mute -= 1
        if tag == self.inside:
            self.code.append((tag, "".join(self.buf).rstrip(), self.getpos()[0]))
            self.inside = None

    def handle_data(self, data):
        if self.inside and not self.mute:
            self.buf.append(data)


def shape(path):
    text = open(path, encoding="utf-8").read()
    s = Shape()
    s.feed(text)
    css = re.search(r"<style>(.*?)</style>", text, re.S).group(1)
    css = re.sub(r"/\*.*?\*/", "", css, flags=re.S).replace(" zh\"", "\"")
    return s, "\n".join(l.rstrip() for l in css.split("\n") if l.strip())


zh, zh_css = shape(zh_path)
en, en_css = shape(en_path)
bad = []
if zh_css != en_css:
    a, b = zh_css.split("\n"), en_css.split("\n")
    i = next((k for k, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
    bad.append("the stylesheets differ, first at rule %d:\n    zh: %s\n    en: %s" % (
        i + 1, (a[i] if i < len(a) else "(ends)")[:110], (b[i] if i < len(b) else "(ends)")[:110]))
for k, (x, y) in enumerate(zip(zh.rows, en.rows)):
    if x[:2] != y[:2]:
        bad.append("the pages part ways at element %d: %s line %d has <%s>, %s line %d has <%s>" % (
            k + 1, zh_path, x[2], x[1], en_path, y[2], y[1]))
        break
else:
    if len(zh.rows) != len(en.rows):
        longer, path = (zh, zh_path) if len(zh.rows) > len(en.rows) else (en, en_path)
        r = longer.rows[min(len(zh.rows), len(en.rows))]
        bad.append("%s goes on where the other ends: <%s> at line %d" % (path, r[1], r[2]))
if not bad:
    for x, y in zip(zh.code, en.code):
        if x[1] != y[1] and not CJK.search(x[1]):       # a placeholder in Chinese is translated; a command is not
            bad.append("a command differs: %s line %d %r, %s line %d %r" % (zh_path, x[2], x[1][:60], en_path, y[2], y[1][:60]))
for label, page, path in (("zh", zh, zh_path), ("en", en, en_path)):
    for a in page.anchors:
        if a not in page.ids:
            bad.append("%s links to #%s, which it does not have" % (path, a))
if CJK.search(re.sub(r'lang="zh-CN">[^<]*<', "", open(en_path, encoding="utf-8").read())):
    bad.append("%s still has Chinese in it" % en_path)
for b in bad:
    print("  " + b)
if bad:
    sys.exit(1)
print("docs-en: same stylesheet, %d elements in step, %d commands identical" % (len(en.rows), len(en.code)))
