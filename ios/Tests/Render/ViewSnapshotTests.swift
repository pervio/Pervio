import XCTest
import SwiftUI
@testable import Pervio

/// The FIRST pixel-level coverage of what the app draws. Until now 301 tests all
/// lived in the logic layer and only two UI smoke tests touched a real screen —
/// so a view could regress in a way no test could see (an agent once "read the
/// code" and wrongly reported the reader toolbar would crowd; it renders
/// icon-only). Each case here renders a real view with injected state and diffs
/// it against a committed baseline PNG, once per app language (the same
/// `pervio.promptLanguage` switch UIStringsTests drives), so a layout change or
/// a string that fails to switch turns red.
///
/// The seams these use are additive and default-off in the app: an injected
/// `WorkflowMarketServerState` (`WorkflowMarketView.init(previewProfile:…)`), a
/// seeded reader body (`ArchiveReaderView(previewContent:)`), and two sheets
/// widened from `private` to `internal`. No product behaviour changes.
///
/// RECORD once, then COMPARE:
///   PERVIO_RECORD_SNAPSHOTS=1 xcodebuild test -only-testing:PervioTests/ViewSnapshotTests …
/// commit ios/Tests/Fixtures/snapshots/*.png, then drop the env var.
@MainActor
final class ViewSnapshotTests: XCTestCase {

    // A phone-width canvas; heights are per case so a row isn't padded with a
    // screenful of background it doesn't fill.
    private let width: CGFloat = 390

    // MARK: - Codex mode picker: the Codex app's four modes, Ask among them (2026-10-18)

    func testCodexModePicker() {
        for lang in [PromptLanguage.chinese, .english] {
            SnapshotLang.withLanguage(lang) {
                var profile = SnapshotFixtures.profile()
                profile.backend = .codex
                CodexSandboxOption.all[2].apply(to: &profile)      // Ask for approval ticked
                // A plain stack, not a List: the renderer draws UIKit-backed
                // containers as the yellow "unsupported" placeholder.
                let view = VStack(alignment: .leading, spacing: 14) {
                    Text("MODE").font(.caption).foregroundStyle(.secondary)
                    CodexModeRows(profile: .constant(profile))
                }
                .padding(16)
                .frame(width: width, height: 420, alignment: .top)
                Snapshot.verify(view, size: CGSize(width: width, height: 420),
                                named: "snap-codex-modes-\(lang.rawValue)")
            }
        }
    }

    // MARK: - Sub-agents and background tasks: the line, the ended row, the list (2026-11-22)

