#!/usr/bin/env python3
"""pervio-push-gateway — the ONE machine that holds the APNs key, so every
user's Mac can reach their own phone's lock screen without owning Apple
credentials (docs/apns.md).

CONTRACT. POST /v1/push with JSON {token, kind, payload, collapse?}:
  token    the device (or Live Activity) push token, 32+ hex chars;
  kind     "alert" | "liveactivity" — the gateway derives topic and push-type
           from this; the CLIENT CANNOT NAME A TOPIC, so this key can never be
           made to push to any app but Pervio;
  payload  the full APNs JSON body the Mac built (same builders as direct mode;
           the gateway forwards bytes, it does not author content);
  collapse optional apns-collapse-id (alerts only, ≤64 chars).
GET /v1/health answers {ok, key} — no auth, no state.

WHAT THE GATEWAY REFUSES: unknown paths/kinds, junk tokens, bodies over
PAYLOAD_CAP (APNs caps alerts at 4KB anyway), and more than RATE_PER_HOUR
pushes per token per hour (in-memory window; a restart forgives — acceptable,
this is an abuse ceiling, not accounting). Content is NEVER logged — a log
line carries the token's first 8 chars, the kind, and the upstream status.

WHAT KEEPS ONE STRANGER FROM TAKING IT DOWN. The address and the contract are
public, and a per-token ceiling alone binds nobody who invents a new token for
every request. So, all in memory and all forgiven by a restart:
  * a source (the client address Caddy reports; a /64 for IPv6) has its own
    hourly ceiling, SOURCE_PER_HOUR;
  * a source whose tokens Apple keeps refusing (BadDeviceToken, Unregistered…)
    is shut out for STRIKE_BLOCK seconds after STRIKES_PER_HOUR of them — the
    refusals are what a made-up token looks like, and they are also what would
    cost this key its standing with Apple;
  * a token Apple has called dead is answered from memory for DEAD_TOKEN_TTL
    seconds instead of asking Apple again (the Mac prunes it on that answer);
  * the whole relay forwards at most GLOBAL_PER_MIN a minute and MAX_INFLIGHT
    at a time, holds at most MAX_CONNECTIONS client connections, and gives a
    client CLIENT_TIMEOUT seconds to say its piece;
  * every table is swept each minute and capped at MAX_TRACKED keys; when one
    is full a NEW key is refused while the ones already known keep working.
No client address is ever written to a log or to disk.

SIGNING is pervio-push's, ported verbatim: ES256 via the openssl CLI (pure
python DER→r||s), JWT cached 50 minutes at STATE_DIR. The upstream POST is
curl --http2, same flags as direct mode, so a payload that works direct works
through the gateway byte-for-byte.

Listens on 127.0.0.1:8787 — Caddy owns TLS and the public face."""
import base64
import collections
import glob
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KEY_DIR = os.environ.get("PERVIO_GW_KEYDIR", "/etc/pervio-gateway")
STATE_DIR = os.environ.get("PERVIO_GW_STATE", "/var/lib/pervio-gateway")
BIND = ("127.0.0.1", int(os.environ.get("PERVIO_GW_PORT", "8787")))
APNS_HOST = os.environ.get("PERVIO_GW_APNS", "api.push.apple.com")
TOPIC = "app.pervio"
LA_TOPIC = TOPIC + ".push-type.liveactivity"
JWT_MAX_AGE = 50 * 60
PAYLOAD_CAP = 8 * 1024
RATE_PER_HOUR = 120
SEND_TIMEOUT = 20


def _env_int(name, default):
    try:
        return max(1, int(os.environ.get(name, "")))
    except ValueError:
        return default


SOURCE_PER_HOUR = _env_int("PERVIO_GW_SOURCE_PER_HOUR", 1200)
GLOBAL_PER_MIN = _env_int("PERVIO_GW_GLOBAL_PER_MIN", 1200)
MAX_INFLIGHT = _env_int("PERVIO_GW_MAX_INFLIGHT", 16)
MAX_CONNECTIONS = _env_int("PERVIO_GW_MAX_CONNECTIONS", 128)
STRIKES_PER_HOUR = _env_int("PERVIO_GW_STRIKES_PER_HOUR", 20)
STRIKE_BLOCK = 3600
DEAD_TOKEN_TTL = 3600
MAX_TRACKED = _env_int("PERVIO_GW_MAX_TRACKED", 50000)
CLIENT_TIMEOUT = 15
# What Apple says about a token that is not a live Pervio device. Anything else
# it refuses (a bad payload, its own outage) says nothing about the token.
DEAD_REASONS = ("BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic", "ExpiredToken")

