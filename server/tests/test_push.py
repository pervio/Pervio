#!/usr/bin/env python3
"""test_push.py — no-cost regression suite for the APNs push path.

Covers, all hermetic (temp $HOME, temp keys, NO real network — there is no APNs key
and we never contact Apple):

  A. JWT construction: header/claims are the exact ES256/kid/iss/iat shape, the
     signature is a real 64-byte r||s that VERIFIES against the key's public half
     (via openssl), and a fresh token is cached and reused for <50 min.
  B. Graceful no-key degrade: `send` with no key (and with a key but no token)
     EXITS 0 and prints one stderr line — the contract the orchestrate hooks rely
     on so a missing key never turns a real event into a hook failure.
  C. dry-run request shape: host / path / method / every header / the JSON payload,
     asserted item by item, in both production and --sandbox, for a thread and no
     thread. The real signing key is present so the dump is faithful (JWT redacted).
  D. Hooks fire: a FAKE `pervio-push` on PATH records its argv; driving
     pervio-orchestrate to a published issue and to a failed run, and driving
     pervio-approve through a permission request, each invokes it with the right
     title/body.

Run directly (`python3 test_push.py`); exits 0 iff every check passes. Registered
in server/tests/run_all.sh SUITES.
"""
import base64
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.realpath(__file__))
BIN = os.path.realpath(os.path.join(HERE, "..", "bin"))
PUSH = os.path.join(BIN, "pervio-push")
ORCH = os.path.join(BIN, "pervio-orchestrate")
APPROVE = os.path.join(BIN, "pervio-approve")

results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name
          + (("  [" + str(detail)[:240] + "]") if (detail and not cond) else ""))


def fresh_home():
    return tempfile.mkdtemp(prefix="tpush_home_", dir="/tmp")


def make_test_key(apns_dir, key_id="TEST123456", team_id="TEAM123456"):
    """Generate a throwaway P-256 .p8 + key_id/issuer_id in apns_dir. Returns the
    key path. A fresh key per run keeps the suite hermetic and commits no secret."""
    os.makedirs(apns_dir, mode=0o700, exist_ok=True)
    ec = os.path.join(apns_dir, "ec.key")
    p8 = os.path.join(apns_dir, "AuthKey_%s.p8" % key_id)
    subprocess.run(["openssl", "ecparam", "-genkey", "-name", "prime256v1",
                    "-noout", "-out", ec], check=True, capture_output=True)
    subprocess.run(["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", ec, "-out", p8],
                   check=True, capture_output=True)
    os.remove(ec)
    with open(os.path.join(apns_dir, "key_id"), "w") as f:
        f.write(key_id)
    with open(os.path.join(apns_dir, "issuer_id"), "w") as f:
        f.write(team_id)
    return p8, key_id, team_id


def load_module(home):
    """Import pervio-push as a module with its HOME-derived paths pinned to `home`.
    (The file has no .py extension, so use a SourceFileLoader.)"""
    loader = importlib.machinery.SourceFileLoader("pervio_push_mod", PUSH)
    spec = importlib.util.spec_from_loader("pervio_push_mod", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    mod.HOME = home
    mod.APNS_DIR = os.path.join(home, ".pervio", "apns")
    mod.TOKENS_DIR = os.path.join(home, ".pervio", "push", "tokens")
    mod.JWT_CACHE = os.path.join(mod.APNS_DIR, ".jwt_cache.json")
    return mod


def b64url_decode(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def run_push(home, *args, extra_env=None, timeout=30):
    """Invoke pervio-push as a subprocess with $HOME pinned. Returns CompletedProcess."""
    env = dict(os.environ, HOME=home)
    if extra_env:
        env.update(extra_env)
    return subprocess.run([sys.executable, PUSH] + list(args),
                          env=env, capture_output=True, text=True, timeout=timeout)


# ===========================================================================
print("=== A. JWT construction + signature verifies ===")
# ===========================================================================
home = fresh_home()
try:
    apns = os.path.join(home, ".pervio", "apns")
    p8, key_id, team_id = make_test_key(apns)
    mod = load_module(home)

    key = mod.find_key()
    check("find_key locates the .p8 + key_id + team_id", key is not None, key)
    if key:
        kp, kid, team = key
        check("find_key returns the key_id from the file", kid == key_id, kid)
        check("find_key returns the team id as issuer", team == team_id, team)

        jwt = mod.make_jwt(kp, kid, team)
        parts = jwt.split(".")
        check("JWT has three dot-separated parts", len(parts) == 3, jwt[:40])

        header = json.loads(b64url_decode(parts[0]))
        claims = json.loads(b64url_decode(parts[1]))
        check("JWT header alg is ES256", header.get("alg") == "ES256", header)
        check("JWT header kid is the key id", header.get("kid") == key_id, header)
        check("JWT claims iss is the team id", claims.get("iss") == team_id, claims)
        check("JWT claims iat is an int seconds timestamp",
              isinstance(claims.get("iat"), int) and claims["iat"] > 1_600_000_000, claims)
        check("JWT header has no padding '='", "=" not in parts[0], parts[0])

        raw = b64url_decode(parts[2])
        check("JWT signature is raw 64-byte r||s (ES256, not DER)", len(raw) == 64, len(raw))

        # Reconstruct a DER signature from r||s and verify with openssl against the
        # key's public half — proves the bytes are a genuine ES256 signature of the
        # signing input, not just the right length.
        r, s = raw[:32], raw[32:]

        def der_int(b):
            b = b.lstrip(b"\x00") or b"\x00"
            if b[0] & 0x80:
                b = b"\x00" + b
            return b"\x02" + bytes([len(b)]) + b

        body = der_int(r) + der_int(s)
        der = b"\x30" + bytes([len(body)]) + body
        derf = os.path.join(home, "sig.der")
        inf = os.path.join(home, "sig.in")
        pubf = os.path.join(home, "pub.pem")
        with open(derf, "wb") as f:
            f.write(der)
        with open(inf, "wb") as f:
            f.write((parts[0] + "." + parts[1]).encode())
        subprocess.run(["openssl", "ec", "-in", kp, "-pubout", "-out", pubf],
                       check=True, capture_output=True)
        vr = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pubf,
                             "-signature", derf, inf], capture_output=True, text=True)
        check("ES256 signature verifies against the key's public half",
              "Verified OK" in vr.stdout, vr.stdout + vr.stderr)

        # Cache: a second mint returns the identical token; a stale cache re-signs.
        jwt2 = mod.make_jwt(kp, kid, team)
        check("a fresh JWT is cached and reused (identical token)", jwt2 == jwt)
        check("the JWT cache file is written 0600",
              (os.stat(mod.JWT_CACHE).st_mode & 0o777) == 0o600,
              oct(os.stat(mod.JWT_CACHE).st_mode & 0o777))
        with open(mod.JWT_CACHE) as f:
            c = json.load(f)
        c["iat"] = time.time() - (60 * 60)   # older than JWT_MAX_AGE
        with open(mod.JWT_CACHE, "w") as f:
            json.dump(c, f)
        jwt3 = mod.make_jwt(kp, kid, team)
        check("a stale cache (>50 min) mints a new token", jwt3 != jwt, "same token reused")
