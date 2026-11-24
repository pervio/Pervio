#!/usr/bin/env bash
# Minimal regression tests for server/bin/pervio-term. It's a tmux/PTY tool, so most
# of it can't run headless — we cover what's pure logic: it parses, rejects unknown
# args, expands a "~/sub" dir correctly (the ${dir#~/} bash-3.2 trap), and talks to
# tmux only on its own `-L pervio` socket.
#
# NOTHING here may touch the user's screen or a real tmux server. Every case that
# reaches tmux at all does so through a STUB `tmux` planted at the front of PATH,
# which records its argv and never draws anything. The stub is also what makes the
# coverage deterministic: this file must never decide, at runtime, that it cannot
# test something. A branch that is not exercised is a FAILURE, not a SKIP — a
# silent SKIP is how a suite keeps printing green while the thing it guards rots
# (proven 2026-08-07: with tmux off PATH the old `*)`/`else` SKIPs passed a
# pervio-term whose tilde expansion was deliberately broken).
set -u
TERM_BIN="$(cd "$(dirname "$0")/../bin" && pwd)/pervio-term"
pass=0; fail=0
ok(){ if [ "$1" = "$2" ]; then echo "PASS $3"; pass=$((pass+1)); else echo "FAIL $3 [$1 != $2]"; fail=$((fail+1)); fi; }
bad(){ echo "FAIL $1 [$2]"; fail=$((fail+1)); }
good(){ echo "PASS $1"; pass=$((pass+1)); }

# --- stub tmux: records argv, draws nothing, never reaches the real binary ------
STUB="$(mktemp -d "${TMPDIR:-/tmp}/ptermstub.XXXXXX")"
trap 'rm -rf "$STUB"' EXIT
TMUX_LOG="$STUB/tmux.argv"
cat > "$STUB/tmux" <<STUBEOF
#!/bin/sh
# FAKE tmux. Appends its argv to \$TMUX_LOG and exits. It must never start a
# server, attach a client, or put a single character on the user's screen.
printf '%s\n' "\$*" >> "$TMUX_LOG"
exit "\${STUB_TMUX_RC:-0}"
STUBEOF
chmod 755 "$STUB/tmux"
# pervio-term takes `command -v tmux` first and only falls back to /usr/bin/tmux
# when that is empty, so putting the stub at the FRONT of PATH is what makes the
# fallback unreachable. Case 5 below proves the stub is really what ran.
export PATH="$STUB:$PATH"

# 1. syntax parses
bash -n "$TERM_BIN"; ok "$?" "0" "pervio-term parses (bash -n)"

# 2. unknown arg → exit 2
bash "$TERM_BIN" --bogus >/dev/null 2>&1; ok "$?" "2" "unknown arg rejected (exit 2)"

# 3. ~/subdir tilde expansion — must NOT produce a literal '~' in the path.
#    The stub tmux guarantees this branch is reached on every machine, so there is
#    no environment in which the check quietly disappears.
: > "$TMUX_LOG"
err="$(bash "$TERM_BIN" --dir '~/__pervio_nope__' 2>&1 >/dev/null)"
rc=$?
ok "$rc" "3" "missing --dir exits 3"
case "$err" in
  *"dir missing"*"~"*)     bad "~/sub expands to \$HOME (no literal ~)" "$err" ;;
  *"dir missing"*"$HOME"*) good "~/sub expands to \$HOME (no literal ~)" ;;
  *)                       bad "~/sub expands to \$HOME (no literal ~)" "unexpected: rc=$rc $err" ;;
esac

# 4. X1: a bad --dir must be refused BEFORE anything is asked of tmux. If this
#    ever regresses, a phone tap on a stale project would spawn a session.
if [ -s "$TMUX_LOG" ]; then bad "a missing --dir never reaches tmux" "$(cat "$TMUX_LOG")"
else good "a missing --dir never reaches tmux"; fi

# 5. --list/--kill must speak ONLY to the private `-L pervio` server, never to the
#    tmux the user runs by hand on the desktop.
: > "$TMUX_LOG"
bash "$TERM_BIN" --list >/dev/null 2>&1
listargv="$(cat "$TMUX_LOG")"
case "$listargv" in
  "-L pervio list-sessions") good "--list talks to the private -L pervio socket only" ;;
  *)                        bad  "--list talks to the private -L pervio socket only" "$listargv" ;;
esac
: > "$TMUX_LOG"
bash "$TERM_BIN" --kill --session demo >/dev/null 2>&1
killargv="$(cat "$TMUX_LOG")"
case "$killargv" in
  "-L pervio kill-session -t demo") good "--kill targets -L pervio and the named session" ;;
  *)                               bad  "--kill targets -L pervio and the named session" "$killargv" ;;
esac

echo ""
# 8. Homebrew/non-PATH tmux: the app's SSH shell has a bare PATH, so a brew tmux
#    must be found by the probe list, not by `command -v`. PATH holds no tmux at
#    all; PERVIO_TMUX_DIRS points at a dir whose tmux is the stub → must run it.
PROBE="$(mktemp -d "${TMPDIR:-/tmp}/ptermprobe.XXXXXX")"; EMPTY="$(mktemp -d "${TMPDIR:-/tmp}/ptermempty.XXXXXX")"
cp "$STUB/tmux" "$PROBE/tmux"; chmod 755 "$PROBE/tmux"
: > "$TMUX_LOG"
PERVIO_TMUX_DIRS="$PROBE" PATH="$EMPTY" /bin/bash "$TERM_BIN" --list >/dev/null 2>&1; rc=$?
if [ "$rc" = "0" ] && grep -q "list-sessions" "$TMUX_LOG"; then good "a tmux outside PATH (brew/local) is found by the probe list"
else bad "a tmux outside PATH (brew/local) is found by the probe list" "rc=$rc log=$(cat "$TMUX_LOG")"; fi

# 9. No tmux anywhere: exit 4 and the line the phone shows must SAY the fix.
: > "$TMUX_LOG"
msg="$(PERVIO_TMUX_DIRS="$EMPTY" PATH="$EMPTY" /bin/bash "$TERM_BIN" --list 2>&1 >/dev/null)"; rc=$?
if [ "$rc" = "4" ] && printf '%s' "$msg" | grep -q "brew install tmux" && [ ! -s "$TMUX_LOG" ]; then good "missing tmux: exit 4 and the message names the install command"
else bad "missing tmux: exit 4 and the message names the install command" "rc=$rc msg=$msg"; fi
rm -rf "$PROBE" "$EMPTY"

if [ "$fail" -eq 0 ]; then echo "=== pervio-term: ALL PASS ✅ ($pass/$((pass+fail))) ==="; exit 0
else echo "=== pervio-term: FAILURES ❌ ($pass/$((pass+fail))) ==="; exit 1; fi
