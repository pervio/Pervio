#!/usr/bin/env python3
"""pervio-push-gateway — hermetic pins on the pure parts (no network, no key).

The one security property this service exists for: the CLIENT CANNOT NAME AN
APNS TOPIC. `kind` alone decides topic and push-type, so the gateway's key can
never push to any app but Pervio. G1-G4 pin validate(); G5 pins the rate
window; G6 pins that the JWT machinery matches pervio-push's (same header/
claims framing against a throwaway P-256 key). G7-G14 pin what keeps one
stranger from taking the relay down: the per-source ceiling, the lock-out of a
source whose tokens Apple keeps refusing, the memory of dead tokens, the global
and in-flight ceilings, the bounded tables and the connection cap — G12-G14
over real HTTP against the real server class, with Apple stood in for.
"""
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
GW = os.path.join(HERE, "..", "gateway", "pervio-push-gateway.py")

results = []


def check(name, ok, detail=""):
    results.append(bool(ok))
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  [%s]" % (detail,)))


def load(tmp):
    os.environ["PERVIO_GW_KEYDIR"] = os.path.join(tmp, "keys")
    os.environ["PERVIO_GW_STATE"] = os.path.join(tmp, "state")
    loader = importlib.machinery.SourceFileLoader("gw", GW)
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("gw", loader))
    loader.exec_module(mod)
    mod.KEY_DIR = os.environ["PERVIO_GW_KEYDIR"]
    mod.STATE_DIR = os.environ["PERVIO_GW_STATE"]
    os.makedirs(mod.KEY_DIR, exist_ok=True)
    os.makedirs(mod.STATE_DIR, exist_ok=True)
    return mod


tmp = tempfile.mkdtemp(prefix="gwtest-")
gw = load(tmp)
TOK = "ab" * 32

print("=== G1: kind alone names the topic (client cannot) ===")
v = gw.validate({"kind": "alert", "token": TOK,
                 "payload": {"aps": {"alert": {"title": "t"}}},
                 "headers": {"apns-topic": "com.evil.app"}})
check("G1a alert maps to the Pervio topic",
      not isinstance(v[0], int) and v[3]["apns-topic"] == "app.pervio", v)
check("G1b a smuggled topic field changes nothing",
      "com.evil.app" not in json.dumps(v[3]), v[3])
v2 = gw.validate({"kind": "liveactivity", "token": TOK, "payload": {"aps": {}}})
check("G1c liveactivity maps to the suffixed topic",
      v2[3]["apns-topic"] == "app.pervio.push-type.liveactivity", v2)
check("G1d push-type follows kind", v2[3]["apns-push-type"] == "liveactivity", v2)

print("=== G2: junk is refused with the right status ===")
check("G2a unknown kind -> 400",
      gw.validate({"kind": "voip", "token": TOK, "payload": {"aps": {}}})[0] == 400)
check("G2b bad token -> 400",
      gw.validate({"kind": "alert", "token": "xyz", "payload": {"aps": {}}})[0] == 400)
check("G2c payload without aps -> 400",
      gw.validate({"kind": "alert", "token": TOK, "payload": {"x": 1}})[0] == 400)
big = {"aps": {"alert": {"body": "x" * 9000}}}
check("G2d oversized payload -> 413",
      gw.validate({"kind": "alert", "token": TOK, "payload": big})[0] == 413)

print("=== G3: collapse id rides alerts only, clipped to 64 ===")
v = gw.validate({"kind": "alert", "token": TOK, "payload": {"aps": {}},
                 "collapse": "c" * 90})
check("G3a collapse clipped", v[3]["apns-collapse-id"] == "c" * 64, v[3])
v = gw.validate({"kind": "liveactivity", "token": TOK, "payload": {"aps": {}},
                 "collapse": "nope"})
check("G3b liveactivity never coalesces", "apns-collapse-id" not in v[3], v[3])

