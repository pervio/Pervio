#!/usr/bin/env bash
# Hermetic SSH endpoint for the iOS end-to-end smoke test (track C).
#
#     bash server/tests/e2e_ios/setup.sh check     # prerequisites only, exit 2 if not ready
#     bash server/tests/e2e_ios/setup.sh start     # bring the endpoint up, print the config path
#     bash server/tests/e2e_ios/setup.sh verify    # start-if-needed, then prove a real chat turn
#     bash server/tests/e2e_ios/setup.sh verify-jump   # prove the ONE-hop chain with stock ssh
#     bash server/tests/e2e_ios/setup.sh verify-chain  # prove the TWO-hop route A→B→C with stock ssh
#     bash server/tests/e2e_ios/setup.sh verify-keyed  # prove the hop that only accepts the SECOND key
#     bash server/tests/e2e_ios/setup.sh rotate    # NEW host key, same address — see "ROTATION"
#     bash server/tests/e2e_ios/setup.sh stale-pin # the host key from BEFORE the last rotate
#     bash server/tests/e2e_ios/setup.sh host-pin  # the host key the server presents NOW
#     bash server/tests/e2e_ios/setup.sh stop      # kill the sshd, remove the sandbox
#     bash server/tests/e2e_ios/setup.sh config-b64  # the launch-argument payload, base64
#
# WHAT IT IS. A throwaway OpenSSH server, started as YOU (no sudo, no root), on
# 127.0.0.1:2222, whose every file lives in one sandbox directory. The phone app
# connects to it exactly as it would to a real dev box: pinned host key, ed25519
# private key, `~/.pervio/bin/pervio-chat --text …` over an exec channel.
#
# WHAT IT NEVER TOUCHES. Not ~/.ssh (no authorized_keys edit, no known_hosts
# entry: the sandbox carries its own AuthorizedKeysFile), not /etc/ssh, not the
# system sshd on port 22 (which keeps running, untouched, on its own port), not
# ~/.pervio, not ~/.claude. Every path this script writes is printed by
# `setup.sh start` and every one of them is under the sandbox root.
#
# HOW THE SANDBOX IS HERMETIC. sshd's ForceCommand runs every incoming command
# through session.sh, which exports HOME=<sandbox>/home and puts the committed
# test shim (server/tests/shim) at the FRONT of PATH. So `~` expands inside the
# sandbox, `~/.pervio/bin/pervio-chat` is the repo's real script (symlinked, not
# copied — a change in server/bin is live here), and the `claude` it finds is the
# no-cost shim, never the real CLI. Zero model calls, zero spend.
#
# THE ECHO CONTRACT. server/tests/shim/claude obeys a `SHIM:{json}` line inside
# the prompt, but a UI test cannot reliably TYPE JSON on a software keyboard. So
# the sandbox puts one more script ahead of it on PATH (agent/claude, generated
# here): it reads the prompt, and asks the committed shim to answer
#     PERVIO_ECHO <the first line of the prompt>
# The shim still does the work — this only scripts it. What that buys the smoke
# test is teeth: the reply carries back the exact nonce the test typed, so a
# green proves the typed bytes reached the server and the server's bytes reached
# the transcript. "Some bubble appeared" cannot satisfy it.
#
# ROTATION. `rotate` is the one thing a fake server cannot imitate: it stops the
# sshd, throws the host key away, generates a NEW one, and starts the sshd again
# on the SAME address with the SAME authorized_keys — exactly what a rebuilt box
# (or an attacker) looks like to a client that pinned the old key. It then proves
# the rotation happened before reporting success: the old line must differ from
# the new one, a real ssh client must still get in, and a real ssh client that
# pins the OLD key must be REFUSED. Only then is the pre-rotation line saved for
# `stale-pin`. Without that self-check, "rotate" could quietly do nothing and
# every test built on it would be certifying itself.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BIN="$REPO/server/bin"
SHIM="$REPO/server/tests/shim"

# One fixed sandbox path so start / verify / stop / the Xcode runner all agree
# without passing state around. Overridable for parallel runs.
ROOT="${PERVIO_E2E_ROOT:-${TMPDIR:-/tmp}/pervio-e2e-ios}"
PORT="${PERVIO_E2E_PORT:-2222}"
# The ROUTE — three daemons in a line, A → B → C, because a "route" is not a
# jump host with a plural name: a two-hop chain is the smallest rig on which
# "which hop failed" can be wrong.
#
#   ENTRY_PORT (A)  the outermost hop; PermitOpen the jump's and keyed's ports
#   JUMP_PORT  (B)  the middle hop;    PermitOpen ONLY the target's port
#   KEYED_PORT (K)  a middle hop that accepts ONLY THE SECOND CLIENT KEY —
#                   see "THE SECOND KEY" below; PermitOpen ONLY the target's port
#   PORT       (C)  the target — the sandbox sshd everything else already uses
#
# Each has its OWN host identity (four different keys), which is what makes
# "pin the wrong hop" a REFUSAL rather than an accident, and PermitOpen makes
# the topology real: A physically cannot reach C, so a client that skipped the
# middle hop could not connect at all.
#
# THE SECOND KEY. Every daemon but K authorizes the same client key, because the
# ordinary route reuses one credential. K authorizes ONLY `client2_ed25519` — a
# machine on the way that has never heard of your key, which is the whole reason
# per-hop credentials exist. A→K→C is therefore a route that can only be walked
# by a client that authenticates hop 2 with a DIFFERENT key from hops 1 and 3;
# no amount of retrying with the profile's own key gets through it. That is what
# makes the iOS per-hop-credential test unfakeable rather than self-certifying.
#
# All hop ports derive from PORT rather than being fixed: layer_ios_unit runs
# its own sandbox on 2223, and a fixed number here would collide with it.
JUMP_PORT="${PERVIO_E2E_JUMP_PORT:-$((PORT + 1))}"
ENTRY_PORT="${PERVIO_E2E_ENTRY_PORT:-$((PORT + 2))}"
KEYED_PORT="${PERVIO_E2E_KEYED_PORT:-$((PORT + 3))}"
ROOT="${ROOT%/}"
# Canonical spelling (pwd -P): $TMPDIR is /var/folders/… which is really
# /private/var/…, and may end in "/". The agent records its cwd as the kernel
# spells it (realpath), the phone asks for the project by the spelling in
# config.json — they must be the same string, or the conversation list looks
# in one folder while the transcript sits in another (seen 2026-10-15).
ROOT="$(cd "$(dirname "$ROOT")" 2>/dev/null && pwd -P)/$(basename "$ROOT")"

HOME_DIR="$ROOT/home"
SSH_DIR="$ROOT/ssh"
AGENT_DIR="$ROOT/agent"
PROJ_DIR="$HOME_DIR/e2eproj"
PID_FILE="$ROOT/sshd.pid"
LOG_FILE="$ROOT/sshd.log"
JUMP_PID_FILE="$ROOT/jump_sshd.pid"
JUMP_LOG_FILE="$ROOT/jump_sshd.log"
ENTRY_PID_FILE="$ROOT/entry_sshd.pid"
ENTRY_LOG_FILE="$ROOT/entry_sshd.log"
KEYED_PID_FILE="$ROOT/keyed_sshd.pid"
KEYED_LOG_FILE="$ROOT/keyed_sshd.log"
# A page on the sandbox "Mac" for the web preview (2026-11-06): a plain HTTP
# server on the loopback, reachable from the phone only through the SSH tunnel.
HTTP_PORT="${PERVIO_E2E_HTTP_PORT:-$((PORT + 4))}"
HTTP_PID_FILE="$ROOT/http.pid"
HTTP_LOG_FILE="$ROOT/http.log"
HTTP_JSON="$ROOT/http.json"
CONFIG_JSON="$ROOT/config.json"
# The host key the server presented BEFORE the last `rotate`. Written only by a
# rotation that proved itself, so its mere existence means "this endpoint really
# changed identity, and this is the identity it had".
STALE_PUB="$SSH_DIR/stale_host_ed25519.pub"

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf 'setup.sh: %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------- prerequisites

