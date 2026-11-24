# Contributing

Pervio is open so you can read it, build it and fork it. Bug reports, feature
requests and pull requests are all welcome.

What tends to go well:

- **A bug with steps.** What you did, what you saw, the app build
  (Settings → About), the agent CLI and its version on your computer.
- **A small, focused fix** with a test that fails without it.
- **Talk first for anything larger.** Open an issue describing the change
  before writing it; a feature that does not fit the scope below is a kind "no"
  that is cheaper to hear early.

Scope, so nobody wastes an evening: Pervio is the remote for the hours you are
away from your computer — phone to your own machine over SSH, nothing installed
beyond the scripts the app lays down, no account, no hosted service. Android, a
web client, a desktop app and a cloud relay for conversations are out of scope.

## Before you push

```sh
bash server/tests/run_all.sh     # the server suites: hermetic, no model calls
bash scripts/test-fast.sh        # the same plus the iOS unit tests (needs Xcode)
python3 scripts/public_scan.py   # nothing personal in the tree
```

See [docs/testing.md](docs/testing.md) for what each layer covers.
