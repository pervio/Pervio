import XCTest
import Network

/// Layer 3 of the test pyramid: XCUITests that drive the REAL app from outside
/// its process. Two kinds live here, and each says which it is:
///
///  * SANDBOX flows need a live hermetic sshd (the round-trip reply, opening a
///    real archived digest and rating a paper). They export
///    `PERVIO_E2E_CONFIG_B64` from  server/tests/e2e_ios/run_smoke.sh  and SKIP
///    without it — a green with no server would be a lie.
///  * BARE-SIM flows drive only the launch-argument seam and the app's own
///    chrome (the route editor's add-hop gesture; the market's bundled catalog;
///    the language switch reaching the market's buttons). They seed ONE home
///    server with a SYNTHETIC config that is never dialed (`syntheticConfigB64`)
///    and run against a plain simulator with no sandbox.
///
/// For the sandbox flows nothing is stubbed on the app side — the app opens a
/// genuine Citadel SSH connection, pins a genuine host key, runs the genuine
/// launcher over an exec channel and parses the genuine NDJSON that comes back.
/// The only double is the agent itself (`server/tests/shim/claude`), so the turn
/// costs nothing and its reply is deterministic.
///
/// HOW TO RUN. Not from Xcode's Test action alone — the endpoint has to exist
/// first. One command does everything (sandbox up, project generated, test run,
/// sandbox down):
///
///     bash server/tests/e2e_ios/run_smoke.sh
///
/// It exports two variables into the test runner's environment:
///   * `PERVIO_E2E_CONFIG_B64` — base64 of the sandbox's config.json, handed to
///     the app verbatim as a launch argument (see UITestBootstrap in
///     ios/Sources/PervioApp.swift).
///   * `PERVIO_E2E_NONCE` — the token the shim echoes back, so the assertion
///     matches THIS run's reply and can't be satisfied by a stale bubble.
/// Without them the test SKIPS rather than inventing a pass; run_smoke.sh then
/// fails, because it demands a "passed" line and treats a skip as red.
///
/// TARGET WIRING. The repo's ios/project.yml has no UI-test target (it is track
/// A's file and this track does not edit it), so run_smoke.sh generates a
/// throwaway project that includes ios/project.yml and adds:
///
///     PervioUITests:
///       type: bundle.ui-testing
///       platform: iOS
///       sources: [ path: UITests ]
///       dependencies: [ target: Pervio ]
///
/// Add that stanza to ios/project.yml (plus `PervioUITests: [test]` in the
/// scheme) to make it a first-class target; nothing in this file changes.
final class SmokeTests: XCTestCase {

    private enum Env {
        static let config = "PERVIO_E2E_CONFIG_B64"
        static let nonce  = "PERVIO_E2E_NONCE"
        /// The sandbox server's HOME on this Mac (the simulator shares the host's
        /// disk), so a test can look at what the app wrote there.
        static let home   = "PERVIO_E2E_HOME"
        /// The sandbox's own page (a loopback HTTP server next to its sshd) and
        /// the token in its body, for the web preview flow.
        static let httpPort  = "PERVIO_E2E_HTTP_PORT"
        static let httpToken = "PERVIO_E2E_HTTP_TOKEN"
    }

    /// Connect + launcher + agent + parse is a lot of moving parts on a cold
    /// simulator; generous, but bounded.
    private let replyTimeout: TimeInterval = 120

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Type a message, get the server's answer back on screen.
    ///
    /// The reply is `PERVIO_ECHO <nonce>` where the nonce is what this test typed
    /// — so a green proves the whole loop, not just that some bubble appeared:
    /// the typed bytes reached the shim through sshd + pervio-chat, and the
    /// shim's stream-json came back through Citadel, AgentEvent.parse, ChatStore
    /// and into the transcript.
    func testTypedMessageRoundTripsThroughRealSSHAndRendersTheReply() throws {
        let cfg = try requireEnv(Env.config)
        let nonce = ProcessInfo.processInfo.environment[Env.nonce] ?? "smokefallback"

        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset",
                               "--pervio-uitest-config=\(cfg)"]
        app.launch()
        dismissSystemPrompt()