print("=== G4: body is the canonical compact JSON ===")
v = gw.validate({"kind": "alert", "token": TOK,
                 "payload": {"aps": {"alert": {"title": "题"}}}})
check("G4 body compact + utf8", v[2] == json.dumps(
    {"aps": {"alert": {"title": "题"}}}, separators=(",", ":")).encode("utf-8"), v[2])

print("=== G5: per-token rate window ===")
gw._rate.clear()
now = 1_700_000_000.0
allowed = sum(1 for i in range(gw.RATE_PER_HOUR + 20)
              if gw.rate_ok(TOK, now=now + i))
check("G5a exactly RATE_PER_HOUR pass in one hour",
      allowed == gw.RATE_PER_HOUR, allowed)
check("G5b the window slides (an hour later it opens again)",
      gw.rate_ok(TOK, now=now + 3700), gw._rate.get(TOK, [])[-1:])
check("G5c another token is unaffected", gw.rate_ok("cd" * 32, now=now + 1))

print("=== G6: JWT framing matches pervio-push (real ES256 via openssl) ===")
ec = os.path.join(tmp, "ec.pem")
p8 = os.path.join(gw.KEY_DIR, "AuthKey_TESTKEY123.p8")
subprocess.run(["openssl", "ecparam", "-genkey", "-name", "prime256v1",
                "-noout", "-out", ec], check=True, capture_output=True)
subprocess.run(["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", ec, "-out", p8],
               check=True, capture_output=True)
with open(os.path.join(gw.KEY_DIR, "issuer_id"), "w") as f:
    f.write("TEAMID9999")
key = gw.find_key()
check("G6a find_key reads key_id from filename + issuer file",
      key is not None and key[1] == "TESTKEY123" and key[2] == "TEAMID9999", key)
jwt = gw.make_jwt(*key)
import base64


def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


parts = jwt.split(".")
check("G6b three parts, ES256 header, team issuer",
      len(parts) == 3
      and json.loads(b64d(parts[0]))["alg"] == "ES256"
      and json.loads(b64d(parts[1]))["iss"] == "TEAMID9999", jwt[:40])
check("G6c signature is raw 64-byte r||s", len(b64d(parts[2])) == 64)
check("G6d cache returns the same token (no re-mint)", gw.make_jwt(*key) == jwt)

def reset():
    for table in (gw._rate, gw._source, gw._strikes, gw._blocked, gw._dead):
        table.clear()
    gw._global.clear()
    gw._swept[0] = 0.0


print("=== G7: who is asking — the address OUR proxy wrote, a /64 for IPv6 ===")
check("G7a the proxy's address is the last one", gw.source_of("203.0.113.5", "127.0.0.1") == "203.0.113.5")
check("G7b an address the client claims in front of it changes nothing",
      gw.source_of("1.1.1.1, 10.0.0.1, 203.0.113.5", "127.0.0.1") == "203.0.113.5")
check("G7c no header -> the socket's peer", gw.source_of(None, "198.51.100.7") == "198.51.100.7")
check("G7d two addresses in one IPv6 /64 are one source",
      gw.source_of("2001:db8:1:2:aaaa:bbbb:cccc:dddd", "") == gw.source_of("2001:db8:1:2::1", "")
      and gw.source_of("2001:db8:1:2::1", "") != gw.source_of("2001:db8:1:3::1", ""),
      (gw.source_of("2001:db8:1:2:aaaa:bbbb:cccc:dddd", ""), gw.source_of("2001:db8:1:2::1", "")))

print("=== G8: one source has an hourly ceiling of its own ===")
reset()
A, B = "203.0.113.5", "198.51.100.7"
allowed = sum(1 for i in range(gw.SOURCE_PER_HOUR + 30) if gw.source_ok(A, now=now + i * 0.01))
check("G8a exactly SOURCE_PER_HOUR pass, whatever tokens it names", allowed == gw.SOURCE_PER_HOUR, allowed)
check("G8b another source is unaffected", gw.source_ok(B, now=now + 1))
check("G8c an hour later it opens again", gw.source_ok(A, now=now + 3700))

