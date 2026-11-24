# Security

Pervio holds an SSH key to your computer, so reports about anything that could
expose that key, weaken host-key pinning, widen what a connected phone can do,
or leak conversation content are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private reporting instead:
the repository's **Security** tab → **Report a vulnerability**. Include what
you did, what you expected, what happened, and the app build number
(Settings → About) or the commit you built from.

There is no bug bounty.

## What the design relies on

- **Keys and passwords** live only in the iOS Keychain of the phone that added
  them. Server addresses and user names are ordinary app settings.
- **The connection** is plain SSH from the phone to a machine you own, with the
  host key pinned when you add the server: the app reads the key from the
  handshake without logging in, shows you its fingerprint, and pins it on your
  word. A changed key is refused, not asked about.
- **No port is opened to the network** besides `sshd`. The helper scripts under
  `~/.pervio/bin` run when the phone starts them over SSH. What runs beyond
  that is what you set up: a scheduled workflow (one launchd entry, or a cron
  line on Linux, that runs the scheduler every five minutes), a terminal
  session kept alive in tmux, and a reader page served on `127.0.0.1` for a few
  minutes when you ask to read a digest in a desktop browser.
- **Third-party model keys** you add for a provider are written to
  `~/.pervio/providers/` on your computer (mode 0600), never stored on the phone.
- **Lock-screen notifications** leave your computer for a small relay
  (`server/gateway/`) that holds the one Apple push key — see
  [the privacy notes in the README](README.md#privacy-and-security) for exactly
  what it can see.
