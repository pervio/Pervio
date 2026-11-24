#!/usr/bin/env python3
"""Regression tests for server/install.sh — the one script whose mistakes are
irrecoverable (it overwrites the launcher dir a live server runs from, and it
rewrites the Claude credentials file).

Hermetic: every run uses a throwaway $HOME under /tmp, a throwaway COPY of the
repo, and a PATH whose first entry holds a fake `security` binary. The real
Keychain is never queried and the real ~/.pervio, ~/.pervio, ~/.claude are never
touched — run_install() refuses to start if $HOME isn't a temp dir.

Covers:
  A1 idempotence   — installing twice changes nothing (bytes AND modes)
  A2 half-install  — a missing/unreadable source must leave the OLD install
                     completely intact; never a new+old mix
  A3 seeding       — a user's ~/.pervio/templates file is never overwritten
  A4 credentials   — Keychain hit / miss / empty, and an interrupted write must
                     not truncate (or expose) the existing credentials file
"""
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
SERVER = os.path.realpath(os.path.join(HERE, ".."))
INSTALL_SRC = os.path.join(SERVER, "install.sh")
REAL_HOME = os.path.realpath(os.path.expanduser("~"))
IS_DARWIN = platform.system() == "Darwin"

results = []
_tmp_roots = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name +
          (("  [" + str(detail)[:400] + "]") if (detail and not cond) else ""))


def skip(name, why):
    print("SKIP " + name + "  (" + why + ")")


# ---------------------------------------------------------------- sandboxing
def mktmp(prefix):
    d = tempfile.mkdtemp(prefix=prefix, dir="/tmp")
    _tmp_roots.append(d)
    return d


def guard_home(home):
    """Hard stop: never let a test point install.sh at a real home."""
    rh = os.path.realpath(home)
    if not (rh.startswith("/tmp/") or rh.startswith("/private/tmp/")):
        raise SystemExit("REFUSING: install HOME %r is not under /tmp" % rh)
    if rh == REAL_HOME or REAL_HOME.startswith(rh + os.sep):
        raise SystemExit("REFUSING: install HOME %r contains the real home" % rh)


SECURITY_SHIM = r"""#!/bin/sh
# Fake `security(1)`. NEVER touches the real Keychain. Logs its argv so the test
# can prove install.sh asked *us* and not /usr/bin/security.
printf '%s\n' "$*" >> "$FAKE_SEC_LOG"
case "${FAKE_SEC:-fail}" in
  ok)    cat "$FAKE_SEC_CRED"; exit 0 ;;
  empty) exit 0 ;;
  fail)  echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; exit 44 ;;
  *)     echo "fake security: unknown mode ${FAKE_SEC}" >&2; exit 99 ;;
esac
"""


# How many templates install.sh seeds — derived from the real repo dir, so
# adopting a new template into server/templates doesn't re-break these pins.
N_TPL = len([f for f in os.listdir(os.path.join(SERVER, "templates"))
             if f.endswith(".json")])