        // 1. The injected server names itself in the home page's servers footer.
        //    This is the first thing that breaks if the launch-argument seam
        //    regresses, and it fails fast (before any SSH) with an unambiguous
        //    message. CONTAINS, not equality: since the entry-page redesign the
        //    home shows one line, "<name> · <user>@<host>", not a server row.
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30),
                      "Injected profile never appeared on the home screen — the launch-argument "
                      + "seam did not run. \(dump(app))")

        // 2. Home → server → project → New conversation (see openNewChat for why
        //    the home screen's "New chat" shortcut is NOT the path taken).
        let composer = try openNewChat(app)

        // 3. Compose.
        composer.tap()
        composer.typeText(nonce)

        // 4. Send.
        let send = try sendButton(app)
        send.tap()

        // 5. The server's answer, containing this run's nonce. Matched across
        //    every element type: assistant prose renders through a UITextView
        //    (SelectableText), not a Text.
        let marker = "PERVIO_ECHO \(nonce)"
        let reply = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", marker, marker)
        ).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: replyTimeout),
                      "No bubble carrying '\(marker)' within \(Int(replyTimeout))s. Either the app "
                      + "never reached the sandbox sshd, or the reply was dropped on the way in. "
                      + "Check the sandbox log (server/tests/e2e_ios/setup.sh root)/sshd.log. \(dump(app))")
    }

    // MARK: - Flow 1b: pick a provider → turn → leave → re-enter → still on it (REAL sandbox)

    /// The first provider tester's bug (2026-10-15), end to end: a conversation
    /// put on a third-party vendor through the engine badge kept the vendor's
    /// MODEL name but lost the VENDOR when the conversation was reopened, so
    /// its next turn asked Anthropic for "glm-5.3". The restore now goes
    /// through one routine (AppStore.restoreKnobs); this drives the real
    /// screens to prove it: badge → "Claude · E2E Vendor" → a turn → back to
    /// the list → the same conversation → the badge must still say the vendor
    /// → a second turn. run_smoke.sh then checks the sandbox's shim_env.log:
    /// BOTH turns must have reached the agent with the vendor's base URL.
    func testProviderPickedInTheBadgeSurvivesLeavingAndReenteringTheConversation() throws {
        let cfg = try requireEnv(Env.config)
        let nonce = ProcessInfo.processInfo.environment[Env.nonce] ?? "smokefallback"
        let vendor = "E2E Vendor"

        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(cfg)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30),
                      "Injected profile never appeared — the launch-argument seam did not run. \(dump(app))")

        let composer = try openNewChat(app)

        // 1. The engine badge offers the sandbox's roster; pick the vendor.
        let badge = app.buttons["engine-badge"]
        XCTAssertTrue(badge.waitForExistence(timeout: 20), "No engine badge in the chat header. \(dump(app))")
        badge.tap()
        let combo = "Claude · " + vendor
        guard let item = firstHittable(app.buttons[combo], app.staticTexts[combo], app.menuItems[combo]) else {
            XCTFail("The badge menu offers no '\(combo)' — the roster from `pervio-chat engines` "
                    + "did not reach the phone, or the sandbox seeded no provider. \(dump(app))")
            throw XCTSkip("no provider combo")   // unreachable: continueAfterFailure = false
        }
        item.tap()
        XCTAssertTrue(badgeSays(app, vendor, timeout: 10),
                      "Picked '\(combo)' but the badge does not show the vendor. \(dump(app))")

        // 2. One turn on the vendor (the shim echoes; the overlay is logged server-side).
        composer.tap()
        composer.typeText(nonce + "pv1")
        try sendButton(app).tap()
        XCTAssertTrue(echo(app, nonce + "pv1").waitForExistence(timeout: replyTimeout),
                      "No reply to the first turn on the vendor. \(dump(app))")

        // 3. Leave: back to the project's conversation list, where the
        //    conversation is titled by its first message.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", nonce + "pv1")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "After leaving, the conversation is not listed by its first message. \(dump(app))")

        // 4. Re-enter. THE regression: the vendor must still be on the badge.
        row.tap()
        _ = try waitForComposer(app)
        XCTAssertTrue(badgeSays(app, vendor, timeout: 15),
                      "Reopened the conversation and the badge lost its vendor — the next turn "
                      + "would carry the vendor's model name to the account's own endpoint. \(dump(app))")

        // 5. A second turn, so the server log proves --provider rode along after re-entry.
        let again = try waitForComposer(app)
        again.tap()
        again.typeText(nonce + "pv2")
        try sendButton(app).tap()
        XCTAssertTrue(echo(app, nonce + "pv2").waitForExistence(timeout: replyTimeout),
                      "No reply to the turn after re-entry. \(dump(app))")
    }

    /// A one-line map of the transcript: which seed rows are on screen (and at
    /// what y), where the reply bubble sits, whether the pill shows — enough to
    /// tell "scrolled to the end" from "shifted by a bubble's height".
    private func whereIsTheTranscript(_ app: XCUIApplication) -> String {
        let h = app.windows.firstMatch.frame.height
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@ OR label BEGINSWITH %@ OR value BEGINSWITH %@",
                        "seed user", "seed user", "PERVIO_ECHO", "PERVIO_ECHO")).allElementsBoundByIndex
        let visible = rows.filter { $0.frame.height > 0 && $0.frame.maxY > 0 && $0.frame.minY < h }
            .map { e -> String in
                let t = e.label.isEmpty ? ((e.value as? String) ?? "") : e.label
                return "\(t.prefix(16))@\(px(e.frame.minY))"
            }
        let pill = app.buttons["New below"].exists || app.buttons["新内容"].exists
        return "on screen: [\(visible.joined(separator: ", "))], pill: \(pill), window h=\(px(h))"
    }

    /// Every seed row's y (on screen or not — off-screen frames are still
    /// reported), plus the sent message and the reply, so a uniform shift
    /// (a scroll) can be told from one row changing height (a layout change).
    private func rowMap(_ app: XCUIApplication) -> String {
        let rows = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@ OR label BEGINSWITH %@ OR value BEGINSWITH %@ OR label BEGINSWITH %@ OR value BEGINSWITH %@",
                        "seed user", "seed user", "seed reply", "seed reply", "slow ", "slow ")).allElementsBoundByIndex
        var seen = Set<String>()
        return rows.compactMap { e -> String? in
            let t = e.label.isEmpty ? ((e.value as? String) ?? "") : e.label
            let k = String(t.prefix(13)).replacingOccurrences(of: "seed ", with: "")
            guard e.frame.height > 0, !seen.contains(k) else { return nil }
            seen.insert(k)
            return "\(k)@\(px(e.frame.minY))"
        }.joined(separator: " ")
    }

    /// Where the chat's chrome sits: the engine badge (top) and the composer
    /// (bottom) — if either moves when a reply lands, the rows move with it and
    /// the transcript did not scroll at all.
    private func edges(_ app: XCUIApplication) -> String {
        let badge = app.buttons["engine-badge"].firstMatch
        let composer = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Message' OR value BEGINSWITH 'Message' OR label BEGINSWITH 'Message'")).firstMatch
        let sv = app.scrollViews.firstMatch
        return "badge y=\(badge.exists ? px(badge.frame.minY) : "-"), composer y=\(composer.exists ? px(composer.frame.minY) : "-"), "
             + "scrollView \(sv.exists ? "y=\(px(sv.frame.minY)) h=\(px(sv.frame.height))" : "-")"
    }

    /// A frame coordinate as text; a vanished element reports an infinite
    /// frame, and `Int(.infinity)` traps the whole test runner (seen 2026-10-15).
    private func px(_ v: CGFloat) -> String { v.isFinite ? String(Int(v)) : "∞" }

    /// The engine badge's accessibility label concatenates its texts (model,
    /// "· vendor", the usage line); CONTAINS on the vendor is the contract.
    private func badgeSays(_ app: XCUIApplication, _ text: String, timeout: TimeInterval) -> Bool {
        app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "engine-badge", text))
            .firstMatch.waitForExistence(timeout: timeout)
    }

    /// The shim's reply bubble for a nonce, matched across element types
    /// (assistant prose renders through a UITextView).
    private func echo(_ app: XCUIApplication, _ nonce: String) -> XCUIElement {
        let marker = "PERVIO_ECHO " + nonce
        return app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", marker, marker)).firstMatch
    }

    // MARK: - Flow 1c: a reply landing while you read history must not move you (REAL sandbox)

    /// The complaint (2026-10-15): "每次有新消息就弹到最下面" — reading older
    /// messages, a reply lands, the transcript jumps to the end and the place is
    /// lost. Driven on the real screens in BOTH composer modes: send a slow
    /// message (the sandbox agent answers after ~8 s), scroll up into the seeded
    /// history, note where a row sits, wait for the reply, and require that row
    /// to be exactly where it was — with the "new below" pill showing instead.
    func testAReplyArrivingWhileReadingHistoryDoesNotMoveTheReader() throws {
        let cfg = try requireEnv(Env.config)
        let nonce = ProcessInfo.processInfo.environment[Env.nonce] ?? "smokefallback"

        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(cfg)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30),
                      "Injected profile never appeared — the launch-argument seam did not run. \(dump(app))")

        let composer = try openSeededConversation(app)
        try assertReplyDoesNotMoveReader(app, composer: composer, nonce: nonce + "ca", phase: "chat mode")

        // Flip the composer to Run mode (a detached run, tailed live) and repeat.
        // The keyboard is still up from the last send; a drag on the transcript
        // dismisses it interactively, so the chip's tap is a tap and not the
        // keyboard's dismissal.
        app.swipeDown()
        guard let chip = firstHittable(app.buttons["mode-chip"]) else {
            XCTFail("No Chat/Run mode chip by the composer. \(dump(app))")
            throw XCTSkip("no mode chip")   // unreachable: continueAfterFailure = false
        }
        let runChip = app.buttons.matching(NSPredicate(format: "identifier == 'mode-chip' AND label CONTAINS[c] 'run'")).firstMatch
        chip.tap()
        if !runChip.waitForExistence(timeout: 4) { app.buttons["mode-chip"].firstMatch.tap() }   // once more if the first tap only closed something
        XCTAssertTrue(runChip.waitForExistence(timeout: 5),
                      "The mode chip did not flip to Run (chip now reads '\(app.buttons["mode-chip"].firstMatch.label)'). \(dump(app))")
        try assertReplyDoesNotMoveReader(app, composer: try waitForComposer(app), nonce: nonce + "ru", phase: "run mode")
    }

    // MARK: - Flow 1d: one branch button per FINISHED turn (REAL sandbox)
    /// Testers saw 「分支到新对话」 under every progress bubble of a running Codex
    /// turn (2026-10-17). On the real screen: the seeded history shows one
    /// button per turn, a turn in progress adds none, and the finished reply
    /// adds exactly one.
    func testBranchButtonAppearsOncePerFinishedTurn() throws {
        let cfg = try requireEnv(Env.config)
        let nonce = ProcessInfo.processInfo.environment[Env.nonce] ?? "smokefallback"
        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(cfg)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30), "Injected profile never appeared. \(dump(app))")
        let composer = try openSeededConversation(app)
        let buttons = app.buttons.matching(identifier: "branch-here")
        // The phone opens a long history on its last 60 turns (ChatStore's
        // `transcript --limit 60`): all 30 seeded replies are on screen, so 30
        // finished turns. One button each — count the replies, not a number
        // this test would have to know.
        let replies = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "seed reply", "seed reply"))
        XCTAssertTrue(replies.firstMatch.waitForExistence(timeout: 30), "the seeded replies never rendered. \(dump(app))")
        // A reply surfaces as more than one accessibility element (the text view
        // and its container both carry the words), so count DISTINCT replies by
        // their "seed reply N" head, not matches.
        let heads = Set(replies.allElementsBoundByIndex.map { el -> String in
            let text = el.label.isEmpty ? ((el.value as? String) ?? "") : el.label
            return String(text.prefix { $0 != "," })
        })
        XCTAssertGreaterThan(heads.count, 1, "expected several seeded replies on screen: \(heads). \(dump(app))")
        // The phone opens a long history on its last 60 turns = all 30 seeded
        // replies, so 30 finished turns. The number is the app's own page size
        // (ChatStore `transcript --limit 60`), pinned here on purpose; counting
        // reply elements instead proved flaky (an off-screen text view may not
        // expose its words yet), while the buttons are plain and countable.
        let shown = 30
        // The anchors are back-filled right after the history loads; give that a moment.
        let deadline = Date().addingTimeInterval(20)
        while buttons.count < shown, Date() < deadline { usleep(500_000) }
        let before = buttons.count
        XCTAssertEqual(before, shown, "one branch button per finished turn shown (last 60 turns = \(shown) replies; heads seen: \(heads.count)). \(dump(app))")
        composer.tap()
        composer.typeText("slow " + nonce + "br")
        try sendButton(app).tap()
        // The turn is running (the sandbox agent answers after a while): no new button yet.
        sleep(3)
        XCTAssertEqual(buttons.count, before, "a turn in progress must not grow a branch button. \(dump(app))")
        XCTAssertTrue(echo(app, "slow " + nonce + "br").waitForExistence(timeout: 120), "the reply never landed. \(dump(app))")
        let settled = Date().addingTimeInterval(15)
        while buttons.count < before + 1, Date() < settled { usleep(500_000) }
        XCTAssertEqual(buttons.count, before + 1, "the finished turn adds exactly one branch button. \(dump(app))")
    }

    /// Deleting a conversation asks first, then the Mac's record goes (2026-10-21):
    /// the pencil menu's red row on the conversation on screen, and the project
    /// list's swipe — Cancel keeps it, Delete removes the row and the file on the
    /// server. The test makes its own conversations; the seeded one must outlive
    /// the suite.
    func testDeletingAConversationAsksFirstThenRemovesItOnTheMac() throws {
        let cfg = try requireEnv(Env.config)
        let home = try requireEnv(Env.home)
        let nonce = (ProcessInfo.processInfo.environment[Env.nonce] ?? "smokefallback") + "del"
        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(cfg)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30), "Injected profile never appeared. \(dump(app))")
        let projects = (home as NSString).appendingPathComponent(".claude/projects")
        func filesCarrying(_ word: String) -> [String] {
            guard let e = FileManager.default.enumerator(atPath: projects) else { return [] }
            return e.compactMap { $0 as? String }.filter { $0.hasSuffix(".jsonl") }.filter {
                (try? String(contentsOfFile: (projects as NSString).appendingPathComponent($0), encoding: .utf8))?.contains(word) == true
            }
        }
        func waitFiles(_ word: String, count: Int, secs: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(secs)
            while filesCarrying(word).count != count, Date() < deadline { usleep(500_000) }
            return filesCarrying(word).count == count
        }

        // 1. A conversation of this test's own, on screen and on the Mac.
        var composer = try openNewChat(app)
        composer.tap(); composer.typeText(nonce + "a")
        try sendButton(app).tap()
        XCTAssertTrue(echo(app, nonce + "a").waitForExistence(timeout: replyTimeout), "the reply never landed. \(dump(app))")
        XCTAssertTrue(waitFiles(nonce + "a", count: 1, secs: 15), "the conversation is not on the Mac: \(filesCarrying(nonce + "a"))")

        // 2. The pencil menu's red row asks; Cancel keeps everything.
        let menu = app.buttons["new-chat-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "no pencil menu. \(dump(app))")
        menu.tap()
        let red = app.buttons["Delete this conversation"]
        XCTAssertTrue(red.waitForExistence(timeout: 5), "no red row in the pencil menu. \(dump(app))")
        red.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "deleting did not ask first. \(dump(app))")
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(echo(app, nonce + "a").waitForExistence(timeout: 5), "Cancel must keep the conversation on screen. \(dump(app))")
        XCTAssertEqual(filesCarrying(nonce + "a").count, 1, "…and on the Mac")

        // 3. Confirmed: off the screen and off the Mac.
        menu.tap()
        XCTAssertTrue(red.waitForExistence(timeout: 5), "the red row is gone the second time. \(dump(app))")
        red.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(waitFiles(nonce + "a", count: 0, secs: 20), "the Mac still has the record: \(filesCarrying(nonce + "a"))")
        XCTAssertFalse(echo(app, nonce + "a").exists, "the deleted conversation is still on screen. \(dump(app))")

        // 4. The project list's swipe on a second conversation: asks, then removes the row and the file.
        composer = try waitForComposer(app)
        composer.tap(); composer.typeText(nonce + "b")
        try sendButton(app).tap()
        XCTAssertTrue(echo(app, nonce + "b").waitForExistence(timeout: replyTimeout), "the second reply never landed. \(dump(app))")
        XCTAssertTrue(waitFiles(nonce + "b", count: 1, secs: 15), "the second conversation is not on the Mac")
        app.buttons["bar-back"].firstMatch.tap()
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", nonce + "b")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the second conversation is not listed. \(dump(app))")
        row.swipeLeft()
        let trash = app.buttons["Delete"].firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: 5), "no Delete on the swipe. \(dump(app))")
        trash.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5), "the list's delete did not ask first. \(dump(app))")
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(waitFiles(nonce + "b", count: 0, secs: 20), "the Mac still has the second record: \(filesCarrying(nonce + "b"))")
        let settled = Date().addingTimeInterval(10)
        while row.exists, Date() < settled { usleep(500_000) }
        XCTAssertFalse(row.exists, "the deleted conversation is still listed. \(dump(app))")
    }

    /// The web preview (2026-11-06): ＋ → Web preview lists what the sandbox
    /// Mac is listening on, the sandbox page opens through the SSH tunnel and
    /// shows its own token, a link inside it stays in the preview, and the
    /// camera drops a screenshot of it into the composer as an attachment.
    func testWebPreviewOpensTheMacsPageThroughTheTunnel() throws {
        let cfg = try requireEnv(Env.config)
        let portText = try requireEnv(Env.httpPort)
        let token = try requireEnv(Env.httpToken)
        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(cfg)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30), "Injected profile never appeared. \(dump(app))")
        _ = try openSeededConversation(app)
        guard let plus = firstHittable(app.buttons["composer-plus"]) else { return XCTFail("no ＋ by the composer. \(dump(app))") }
        plus.tap()
        let entry = app.buttons["Web preview"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "no Web preview in the ＋ menu. \(dump(app))")
        entry.tap()
        // The sandbox page is one of the rows the Mac reports listening.
        let row = app.buttons["web-port-\(portText)"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the sandbox page's port \(portText) is not listed. \(dump(app))")
        row.tap()
        // The page came through the tunnel: its body carries this sandbox's token.
        let body = app.webViews.staticTexts[token]
        XCTAssertTrue(body.waitForExistence(timeout: 45), "the page's token never showed — the tunnel did not carry the page. \(dump(app))")
        let status = app.staticTexts["web-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("Tunnel up"), "the status line should say the tunnel is up: '\(status.label)'")
        // A link inside the page stays in the preview (no jump to Safari).
        let link = app.webViews.links["second page"]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "the page's own link is not there. \(dump(app))")
        link.tap()
        XCTAssertTrue(app.webViews.staticTexts["PERVIO_WEB_SECOND"].waitForExistence(timeout: 30), "the second page did not open inside the preview. \(dump(app))")
        XCTAssertTrue(app.state == .runningForeground, "the app left the foreground — the link must not open Safari")
        // The camera: a screenshot lands in the composer, the preview closes.
        let shot = app.buttons["web-shot"]
        XCTAssertTrue(shot.waitForExistence(timeout: 5))
        shot.tap()
        let chip = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "web-\(portText)")).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 30), "no screenshot chip by the composer. \(dump(app))")
        XCTAssertFalse(app.staticTexts["web-status"].exists, "the preview should have closed after the shot")
    }

    // MARK: - Flow: a file and a conversation brought over from ANOTHER computer (REAL sandbox, under two names)

    /// A name picked on another computer that is a link to a file OUTSIDE the
    /// folder it sits in (a repository can carry `notes.txt` that leads to a
    /// private key — security review 2026-11-22, #5): the row says where it
    /// leads, a tap asks before anything is read, "Skip" brings nothing, and
    /// "Bring it" brings the file it leads to. Against the sandbox's real file
    /// system, through the app's real pages.
    func testALinkPickedOnAnotherComputerIsAskedAboutBeforeItIsRead() throws {
        let cfg = try requireEnv(Env.config)
        let home = try requireEnv(Env.home)
        let nonce = String(UUID().uuidString.prefix(8)).lowercased()
        let fm = FileManager.default
        let far = home + "/farlink" + nonce
        let vault = home + "/vault" + nonce
        try fm.createDirectory(atPath: far, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: vault, withIntermediateDirectories: true)
        let secret = "PRIVATE-\(nonce)-do-not-carry"
        try secret.write(toFile: vault + "/id_key", atomically: true, encoding: .utf8)
        let linkName = "notes-\(nonce).txt"
        try fm.createSymbolicLink(atPath: far + "/" + linkName, withDestinationPath: "../vault\(nonce)/id_key")
        try "plain".write(toFile: far + "/plain-\(nonce).txt", atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: far); try? fm.removeItem(atPath: vault) }

        guard let raw = Data(base64Encoded: cfg),
              var json = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return XCTFail("the sandbox config is not base64 JSON")
        }
        json["second"] = ["name": "Far Mac", "projectDir": far, "viaJump": true]
        let two = try JSONSerialization.data(withJSONObject: json).base64EncodedString()
        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(two)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30), "Injected profile never appeared. \(dump(app))")
        _ = try openSeededConversation(app)
        let uploads = home + "/.pervio/uploads"
        let before = Set((try? fm.contentsOfDirectory(atPath: uploads)) ?? [])
        func landed() -> Set<String> { Set((try? fm.contentsOfDirectory(atPath: uploads)) ?? []).subtracting(before) }

        /// ＋ → Server file… → From: Far Mac → tap the link's row.
        func pickTheLink() throws {
            guard let plus = firstHittable(app.buttons["composer-plus"]) else { return XCTFail("no ＋ by the composer. \(dump(app))") }
            plus.tap()
            guard let entry = firstHittable(menuItem(app, "Server file"), menuItem(app, "服务器文件")) else {
                return XCTFail("no Server file… in the ＋ menu. \(dump(app))")
            }
            entry.tap()
            let switcher = app.buttons["source-switcher"]
            XCTAssertTrue(switcher.waitForExistence(timeout: 20), "no From row. \(dump(app))")
            switcher.tap()
            guard let other = firstHittable(menuItem(app, "Far Mac")) else { return XCTFail("the other computer is not in the menu. \(dump(app))") }
            other.tap()
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", linkName)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 45), "the other computer's folder did not list. \(dump(app))")
            XCTAssertTrue(row.label.contains("id_key"), "a link's row must say where it leads, before it is tapped: '\(row.label)'")
            shot(app, "link-1-row")
            row.tap()
        }

        // "Skip": nothing is read, nothing lands, and the page says why.
        try pickTheLink()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "a link out of its folder was not asked about. \(dump(app))")
        XCTAssertTrue(alert.label.contains(linkName), "the question names what was picked: '\(alert.label)'")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "vault\(nonce)/id_key")).firstMatch.exists,
                      "…and the file it leads to. \(dump(app))")
        XCTAssertTrue(landed().isEmpty, "something reached this computer before the person answered: \(landed())")
        shot(app, "link-2-question")
        alert.buttons["Skip"].tap()
        let said = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "was not brought over")).firstMatch
        XCTAssertTrue(said.waitForExistence(timeout: 20), "'Skip' left no word on the page. \(dump(app))")
        XCTAssertTrue(landed().isEmpty, "'Skip' still brought something: \(landed())")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", linkName)).firstMatch.exists, "a chip appeared")

        // "Bring it": the file it leads to arrives, under the name that was picked.
        try pickTheLink()
        XCTAssertTrue(alert.waitForExistence(timeout: 30), "the second pick was not asked about. \(dump(app))")
        alert.buttons["Bring it"].tap()
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !landed().contains(where: { $0.hasSuffix("-" + linkName) }) { usleep(300_000) }
        guard let file = landed().first(where: { $0.hasSuffix("-" + linkName) }) else {
            return XCTFail("'Bring it' brought nothing: \(landed()). \(dump(app))")
        }
        XCTAssertEqual(try String(contentsOfFile: uploads + "/" + file, encoding: .utf8), secret,
                       "what landed is not the file the link leads to")
        shot(app, "link-3-brought")
    }

    /// 2026-11-22, the person's ask: several computers working together through
    /// the phone. Two saved servers — the sandbox under two names and two
    /// folders, which to the app is two computers. ＋ → Server file… gains a
    /// "From" row; with the other computer chosen the page lists ITS folder, a
    /// file over 8 MB says so in its row, a directory cannot be handed over,
    /// and a tapped file is read from there, written here and lands as a chip
    /// while the strip above the composer names the leg it is on. ＋ →
    /// Context… does the same for a conversation too long for one document:
    /// its full record comes along as a second file and the document says
    /// where that is. Checked on the sandbox's own disk, not on the screen:
    /// the bytes that landed are the bytes that were there, every turn once.
    func testAFileAndAConversationComeOverFromAnotherComputer() throws {
        let cfg = try requireEnv(Env.config)
        let home = try requireEnv(Env.home)
        let nonce = String(UUID().uuidString.prefix(8)).lowercased()     // hex: it ends a session id
        let fm = FileManager.default

        // The other computer's folder, with three files of its own.
        let far = home + "/far" + nonce
        try fm.createDirectory(atPath: far + "/sub", withIntermediateDirectories: true)
        var blob = Data(count: 6 * 1024 * 1024 + 4321)          // several chunks on both legs
        blob.withUnsafeMutableBytes { raw in
            var x: UInt64 = 0x9E3779B97F4A7C15
            for i in 0..<raw.count { x ^= x << 13; x ^= x >> 7; x ^= x << 17; raw[i] = UInt8(truncatingIfNeeded: x) }
        }
        let blobName = "blob-\(nonce).bin"
        try blob.write(to: URL(fileURLWithPath: far + "/" + blobName))
        let hugeName = "huge-\(nonce).bin"
        fm.createFile(atPath: far + "/" + hugeName, contents: nil)
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: far + "/" + hugeName))
        try h.truncate(atOffset: 9 * 1024 * 1024); try h.close()   // 9 MB of nothing: over the limit

        // …and a conversation of 900 turns that happened in that folder.
        let sid = "0000fa20-0000-4000-8000-0000" + nonce
        let enc = String(far.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "-" })
        let records = home + "/.claude/projects/" + enc
        try fm.createDirectory(atPath: records, withIntermediateDirectories: true)
        var lines: [String] = []
        for i in 1...450 {
            let q = i == 1 ? "far long conversation \(nonce)" : "far question \(i) of \(nonce)"
            for (type, role, content): (String, String, Any) in [
                ("user", "user", q),
                ("assistant", "assistant", [["type": "text", "text": "far answer \(i) of \(nonce)"]]),
            ] {
                let row: [String: Any] = ["type": type, "cwd": far, "uuid": "far-\(type.prefix(1))\(i)",
                                          "message": ["role": role, "content": content, "model": "e2e-shim"]]
                lines.append(String(decoding: try JSONSerialization.data(withJSONObject: row), as: UTF8.self))
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: records + "/" + sid + ".jsonl", atomically: true, encoding: .utf8)
        defer {
            try? fm.removeItem(atPath: far)
            try? fm.removeItem(atPath: records)
        }

        // The sandbox, saved twice.
        guard let raw = Data(base64Encoded: cfg),
              var json = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return XCTFail("the sandbox config is not base64 JSON")
        }
        // Behind the sandbox's jump host: the same endpoint by the same path
        // would be this very Mac to the app, and not offered at all.
        json["second"] = ["name": "Far Mac", "projectDir": far, "viaJump": true]
        let two = try JSONSerialization.data(withJSONObject: json).base64EncodedString()

        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(two)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30), "Injected profile never appeared. \(dump(app))")
        _ = try openSeededConversation(app)
        let uploads = home + "/.pervio/uploads"
        let before = Set((try? fm.contentsOfDirectory(atPath: uploads)) ?? [])

        // ---- a file
        guard let plus = firstHittable(app.buttons["composer-plus"]) else { return XCTFail("no ＋ by the composer. \(dump(app))") }
        plus.tap()
        guard let entry = firstHittable(menuItem(app, "Server file"), menuItem(app, "服务器文件")) else {
            return XCTFail("no Server file… in the ＋ menu. \(dump(app))")
        }
        entry.tap()
        let switcher = app.buttons["source-switcher"]
        XCTAssertTrue(switcher.waitForExistence(timeout: 20), "two servers are saved and the page has no From row. \(dump(app))")
        XCTAssertTrue(switcher.label.contains("E2E Sandbox"), "the page opens on the conversation's own computer: '\(switcher.label)'")
        XCTAssertFalse(app.staticTexts["source-note"].exists, "nothing travels while this computer is chosen, so nothing should say it does")
        shot(app, "far-1-own")
        switcher.tap()
        guard let other = firstHittable(menuItem(app, "Far Mac")) else { return XCTFail("the other computer is not in the menu. \(dump(app))") }
        other.tap()
        let note = app.staticTexts["source-note"]
        XCTAssertTrue(note.waitForExistence(timeout: 20), "choosing another computer says nothing about how a pick gets here. \(dump(app))")
        XCTAssertTrue(note.label.contains("E2E Sandbox") && note.label.contains("8 MB"), "the note names where it goes and the limit: '\(note.label)'")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", blobName)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 45), "the other computer's folder did not list (it opens on ITS folder). \(dump(app))")
        let huge = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", hugeName)).firstMatch
        XCTAssertTrue(huge.exists, "the large file is not listed. \(dump(app))")
        XCTAssertTrue(huge.label.contains("over 8 MB"), "a file over the limit must say so in its row: '\(huge.label)'")
        XCTAssertFalse(huge.isEnabled, "a file over the limit must not be tappable")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "Hand this", "交给对话")).firstMatch.exists,
                       "a directory on another computer was offered to this conversation. \(dump(app))")
        shot(app, "far-2-other")
        row.tap()

        // The strip names the leg it is on; whatever of it the polling catches is logged.
        let chip = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", blobName)).firstMatch
        var stages: [String] = []
        var sawStop = false
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            let strip = app.descendants(matching: .any).matching(identifier: "transfer-strip").firstMatch
            // One look at the strip, not "is it there" and then "what does it say":
            // it can go between the two, and a label asked of an element that
            // has just gone is a test failure of its own (seen 2026-11-22).
            if let seen = try? strip.snapshot() {
                if !sawStop { sawStop = app.buttons["transfer-stop"].exists }
                let label = seen.label
                if !label.isEmpty, stages.last != label { stages.append(label); if stages.count == 2 { shot(app, "far-3-strip") } }
            } else if chip.exists { break }
        }
        NSLog("PERVIO_PROBE transfer strip: %@", stages.description)
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "the file never became a chip. strip said \(stages). \(dump(app))")
        XCTAssertTrue(stages.contains { $0.contains("Far Mac") || $0.contains("E2E Sandbox") },
                      "while a 6 MB file crossed, the strip never named a computer: \(stages)")
        XCTAssertFalse(stages.contains { $0.contains("Uploading") }, "a pick from another computer read as a plain upload: \(stages)")
        XCTAssertTrue(sawStop, "a transfer this long has to offer a way to stop it")
        shot(app, "far-4-chip")
        let landed = Set((try? fm.contentsOfDirectory(atPath: uploads)) ?? []).subtracting(before)
        guard let file = landed.first(where: { $0.hasSuffix("-" + blobName) }) else {
            return XCTFail("nothing named \(blobName) landed in this computer's uploads: \(landed)")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: uploads + "/" + file)), blob,
                       "the file that landed is not the file that was on the other computer")

        // ---- a conversation
        guard let plus2 = firstHittable(app.buttons["composer-plus"]) else { return XCTFail("the ＋ did not come back. \(dump(app))") }
        plus2.tap()
        guard let ctx = firstHittable(menuItem(app, "Context"), menuItem(app, "背景")) else {
            return XCTFail("no Context… in the ＋ menu. \(dump(app))")
        }
        ctx.tap()
        let switcher2 = app.buttons["source-switcher"]
        XCTAssertTrue(switcher2.waitForExistence(timeout: 20), "the Context page has no From row. \(dump(app))")
        switcher2.tap()
        guard let other2 = firstHittable(menuItem(app, "Far Mac")) else { return XCTFail("the other computer is not in the menu. \(dump(app))") }
        other2.tap()
        XCTAssertTrue(app.staticTexts["source-note"].waitForExistence(timeout: 20), "no note on the Context page. \(dump(app))")
        let project = app.staticTexts["far" + nonce].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 60), "the other computer's projects did not list. \(dump(app))")
        XCTAssertFalse(app.staticTexts["This project"].exists, "a folder on another computer was marked as this conversation's project")
        project.tap()
        let conv = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "far long conversation \(nonce)")).firstMatch
        XCTAssertTrue(conv.waitForExistence(timeout: 30), "the far conversation is not listed. \(dump(app))")
        conv.tap()
        shot(app, "far-5-context")
        let attach = app.buttons["context-attach"]
        XCTAssertTrue(attach.waitForExistence(timeout: 5) && attach.isEnabled, "the attach button did not arm. \(dump(app))")
        attach.tap()
        let thread = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "🧵 far" + nonce)).firstMatch
        XCTAssertTrue(thread.waitForExistence(timeout: 120), "the conversation never became a chip. \(dump(app))")
        shot(app, "far-6-both")

        let after = Set((try? fm.contentsOfDirectory(atPath: uploads)) ?? []).subtracting(before)
        let id8 = String(sid.prefix(8))
        guard let docName = after.first(where: { $0.hasSuffix("-context-\(id8).md") }),
              let fullName = after.first(where: { $0.hasSuffix("-context-\(id8)-full.md") }) else {
            return XCTFail("a 900-turn conversation must land as a document AND its full record: \(after)")
        }
        let doc = try String(contentsOfFile: uploads + "/" + docName, encoding: .utf8)
        let full = try String(contentsOfFile: uploads + "/" + fullName, encoding: .utf8)
        XCTAssertTrue(doc.contains("Source computer: Far Mac"), String(doc.prefix(300)))
        XCTAssertTrue(doc.contains("has 900 turns in all; this document holds turns 501-900"), String(doc.prefix(500)))
        XCTAssertTrue(doc.contains(uploads + "/" + fullName), "the document does not name where the full record landed: \(doc.prefix(700))")
        XCTAssertFalse(doc.contains("pervio-sessions"), "a command that only works on the other computer was handed to this one")
        XCTAssertTrue(doc.contains("#900 [assistant] far answer 450 of \(nonce)"))
        XCTAssertTrue(full.contains("this file holds turns 1-900"), String(full.prefix(400)))
        let body = full.components(separatedBy: "\n---\n").dropFirst().joined(separator: "\n---\n")
        let entries = body.components(separatedBy: "\n\n")
        XCTAssertEqual(entries.count, 900, "the full record does not hold every turn once")
        for (i, e) in entries.enumerated() {
            let n = i + 1, pair = (n + 1) / 2
            let want = n % 2 == 1 ? "#\(n) [user] " + (n == 1 ? "far long conversation \(nonce)" : "far question \(pair) of \(nonce)")
                                  : "#\(n) [assistant] far answer \(pair) of \(nonce)"
            if e != want { XCTFail("turn \(n) of the full record is wrong: '\(e.prefix(80))' (want '\(want)')"); break }
        }
    }

    // MARK: - Flow 1g: sub-agents and background commands are one line, with the list behind it (REAL sandbox)
    /// The person, 2026-11-22: "可以跟后面进程弄在一个框(不然太多就是盖住对话了)
    /// 只不过可以点击查看一共有多少". A Run turn whose engine starts two sub-agents
    /// and two background commands (the sandbox agent's "agents …" — the events
    /// of a real Claude Code, through the real pervio-run): one line above the
    /// composer counts them, a tap lists each with its type and totals, an
    /// ending moves down the list while it is open, and when all have ended the
    /// conversation keeps one line that opens the same list.
    func testSubagentsAndBackgroundCommandsAreOneLineWithTheListBehindIt() throws {
        let cfg = try requireEnv(Env.config)
        let nonce = ProcessInfo.processInfo.environment[Env.nonce] ?? "smokefallback"

        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(cfg)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30),
                      "Injected profile never appeared — the launch-argument seam did not run. \(dump(app))")
        let composer = try openSeededConversation(app)

        // Run mode: the engine's process stays on past its reply, which is where background work lives.
        guard let chip = firstHittable(app.buttons["mode-chip"]) else {
            XCTFail("No Chat/Run mode chip by the composer. \(dump(app))")
            throw XCTSkip("no mode chip")   // unreachable: continueAfterFailure = false
        }
        let runChip = app.buttons.matching(NSPredicate(format: "identifier == 'mode-chip' AND label CONTAINS[c] 'run'")).firstMatch
        chip.tap()
        if !runChip.waitForExistence(timeout: 4) { app.buttons["mode-chip"].firstMatch.tap() }
        XCTAssertTrue(runChip.waitForExistence(timeout: 5), "The mode chip did not flip to Run. \(dump(app))")

        composer.tap()
        composer.typeText("agents " + nonce + "ag")
        try sendButton(app).tap()
        XCTAssertTrue(echo(app, "agents " + nonce + "ag").waitForExistence(timeout: 60), "the reply never landed. \(dump(app))")

        // One line, however many there are.
        let bar = app.buttons["background-bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "no line above the composer for the engine's sub-agents. \(dump(app))")
        XCTAssertTrue(bar.label.contains("2 subagents") && bar.label.contains("background command"),
                      "the line does not count them by kind: '\(bar.label)'")
        XCTAssertFalse(app.descendants(matching: .any)["background-card"].exists,
                       "while anything runs nothing is added under the reply (it used to grow there, two lines a task)")
        shot(app, "agents-line")

        // The list behind it: each sub-agent as what it is, with what it has used.
        bar.tap()
        let any = app.descendants(matching: .any)
        let reviewer = any["background-running-a1"]
        XCTAssertTrue(reviewer.waitForExistence(timeout: 10), "the list did not open, or has no row for the first sub-agent. \(dump(app))")
        let said = reviewer.label
        XCTAssertTrue(said.contains("Review the diff") && said.contains("general-purpose"), "the row does not name the sub-agent and its type: '\(said)'")
        XCTAssertTrue(said.contains("12k tokens") && said.contains("3 tool uses"), "the row does not carry its latest totals: '\(said)'")
        XCTAssertTrue(any["background-running-a2"].exists && any["background-running-c1"].exists, "a row is missing. \(dump(app))")
        shot(app, "agents-list")

        // One of them stopped on its own: asked once, then that task alone ends
        // as stopped — through the real pervio-run and the engine's own control request.
        let stopKey = app.buttons["background-stop-c1"]
        XCTAssertTrue(stopKey.waitForExistence(timeout: 5), "a living Claude run's rows have a stop key. \(dump(app))")
        stopKey.tap()
        let confirm = app.buttons["background-stop-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the stop key asks before it stops. \(dump(app))")
        shot(app, "agents-stop-ask")
        confirm.tap()
        let buildStopped = any["background-ended-c1"]
        XCTAssertTrue(buildStopped.waitForExistence(timeout: 20), "the stopped command never moved to the ended ones. \(dump(app))")
        XCTAssertTrue(buildStopped.label.contains("stopped"), "a stopped task must read as stopped: '\(buildStopped.label)'")
        XCTAssertTrue(any["background-running-a1"].exists && any["background-running-a2"].exists, "the others go on. \(dump(app))")

        // An ending while the list is open moves down, with what it came back with.
        let testsEnded = any["background-ended-b1"]
        XCTAssertTrue(testsEnded.waitForExistence(timeout: 60), "the sub-agent's own command ended on the Mac and the open list never said so. \(dump(app))")
        XCTAssertTrue(testsEnded.label.contains("tests done"), "an ended row does not say what it came back with: '\(testsEnded.label)'")
        XCTAssertTrue(any["background-running-a1"].exists, "the sub-agent that launched it is still going")
        app.buttons["Done"].firstMatch.tap()

        // All ended: the line above the composer goes, the conversation keeps one row.
        let ended = app.buttons["background-card"]
        let deadline = Date().addingTimeInterval(90)
        while !(ended.exists && !bar.exists), Date() < deadline { usleep(700_000) }
        XCTAssertFalse(bar.exists, "everything ended on the Mac and the line still says something runs. \(dump(app))")
        XCTAssertTrue(ended.exists, "nothing in the conversation says how the background work ended. \(dump(app))")
        XCTAssertTrue(ended.label.contains("3 done") && ended.label.contains("1 stopped"), "the row does not say how it went: '\(ended.label)'")
        shot(app, "agents-ended")
        if !ended.isHittable { app.swipeUp() }
        ended.tap()
        let reviewed = any["background-ended-a1"]
        XCTAssertTrue(reviewed.waitForExistence(timeout: 10), "the ended row did not open the list. \(dump(app))")
        XCTAssertTrue(reviewed.label.contains("review done") && reviewed.label.contains("tokens"), "'\(reviewed.label)'")
        XCTAssertTrue(any["background-ended-c1"].label.contains("stopped"), "'\(any["background-ended-c1"].label)'")
        shot(app, "agents-ended-list")

        // Left and come back to: what ended is still said (kept on the phone
        // until the next turn), and there is nothing left to stop.
        app.buttons["Done"].firstMatch.tap()
        app.terminate()
        app.launch()                       // the app closed and opened again: the page's state is gone, the phone's is not
        dismissSystemPrompt()
        _ = try openSeededConversation(app)
        XCTAssertTrue(app.buttons["background-card"].waitForExistence(timeout: 20),
                      "back in the conversation, the row that says how the background work ended is gone. \(dump(app))")
        XCTAssertTrue(app.buttons["background-card"].label.contains("1 stopped"), "'\(app.buttons["background-card"].label)'")
    }

    // MARK: - Flow 1h: the pages that show the Mac come back by themselves when the Mac does (REAL sandbox, through a door)
    /// The person, 2026-11-22: "主页如果连接不上…每次都是退出app重新进去才能好",
    /// and then, for the other list pages, "都开始吧". A page read the Mac once
    /// and stayed on what that read said. Here the sandbox's sshd is reached
    /// through a door this test can shut and open (a loopback relay of its
    /// own), so the Mac goes away and comes back while the app keeps running —
    /// and nobody touches the app between the door opening and the page being
    /// right again. Walked on every page that follows the rule:
    ///   home       shut at launch → says so and that it is retrying → opened → fills in
    ///   projects   shut while the app is away → says so over its list → opened → the line goes
    ///   workflows  opened onto a Mac that is gone → says so → opened → the page reads
    ///   projects   come BACK to with the Mac gone (a page reads when returned to) → says so → opened → the line goes
    ///   sessions   shut, pulled → says so over its list → opened → the line goes
    func testThePagesThatShowTheMacComeBackByThemselvesWhenItDoes() throws {
        let cfg = try requireEnv(Env.config)
        guard let raw = Data(base64Encoded: cfg),
              var json = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let sshd = json["port"] as? Int else {
            XCTFail("the sandbox config is not what this test reads"); return
        }
        let door = try Door(to: UInt16(sshd))
        defer { door.shut() }
        json["port"] = Int(door.port)
        let viaDoor = try JSONSerialization.data(withJSONObject: json).base64EncodedString()

        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(viaDoor)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30),
                      "Injected profile never appeared — the launch-argument seam did not run. \(dump(app))")
        let any = app.descendants(matching: .any)
        let unreachable = any["mac-unreachable"]
        /// A conversation of the project, whichever is on screen: the seeded
        /// one sinks below the fold as the flows before this one add theirs.
        let conversation = any.matching(NSPredicate(format: "label CONTAINS %@ OR label BEGINSWITH %@",
                                                    "e2e long history", "smoke")).firstMatch
        /// The home page has read the Mac: its conversations are listed under
        /// this heading. (Not one conversation by name — the block shows the
        /// ten newest, and a sandbox many flows have used has more.)
        let listed = any.matching(NSPredicate(format: "label IN %@", ["Recent", "最近"])).firstMatch
        /// The Mac is back: the page's line must go, by itself, within the waits it keeps (2, 4, 8, 15 s…).
        func comesBack(_ page: String, _ shows: XCUIElement? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
            try door.open()
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline, unreachable.exists || !(shows?.exists ?? true) { usleep(500_000) }
            XCTAssertFalse(unreachable.exists, "\(page): the Mac came back and the page still says it cannot reach it — the app had to be quit for that. \(dump(app))", file: file, line: line)
            if let shows { XCTAssertTrue(shows.exists, "\(page): the page never read the Mac again. \(dump(app))", file: file, line: line) }
        }
        /// The Mac is gone: the page must say so — and that it is trying again — over what it already shows.
        func saysSo(_ page: String, keeps: XCUIElement? = nil, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(unreachable.waitForExistence(timeout: 40), "\(page): with the Mac out of reach the page shows no sign of it. \(dump(app))", file: file, line: line)
            XCTAssertTrue(any["mac-retrying"].waitForExistence(timeout: 20), "\(page): the page does not say it is trying again. \(dump(app))", file: file, line: line)
            if let keeps { XCTAssertTrue(keeps.exists, "\(page): what was read before must stay on the page (stale beats blank). \(dump(app))", file: file, line: line) }
        }
        func awayAndBack() { XCUIDevice.shared.press(.home); sleep(2); app.activate() }

        // Home: shut at launch.
        saysSo("home")
        XCTAssertFalse(listed.exists, "nothing of the Mac's can be on the page yet")
        XCTAssertFalse(app.buttons["home-retry"].exists, "no retry key: a failed read is the one signal, a pull the one way to ask sooner")
        shot(app, "pages-1-home-unreachable")
        try comesBack("home", listed)
        shot(app, "pages-2-home-back")

        // Projects: the Mac goes while the app is away. (The footer that leads
        // there sits under the conversations just listed — below the fold when
        // there are many.)
        guard let footer = scrollToFirstHittable(app, homeServerLine(app)) else {
            XCTFail("the home page's server line is nowhere to be reached. \(dump(app))"); return
        }
        footer.tap()
        let project = app.staticTexts["e2eproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 60), "The seeded project never listed. \(dump(app))")
        door.shut()
        awayAndBack()
        saysSo("projects, back from the background", keeps: project)
        shot(app, "pages-3-projects-unreachable")
        try comesBack("projects", project)

        // Workflows: opened onto a Mac that is gone.
        door.shut()
        app.staticTexts["Multi-step workflows"].firstMatch.tap()
        saysSo("workflows, opened")
        try comesBack("workflows")
        XCTAssertTrue(app.staticTexts["No workflows yet."].waitForExistence(timeout: 20) || app.cells.count > 2,
                      "the workflows page did not read the Mac after it came back. \(dump(app))")

        // Projects again: come BACK to with the Mac gone — a page reads when it is returned to.
        door.shut()
        app.buttons["bar-back"].firstMatch.tap()
        saysSo("projects, come back to", keeps: project)
        try comesBack("projects again", project)

        // Sessions: pulled with the Mac gone.
        project.tap()
        XCTAssertTrue(conversation.waitForExistence(timeout: 30), "The project's conversations are not listed. \(dump(app))")
        door.shut()
        conversation.swipeDown(velocity: .slow)
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        saysSo("sessions, pulled", keeps: conversation)
        shot(app, "pages-4-sessions-unreachable")
        try comesBack("sessions", conversation)
    }

    /// A read the Mac REFUSED is not one it could not be reached for: the line
    /// is red, nothing tries again by itself (a credential sent again and again
    /// is how an address gets banned — counted here in the sandbox sshd's own
    /// log, which also covers the standing runs poll), and the way out is the
    /// server's settings instead of the checkup. Fixed there, the page reads
    /// again without the app being quit, and nothing goes on asking as the
    /// account that was wrong.
    func testARefusedReadPointsToTheSettingsAndThePageReadsAgainOnceFixed() throws {
        let cfg = try requireEnv(Env.config)
        let home = try requireEnv(Env.home)
        let nonce = try requireEnv(Env.nonce)
        guard let raw = Data(base64Encoded: cfg),
              var json = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let account = json["username"] as? String else {
            XCTFail("the sandbox config is not what this test reads"); return
        }
        let wrong = "pervio-wrong-\(nonce)"
        json["username"] = wrong
        let seededWrong = try JSONSerialization.data(withJSONObject: json).base64EncodedString()
        let log = (home as NSString).deletingLastPathComponent + "/sshd.log"
        /// How many times the sandbox's sshd was asked as the wrong account.
        func refusals() -> Int {
            let text = String(decoding: (try? Data(contentsOf: URL(fileURLWithPath: log))) ?? Data(), as: UTF8.self)
            return text.components(separatedBy: "Invalid user \(wrong) ").count - 1
        }

        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(seededWrong)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30),
                      "Injected profile never appeared — the launch-argument seam did not run. \(dump(app))")
        let any = app.descendants(matching: .any)
        let refused = any["mac-refused"]
        let settings = app.buttons["mac-settings"]
        XCTAssertTrue(refused.waitForExistence(timeout: 40), "the Mac refused the account and the page does not say so. \(dump(app))")
        XCTAssertTrue(settings.exists, "a refusal is fixed in the server's settings: the line must lead there. \(dump(app))")
        XCTAssertFalse(any["mac-unreachable"].exists, "refused is not unreachable")
        XCTAssertFalse(any["mac-retrying"].exists, "nothing is trying again, so nothing may say it is")
        XCTAssertFalse(app.buttons["mac-checkup"].exists)

        // Let the launch's own first asks land (the two blocks, the runs poll,
        // the script check), then count: nothing more may be asked by itself.
        var asked = refusals(), still = 0
        while still < 5 {
            sleep(1)
            let now = refusals()
            if now == asked { still += 1 } else { asked = now; still = 0 }
        }
        XCTAssertGreaterThan(asked, 0, "the sandbox's sshd did not log the refusals this test counts — \(log)")
        sleep(25)                            // the standing poll used to come every 15 s
        XCTAssertEqual(refusals(), asked, "a refused account was sent again with nobody asking")
        XCTAssertTrue(refused.exists)
        XCTAssertFalse(any["mac-retrying"].exists)
        shot(app, "refused-1-home")

        // The way out: the server's settings, the account corrected, Save.
        settings.tap()
        let field = app.textFields.matching(NSPredicate(format: "value == %@", wrong)).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "the settings did not open on this server. \(dump(app))")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: wrong.count + 2) + account)
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", account)).firstMatch.waitForExistence(timeout: 10),
                      "the account was not retyped as meant. \(dump(app))")
        app.buttons["Save"].firstMatch.tap()

        let listed = any.matching(NSPredicate(format: "label IN %@", ["Recent", "最近"])).firstMatch
        XCTAssertTrue(listed.waitForExistence(timeout: 60),
                      "the settings were fixed and the page did not read the Mac again — the app had to be quit for that. \(dump(app))")
        // The line goes when the READ is through — both of the page's blocks;
        // the conversations can be listed a moment before the other one answers.
        let gone = Date().addingTimeInterval(20)
        while refused.exists, Date() < gone { usleep(300_000) }
        XCTAssertFalse(refused.exists, "the page was read again and still says the Mac refused. \(dump(app))")
        shot(app, "refused-2-home-fixed")
        sleep(6)
        XCTAssertEqual(refusals(), asked, "after the fix something still asked as the account that was wrong (a poll built before the settings changed)")
        // …and the running row's poll is alive again, as the account that is
        // right: with the page read, it is the one thing here that still asks
        // the Mac every few seconds (each ask is a command in sshd's log).
        func commands() -> Int {
            let text = String(decoding: (try? Data(contentsOf: URL(fileURLWithPath: log))) ?? Data(), as: UTF8.self)
            return text.components(separatedBy: "Starting session: ").count - 1
        }
        // First let what the fresh read set off run out (the script check, the
        // model menu, the engine probe): ten seconds without a command.
        var seen = commands(), calm = 0, waited = 0
        while calm < 10, waited < 45 {
            sleep(1); waited += 1
            let now = commands()
            if now == seen { calm += 1 } else { seen = now; calm = 0 }
        }
        sleep(22)                            // the poll's idle pace is 15 s
        XCTAssertGreaterThan(commands(), seen, "the settings were fixed and the running row's poll never came back — that row stays dead until the app is quit")
    }

    /// A screenshot onto the sandbox's disk, for looking at afterwards.
    private func shot(_ app: XCUIApplication, _ name: String) {
        guard let home = ProcessInfo.processInfo.environment[Env.home] else { return }
        let dir = (home as NSString).deletingLastPathComponent + "/shots"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
    }

    // MARK: - Probe: walk the main screens and hold still (screenshots from the host)
    /// Not a verdict, a stage for looking: with PERVIO_E2E_PROBE=1 it walks
    /// home → servers → project → history → chat → terminal → settings, pausing
    /// on each so `xcrun simctl io … screenshot` on the host can capture the
    /// layout on a given device (the compact bar on a small phone, 2026-10-17).
    /// Skips otherwise, so the suite's verdict never depends on it.
    func testScreensProbe() throws {
        guard ProcessInfo.processInfo.environment["PERVIO_E2E_PROBE"] != nil else { throw XCTSkip("probe only") }
        let cfg = try requireEnv(Env.config)
        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(cfg)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30), "\(dump(app))")
        sleep(6)                                              // 1: home
        openServersList(app); sleep(6)                        // 2: servers
        app.navigationBars.buttons.firstMatch.tap(); sleep(2)
        _ = try openSeededConversation(app)                   // 3/4: project, history → 5: chat
        sleep(6)
        let term = app.buttons["Terminal"].firstMatch
        if term.waitForExistence(timeout: 10) {
            term.tap(); sleep(8)                              // 6: terminal
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap(); sleep(8)   // keyboard up, if the sim shows one
            if let done = firstHittable(app.buttons["Done"], app.buttons["完成"]) { done.tap(); sleep(2) }
        }
        for _ in 0..<3 { if let back = firstHittable(app.buttons["bar-back"]) { back.tap(); sleep(2) } }
        if let gear = firstHittable(app.buttons["Settings"], app.buttons["gearshape"]) { gear.tap(); sleep(6) }   // 7: settings
    }

    // MARK: - Flow 3c: our own back glyph keeps the edge swipe (REAL sandbox)
    /// Hiding the system back button normally kills the interactive pop; the
    /// bar helper hands it back (PervioBar.swift). Pinned: on the servers page
    /// a drag from the left edge returns home.
    func testSwipeBackStillWorksWithOurBackButton() throws {
        let cfg = try requireEnv(Env.config)
        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(cfg)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30), "\(dump(app))")
        openServersList(app)
        XCTAssertTrue(app.buttons["bar-back"].firstMatch.waitForExistence(timeout: 10), "the servers page shows our back glyph. \(dump(app))")
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: to)
        XCTAssertTrue(app.navigationBars["Pervio"].waitForExistence(timeout: 8) || homeServerLine(app).waitForExistence(timeout: 8),
                      "the edge swipe did not pop back home. \(dump(app))")
    }

    // MARK: - The editor's top bar: Edit, Run and Save are all there (2026-10-20)
    /// Three bare siblings in one toolbar item drew only the first on iOS 26 —
    /// the person opened a workflow and found "…" alone: no Save, no Run. The
    /// trailing group is one HStack now; this pins that every word is on screen.
    func testWorkflowEditorBarShowsEditRunAndSave() throws {
        let cfg = try requireEnv(Env.config)
        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(cfg)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30), "\(dump(app))")
        guard let wf = firstHittable(app.buttons["工作流"], app.staticTexts["工作流"], app.buttons["Workflows"], app.staticTexts["Workflows"]) else {
            return XCTFail("no Workflows chip on the home page. \(dump(app))")
        }
        wf.tap()
        guard let new = firstHittable(app.buttons["New workflow"], app.staticTexts["New workflow"]) else {
            return XCTFail("no New workflow row. \(dump(app))")
        }
        new.tap()
        XCTAssertTrue(app.buttons["wf-save"].waitForExistence(timeout: 10), "the Save word is missing from the editor's bar. \(dump(app))")
        XCTAssertTrue(app.buttons["wf-run"].exists, "the Run word is missing from the editor's bar. \(dump(app))")
        XCTAssertTrue(app.buttons["wf-more"].exists, "the … menu is missing. \(dump(app))")
        XCTAssertTrue(app.buttons["Edit"].exists || app.buttons["编辑"].exists, "the Edit button is missing. \(dump(app))")
        XCTAssertFalse(app.buttons["wf-run"].isEnabled, "an empty draft can't run: Run shows, disabled")
    }

    // MARK: - Save makes a template of mine on the Mac (2026-10-20)
    /// Modify a market template, Save: the draft lands in ~/.pervio/templates on
    /// the server as a file of the person's own — the market's Mine shelf.
    func testWorkflowEditorSaveWritesATemplateOfMineOnTheServer() throws {
        let cfg = try requireEnv(Env.config)
        let home = try requireEnv(Env.home)
        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(cfg)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30), "\(dump(app))")
        navigateHomeToMarket(app)
        guard let row = firstHittable(app.staticTexts["GitHub 热点日报"], app.buttons["GitHub 热点日报"]) else {
            return XCTFail("the sandbox market has no GitHub 热点日报 row. \(dump(app))")
        }
        row.tap()
        // The row may be the sandbox's own template of that name (its row opens
        // the editor straight away) or the bundled publication (a detail page
        // with a Customize… link). Either way we want the editor.
        let save = app.buttons["wf-save"]
        if !save.waitForExistence(timeout: 15) {
            let custom = app.buttons["Customize…"].exists ? app.buttons["Customize…"]
                : app.buttons["自定义…"].exists ? app.buttons["自定义…"]
                : app.staticTexts["Customize…"].exists ? app.staticTexts["Customize…"] : app.staticTexts["自定义…"]
            XCTAssertTrue(custom.waitForExistence(timeout: 10), "neither the editor nor a Customize… link appeared")
            custom.tap()
        }
        XCTAssertTrue(save.waitForExistence(timeout: 15), "no Save in the editor")
        XCTAssertTrue(save.isEnabled, "a valid template must be saveable as mine")
        let dir = home + "/.pervio/templates"
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        NSLog("PERVIO_SMOKE save: before=%@ dir=%@", before.description, dir)
        save.tap()
        let alert = app.alerts.firstMatch
        let shown = alert.waitForExistence(timeout: 30)
        NSLog("PERVIO_SMOKE save: alert shown=%d", shown ? 1 : 0)
        XCTAssertTrue(shown, "Save should confirm with the saved alert")
        if let ok = firstHittable(alert.buttons["OK"], app.buttons["OK"]) { ok.tap() }
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        NSLog("PERVIO_SMOKE save: after=%@", after.description)
        let added = after.subtracting(before)
        XCTAssertEqual(added.count, 1, "exactly one new template file of mine on the server; before=\(before) after=\(after)")
        if let file = added.first, let data = FileManager.default.contents(atPath: home + "/.pervio/templates/" + file),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            XCTAssertEqual(obj["name"] as? String, "GitHub 热点日报", "the file carries the draft's name")
            XCTAssertNotNil(obj["spec"], "and its spec")
        } else {
            XCTFail("the new template file is not readable JSON")
        }
    }

    // MARK: - Probe 3: the workflows page and the editor's top bar (screenshots from the host, 2026-10-20)
    func testWorkflowEditorProbe() throws {
        guard ProcessInfo.processInfo.environment["PERVIO_E2E_PROBE"] != nil else { throw XCTSkip("probe only") }
        let cfg = try requireEnv(Env.config)
        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(cfg)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30), "\(dump(app))")
        if let wf = firstHittable(app.buttons["工作流"], app.staticTexts["工作流"], app.buttons["Workflows"], app.staticTexts["Workflows"]) {
            wf.tap(); sleep(6)                                                                            // 1: the workflows page
        }
        if let new = firstHittable(app.buttons["New workflow"], app.staticTexts["New workflow"]) {
            new.tap(); sleep(6)                                                                           // 2: the editor (… / Edit / Run)
        }
        if let more = firstHittable(app.buttons["wf-more"], app.buttons["More"]) {
            more.tap(); sleep(4)                                                                          // 3: the … menu (Save as server template)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap(); sleep(2)
        }
        let daily = app.switches["Run daily on the server"].firstMatch
        if daily.waitForExistence(timeout: 5) {
            daily.tap(); sleep(5)                                                                         // 4: Run daily on → "Save" replaces "Run"
        }
        NSLog("PERVIO_PROBE editor bar: %@", app.navigationBars.firstMatch.debugDescription)
    }

    // MARK: - Probe 3b: a VALID workflow (seeded from the market) — does the bar show Edit / Run, then Save when daily is on?
    func testWorkflowEditorValidProbe() throws {
        guard ProcessInfo.processInfo.environment["PERVIO_E2E_PROBE"] != nil else { throw XCTSkip("probe only") }
        let cfg = try requireEnv(Env.config)
        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(cfg)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30), "\(dump(app))")
        navigateHomeToMarket(app); sleep(6)                                                               // 1: the market
        // A publication's detail page, then its "Customize…" link → the editor
        // seeded with that (valid) workflow.
        if let row = firstHittable(app.staticTexts["GitHub 热点日报"], app.buttons["GitHub 热点日报"]) { row.tap(); sleep(5) }   // 2: detail
        if let custom = firstHittable(app.buttons["Customize…"], app.buttons["自定义…"], app.buttons["Customize"], app.buttons["自定义"],
                                      app.staticTexts["Customize…"], app.staticTexts["自定义…"]) {
            custom.tap(); sleep(6)                                                                        // 3: the editor, valid workflow
        }
        NSLog("PERVIO_PROBE bar buttons: %@", app.navigationBars.firstMatch.buttons.allElementsBoundByIndex.map { $0.label }.description)
        NSLog("PERVIO_PROBE all buttons with Run/Save/Edit: %@", app.buttons.allElementsBoundByIndex.map { $0.label }.filter { ["Run", "Save", "Edit", "More"].contains($0) }.description)
        let daily = app.switches.firstMatch
        if daily.waitForExistence(timeout: 5) {
            daily.tap(); sleep(5)                                                                         // 3: daily on → Save?
            NSLog("PERVIO_PROBE bar buttons (daily on): %@", app.navigationBars.firstMatch.buttons.allElementsBoundByIndex.map { $0.label }.description)
        }
    }

    // MARK: - Probe 2: the Context panel, a rename alert, and the text-size setting (screenshots from the host)
    func testPanelsProbe() throws {
        guard ProcessInfo.processInfo.environment["PERVIO_E2E_PROBE"] != nil else { throw XCTSkip("probe only") }
        let cfg = try requireEnv(Env.config)
        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(cfg)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30), "\(dump(app))")
        _ = try openSeededConversation(app)
        // the + menu → Context… → the project → its layer with ticks
        if let plus = firstHittable(app.buttons["composer-plus"]) { plus.tap(); sleep(2) }
        if let ctx = firstHittable(menuItem(app, "Context"), menuItem(app, "背景")) { ctx.tap(); sleep(5) }      // 1: Context panel
        let proj = app.staticTexts["e2eproj"].firstMatch
        if proj.waitForExistence(timeout: 10) { proj.tap(); sleep(6) }                                  // 2: the project layer (ticks)
        // Back to the sheet's root (its Cancel lives there), then Cancel. Tapping
        // the chat behind a half-height sheet just drops the sheet.
        if let back = lowestBarBack(app) { back.tap(); sleep(2) }
        if let cancel = firstHittable(app.buttons["Cancel"], app.buttons["取消"]) { cancel.tap(); sleep(2) }
        // the title menu → rename
        if let badge = firstHittable(app.buttons["engine-badge"]) { badge.tap(); sleep(2) }
        if let rename = firstHittable(menuItem(app, "Rename"), menuItem(app, "重命名")) { rename.tap(); sleep(5) }   // 3: rename alert
        if let cancel = firstHittable(app.buttons["Cancel"], app.buttons["取消"]) { cancel.tap(); sleep(1) }
        for _ in 0..<3 { if let back = firstHittable(app.buttons.matching(identifier: "bar-back").firstMatch) { back.tap(); sleep(2) } }
        // Settings → text size: large, then look at home and the chat
        if let gear = firstHittable(app.buttons["Settings"], app.buttons["gearshape"]) { gear.tap(); sleep(3) }
        let sizes = app.segmentedControls.firstMatch
        NSLog("PERVIO_PROBE size picker: %@", sizes.exists ? sizes.debugDescription : "no segmented control")
        if let large = firstHittable(sizes.buttons["Large"], sizes.buttons["大"], app.buttons["Large"], app.buttons["大"]) {
            large.tap(); sleep(4)                                                                         // 4: settings, large
        } else if sizes.exists, sizes.buttons.count >= 4 {
            sizes.buttons.element(boundBy: 3).tap(); sleep(4)
        }
        NSLog("PERVIO_PROBE size picker after: %@", sizes.exists ? sizes.debugDescription : "gone")
        if let done = firstHittable(app.buttons["Done"], app.buttons["完成"]) { done.tap(); sleep(5) }            // 5: home, large
        _ = try? openSeededConversation(app); sleep(8)                                                       // 6: chat, large
    }

    /// Probe: does Settings → Large actually move text on the real screen, live
    /// and after a relaunch? Numbers in the log (PERVIO_PROBE …).
    func testTextSizeProbe() throws {
        guard ProcessInfo.processInfo.environment["PERVIO_E2E_PROBE"] != nil else { throw XCTSkip("probe only") }
        let cfg = try requireEnv(Env.config)
        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(cfg)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30), "\(dump(app))")
        func greeting() -> CGRect {
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Good")).firstMatch.frame
        }
        func recent() -> CGRect { app.staticTexts["Recent"].firstMatch.frame }
        sleep(2)
        let g0 = greeting(), r0 = recent()
        NSLog("PERVIO_PROBE home before: greeting %@ recent %@", NSCoder.string(for: g0), NSCoder.string(for: r0))
        guard let gear = firstHittable(app.buttons["Settings"], app.buttons["gearshape"]) else { XCTFail("no gear"); return }
        gear.tap(); sleep(3)
        let lang = app.staticTexts["App language"].firstMatch
        NSLog("PERVIO_PROBE sheet before: App language %@", NSCoder.string(for: lang.frame))
        let sizes = app.segmentedControls.firstMatch
        guard let large = firstHittable(sizes.buttons["Large"], sizes.buttons["大"]) else { XCTFail("no Large"); return }
        large.tap(); sleep(4)
        NSLog("PERVIO_PROBE sheet after Large: App language %@ picker %@", NSCoder.string(for: lang.frame), NSCoder.string(for: sizes.frame))
        if let done = firstHittable(app.buttons["Done"], app.buttons["完成"]) { done.tap(); sleep(4) }
        NSLog("PERVIO_PROBE home after: greeting %@ recent %@", NSCoder.string(for: greeting()), NSCoder.string(for: recent()))
        app.terminate()
        app.launchArguments = ["--pervio-uitest-config=\(cfg)"]
        app.launch()
        dismissSystemPrompt()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30), "\(dump(app))")
        sleep(3)
        NSLog("PERVIO_PROBE home after relaunch: greeting %@ recent %@", NSCoder.string(for: greeting()), NSCoder.string(for: recent()))
        // And the other way: small.
        if let gear = firstHittable(app.buttons["Settings"], app.buttons["gearshape"]) { gear.tap(); sleep(3) }
        let sizes2 = app.segmentedControls.firstMatch
        if let small = firstHittable(sizes2.buttons["Small"], sizes2.buttons["小"]) { small.tap(); sleep(4) }
        NSLog("PERVIO_PROBE sheet after Small: App language %@", NSCoder.string(for: app.staticTexts["App language"].firstMatch.frame))
        if let done = firstHittable(app.buttons["Done"], app.buttons["完成"]) { done.tap(); sleep(4) }
        NSLog("PERVIO_PROBE home after Small: greeting %@ recent %@", NSCoder.string(for: greeting()), NSCoder.string(for: recent()))
        sleep(4)
    }

    /// Home → server → project → the seeded 30-turn conversation → its composer.
    private func openSeededConversation(_ app: XCUIApplication) throws -> XCUIElement {
        guard let footer = firstHittable(homeServerLine(app)) else {
            XCTFail("The home page shows no servers footer. \(dump(app))")
            throw XCTSkip("no servers footer")   // unreachable
        }
        footer.tap()
        let project = app.staticTexts["e2eproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 60),
                      "The seeded project never listed. \(dump(app))")
        project.tap()
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "e2e long history")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30),
                      "The seeded long conversation is not listed. \(dump(app))")
        row.tap()
        return try waitForComposer(app)
    }

    private func assertReplyDoesNotMoveReader(_ app: XCUIApplication, composer: XCUIElement,
                                              nonce: String, phase: String) throws {
        composer.tap()
        composer.typeText("slow " + nonce)
        try sendButton(app).tap()
        // Your own words come into view by design; now go read the history.
        for _ in 0..<5 { app.swipeDown() }
        // Seed rows render through a UITextView (value) or a Text (label).
        let seedRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "seed user", "seed user"))
            .allElementsBoundByIndex
        guard let anchorRow = seedRows.first(where: { $0.isHittable }) else {
            XCTFail("After scrolling up, no seed row is on screen (\(phase)). \(dump(app))")
            throw XCTSkip("no anchor row")   // unreachable
        }
        let key = anchorRow.label.isEmpty ? ((anchorRow.value as? String) ?? "") : anchorRow.label
        let before = anchorRow.frame
        // Precondition: the reply must not have landed yet, or this measures
        // nothing (typing, five swipes and the row map below take XCUITest
        // ~20 s; the sandbox agent waits 40 s on a "slow …" prompt).
        guard !echo(app, "slow " + nonce).exists else {
            throw XCTSkip("the sandbox answered before the test finished scrolling up (\(phase)) — raise the slow delay in setup.sh")
        }
        let edgesBefore = edges(app)
        let rowsBefore = rowMap(app)
        guard !echo(app, "slow " + nonce).exists else {
            throw XCTSkip("the sandbox answered while the row map was being taken (\(phase)) — raise the slow delay in setup.sh")
        }

        // The reply lands (~20 s after the send).
        XCTAssertTrue(echo(app, "slow " + nonce).waitForExistence(timeout: replyTimeout),
                      "No reply to the slow message (\(phase)). \(dump(app))")
        sleep(3)   // any reload / scroll the landing triggers has to have happened by now
        let after = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ OR value == %@", key, key)).firstMatch
        XCTAssertTrue(after.exists && after.isHittable,
                      "The row you were reading is no longer on screen after the reply landed (\(phase)) "
                      + "— the transcript jumped. Row '\(key.prefix(14))' was at y=\(px(before.minY)), now "
                      + "\(after.exists ? "y=\(px(after.frame.minY))" : "gone"). \(whereIsTheTranscript(app))")
        XCTAssertEqual(after.frame.minY, before.minY, accuracy: 3,
                       "The row you were reading moved by \(px(after.frame.minY - before.minY))pt when the reply landed (\(phase)). "
                       + "Edges before: \(edgesBefore); after: \(edges(app)). \(whereIsTheTranscript(app)) "
                       + "ROWS before: \(rowsBefore) ROWS after: \(rowMap(app))")
        let pill = firstHittable(app.buttons["New below"], app.buttons["新内容"],
                                 app.staticTexts["New below"], app.staticTexts["新内容"])
        XCTAssertNotNil(pill, "No 'new below' pill after a reply landed below the reader (\(phase)). \(dump(app))")
        pill?.tap()   // back to the end for the next phase
    }

    // MARK: - Flow 2: connect → open the digest → tap 👍 (REAL sandbox)

    /// The morning-report loop, end to end: open the seeded publication's latest
    /// issue in the reader and tap one rating button, whose long-press menu the
    /// report's `actions` spec hangs off an arXiv line. NEEDS the sandbox — a
    /// real report has to be on the server for the reader to render and for the
    /// 👍 to have something to write back to.
    ///
    /// Deliberately tolerant about WHERE the digest is reached from (home card or
    /// the server's publications list) and about the exact rating glyph, because
    /// this is a smoke test of "the report renders and its action fires", not a
    /// pixel contract — that is what the snapshot suite is for.
    func testOpenDigestAndRateOnePaper() throws {
        let cfg = try requireEnv(Env.config)
        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset", "--pervio-uitest-config=\(cfg)"]
        app.launch()
        dismissSystemPrompt()

        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30),
                      "Injected profile never appeared — the launch-argument seam did not run. \(dump(app))")

        // The home strip for a publication carries the read cue — "阅读 →" under
        // the shipped Chinese default, "Read →" in English. If the sandbox
        // seeded no publication, skip rather than fail — the loop this covers
        // only exists when a report does.
        let readCue = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "阅读 →", "Read →")
        ).firstMatch
        guard readCue.waitForExistence(timeout: 60) else {
            throw XCTSkip("No publication strip on the home screen — the sandbox seeded no "
                          + "archived report, so there is no digest to open. \(dump(app))")
        }
        readCue.tap()

        // The reader renders the issue as rich text; wait for ANY substantial
        // body to appear (the masthead "论文晨报" is in every issue).
        let masthead = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "论文晨报", "论文晨报")
        ).firstMatch
        XCTAssertTrue(masthead.waitForExistence(timeout: 30),
                      "The reader never rendered the issue body. \(dump(app))")

        // The rating action is a menu at the end of an arXiv line. Its trigger is
        // an image/button carrying the report's action glyph; match broadly and
        // require SOMETHING tappable to exist, then tap the first rating control.
        // A report always ships 👍/👎/多看/少看, exposed as a menu button.
        let ratingButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS[c] %@",
                        "👍", "hand.thumbsup", "thumbsup")
        ).firstMatch
        guard ratingButton.waitForExistence(timeout: 15) else {
            throw XCTSkip("This issue exposed no rating control to tap — the report's `actions` "
                          + "menu did not surface a 👍 button in the tree. \(dump(app))")
        }
        ratingButton.tap()
        // A successful write toasts; a failure alerts. Either proves the tap was
        // wired to the server round-trip (the point of the flow), so we only
        // require that the tap did not crash and the reader is still up.
        XCTAssertTrue(masthead.exists || app.staticTexts["论文晨报"].waitForExistence(timeout: 10),
                      "The reader disappeared after tapping a rating — the action tap crashed "
                      + "or navigated away unexpectedly. \(dump(app))")
    }

    // MARK: - Flow 3: new profile → add a hop → cancel (BARE simulator)

    /// The route editor's core gesture, no server needed: open the New-Server
    /// sheet, add a hop, confirm a hop row appeared, then Cancel and confirm the
    /// sheet closed without saving. Uses a SYNTHETIC config so the home screen
    /// has a seeded server (the reset+config seam), but never dials anything.
    func testNewProfileAddHopThenCancel() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset",
                               "--pervio-uitest-config=\(Self.syntheticConfigB64)"]
        app.launch()
        dismissSystemPrompt()

        // Adding a server moved OFF the entry page: its '+' now lives only in
        // ServersListView, reached by the footer's trailing "Servers" word (the
        // right tap zone). Open that list, then its '+', which is the same
        // ProfileEditView(ServerProfile()) the home page used to present.
        openServersList(app)
        // The '+' now carries a spoken name as well as its symbol identifier
        // (`.accessibilityLabel(L.addServer())`), so match EITHER: the symbol
        // "plus" the element still reports, or the localized label under whichever
        // language the sim happens to be in. Last resort, the nav bar's trailing
        // button — the only one on this page.
        guard let add = firstHittable(app.buttons["plus"],
                                      app.buttons["添加服务器"], app.buttons["Add a server"],
                                      app.navigationBars.buttons.element(
                                        boundBy: max(app.navigationBars.buttons.count - 1, 0)))
        else {
            XCTFail("The servers page shows no '+' to add a server. \(dump(app))")
            throw XCTSkip("no add button")   // unreachable: continueAfterFailure = false
        }
        add.tap()

        // The editor is a Form titled "New Server". Its route section sits BELOW
        // the connection/model fields, so on a phone it starts off-screen — scroll
        // the form down until "Add a hop" (Chinese default: "加一跳") is on screen
        // before reaching for it.
        let addHop = scrollToFirstHittable(app,
                                           app.buttons["加一跳"], app.buttons["Add a hop"],
                                           app.staticTexts["加一跳"], app.staticTexts["Add a hop"])
        guard let addHop else {
            XCTFail("The New-Server editor has no 'Add a hop' control — the route section "
                    + "did not render even after scrolling. \(dump(app))")
            throw XCTSkip("no add-hop")   // unreachable: continueAfterFailure = false
        }
        // A hop row is titled "第 1 跳" / "Hop 1". None before, one after.
        let hopRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "第 1 跳", "Hop 1")
        ).firstMatch
        XCTAssertFalse(hopRow.exists, "A hop row existed before 'Add a hop' was tapped. \(dump(app))")
        addHop.tap()
        XCTAssertTrue(hopRow.waitForExistence(timeout: 10),
                      "Tapping 'Add a hop' added no hop row — the route list did not grow. \(dump(app))")

        // Cancel: the sheet dismisses. We were on ServersListView (titled
        // "服务器" / "Servers") when we opened the '+', so that is where we land —
        // accept either the servers page or the entry page (a pop that overshoots
        // still proves the sheet closed without saving).
        let cancel = firstHittable(app.buttons["Cancel"])
        cancel?.tap()
        XCTAssertTrue(app.navigationBars["服务器"].waitForExistence(timeout: 10)
                      || app.navigationBars["Servers"].waitForExistence(timeout: 10)
                      || app.navigationBars["Pervio"].waitForExistence(timeout: 10)
                      || homeServerLine(app).waitForExistence(timeout: 10),
                      "The editor did not dismiss after Cancel. \(dump(app))")
    }

    // MARK: - Flow 3b: the footer's TWO tap zones (BARE simulator)

    /// The complaint this pins: tapping the server's NAME in the home footer used
    /// to open the management list, so getting to the machine took two taps
    /// through a page nobody asked for. The footer is now two targets — the row
    /// body walks straight into that server (ProjectsView, titled with the
    /// server's name), and ONLY the trailing "服务器 / Servers" word opens the
    /// list. This taps each and reads the nav bar that comes up.
    ///
    /// No sandbox needed: the landing screen's TITLE is drawn before any SSH (the
    /// synthetic config's dead port makes the project list fail underneath, which
    /// is irrelevant — the assertion is about WHICH screen opened, the same
    /// discipline as testHomeNewChatCardOpensAFreshChatAndNotTheBuilder).
    func testHomeFooterNameOpensTheServerAndOnlyTheWordOpensTheList() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset",
                               "--pervio-uitest-config=\(Self.syntheticConfigB64)"]
        app.launch()
        dismissSystemPrompt()

        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30),
                      "Injected profile never appeared in the home footer. \(dump(app))")

        // Zone 1 — the name. Must land on the SERVER, not the list.
        homeServerLine(app).tap()
        XCTAssertTrue(app.navigationBars["E2E Sandbox"].waitForExistence(timeout: 15),
                      "Tapping the footer's server name did not open that server's page. \(dump(app))")
        XCTAssertFalse(app.navigationBars["服务器"].exists || app.navigationBars["Servers"].exists,
                       "Tapping the NAME landed on the servers management list — the two tap "
                       + "zones collapsed back into one. \(dump(app))")

        // Back to the entry page.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 15),
                      "Did not return to the entry page. \(dump(app))")

        // Zone 2 — the trailing word. Must open the list.
        guard let word = firstHittable(app.buttons["服务器"], app.staticTexts["服务器"],
                                       app.buttons["Servers"], app.staticTexts["Servers"]) else {
            XCTFail("The footer shows no trailing Servers word. \(dump(app))")
            throw XCTSkip("no servers word")   // unreachable: continueAfterFailure = false
        }
        word.tap()
        XCTAssertTrue(app.navigationBars["服务器"].waitForExistence(timeout: 15)
                      || app.navigationBars["Servers"].waitForExistence(timeout: 15),
                      "Tapping the footer's 'Servers' word did not open the management list. \(dump(app))")
    }

    /// Open ServersListView from the entry page. With a home server present, the
    /// path is the footer's trailing "服务器" / "Servers" word (the right tap
    /// zone). With NO server yet (first run), the footer isn't drawn — the empty
    /// state's "添加服务器" / "Add a server" button pushes the same list. Try both.
    private func openServersList(_ app: XCUIApplication) {
        _ = firstHittable(homeServerLine(app),
                          app.buttons["添加服务器"], app.buttons["Add a server"])
        if let entry = firstHittable(app.buttons["服务器"], app.staticTexts["服务器"],
                                     app.buttons["Servers"], app.staticTexts["Servers"],
                                     app.buttons["添加服务器"], app.buttons["Add a server"],
                                     app.staticTexts["添加服务器"], app.staticTexts["Add a server"]) {
            entry.tap()
        }
    }

    // MARK: - Flow 4: market → the catalog's action verbs (BARE simulator)

    /// The PUBLICATIONS shelf is server-fed BY DESIGN since 4ac40b3: the
    /// bundled paper digest was a fossil (its frozen Swift copy re-printed a
    /// months-old pipeline), so publications now come only from the server's
    /// ~/.pervio/templates — which ServerProvisioner seeds on first pave. On a
    /// bare sim that shelf is honestly empty; what MUST render serverless is
    /// the bundled capability catalog with its action verbs.
    func testMarketShowsInstallableCatalog() throws {
        let app = launchAtMarket()
        let action = firstHittable(
            app.buttons["安装到服务器"], app.buttons["Install on server"],
            app.buttons["运行…"], app.buttons["Run…"],
            app.staticTexts["安装到服务器"], app.staticTexts["Install on server"])
        XCTAssertNotNil(action,
                        "The market showed no 安装/Install (or 运行/Run) control on any bundled "
                        + "capability row — the catalog did not render its actions. \(dump(app))")
    }

    // MARK: - Settings → the privacy policy is one tap away

    /// App Review 5.1.1(i): the privacy policy has to be reachable from inside
    /// the app. BARE simulator. The row is a link out to the browser, so it is
    /// looked for and never tapped — a tap would leave the app for Safari.
    func testSettingsOffersThePrivacyPolicy() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset",
                               "--pervio-uitest-config=\(Self.syntheticConfigB64)"]
        app.launch()
        dismissSystemPrompt()

        firstHittable(app.buttons["gearshape"], app.navigationBars.buttons.firstMatch)?.tap()
        let row = app.descendants(matching: .any)["settings-privacy"]
        // It is the last row; on a short screen a List builds it only once it
        // scrolls into view.
        if !row.waitForExistence(timeout: 6) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 4),
                      "Settings shows no privacy policy row\n" + dump(app))
        let label = row.label
        XCTAssertTrue(label.contains("Privacy Policy") || label.contains("隐私政策"),
                      "the row reads \(label)")
    }

    // MARK: - Flow 5: settings → switch to 中文 → the market's buttons are Chinese

    /// The language switch, observed on real chrome: the shipped default is
    /// English (2026-09-01), so the observable flip is Settings → 中文, then
    /// the market's install verb must read 安装到服务器 (and the English verb
    /// must be gone). BARE simulator — the bundled catalog is enough, and this
    /// is the whole point of the one-toggle-drives-the-UI contract.
    func testSwitchToChineseMakesMarketButtonsChinese() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset",
                               "--pervio-uitest-config=\(Self.syntheticConfigB64)"]
        app.launch()
        dismissSystemPrompt()

        // Settings lives behind the gear (top-leading).
        let gear = firstHittable(app.buttons["gearshape"], app.navigationBars.buttons.firstMatch)
        gear?.tap()
        // The picker is a `Picker(…).pickerStyle(.menu)` — it surfaces as a BUTTON
        // whose label is the field name PLUS its current value ("App 语言, 中文"),
        // so an EXACT "App 语言" match misses and the button is the tap target, not
        // the inner static text. Match by CONTAINS on the button.
        let picker = firstHittable(
            app.buttons.matching(NSPredicate(format:
                "label CONTAINS %@ OR label CONTAINS %@", "App 语言", "App language")).firstMatch,
            app.buttons["App 语言"], app.buttons["App language"])
        picker?.tap()
        // The menu items are Buttons in a popover; give the menu a beat to open.
        let chinese = firstHittable(app.buttons["中文"], app.staticTexts["中文"])
        chinese?.tap()
        // Close Settings (完成 / Done — now Chinese).
        firstHittable(app.buttons["完成"], app.buttons["Done"])?.tap()

        // Now the market's install verb must be Chinese. Capture the verdicts
        // BEFORE asserting so the language can be restored even on a red (this test
        // has continueAfterFailure = false).
        navigateHomeToMarket(app)
        let englishVerbGone = firstHittable(app.buttons["Install on server"],
                                            app.staticTexts["Install on server"]) == nil
        let installZH = firstHittable(app.buttons["安装到服务器"], app.staticTexts["安装到服务器"],
                                      app.buttons["运行…"], app.staticTexts["运行…"])
        let treeOnFailure = (installZH == nil || !englishVerbGone) ? dump(app) : ""

        // Restore the shipped default (English) through the same UI. The language
        // lives in the app's shared UserDefaults, which the PervioTests unit host
        // reads on the SAME simulator. `--pervio-uitest-reset` clears it at the
        // next smoke launch (since 2026-11-22), and the unit suites pin their own
        // language — but a stray "zh" left here would still belie the shipped
        // state for whatever opens the app next. Best-effort, so it can't itself fail.
        restoreAppLanguageToEnglish(app)

        XCTAssertNotNil(installZH,
                        "After switching to 中文, the market's install verb is not Chinese "
                        + "— the app-language toggle did not reach the market chrome. \(treeOnFailure)")
        XCTAssertTrue(englishVerbGone,
                      "An English install verb is still showing under 中文. \(treeOnFailure)")
    }

    /// Flip the app language back to English via Settings, so this test leaves
    /// the shared simulator defaults in the shipped state. Best-effort and
    /// silent: it runs as cleanup, so a miss here must not add a second failure.
    private func restoreAppLanguageToEnglish(_ app: XCUIApplication) {
        // Reach Settings from wherever we are: pop to root first if a back button
        // is showing, then open the gear.
        for _ in 0..<3 {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            if back.exists && back.isHittable,
               (back.label == "Pervio" || back.label.isEmpty == false),
               app.buttons["gearshape"].exists == false {
                back.tap()
            } else { break }
        }
        guard let gear = firstHittable(app.buttons["gearshape"],
                                       app.navigationBars.buttons.firstMatch) else { return }
        gear.tap()
        // The picker button now reads "App 语言, 中文"; match by CONTAINS.
        guard let picker = firstHittable(
            app.buttons.matching(NSPredicate(format:
                "label CONTAINS %@ OR label CONTAINS %@", "App 语言", "App language")).firstMatch)
        else { return }
        picker.tap()
        firstHittable(app.buttons["English"], app.staticTexts["English"])?.tap()
        // Close Settings — the Done button reads "Done" again under English.
        firstHittable(app.buttons["Done"], app.buttons["完成"])?.tap()
    }

    // MARK: - Helpers

    private func requireEnv(_ key: String) throws -> String {
        guard let v = ProcessInfo.processInfo.environment[key], !v.isEmpty else {
            throw XCTSkip("""
                \(key) is not set, so there is no server to smoke-test against. \
                This test is driven by  bash server/tests/e2e_ios/run_smoke.sh  \
                which brings up the hermetic sshd and exports it. Skipping rather \
                than passing: a green here would be a lie.
                """)
        }
        return v
    }

    /// A base64 config the bootstrap accepts but that is never dialed — a bogus
    /// host on a closed port. It exists only to seed ONE home server so the home
    /// screen shows the Workflows quick card and the market is reachable; the
    /// bundled catalog these flows assert on needs no live connection. The
    /// private key is a syntactically-plausible placeholder (never used).
    static let syntheticConfigB64: String = {
        let cfg: [String: Any] = [
            "host": "127.0.0.1", "port": 2, "username": "nobody",
            "privateKey": "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----",
            "pinnedHostKey": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAsynthetic",
            "name": "E2E Sandbox",
        ]
        let data = try! JSONSerialization.data(withJSONObject: cfg)
        return data.base64EncodedString()
    }()

    /// Launch with the synthetic config and navigate home → Workflows → market,
    /// returning the app at the market. Bare-sim path (no SSH needed to render
    /// the market's bundled catalog).
    private func launchAtMarket() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset",
                               "--pervio-uitest-config=\(Self.syntheticConfigB64)"]
        app.launch()
        dismissSystemPrompt()
        navigateHomeToMarket(app)
        return app
    }

    /// Home screen → the "Workflows" quick chip → "Browse the market". Both rows
    /// render before any SSH completes (WorkflowsView shows the market link
    /// immediately; the market shows its bundled catalog), so this needs no
    /// server. `@discardableResult`-style: best-effort, the caller asserts.
    ///
    /// The chip switches language with the rest of the app ("Workflows" under
    /// the shipped English default, "工作流" under Chinese), and BOTH callers
    /// matter: flow 4 runs on the shipped default, flow 5 right after
    /// flipping to 中文.
    private func navigateHomeToMarket(_ app: XCUIApplication) {
        if let workflows = firstHittable(app.buttons["工作流"], app.staticTexts["工作流"],
                                         app.buttons["Workflows"], app.staticTexts["Workflows"]) {
            workflows.tap()
        }
        if let market = firstHittable(app.buttons["Browse the market"],
                                      app.staticTexts["Browse the market"]) {
            market.tap()
        }
    }

    /// The app asks for notification permission on first launch; the system sheet
    /// steals the first taps if it is left standing. Non-fatal when absent (the
    /// permission is remembered after the first run).
    private func dismissSystemPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Don't Allow", "允许", "不允许", "OK"] {
            let button = springboard.buttons[label]
            if button.waitForExistence(timeout: 2) {
                button.tap()
                return
            }
        }
    }

    /// The home screen's own "New chat" chip must open a FRESH chat — not Build.
    ///
    /// Regression pin for the multi-link List row: sibling NavigationLinks in one
    /// row collapse into a single activation and the LAST one (Build) wins, so
    /// tapping "New chat" landed in the workflow builder with its prompt already
    /// typed (measured 2026-08-07). The fix made them Buttons that append to an
    /// explicit NavigationPath, and the redesign's chip row keeps that idiom.
    /// This taps the real chip and fails if the composer arrives pre-filled —
    /// i.e. if the row ever collapses again.
    ///
    /// No SSH turn is needed: the assertion is about WHICH screen opened.
    func testHomeNewChatCardOpensAFreshChatAndNotTheBuilder() throws {
        let cfg = try requireEnv(Env.config)

        let app = XCUIApplication()
        app.launchArguments = ["--pervio-uitest-reset",
                               "--pervio-uitest-config=\(cfg)"]
        app.launch()
        dismissSystemPrompt()

        XCTAssertTrue(homeServerLine(app).waitForExistence(timeout: 30),
                      "Injected profile never appeared — the launch-argument seam "
                      + "did not run. \(dump(app))")

        // The chip reads "＋ 新对话" by default and "+ New chat" in English (the
        // plus is fullwidth only in the Chinese one).
        guard let card = firstHittable(app.buttons["＋ 新对话"], app.staticTexts["＋ 新对话"],
                                       app.buttons["+ New chat"], app.staticTexts["+ New chat"]) else {
            XCTFail("Home has no 'New chat' chip. \(dump(app))")
            throw XCTSkip("no quick chip")   // unreachable: continueAfterFailure = false
        }
        card.tap()

        let composer = try waitForComposer(app)
        let value = (composer.value as? String) ?? ""
        // An empty SwiftUI TextField reports its placeholder as its value.
        XCTAssertTrue(value.isEmpty || value.hasPrefix("Message"),
                      "The home 'New chat' card opened a composer already holding "
                      + "'\(value.prefix(60))…'. If that is the workflow-builder "
                      + "prompt, the three quick cards collapsed into one link again "
                      + "and the last one (Build) is eating every tap. \(dump(app))")
    }

    /// Open a fresh conversation and return its composer, by the route that
    /// actually works: the servers footer → the server → the seeded project →
    /// "New conversation".
    ///
    /// NOT the home screen's "New chat" chip, and that is a finding, not a
    /// preference. Sibling NavigationLinks inside ONE List row collapse into a
    /// single activation, so the row opens the LAST link. Measured here on
    /// 2026-08-07: XCUITest logged `Tap "New chat" Button` and the screen that
    /// came up was Build — its composer already held WorkflowBuilderPrompt.text
    /// ("你是 Pervio 的 workfl…"). Every row on the route below holds exactly one
    /// link, so each tap goes where its label says.
    ///
    /// The landing is still CHECKED (a fresh chat's composer is empty) — if the
    /// route ever starts lying too, this fails loudly instead of typing into
    /// somebody else's prompt.
    private func openNewChat(_ app: XCUIApplication) throws -> XCUIElement {
        // Since the two-zone footer, tapping the LEFT zone (the server's name +
        // host) drops STRAIGHT into that server's ProjectsView — no servers-list
        // hop. `homeServerLine` matches the name label, which lives in that left
        // button, so this tap lands on projects directly. (Only the trailing
        // "Servers" word opens the management list; that path is exercised by
        // testNewProfileAddHopThenCancel.)
        guard let footer = firstHittable(homeServerLine(app)) else {
            XCTFail("The home page shows no servers footer. \(dump(app))")
            throw XCTSkip("no servers footer")   // unreachable: continueAfterFailure = false
        }
        footer.tap()

        // The project list arrives over SSH — this is the first proof the app can
        // reach the sandbox at all, so give it room and say so when it doesn't.
        let project = app.staticTexts["e2eproj"]
        XCTAssertTrue(project.waitForExistence(timeout: 60),
                      "The seeded project never listed — the app could not run "
                      + "`pervio-sessions projects` on the sandbox. \(dump(app))")
        project.tap()

        guard let fresh = firstHittable(app.staticTexts["New conversation"],
                                        app.buttons["New conversation"]) else {
            XCTFail("No 'New conversation' entry. \(dump(app))")
            throw XCTSkip("no new-conversation row")   // unreachable
        }
        fresh.tap()

        let composer = try waitForComposer(app)
        let value = (composer.value as? String) ?? ""
        // An empty SwiftUI TextField reports its placeholder as the value, so
        // "empty" means empty-or-placeholder.
        XCTAssertTrue(value.isEmpty || value.hasPrefix("Message"),
                      "Landed on a chat whose composer was already filled with "
                      + "'\(value.prefix(40))…' — the tap did not open a fresh "
                      + "conversation. \(dump(app))")
        return composer
    }

    /// The entry page's servers footer, which since the redesign is the only
    /// place the home screen names a server: one line reading
    /// "<name> · <user>@<host>". Matched by CONTAINS on the seeded name, so it
    /// survives the host/user half changing.
    private func homeServerLine(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "E2E Sandbox")
        ).firstMatch
    }

    /// With a sheet up, two bars carry our back glyph (the chat's behind, the
    /// sheet's in front, lower on the screen): the lowest one is the sheet's.
    private func lowestBarBack(_ app: XCUIApplication) -> XCUIElement? {
        let q = app.buttons.matching(identifier: "bar-back")
        _ = q.firstMatch.waitForExistence(timeout: 10)
        return q.allElementsBoundByIndex.filter { $0.exists }.max { $0.frame.minY < $1.frame.minY }
    }

    /// A row of an open menu (the composer's +, the title badge): UIKit lists
    /// menu rows as buttons whose label is the title, so match by a word of it.
    private func menuItem(_ app: XCUIApplication, _ word: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", word)).firstMatch
    }

    private func firstHittable(_ candidates: XCUIElement...) -> XCUIElement? {
        for c in candidates where c.waitForExistence(timeout: 20) && c.isHittable { return c }
        for c in candidates where c.exists { return c }
        return nil
    }

    /// Like `firstHittable`, but for a control that may start below the fold of a
    /// scrolling Form: try as-is, then swipe up a few times, re-checking each
    /// candidate after every swipe. Returns the first hittable (or merely
    /// existing) match, or nil if it never comes into view.
    private func scrollToFirstHittable(_ app: XCUIApplication,
                                       _ candidates: XCUIElement...) -> XCUIElement? {
        func pick() -> XCUIElement? {
            for c in candidates where c.exists && c.isHittable { return c }
            return nil
        }
        // First give the editor a moment to render at all (its first field arrives
        // before the route section), then look without scrolling.
        _ = candidates.first?.waitForExistence(timeout: 10)
        if let hit = pick() { return hit }
        for _ in 0..<6 {
            app.swipeUp()
            if let hit = pick() { return hit }
        }
        // Last resort: exists-but-not-hittable (a caller may still tap it).
        for c in candidates where c.exists { return c }
        return nil
    }

    /// The composer is a `TextField(… , axis: .vertical)` with no identifier, so
    /// match its placeholder first and fall back to "the bottom-most text input
    /// on screen" — which it always is.
    private func waitForComposer(_ app: XCUIApplication) throws -> XCUIElement {
        let byPlaceholder = NSPredicate(format: "placeholderValue BEGINSWITH 'Message' "
                                        + "OR label BEGINSWITH 'Message' "
                                        + "OR value BEGINSWITH 'Message'")
        let field = app.textFields.matching(byPlaceholder).firstMatch
        if field.waitForExistence(timeout: 20) { return field }
        let view = app.textViews.matching(byPlaceholder).firstMatch
        if view.exists { return view }

        _ = app.textFields.firstMatch.waitForExistence(timeout: 10)
        let inputs = (app.textFields.allElementsBoundByIndex + app.textViews.allElementsBoundByIndex)
            .filter { $0.exists }
        if let bottom = inputs.max(by: { $0.frame.maxY < $1.frame.maxY }) { return bottom }

        XCTFail("Composer field not found on the chat screen. \(dump(app))")
        throw XCTSkip("composer missing")   // unreachable: continueAfterFailure = false
    }

    /// The send control is `Image(systemName: "arrow.up.circle.fill")` inside a
    /// Button with no explicit identifier, so match the symbol name the way UIKit
    /// exposes it and fall back to the composer row's trailing button.
    private func sendButton(_ app: XCUIApplication) throws -> XCUIElement {
        let bySymbol = app.buttons.matching(
            NSPredicate(format: "identifier CONTAINS 'arrow.up.circle' "
                        + "OR label CONTAINS[c] 'arrow.up.circle' "
                        + "OR identifier CONTAINS 'moon.circle' "
                        + "OR label CONTAINS[c] 'moon.circle'")
        ).firstMatch
        if bySymbol.waitForExistence(timeout: 10) { return bySymbol }
        // Fallback: the bottom-most button on screen is the composer's send.
        let buttons = app.buttons.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        if let lowest = buttons.max(by: { $0.frame.maxY < $1.frame.maxY }) { return lowest }
        XCTFail("Send button not found. \(dump(app))")
        throw XCTSkip("send button missing")   // unreachable: continueAfterFailure = false
    }

    /// Attach the whole element tree so a failure in CI is diagnosable without a
    /// second run. Truncated — the full tree can be enormous.
    private func dump(_ app: XCUIApplication) -> String {
        let tree = app.debugDescription
        let attachment = XCTAttachment(string: tree)
        attachment.name = "element-tree"
        attachment.lifetime = .keepAlways
        add(attachment)
        return "\n--- element tree (truncated; full copy attached) ---\n"
            + String(tree.prefix(4000))
    }
}

