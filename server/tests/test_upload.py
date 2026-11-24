#!/usr/bin/env python3
"""Regression tests for server/bin/pervio-upload (chunked base64 file receive).
Hermetic isolated $HOME. Asserts init→finish round-trip, filename sanitization,
temp-file containment (no writing/decoding outside ~/.pervio/uploads), and the
size caps.

Plus the robustness half (D2/D3), all of which used to end in a file the model
would read as the user's document:
  * a damaged stream (a remote shell's stderr landing among the chunks) decoded
    LENIENTLY into different bytes and was reported as a successful upload —
    decoding is strict now, line breaks still tolerated;
  * a truncated transfer is valid base64, so the decoded SIZE is declared at
    init, travels inside the token, and is enforced at finish (a client cannot
    revise it later);
  * --tmp was resolved twice (check, then open), so a symlink swapped between
    the two resolutions redirected the read — the temp is now opened
    O_NOFOLLOW against a directory fd, and the .part destination is created
    O_EXCL|O_NOFOLLOW so a planted symlink can't be written through."""
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
UPLOAD = os.path.realpath(os.path.join(HERE, "..", "bin", "pervio-upload"))

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + (("  [" + str(detail)[:200] + "]") if (detail and not cond) else ""))


def up(home, *args):
    e = dict(os.environ, HOME=home)
    p = subprocess.run([sys.executable, UPLOAD] + list(args), env=e, capture_output=True, text=True)
    try:
        return json.loads(p.stdout), p
    except json.JSONDecodeError:
        return None, p


def fresh():
    return tempfile.mkdtemp(prefix="pup_home_", dir="/tmp")


# ---------- init ----------
print("=== init ===")
home = fresh()
o, _ = up(home, "init")
check("init returns tmp/token/dir", all(k in o for k in ("tmp", "token", "dir")), o)
check("init tmp is a .b64 under uploads", o["tmp"].endswith(".b64") and o["tmp"].startswith(os.path.join(home, ".pervio", "uploads")), o["tmp"])
check("init created the temp file", os.path.isfile(o["tmp"]))
import stat
check("uploads dir is 0700", stat.S_IMODE(os.stat(o["dir"]).st_mode) == 0o700, oct(stat.S_IMODE(os.stat(o["dir"]).st_mode)))

# ---------- finish round-trip ----------
print("=== finish round-trip ===")
content = b"hello upload \xf0\x9f\x98\x80 bytes"       # includes multibyte
with open(o["tmp"], "w") as f:
    f.write(base64.b64encode(content).decode())
fin, _ = up(home, "finish", "--tmp", o["tmp"], "--name", "My Report.txt")
check("finish returns path + bytes", "path" in fin and fin.get("bytes") == len(content), fin)
check("decoded file exists with exact content", os.path.isfile(fin["path"]) and open(fin["path"], "rb").read() == content)
check("temp .b64 removed after finish", not os.path.exists(o["tmp"]))
check("dest name sanitized (space→_, keeps ext)", os.path.basename(fin["path"]).endswith("My_Report.txt"), fin["path"])
shutil.rmtree(home, ignore_errors=True)

# ---------- filename can't traverse or carry slashes ----------
print("=== filename sanitization ===")
home = fresh()
o, _ = up(home, "init")
with open(o["tmp"], "w") as f:
    f.write(base64.b64encode(b"x").decode())
fin, _ = up(home, "finish", "--tmp", o["tmp"], "--name", "../../etc/passwd")
base = os.path.basename(fin["path"])
check("traversal name reduced to a safe basename", "/" not in base and ".." not in base and base.endswith("passwd"), fin)
check("dest stays inside uploads", os.path.realpath(fin["path"]).startswith(os.path.realpath(o["dir"]) + os.sep))
shutil.rmtree(home, ignore_errors=True)

# ---------- temp-file containment ----------
print("=== temp-file containment ===")
home = fresh()
up(home, "init")   # ensure uploads dir exists
marker = os.path.join(home, "OUTSIDE.secret")
with open(marker, "w") as f:
    f.write("SECRET")
# a --tmp pointing outside uploads must be refused (not read, not decoded)
for bad in (marker, "/etc/hosts", os.path.join(home, ".pervio", "uploads", "..", "..", "escape.b64")):
    fin, _ = up(home, "finish", "--tmp", bad, "--name", "x")
    ok = fin.get("error") == "bad temp file"
    results.append(ok)
    if not ok:
        print("FAIL containment: --tmp %r not refused [%s]" % (bad, fin))
print("PASS finish refuses any --tmp outside uploads/*.b64 (bad temp file)")
check("outside file untouched", open(marker).read() == "SECRET")
# a non-.b64 temp inside uploads is also refused
notb64 = os.path.join(home, ".pervio", "uploads", "nope.txt")
open(notb64, "w").write(base64.b64encode(b"x").decode())
fin, _ = up(home, "finish", "--tmp", notb64, "--name", "x")
check("finish refuses a non-.b64 temp", fin.get("error") == "bad temp file", fin)
shutil.rmtree(home, ignore_errors=True)

