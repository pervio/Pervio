# ios/Tests/Fixtures

Generated — do NOT edit by hand.

    python3 server/tests/export_fixtures.py

Every *.json here is the verbatim stdout of one real server command, run against
a throwaway $HOME built by that script (see its header for the two normalizations
and the single stubbed boundary). `bash server/tests/run_all.sh` re-exports and
fails if anything drifted, so a server-side shape change shows up as a red test
instead of a silently stale fixture.

| fixture | produced by | notes |
| --- | --- | --- |
| `projects.json` | `pervio-sessions projects` |  |
| `home.json` | `pervio-sessions home --dir /home/pervio --top 3 --per 3 --limit 10` | the folders under the default folder (itself excluded), each with its newest rows, + the default folder's own chats |
| `sessions-list.json` | `pervio-sessions list --dir /home/pervio/app` | two claude sessions + one codex thread for the same cwd |
| `transcript.json` | `pervio-sessions transcript --dir /home/pervio/app --session 1a2b3c4d-0000-4000-8000-00000000aaaa` |  |
| `search.json` | `pervio-sessions search --query pervio --limit 30` | cross-project, claude + codex |
| `usage.json` | `pervio-sessions usage` | urlopen stubbed with the endpoint's response shape; scoped pool included |
| `templates.json` | `pervio-orchestrate templates list` | bare spec + market wrapper + playbook + a broken file |
| `archives.json` | `pervio-orchestrate archives list` | schedule-sourced publication (with the schedule join) + a publish-step one |
| `schedules.json` | `pervio-orchestrate schedule list` | PERVIO_TICK_NOW=2026-08-01T09:00, TZ=UTC |
| `runs-list.json` | `pervio-run list` | one done, one running, one failed |
| `serverfs-ls.json` | `SSHService.serverFsScript: ls <dir>` | the app's own wire command over the embedded script |
| `serverfs-ls-missing.json` | `SSHService.serverFsScript: ls <missing path>` | in-band {"error": …}, not a thrown connection failure |
| `serverfs-file.json` | `SSHService.serverFsScript: file <text file>` |  |
| `serverfs-file-fffd.json` | `SSHService.serverFsScript: file <name containing U+FFFD>` | a REAL U+FFFD in the name — addressable; see the R12 note in DecodingTests |
| `serverfs-file-binary.json` | `SSHService.serverFsScript: file <binary file>` | in-band {"error": "binary"} |

Last regenerated: 2026-11-21 (informational — the freshness check compares the *.json fixtures only).