def make_repo(build="v1"):
    """A throwaway copy of server/ (install.sh + bin/ + templates/).

    `build` stamps every payload file so a test can tell "the bytes that were
    already installed" apart from "the bytes this run would install".
    """
    d = mktmp("pinst_repo_")
    shutil.copy2(INSTALL_SRC, os.path.join(d, "install.sh"))
    shutil.copytree(os.path.join(SERVER, "bin"), os.path.join(d, "bin"),
                    ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copytree(os.path.join(SERVER, "templates"), os.path.join(d, "templates"))
    if build != "v1":
        for name in sorted(os.listdir(os.path.join(d, "bin"))):
            p = os.path.join(d, "bin", name)
            if not os.path.isfile(p):
                continue
            os.chmod(p, 0o644)
            with open(p, "a") as f:
                f.write("\n# PERVIO-TEST-BUILD %s\n" % build)
        for name in sorted(os.listdir(os.path.join(d, "templates"))):
            p = os.path.join(d, "templates", name)
            obj = json.load(open(p))
            obj["_pervio_test_build"] = build
            with open(p, "w") as f:
                json.dump(obj, f)
    return d


def run_install(repo, home, sec="fail", cred="", ulimit_blocks=None, timeout=300):
    guard_home(home)
    shim = os.path.join(repo, "_shim")
    os.makedirs(shim, exist_ok=True)
    credf = os.path.join(shim, "cred.txt")
    with open(credf, "w") as f:
        f.write(cred)
    log = os.path.join(shim, "security.log")
    secpath = os.path.join(shim, "security")
    with open(secpath, "w") as f:
        f.write(SECURITY_SHIM)
    os.chmod(secpath, 0o755)
    tmpdir = os.path.join(home, ".tmp")
    os.makedirs(tmpdir, exist_ok=True)
    env = {
        "HOME": home,
        "PATH": shim + ":/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": tmpdir,
        "LANG": "C",
        "FAKE_SEC": sec,
        "FAKE_SEC_CRED": credf,
        "FAKE_SEC_LOG": log,
    }
    script = os.path.join(repo, "install.sh")
    if ulimit_blocks is None:
        cmd = ["bash", script]
    else:
        # Inject a hard failure *in the middle of a write*: RLIMIT_FSIZE. Any
        # write past the limit kills the writer with SIGXFSZ — exactly what a
        # full disk / killed session looks like to a half-written file.
        cmd = ["bash", "-c", "ulimit -f %d; exec bash %s" % (ulimit_blocks, script)]
    p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout)
    p.seclog = open(log).read() if os.path.exists(log) else ""
    return p


def snap(root):
    """relpath -> (bytes, mode) for every file under root."""
    out = {}
    for dirpath, _dirs, files in os.walk(root):
        for fn in files:
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, root)
            out[rel] = (open(p, "rb").read(), stat.S_IMODE(os.lstat(p).st_mode))
    return out


def mode_of(p):
    return stat.S_IMODE(os.lstat(p).st_mode)


DEST = os.path.join(".pervio", "bin")


def payload_sources():
    """(mode, repo-relative source) for everything install.sh ships.

    Understands both the `payload=( "0755 name" ... )` manifest and the older
    one-`install`-line-per-file form, so this suite still reads the payload if
    install.sh is reverted (which is exactly what mutation-proving does)."""
    txt = open(INSTALL_SRC).read()
    out = []
    m = re.search(r'^payload=\(\s*$(.*?)^\)\s*$', txt, re.M | re.S)
    if m:
        for line in m.group(1).splitlines():
            e = re.match(r'\s*"(\d+) ([^"]+)"\s*$', line)
            if e:
                out.append((e.group(1), e.group(2)))
    for e in re.finditer(r'^\s*install -m (\d+) "\$here/([^"]+)"', txt, re.M):
        out.append((e.group(1), e.group(2)))
    return out


# =========================================================== A0 manifest sanity
print("=== A0: install.sh's payload list ===")
srcs = payload_sources()
check("install.sh names a non-trivial payload", len(srcs) >= 10, len(srcs))
missing = [s for _m, s in srcs if not os.path.exists(os.path.join(SERVER, s))]
check("every source install.sh copies exists in the repo", missing == [], missing)

# ================================================================ A1 idempotence
print("=== A1: installing twice changes nothing ===")
repo = make_repo("v1")
home = mktmp("pinst_home_")
p1 = run_install(repo, home)
check("first install exits 0", p1.returncode == 0, p1.stderr[-400:])
dest = os.path.join(home, DEST)
s1 = snap(dest)
check("payload landed in ~/.pervio/bin (plus the rev stamp)",
      len(s1) == len(srcs) + 1, sorted(s1))
bad = []
for mode, rel in srcs:
    name = os.path.basename(rel)
    want = open(os.path.join(repo, rel), "rb").read()
    got = s1.get(name)
    if got is None or got[0] != want or got[1] != int(mode, 8):
        bad.append(name)
check("each installed file has the source's exact bytes and mode", bad == [], bad)

tpl_before = snap(os.path.join(home, ".pervio", "templates"))
p2 = run_install(repo, home)
check("second install exits 0", p2.returncode == 0, p2.stderr[-400:])
s2 = snap(dest)
check("re-install: same set of files", sorted(s1) == sorted(s2),
      set(s1) ^ set(s2))