    func testBackgroundTaskCardAndBar() {
        for lang in [PromptLanguage.chinese, .english] {
            SnapshotLang.withLanguage(lang) {
                let now = Date()
                let t0 = now.addingTimeInterval(-192)
                let running = [
                    BackgroundTask(id: "a1", description: "Review the transfer code for races", startedAt: t0, kind: .agent,
                                   agentType: "general-purpose", tokens: 48_230, toolUses: 17, activity: "Reading ios/Sources/Services/ChatStore.swift"),
                    BackgroundTask(id: "b1", description: "xcodebuild test -only-testing:PervioTests", startedAt: now.addingTimeInterval(-71),
                                   kind: .command, parentId: "a1"),
                    BackgroundTask(id: "a2", description: "Find every caller of uploadFile", startedAt: now.addingTimeInterval(-64), kind: .agent,
                                   agentType: "Explore", tokens: 9_871, toolUses: 1, activity: "Searching for uploadFile"),
                    BackgroundTask(id: "b2", description: "Run the test suite (npm test)", startedAt: now.addingTimeInterval(-340), kind: .command),
                ]
                let ended = [
                    BackgroundTaskRecord(id: "a0", description: "Check the docs against the code", duration: 29.5, status: "completed",
                                         kind: .agent, agentType: "general-purpose", tokens: 13_165, toolUses: 6,
                                         summary: "Two sentences in web/docs.html do not match the code: the 8 MB limit and the seven-day cleanup."),
                    BackgroundTaskRecord(id: "b0", description: "Build the app", duration: 340, status: "failed", kind: .command,
                                         summary: "exit code 65"),
                    BackgroundTaskRecord(id: "a9", description: "Draft the release note", duration: 12, status: "stopped", kind: .agent,
                                         agentType: "general-purpose", tokens: 4_100, toolUses: 2),
                ]
                let view = VStack(alignment: .leading, spacing: 14) {
                    BackgroundTaskBar(tasks: running)
                    BackgroundTaskCard(done: ended)
                    // In the sheet the rows sit in a ScrollView, which offers them all
                    // the height they ask for; a fixed canvas squeezes a wrapping
                    // line to one instead — so here they are given the same offer.
                    BackgroundTaskRows(tasks: running, done: ended, now: now)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(width: width, height: 880, alignment: .top)
                .background(Palette.bg)
                Snapshot.verify(view, size: CGSize(width: width, height: 880),
                                named: "snap-background-card-\(lang.rawValue)")
                // Where one task can be stopped on its own (a living Claude run):
                // a stop key on each running row, and "stopping" on the one asked.
                let stoppable = BackgroundTaskRows(tasks: running, done: [], now: now, stopping: ["a2"], onStop: { _ in })
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(16)
                    .frame(width: width, height: 420, alignment: .top)
                    .background(Palette.bg)
                Snapshot.verify(stoppable, size: CGSize(width: width, height: 420),
                                named: "snap-background-stop-\(lang.rawValue)")
            }
        }
    }

    // MARK: - The one way a page says the Mac is not answering (2026-11-22)

    /// Orange, with "trying again by itself" and the checkup, when it cannot
    /// be reached; red, with the way to the server's settings and no
    /// retrying, when it refused.
    func testMacProblemRow() {
        for lang in [PromptLanguage.chinese, .english] {
            SnapshotLang.withLanguage(lang) {
                var profile = ServerProfile()
                profile.name = "Mac mini"; profile.host = "mac-mini.local"; profile.username = "me"
                let view = VStack(alignment: .leading, spacing: 22) {
                    MacProblemRow(problem: .unreachable(L.connErrPortClosed(profile.host, 22)), retrying: true,
                                  profile: profile, secret: "s")
                    MacProblemRow(problem: .refused(L.connErrAuthRejected(profile.host, profile.username)), retrying: false,
                                  profile: profile, secret: "s")
                }
                .environmentObject(AppStore())
                .padding(16)
                .frame(width: width, height: 330, alignment: .top)
                .background(Palette.bg)
                Snapshot.verify(view, size: CGSize(width: width, height: 330),
                                named: "snap-mac-problem-\(lang.rawValue)")
            }
        }
    }

    // MARK: - Codex Fast switch + the Context rows' engine marks (2026-10-19)

    func testCodexFastRowAndDocMarks() {
        let paper = #"{"v":1,"chat":{"codex":[{"id":"gpt-6.1-sol","note":"GPT-6.1-Sol · the config default","fast":{"id":"priority","name":"Fast","description":"2x speed, increased usage"}}],"codexServiceTier":"priority","codexDefaultModel":"gpt-6.1-sol"}}"#
        _ = ModelMenuStore.shared.apply(Data(paper.utf8), persist: false)
        for lang in [PromptLanguage.chinese, .english] {
            SnapshotLang.withLanguage(lang) {
                var profile = SnapshotFixtures.profile()
                profile.backend = .codex
                let view = VStack(alignment: .leading, spacing: 14) {
                    Text("SPEED").font(.caption).foregroundStyle(.secondary)
                    CodexSpeedRow(profile: .constant(profile), showsSwitch: false)
                    Divider()
                    Text("NOTES").font(.caption).foregroundStyle(.secondary)
                    ForEach([("CLAUDE.md", "claude-md"), ("AGENTS.md", "agents-md"), (".cursor/rules", "cursor-rules"), ("MEMORY.md", "memory")], id: \.0) { name, kind in
                        HStack(spacing: 6) {
                            Text(name).font(.subheadline)
                            DocEngineMarks(kind: kind)
                        }
                    }
                }
                .padding(16)
                .frame(width: width, height: 360, alignment: .top)
                Snapshot.verify(view, size: CGSize(width: width, height: 360),
                                named: "snap-codex-fast-docmarks-\(lang.rawValue)")
            }
        }
    }

    // MARK: - Market row, each state (subscribe / subscribed / name-conflict /
    //         name-it-first / subscribing), Chinese + English

    func testMarketRow_subscribe() { marketRow(.subscribe, "snap-market-row-subscribe") }
    func testMarketRow_subscribed() { marketRow(.subscribed, "snap-market-row-subscribed") }
    func testMarketRow_nameConflict() { marketRow(.nameConflict, "snap-market-row-name-conflict") }
    func testMarketRow_nameFirst() { marketRow(.nameFirst, "snap-market-row-name-first") }
    func testMarketRow_subscribing() { marketRow(.subscribing, "snap-market-row-subscribing") }

    private enum MarketState { case subscribe, subscribed, nameConflict, nameFirst, subscribing }

    /// Build the server state that drives ONE row into `state`, then render the
    /// real `itemRow` (via the preview seam) in both languages.
    private func marketRow(_ state: MarketState, _ name: String) {
        for lang in [PromptLanguage.chinese, .english] {
            SnapshotLang.withLanguage(lang) {
                let profile = SnapshotFixtures.profile()
                let server = WorkflowMarketServerState(profile: profile, secret: "s")
                let item: WorkflowMarketItem

                switch state {
                case .subscribe:
                    // A publication with no matching schedule → live 订阅 button.
                    item = SnapshotFixtures.publicationItem(name: "晨报快讯")
                case .subscribed:
                    // A named publication whose schedule already exists and has
                    // no same-named rival → the button reads 已订阅 (disabled).
                    item = SnapshotFixtures.publicationItem(name: "晨报快讯")
                    server.schedules = [SnapshotFixtures.schedule(named: item.spec.scheduleName)]
                case .nameConflict:
                    // Two subscribable publications share one name → .nameTaken,
                    // so the button shows 名字冲突 and the row prints the note.
                    item = SnapshotFixtures.publicationItem(name: "热点日报")
                    server.templates = [SnapshotFixtures.rivalTemplate(named: "热点日报")]
                    server.schedules = [SnapshotFixtures.schedule(named: item.spec.scheduleName)]
                case .nameFirst:
                    // A NAMELESS publication whose schedule name is the shared
                    // bucket → .unnamedBucket → 先起个名字 + its note.
                    item = SnapshotFixtures.publicationItem(name: "")
                    server.schedules = [SnapshotFixtures.schedule(named: item.spec.scheduleName)]
                case .subscribing:
                    // A tap in flight → the button reads 订阅中… (disabled).
                    item = SnapshotFixtures.publicationItem(name: "晨报快讯")
                    server.busy = [item.id]
                }

                let view = WorkflowMarketView(previewProfile: profile, secret: "s", server: server)
                    .previewRow(item)
                    .frame(width: width)
                    .padding(16)

                Snapshot.verify(view, size: CGSize(width: width, height: 220),
                                named: "\(name)-\(lang.rawValue)")
            }
        }
    }

    // MARK: - Chat composer with the workflow panel open (fork key lit),
    //         Chinese + English

    private func composerTemplate(_ name: String, _ file: String,
                                  _ summary: String) -> ServerTemplate {
        try! JSONDecoder().decode(ServerTemplate.self, from: Data("""
        {"file":"\(file)","name":"\(name)","ok":true,"summary":"\(summary)","mtime":0}
        """.utf8))
    }

    func testChatComposer_withWorkflowPanelOpen() {
        for lang in [PromptLanguage.chinese, .english] {
            SnapshotLang.withLanguage(lang) {
                let view = ChatView(
                    previewComposerProfile: SnapshotFixtures.profile(), secret: "s",
                    templates: [
                        composerTemplate("论文晨报", "paper-digest.json",
                                         "每天 12:30 自动出刊的论文精选"),
                        composerTemplate("GitHub 热点日报", "github-daily.json",
                                         "trending · PH · HN 三板块,按口味裁量"),
                    ])
                    .composerPreviewSlice
                    .frame(width: width)
                Snapshot.verify(view, size: CGSize(width: width, height: 380),
                                named: "snap-chat-composer-\(lang.rawValue)")
            }
        }
    }

    // MARK: - Permission approval sheet (a pervio_schedule create, with verb +
    //         argument rows + the spend warning), Chinese + English

    func testPermissionApprovalSheet() {
        for lang in [PromptLanguage.chinese, .english] {
            SnapshotLang.withLanguage(lang) {
                // A schedule-create call: leads with the "修改订阅 / Edit
                // subscription" verb, breaks the args into plain-words rows
                // (subscription id, action = create, time, days, keep-runs), and
                // shows the orange spend warning — the busiest, most
                // safety-loaded shape the sheet ever draws.
                let call = ToolCall(
                    name: "mcp__perviotools__pervio_schedule",
                    label: "pervio_schedule",
                    mcpInput: [
                        "id": "论文晨报",
                        "action": "create",
                        "time": "06:30",
                        "days": "1,3,5",
                        "keepRuns": "7",
                    ])
                // Render the sheet's `approvalBody` (the inner VStack) directly —
                // NOT `approvalScroll` (a ScrollView, which ImageRenderer draws
                // EMPTY) and NOT its NavigationStack (also unrasterizable). This is
                // the exact content the real sheet shows above its Allow/Deny bar.
                let view = PermissionApprovalSheet(call: call, onAllow: {}, onDeny: { _ in })
                    .approvalBody
                    .frame(width: width, alignment: .top)
                Snapshot.verify(view, size: CGSize(width: width, height: 360),
                                named: "snap-permission-schedule-\(lang.rawValue)")
            }
        }
    }

    /// A template started by NAME: the sheet shows what the Mac says it would
    /// run — every step, the whole shell line, where its result is written —
    /// and, for a workflow the phone cannot read, says so with Allow off
    /// (security review 2026-11-22, #2).
    func testPermissionApprovalSheetForAWorkflow() {
        func b64(_ spec: [String: Any]) -> String {
            try! JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys]).base64EncodedString()
        }
        let resolved = b64([
            "name": "nightly", "dir": "/Users/me/code/shop-api",
            "steps": [
                ["id": "tests", "command": "npm ci && npm test -- --reporter dot && git diff --stat origin/release...HEAD | tail -5"],
                ["id": "review", "backend": "claude", "perm": "plan", "prompt": "…"],
                ["id": "notes", "backend": "claude", "perm": "acceptEdits", "dir": "docs", "prompt": "…", "publish": true],
            ]])
        for lang in [PromptLanguage.chinese, .english] {
            SnapshotLang.withLanguage(lang) {
                var call = ToolCall(name: "mcp__perviotools__pervio_start", label: "pervio_start",
                                    mcpInput: ["template": "nightly"])
                call.shownSpec = resolved
                let shown = PermissionApprovalSheet(call: call, onAllow: {}, onDeny: { _ in })
                Snapshot.verify(shown.approvalBody.frame(width: width, alignment: .top),
                                size: CGSize(width: width, height: 420),
                                named: "snap-permission-workflow-\(lang.rawValue)")
                XCTAssertTrue(shown.canAllow)

                call.shownSpec = "!!! not a workflow !!!"
                let unreadable = PermissionApprovalSheet(call: call, onAllow: {}, onDeny: { _ in })
                Snapshot.verify(unreadable.approvalBody.frame(width: width, alignment: .top),
                                size: CGSize(width: width, height: 230),
                                named: "snap-permission-unreadable-\(lang.rawValue)")
                XCTAssertFalse(unreadable.canAllow)
            }
        }
    }

    // MARK: - Route editor hop list (two hops, the second on its own
    //         credential so it wears the 独立凭据 badge), Chinese + English

    func testRouteEditorHopList() {
        for lang in [PromptLanguage.chinese, .english] {
            SnapshotLang.withLanguage(lang) {
                // Hop 1: pinned, uses the profile's own credential (the common
                // bastion). Hop 2: pinned AND carries its OWN key → the collapsed
                // row shows 已钉 + 独立凭据 side by side.
                var hop1 = JumpHop(); hop1.host = "bastion.example.com"; hop1.port = 22
                hop1.pinnedHostKey = "ssh-ed25519 AAAAC3Nz-hop1"
                var hop2 = JumpHop(); hop2.host = "10.0.0.42"; hop2.port = 2222
                hop2.pinnedHostKey = "ssh-ed25519 AAAAC3Nz-hop2"
                hop2.auth = .privateKey

                // The editor is a whole Form/NavigationStack that ImageRenderer
                // can't rasterize, so render the two collapsed hop rows the
                // editor actually draws (RouteHopSummary — its DisclosureGroup
                // label) stacked as they appear in the 经由 section. This is the
                // two-hops / own-credential-badge contract the task asks for.
                let view = VStack(alignment: .leading, spacing: 14) {
                    Text(L.routeSectionTitle())
                        .font(.caption).foregroundStyle(.secondary)
                    RouteHopSummary(index: 0, hop: hop1)
                    Divider().overlay(Palette.hairline)
                    RouteHopSummary(index: 1, hop: hop2)
                }
                .padding(16)
                .frame(width: width, alignment: .leading)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                .padding(16)

                Snapshot.verify(view, size: CGSize(width: width, height: 200),
                                named: "snap-route-editor-\(lang.rawValue)")
            }
        }
    }

    // MARK: - Reader top bar + a real morning report, Chinese + English
    //
    // The reader's OWN top bar is its `dateBar` (◀ · date · ▶), a plain HStack
    // INSIDE the view — distinct from the nav-bar toolbar (Open on computer /
    // Discuss), which lives in `.toolbar` and (a) can't be rasterized by
    // ImageRenderer and (b) is icon-only anyway. That toolbar is exercised by
    // the XCUITest instead; here we pin the in-content top bar + the real
    // 2026-08-06 issue, seeded through the preview seam (no SSH). Rendered
    // WITHOUT a NavigationStack (which ImageRenderer renders as a placeholder);
    // the `.toolbar`/`.navigationTitle` modifiers are inert here, harmlessly.
    //
    // Two languages: the report BODY is server content that stays Chinese in
    // BOTH — so the pair is byte-identical on purpose, which is itself the
    // contract (the reader must NOT translate a server-authored report).

    func testReaderTopBarWithRealIssue() throws {
        let body = try ReportFixture.markdown("papers-2026-08-06")
        let publication = SnapshotFixtures.publication(name: "论文晨报",
                                                       issue: "2026-08-06")
        for lang in [PromptLanguage.chinese, .english] {
            SnapshotLang.withLanguage(lang) {
                // Render the reader's `reportBody` (the seeded RichMessageText),
                // NOT the whole `ArchiveReaderView`: the reader wraps its body in a
                // ScrollView, which ImageRenderer rasterizes EMPTY, so a snapshot
                // of the whole view shows only the date bar and a blank page. This
                // is the exact report the reader scrolls — the pixels worth pinning
                // (masthead, section headers, arXiv lines). The `dateBar` is a
                // plain HStack the XCUITest exercises live instead.
                let reader = ArchiveReaderView(profile: SnapshotFixtures.profile(), secret: "s",
                                               publication: publication, previewContent: body)
                let view = reader.reportBody
                    .frame(width: width, height: 700, alignment: .top)
                    .clipped()

                Snapshot.verify(view, size: CGSize(width: width, height: 700),
                                named: "snap-reader-\(lang.rawValue)")
            }
        }
    }

    // MARK: - Home publication strip (fresh-today, with a teaser), Chinese + English
    //
    // The redesigned strip is a COMPACT digest row: surface fill with no accent
    // gradient stroke, the issue date as quiet monospaced caption instead of a
    // filled capsule, teaser capped at two lines. Its one word that switches is
    // the read cue (阅读 → / Read →), so the pair is both a layout pin and a
    // language pin; "NEW" is a deliberately language-stable badge.

    func testHomePublicationCard() {
        for lang in [PromptLanguage.chinese, .english] {
            SnapshotLang.withLanguage(lang) {
                let view = HomePublicationCardShell(
                    name: "论文晨报",
                    badge: "2026-08-06",
                    preview: "用“减去对照组”的操作，OCSD 把 GRPO 在 ALFWorld 上的成功率从 73% 拉到 87%，几乎零额外成本。",
                    state: .freshToday)
                    .frame(width: width)
                    .padding(16)

                Snapshot.verify(view, size: CGSize(width: width, height: 200),
                                named: "snap-home-card-\(lang.rawValue)")
            }
        }
    }

    // MARK: - Home running-indicator row (otter + "N 个在跑"), Chinese + English
    //
    // The signal the old entry page had and the redesign lost: work executing on
    // the home server, shown as one quiet line between the paper strip and
    // Recent. The count is the one word that switches (N 个在跑 / N running), so
    // the pair is both a layout pin and a language pin; the otter is the resting
    // pose of the runner mascot. Hidden entirely when nothing runs — this case
    // pins the count = 3 shape.
    //
    // Only the LABEL is pinned here (its look is unchanged by the fix that
    // rewired the row's tap from WorkflowsView to the running-tasks sheet). The
    // tap behaviour — that a counted detached run is actually reachable, not just
    // countable — is a data contract, exercised in HomeRunningRowTests rather
    // than as pixels.

    func testHomeRunningRow() {
        for lang in [PromptLanguage.chinese, .english] {
            SnapshotLang.withLanguage(lang) {
                let view = HomeRunningRowLabel(count: 3)
                    .frame(width: width)
                    .padding(16)

                Snapshot.verify(view, size: CGSize(width: width, height: 80),
                                named: "snap-home-running-\(lang.rawValue)")
            }
        }
    }

    // MARK: - The whole entry page, Chinese + English
    //
    // The redesign's contract in one frame: greeting, the hairline composer with
    // its three chips, the publication strip, the recent threads, and the
    // servers footer — in that order, with every word switching languages.
    //
    // NOT `RootView`: it is a List inside a NavigationStack, and ImageRenderer
    // rasterizes both as EMPTY (the same trap the reader case documents). This
    // renders the real row views the List lays out, stacked in the page's own
    // order — the pixels that carry the design.
    //
    // The composer's field is rendered through its `staticFieldForRender` seam
    // for the same family of reasons: ImageRenderer draws a live TextField as a
    // yellow placeholder box, so the live control would pin noise. The
    // placeholder still comes from the same `L` call it does in the app.
    //
    // DETERMINISM. Two clocks would otherwise rot this baseline: the greeting
    // (time of day + today's date) is pinned through the header's injected
    // `now`/`calendar` plus a UTC environment, and the recent rows' relative
    // times are seeded as fixed OFFSETS from the moment of render (≈5 minutes /
    // 1 hour / 2 hours ago), so they print the same words whenever it runs.

    func testHomePageWholeEntryScreen() {
        // 2026-08-12 14:30 UTC — a Wednesday afternoon, so the greeting is the
        // afternoon one and the date line reads Wednesday, Aug 12.
        let pinnedNow = Date(timeIntervalSince1970: 1_786_545_000)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!

        for lang in [PromptLanguage.chinese, .english] {
            SnapshotLang.withLanguage(lang) {
                let view = VStack(alignment: .leading, spacing: 18) {
                    HomeGreetingHeader(now: pinnedNow, calendar: utc)
                    HomeComposerRow(profile: TestFactory.profile(), secret: "s", path: .constant(NavigationPath()),
                                    staticFieldForRender: true)
                    HomePublicationCardShell(
                        name: "论文晨报",
                        badge: "2026-08-12",
                        preview: "今日一句：检索增强让小模型在长上下文问答上追平了两倍参数的对手。",
                        state: .freshToday)
                    // The running-indicator line, in its natural slot between the
                    // paper strip and Recent — the signal the redesign lost.
                    HomeRunningRowLabel(count: 2)
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L.recentHeader()).font(.caption).foregroundStyle(.secondary)
                        ForEach(SnapshotFixtures.recentItems()) { item in
                            HomeRecentRowLabel(item: item)
                        }
                    }
                    Spacer(minLength: 0)
                    HomeServersLineLabel(profile: SnapshotFixtures.profile())
                }
                .padding(16)
                .frame(width: width, height: 680, alignment: .top)
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)

                Snapshot.verify(view, size: CGSize(width: width, height: 680),
                                named: "snap-home-page-\(lang.rawValue)")
            }
        }
    }

    // MARK: - The home page's folders block (2026-10-17): the folders worked in
    //         most recently, each with its newest chats under it, then the
    //         default folder's own chats — Chinese + English.
    //
    // Same shape as the home-page case: the REAL row labels the List lays out
    // (`HomeProjectRowLabel`, `HomeRecentRowLabel` without the folder caption,
    // indented under their folder), stacked the way `HomeRecentRows` stacks
    // them, so the pixels pinned are the pixels the page draws.
    func testHomeFoldersBlock() {
        for lang in [PromptLanguage.chinese, .english] {
            SnapshotLang.withLanguage(lang) {
                let view = VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L.homeProjectsHeader()).font(.caption).foregroundStyle(.secondary)
                        // The first folder open (its chats + the see-all row), the second closed.
                        ForEach(Array(SnapshotFixtures.homeProjects().enumerated()), id: \.element.id) { i, p in
                            HomeProjectRowLabel(project: p, expanded: i == 0)
                            if i == 0 {
                                ForEach(p.recent) { s in
                                    HomeRecentRowLabel(item: .init(dir: p.path, session: s), showsFolder: false)
                                        .padding(.leading, 32)
                                }
                                HomeSeeAllRowLabel(count: p.sessions)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L.recentHeader()).font(.caption).foregroundStyle(.secondary)
                        ForEach(SnapshotFixtures.recentItems()) { item in
                            HomeRecentRowLabel(item: item, showsFolder: false)
                        }
                    }
                }
                .padding(16)
                .frame(width: width, height: 560, alignment: .top)
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)

                Snapshot.verify(view, size: CGSize(width: width, height: 560),
                                named: "snap-home-folders-\(lang.rawValue)")
            }
        }
    }

    // MARK: - Cursor's engine badge marks the vendor behind the picked model
    //         (2026-10-18): the Cursor icon stays in front, the model name
    //         follows, then the vendor's mark — Anthropic, OpenAI, Google, xAI;
    //         Cursor's own composer and the auto router carry none.
    func testCursorBadgeMarksTheModelsVendor() {
        for lang in [PromptLanguage.chinese, .english] {
            SnapshotLang.withLanguage(lang) {
                let picks = ["claude-opus-5-thinking-high", "gpt-5.3-codex", "gemini-3.7-flash-high", "cursor-grok-4.5-high", "composer-2.5", "auto"]
                let view = VStack(alignment: .leading, spacing: 16) {
                    ForEach(picks, id: \.self) { id in
                        HStack(spacing: 6) {
                            Image(AgentBackend.cursor.iconAsset).resizable().scaledToFit().frame(width: 16, height: 16)
                            Text(id).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if let v = CursorModelVendor.of(id) {
                                VendorMark(preset: v.preset, label: v.label, size: 14)
                            }
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
                .frame(width: width, height: 260, alignment: .topLeading)

                Snapshot.verify(view, size: CGSize(width: width, height: 260),
                                named: "snap-cursor-marks-\(lang.rawValue)")
            }
        }
    }

    // MARK: - The servers page (the ledger the footer's "Servers" word pushes),
    //         Chinese + English
    //
    // The redesign's second surface: no tiles, no cards — three rows of
    // name / user@host:port separated by the app's own hairline, with the home
    // server marked by a WORD (主服务器 / Home) instead of the old gold star.
    // That badge is the one string on the page that switches, so the pair is
    // both a layout pin and a language pin.
    //
    // NOT `ServersListView` itself: it is a List inside the caller's
    // NavigationStack, and ImageRenderer rasterizes both as EMPTY (the trap the
    // reader and home-page cases document). This renders the REAL row label the
    // List lays out (`ServerRowLabel` — literally the NavigationLink's label)
    // stacked with the separator tint the rows carry, so the pixels pinned are
    // the pixels the page draws. The nav bar (inline "服务器" title + the single
    // '+') is chrome ImageRenderer cannot draw; the XCUITest taps that '+'
    // instead.
    func testServersListPage() {
        for lang in [PromptLanguage.chinese, .english] {
            SnapshotLang.withLanguage(lang) {
                let servers = SnapshotFixtures.serverLedger()
                let view = VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(servers.enumerated()), id: \.element.id) { index, profile in
                        ServerRowLabel(profile: profile, isHome: index == 0)
                        if index < servers.count - 1 {
                            Rectangle().fill(Palette.hairline).frame(height: 1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
                .frame(width: width, height: 680, alignment: .top)

                Snapshot.verify(view, size: CGSize(width: width, height: 680),
                                named: "snap-servers-list-\(lang.rawValue)")
            }
        }
    }

    // MARK: - The Dynamic Island, expanded, mid-workflow — Chinese + English
    //
    // The FIRST pixel coverage of the Live Activity. It earns its place because
    // the island is the one surface nobody can look at while developing: it
    // renders in another process, on a device, only while real work is running.
    // Every previous island change was verified by reading the code — the exact
    // habit these snapshots exist to replace.
    //
    // What it pins, top to bottom: the otter's cream tile, the workflow name over
    // its step count, the quiet relative time in the corner (TWO Texts, because
    // concatenating them kills the system's auto-refresh), the trail with four
    // milestones walked and the fifth cell half-filled by the system, and the tool
    // row under it.
    //
    // NOT the widget's `DynamicIsland` itself: those regions only exist inside
    // SpringBoard's own presentation, and WidgetKit cannot be driven from a unit
    // test. `IslandExpandedCard` stacks the three SHIPPED region views the way the
    // island stacks them, so the pixels here are the pixels the card draws; only
    // the black capsule around them is the test's.
    //
    // TWO SOURCES OF DRIFT ARE PINNED DOWN so the baseline is byte-stable:
    //   * the relative text reads from `startedAt`, set 185s back — mid-bucket, so
    //     it says "3 min"/"3分钟" for the next 55 seconds no matter when the suite
    //     runs;
    //   * the filling cell's window is centred on now, so the system draws it at
    //     50% on every run instead of wherever the clock happens to be.
    // The LOCALE, not the app's language switch, is what varies between the pair:
    // the widget runs in its own process and cannot read the app's UserDefaults
    // without an App Group, so the island follows the device — and so must this.
    func testIslandExpanded_workflowInProgress() {
        for (lang, locale, strings) in [
            ("zh", Locale(identifier: "zh_Hans_CN"), IslandStrings.chinese),
            ("en", Locale(identifier: "en_US"), IslandStrings.english),
        ] {
            let now = Date()
            let view = IslandExpandedCard(
                title: lang == "zh" ? "组会周报" : "Weekly report",   // a workflow's name is the person's own words
                subtitle: lang == "zh" ? "4/6 步已完成" : "4/6 steps done",
                step: 4, done: 4, total: 6,
                startedAt: now.addingTimeInterval(-185),
                current: now.addingTimeInterval(-45)...now.addingTimeInterval(45),
                toolGlyph: "doc.text",
                toolLine: "Read · paper_07.pdf",
                strings: strings,
                staticFillForRender: 0.55)
                .environment(\.locale, locale)
                .padding(16)

            Snapshot.verify(view, size: CGSize(width: 392, height: 150),
                            named: "snap-island-expanded-\(lang)")
        }
    }
}

// MARK: - Fixtures for the snapshot cases

/// Deterministic builders for the view state each snapshot needs. Kept separate
/// from `TestFactory` (which is @MainActor-scoped to the logic suites) and named
/// so a case reads as "a publication item called X".
@MainActor
enum SnapshotFixtures {

    static func profile() -> ServerProfile {
        var p = ServerProfile()
        p.name = "prod-1"
        p.host = "10.0.0.9"
        p.username = "deploy"
        p.projectDir = "/srv/app"
        p.pinnedHostKey = "ssh-ed25519 AAAA"
        return p
    }

    /// Three saved servers for the ledger page — the first is the home one (it
    /// wears the 主服务器 / Home word), the other two are an ordinary box and one
    /// on a non-standard port, so the row's `user@host:port` line is pinned in
    /// both its short and its long form.
    static func serverLedger() -> [ServerProfile] {
        func make(_ name: String, _ user: String, _ host: String, _ port: Int) -> ServerProfile {
            var p = ServerProfile()
            p.name = name; p.username = user; p.host = host; p.port = port
            p.projectDir = "/srv/app"
            p.pinnedHostKey = "ssh-ed25519 AAAA"
            return p
        }
        return [
            make("prod-1", "deploy", "10.0.0.9", 22),
            make("MacBook Pro", "me", "192.168.1.24", 22),
            make("build-box", "ci", "build.example.com", 2222),
        ]
    }

    /// A publication market item: one publishing step, so `isPublication` is
    /// true and the 刊物 chip + 订阅 row render. `name` drives its schedule name
    /// ("" → the shared unnamed bucket).
    static func publicationItem(name: String) -> WorkflowMarketItem {
        var step = WorkflowStep(id: "digest", backend: .claude, prompt: "写今天的晨报。")
        step.publishEnabled = true                      // → publishes → 刊物 shelf
        var spec = WorkflowSpec()
        spec.name = name
        spec.dir = "~"
        spec.steps = [step]
        return WorkflowMarketItem(
            id: "snap-pub-" + (name.isEmpty ? "unnamed" : name),
            title: name.isEmpty ? "未命名刊物" : name,
            author: "pervio",
            summary: "每天早上把最值得读的几篇挑出来，印成一页卡片。",
            tags: ["daily"],
            spec: spec,
            suggestedTime: "06:30")
    }

    /// A second server template that publishes under the SAME workflow name —
    /// the rival that turns a subscribe into a name-conflict.
    static func rivalTemplate(named: String) -> ServerTemplate {
        // Build the wrapper JSON the server sends, so the ServerTemplate decodes
        // exactly as a real listing row would (spec included, publishing).
        let json = """
        {"file":"rival.json","name":"\(named)","ok":true,"steps":1,
         "spec":{"name":"\(named)","dir":"~","steps":[
            {"id":"digest","backend":"claude","prompt":"x","publish":true}]}}
        """
        return try! JSONDecoder().decode(ServerTemplate.self, from: Data(json.utf8))
    }

    static func schedule(named: String) -> WorkflowSchedule {
        FakeSSH.scheduleRow(id: "s-\(named)", name: named, time: "06:30")
    }

    /// Three recent threads for the entry page, timed as fixed OFFSETS from now
    /// (not absolute instants) so their relative labels — "5 minutes ago",
    /// "1 hour ago", "2 hours ago" — are the same words on any day the suite
    /// runs. The offsets sit mid-bucket so a few milliseconds of render time
    /// can't tip one across a rounding boundary.
    static func recentItems() -> [HomeRecentModel.Item] {
        let now = Int(Date().timeIntervalSince1970)
        func item(_ id: String, _ preview: String, _ ago: Int,
                  _ backend: AgentBackend, _ dir: String) -> HomeRecentModel.Item {
            HomeRecentModel.Item(
                dir: dir,
                session: SessionSummary(id: id, preview: preview,
                                        modified: now - ago, bytes: 4096,
                                        backend: backend))
        }
        return [
            item("s1", "重构 orchestrator 的合并逻辑", 310, .claude, "/home/you/Pervio"),
            item("s2", "组会周报 已生成", 3_720, .codex, "/home/you/weekly"),
            item("s3", "修 ChatView 滚动 bug", 7_500, .claude, "/home/you/Pervio"),
        ]
    }

    /// Two folders with their newest chats, as `pervio-sessions home` hands them
    /// over; the same mid-bucket offsets as `recentItems` keep the words stable.
    static func homeProjects() -> [HomeProject] {
        let now = Int(Date().timeIntervalSince1970)
        func row(_ id: String, _ preview: String, _ ago: Int, _ backend: AgentBackend) -> SessionSummary {
            SessionSummary(id: id, preview: preview, modified: now - ago, bytes: 4096, backend: backend)
        }
        func project(_ path: String, _ sessions: Int, _ ago: Int, _ recent: [SessionSummary]) -> HomeProject {
            let json = "{\"path\": \"\(path)\", \"sessions\": \(sessions), \"modified\": \(now - ago), \"recent\": []}"
            let bare = try! JSONDecoder().decode(HomeProject.self, from: Data(json.utf8))
            return HomeProject(copy: bare, recent: recent)
        }
        return [
            project("/home/you/Pervio", 13, 310, [row("p1", "修 ChatView 滚动 bug", 310, .claude),
                                                   row("p2", "给终端加字号设置", 3_720, .codex)]),
            project("/home/you/Altas", 2, 7_500, [row("p3", "帮我测试一下 RPM、TPM 以及并发", 7_500, .claude)]),
        ]
    }

    /// A publication with one dated issue, for the reader.
    static func publication(name: String, issue: String) -> ArchivePublication {
        let json = """
        {"name":"\(name)","dir":"~/.pervio/archives/\(name)",
         "files":[{"file":"\(issue).md","mtime":1000}]}
        """
        return try! JSONDecoder().decode(ArchivePublication.self, from: Data(json.utf8))
    }
}