print("=== G9: the relay as a whole has a per-minute ceiling ===")
reset()
allowed = sum(1 for i in range(gw.GLOBAL_PER_MIN + 50) if gw.global_ok(now=now + i * 0.001))
check("G9a exactly GLOBAL_PER_MIN pass in a minute", allowed == gw.GLOBAL_PER_MIN, allowed)
check("G9b a minute later it opens again", gw.global_ok(now=now + 61))

print("=== G10: tokens Apple refuses shut their source out; a dead token is remembered ===")
reset()
shut = [gw.note_refusal(A, "%064x" % i, 400, "BadDeviceToken", now=now + i)
        for i in range(gw.STRIKES_PER_HOUR)]
check("G10a not before STRIKES_PER_HOUR refusals", not any(shut[:-1]), shut)
check("G10b the last one shuts the source out", shut[-1] and gw.source_blocked(A, now=now + 30))
check("G10c for STRIKE_BLOCK seconds, then it is let back in",
      gw.source_blocked(A, now=now + gw.STRIKES_PER_HOUR + gw.STRIKE_BLOCK - 5)
      and not gw.source_blocked(A, now=now + gw.STRIKES_PER_HOUR + gw.STRIKE_BLOCK + 5))
check("G10d another source is not", not gw.source_blocked(B, now=now + 30))
check("G10e a refused token is answered from memory, with Apple's own status and reason",
      gw.dead_token("%064x" % 3, now=now + 60) == (400, "BadDeviceToken"))
check("G10f and forgotten after DEAD_TOKEN_TTL",
      gw.dead_token("%064x" % 3, now=now + 3 + gw.DEAD_TOKEN_TTL + 5) is None)
reset()
quiet = [gw.note_refusal(B, "ee" * 32, 413, "PayloadTooLarge", now=now + i) for i in range(60)] \
      + [gw.note_refusal(B, "ee" * 32, 503, "", now=now + i) for i in range(60)]
check("G10g a refusal that is not about the token is no strike (Apple's outage must not lock people out)",
      not any(quiet) and not gw.source_blocked(B, now=now + 61) and gw.dead_token("ee" * 32, now=now + 61) is None)

print("=== G11: the tables cannot be grown without bound ===")
reset()
cap, gw.MAX_TRACKED = gw.MAX_TRACKED, 40
known = ["%064x" % (0x1000 + i) for i in range(40)]
check("G11a up to MAX_TRACKED distinct tokens are tracked", all(gw.rate_ok(t, now=now) for t in known))
check("G11b one more NEW token is refused", not gw.rate_ok("%064x" % 0x9999, now=now + 1))
check("G11c the ones already known keep working", gw.rate_ok(known[7], now=now + 2))
check("G11d the table did not grow", len(gw._rate) == 40, len(gw._rate))
check("G11e an hour on, the sweep has made room", gw.rate_ok("%064x" % 0x9999, now=now + 3700)
      and len(gw._rate) <= 2, len(gw._rate))
gw.MAX_TRACKED = cap

print("=== G12: over HTTP — a flood of made-up tokens from one source ===")
import http.client
import socket
import threading
import time as _time

reset()
calls = []            # every time Apple WOULD have been asked
answers = {}          # token -> (status, body); default: Apple has never heard of it
gate = threading.Event(); gate.set()


def fake_apns(token, body, headers, jwt):
    calls.append(token)
    gate.wait(10)
    return answers.get(token, (400, '{"reason":"BadDeviceToken"}'))


gw.curl_send = fake_apns
gw.STRIKES_PER_HOUR = 6
srv = gw.Server(("127.0.0.1", 0), gw.Handler)
port = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()