diff = [k for k in s1 if s1[k] != s2.get(k)]
check("re-install: every file byte-identical and same mode", diff == [], diff)
# Compare the templates as they were BEFORE this second install to how they are
# AFTER it. Snapshotting twice after the fact compared a value to itself and
# passed even when seeding overwrote every user template.
tpl_after = snap(os.path.join(home, ".pervio", "templates"))
check("re-install: seeded templates byte-identical too",
      tpl_before == tpl_after and len(tpl_after) == N_TPL, sorted(tpl_after))

# ================================================== A2 no half-installed state
print("=== A2: a broken source must not leave a new+old mix ===")
for label, breaker in (("missing", "unlink"), ("unreadable", "chmod000")):
    home = mktmp("pinst_home_")
    good = make_repo("v1")
    p = run_install(good, home)
    assert p.returncode == 0, p.stderr
    before = snap(os.path.join(home, DEST))
    check("A2/%s: baseline install is complete" % label,
          len(before) == len(srcs) + 1, sorted(before))

    broken = make_repo("v2")
    # break a source in the MIDDLE of install.sh's list: everything before it
    # would already have been overwritten by a non-staged installer.
    victim_rel = srcs[len(srcs) // 2][1]
    victim = os.path.join(broken, victim_rel)
    if breaker == "unlink":
        os.unlink(victim)
    else:
        os.chmod(victim, 0o000)
    p = run_install(broken, home)
    if breaker == "chmod000":
        os.chmod(victim, 0o644)

    check("A2/%s: install exits non-zero" % label, p.returncode != 0,
          "rc=%s out=%s err=%s" % (p.returncode, p.stdout[-200:], p.stderr[-200:]))
    out = p.stdout + p.stderr
    check("A2/%s: the error names the unusable source" % label,
          os.path.basename(victim_rel) in out, out[-400:])

    after = snap(os.path.join(home, DEST))
    upgraded = sorted(k for k in before if k in after and after[k] != before[k])
    check("A2/%s: NOT ONE installed file was replaced (no new/old mix)" % label,
          upgraded == [], upgraded)
    lost = sorted(k for k in before if k not in after)
    check("A2/%s: the previous install is still complete" % label, lost == [], lost)
    junk = sorted(f for f in os.listdir(os.path.join(home, DEST))
                  if f not in {os.path.basename(s) for _m, s in srcs}
                  and f != ".pervio-rev")   # the revision stamp is contract, not junk
    check("A2/%s: the failed run left no scratch dir in the launcher dir" % label,
          junk == [], junk)

# a run killed before its cleanup (SIGKILL) can't tidy up; the next install must
print("=== A2: stale staging debris is swept, not accumulated ===")
home = mktmp("pinst_home_")
p = run_install(make_repo("v1"), home)
assert p.returncode == 0, p.stderr
stale = os.path.join(home, DEST, ".staging.deadrun")
os.makedirs(stale)
with open(os.path.join(stale, "pervio-chat"), "w") as f:
    f.write("half-copied corpse")
p = run_install(make_repo("v1"), home)
check("A2/stale: install still exits 0", p.returncode == 0, p.stderr[-300:])
check("A2/stale: the abandoned staging dir is gone", not os.path.exists(stale),
      sorted(os.listdir(os.path.join(home, DEST))))
check("A2/stale: the launcher dir holds only the payload (plus the rev stamp)",
      sorted(os.listdir(os.path.join(home, DEST))) ==
      sorted({os.path.basename(s) for _m, s in srcs} | {".pervio-rev"}),
      sorted(os.listdir(os.path.join(home, DEST))))

# ================================================ A3 user templates are sacred
print("=== A3: seeding never eats a user's template ===")
home = mktmp("pinst_home_")
repo1 = make_repo("v1")
p = run_install(repo1, home)
assert p.returncode == 0, p.stderr
tpl = os.path.join(home, ".pervio", "templates")
seeded = sorted(os.listdir(tpl))
check("A3: fresh home gets the repo templates", len(seeded) == N_TPL, seeded)

mine = json.dumps({"name": "my tuned deep audit", "model": "opus"}).encode()
with open(os.path.join(tpl, "deep-audit.json"), "wb") as f:
    f.write(mine)
with open(os.path.join(tpl, "only-mine.json"), "wb") as f:
    f.write(b'{"name":"only mine"}')

repo2 = make_repo("v2")   # repo templates now differ from what was seeded
with open(os.path.join(repo2, "templates", "brand-new.json"), "w") as f:
    f.write('{"name":"brand new"}')
p = run_install(repo2, home)
check("A3: re-install exits 0", p.returncode == 0, p.stderr[-300:])
check("A3: the user's edited template keeps the USER's bytes",
      open(os.path.join(tpl, "deep-audit.json"), "rb").read() == mine)
check("A3: an untouched seeded template is also left alone (not re-stamped)",
      b"_pervio_test_build" not in open(os.path.join(tpl, "mini-survey.json"), "rb").read())
check("A3: a user-only template survives", os.path.exists(os.path.join(tpl, "only-mine.json")))
check("A3: a genuinely new repo template is still seeded",
      os.path.exists(os.path.join(tpl, "brand-new.json")))
check("A3: output says the existing one was left as-is",
      "deep-audit.json already in" in p.stdout, p.stdout[-300:])

# ====================================================== A4 credentials writing
print("=== A4: Keychain -> ~/.claude/.credentials.json ===")
OLD = b'{"claudeAiOauth":{"accessToken":"OLD-TOKEN-do-not-lose-me"}}'


def with_old_creds():
    home = mktmp("pinst_home_")
    os.makedirs(os.path.join(home, ".claude"))
    p = os.path.join(home, ".claude", ".credentials.json")
    with open(p, "wb") as f:
        f.write(OLD)
    os.chmod(p, 0o600)
    return home, p


if not IS_DARWIN:
    skip("A4 credential sync", "install.sh only syncs the Keychain on Darwin")
else:
    repo = make_repo("v1")

    # --- (a) Keychain hit -----------------------------------------------
    home, credp = with_old_creds()
    NEW = '{"claudeAiOauth":{"accessToken":"NEW-TOKEN"}}'
    p = run_install(repo, home, sec="ok", cred=NEW)
    check("A4a: exits 0", p.returncode == 0, p.stderr[-300:])
    check("A4a: the fake security shim served the lookup (real Keychain untouched)",
          "find-generic-password" in p.seclog and "Claude Code-credentials" in p.seclog, p.seclog)
    check("A4a: credentials replaced with the Keychain value",
          open(credp, "rb").read() == NEW.encode(), open(credp, "rb").read()[:80])
    check("A4a: mode is 0600", mode_of(credp) == 0o600, oct(mode_of(credp)))

    # --- (b) Keychain miss ----------------------------------------------
    home, credp = with_old_creds()
    p = run_install(repo, home, sec="fail")
    check("A4b: exits 0 on a Keychain miss", p.returncode == 0, p.stderr[-300:])
    check("A4b: the OLD credentials are byte-identical", open(credp, "rb").read() == OLD)
    check("A4b: mode still 0600", mode_of(credp) == 0o600, oct(mode_of(credp)))
    check("A4b: says it left them as-is", "left as-is" in p.stdout, p.stdout[-300:])

    # --- (c) Keychain returns empty -------------------------------------
    home, credp = with_old_creds()
    p = run_install(repo, home, sec="empty")
    check("A4c: exits 0 on an empty Keychain value", p.returncode == 0, p.stderr[-300:])
    check("A4c: the OLD credentials are byte-identical", open(credp, "rb").read() == OLD)
    check("A4c: mode still 0600", mode_of(credp) == 0o600, oct(mode_of(credp)))

    # --- (d) nothing anywhere -------------------------------------------
    home = mktmp("pinst_home_")
    p = run_install(repo, home, sec="fail")
    check("A4d: exits 0 with no creds at all", p.returncode == 0, p.stderr[-300:])
    check("A4d: no credentials file conjured out of nothing",
          not os.path.exists(os.path.join(home, ".claude", ".credentials.json")))
    check("A4d: tells the user to /login", "NONE found" in p.stdout, p.stdout[-300:])

    # --- (e) the write is CUT SHORT (disk full / killed session) ---------
    # RLIMIT_FSIZE = 256 KB: every payload file fits (largest is ~122 KB) but the
    # 1 MB credential blob does not, so the writer dies mid-write. The existing
    # credentials must survive untouched — this is the irrecoverable one.
    home, credp = with_old_creds()
    big = "X" * (1024 * 1024)
    p = run_install(repo, home, sec="ok", cred=big, ulimit_blocks=512)
    check("A4e: the payload still installed before the cred step",
          len(snap(os.path.join(home, DEST))) == len(srcs) + 1,
          sorted(snap(os.path.join(home, DEST))))
    check("A4e: install reports failure when the cred write is cut short",
          p.returncode != 0, "rc=%s err=%s" % (p.returncode, p.stderr[-200:]))
    got = open(credp, "rb").read()
    check("A4e: the OLD credentials are byte-identical after the interrupted write",
          got == OLD, "len=%d head=%r" % (len(got), got[:60]))
    check("A4e: credentials never left group/world readable",
          mode_of(credp) == 0o600, oct(mode_of(credp)))
    leftovers = sorted(f for f in os.listdir(os.path.join(home, ".claude"))
                       if f != ".credentials.json")
    check("A4e: no half-written temp left behind in ~/.claude", leftovers == [], leftovers)

    # --- (f) same interruption, but no credentials file existed yet ------
    # The danger here is the other one: a fresh `>` creates the file with the
    # umask's 0644 and only chmods it AFTER the write, so a write that dies
    # leaves a chunk of a live OAuth token readable by every account on the box.
    home = mktmp("pinst_home_")
    p = run_install(repo, home, sec="ok", cred=big, ulimit_blocks=512)
    claude_dir = os.path.join(home, ".claude")
    spilled = []
    for f in (os.listdir(claude_dir) if os.path.isdir(claude_dir) else []):
        fp = os.path.join(claude_dir, f)
        if os.path.isfile(fp) and (mode_of(fp) & 0o077) and open(fp, "rb").read(1) == b"X":
            spilled.append((f, oct(mode_of(fp))))
    check("A4f: an interrupted first write leaks no group/world-readable token",
          spilled == [], spilled)
    check("A4f: no truncated stub is left as the real credentials file",
          not os.path.exists(os.path.join(claude_dir, ".credentials.json")),
          os.path.getsize(os.path.join(claude_dir, ".credentials.json"))
          if os.path.exists(os.path.join(claude_dir, ".credentials.json")) else "")

# ================================================ AR the revision stamp
# The app↔server handshake (ServerProvisioner) compares content hashes computed
# in THREE places: install.sh (shell, shasum), the app (Swift, CryptoKit), and
# here (python, hashlib). Canon: per payload file in sorted-name order, feed
# "name NUL content NUL" into SHA-256, keep 16 hex. Drift in any implementation
# is silent in production (endless repaves, or never repaving) — this section
# pins the shell one; ServerProvisionerTests pins Swift against the same bytes.
print("=== AR: .pervio-rev is the payload's content hash ===")
import hashlib                                                        # noqa: E402
home = mktmp("pinst_home_")
p = run_install(make_repo("v1"), home)
check("AR install ok", p.returncode == 0, p.stderr[-200:])
rev_path = os.path.join(home, DEST, ".pervio-rev")
check("AR the stamp exists after install", os.path.exists(rev_path))
_h = hashlib.sha256()
for _name in sorted(os.path.basename(s) for _m, s in srcs):
    _h.update(_name.encode()); _h.update(b"\0")
    with open(os.path.join(home, DEST, _name), "rb") as _f:
        _h.update(_f.read())
    _h.update(b"\0")
_want = _h.hexdigest()[:16]
_got = open(rev_path).read().strip()
check("AR the shell stamp equals python's canonical hash", _got == _want,
      (_got, _want))
check("AR 16 lowercase hex", re.fullmatch(r"[0-9a-f]{16}", _got) is not None, _got)
# Same payload → same stamp on a re-run (the handshake's stability half).
p = run_install(make_repo("v1"), home)
check("AR reinstalling the same payload keeps the stamp",
      p.returncode == 0 and open(rev_path).read().strip() == _got,
      open(rev_path).read().strip())

# ----------------------------------------------------------------- teardown
for d in _tmp_roots:
    shutil.rmtree(d, ignore_errors=True)

ok = all(results)
print("\n=== install.sh: %s (%d/%d) ===" %
      ("ALL PASS ✅" if ok else "FAILURES ❌", sum(results), len(results)))
sys.exit(0 if ok else 1)