finally:
    shutil.rmtree(home, ignore_errors=True)


# ===========================================================================
print("\n=== B. graceful no-key / no-token degrade (exit 0 + one stderr line) ===")
# ===========================================================================
home = fresh_home()
try:
    # (B1) No key at all.
    p = run_push(home, "send", "--title", "T", "--body", "B")
    check("send with NO key exits 0", p.returncode == 0, "rc=%d" % p.returncode)
    check("send with NO key writes a reason to stderr", p.stderr.strip() != "", repr(p.stderr))
    check("send with NO key prints NOTHING to stdout (quiet no-op)", p.stdout == "", repr(p.stdout))

    # (B2) Key present but no token uploaded yet.
    make_test_key(os.path.join(home, ".pervio", "apns"))
    p = run_push(home, "send", "--title", "T", "--body", "B")
    check("send with key but NO token exits 0", p.returncode == 0, "rc=%d" % p.returncode)
    check("send with key but NO token explains the missing token on stderr",
          "token" in p.stderr.lower(), repr(p.stderr))

    # (B3) check reports NOT READY (exit 1) with no token, READY (exit 0) once one lands.
    pc = run_push(home, "check")
    check("check exits 1 when not ready", pc.returncode == 1, "rc=%d" % pc.returncode)
    check("check names the missing piece", "token" in pc.stdout.lower(), pc.stdout)
    tokens_dir = os.path.join(home, ".pervio", "push", "tokens")
    os.makedirs(tokens_dir, exist_ok=True)
    with open(os.path.join(tokens_dir, "device-A"), "w") as f:
        f.write("a" * 64)
    pc = run_push(home, "check")
    check("check exits 0 once a key AND a token are present", pc.returncode == 0, pc.stdout)
    check("check reports READY", "READY" in pc.stdout, pc.stdout)
finally:
    shutil.rmtree(home, ignore_errors=True)


