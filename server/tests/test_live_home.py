#!/usr/bin/env python3
"""The throwaway home of the real-agent suite (test_agents_live.py) — FREE.

That suite spends real quota, so it is opt-in and rarely run; its promise that
"no scenario can create, edit or delete anything in the user's real ~/.pervio"
was false for ten weeks without anything noticing (its list of credential links
named ".pervio" itself, so the real tree was linked in whole). This file holds
that promise in the default, no-cost layer, against a FAKE real home — it never
looks at the machine's own ~/.pervio and never starts an agent.

  H1  the home's ~/.pervio is a directory of its own, born empty
  H2  the real credentials are still reachable (one file, linked by itself)
  H3  what a scenario writes there does not appear in the real home
  H4  cleanup removes the throwaway and leaves the real home exactly as it was
  H5  a home that is NOT isolated is refused — the guard raises
  H6  the suite's own list can never name ~/.pervio again
"""
import importlib.machinery
import importlib.util
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
results = []


def check(name, ok, detail=""):
    results.append(bool(ok))
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  [%s]" % (detail,)))


def load():
    loader = importlib.machinery.SourceFileLoader("agents_live", os.path.join(HERE, "test_agents_live.py"))
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("agents_live", loader))
    loader.exec_module(mod)          # defines things; main() runs only as __main__
    return mod


def tree(root):
    """Every path under root with what it is and, for a file, what it holds."""
    out = {}
    for dp, dns, fns in os.walk(root):
        for n in dns:
            out[os.path.relpath(os.path.join(dp, n), root)] = "dir"
        for n in fns:
            p = os.path.join(dp, n)
            out[os.path.relpath(p, root)] = open(p, "rb").read()
    return out


live = load()

# A stand-in for the person's real home: workflows, a schedule, an archive, a
# credentials file — the things the real suite must never touch.
fake_real = tempfile.mkdtemp(prefix="livehome-real-")
for sub in ("templates", "wf", "schedules", "archives", "papers"):
    os.makedirs(os.path.join(fake_real, ".pervio", sub))
with open(os.path.join(fake_real, ".pervio", "templates", "mine.json"), "w") as f:
    f.write('{"name": "my own workflow"}')
with open(os.path.join(fake_real, ".pervio", "schedules", "s1.json"), "w") as f:
    f.write('{"cron": "30 6 * * *"}')
with open(os.path.join(fake_real, ".pervio", "credentials.env"), "w") as f:
    f.write("EXAMPLE_TOKEN=not-a-real-one\n")
os.makedirs(os.path.join(fake_real, ".claude"))
with open(os.path.join(fake_real, ".claude", "auth"), "w") as f:
    f.write("x")
live.REAL_HOME = fake_real
before = tree(fake_real)

print("=== H1: the home's ~/.pervio is its own, and empty ===")
home = live.LiveHome()
check("H1a ~/.pervio is a real directory, not a link", os.path.isdir(home.pervio) and not os.path.islink(home.pervio))
check("H1b it resolves inside the throwaway home, not to the real one",
      os.path.realpath(home.pervio).startswith(os.path.realpath(home.path) + os.sep)
      and os.path.realpath(home.pervio) != os.path.realpath(os.path.join(fake_real, ".pervio")),
      os.path.realpath(home.pervio))
check("H1c born empty: none of the person's templates or schedules are in it",
      os.listdir(home.templates) == [] and os.listdir(os.path.join(home.pervio, "schedules")) == [],
      (os.listdir(home.templates), os.listdir(os.path.join(home.pervio, "schedules"))))

print("=== H2: the real credentials are still reachable ===")
cred = os.path.join(home.pervio, "credentials.env")
check("H2a credentials.env reads as the real one", os.path.isfile(cred)
      and open(cred).read() == "EXAMPLE_TOKEN=not-a-real-one\n")
check("H2b claude's own directory is the real one", os.path.isfile(os.path.join(home.path, ".claude", "auth")))
links = sorted(n for n in os.listdir(home.pervio) if os.path.islink(os.path.join(home.pervio, n)))
check("H2c that file is the ONLY thing in ~/.pervio that leads outside", links == ["credentials.env"], links)

print("=== H3: what a scenario writes stays in the throwaway ===")
home.write_template("scenario.json", {"name": "written by a test"})
os.makedirs(os.path.join(home.wf_dir("wf123"), "steps"))
with open(os.path.join(home.pervio, "schedules", "t.json"), "w") as f:
    f.write("{}")
shutil.rmtree(os.path.join(home.pervio, "archives"))          # a scenario that deletes
check("H3 the real home is untouched by a write, a new run and a delete", tree(fake_real) == before,
      sorted(set(tree(fake_real)) ^ set(before)))

print("=== H4: cleanup takes the throwaway, and only the throwaway ===")
path = home.path
home.cleanup()
check("H4a the throwaway home is gone", not os.path.exists(path), path)
check("H4b the real home is exactly as it was — credentials file included", tree(fake_real) == before,
      sorted(set(tree(fake_real)) ^ set(before)))

print("=== H5: a home that is not isolated is refused ===")
bad = live.LiveHome()
shutil.rmtree(bad.pervio)
os.symlink(os.path.join(fake_real, ".pervio"), bad.pervio)    # what the old list did
try:
    bad.assert_isolated()
    refused = False
except RuntimeError:
    refused = True
check("H5a the guard raises when ~/.pervio is the real tree", refused)
os.unlink(bad.pervio)
bad.cleanup()
check("H5b and that experiment did not touch the real home either", tree(fake_real) == before)

print("=== H6: the list of links can never name ~/.pervio ===")
check("H6a .pervio is not among the linked directories", ".pervio" not in live.CRED_LINKS, live.CRED_LINKS)
check("H6b nothing linked INTO ~/.pervio is a directory of the person's data",
      not (set(live.PERVIO_CRED_FILES) & set(live.GUARDED)) and "bin" not in live.PERVIO_CRED_FILES,
      live.PERVIO_CRED_FILES)

shutil.rmtree(fake_real, ignore_errors=True)
n = sum(results)
print("\n=== the live suite's throwaway home: %s (%d/%d) ===" % ("ALL PASS" if n == len(results) else "FAILURES", n, len(results)))
sys.exit(0 if n == len(results) else 1)