# ---------- size caps ----------
print("=== size caps ===")
home = fresh()
o, _ = up(home, "init")
# decoded 9 MB (> MAX_BYTES 8 MB); b64 is ~12 MB (== MAX_B64, not over) → caught by decoded cap
big = b"A" * (9 * 1024 * 1024)
with open(o["tmp"], "w") as f:
    f.write(base64.b64encode(big).decode())
fin, _ = up(home, "finish", "--tmp", o["tmp"], "--name", "big.bin")
check("oversize decoded file rejected", fin.get("error") == "file too large", fin)
check("oversize temp cleaned up", not os.path.exists(o["tmp"]))
# no giant dest left behind
dests = [f for f in os.listdir(o["dir"]) if not f.endswith(".b64")]
check("no decoded file written for an oversize upload", dests == [], dests)
shutil.rmtree(home, ignore_errors=True)

# ---------- base64 integrity (D2) ----------
# The bytes arrive as `printf '%s' <chunk> >> tmp` over SSH: anything the remote
# shell prints on a bad day lands in the SAME file. A lenient decode drops the
# characters it doesn't recognise and keeps going, so a damaged stream turns
# into a DIFFERENT file that is reported as a successful upload — and the model
# then reads it as the user's document.
print("=== base64 integrity ===")
home = fresh()
o, _ = up(home, "init")
payload = bytes(range(256)) * 2                       # 512 bytes, every value
enc = base64.b64encode(payload).decode()
# One chunk's printf failed and its stderr landed in the stream instead. The
# noise carries exactly 16 base64-alphabet characters, so the file stays
# 4-aligned and a lenient decode returns 524 bytes of garbage without a murmur.
noisy = enc[:100] + "printf: write error" + enc[100:]
with open(o["tmp"], "w") as f:
    f.write(noisy)
fin, _ = up(home, "finish", "--tmp", o["tmp"], "--name", "doc.bin")
check("a corrupt base64 stream is refused, not silently decoded",
      "path" not in fin and "corrupt" in str(fin.get("error", "")), fin)
dests = [f for f in os.listdir(o["dir"]) if not f.endswith(".b64")]
check("no file is written for a corrupt stream", dests == [], dests)
check("the corrupt temp is cleaned up", not os.path.exists(o["tmp"]))
shutil.rmtree(home, ignore_errors=True)

# …while the legitimate transfer shape stays legal: strict decoding must not
# break a client whose chunks arrive newline-separated.
home = fresh()
o, _ = up(home, "init")
with open(o["tmp"], "w") as f:
    f.write("\n".join(enc[i:i + 76] for i in range(0, len(enc), 76)) + "\n")
fin, _ = up(home, "finish", "--tmp", o["tmp"], "--name", "wrapped.bin")
check("newline-separated base64 still decodes (chunked transfer stays legal)",
      fin.get("bytes") == len(payload)
      and open(fin.get("path", os.devnull), "rb").read() == payload, fin)
shutil.rmtree(home, ignore_errors=True)

# ---------- declared byte count (D2) ----------
# A truncated transfer (the phone died between chunks) is still VALID base64 —
# nothing about the bytes says they are incomplete. The size is declared at
# init, travels in the token the client hands back, and finish refuses anything
# that doesn't decode to exactly that many bytes.
print("=== declared byte count ===")
home = fresh()
o, _ = up(home, "init", "--bytes", str(len(payload)))
check("init --bytes echoes the declared size", o.get("bytes") == len(payload), o)
check("init --bytes still returns a .b64 temp under uploads",
      str(o.get("tmp", "")).endswith(".b64") and os.path.isfile(o.get("tmp", "")), o)
with open(o["tmp"], "w") as f:
    f.write(enc[:200])                                # 200 chars -> 150 bytes
fin, _ = up(home, "finish", "--tmp", o["tmp"], "--name", "doc.bin")
check("a truncated upload is refused against the declared size",
      "path" not in fin and "size mismatch" in str(fin.get("error", "")), fin)
dests = [f for f in os.listdir(o["dir"]) if not f.endswith(".b64")]
check("no file is written for a short upload", dests == [], dests)
shutil.rmtree(home, ignore_errors=True)

home = fresh()
o, _ = up(home, "init", "--bytes", str(len(payload)))
with open(o["tmp"], "w") as f:
    f.write(enc)
fin, _ = up(home, "finish", "--tmp", o["tmp"], "--name", "doc.bin")
check("a complete upload passes the declared-size check",
      fin.get("bytes") == len(payload)
      and open(fin.get("path", os.devnull), "rb").read() == payload, fin)