# Everything the endpoint needs, each reported by name so a failure is a
# shopping list and not a mystery. Exit 2 = "environment not ready" (track C is
# allowed to degrade); exit 0 = ready.
cmd_check() {
  local missing=0
  _need() {  # $1 = human name, $2 = test command
    if eval "$2" >/dev/null 2>&1; then
      say "  ok      $1"
    else
      say "  MISSING $1"
      missing=$((missing + 1))
    fi
  }
  say "e2e_ios prerequisites:"
  _need "sshd binary (/usr/sbin/sshd)"          "[ -x /usr/sbin/sshd ]"
  _need "ssh client"                            "command -v ssh"
  _need "ssh-keygen"                            "command -v ssh-keygen"
  _need "python3 (the shim's interpreter)"      "command -v python3"
  _need "repo server/bin/pervio-chat"            "[ -x '$BIN/pervio-chat' ]"
  _need "repo server/tests/shim/claude"         "[ -x '$SHIM/claude' ]"
  # A port already in use by SOMETHING ELSE is the one failure that looks like a
  # green (we'd talk to a stranger's sshd), so it is a hard check unless the
  # listener is our own sandbox.
  if is_running; then
    say "  ok      port $PORT (already ours: pid $(cat "$PID_FILE"))"
  elif port_open; then
    say "  MISSING port $PORT is taken by another process"
    missing=$((missing + 1))
  else
    say "  ok      port $PORT free"
  fi
  if is_running "$JUMP_PID_FILE"; then
    say "  ok      jump port $JUMP_PORT (already ours: pid $(cat "$JUMP_PID_FILE"))"
  elif port_open "$JUMP_PORT"; then
    say "  MISSING jump port $JUMP_PORT is taken by another process"
    missing=$((missing + 1))
  else
    say "  ok      jump port $JUMP_PORT free"
  fi
  if is_running "$ENTRY_PID_FILE"; then
    say "  ok      entry port $ENTRY_PORT (already ours: pid $(cat "$ENTRY_PID_FILE"))"
  elif port_open "$ENTRY_PORT"; then
    say "  MISSING entry port $ENTRY_PORT is taken by another process"
    missing=$((missing + 1))
  else
    say "  ok      entry port $ENTRY_PORT free"
  fi
  if is_running "$KEYED_PID_FILE"; then
    say "  ok      keyed port $KEYED_PORT (already ours: pid $(cat "$KEYED_PID_FILE"))"
  elif port_open "$KEYED_PORT"; then
    say "  MISSING keyed port $KEYED_PORT is taken by another process"
    missing=$((missing + 1))
  else
    say "  ok      keyed port $KEYED_PORT free"
  fi
  if [ "$missing" -gt 0 ]; then
    warn "e2e_ios: environment NOT ready ($missing missing)"
    return 2
  fi
  say "e2e_ios: environment ready"
  return 0
}

port_open() { nc -z -w 2 127.0.0.1 "${1:-$PORT}" >/dev/null 2>&1; }

is_running() {  # $1 = pid file (defaults to the main sshd's)
  local f="${1:-$PID_FILE}"
  [ -f "$f" ] || return 1
  local pid; pid="$(cat "$f" 2>/dev/null)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" >/dev/null 2>&1
}

# The OpenSSH line the sandbox's sshd presents right now: "type blob", no
# comment — the exact shape the app pins and the tests compare.
host_line() { awk '{print $1" "$2}' "$SSH_DIR/host_ed25519.pub"; }

# --------------------------------------------------- sshd up / down (reusable)
#
# Split out of start/stop because `rotate` has to cycle the DAEMON without
# touching the sandbox around it: the same client key, the same authorized_keys,
# the same temp HOME, the same port — only the server's identity changes.

start_sshd() {  # $1 = sshd_config (default main), $2 = port, $3 = log
  local conf="${1:-$SSH_DIR/sshd_config}" port="${2:-$PORT}" log="${3:-$LOG_FILE}"
  /usr/sbin/sshd -f "$conf" -E "$log" \
    || die "sshd failed to start — see $log"
  # sshd forks; wait for the socket rather than guessing.
  local i=0
  while [ "$i" -lt 50 ]; do
    port_open "$port" && break
    sleep 0.1
    i=$((i + 1))
  done
  port_open "$port" || die "sshd did not start listening on $port — see $log"
}

# The web preview's page: a token of this sandbox's own in its body, so the UI
# test can tell the page it opened came through THIS tunnel and not from a
# cache or another run. http.json carries port and token to run_smoke.sh.
start_http() {
  local www="$ROOT/www" token="webtoken-$(date +%s)-$$"
  mkdir -p "$www"
  cat > "$www/index.html" <<HTML
<!doctype html><html><head><meta charset="utf-8"><title>Pervio sandbox page</title></head>
<body><h1>PERVIO_WEB_PAGE</h1><p id="token">$token</p><p><a href="/second.html">second page</a></p></body></html>
HTML
  cat > "$www/second.html" <<HTML
<!doctype html><html><head><meta charset="utf-8"><title>Second</title></head><body><h1>PERVIO_WEB_SECOND</h1></body></html>
HTML
  ( cd "$www" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 ) >"$HTTP_LOG_FILE" 2>&1 &
  echo $! > "$HTTP_PID_FILE"
  local i=0
  while [ "$i" -lt 50 ]; do
    port_open "$HTTP_PORT" && break
    sleep 0.1
    i=$((i + 1))
  done
  port_open "$HTTP_PORT" || die "the sandbox page did not start listening on $HTTP_PORT — see $HTTP_LOG_FILE"
  printf '{"port": %s, "token": "%s"}\n' "$HTTP_PORT" "$token" > "$HTTP_JSON"
}

