#!/usr/bin/env bash
# Install the Pervio launchers into ~/.pervio/bin on this server.
# Run from the repo root on the server:   bash server/install.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="$HOME/.pervio/bin"

# Everything we ship, as "<mode> <path under the repo's server/>". The last two
# are data, not launchers: pervio-brief.md is a prompt, and _pervio_lib.py is the
# shared child-agent library imported by pervio-orchestrate / pervio-dispatch —
# not executable itself, but the scripts die without it next to them.
payload=(
  "0755 bin/pervio-chat"
  "0755 bin/pervio-run"
  "0755 bin/pervio-term"
  "0755 bin/pervio-sessions"
  "0755 bin/pervio-upload"
  "0755 bin/pervio-codex-index"
  "0755 bin/pervio-hb"
  "0755 bin/pervio-orchestrate"
  "0755 bin/pervio-schedule-tick"
  "0755 bin/pervio-dispatch"
  "0755 bin/pervio-approve"
  "0755 bin/pervio-chat-stream"
  "0755 bin/pervio-arxiv-fetch"
  "0755 bin/pervio-digest-assemble"
  "0755 bin/pervio-push"
  "0755 bin/pervio-feedback"
  "0755 bin/pervio-view"
  "0755 bin/pervio-mcp"
  "0755 bin/pervio-group"
  "0755 bin/pervio-provider"
  "0755 bin/pervio-cursor-stream"
  "0755 bin/pervio-ports"
  "0644 bin/pervio-brief.md"
  "0644 bin/_pervio_lib.py"
)

stage=""; cred_tmp=""
cleanup() {
  [ -n "$stage" ] && rm -rf "$stage"
  [ -n "$cred_tmp" ] && rm -f "$cred_tmp"
  return 0
}
trap cleanup EXIT

# Stage first, publish second. This used to be one `install` line per file, so a
# truncated checkout (or an unreadable file, or a half-finished rsync) aborted
# midway and left ~/.pervio/bin half new and half old — the server would then run a new
# pervio-orchestrate against last week's _pervio_lib.py, which is worse than not
# installing at all. Now nothing in $dest is touched until every source has been
# copied into a staging dir INSIDE $dest (same filesystem, so publishing is a
# rename(2) per file, not a re-copy that can die mid-file).
#
# Honest about the remaining window: publishing is 16 renames, not one atomic
# swap, so a kill DURING the publish loop can still leave a new/old mix — each
# individual file is all-or-nothing, the set is not. Closing that would mean
# publishing a whole directory and flipping a symlink; the copy-time hole (the
# common one: a truncated checkout, an unreadable file) is what this closes.
mkdir -p "$dest"
rm -rf "$dest"/.staging.*   # a SIGKILLed run can't run its trap; sweep its debris
stage="$(mktemp -d "$dest/.staging.XXXXXX")"

bad=0
for entry in "${payload[@]}"; do
  mode="${entry%% *}"; rel="${entry#* }"; name="${rel##*/}"
  src="$here/$rel"
  if [ ! -r "$src" ] || [ ! -f "$src" ]; then
    echo "install.sh: missing or unreadable source: $src" >&2
    bad=1
    continue
  fi
  install -m "$mode" "$src" "$stage/$name"
done
if [ "$bad" -ne 0 ]; then
  echo "install.sh: ABORTED — $dest was not touched; the previous install is still intact." >&2
  exit 1
fi

for entry in "${payload[@]}"; do
  rel="${entry#* }"; name="${rel##*/}"
  mv -f "$stage/$name" "$dest/$name"
done
rm -rf "$stage"; stage=""

# --- Revision stamp: what the app's handshake reads ---
# The installed set's content hash, written LAST (a partial publish must never
# look current). Canonical form — shared byte-for-byte with the app's
# ServerProvisioner and pinned by test_install.py: for each payload file in
# sorted-by-name order, feed "name NUL content NUL" into SHA-256; keep the
# first 16 hex chars. Content-addressed, so nobody ever bumps a version number:
# scripts changed ⇒ rev changed, and the app repaves on its next connect.
rev="$(for name in $(printf '%s\n' "${payload[@]#* }" | sed 's|^bin/||' | LC_ALL=C sort); do
         printf '%s' "$name"; printf '\0'; cat "$dest/$name"; printf '\0'
       done | shasum -a 256 | cut -c1-16)"