_rate_lock = threading.Lock()
_rate = {}      # token  -> [epoch, ...] within the last hour
_source = {}    # source -> [epoch, ...] within the last hour
_strikes = {}   # source -> [epoch, ...] of tokens Apple refused, last hour
_blocked = {}   # source -> epoch until which it is shut out
_dead = {}      # token  -> (epoch until, apns status, reason)
_global = collections.deque()   # epochs of forwarded pushes, last minute
_swept = [0.0]
_inflight = threading.BoundedSemaphore(MAX_INFLIGHT)


def _log(msg):
    sys.stderr.write("pervio-push-gateway: %s\n" % msg)
    sys.stderr.flush()


def _b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def find_key():
    p8s = sorted(glob.glob(os.path.join(KEY_DIR, "AuthKey_*.p8")))
    if not p8s:
        return None
    key_path = p8s[0]
    key_id = _read_small(os.path.join(KEY_DIR, "key_id"))
    if not key_id:
        base = os.path.basename(key_path)
        if base.startswith("AuthKey_") and base.endswith(".p8"):
            key_id = base[len("AuthKey_"):-len(".p8")]
    team_id = _read_small(os.path.join(KEY_DIR, "issuer_id"))
    if not (key_id and team_id):
        return None
    return (key_path, key_id, team_id)


def _read_small(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def _der_ecdsa_to_raw(der, size=32):
    if not der or der[0] != 0x30:
        raise ValueError("not a DER SEQUENCE")
    idx = 1
    ln = der[idx]
    idx += 1
    if ln & 0x80:
        idx += (ln & 0x7F)

    def read_int(buf, i):
        if buf[i] != 0x02:
            raise ValueError("expected INTEGER")
        length = buf[i + 1]
        i += 2
        val = buf[i:i + length]
        i += length
        val = val.lstrip(b"\x00")
        if len(val) > size:
            raise ValueError("integer wider than field")
        return val.rjust(size, b"\x00"), i

    r, idx = read_int(der, idx)
    s, idx = read_int(der, idx)
    return r + s


def sign_es256(signing_input, key_path):
    proc = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path],
                          input=signing_input.encode("ascii"),
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    if proc.returncode != 0:
        raise ValueError("openssl: %s" % proc.stderr.decode("utf-8", "replace")[:200])
    return _der_ecdsa_to_raw(proc.stdout)


def make_jwt(key_path, key_id, team_id):
    cache = os.path.join(STATE_DIR, ".jwt_cache.json")
    try:
        with open(cache, "r", encoding="utf-8") as f:
            c = json.load(f)
        if (c.get("kid") == key_id and c.get("jwt")
                and time.time() - float(c.get("iat", 0)) < JWT_MAX_AGE):
            return c["jwt"]
    except (OSError, ValueError):
        pass
    iat = int(time.time())
    header = _b64url(json.dumps({"alg": "ES256", "kid": key_id},
                                separators=(",", ":")).encode("ascii"))
    claims = _b64url(json.dumps({"iss": team_id, "iat": iat},
                                separators=(",", ":")).encode("ascii"))
    signing_input = header + "." + claims
    jwt = signing_input + "." + _b64url(sign_es256(signing_input, key_path))
    try:
        fd = os.open(cache, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"kid": key_id, "jwt": jwt, "iat": iat}, f)
    except OSError:
        pass
    return jwt


def is_token(tok):
    tok = (tok or "").strip().lower()
    return bool(tok) and len(tok) >= 32 and all(c in "0123456789abcdef" for c in tok)


def _sweep(now):
    """Drop what has aged out of every table — at most once a minute, under
    the lock. Without it a table only ever shrank for keys that came back."""
    if now - _swept[0] < 60:
        return
    _swept[0] = now
    for table in (_rate, _source, _strikes):
        for k in [k for k, hits in table.items() if not hits or now - hits[-1] >= 3600]:
            del table[k]
    for k in [k for k, until in _blocked.items() if until <= now]:
        del _blocked[k]
    for k in [k for k, (until, _, _) in _dead.items() if until <= now]:
        del _dead[k]


def _hit(table, key, limit, now):
    """One more hit for `key` in an hourly window; False when that would pass
    `limit`, or when the table is full and `key` is not in it (a stranger
    cannot push the keys already known out of memory). Call under the lock."""
    _sweep(now)
    hits = [t for t in table.get(key, []) if now - t < 3600]
    if len(hits) >= limit:
        table[key] = hits
        return False
    if not hits and key not in table and len(table) >= MAX_TRACKED:
        return False
    hits.append(now)
    table[key] = hits
    return True