# ===========================================================================
print("\n=== C. dry-run request shape (host/path/method/headers/payload) ===")
# ===========================================================================
home = fresh_home()
try:
    make_test_key(os.path.join(home, ".pervio", "apns"))
    tokens_dir = os.path.join(home, ".pervio", "push", "tokens")
    os.makedirs(tokens_dir, exist_ok=True)
    device_hex = "b" * 64
    with open(os.path.join(tokens_dir, "device-A"), "w") as f:
        f.write(device_hex)

    # (C0) Who started the work is the only one told it finished: with two phones
    # on file, --device narrows the send to that phone; an unknown device sends
    # to nobody (never "everyone instead"); no --device keeps the fan-out.
    with open(os.path.join(tokens_dir, "device-B"), "w") as f:
        f.write("c" * 64)
    pd = run_push(home, "dry-run", "--title", "t", "--body", "b", "--device", "device-A")
    check("--device sends to that phone's token only",
          pd.returncode == 0 and pd.stdout.splitlines()[0].endswith("/3/device/" + device_hex)
          and "more device" not in pd.stdout, pd.stdout[:300])
    pd = run_push(home, "dry-run", "--title", "t", "--body", "b", "--device", "device-Z")
    check("--device for a phone with no token sends to nobody and says so",
          pd.returncode == 0 and "POST" not in pd.stdout and "no token on file for device device-Z" in pd.stderr,
          (pd.stdout[:120], pd.stderr[:200]))
    pd = run_push(home, "dry-run", "--title", "t", "--body", "b")
    check("without --device every phone on file is reached", "(+ 1 more device(s))" in pd.stdout, pd.stdout[-200:])
    os.remove(os.path.join(tokens_dir, "device-B"))

    # (C1) Production, with a thread.
    p = run_push(home, "dry-run", "--title", "论文晨报 2026-08-12",
                 "--body", "已送达", "--thread", "pervio-digest")
    out = p.stdout
    check("dry-run exits 0", p.returncode == 0, "rc=%d" % p.returncode)
    check("dry-run request line is POST to api.push.apple.com",
          out.splitlines()[0] == "POST https://api.push.apple.com/3/device/" + device_hex,
          out.splitlines()[0] if out else "")
    check("dry-run sets apns-topic to the app bundle id",
          "apns-topic: app.pervio" in out, out)
    check("dry-run sets apns-push-type: alert", "apns-push-type: alert" in out, out)
    check("dry-run sets apns-priority: 10", "apns-priority: 10" in out, out)
    check("dry-run carries an authorization bearer (redacted)",
          "authorization: bearer <redacted>" in out, out)
    check("dry-run sets apns-collapse-id from the thread",
          "apns-collapse-id: pervio-digest" in out, out)
    # Payload is the last line; parse it as JSON and check the aps structure.
    payload_line = out.rstrip("\n").splitlines()[-1]
    try:
        payload = json.loads(payload_line)
    except ValueError:
        payload = {}
    check("payload is valid JSON with an aps object", "aps" in payload, payload_line)
    aps = payload.get("aps", {})
    check("payload alert.title is the title",
          aps.get("alert", {}).get("title") == "论文晨报 2026-08-12", aps)
    check("payload alert.body is the body", aps.get("alert", {}).get("body") == "已送达", aps)
    check("payload sound is default", aps.get("sound") == "default", aps)
    check("payload thread-id echoes the thread", aps.get("thread-id") == "pervio-digest", aps)

    # (C2) --sandbox switches ONLY the host; no thread => no collapse/thread-id.
    p = run_push(home, "dry-run", "--title", "Hi", "--body", "There", "--sandbox")
    out = p.stdout
    check("--sandbox targets api.sandbox.push.apple.com",
          out.splitlines()[0].startswith("POST https://api.sandbox.push.apple.com/3/device/"),
          out.splitlines()[0] if out else "")
    check("no --thread => no apns-collapse-id header", "apns-collapse-id" not in out, out)
    payload_line = out.rstrip("\n").splitlines()[-1]
    payload = json.loads(payload_line)
    check("no --thread => no thread-id in payload", "thread-id" not in payload.get("aps", {}), payload)

    # (C3) dry-run works even with NO key (unsigned shape) — reviewable pre-setup.
    home2 = fresh_home()
    try:
        p = run_push(home2, "dry-run", "--title", "X", "--body", "Y")
        check("dry-run with no key still prints a request shape, exit 0",
              p.returncode == 0 and p.stdout.startswith("POST https://api.push.apple.com/3/device/"),
              p.stdout[:80])
    finally:
        shutil.rmtree(home2, ignore_errors=True)
finally:
    shutil.rmtree(home, ignore_errors=True)


# ===========================================================================
print("\n=== D. hooks actually invoke pervio-push (fake recorder on PATH) ===")
# ===========================================================================