/// A door in front of the sandbox's sshd that a test can shut and open while
/// the app runs: a loopback listener in the test's own process, relaying every
/// connection to the real port. Shut, nothing listens there — what a phone
/// sees of a Mac it cannot reach — and what was connected is cut.
private final class Door {
    let port: UInt16
    private let target: UInt16
    private var listener: NWListener?
    private var open_: [NWConnection] = []
    private let q = DispatchQueue(label: "pervio.uitest.door")

    init(to target: UInt16) throws {
        self.target = target
        // A port nobody listens on: ask the system for one, then let it go.
        let probe = try NWListener(using: .tcp)
        let ready = DispatchSemaphore(value: 0)
        probe.stateUpdateHandler = { state in
            switch state { case .ready, .failed, .cancelled: ready.signal(); default: break }
        }
        probe.newConnectionHandler = { $0.cancel() }
        probe.start(queue: q)
        _ = ready.wait(timeout: .now() + 5)
        guard let p = probe.port?.rawValue, p != 0 else { throw NSError(domain: "Door", code: 1) }
        port = p
        probe.cancel()
        usleep(200_000)
    }

    func open() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { state in
            switch state { case .ready, .failed: ready.signal(); default: break }
        }
        l.newConnectionHandler = { [weak self] inbound in self?.relay(inbound) }
        l.start(queue: q)
        _ = ready.wait(timeout: .now() + 5)
        q.sync { listener = l }
    }

    func shut() {
        q.sync {
            listener?.cancel(); listener = nil
            for c in open_ { c.cancel() }
            open_ = []
        }
        usleep(200_000)
    }

    private func relay(_ inbound: NWConnection) {
        let out = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: target)!, using: .tcp)
        open_ += [inbound, out]
        inbound.start(queue: q); out.start(queue: q)
        pump(inbound, out); pump(out, inbound)
    }

    private func pump(_ from: NWConnection, _ to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            if let data, !data.isEmpty { to.send(content: data, completion: .contentProcessed { _ in }) }
            if done || error != nil { from.cancel(); to.cancel(); return }
            self?.pump(from, to)
        }
    }
}