def rate_ok(token, now=None):
    """True if this token is under RATE_PER_HOUR for the trailing hour (and
    records the hit). Pure enough for tests: `now` injectable."""
    now = time.time() if now is None else now
    with _rate_lock:
        return _hit(_rate, token, RATE_PER_HOUR, now)


def source_of(forwarded_for, peer):
    """Who is asking: the last address in X-Forwarded-For (the one OUR proxy
    wrote — anything before it is the client's own claim), else the socket's
    peer. An IPv6 source is its /64: a single subscriber owns that many
    addresses, so counting each one separately would count nothing."""
    ip = ""
    if forwarded_for:
        ip = forwarded_for.split(",")[-1].strip()
    ip = (ip or peer or "").strip().strip("[]").lower()
    if ":" in ip and "." not in ip:
        head = ip.split("::")[0] if "::" in ip else ip
        groups = [g for g in head.split(":") if g][:4]
        return ":".join(groups) + "::/64"
    return ip


def source_blocked(source, now=None):
    now = time.time() if now is None else now
    with _rate_lock:
        return _blocked.get(source, 0) > now


def source_ok(source, now=None):
    """True if this source is under SOURCE_PER_HOUR (and records the hit)."""
    now = time.time() if now is None else now
    with _rate_lock:
        return _hit(_source, source, SOURCE_PER_HOUR, now)


def global_ok(now=None):
    """True if the relay as a whole is under GLOBAL_PER_MIN (and records it)."""
    now = time.time() if now is None else now
    with _rate_lock:
        while _global and now - _global[0] >= 60:
            _global.popleft()
        if len(_global) >= GLOBAL_PER_MIN:
            return False
        _global.append(now)
        return True


def dead_token(token, now=None):
    """(apns status, reason) when Apple called this token dead within
    DEAD_TOKEN_TTL, else None."""
    now = time.time() if now is None else now
    with _rate_lock:
        entry = _dead.get(token)
        if entry and entry[0] > now:
            return entry[1], entry[2]
        return None


def apns_reason(upstream):
    try:
        return str(json.loads(upstream).get("reason") or "")
    except (ValueError, AttributeError):
        return ""


def note_refusal(source, token, status, reason, now=None):
    """Apple refused `token`. If the refusal is about the token itself,
    remember the token as dead and count a strike against the source; True when
    that strike shuts the source out."""
    if reason not in DEAD_REASONS:
        return False
    now = time.time() if now is None else now
    with _rate_lock:
        _sweep(now)
        if token in _dead or len(_dead) < MAX_TRACKED:
            _dead[token] = (now + DEAD_TOKEN_TTL, status, reason)
        strikes = [t for t in _strikes.get(source, []) if now - t < 3600]
        strikes.append(now)
        if source in _strikes or len(_strikes) < MAX_TRACKED:
            _strikes[source] = strikes
        if len(strikes) >= STRIKES_PER_HOUR and (source in _blocked or len(_blocked) < MAX_TRACKED):
            _blocked[source] = now + STRIKE_BLOCK
            return True
        return False


def validate(req):
    """(kind, token, body_bytes, headers) or a (status, error) tuple.
    Topic and push-type come from KIND ALONE — the one security property this
    service exists to keep."""
    kind = req.get("kind")
    token = (req.get("token") or "").strip().lower()
    payload = req.get("payload")
    if kind not in ("alert", "liveactivity"):
        return (400, "kind must be alert|liveactivity")
    if not is_token(token):
        return (400, "bad token")
    if not isinstance(payload, dict) or "aps" not in payload:
        return (400, "payload must be an APNs JSON object with aps")
    body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    if len(body) > PAYLOAD_CAP:
        return (413, "payload too large")
    headers = {
        "apns-topic": LA_TOPIC if kind == "liveactivity" else TOPIC,
        "apns-push-type": kind,
        "apns-priority": "10",
    }
    if kind == "alert":
        collapse = (req.get("collapse") or "").strip()
        if collapse:
            headers["apns-collapse-id"] = collapse[:64]
    return (kind, token, body, headers)


