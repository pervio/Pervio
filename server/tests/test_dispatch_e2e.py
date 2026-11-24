#!/usr/bin/env python3
"""P4 real-agent e2e (opt-in; spends ~$0.02 of Claude quota). A workflow step with
`allowDispatch: true` actually calls `pervio-dispatch` to spawn a real child claude
turn; asserts the child ran, its real cost landed in the dispatch ledger, its branch
was kept for audit, and its ephemeral worktree was cleaned up. Run via
`bash server/tests/run_all.sh --e2e` or directly. Uses the REAL $HOME so pervio-chat
finds ~/.pervio/credentials.env."""
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


def g(c, *a):
    p = subprocess.run(["git", "-C", c] + list(a), capture_output=True, text=True)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def mkrepo():
    d = tempfile.mkdtemp(prefix="p4e2e_", dir="/tmp")
    for a in (["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]):
        subprocess.run(["git", "-C", d] + a, capture_output=True)
    open(os.path.join(d, "base.txt"), "w").write("base\n")
    subprocess.run(["git", "-C", d, "add", "-A"], capture_output=True)
    subprocess.run(["git", "-C", d, "commit", "-qm", "base"], capture_output=True)
    return d


def main():
    repo = mkrepo()
    child_b64 = base64.b64encode(b"Reply with exactly the single word PONG and nothing else.").decode()
    parent = ("Use the Bash tool to run EXACTLY this one command, nothing else:\n\n"
              "pervio-dispatch --backend claude --model " + HAIKU + " --prompt-b64 " + child_b64 + "\n\n"
              "It prints ONE json line. Report only the value of its \"text\" field.")
    spec = {"name": "p4e2e", "dir": repo, "budgetUSD": 1.0, "steps": [
        {"id": "worker", "backend": "claude", "perm": "default", "model": HAIKU,
         "effort": "low", "allowDispatch": True, "prompt": parent}]}
    env = dict(os.environ)
    b64 = base64.b64encode(json.dumps(spec).encode()).decode()
    wf = json.loads(subprocess.run([sys.executable, ORCH, "start", "--spec-b64", b64],
                                   env=env, capture_output=True, text=True).stdout)["wfId"]
    led = {}
    for _ in range(300):
        led = json.loads(subprocess.run([sys.executable, ORCH, "status", "--wf", wf],
                                        env=env, capture_output=True, text=True).stdout)
        if led.get("status") in ("done", "failed"):
            break
        time.sleep(1)

    ledp = os.path.expanduser("~/.pervio/wf/%s/dispatch/ledger.ndjson" % wf)
    done = [json.loads(l) for l in open(ledp)] if os.path.exists(ledp) else []
    done = [e for e in done if e.get("type") == "done"]
    _, refs, _ = g(repo, "for-each-ref", "--format=%(refname:short)", "refs/heads/pervio/wf-%s/dispatch/" % wf)
    wt_left = g(repo, "worktree", "list", "--porcelain")[1].count("worktree ")

    checks = [
        ("run completed", led.get("status") == "done"),
        ("dispatch recorded a real child cost", len(done) >= 1 and done[0].get("costUSD", 0) > 0),
        ("child branch kept for audit", any("dispatch/worker/" in r for r in refs.splitlines())),
        ("ephemeral worktree cleaned up", wt_left == 1),
    ]
    for name, ok in checks:
        print(("PASS " if ok else "FAIL ") + name)
    print("worker output:", (led.get("steps", [{}])[0].get("output") or "")[:120])

    subprocess.run([sys.executable, ORCH, "delete", "--wf", wf], env=env, capture_output=True)
    shutil.rmtree(repo, ignore_errors=True)
    ok = all(c[1] for c in checks)
    print("\n=== pervio-dispatch e2e: %s ===" % ("PASS ✅" if ok else "FAIL ❌"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