printf '%s' "$rev" > "$dest/.pervio-rev"
echo "  rev: $rev"

# --- Starter workflow templates (the user's personal market) ---
# Seed ~/.pervio/templates with the repo's capability templates so `templates
# list` (and the app's market) has them from day one. Copy ONLY when the target
# doesn't exist: once installed the file belongs to the user (they may have
# tuned prompts/models/dirs), so a re-run must never overwrite it.
tpl="$HOME/.pervio/templates"
mkdir -p "$tpl"
for f in "$here"/templates/*.json; do
  [ -e "$f" ] || continue   # unmatched glob stays literal — skip it
  base="$(basename "$f")"
  if [ -e "$tpl/$base" ]; then
    echo "  template: $base already in $tpl — left as-is"
  else
    install -m 0644 "$f" "$tpl/$base"
    echo "  template: seeded $tpl/$base"
  fi
done

echo "Installed:"
ls -la "$dest"

echo
echo "Checks:"
command -v claude >/dev/null && echo "  claude: $(command -v claude) ($(claude --version 2>/dev/null | head -1))" \
                              || echo "  claude: NOT FOUND on PATH (the launchers also probe ~/.local/bin)"
command -v tmux   >/dev/null && echo "  tmux:   $(command -v tmux) ($(tmux -V))" \
                              || { [ -x /usr/bin/tmux ] && echo "  tmux:   /usr/bin/tmux ($(/usr/bin/tmux -V))" \
                                   || echo "  tmux:   NOT FOUND (terminal mode needs it; chat mode does not)"; }

# --- macOS only: make Claude's login usable over SSH ---
# On macOS `claude` stores its OAuth token in the login Keychain, which a
# NON-interactive SSH session (how Pervio runs pervio-chat) cannot read — so chats
# fail with "Not logged in". This script runs in YOUR interactive shell, which DOES
# have Keychain access, so copy the token to ~/.claude/.credentials.json — the same
# file Linux uses and that SSH can read. Re-running this refreshes a stale token.
# Linux skips this block entirely (no Keychain, creds are already a file).
if [ "$(uname)" = "Darwin" ]; then
  echo
  # Read once (a Keychain prompt may appear — click "Always Allow"). The `if cmd`
  # form keeps `set -e` from aborting when no credential exists yet.
  if cred="$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null)" && [ -n "$cred" ]; then
    mkdir -p "$HOME/.claude"
    # Write to a 0600 temp beside the target, then rename. `> file` truncated the
    # live credentials BEFORE writing, so a full disk or a killed session left a
    # half-token behind and the working login was gone for good — and the chmod
    # only ran afterwards, so a fresh file was world-readable while it was being
    # written. rename(2) makes the swap all-or-nothing; a death mid-write can now
    # only cost the temp file.
    # A SIGKILLed run cannot fire its trap, so sweep any debris a previous one
    # left — same reason the staging dir gets swept above.
    rm -f "$HOME/.claude/.credentials.json.new."* 2>/dev/null || true
    cred_tmp="$(mktemp "$HOME/.claude/.credentials.json.new.XXXXXX")"
    chmod 600 "$cred_tmp"
    ( printf '%s' "$cred" > "$cred_tmp" )   # subshell: it dies, we still clean up
    mv -f "$cred_tmp" "$HOME/.claude/.credentials.json"
    cred_tmp=""
    unset cred
    echo "  claude creds: synced Keychain login -> ~/.claude/.credentials.json (so SSH-launched claude is logged in)"
  elif [ -s "$HOME/.claude/.credentials.json" ]; then
    echo "  claude creds: ~/.claude/.credentials.json present (no Keychain item) — left as-is"
  else
    echo "  claude creds: NONE found — run 'claude' and /login in a normal Terminal, then re-run this script"
  fi
fi

echo
echo "Done. Point the iOS app's 'Launcher dir' at: $dest"