stop_http() {
  is_running "$HTTP_PID_FILE" || return 0
  local pid; pid="$(cat "$HTTP_PID_FILE")"
  kill "$pid" 2>/dev/null
  local i=0
  while [ "$i" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  kill -9 "$pid" 2>/dev/null
  rm -f "$HTTP_PID_FILE"
}

# Stops the daemon and waits for the PORT to go quiet, not just for the process
# to die: a restart that races the old listener's socket loses the bind, and the
# rotation would come back "sshd failed to start" for no reason a reader could
# see.
stop_sshd() {  # $1 = pid file (default main), $2 = port
  local pidf="${1:-$PID_FILE}" port="${2:-$PORT}"
  is_running "$pidf" || return 0
  local pid; pid="$(cat "$pidf")"
  kill "$pid" 2>/dev/null
  local i=0
  while [ "$i" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  kill -9 "$pid" 2>/dev/null
  i=0
  while [ "$i" -lt 50 ] && port_open "$port"; do sleep 0.1; i=$((i + 1)); done
  rm -f "$pidf"
  printf '%s\n' "$pid"
}

# ---------------------------------------------------------------------- start

cmd_start() {
  if is_running; then
    say "e2e_ios: already up (pid $(cat "$PID_FILE"), port $PORT)"
    say "$CONFIG_JSON"
    return 0
  fi
  cmd_check >/dev/null || { cmd_check; return 2; }

  rm -rf "$ROOT"
  mkdir -p "$SSH_DIR" "$AGENT_DIR" "$HOME_DIR/.pervio" "$PROJ_DIR" || die "cannot create sandbox at $ROOT"
  chmod 700 "$ROOT" "$SSH_DIR" "$HOME_DIR"

  write_agent_double
  seed_project_history
  seed_provider

  # The launchers are the REPO's scripts, reached by symlink: the smoke test must
  # exercise what ships, and `readlink -f` inside pervio-chat then resolves its
  # siblings (pervio-hb, pervio-mcp, …) out of server/bin the same way a real
  # deployment resolves them out of ~/.pervio/bin.
  # A real directory of PER-FILE symlinks, not one symlink to server/bin: the
  # app paves ~/.pervio/bin on connect when it finds no revision stamp, and
  # through a directory symlink that pave wrote its stamp and chmods INTO the
  # repo's server/bin (seen 2026-10-15: three scripts' modes flipped, a stray
  # .pervio-rev). With per-file links the pave replaces links inside the
  # sandbox and the repo is never touched; an unpaved sandbox still runs the
  # repo's live scripts through the links.
  mkdir -p "$HOME_DIR/.pervio/bin" || die "cannot create launcher dir"
  for f in "$BIN"/*; do
    case "$(basename "$f")" in __pycache__|.pervio-rev) continue ;; esac
    ln -s "$f" "$HOME_DIR/.pervio/bin/$(basename "$f")" || die "cannot link launcher $(basename "$f")"
  done

  ssh-keygen -q -t ed25519 -f "$SSH_DIR/host_ed25519" -N '' -C 'pervio-e2e-host' \
    || die "ssh-keygen (host key) failed"
  ssh-keygen -q -t ed25519 -f "$SSH_DIR/client_ed25519" -N '' -C 'pervio-e2e-client' \
    || die "ssh-keygen (client key) failed"
  cp "$SSH_DIR/client_ed25519.pub" "$SSH_DIR/authorized_keys"
  chmod 600 "$SSH_DIR/authorized_keys"

  # The SECOND client key, and the authorized_keys that holds ONLY it. Nothing
  # else on the rig accepts it and it accepts nothing else — that separation is
  # the entire experiment: a hop reachable only with a credential the rest of
  # the route never uses.
  ssh-keygen -q -t ed25519 -f "$SSH_DIR/client2_ed25519" -N '' -C 'pervio-e2e-client2' \
    || die "ssh-keygen (second client key) failed"
  cp "$SSH_DIR/client2_ed25519.pub" "$SSH_DIR/authorized_keys_keyed"
  chmod 600 "$SSH_DIR/authorized_keys_keyed"

  # ForceCommand target: this is what makes the session hermetic. sshd hands us
  # the client's command in SSH_ORIGINAL_COMMAND; we re-export HOME/PATH first so
  # the app's `~/.pervio/bin/pervio-chat` and its `claude` both resolve inside the
  # sandbox. An interactive login (no command) gets a shell in the sandbox too.
  cat > "$SSH_DIR/session.sh" <<SESSION
#!/bin/sh
# Hermetic session wrapper — generated by server/tests/e2e_ios/setup.sh.
HOME='$HOME_DIR'
PATH='$AGENT_DIR:$SHIM:$HOME_DIR/.pervio/bin:/usr/bin:/bin:/usr/sbin:/sbin'
PERVIO_E2E=1
# The committed shim appends one JSON line per agent start with the ANTHROPIC_*
# / PERVIO_PROVIDER* it was given — the only proof that a turn really rode a
# provider overlay (the phone's badge can say one thing and the command another).
SHIM_ENV_LOG='$ROOT/shim_env.log'
export HOME PATH PERVIO_E2E SHIM_ENV_LOG
cd "\$HOME" || exit 1
if [ -n "\${SSH_ORIGINAL_COMMAND:-}" ]; then
  exec /bin/bash -c "\$SSH_ORIGINAL_COMMAND"
fi
exec /bin/bash -l
SESSION
  chmod 700 "$SSH_DIR/session.sh"

  cat > "$SSH_DIR/sshd_config" <<CONF
# Generated by server/tests/e2e_ios/setup.sh — throwaway, sandbox-only.
Port $PORT
ListenAddress 127.0.0.1
HostKey $SSH_DIR/host_ed25519
AuthorizedKeysFile $SSH_DIR/authorized_keys
PidFile $PID_FILE
# The sandbox lives under \$TMPDIR, whose ancestors are not 0755-clean the way
# StrictModes demands; the keys themselves are 0600 and owner-only.
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitUserEnvironment no
PermitTunnel no
# Local forwarding to the loopback only: the web preview's tunnel (2026-11-06)
# rides a direct-tcpip channel to 127.0.0.1:<port>, never to another host.
AllowTcpForwarding local
PermitOpen 127.0.0.1:* localhost:*
X11Forwarding no
PrintMotd no
# The app opens SEVERAL connections at once (session browser, run monitor, home
# publications), and a cold simulator can be slow to finish a handshake. Measured
# 2026-08-07 with a 30s grace: four simultaneous connects tripped "Timeout before
# authentication", which armed OpenSSH 9.8+'s per-source penalties — and since
# every connection here comes from 127.0.0.1, the penalty then dropped ALL of
# them and the app showed "Couldn't load projects." So: the stock grace time, a
# high startup ceiling, and NO penalties. Penalties defend an internet-facing
# sshd from strangers; on a loopback test rig they only shoot the client.
LoginGraceTime 120
MaxStartups 100
ForceCommand $SSH_DIR/session.sh
LogLevel VERBOSE
CONF
  # PerSourcePenalties is OpenSSH 9.8+; adding it blind would make an older sshd
  # refuse to start, so only append it if this sshd admits to knowing it.
  if /usr/sbin/sshd -t -f "$SSH_DIR/sshd_config" -o "PerSourcePenalties no" >/dev/null 2>&1; then
    printf 'PerSourcePenalties no\n' >> "$SSH_DIR/sshd_config"
  fi

  # ------------------------------------------------------- the two hop daemons
  # The route: ENTRY (A) → JUMP (B) → the sandbox sshd (C). Each hop is its own
  # daemon with its OWN host identity, because the app pins EVERY hop and only a
  # server that really presents a different key per hop can prove each pin is
  # enforced against the right machine. Same authorized_keys throughout (the app
  # reuses one credential for the whole route); ForceCommand keeps any session
  # hermetic.
  #
  #  * AllowTcpForwarding local + PermitOpen ONE address — each hop can carry a
  #    direct-tcpip channel to exactly the NEXT machine and nowhere else, like a
  #    locked-down bastion. That is what makes the topology real instead of
  #    decorative: A physically cannot reach C, so a client that skipped B could
  #    not connect at all, and a client that "connected" without traversing both
  #    hops is impossible rather than merely unlikely.
  #  * LogLevel DEBUG1 — sshd only names the direct-tcpip target at debug level,
  #    and the iOS chain tests grep these logs to prove the bytes went THROUGH
  #    each hop (a direct connect to the target would leave both logs empty —
  #    the hollow green the assertions exist to kill).
  # Hop A may reach EITHER middle hop and still nothing else — the target is not
  # in its PermitOpen, so "A physically cannot deliver C" is unchanged. What it
  # buys is a second two-hop route (A→K→C) over the same entry hop, so the
  # per-hop-credential test differs from the ordinary route test in exactly one
  # thing: which key opens the middle machine.
  write_hop_sshd jump  "$JUMP_PORT"  "$PORT"                  "$JUMP_PID_FILE"
  write_hop_sshd keyed "$KEYED_PORT" "$PORT"                  "$KEYED_PID_FILE" \
                 "$SSH_DIR/authorized_keys_keyed"
  write_hop_sshd entry "$ENTRY_PORT" "$JUMP_PORT $KEYED_PORT" "$ENTRY_PID_FILE"

  start_sshd
  start_sshd "$SSH_DIR/jump_sshd_config"  "$JUMP_PORT"  "$JUMP_LOG_FILE"
  start_sshd "$SSH_DIR/keyed_sshd_config" "$KEYED_PORT" "$KEYED_LOG_FILE"
  start_sshd "$SSH_DIR/entry_sshd_config" "$ENTRY_PORT" "$ENTRY_LOG_FILE"
  start_http

  write_config

  say "e2e_ios: up on 127.0.0.1:$PORT (pid $(cat "$PID_FILE" 2>/dev/null))"
  say "  entry sshd   127.0.0.1:$ENTRY_PORT (pid $(cat "$ENTRY_PID_FILE" 2>/dev/null)) — direct-tcpip to $JUMP_PORT/$KEYED_PORT only  [hop A]"
  say "  jump sshd    127.0.0.1:$JUMP_PORT (pid $(cat "$JUMP_PID_FILE" 2>/dev/null)) — direct-tcpip to $PORT only  [hop B]"
  say "  keyed sshd   127.0.0.1:$KEYED_PORT (pid $(cat "$KEYED_PID_FILE" 2>/dev/null)) — SECOND client key only  [hop K]"
  say "  route        A:$ENTRY_PORT → B:$JUMP_PORT → C:$PORT (four distinct host keys)"
  say "  sandbox page 127.0.0.1:$HTTP_PORT (pid $(cat "$HTTP_PID_FILE" 2>/dev/null)) — the web preview's target, loopback only"
  say "  keyed route  A:$ENTRY_PORT → K:$KEYED_PORT → C:$PORT (K accepts client2 ONLY)"
  say "  sandbox      $ROOT"
  say "  temp HOME    $HOME_DIR"
  say "  launchers    $HOME_DIR/.pervio/bin -> $BIN"
  say "  shim on PATH $SHIM"
  say "  ~/.ssh       UNTOUCHED (authorized_keys lives at $SSH_DIR/authorized_keys)"
  say "$CONFIG_JSON"
}

# One hop of the route: its own host key, its own sshd_config, and a PermitOpen
# that lets it reach exactly the machines named — and nothing else.
#   $1 = name ("jump" | "entry" | "keyed")  $2 = listen port
#   $3 = the port(s) it may open a direct-tcpip channel to (space-separated)
#   $4 = pid file
#   $5 = authorized_keys file (default: the shared one every other hop uses)
write_hop_sshd() {
  local name="$1" port="$2" nexthop="$3" pidf="$4"
  local authkeys="${5:-$SSH_DIR/authorized_keys}"
  local key="$SSH_DIR/${name}_host_ed25519" conf="$SSH_DIR/${name}_sshd_config"
  local permit="" p
  # PermitOpen takes several destinations on ONE line; building it here (rather
  # than hardcoding a single "$nexthop") is what lets the entry hop carry either
  # middle machine without widening it to "any".
  for p in $nexthop; do permit="$permit 127.0.0.1:$p"; done
  ssh-keygen -q -t ed25519 -f "$key" -N '' -C "pervio-e2e-${name}-host" \
    || die "ssh-keygen ($name host key) failed"
  cat > "$conf" <<CONF
# Generated by server/tests/e2e_ios/setup.sh — throwaway $name hop, sandbox-only.
Port $port
ListenAddress 127.0.0.1
HostKey $key
AuthorizedKeysFile $authkeys
PidFile $pidf
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitUserEnvironment no
PermitTunnel no
AllowTcpForwarding local
PermitOpen$permit
X11Forwarding no
PrintMotd no
LoginGraceTime 120
MaxStartups 100
ForceCommand $SSH_DIR/session.sh
LogLevel DEBUG1
CONF
  if /usr/sbin/sshd -t -f "$conf" -o "PerSourcePenalties no" >/dev/null 2>&1; then
    printf 'PerSourcePenalties no\n' >> "$conf"
  fi
}

# One past conversation, so `pervio-sessions projects` reports a project and the
# app's Projects screen has a row to tap.
#
# This is what the smoke test navigates through, and the reason is worth writing
# down: the home screen's "New chat" shortcut CANNOT be used. Its three cards
# (New chat / Workflows / Build) are three NavigationLinks inside ONE List row,
# and SwiftUI collapses those into a single row activation — tapping "New chat"
# opens "Build". Proven here on 2026-08-07: the tap logged as `Tap "New chat"
# Button` and the screen that came up had the workflow-builder prompt already in
# the composer. Servers → project → New conversation is one link per row, so it
# goes where it says.
seed_project_history() {
  # Into the folder Claude Code itself would use for this cwd (its encoding:
  # every non-alphanumeric → "-"), so the seed and the agent double's
  # transcripts share one folder and the project lists once.
  PERVIO_CWD="$PROJ_DIR" PERVIO_HOME="$HOME_DIR" python3 - <<'PY'
import json, os, re, sys
cwd = os.environ["PERVIO_CWD"]
folder = os.path.join(os.environ["PERVIO_HOME"], ".claude", "projects", re.sub(r"[^A-Za-z0-9]", "-", cwd))
os.makedirs(folder, exist_ok=True)
# A LONG conversation (30 turns), so a smoke test can scroll up into history
# and prove a landing reply does not move the reader. Titled by its first line.
lines = []
for i in range(1, 31):
    text = ("e2e long history conversation seeded for the smoke test" if i == 1
            else "seed user %d asks about the %dth thing in a sentence long enough to wrap on a phone" % (i, i))
    lines.append({"type": "user", "cwd": cwd, "uuid": "e2e-seed-u%d" % i,
                  "message": {"role": "user", "content": text}})
    lines.append({"type": "assistant", "cwd": cwd, "uuid": "e2e-seed-a%d" % i,
                  "message": {"role": "assistant", "model": "e2e-shim",
                              "content": [{"type": "text", "text": "seed reply %d, two lines of answer so the row has height\nand a second line." % i}]}})
with open(os.path.join(folder, "00000000-0000-4000-8000-0000000000e2.jsonl"), "w") as f:
    for line in lines:
        f.write(json.dumps(line) + "\n")
PY
}

# The scripted agent (see "THE ECHO CONTRACT" at the top). It does NOT replace
# the committed shim — it drives it, so the stream-json the app parses is still
# the shim's, byte for byte.
# One third-party provider in the sandbox's roster, so the phone's engine badge
# offers "Claude · E2E Vendor" and a turn on it must reach the shim with
# ANTHROPIC_BASE_URL=https://e2e.invalid/anthropic (shim_env.log). Same file
# shape pervio-provider writes (0700 dir, 0600 file); the key is a dummy.
seed_provider() {
  local dir="$HOME_DIR/.pervio/providers"
  mkdir -p "$dir" && chmod 700 "$dir"
  cat > "$dir/e2e.env" <<'ENV'
ENGINE=claude
LABEL='E2E Vendor'
BASE_URL=https://e2e.invalid/anthropic
API_KEY=e2e-dummy-key
MODELS=e2e-model-a,e2e-model-b
DEFAULT_MODEL=e2e-model-a
MODELS_SOURCE=manual
ENV
  chmod 600 "$dir/e2e.env"
}

write_agent_double() {
  cat > "$AGENT_DIR/claude" <<AGENT
#!/usr/bin/env python3
"""Agent double for the iOS smoke test — generated by server/tests/e2e_ios/setup.sh.

Takes the first line of the prompt as the user's typed text and asks the
COMMITTED shim (server/tests/shim/claude) to answer "PERVIO_ECHO <that text>".
The shim produces the events; this only scripts what it says, so a UI test can
assert on a token it typed itself instead of on generic prose.

Two faces, like the real CLI (2026-10-21): a plain-text prompt on stdin is one
turn (chat mode); with --input-format stream-json and a JSON user message as
the first line (a living run: pervio-run's keeper feeds the turns and never
closes the pipe) it relays each message into ONE shim process, scripting the
reply per turn, and leaves when the pipe closes."""
import json
import os
import re
import subprocess
import sys
import time
import uuid

SHIM = "$SHIM/claude"
LOG = "$ROOT/agent.log"

argv = sys.argv[1:]
sid = argv[argv.index("--resume") + 1] if "--resume" in argv and argv.index("--resume") + 1 < len(argv) else str(uuid.uuid4())
cwd = os.getcwd()
folder = os.path.join(os.path.expanduser("~"), ".claude", "projects", re.sub(r"[^A-Za-z0-9]", "-", cwd))


def script(prompt):
    """Per turn: pick the typed line, answer late if it says "slow …", write the
    transcript the phone's conversation list reads, log it; returns the reply."""
    first = ""
    for line in prompt.splitlines():
        s = line.strip()
        if s and not s.startswith("SHIM:"):
            first = s
            break
    reply = "PERVIO_ECHO " + first[:200]
    # "slow …": answer late, so a test can scroll around while the turn is in flight.
    if first.lower().startswith("slow "):
        time.sleep(40)      # XCUITest types, swipes and maps rows slowly; the reply must land AFTER all that
    # A conversation per chat, like the real CLI: --resume names an existing one,
    # otherwise a fresh id — and each turn is appended to the transcript under
    # ~/.claude/projects/<encoded cwd>/<id>.jsonl (the shape pervio-sessions reads),
    # so the phone's conversation list shows it, titled by its first message, and
    # a smoke test can leave the chat and come back to it.
    try:
        os.makedirs(folder, exist_ok=True)
        now = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
        with open(os.path.join(folder, sid + ".jsonl"), "a") as f:
            f.write(json.dumps({"type": "user", "cwd": cwd, "uuid": str(uuid.uuid4()), "timestamp": now,
                                "sessionId": sid, "message": {"role": "user", "content": first}}) + "\n")
            f.write(json.dumps({"type": "assistant", "cwd": cwd, "uuid": str(uuid.uuid4()), "timestamp": now,
                                "sessionId": sid, "message": {"role": "assistant", "model": "e2e-shim",
                                                               "content": [{"type": "text", "text": reply}]}}) + "\n")
    except OSError:
        pass
    try:
        with open(LOG, "a") as f:
            f.write(json.dumps({"argv": argv, "sid": sid, "prompt": prompt[:400], "reply": reply}) + "\n")
    except OSError:
        pass
    return reply


def background(prompt):
    """"agents …": the turn also starts two sub-agents and two background
    commands, one of them a sub-agent's own (the shim's `bg` list — the events
    of a real Claude Code 2.1.322). They outlast the reply by tens of seconds:
    XCUITest needs that long to open the list and read a row."""
    first = next((l.strip() for l in prompt.splitlines() if l.strip() and not l.strip().startswith("SHIM:")), "")
    if not first.lower().startswith("agents "):
        return {}
    return {"bg": [
        {"id": "a1", "desc": "Review the diff", "agent": "general-purpose", "secs": 50, "text": "review done",
         "progress": [{"after": 1, "desc": "Reading app.py", "tokens": 9871, "tools": 1},
                      {"after": 3, "desc": "Running pytest", "tokens": 12045, "tools": 3}]},
        {"id": "b1", "desc": "pytest -q", "parent": "a1", "secs": 28, "text": "tests done"},
        {"id": "a2", "desc": "Find the callers", "agent": "Explore", "secs": 40, "text": "three callers",
         "progress": [{"after": 2, "desc": "Searching for upload", "tokens": 4100, "tools": 2}]},
        {"id": "c1", "desc": "npm run build", "secs": 34, "text": "build done", "status": "failed"}]}


def message_text(line):
    try:
        o = json.loads(line)
    except ValueError:
        return None
    if not isinstance(o, dict) or o.get("type") != "user":
        return None
    c = (o.get("message") or {}).get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
    return None


first = sys.stdin.readline()
if "--input-format" in argv and "stream-json" in argv and message_text(first.strip()) is not None:
    # Living run: one shim for the whole life of the run, a turn per message.
    shim = subprocess.Popen([SHIM] + argv, stdin=subprocess.PIPE, text=True)
    line = first
    while line:
        text = message_text(line.strip())
        if text is not None:
            reply = script(text)
            # Appended LAST: the shim keeps the last SHIM: line it sees.
            scripted = text + "\nSHIM:" + json.dumps(dict({"text": reply, "sid": sid}, **background(text))) + "\n"
            try:
                shim.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": scripted}}) + "\n")
                shim.stdin.flush()
            except (BrokenPipeError, OSError):
                break
        elif line.strip():
            # Not a message: a control line for the engine (stop_task), passed on as it came.
            try:
                shim.stdin.write(line if line.endswith("\n") else line + "\n")
                shim.stdin.flush()
            except (BrokenPipeError, OSError):
                break
        line = sys.stdin.readline()
    try:
        shim.stdin.close()
    except OSError:
        pass
    sys.exit(shim.wait())
else:
    # One prompt as plain text, one turn, the way the one-shot CLI reads it.
    prompt = first + sys.stdin.read()
    reply = script(prompt)
    # Appended LAST: the shim keeps the last SHIM: line it sees, so this wins over
    # anything the prompt itself carried.
    scripted = prompt + "\nSHIM:" + json.dumps({"text": reply, "sid": sid}) + "\n"
    done = subprocess.run([SHIM] + argv, input=scripted, text=True)
    sys.exit(done.returncode)
AGENT
  chmod 700 "$AGENT_DIR/claude"
}

# The single source of truth the iOS side consumes. `privateKey` is the sandbox
# client key (thrown away on stop); `pinnedHostKey` is the sandbox host key, so
# the app's mandatory pinning is satisfied without a trust-on-first-use prompt.
write_config() {
  local hostline priv priv2 jumpline entryline keyedline
  hostline="$(awk '{print $1" "$2}' "$SSH_DIR/host_ed25519.pub")"
  priv="$(cat "$SSH_DIR/client_ed25519")"
  # Each hop block is present only when that daemon was set up (an older sandbox
  # dir has no hop keys) — the iOS side treats a missing block as "no chain to
  # test" and skips honestly rather than failing on someone else's sandbox.
  jumpline=""
  [ -f "$SSH_DIR/jump_host_ed25519.pub" ] \
    && jumpline="$(awk '{print $1" "$2}' "$SSH_DIR/jump_host_ed25519.pub")"
  entryline=""
  [ -f "$SSH_DIR/entry_host_ed25519.pub" ] \
    && entryline="$(awk '{print $1" "$2}' "$SSH_DIR/entry_host_ed25519.pub")"
  keyedline=""
  priv2=""
  if [ -f "$SSH_DIR/keyed_host_ed25519.pub" ] && [ -f "$SSH_DIR/client2_ed25519" ]; then
    keyedline="$(awk '{print $1" "$2}' "$SSH_DIR/keyed_host_ed25519.pub")"
    priv2="$(cat "$SSH_DIR/client2_ed25519")"
  fi
  PERVIO_HOSTLINE="$hostline" PERVIO_PRIV="$priv" PERVIO_PRIV2="$priv2" \
  PERVIO_USER="$(id -un)" PERVIO_PORT="$PORT" PERVIO_PROJ="$PROJ_DIR" \
  PERVIO_JUMPLINE="$jumpline" PERVIO_JUMP_PORT="$JUMP_PORT" \
  PERVIO_JUMP_LOG="$JUMP_LOG_FILE" \
  PERVIO_ENTRYLINE="$entryline" PERVIO_ENTRY_PORT="$ENTRY_PORT" \
  PERVIO_ENTRY_LOG="$ENTRY_LOG_FILE" \
  PERVIO_KEYEDLINE="$keyedline" PERVIO_KEYED_PORT="$KEYED_PORT" \
  PERVIO_KEYED_LOG="$KEYED_LOG_FILE" \
  python3 - "$CONFIG_JSON" <<'PY'
import json, os, sys
cfg = {
    "name": "E2E Sandbox",
    "host": "127.0.0.1",
    "port": int(os.environ["PERVIO_PORT"]),
    "username": os.environ["PERVIO_USER"],
    "projectDir": os.environ["PERVIO_PROJ"],
    "launcherDir": "~/.pervio/bin",
    "pinnedHostKey": os.environ["PERVIO_HOSTLINE"],
    "privateKey": os.environ["PERVIO_PRIV"],
    # Shim-friendly knobs: the shim ignores argv, but these keep the command the
    # app builds identical in shape to a production turn.
    "model": "",
    "effort": "",
    "permissionMode": "default",
    "backend": "claude",
}
if os.environ.get("PERVIO_JUMPLINE"):
    # Hop B — the one closest to the target; it may open a direct-tcpip channel
    # to the target and nowhere else.
    cfg["jump"] = {
        "host": "127.0.0.1",
        "port": int(os.environ["PERVIO_JUMP_PORT"]),
        "pinnedHostKey": os.environ["PERVIO_JUMPLINE"],
        # The jump sshd's DEBUG1 log: the chain test greps it for the
        # direct-tcpip open, the proof its bytes went through the jump.
        "logFile": os.environ["PERVIO_JUMP_LOG"],
    }
if os.environ.get("PERVIO_ENTRYLINE"):
    # Hop A — the OUTERMOST hop, the one the phone dials directly. It may open a
    # direct-tcpip channel to hop B or hop K and nowhere else, so a two-hop route
    # is the only way from here to the target.
    cfg["entry"] = {
        "host": "127.0.0.1",
        "port": int(os.environ["PERVIO_ENTRY_PORT"]),
        "pinnedHostKey": os.environ["PERVIO_ENTRYLINE"],
        "logFile": os.environ["PERVIO_ENTRY_LOG"],
    }
if os.environ.get("PERVIO_KEYEDLINE") and os.environ.get("PERVIO_PRIV2"):
    # Hop K — a middle hop that authorizes ONLY `privateKey2`. Reachable from
    # hop A, opens a channel to the target and nowhere else, and refuses the
    # client key every other machine here accepts. Both halves ship together:
    # without the second private key the hop is unusable, so the iOS side treats
    # a missing pair as "no per-hop-credential rig" and skips.
    cfg["keyed"] = {
        "host": "127.0.0.1",
        "port": int(os.environ["PERVIO_KEYED_PORT"]),
        "pinnedHostKey": os.environ["PERVIO_KEYEDLINE"],
        "logFile": os.environ["PERVIO_KEYED_LOG"],
    }
    cfg["privateKey2"] = os.environ["PERVIO_PRIV2"]
with open(sys.argv[1], "w") as f:
    json.dump(cfg, f, indent=2, sort_keys=True)
PY
  chmod 600 "$CONFIG_JSON"
}

cmd_config_b64() {
  is_running || die "not running — 'setup.sh start' first"
  [ -f "$CONFIG_JSON" ] || die "no config at $CONFIG_JSON"
  python3 -c 'import base64,sys;sys.stdout.write(base64.b64encode(open(sys.argv[1],"rb").read()).decode())' "$CONFIG_JSON"
}

# ---------------------------------------------------------------------- verify

# Proves the endpoint end to end from the SERVER side, using the same command
# shape SSHService.buildChatCommand emits. If this is red, no iOS failure above
# it means anything — so run it before blaming the app.
cmd_verify() {
  is_running || cmd_start >/dev/null || return 2
  local nonce marker prompt b64 out
  nonce="${PERVIO_E2E_NONCE:-verify$$}"
  marker="PERVIO_ECHO $nonce"
  prompt="$nonce"
  b64="$(printf '%s' "$prompt" | python3 -c 'import base64,sys;sys.stdout.write(base64.b64encode(sys.stdin.buffer.read()).decode())')"
  out="$(ssh -i "$SSH_DIR/client_ed25519" -p "$PORT" \
            -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
            -o LogLevel=ERROR 127.0.0.1 \
            "~/.pervio/bin/pervio-chat --text --dir '$PROJ_DIR' --perm 'default' --prompt-b64 $b64" 2>&1)"
  local rc=$?
  if [ $rc -ne 0 ]; then
    warn "e2e_ios verify: ssh/pervio-chat exited $rc"
    warn "$out"
    return 1
  fi
  if printf '%s' "$out" | grep -q "$marker"; then
    say "e2e_ios verify: OK — pervio-chat returned the shim marker over SSH"
    say "$out" | tail -3
    return 0
  fi
  warn "e2e_ios verify: marker '$marker' NOT in the reply"
  warn "$out"
  return 1
}

# Proves the JUMP chain end to end with the stock OpenSSH client: hop 1 to the
# jump sshd, a -W direct-tcpip channel to the target, the full second handshake,
# and a command that must evaluate on the TARGET. Then proves the traversal is
# real by finding the direct-tcpip open in the jump sshd's log. If this is red,
# no iOS chain failure means anything — run it before blaming the app.
cmd_verify_jump() {
  is_running || cmd_start >/dev/null || return 2
  is_running "$JUMP_PID_FILE" || die "jump sshd not running — 'setup.sh stop' then 'start' (old sandbox has no jump)"
  local nonce out rc
  nonce="chain$$"
  out="$(ssh -i "$SSH_DIR/client_ed25519" -p "$PORT" \
            -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR \
            -o ProxyCommand="ssh -i $SSH_DIR/client_ed25519 -p $JUMP_PORT -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR -W %h:%p 127.0.0.1" \
            127.0.0.1 "echo $nonce-\$((6*7))" 2>&1)"
  rc=$?
  if [ $rc -ne 0 ] || ! printf '%s' "$out" | grep -q "$nonce-42"; then
    warn "e2e_ios verify-jump: chained command failed (exit $rc)"
    warn "$out"
    return 1
  fi
  if ! grep -q "direct-tcpip" "$JUMP_LOG_FILE"; then
    warn "e2e_ios verify-jump: command ran but the jump log shows no direct-tcpip open — the chain did not go through the jump"
    return 1
  fi
  say "e2e_ios verify-jump: OK — command evaluated on the target THROUGH the jump"
  grep "direct-tcpip" "$JUMP_LOG_FILE" | tail -1
  return 0
}

# Proves the TWO-hop route end to end with the stock OpenSSH client:
# A → B → C, each leg a direct-tcpip channel of the leg before it, and a command
# that must evaluate on C. Then proves the traversal is real from BOTH hops'
# logs: a direct connect leaves both empty, and a one-hop connect leaves the
# entry hop's empty. If this is red, no iOS route failure means anything — run
# it before blaming the app.
# How many direct-tcpip opens a hop's log holds — always ONE integer, even when
# the answer is zero or the file does not exist yet.
tcpip_opens() {
  local n
  n="$(grep -c "direct-tcpip" "$1" 2>/dev/null)" || true
  printf '%s\n' "${n:-0}"
}

cmd_verify_chain() {
  is_running || cmd_start >/dev/null || return 2
  is_running "$JUMP_PID_FILE"  || die "jump sshd not running — 'setup.sh stop' then 'start'"
  is_running "$ENTRY_PID_FILE" || die "entry sshd not running — 'setup.sh stop' then 'start' (old sandbox has no entry hop)"
  local nonce out rc entry_before jump_before entry_after jump_after
  nonce="route$$"
  # `grep -c` prints the count AND exits 1 when it is zero, so `|| echo 0` would
  # append a second line and the arithmetic below would blow up on "0\n0".
  entry_before="$(tcpip_opens "$ENTRY_LOG_FILE")"
  jump_before="$(tcpip_opens "$JUMP_LOG_FILE")"
  # -J A,B is OpenSSH's own multi-hop ProxyJump: the same topology the app now
  # walks hop by hop.
  #
  # The settings go in a sandbox ssh_config rather than on the command line
  # because command-line `-o` does NOT reach the inner hops: ssh builds the jump
  # as a child `ssh -W`, and (see ssh.c) it forwards only `-l/-p/-J/-F/-v` — so a
  # `-o StrictHostKeyChecking=no` here applied to the LAST leg alone and hop A
  # died with "Host key verification failed". `-F` IS forwarded, so a config
  # file is the one way to give every leg the same identity and the same
  # (deliberately unpinned — this is the rig, not the app) host-key policy.
  # Nothing in ~/.ssh is read or written: the file is ours and known_hosts is
  # /dev/null.
  cat > "$SSH_DIR/ssh_config.chain" <<CONF
Host *
  IdentityFile $SSH_DIR/client_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  GlobalKnownHostsFile /dev/null
  BatchMode yes
  LogLevel ERROR
CONF
  chmod 600 "$SSH_DIR/ssh_config.chain"
  out="$(ssh -F "$SSH_DIR/ssh_config.chain" -p "$PORT" \
            -J "127.0.0.1:$ENTRY_PORT,127.0.0.1:$JUMP_PORT" \
            127.0.0.1 "echo $nonce-\$((6*7))" 2>&1)"
  rc=$?
  if [ $rc -ne 0 ] || ! printf '%s' "$out" | grep -q "$nonce-42"; then
    warn "e2e_ios verify-chain: two-hop command failed (exit $rc)"
    warn "$out"
    return 1
  fi
  entry_after="$(tcpip_opens "$ENTRY_LOG_FILE")"
  jump_after="$(tcpip_opens "$JUMP_LOG_FILE")"
  if [ "$entry_after" -le "$entry_before" ]; then
    warn "e2e_ios verify-chain: the ENTRY hop's log gained no direct-tcpip open — hop A was not traversed"
    return 1
  fi
  if [ "$jump_after" -le "$jump_before" ]; then
    warn "e2e_ios verify-chain: the JUMP hop's log gained no direct-tcpip open — hop B was not traversed"
    return 1
  fi
  say "e2e_ios verify-chain: OK — command evaluated on C THROUGH A:$ENTRY_PORT and B:$JUMP_PORT"
  say "  entry direct-tcpip opens $entry_before → $entry_after"
  say "  jump  direct-tcpip opens $jump_before → $jump_after"
  grep "direct-tcpip" "$ENTRY_LOG_FILE" | tail -1
  grep "direct-tcpip" "$JUMP_LOG_FILE" | tail -1
  return 0
}

# Proves the PER-HOP CREDENTIAL rig with the stock OpenSSH client, in the only
# order that can prove anything:
#
#   1. hop K REFUSES the client key every other machine here accepts. If this
#      ever passes, K is not a machine that "only knows another key" and the iOS
#      test built on it would be certifying itself — a route that connects with
#      one credential everywhere proves nothing about per-hop credentials.
#   2. hop K ACCEPTS the second key. So a later refusal in the app can only mean
#      "the app did not use the hop's own credential", never "K is down".
#   3. the whole route A → K → C runs a command on C, with both traversals
#      proven from the hops' own logs.
#
# If this is red, no iOS per-hop-credential failure means anything — run it
# before blaming the app.
cmd_verify_keyed() {
  is_running || cmd_start >/dev/null || return 2
  is_running "$KEYED_PID_FILE" || die "keyed sshd not running — 'setup.sh stop' then 'start' (old sandbox has no keyed hop)"
  is_running "$ENTRY_PID_FILE" || die "entry sshd not running — 'setup.sh stop' then 'start'"
  local out rc nonce entry_before keyed_before entry_after keyed_after

  # (1) the profile's own key must NOT open hop K.
  out="$(ssh -i "$SSH_DIR/client_ed25519" -p "$KEYED_PORT" \
            -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR \
            -o ConnectTimeout=10 127.0.0.1 'echo KEYED-LET-THE-WRONG-KEY-IN' 2>&1)"
  rc=$?
  if [ $rc -eq 0 ] || printf '%s' "$out" | grep -q KEYED-LET-THE-WRONG-KEY-IN; then
    warn "e2e_ios verify-keyed: hop K accepted the FIRST client key (ssh exit $rc)."
    warn "It is meant to authorize client2 and nothing else, so every per-hop-credential"
    warn "test on top of it would pass with any credential: $out"
    return 1
  fi

  # (2) … and the second key must.
  out="$(ssh -i "$SSH_DIR/client2_ed25519" -p "$KEYED_PORT" \
            -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR \
            -o ConnectTimeout=10 127.0.0.1 'echo KEYED-ALIVE' 2>&1)"
  rc=$?
  if [ $rc -ne 0 ] || ! printf '%s' "$out" | grep -q KEYED-ALIVE; then
    warn "e2e_ios verify-keyed: hop K refused the SECOND client key too (ssh exit $rc)."
    warn "Then 'refused' can never be told apart from 'K is broken': $out"
    return 1
  fi

  # (3) the route A → K → C, each leg with the identity that leg needs. Both
  #     keys are offered on every leg because `-J` forwards only -l/-p/-J/-F/-v
  #     (see verify-chain) — the point proven here is the TOPOLOGY; which key
  #     opens K is settled by (1) and (2) above.
  nonce="keyed$$"
  entry_before="$(tcpip_opens "$ENTRY_LOG_FILE")"
  keyed_before="$(tcpip_opens "$KEYED_LOG_FILE")"
  cat > "$SSH_DIR/ssh_config.keyed" <<CONF
Host *
  IdentityFile $SSH_DIR/client_ed25519
  IdentityFile $SSH_DIR/client2_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  GlobalKnownHostsFile /dev/null
  BatchMode yes
  LogLevel ERROR
CONF
  chmod 600 "$SSH_DIR/ssh_config.keyed"
  out="$(ssh -F "$SSH_DIR/ssh_config.keyed" -p "$PORT" \
            -J "127.0.0.1:$ENTRY_PORT,127.0.0.1:$KEYED_PORT" \
            127.0.0.1 "echo $nonce-\$((6*7))" 2>&1)"
  rc=$?
  if [ $rc -ne 0 ] || ! printf '%s' "$out" | grep -q "$nonce-42"; then
    warn "e2e_ios verify-keyed: the A→K→C command failed (exit $rc)"
    warn "$out"
    return 1
  fi
  entry_after="$(tcpip_opens "$ENTRY_LOG_FILE")"
  keyed_after="$(tcpip_opens "$KEYED_LOG_FILE")"
  if [ "$entry_after" -le "$entry_before" ]; then
    warn "e2e_ios verify-keyed: the ENTRY hop's log gained no direct-tcpip open — hop A was not traversed"
    return 1
  fi
  if [ "$keyed_after" -le "$keyed_before" ]; then
    warn "e2e_ios verify-keyed: the KEYED hop's log gained no direct-tcpip open — hop K was not traversed"
    return 1
  fi
  say "e2e_ios verify-keyed: OK"
  say "  hop K:$KEYED_PORT REFUSED the first client key, ACCEPTED the second"
  say "  route A:$ENTRY_PORT → K:$KEYED_PORT → C:$PORT ran a command on C"
  say "  entry direct-tcpip opens $entry_before → $entry_after"
  say "  keyed direct-tcpip opens $keyed_before → $keyed_after"
  return 0
}

# ---------------------------------------------------------------------- rotate

# Run one command against the sandbox with EXACTLY `$1` pinned as the host key,
# the way a client with a known_hosts entry does. Never reads or writes your
# ~/.ssh: both known-hosts files are overridden, and the one we do use lives in
# the sandbox. Exit code is ssh's, so "refused" and "ran" are distinguishable.
ssh_pinned() {  # $1 = host key line to pin, $2 = remote command
  local kh="$SSH_DIR/known_hosts.probe"
  printf '[127.0.0.1]:%s %s\n' "$PORT" "$1" > "$kh"
  chmod 600 "$kh"
  ssh -i "$SSH_DIR/client_ed25519" -p "$PORT" \
      -o IdentitiesOnly=yes -o BatchMode=yes -o PasswordAuthentication=no \
      -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$kh" \
      -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR \
      127.0.0.1 "$2" 2>&1
}

# THE ROTATION. Stop the daemon, throw the host key away, make a new one, start
# again on the same port with the same authorized_keys. Everything else about
# the endpoint — the client key, the temp HOME, the seeded project — survives, so
# a client that reconnects sees one difference and only one: it is not the same
# server any more.
#
# Then it must PROVE that, because a rotation that silently did nothing would
# turn every test built on top of it into a test of nothing:
#   1. the new line differs from the old one;
#   2. a real ssh client pinning the NEW key still gets in and runs a command
#      (so a later refusal cannot be "the box is down");
#   3. a real ssh client pinning the OLD key is REFUSED.
# Only after all three does it save the pre-rotation line for `stale-pin`.
cmd_rotate() {
  is_running || cmd_start >&2 || return 2

  local before after out rc
  before="$(host_line)"
  [ -n "$before" ] || die "no host key to rotate away from at $SSH_DIR/host_ed25519.pub"

  stop_sshd >/dev/null
  rm -f "$SSH_DIR/host_ed25519" "$SSH_DIR/host_ed25519.pub"
  ssh-keygen -q -t ed25519 -f "$SSH_DIR/host_ed25519" -N '' -C 'pervio-e2e-host-rotated' \
    || die "ssh-keygen (new host key) failed"
  start_sshd

  after="$(host_line)"
  if [ "$before" = "$after" ]; then
    die "rotate produced the SAME host key — nothing was rotated, and anything built
     on this would be certifying itself. Refusing to report a rotation."
  fi

  # (2) the endpoint is alive under its new identity …
  out="$(ssh_pinned "$after" 'echo ROTATE-ALIVE')"; rc=$?
  if [ $rc -ne 0 ] || ! printf '%s' "$out" | grep -q ROTATE-ALIVE; then
    die "after rotating, a client pinning the NEW key could not get in (ssh exit $rc):
     $out
     Every 'refused' from here on would be ambiguous, so this is fatal."
  fi

  # … (3) and the key it used to present no longer opens it. This is the
  # server-side twin of the iOS test: if it ever passes, the rotation was fake.
  out="$(ssh_pinned "$before" 'echo STALE-KEY-STILL-WORKS')"; rc=$?
  if [ $rc -eq 0 ] || printf '%s' "$out" | grep -q STALE-KEY-STILL-WORKS; then
    die "a client pinning the PRE-ROTATION key still connected — the host key did not
     really change (ssh exit $rc): $out"
  fi

  printf '%s\n' "$before" > "$STALE_PUB"
  chmod 600 "$STALE_PUB"
  write_config     # config.json now carries the NEW pin

  say "e2e_ios: host key ROTATED on 127.0.0.1:$PORT (pid $(cat "$PID_FILE" 2>/dev/null))"
  say "  was          $(printf '%s' "$before" | cut -c1-28)…  ($(ssh-keygen -lf "$STALE_PUB" 2>/dev/null | awk '{print $2}'))"
  say "  now          $(printf '%s' "$after"  | cut -c1-28)…  ($(ssh-keygen -lf "$SSH_DIR/host_ed25519.pub" 2>/dev/null | awk '{print $2}'))"
  say "  proven       old key REFUSED, new key connects, same address, same client key"
  say "$before"
}

# The two accessors a runner needs. `stale-pin` is empty (and exit 1) until a
# rotation has actually happened, so a caller can never mistake "we never
# rotated" for "here is the old key".
cmd_stale_pin() {
  [ -s "$STALE_PUB" ] || { warn "e2e_ios: nothing rotated yet — run 'setup.sh rotate' first"; return 1; }
  cat "$STALE_PUB"
}

cmd_host_pin() {
  [ -f "$SSH_DIR/host_ed25519.pub" ] || { warn "e2e_ios: no endpoint (run 'setup.sh start')"; return 1; }
  host_line
}

# ------------------------------------------------------------------------ stop

cmd_stop() {
  if is_running; then
    local pid; pid="$(stop_sshd)"
    say "e2e_ios: stopped (pid $pid)"
  else
    say "e2e_ios: not running"
  fi
  if is_running "$JUMP_PID_FILE"; then
    local jpid; jpid="$(stop_sshd "$JUMP_PID_FILE" "$JUMP_PORT")"
    say "e2e_ios: jump sshd stopped (pid $jpid)"
  fi
  if is_running "$ENTRY_PID_FILE"; then
    local epid; epid="$(stop_sshd "$ENTRY_PID_FILE" "$ENTRY_PORT")"
    say "e2e_ios: entry sshd stopped (pid $epid)"
  fi
  if is_running "$KEYED_PID_FILE"; then
    local kpid; kpid="$(stop_sshd "$KEYED_PID_FILE" "$KEYED_PORT")"
    say "e2e_ios: keyed sshd stopped (pid $kpid)"
  fi
  if is_running "$HTTP_PID_FILE"; then
    stop_http
    say "e2e_ios: sandbox page stopped"
  fi
  # Only ever removes the sandbox we created, and only if it looks like ours.
  case "$ROOT" in
    */pervio-e2e-ios*) [ -d "$ROOT" ] && rm -rf "$ROOT" && say "e2e_ios: sandbox removed ($ROOT)" ;;
    *) warn "e2e_ios: refusing to remove an unexpected root: $ROOT" ;;
  esac
}

case "${1:-}" in
  check)      cmd_check ;;
  start)      cmd_start ;;
  verify)     cmd_verify ;;
  verify-jump) cmd_verify_jump ;;
  verify-chain) cmd_verify_chain ;;
  verify-keyed) cmd_verify_keyed ;;
  rotate)     cmd_rotate ;;
  stale-pin)  cmd_stale_pin ;;
  host-pin)   cmd_host_pin ;;
  stop)       cmd_stop ;;
  config-b64) cmd_config_b64 ;;
  root)       say "$ROOT" ;;
  *) warn "usage: setup.sh {check|start|verify|verify-jump|verify-chain|verify-keyed|rotate|stale-pin|host-pin|stop|config-b64|root}"; exit 64 ;;
esac
