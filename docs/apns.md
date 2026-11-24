# Lock-screen push (APNs)

**Since 2026-10-13 nothing has to be set up on the Mac.** With no local key,
`pervio-push` sends through Pervio's own relay (`https://push.pervio.dev`, see
`server/gateway/`), which holds the one APNs key; the Mac still builds the whole
payload and the relay can only push to Pervio (it derives the topic itself).
`pervio-push check` says `key: via relay …` when that is the path. To point at
another relay write its URL to `~/.pervio/push/gateway`; write `off` there (or
set `PERVIO_PUSH_GATEWAY=off`) to refuse any relay and require a local key.
The rest of this page is the local-key path, which still wins whenever
`~/.pervio/apns` holds a key.

The Mac talks straight to Apple (`api.push.apple.com`) over HTTP/2 and signs its own
JWT — no Firebase, no OneSignal. This closes the one gap the in-app
notifier can't: once iOS suspends the app, no Swift code runs and the SSH socket is
gone, so a 6:30am digest landing, a workflow failing, or Claude pausing for approval
can't ping the phone from the app. The server reaches it through Apple instead.

With no local key and the relay turned off (`off`, above), it all degrades
gracefully: `pervio-push send` is a silent no-op that exits 0, and the hooks that
call it stay quiet. Nothing breaks; nothing pings. The moment a key and a device
token are in place, the same hooks start delivering — no code change, no redeploy.

**If you built the app yourself** (your own bundle id), the relay cannot deliver to
it, yet a Mac with no local key would still send it every notification. Write `off`
first, then follow this page for your own key and set `TOPIC` in
`server/bin/pervio-push` to your bundle id.

## The one thing you have to do

Generate an APNs signing key in the Apple Developer portal and drop it on the Mac.
Once — the key never expires.

1. Go to <https://developer.apple.com/account/resources/authkeys/list>
   (Certificates, Identifiers & Profiles → **Keys**).
2. Click **+** (Create a key). Give it a name (e.g. "Pervio APNs").
   Tick **Apple Push Notifications service (APNs)**. Continue → Register.
3. **Download** the `.p8` file. You can only download it once — if you lose it,
   revoke and make a new one. Note the **Key ID** shown on the page (10 chars,
   e.g. `ABC123DEFG`).
4. Put the three pieces on the Mac, owner-only:

   ```sh
   mkdir -p ~/.pervio/apns && chmod 700 ~/.pervio/apns
   mv ~/Downloads/AuthKey_ABC123DEFG.p8 ~/.pervio/apns/   # keep the AuthKey_<KEYID>.p8 name
   chmod 600 ~/.pervio/apns/AuthKey_*.p8
   printf 'ABC123DEFG' > ~/.pervio/apns/key_id            # the 10-char Key ID from step 3
   printf 'TEAM123456' > ~/.pervio/apns/issuer_id         # your 10-char Team ID (the JWT issuer)
   chmod 600 ~/.pervio/apns/key_id ~/.pervio/apns/issuer_id
   ```

   - Keep the downloaded filename `AuthKey_<KEYID>.p8`; the key id is also parsed
     from it, so `key_id` is a belt-and-suspenders copy.
   - `issuer_id` holds your **Team ID**, not the Key ID. It is the 10-char team
     identifier (top-right of the developer portal, or `DEVELOPMENT_TEAM` in
     `ios/Signing.local.xcconfig`). The filename `issuer_id` matches
     the App Store Connect key layout in `~/.pervio/asc/` so the two look the same;
     for APNs the issuer just happens to be the team.

That's it. The layout deliberately mirrors `~/.pervio/asc/` (the TestFlight upload
key). The `.p8` never goes in the repo — `.gitignore` blocks `*.p8`, and it lives
outside the tree anyway.

### Check it took

```sh
server/bin/pervio-push check
```

- `key: OK … tokens: OK … => READY` — you're done; pushes will deliver.
- `tokens: NONE` — the key is in place but no phone has uploaded a token yet. Open
  the app once on the phone (see below).

## The phone's side (automatic)