def push(token, xff, kind="alert"):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    body = json.dumps({"kind": kind, "token": token, "payload": {"aps": {"alert": {"title": "t"}}}})
    c.request("POST", "/v1/push", body=body,
              headers={"Content-Type": "application/json", "X-Forwarded-For": xff})
    r = c.getresponse()
    out = (r.status, r.read().decode("utf-8"))
    c.close()
    return out


flood = [push("%064x" % (0xF00D + i), A)[0] for i in range(15)]
check("G12a the first STRIKES_PER_HOUR reach Apple and come back refused (502)",
      flood[:6] == [502] * 6, flood)
check("G12b every one after that is turned away (429)", flood[6:] == [429] * 9, flood)
check("G12c and Apple was asked exactly STRIKES_PER_HOUR times — the flood stops costing anything",
      len(calls) == 6, len(calls))
check("G12d claiming another address in front of the real one does not get back in",
      push("%064x" % 0xBEEF, "8.8.8.8, " + A)[0] == 429 and len(calls) == 6, len(calls))
GOOD = "aa" * 32
answers[GOOD] = (200, "")
check("G12e meanwhile another source's real push goes through", push(GOOD, B) == (200, '{"ok":true,"apns":200,"reason":""}'),
      push(GOOD, B))
GONE = "bb" * 32
answers[GONE] = (410, '{"reason":"Unregistered"}')
before = len(calls)
first = push(GONE, B)
again = push(GONE, B)
check("G12f a token Apple calls gone is asked about once …", len(calls) == before + 1, len(calls) - before)
check("G12g … and the second answer still carries the 410 the Mac prunes the token on",
      first[0] == 502 and again[0] == 502 and "410" in again[1] and "Unregistered" in again[1], again)

print("=== G13: at most MAX_INFLIGHT pushes are with Apple at once ===")
reset()
gw._inflight = threading.BoundedSemaphore(1)
gate.clear()                       # Apple is slow: the first push stays in flight
got = {}
t1 = threading.Thread(target=lambda: got.__setitem__("first", push(GOOD, "192.0.2.1")))
t1.start()
for _ in range(100):
    if calls and calls[-1] == GOOD and len(calls) > before + 1:
        break
    _time.sleep(0.02)
second = push("cc" * 32, "192.0.2.2")
gate.set(); t1.join(10)
check("G13a the one in flight completes", got.get("first", (0,))[0] == 200, got)
check("G13b the one that found no room is told the relay is busy (503), not queued",
      second[0] == 503 and "busy" in second[1], second)
gw._inflight = threading.BoundedSemaphore(gw.MAX_INFLIGHT)
srv.shutdown(); srv.server_close()

print("=== G14: connections are capped, and a client that stalls is dropped ===")
reset()
gw.MAX_CONNECTIONS = 2
gw.Handler.timeout = 1
srv = gw.Server(("127.0.0.1", 0), gw.Handler)
port = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()
idle = [socket.create_connection(("127.0.0.1", port), timeout=5) for _ in range(2)]
_time.sleep(0.2)
extra = socket.create_connection(("127.0.0.1", port), timeout=5)
extra.sendall(b"GET /v1/health HTTP/1.0\r\n\r\n")
try:
    reply = extra.recv(200)
except OSError:
    reply = b""
check("G14a with every slot taken, one more connection is closed unanswered", reply == b"", reply[:40])
extra.close()
_time.sleep(1.6)                    # the two that said nothing run out of time
try:
    dropped = all(s.recv(10) == b"" for s in idle)
except OSError:
    dropped = True
check("G14b a client that says nothing is dropped after CLIENT_TIMEOUT", dropped)
for s_ in idle:
    s_.close()
c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
c.request("GET", "/v1/health")
check("G14c and the relay answers again once they are gone", c.getresponse().status == 200)
c.close()
srv.shutdown(); srv.server_close()

n = sum(results)
print("\n%d/%d passed" % (n, len(results)))
sys.exit(0 if n == len(results) else 1)