check("the declared size never leaks into the visible filename",
      os.path.basename(fin.get("path", "")) == o["token"] + "-doc.bin", fin)
# A client cannot talk its way past the size the SERVER recorded at init.
o, _ = up(home, "init", "--bytes", str(len(payload)))
with open(o["tmp"], "w") as f:
    f.write(enc)
fin, _ = up(home, "finish", "--tmp", o["tmp"], "--name", "d.bin",
            "--bytes", str(len(payload) + 1))
check("finish --bytes cannot override the size declared at init",
      "path" not in fin and "size mismatch" in str(fin.get("error", "")), fin)
# Declared at finish only (no init declaration) still gets checked.
o, _ = up(home, "init")
with open(o["tmp"], "w") as f:
    f.write(enc)
fin, _ = up(home, "finish", "--tmp", o["tmp"], "--name", "d.bin", "--bytes", "999")
check("finish --bytes alone is honoured when init declared nothing",
      "path" not in fin and "size mismatch" in str(fin.get("error", "")), fin)
# An impossible declaration is refused BEFORE the phone uploads 12 MB.
bad, _ = up(home, "init", "--bytes", str(9 * 1024 * 1024))
check("init refuses a declaration over the decoded cap, before any transfer",
      bad.get("error") == "file too large" and "tmp" not in bad, bad)
bad, _ = up(home, "init", "--bytes", "-1")
check("init refuses a nonsense declaration", "tmp" not in bad, bad)
shutil.rmtree(home, ignore_errors=True)

# ---------- temp identity: no symlink, no planted name (D3) ----------
# finish used to resolve --tmp TWICE (once to containment-check it, once to open
# it), so a symlink swapped between the two resolutions redirected the read
# outside the uploads dir — the classic check/use race, and the primitive it
# needs is a symlink sitting at the final path component. The temp is now opened
# with O_NOFOLLOW relative to a directory fd captured once, so a symlink is
# refused outright and there is no second resolution left to win. (Limitation:
# this pins the property that makes the race unwinnable; the microsecond swap
# itself is not deterministically reproducible in a test.)
print("=== temp identity ===")
home = fresh()
o, _ = up(home, "init")
with open(o["tmp"], "w") as f:
    f.write(base64.b64encode(b"real payload").decode())
link = os.path.join(o["dir"], "0" * 32 + ".b64")       # realpath lands INSIDE uploads
os.symlink(o["tmp"], link)
fin, _ = up(home, "finish", "--tmp", link, "--name", "x")
check("a symlink temp inside uploads is refused (never followed)",
      fin.get("error") == "bad temp file", fin)
check("the real temp survives an attempt made through the symlink",
      os.path.isfile(o["tmp"]))
planted = os.path.join(o["dir"], "not-a-real-token.b64")
with open(planted, "w") as f:
    f.write(base64.b64encode(b"x").decode())
fin, _ = up(home, "finish", "--tmp", planted, "--name", "x")
check("a .b64 name this tool never minted is refused",
      fin.get("error") == "bad temp file", fin)
check("the planted file is left alone", os.path.isfile(planted))
shutil.rmtree(home, ignore_errors=True)

# ---------- the decoded write never follows a symlink (D3) ----------
# Uploads live in a shared-host home; the .part name finish is about to write is
# derivable from the token. Planting a symlink there used to make the decode
# write THROUGH it and clobber whatever it pointed at.
print("=== destination write ===")
home = fresh()
o, _ = up(home, "init")
secret = os.path.join(home, "OUTSIDE.key")
with open(secret, "w") as f:
    f.write("PRIVATE KEY")
os.symlink(secret, os.path.join(o["dir"], o["token"] + "-doc.txt.part"))
with open(o["tmp"], "w") as f:
    f.write(base64.b64encode(b"uploaded body").decode())
fin, _ = up(home, "finish", "--tmp", o["tmp"], "--name", "doc.txt")
check("an outside file symlinked as the .part destination is NOT overwritten",
      open(secret).read() == "PRIVATE KEY", open(secret).read()[:60])
check("the upload still lands as a real file inside uploads",
      "path" in fin and os.path.isfile(fin["path"])
      and not os.path.islink(fin["path"])
      and open(fin["path"], "rb").read() == b"uploaded body", fin)
shutil.rmtree(home, ignore_errors=True)

# ---------- abort ----------
print("=== abort ===")
home = fresh()
o, _ = up(home, "init")
ab, _ = up(home, "abort", "--tmp", o["tmp"])
check("abort removes the temp", ab.get("aborted") is True and not os.path.exists(o["tmp"]), ab)
ab2, _ = up(home, "abort", "--tmp", "/etc/hosts")
check("abort refuses a temp outside uploads", ab2.get("aborted") is False)
shutil.rmtree(home, ignore_errors=True)

ok = all(results)
print("\n=== pervio-upload: %s (%d/%d) ===" % ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