def fake_push_dir(home):
    """A shim dir holding a fake `pervio-push` that appends its argv (as JSON) to
    $PUSH_LOG and exits 0 — the recorder the hooks call instead of the real sender."""
    d = os.path.join(home, "shim-push")
    os.makedirs(d, exist_ok=True)
    fake = os.path.join(d, "pervio-push")
    with open(fake, "w") as f:
        f.write("#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "p = os.environ.get('PUSH_LOG')\n"
                "if p:\n"
                "    with open(p, 'a') as fh: fh.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                "sys.exit(0)\n")
    os.chmod(fake, 0o755)
    return d


def read_push_log(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def argv_flag(argv, flag):
    """The value following `flag` in a recorded argv list, or ''."""
    if flag in argv:
        i = argv.index(flag)
        if i + 1 < len(argv):
            return argv[i + 1]
    return ""


# The orchestrate hooks and pervio-approve invoke pervio-push via sys.executable
# (python) with the script path, so a fake ON PATH is not enough by itself: the
# hooks build an absolute path to their SIBLING pervio-push. We therefore run the
# hook against a temp BIN that contains the fake as the sibling. The simplest,
# faithful way to exercise "does orchestrate call its sibling pervio-push" without
# copying the whole 140KB script is to unit-test the hook helper `_push_notify`
# directly, with the module's PUSH pointed at the fake — same code path the run
# loop takes, just invoked in isolation.
home = fresh_home()
try:
    push_log = os.path.join(home, "push.log")
    shim = fake_push_dir(home)
    fake = os.path.join(shim, "pervio-push")
    # The fake reads $PUSH_LOG from the env it INHERITS via Popen, so set it on the
    # parent's environment before firing the (detached) hook.
    os.environ["PUSH_LOG"] = push_log

    # (D1) orchestrate's _push_notify shells out to its sibling pervio-push.
    loader = importlib.machinery.SourceFileLoader("orch_mod", ORCH)
    ospec = importlib.util.spec_from_loader("orch_mod", loader)
    orch = importlib.util.module_from_spec(ospec)
    # Importing pervio-orchestrate must not start a run; it only defines things at
    # import (its CLI is under `if __name__ == '__main__'`). Pin HOME first.
    os.environ["HOME"] = home
    loader.exec_module(orch)
    orch.PUSH = fake
    orch._push_notify("论文晨报", "2026-08-12 已送达", thread="pervio-digest")
    # _push_notify is fire-and-forget (Popen, detached) — give the child a moment.
    for _ in range(50):
        if read_push_log(push_log):
            break
        time.sleep(0.05)
    calls = read_push_log(push_log)
    check("orchestrate _push_notify invoked pervio-push", len(calls) >= 1, calls)
    if calls:
        c = calls[0]
        check("hook call is a `send`", c[:1] == ["send"], c)
        check("hook passes --title = workflow name", argv_flag(c, "--title") == "论文晨报", c)
        check("hook passes --body = date + 已送达", argv_flag(c, "--body") == "2026-08-12 已送达", c)
        check("hook passes the --thread", argv_flag(c, "--thread") == "pervio-digest", c)

    # (D1b) a workflow started from a phone tells THAT phone only (2026-10-18):
    # the device recorded at start rides the push as --device; without one the
    # send is unaddressed (every token), as before.
    check("hook without a device passes no --device", "--device" not in (calls[0] if calls else []), calls)
    open(push_log, "w").close()
    orch._push_notify("论文晨报", "2026-08-12 已送达", thread="pervio-digest", device="phone-7")
    for _ in range(50):
        if read_push_log(push_log):
            break
        time.sleep(0.05)
    calls = read_push_log(push_log)
    check("hook with a device addresses the push to it (--device)",
          bool(calls) and argv_flag(calls[0], "--device") == "phone-7", calls)

    # (D2) the failure hook shape (same helper, failure wording).
    open(push_log, "w").close()
    orch._push_notify("每日报告", "失败:build", thread="pervio-wf-abc")
    for _ in range(50):
        if read_push_log(push_log):
            break
        time.sleep(0.05)
    calls = read_push_log(push_log)
    check("failure hook invoked pervio-push", len(calls) >= 1, calls)
    if calls:
        check("failure body starts with 失败:",
              argv_flag(calls[0], "--body").startswith("失败:"), calls[0])

    # (D3) missing pervio-push must NOT raise out of the hook (fire-and-forget).
    open(push_log, "w").close()
    orch.PUSH = os.path.join(home, "does-not-exist-pervio-push")
    raised = False
    try:
        orch._push_notify("X", "Y")
    except Exception as e:  # noqa: BLE001
        raised = True
        check("hook swallowed a missing pervio-push", False, str(e))
    if not raised:
        check("hook with a missing pervio-push does not raise", True)
finally:
    shutil.rmtree(home, ignore_errors=True)
    os.environ.pop("PUSH_LOG", None)


# (D4) pervio-approve fires pervio-push on the FIRST permission request, once.
home = fresh_home()
try:
    push_log = os.path.join(home, "approve_push.log")
    shim = fake_push_dir(home)
    fake = os.path.join(shim, "pervio-push")

    aloader = importlib.machinery.SourceFileLoader("approve_mod", APPROVE)
    aspec = importlib.util.spec_from_loader("approve_mod", aloader)
    approve = importlib.util.module_from_spec(aspec)
    os.environ["PERVIO_SID"] = "testsid"
    os.environ["HOME"] = home
    aloader.exec_module(approve)
    approve.PUSH = fake
    os.environ["PUSH_LOG"] = push_log

    # _push_approval maps the tool to a verb and shells out once.
    approve._push_approval("Edit")
    for _ in range(50):
        if read_push_log(push_log):
            break
        time.sleep(0.05)
    calls = read_push_log(push_log)
    check("pervio-approve _push_approval invoked pervio-push", len(calls) >= 1, calls)
    if calls:
        c = calls[0]
        check("approval title is 'Claude 在等你批准'",
              argv_flag(c, "--title") == "Claude 在等你批准", c)
        check("approval body maps Edit -> 改文件", argv_flag(c, "--body") == "改文件", c)
        check("approval uses the pervio-approve thread",
              argv_flag(c, "--thread") == "pervio-approve", c)

    # An unknown tool falls back to the tool name (not a crash / empty body).
    open(push_log, "w").close()
    approve._push_approval("SomeFutureTool")
    for _ in range(50):
        if read_push_log(push_log):
            break
        time.sleep(0.05)
    calls = read_push_log(push_log)
    check("unknown tool falls back to the tool name as the verb",
          calls and argv_flag(calls[0], "--body") == "SomeFutureTool", calls)
finally:
    shutil.rmtree(home, ignore_errors=True)
    os.environ.pop("PERVIO_SID", None)
    os.environ.pop("PUSH_LOG", None)


# ===========================================================================
print("\n=== E. Live Activity end-push (apns-push-type: liveactivity) ===")
# ===========================================================================
# WHY THIS EXISTS. Every ActivityKit `end()` call lives in the iOS app process.
# A detached run finishes on the Mac long after iOS suspended the app, so no Swift
# code is left to end the Live Activity — the Dynamic Island keeps counting forever.
# The ONLY way to end it from here is an ActivityKit push, which needs its own
# push type, its own topic suffix, and its own per-activity token. These tests pin
# that request byte for byte against Apple's documented contract.

LA_TOKEN = "c" * 64          # the per-ACTIVITY token (NOT the device token)
DEVICE_TOKEN = "b" * 64      # the device token — must never be used for this push

# Every stored property of RunActivityAttributes.ContentState, verbatim. Swift's
# synthesized Codable applies no defaults, so a key this side forgets is a push
# ActivityKit silently drops — the island stays stuck and nothing anywhere says
# why. Pinned as a SET in one place so the two assertions below (an end and an
# update) can never drift apart from each other, and so adding a field to the
# Swift type without adding it here turns red instead of turning quiet.
# The iOS half of the same contract is LiveActivityPushTests.
CONTENT_STATE_KEYS = {"status", "detail", "finished", "step",
                      "stepsDone", "stepsTotal", "failed",
                      "toolIcon", "toolLine", "stepETA", "stepStartedAt"}


def seed_activity(home, run_id, token=LA_TOKEN):
    """Write a per-activity push token where the phone uploads it."""
    d = os.path.join(home, ".pervio", "push", "liveactivity")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, run_id), "w") as f:
        f.write(token)
    return os.path.join(d, run_id)


