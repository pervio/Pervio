#!/usr/bin/env python3
"""public_scan — the gate a tree passes before it is published.

    python3 scripts/public_scan.py [DIR]        (default: the current directory)

Walks every text file under DIR and fails (exit 1) on anything that should
not leave a developer's machine: key material, tokens, personal e-mail
addresses, public IP literals, tailnet addresses, home-directory paths, and
whatever literals the developer lists in a private file next to the tree
(`.public-scan.local`, one per line, git-ignored — the list of things to keep
out is itself not something to publish).

Fixtures are allowed to LOOK like secrets where a test needs them to: a key
block in one of the test files named in KNOWN_TEST_KEYS, a token carrying
FAKE / PLANTED / EXAMPLE / DUMMY, addresses from the documentation ranges,
`/Users/me`-style placeholders. Everything else is a finding with its file
and line. A tree that cannot be read is an error, never "clean"."""
import os
import re
import sys

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
SKIP_DIRS = {".git", "node_modules", "DerivedData", ".build", "__pycache__"}
BINARY = (".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf", ".ttf", ".otf", ".woff", ".woff2", ".mp4", ".heic", ".icns")
VECTOR = (".svg",)                       # path data is full of dotted numbers
# The only files allowed to carry a whole private key: keys made for a test and
# authorised nowhere. A key block anywhere else — another test file included —
# is a finding, so a new one has to be put on this list by a person who looked.
KNOWN_TEST_KEYS = {
    "ios/Tests/Store/KeychainTests.swift",          # a filler body, not a key
    "ios/Tests/Transport/HostIdentityTests.swift",  # an ed25519 key made for the test
}

PLACEHOLDER_USERS = {"me", "x", "you", "yourname", "user", "username", "runner", "shared", "name", "pervio", "someone"}
DOC_NETS = re.compile(r"^(?:127\.|0\.|10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.|169\.254\.|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|255\.|1\.2\.3\.4$|8\.8\.[48]\.[48]$|1\.1\.1\.1$)")

RULES = [
    ("private key block", re.compile(r"-----BEGIN (?:OPENSSH |RSA |EC |DSA |)PRIVATE KEY-----")),
    ("token", re.compile(r"sk-ant-[A-Za-z0-9_-]{16,}|sk-proj-[A-Za-z0-9_-]{16,}|\bsk-[A-Za-z0-9]{40,}|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[bap]-[A-Za-z0-9-]{20,}")),
    ("personal e-mail", re.compile(r"[A-Za-z0-9._%+-]+@(?:gmail|qq|163|126|outlook|hotmail|icloud|foxmail|proton|protonmail|yahoo|live|me)\.[a-z.]{2,}")),
    ("public IPv4", re.compile(r"(?<![\d.])(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?![\d.])")),
    ("tailnet name", re.compile(r"[a-z0-9-]+\.ts\.net")),
    ("home path", re.compile(r"/(?:Users|home)/([A-Za-z0-9._-]+)/")),
]
FAKE = re.compile(r"FAKE|PLANTED|EXAMPLE|DUMMY", re.I)


def key_body_follows(lines, i):
    """True when a key header (line i, 1-based) is followed by base64 — on the
    next line, or on the same line after an escaped newline (a key kept as one
    JSON string) — i.e. this is key material, not a sentence that mentions the
    header."""
    same = lines[i - 1].split("PRIVATE KEY-----", 1)[1]
    if re.match(r"(?:\\r)?\\n[A-Za-z0-9+/=]{40,}", same):
        return True
    for nxt in lines[i:i + 3]:
        body = nxt.strip().strip("\"',\\n")
        if not body:
            continue
        return re.fullmatch(r"[A-Za-z0-9+/=]{40,}", body) is not None
    return False


def extra_literals():
    for base in (ROOT, os.getcwd()):
        p = os.path.join(base, ".public-scan.local")
        if os.path.isfile(p):
            with open(p, encoding="utf-8") as f:
                return [l.strip() for l in f if l.strip() and not l.startswith("#")]
    return []


SCANNED = [0]


def _walk_failed(err):
    raise SystemExit("public_scan: cannot read %s (%s) — nothing was verified" % (err.filename, err.strerror))


def findings():
    literals = extra_literals()
    for dirpath, dirs, files in os.walk(ROOT, onerror=_walk_failed):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for fn in sorted(files):
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, ROOT)
            if fn == ".public-scan.local" or rel == "scripts/public_scan.py":
                continue
            low = fn.lower()
            if low.endswith(BINARY):
                continue
            try:
                with open(full, encoding="utf-8", errors="replace") as f:
                    lines = f.read().splitlines()
            except OSError as e:
                yield rel, 0, "unreadable file", e.strerror or "could not be read"
                continue
            SCANNED[0] += 1
            for i, line in enumerate(lines, 1):
                for lit in literals:
                    if lit in line:
                        yield rel, i, "private literal", "(listed in .public-scan.local)"
                for name, rx in RULES:
                    if name == "public IPv4" and low.endswith(VECTOR):
                        continue                 # path data is full of dotted numbers
                    for m in rx.finditer(line):
                        hit = m.group(0)
                        if name == "private key block" and (rel in KNOWN_TEST_KEYS or not key_body_follows(lines, i)):
                            continue             # a listed test key, or the header named in prose
                        if name == "token" and FAKE.search(hit):
                            continue
                        if name == "public IPv4":
                            ip = m.group(1)
                            parts = ip.split(".")
                            if any(int(p) > 255 for p in parts) or DOC_NETS.match(ip):
                                continue
                            if re.search(r"version|v\d|\bOS\b|Chrome|Safari|macOS|iOS|\bSDK\b|Xcode", line, re.I) and int(parts[0]) < 40:
                                continue             # a dotted version number, not an address
                        if name == "home path":
                            who = m.group(1)
                            if who.lower() in PLACEHOLDER_USERS or len(who) == 1 or who.startswith((".", "$", "<", "{", "%", "…")):
                                continue             # /Users/me, /home/u, a sandbox's own home/.pervio
                        if name == "personal e-mail" and re.search(r"example|noreply|placeholder", hit, re.I):
                            continue
                        yield rel, i, name, hit[:6] + "…" if name in ("token", "personal e-mail") else hit[:60]


def main():
    if not os.path.isdir(ROOT):
        raise SystemExit("public_scan: %s is not a directory — nothing was verified" % ROOT)
    rows = list(findings())
    if not SCANNED[0]:
        raise SystemExit("public_scan: no file was read under %s — nothing was verified" % ROOT)
    for rel, i, name, hit in rows:
        print("%s:%d: %s: %s" % (rel, i, name, hit))
    if rows:
        print("\npublic_scan: %d finding(s) — fix them (a key made for a test goes on KNOWN_TEST_KEYS in this file)." % len(rows))
        sys.exit(1)
    print("public_scan: clean (%d files read under %s)" % (SCANNED[0], ROOT))


if __name__ == "__main__":
    main()
