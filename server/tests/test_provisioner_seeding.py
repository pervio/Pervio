#!/usr/bin/env python3
"""The provisioner's template seeding — the write-if-absent shell that copies
bundled seed templates into ~/.pervio/templates — EXECUTED for real against
fixture homes. The command skeletons are EXTRACTED from the Swift source
(interpolation holes substituted the way ServerProvisioner.shq would), so an
edit over there that breaks the shell turns this suite red — the same
cross-layer discipline as test_install's hash parity.

Pins: S0 extraction sane; S1 the probe lists only what's missing and inits the
dir; S2 an absent template decodes into place byte-exact, scratch swept;
S3 an existing file is NEVER touched (the user's edits win), scratch swept;
S4 cleanup removes the scratch dir.
"""
import base64
import os
import re
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SWIFT = os.path.join(HERE, "..", "..", "ios", "Sources", "Services",
                     "ServerProvisioner.swift")

results = []


def check(name, ok, detail=""):
    results.append(bool(ok))
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  [%s]" % (detail,)))


def shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


SRC = open(SWIFT, encoding="utf-8").read()


def pieces(block):
    """Swift string concatenation -> the runtime string pieces, unescaped."""
    raw = re.findall(r'"((?:[^"\\]|\\.)*)"', block)
    return [re.sub(r'\\(["\\])', r"\1", p) for p in raw]


def func_body(name, until):
    m = re.search(re.escape(name) + r"(.*?)" + re.escape(until), SRC, re.S)
    return m.group(1) if m else ""


# --- probe: prefix + per-name check joined by "; " (composed as Swift joins) ---
probe_body = func_body("func seedProbeCommand", "func seedChunkCommands")
probe_pieces = pieces(probe_body)
CHECK_TPL = next((p for p in probe_pieces if p.startswith("[ -e ")), "")
PREFIX = next((p for p in probe_pieces if p.startswith("mkdir -p ")), "")
SEP = "; " if 'separator: "; "' in probe_body else ""


def probe_cmd(names):
    checks = SEP.join(CHECK_TPL.replace("\\(shq($0))", shq(n)) for n in names)
    return PREFIX + checks


# --- upload: chunk-append skeleton + the guarded landing ---
# Anchors live INSIDE the seed chunker's body — "while offset" alone would
# find the bin chunker first and this suite would replay the wrong shell.
chunk_body = func_body("func seedChunkCommands", "static let seedCleanupCommand")
m = re.search(r'("mkdir -p ~/\.pervio/templates/\.seed.*?)\n\s*offset = end',
              chunk_body, re.S)
append_tpl = "".join(pieces(m.group(1))) if m else ""
m = re.search(r'("if \[ ! -e.*?)\n\s*return cmds', chunk_body, re.S)
land_tpl = "".join(pieces(m.group(1))) if m else ""
m = re.search(r'seedCleanupCommand = "([^"]+)"', SRC)
CLEANUP = m.group(1) if m else ""


def upload_cmds(name, data):
    b64 = base64.b64encode(data).decode()
    app = append_tpl.replace("\\(shq(chunk))", shq(b64)).replace("\\(shq(name))", shq(name))
    land = land_tpl.replace("\\(shq(name))", shq(name))
    return [app, land]


check("S0 skeletons extracted from Swift and look like the seeding",
      CHECK_TPL and PREFIX and SEP and "printf '%s'" in append_tpl
      and "templates/.seed" in append_tpl
      and land_tpl.startswith("if [ ! -e ~/.pervio/templates/")
      and "mv -n" in land_tpl and "rm -f" in land_tpl
      and CLEANUP.startswith("rm -rf ~/.pervio/templates/.seed"),
      "check=%r prefix=%r land=%r" % (CHECK_TPL[:40], PREFIX, land_tpl[:60]))


def run_in(home, cmd):
    return subprocess.run(["bash", "-c", cmd], env=dict(os.environ, HOME=home),
                          capture_output=True, text=True, timeout=20)


def fixture(present=()):
    home = tempfile.mkdtemp(prefix="seed-")
    if present:
        os.makedirs(os.path.join(home, ".pervio", "templates"))
        for name, body in present:
            with open(os.path.join(home, ".pervio", "templates", name), "w") as f:
                f.write(body)
    return home


# S1: probe lists only the missing, and inits the dir on a fresh home.
home = fixture(present=[("x.json", "{}")])
out = run_in(home, probe_cmd(["x.json", "y.json"]))
check("S1a probe lists only the missing template",
      out.stdout == "y.json\n", repr(out.stdout) + out.stderr)
fresh = fixture()
out = run_in(fresh, probe_cmd(["x.json", "y.json"]))
check("S1b fresh home: everything missing, dir created",
      out.stdout == "x.json\ny.json\n"
      and os.path.isdir(os.path.join(fresh, ".pervio", "templates")),
      repr(out.stdout) + out.stderr)

# S2: absent -> decoded into place byte-exact; per-file scratch swept.
body = '{"名":"值\'quote","n":1}\n'
home = fixture(present=[("x.json", "{}")])
for cmd in upload_cmds("y.json", body.encode()):
    out = run_in(home, cmd)
dst = os.path.join(home, ".pervio", "templates", "y.json")
scr = os.path.join(home, ".pervio", "templates", ".seed")
check("S2a missing template lands byte-exact",
      os.path.exists(dst) and open(dst, encoding="utf-8").read() == body,
      out.stderr)
check("S2b per-file scratch swept after landing",
      not os.listdir(scr) if os.path.isdir(scr) else True,
      str(os.listdir(scr)) if os.path.isdir(scr) else "no scratch dir")

# S3: present -> NEVER touched, even with scratch staged; scratch swept.
home = fixture(present=[("y.json", "USER EDITED")])
for cmd in upload_cmds("y.json", body.encode()):
    out = run_in(home, cmd)
dst = os.path.join(home, ".pervio", "templates", "y.json")
check("S3 an existing template survives the seeding untouched",
      open(dst, encoding="utf-8").read() == "USER EDITED", out.stderr)
scr = os.path.join(home, ".pervio", "templates", ".seed")
check("S3b scratch swept on the guarded-skip path too",
      not os.listdir(scr) if os.path.isdir(scr) else True,
      str(os.listdir(scr)) if os.path.isdir(scr) else "")

# S4: cleanup removes the scratch dir wholesale.
out = run_in(home, CLEANUP)
check("S4 cleanup removes ~/.pervio/templates/.seed",
      not os.path.isdir(scr), out.stderr)

print()
ok = all(results)
print("test_provisioner_seeding:", ("OK (%d checks)" % len(results)) if ok
      else "FAILED (%d/%d)" % (sum(results), len(results)))
raise SystemExit(0 if ok else 1)