def payload_of(out):
    """Parse the JSON body off the end of a dry-run dump."""
    try:
        return json.loads(out.rstrip("\n").splitlines()[-1])
    except (ValueError, IndexError):
        return {}


home = fresh_home()
try:
    make_test_key(os.path.join(home, ".pervio", "apns"))
    tokens_dir = os.path.join(home, ".pervio", "push", "tokens")
    os.makedirs(tokens_dir, exist_ok=True)
    with open(os.path.join(tokens_dir, "device-A"), "w") as f:
        f.write(DEVICE_TOKEN)
    seed_activity(home, "run123abc")

    # (E1) The end request, item by item.
    p = run_push(home, "liveactivity", "--run", "run123abc", "--dry-run")
    out = p.stdout
    check("liveactivity dry-run exits 0", p.returncode == 0,
          "rc=%d stderr=%s" % (p.returncode, p.stderr))
    first = out.splitlines()[0] if out else ""
    check("posts to the ACTIVITY token, not the device token",
          first == "POST https://api.push.apple.com/3/device/" + LA_TOKEN, first)
    check("apns-push-type is liveactivity (not alert)",
          "apns-push-type: liveactivity" in out, out)
    check("apns-topic gets the .push-type.liveactivity suffix",
          "apns-topic: app.pervio.push-type.liveactivity" in out, out)
    check("apns-priority: 10 (deliver the dismissal immediately)",
          "apns-priority: 10" in out, out)
    check("carries an authorization bearer (redacted)",
          "authorization: bearer <redacted>" in out, out)
    check("no apns-collapse-id on a Live Activity push",
          "apns-collapse-id" not in out, out)

    aps = payload_of(out).get("aps", {})
    check("aps.event is end", aps.get("event") == "end", aps)
    check("aps.timestamp is epoch SECONDS (int, ~now)",
          isinstance(aps.get("timestamp"), int)
          and abs(aps["timestamp"] - int(time.time())) < 120, aps)
    check("aps has a dismissal-date so the island actually goes away",
          isinstance(aps.get("dismissal-date"), int), aps)
    check("dismissal-date is at/after the timestamp and within Apple's 4h window",
          isinstance(aps.get("dismissal-date"), int)
          and 0 <= aps["dismissal-date"] - aps.get("timestamp", 0) <= 4 * 3600, aps)

    cs = aps.get("content-state")
    check("aps has a content-state object", isinstance(cs, dict), aps)
    if isinstance(cs, dict):
        # Swift's SYNTHESIZED Codable does not apply property defaults: every
        # stored property of RunActivityAttributes.ContentState must be present or
        # the whole push is dropped. Pin the exact key set.
        check("content-state carries EXACTLY the ContentState keys",
              set(cs.keys()) == CONTENT_STATE_KEYS, cs)
        check("content-state.finished is a real JSON bool true",
              cs.get("finished") is True, cs)
        check("content-state.step is an int", isinstance(cs.get("step"), int), cs)
        check("content-state.status defaults to Done", cs.get("status") == "Done", cs)
        check("content-state.detail defaults to empty", cs.get("detail") == "", cs)
        # The trail fields decode as ints and default to 0 (an open-ended run the
        # Mac ends knows no step counts → the receding path collapses).
        check("content-state.stepsDone defaults to int 0",
              cs.get("stepsDone") == 0 and isinstance(cs.get("stepsDone"), int), cs)
        check("content-state.stepsTotal defaults to int 0",
              cs.get("stepsTotal") == 0 and isinstance(cs.get("stepsTotal"), int), cs)
        # `failed` must be a real JSON bool (Swift decodes Bool, not 0/1); a plain
        # end (no --failed) is a clean finish, so false.
        check("content-state.failed is JSON bool false on a clean end",
              cs.get("failed") is False, cs)
        # A finished card has no "currently doing": no tool row, and no ETA for a
        # self-filling cell that would otherwise keep creeping under a done run —
        # which is the stuck island wearing a different hat.
        check("an end clears the tool row",
              cs.get("toolIcon") == "" and cs.get("toolLine") == "", cs)
        check("an end carries no step ETA",
              cs.get("stepETA") == 0 and isinstance(cs.get("stepETA"), int), cs)
        # stepStartedAt is epoch SECONDS (a plain int, NOT a Codable Date — that
        # would drag in JSONDecoder's 2001 reference-date trap), and it is always
        # this push's own timestamp: an update IS the step boundary.
        check("content-state.stepStartedAt is the push's own epoch-second timestamp",
              cs.get("stepStartedAt") == aps.get("timestamp")
              and isinstance(cs.get("stepStartedAt"), int), cs)

    # (E2) The final frame is overridable (a failed run says something else), and
    # --failed marks the terminal state as a failure for the island's rust look.
    p = run_push(home, "liveactivity", "--run", "run123abc", "--status", "Ended",
                 "--detail", "退出码 5", "--step", "7", "--failed", "--dry-run")
    cs = payload_of(p.stdout).get("aps", {}).get("content-state", {})
    check("--status flows into content-state.status", cs.get("status") == "Ended", cs)
    check("--detail flows into content-state.detail", cs.get("detail") == "退出码 5", cs)
    check("--step flows into content-state.step (int, not str)", cs.get("step") == 7, cs)
    check("--failed sets content-state.failed to JSON bool true",
          cs.get("failed") is True, cs)

    # (E2b) A workflow end carries real trail counts (ints, not strings).
    p = run_push(home, "liveactivity", "--run", "run123abc",
                 "--steps-done", "6", "--steps-total", "6", "--dry-run")
    cs = payload_of(p.stdout).get("aps", {}).get("content-state", {})
    check("--steps-done flows into content-state.stepsDone (int)",
          cs.get("stepsDone") == 6, cs)
    check("--steps-total flows into content-state.stepsTotal (int)",
          cs.get("stepsTotal") == 6, cs)

    # (E2c) The tool row + the current step's ETA — the two things the combo
    # island draws that the old card had no words for. They only mean anything on
    # an `update` (an end clears them, asserted above).
    p = run_push(home, "liveactivity", "--run", "run123abc", "--event", "update",
                 "--tool-icon", "terminal", "--tool-line", "Bash · npm test",
                 "--step-eta", "45", "--dry-run")
    cs = payload_of(p.stdout).get("aps", {}).get("content-state", {})
    check("--tool-icon flows into content-state.toolIcon",
          cs.get("toolIcon") == "terminal", cs)
    check("--tool-line flows into content-state.toolLine (UTF-8 middot intact)",
          cs.get("toolLine") == "Bash · npm test", cs)
    check("--step-eta flows into content-state.stepETA (int, not str)",
          cs.get("stepETA") == 45 and isinstance(cs.get("stepETA"), int), cs)

    # (E2d) A junk ETA can't poison the island: a negative one would make an
    # invalid ProgressView range, and an absurd one leaves a cell that never
    # visibly moves — worse than admitting we don't know (0 → the island's own
    # default).
    p = run_push(home, "liveactivity", "--run", "run123abc", "--event", "update",
                 "--step-eta", "-5", "--dry-run")
    cs = payload_of(p.stdout).get("aps", {}).get("content-state", {})
    check("a negative --step-eta clamps to 0", cs.get("stepETA") == 0, cs)
    p = run_push(home, "liveactivity", "--run", "run123abc", "--event", "update",
                 "--step-eta", "99999", "--dry-run")
    cs = payload_of(p.stdout).get("aps", {}).get("content-state", {})
    check("an absurd --step-eta clamps to an hour", cs.get("stepETA") == 3600, cs)
    p = run_push(home, "liveactivity", "--run", "run123abc", "--event", "update",
                 "--step-eta", "soon", "--dry-run")
    cs = payload_of(p.stdout).get("aps", {}).get("content-state", {})
    check("a non-numeric --step-eta falls back to 0, not a crash",
          cs.get("stepETA") == 0 and p.returncode == 0, cs)

    # (E3) update event: same headers, no dismissal-date (nothing is ending).
    p = run_push(home, "liveactivity", "--run", "run123abc", "--event", "update",
                 "--status", "Working…", "--dry-run")
    out = p.stdout
    aps = payload_of(out).get("aps", {})
    check("--event update sets aps.event = update", aps.get("event") == "update", aps)
    check("an update carries NO dismissal-date", "dismissal-date" not in aps, aps)
    check("an update still uses the liveactivity push type",
          "apns-push-type: liveactivity" in out, out)
    check("an update still carries a full content-state",
          set(aps.get("content-state", {}).keys()) == CONTENT_STATE_KEYS, aps)
    check("an update is not marked finished",
          aps.get("content-state", {}).get("finished") is False, aps)

    # (E4) --sandbox switches only the host.
    p = run_push(home, "liveactivity", "--run", "run123abc", "--sandbox", "--dry-run")
    first = p.stdout.splitlines()[0] if p.stdout else ""
    check("--sandbox targets api.sandbox.push.apple.com",
          first == "POST https://api.sandbox.push.apple.com/3/device/" + LA_TOKEN, first)

    # (E5) An UNKNOWN run has no activity token → silent success, nothing sent.
    p = run_push(home, "liveactivity", "--run", "no-such-run")
    check("unknown run exits 0 (fire-and-forget from the run wrapper)",
          p.returncode == 0, "rc=%d" % p.returncode)
    check("unknown run prints NOTHING to stdout", p.stdout == "", repr(p.stdout))
    check("unknown run explains itself on stderr once", p.stderr.strip() != "", repr(p.stderr))

    # (E6) Missing --run is a no-op, not a crash.
    p = run_push(home, "liveactivity")
    check("no --run exits 0", p.returncode == 0, "rc=%d" % p.returncode)
    check("no --run sends nothing", p.stdout == "", repr(p.stdout))

    # (E7) A run id can't escape the liveactivity dir.
    outside = os.path.join(home, ".pervio", "push", "tokens", "device-A")
    check("the traversal target really exists (guard is meaningful)",
          os.path.exists(outside), outside)
    p = run_push(home, "liveactivity", "--run", "../tokens/device-A", "--dry-run")
    check("a path-traversal run id never reads another file",
          DEVICE_TOKEN not in p.stdout, p.stdout[:160])
    check("a path-traversal run id still exits 0", p.returncode == 0, "rc=%d" % p.returncode)

    # (E8) No APNs key at all → silent no-op (same contract as `send`).
    home2 = fresh_home()
    try:
        seed_activity(home2, "run123abc")
        p = run_push(home2, "liveactivity", "--run", "run123abc")
        check("no key => liveactivity exits 0 quietly", p.returncode == 0
              and p.stdout == "", "rc=%d out=%r" % (p.returncode, p.stdout))
    finally:
        shutil.rmtree(home2, ignore_errors=True)

    # (E9) `check` reports the Live Activity leg too.
    pc = run_push(home, "check")
    check("check mentions the live activity token(s)",
          "live activity" in pc.stdout.lower(), pc.stdout)