def curl_send(token, body, headers, jwt):
    url = "https://%s/3/device/%s" % (APNS_HOST, token)
    cmd = ["curl", "--http2", "-s", "-S", "--max-time", str(SEND_TIMEOUT),
           "-X", "POST", "-o", "-", "-w", "\n%{http_code}"]
    for k, v in headers.items():
        cmd += ["-H", "%s: %s" % (k, v)]
    cmd += ["-H", "authorization: bearer " + jwt]
    cmd += ["--data-binary", "@-", url]
    try:
        proc = subprocess.run(cmd, input=body, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=SEND_TIMEOUT + 5)
    except (OSError, subprocess.SubprocessError) as e:
        return (0, "curl failed: %s" % e)
    out = proc.stdout.decode("utf-8", "replace")
    nl = out.rfind("\n")
    status_str = out[nl + 1:].strip() if nl >= 0 else out.strip()
    try:
        status = int(status_str)
    except ValueError:
        status = 0
    return (status, out[:nl] if nl >= 0 else "")


class Handler(BaseHTTPRequestHandler):
    server_version = "pervio-push-gateway"
    sys_version = ""
    timeout = CLIENT_TIMEOUT      # a client that stalls is dropped, not waited on

    def log_message(self, *a):
        pass

    def _json(self, code, obj, retry_after=0):
        data = json.dumps(obj, separators=(",", ":")).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        if retry_after:
            self.send_header("Retry-After", str(retry_after))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/") == "/v1/health":
            self._json(200, {"ok": True, "key": bool(find_key())})
        else:
            self._json(404, {"ok": False, "error": "not found"})

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/push":
            self._json(404, {"ok": False, "error": "not found"})
            return
        source = source_of(self.headers.get("X-Forwarded-For"), self.client_address[0])
        if source_blocked(source):
            # Answered before a byte of the body is read: a shut-out source
            # costs this relay one header parse per try, nothing more.
            self.close_connection = True
            self._json(429, {"ok": False, "error": "too many refused tokens — try again later"},
                       retry_after=STRIKE_BLOCK)
            return
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            n = 0
        if n <= 0 or n > PAYLOAD_CAP + 1024:
            self._json(413, {"ok": False, "error": "bad length"})
            return
        try:
            req = json.loads(self.rfile.read(n).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self._json(400, {"ok": False, "error": "bad json"})
            return
        v = validate(req)
        if isinstance(v[0], int):
            self._json(v[0], {"ok": False, "error": v[1]})
            return
        kind, token, body, headers = v
        if not source_ok(source):
            self._json(429, {"ok": False, "error": "rate limited"}, retry_after=600)
            return
        dead = dead_token(token)
        if dead:
            # The same shape Apple's own refusal had (the Mac prunes a token on
            # a 410 it reads here) — without asking Apple a second time.
            self._json(502, {"ok": False, "apns": dead[0],
                             "reason": json.dumps({"reason": dead[1]}, separators=(",", ":"))})
            return
        if not rate_ok(token):
            self._json(429, {"ok": False, "error": "rate limited"}, retry_after=600)
            return
        if not global_ok():
            self._json(503, {"ok": False, "error": "relay busy"}, retry_after=30)
            return
        key = find_key()
        if not key:
            self._json(503, {"ok": False, "error": "gateway has no key"})
            return
        try:
            jwt = make_jwt(*key)
        except ValueError as e:
            _log("sign failed: %s" % e)
            self._json(500, {"ok": False, "error": "signing failed"})
            return
        if not _inflight.acquire(blocking=False):
            self._json(503, {"ok": False, "error": "relay busy"}, retry_after=5)
            return
        try:
            status, upstream = curl_send(token, body, headers, jwt)
        finally:
            _inflight.release()
        _log("push %s… kind=%s apns=%s" % (token[:8], kind, status))
        ok = 200 <= status < 300
        if not ok and note_refusal(source, token, status, apns_reason(upstream)):
            _log("a source was shut out for %ds after %d refused tokens in an hour"
                 % (STRIKE_BLOCK, STRIKES_PER_HOUR))
        self._json(200 if ok else 502,
                   {"ok": ok, "apns": status,
                    "reason": (upstream[:200] if not ok else "")})


class Server(ThreadingHTTPServer):
    """ThreadingHTTPServer starts a thread per connection without limit. This
    one holds MAX_CONNECTIONS slots; a connection that finds none is closed at
    once instead of becoming one more thread."""
    daemon_threads = True

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._slots = threading.BoundedSemaphore(MAX_CONNECTIONS)

    def process_request(self, request, client_address):
        if not self._slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        super().process_request(request, client_address)

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._slots.release()


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    srv = Server(BIND, Handler)
    _log("listening on %s:%d, key=%s" % (BIND[0], BIND[1], bool(find_key())))
    srv.serve_forever()


if __name__ == "__main__":
    main()
