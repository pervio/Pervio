#!/usr/bin/env python3
"""pervio-ports: the listening services the phone's web preview offers.

A fake `lsof` on PATH pins the parse (one row per port, loopback beats
wildcard, sshd left out, newest first); a real listener on a free port pins
that the script finds a service that really listens on this machine."""
import json
import os
import socket
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PORTS = os.path.join(HERE, "..", "bin", "pervio-ports")
results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS " if cond else "FAIL ") + name + (("  [" + str(detail)[:300] + "]") if (detail and not cond) else ""))


def run(env):
    p = subprocess.run([sys.executable, PORTS, "list"], env=env, capture_output=True, text=True, timeout=30)
    return p, (json.loads(p.stdout) if p.stdout.strip().startswith("[") else None)


# ---- the parse, against a scripted lsof --------------------------------------
print("=== pervio-ports: parse ===")
tmp = tempfile.mkdtemp(prefix="pports_", dir="/tmp")
fake = os.path.join(tmp, "lsof")
with open(fake, "w") as f:
    f.write("#!/bin/sh\n"
            "cat <<'LS'\n"
            "p4242\ncnode\nn*:3000\nn127.0.0.1:3000\n"
            "p5151\ncPython\nn[::1]:8000\n"
            "p99\ncsshd\nn*:22\n"
            "p7373\ncpostgres\nn127.0.0.1:5432\n"
            "LS\n")
os.chmod(fake, 0o755)
env = dict(os.environ, PATH=tmp + ":" + os.environ.get("PATH", ""))
p, rows = run(env)
check("P1 list exits 0 with a JSON array", p.returncode == 0 and isinstance(rows, list), (p.returncode, p.stdout[:200], p.stderr[-200:]))
by_port = {r["port"]: r for r in rows or []}
check("P2 one row per port, the process named, the pid carried",
      set(by_port) == {3000, 8000, 5432} and by_port[3000]["process"] == "node" and by_port[3000]["pid"] == 4242, rows)
check("P3 a server bound on * AND 127.0.0.1 reads as loopback (the narrower truth); [::1] is loopback too",
      by_port[3000]["bind"] == "loopback" and by_port[8000]["bind"] == "loopback" and by_port[5432]["bind"] == "loopback", rows)
check("P4 sshd's own port is left out", 22 not in by_port, rows)
check("P5 every row carries a since (0 when ps knows nothing of a fake pid)", all("since" in r for r in rows or []), rows)
with open(fake, "w") as f:
    f.write("#!/bin/sh\ncat <<'LS'\np1\ncnginx\nn*:8080\nLS\n")
p, rows = run(env)
check("P6 a wildcard-only bind reads as all", rows and rows[0]["bind"] == "all" and rows[0]["port"] == 8080, rows)
with open(fake, "w") as f:
    f.write("#!/bin/sh\nexit 1\n")
p, rows = run(env)
check("P7 lsof failing is an empty list, not a crash", p.returncode == 0 and rows == [], (p.returncode, p.stdout, p.stderr[-200:]))

# ---- the real thing: a listener this test opens is found --------------------
print("=== pervio-ports: a real listener ===")
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.bind(("127.0.0.1", 0)); srv.listen(1)
port = srv.getsockname()[1]
p, rows = run(dict(os.environ))
mine = next((r for r in rows or [] if r["port"] == port), None)
check("R1 a port this test listens on is listed, loopback, with this process's pid and a start time",
      mine is not None and mine["bind"] == "loopback" and mine["pid"] == os.getpid() and mine["since"] > 0, (port, mine, (rows or [])[:3]))
srv.close()
p, rows = run(dict(os.environ))
check("R2 closed, it is gone", not any(r["port"] == port for r in rows or []), [r["port"] for r in rows or []])

n_ok = sum(results); n = len(results)
print("=== pervio-ports: %s (%d/%d) ===" % ("ALL PASS ✅" if n_ok == n else "FAILURES ❌", n_ok, n))
sys.exit(0 if n_ok == n else 1)