finally:
    shutil.rmtree(home, ignore_errors=True)


# ===========================================================================
print("\n=== F. pervio-run's wrapper ends the Live Activity when the run finishes ===")
# ===========================================================================
# The run wrapper already fires the lock-screen alert at the exact moment the work
# finishes. That is also the only moment anything can end the Live Activity, so the
# same hook must send the liveactivity push — otherwise the island keeps counting.
RUNBIN = os.path.join(BIN, "pervio-run")

home = fresh_home()
try:
    # A throwaway bin/ holding a COPY of pervio-run (it resolves its siblings via
    # realpath(__file__), so a symlink would point back at the repo) next to a fake
    # pervio-chat and a fake pervio-push recorder. `_pervio_lib.py` must ride along:
    # pervio-run imports push_lang from it, sibling-style, same as pervio-orchestrate.
    tbin = os.path.join(home, "bin")
    os.makedirs(tbin, exist_ok=True)
    shutil.copy(RUNBIN, os.path.join(tbin, "pervio-run"))
    shutil.copy(os.path.join(BIN, "_pervio_lib.py"), os.path.join(tbin, "_pervio_lib.py"))
    push_log = os.path.join(home, "run_push.log")

    fake_push = os.path.join(tbin, "pervio-push")
    with open(fake_push, "w") as f:
        f.write("#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "p = os.environ.get('PUSH_LOG')\n"
                "if p:\n"
                "    with open(p, 'a') as fh: fh.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                "sys.exit(0)\n")
    os.chmod(fake_push, 0o755)

    fake_chat = os.path.join(tbin, "pervio-chat")
    with open(fake_chat, "w") as f:
        f.write("#!/usr/bin/env python3\n"
                "import sys\n"
                'print(\'{"type":"result","is_error":false,"session_id":"s1"}\')\n'
                "sys.exit(int(sys.argv[-1]) if sys.argv[-1].isdigit() else 0)\n")
    os.chmod(fake_chat, 0o755)

    env = dict(os.environ, HOME=home, PUSH_LOG=push_log)
    b64 = base64.b64encode("hello".encode()).decode()
    p = subprocess.run([sys.executable, os.path.join(tbin, "pervio-run"), "start",
                        "--dir", os.path.join(home, "proj"), "--prompt-b64", b64],
                       env=env, capture_output=True, text=True, timeout=30)
    rid = ""
    try:
        rid = json.loads(p.stdout)["runId"]
    except (ValueError, KeyError):
        pass
    check("pervio-run start returned a runId", bool(rid), p.stdout + p.stderr)

    # The wrapper is detached; wait for BOTH pushes to land.
    calls = []
    for _ in range(120):
        calls = read_push_log(push_log)
        if any(c[:1] == ["liveactivity"] for c in calls):
            break
        time.sleep(0.05)

    check("the run wrapper still sends the ordinary alert",
          any(c[:1] == ["send"] for c in calls), calls)
    la = [c for c in calls if c[:1] == ["liveactivity"]]
    check("the run wrapper ALSO ends the Live Activity", len(la) == 1, calls)
    if la:
        check("it ends THIS run's activity", argv_flag(la[0], "--run") == rid, la[0])
        check("it sends the end event",
              argv_flag(la[0], "--event") == "end" or "--event" not in la[0], la[0])
        check("a clean run's final frame says Done",
              argv_flag(la[0], "--status") == "Done", la[0])

    # A FAILED run must end the island too (with a different final frame).
    open(push_log, "w").close()
    p = subprocess.run([sys.executable, os.path.join(tbin, "pervio-run"), "start",
                        "--dir", os.path.join(home, "proj"), "--prompt-b64", b64,
                        "--model", "9"],   # the fake chat exits with its last argv
                       env=env, capture_output=True, text=True, timeout=30)
    for _ in range(120):
        calls = read_push_log(push_log)
        if any(c[:1] == ["liveactivity"] for c in calls):
            break
        time.sleep(0.05)
    la = [c for c in calls if c[:1] == ["liveactivity"]]
    check("a FAILED run also ends the Live Activity", len(la) == 1, calls)
    if la:
        check("a failed run's final frame is not Done",
              argv_flag(la[0], "--status") not in ("", "Done"), la[0])
        check("a failed run passes --failed (island shows the rust terminal look)",
              "--failed" in la[0], la[0])
finally:
    shutil.rmtree(home, ignore_errors=True)


# ===========================================================================
print("=== E. No local key → the relay (push.pervio.dev) carries the push ===")
# ===========================================================================
home = fresh_home()
try:
    tokens_dir = os.path.join(home, ".pervio", "push", "tokens")
    os.makedirs(tokens_dir, mode=0o700)
    with open(os.path.join(tokens_dir, "DEVICE-1"), "w") as f:
        f.write("ab" * 32)
    la_dir = os.path.join(home, ".pervio", "push", "liveactivity")
    os.makedirs(la_dir, mode=0o700)
    with open(os.path.join(la_dir, "run000000001"), "w") as f:
        f.write("cd" * 40)
    # A fake curl on PATH: records argv + stdin, answers like the relay would.
    shim = os.path.join(home, "shim-curl"); os.makedirs(shim)
    curl_log = os.path.join(home, "curl.log")
    with open(os.path.join(shim, "curl"), "w") as f:
        f.write("#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "argv = sys.argv[1:]\n"
                "body = sys.stdin.read() if '@-' in argv else ''\n"
                "with open(os.environ['CURL_LOG'], 'a') as fh: fh.write(json.dumps({'argv': argv, 'stdin': body}) + '\\n')\n"
                "url = argv[-1]\n"
                "if url.endswith('/v1/health'):\n"
                "    sys.stdout.write(os.environ.get('HEALTH', '{\"ok\":true,\"key\":true}'))\n"
                "else:\n"
                "    sys.stdout.write(os.environ.get('PUSH_RESP', '{\"ok\":true,\"apns\":200}') + '\\n' + os.environ.get('PUSH_CODE', '200'))\n")
    os.chmod(os.path.join(shim, "curl"), 0o755)
    env = {"PATH": shim + ":" + os.environ.get("PATH", ""), "CURL_LOG": curl_log,
           "PERVIO_PUSH_GATEWAY": "https://relay.test"}

    def curl_calls():
        try:
            with open(curl_log) as fh:
                return [json.loads(l) for l in fh if l.strip()]
        except OSError:
            return []

    p = run_push(home, "send", "--title", "T", "--body", "B", "--thread", "pervio-run-x", extra_env=env)
    calls = curl_calls()
    sent = [c for c in calls if c["argv"][-1] == "https://relay.test/v1/push"]
    body = json.loads(sent[0]["stdin"]) if sent else {}
    check("E1 send with no key posts ONE alert to the relay's /v1/push and exits 0",
          p.returncode == 0 and len(sent) == 1 and "sent via relay" in p.stderr, (p.returncode, p.stderr[-200:], len(sent)))
    check("E2 the relay request is {kind: alert, token, payload (with aps), collapse}",
          body.get("kind") == "alert" and body.get("token") == "ab" * 32 and body.get("collapse") == "pervio-run-x"
          and body.get("payload", {}).get("aps", {}).get("alert") == {"title": "T", "body": "B"}
          and body["payload"]["aps"].get("thread-id") == "pervio-run-x", body)
    check("E3 the relay call never names a topic or a bearer (the relay owns both)",
          not any("apns-topic" in a or "authorization" in a.lower() for a in sent[0]["argv"]) if sent else False,
          sent[0]["argv"] if sent else None)
    open(curl_log, "w").close()
    p = run_push(home, "liveactivity", "--run", "run000000001", "--event", "end", "--status", "Done", extra_env=env)
    calls = curl_calls()
    la = [json.loads(c["stdin"]) for c in calls if c["argv"][-1] == "https://relay.test/v1/push"]
    check("E4 ending a Live Activity with no key goes through the relay as kind=liveactivity, and retires the token",
          p.returncode == 0 and len(la) == 1 and la[0].get("kind") == "liveactivity" and la[0].get("token") == "cd" * 40
          and la[0]["payload"].get("aps", {}).get("event") == "end" and not os.path.exists(os.path.join(la_dir, "run000000001")),
          (p.returncode, p.stderr[-200:], la))
    p = run_push(home, "check", extra_env=env)
    check("E5 check reports READY via the relay when it answers with a key on board",
          p.returncode == 0 and "via relay https://relay.test" in p.stdout and "READY" in p.stdout, (p.returncode, p.stdout))
    p = run_push(home, "check", extra_env=dict(env, HEALTH='{"ok":true,"key":false}'))
    check("E5b a relay without a key is NOT READY", p.returncode == 1 and "NOT READY" in p.stdout, (p.returncode, p.stdout))
    p = run_push(home, "check", extra_env=dict(env, PERVIO_PUSH_GATEWAY="off"))
    check("E6 PERVIO_PUSH_GATEWAY=off disables the relay: no key → NOT READY", p.returncode == 1 and "relay" not in p.stdout, (p.returncode, p.stdout))
    open(curl_log, "w").close()
    p = run_push(home, "send", "--title", "T", "--body", "B", extra_env=dict(env, PERVIO_PUSH_GATEWAY="off"))
    check("E7 with the relay off and no key, send is the old silent no-op (exit 0, nothing posted)",
          p.returncode == 0 and not curl_calls() and "skipping push" in p.stderr, (p.returncode, p.stderr[-160:]))
    # the file form of the override
    with open(os.path.join(home, ".pervio", "push", "gateway"), "w") as f:
        f.write("https://mine.example/\n")
    p = run_push(home, "check", extra_env={k: v for k, v in env.items() if k != "PERVIO_PUSH_GATEWAY"})
    check("E8 ~/.pervio/push/gateway names another relay (trailing slash tolerated)",
          "via relay https://mine.example" in p.stdout, p.stdout)
    # a local key wins over the relay: direct mode, byte-for-byte as before
    make_test_key(os.path.join(home, ".pervio", "apns"))
    open(curl_log, "w").close()
    p = run_push(home, "send", "--title", "T", "--body", "B", extra_env=env)
    calls = curl_calls()
    check("E9 a local key keeps direct mode (api.push.apple.com, bearer signed here), the relay untouched",
          p.returncode == 0 and calls and calls[0]["argv"][-1].startswith("https://api.push.apple.com/3/device/")
          and any(a.lower().startswith("authorization: bearer") for a in calls[0]["argv"])
          and not any(c["argv"][-1].startswith("https://relay.test") for c in calls), (p.returncode, [c["argv"][-1] for c in calls]))
finally:
    shutil.rmtree(home, ignore_errors=True)

ok = all(results)
print("\n=== pervio-push: %s (%d/%d) ==="
      % ("ALL PASS" if ok else "FAILURES", sum(results), len(results)))
sys.exit(0 if ok else 1)
