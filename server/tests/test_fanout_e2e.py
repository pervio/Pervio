#!/usr/bin/env python3
"""Fan-out real-agent e2e (opt-in; spends ~$0.05). A producer step emits a real
numbered list; a fan-out step splits it and runs one real child agent turn per item.
Asserts every item produced a child result. Run via `run_all.sh --e2e`. Uses the
REAL $HOME so pervio-chat finds ~/.pervio/credentials.env."""
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.realpath(__file__))
ORCH = os.path.realpath(os.path.join(HERE, "..", "bin", "pervio-orchestrate"))
HAIKU = "claude-haiku-4-5-20251001"


def main():
    repo = tempfile.mkdtemp(prefix="foe2e_", dir="/tmp")
    for a in (["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]):
        subprocess.run(["git", "-C", repo] + a, capture_output=True)
    open(os.path.join(repo, "base.txt"), "w").write("base\n")
    subprocess.run(["git", "-C", repo, "add", "-A"], capture_output=True)
    subprocess.run(["git", "-C", repo, "commit", "-qm", "base"], capture_output=True)

    spec = {"name": "foe2e", "dir": repo, "steps": [
        {"id": "make", "backend": "claude", "perm": "plan", "model": HAIKU, "effort": "low",
         "prompt": "Output a compact numbered list of EXACTLY 3 fruits, each line 'N. <fruit>'. Nothing else."},
        {"id": "up", "backend": "claude", "perm": "plan", "model": HAIKU, "effort": "low",
         "fanout": {"over": "{{make.output}}", "split": "numbered", "as": "item", "max": 10, "maxParallel": 3},
         "prompt": "Reply with ONLY the UPPERCASE form of this fruit, nothing else: {{item}}"}]}
    env = dict(os.environ)
    wf = json.loads(subprocess.run([sys.executable, ORCH, "start", "--spec-b64",
                                    base64.b64encode(json.dumps(spec).encode()).decode()],
                                   env=env, capture_output=True, text=True).stdout)["wfId"]
    led = {}
    for _ in range(300):
        led = json.loads(subprocess.run([sys.executable, ORCH, "status", "--wf", wf],
                                        env=env, capture_output=True, text=True).stdout)
        if led.get("status") in ("done", "failed"):
            break
        time.sleep(1)
    w = next((s for s in led.get("steps", []) if s["id"] == "up"), {})
    checks = [
        ("run completed", led.get("status") == "done"),
        ("fan-out split into >=2 real children", (w.get("fanoutTotal") or 0) >= 2),
        ("every child produced a result", w.get("fanoutOk") == w.get("fanoutTotal")),
        ("output carries the N/M summary + per-item results", (w.get("output") or "").split("/")[0].isdigit()),
    ]
    for name, ok in checks:
        print(("PASS " if ok else "FAIL ") + name)
    print("fan-out output:", (w.get("output") or "")[:160].replace("\n", " | "))
    subprocess.run([sys.executable, ORCH, "delete", "--wf", wf], env=env, capture_output=True)
    shutil.rmtree(repo, ignore_errors=True)
    ok = all(c[1] for c in checks)
    print("\n=== fan-out e2e: %s ===" % ("PASS ✅" if ok else "FAIL ❌"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