Nothing to do here — it already happens. On every launch the app registers for
remote notifications, and when Apple hands it a device token it writes the token to
the Mac over the existing SSH channel:

```
~/.pervio/push/tokens/<device-uuid>     # one hex token per device
```

Re-launches overwrite the same file (no pile-up); if Apple rotates the token, the
new one is re-uploaded. Two phones are two files, and the Mac fans a push out to
both. A push that arrives while the app is open is suppressed on purpose — the live
app already shows that state, so it doesn't interrupt you.

### The Dynamic Island's own token

A Live Activity is addressed by its **own** token, not the device's, so a second
file appears while a Run's island is showing:

```
~/.pervio/push/liveactivity/<runId>     # one hex token per LIVE activity
```

The phone writes it when it starts the card and deletes it when the card ends. It
exists because every `Activity.end(...)` call lives inside the **app process**: a
detached run finishes long after iOS suspended the app, so nothing on the phone is
left to stop the island — it just kept counting. `pervio-run`'s completion wrapper
now sends an ActivityKit push alongside the ordinary alert:

```
pervio-push liveactivity --run <runId> --event end --status Done
```

which uses `apns-push-type: liveactivity` and the suffixed topic
`app.pervio.push-type.liveactivity`. Missing token / missing key ⇒ silent exit 0,
same contract as `send`. As a backstop for a push that never lands, the card also
carries a one-hour `staleDate`, after which the island freezes its timer instead of
counting indefinitely.

The app build carries the `aps-environment` entitlement (set in `ios/project.yml`,
the source of truth — the `.pbxproj` is regenerated from it, so this can't be added
in Xcode by hand).

## Sandbox vs production

APNs has two hosts, chosen by how the app was **signed**:

| Host (Mac side)                    | App build                                   | Flag                 |
| ---------------------------------- | ------------------------------------------- | -------------------- |
| `api.push.apple.com` (default)     | **TestFlight / App Store** (cloud-signed)   | *(none)*             |
| `api.sandbox.push.apple.com`       | **Debug build run from Xcode on a cable**   | `pervio-push --sandbox` |

The entitlement value is `development` in `project.yml`, but Apple's cloud signing
rewrites it to `production` when it re-signs a TestFlight/App Store upload — so the
same source covers both. In practice: since the phone runs the **TestFlight** build,
the default (production, no flag) is what you want. Use `--sandbox` only when testing
against a debug build wired to Xcode — the notifications the scripts send on their
own (a run finished, an approval waiting, a digest delivered) always use production;
`--sandbox` exists only on the commands you type. A token minted for one environment is rejected
by the other (`400 BadDeviceToken`), which is the usual cause if a push 404/400s
after everything looks set up — you're pointing at the wrong host for that build.

## What sends, and when

Three fire-and-forget hooks call `pervio-push send` (10s cap, never block or fail
the workflow):

- **Digest published** — after an issue is archived: title = workflow name,
  body = `"<YYYY-MM-DD> 已送达"`. (`server/bin/pervio-orchestrate`)
- **Workflow failed** — once per run, on failure: `"失败:<step>"`.
  (`server/bin/pervio-orchestrate`)
- **Approval waiting** — when Claude pauses for an ask-tier tool during a live
  approval turn: title = `"Claude 在等你批准"`, body = the verb (改文件/写文件/跑命令/…).
  (`server/bin/pervio-approve`)

Manual test once a token is uploaded:

```sh
server/bin/pervio-push send --title "Pervio" --body "测试推送" --thread test
server/bin/pervio-push dry-run --title "Pervio" --body "看看请求长啥样"   # prints the request, sends nothing
```

## Security notes

- `~/.pervio/apns/` and the `.p8` are `0600`/`0700`, owner-only. The signed JWT is
  cached at `~/.pervio/apns/.jwt_cache.json` (`0600`) and reused for ≤50 min (Apple's
  hard limit is 60), so we don't re-sign on every push.
- The device token is not secret, but the tokens dir is `0700` all the same.
- A device that un-registers returns `410`; its token file is pruned automatically
  so we stop trying to reach it.
