import XCTest
// Citadel's own error types, constructed directly so the two connect failures
// that normally need a live server can be classified without a socket.
@preconcurrency import Citadel
@testable import Pervio

/// L2: the app's own INTERFACE chrome follows the same Settings language choice
/// (`pervio.promptLanguage`) as the injected prompts — one toggle, no split
/// between "prompts in English, buttons in Chinese". This pins the wire at the
/// seams the views actually call (`UIStrings.L`, and the ObservableObject /
/// enum helpers the market and Workflows list read for their labels), so
/// "switch to English and the market's key labels are English" is measured, not
/// asserted about a resource table.
///
/// Boundary: CHROME only. Market catalog titles/summaries and server-authored
/// template/report bodies stay in their author's language and are NOT covered.
/// The Chinese defaults are pinned byte-for-byte so the shipped behaviour can't
/// drift while the English half is added.
@MainActor
final class UIStringsTests: XCTestCase {

    private let key = "pervio.promptLanguage"
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)   // shipped default: English
    }
    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }
    private func setEnglish() { UserDefaults.standard.set("en", forKey: key) }
    private func setChinese() { UserDefaults.standard.set("zh", forKey: key) }

    /// True when the string still carries CJK ideographs or full-width CJK
    /// punctuation (「」、: etc.) — i.e. it did NOT switch to English.
    private func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)
            || (0x3000...0x303F).contains($0.value)
            || (0xFF00...0xFFEF).contains($0.value)
        }
    }

    // MARK: - Market: the buttons the user pointed at

    func testChinese_marketButtonsStayChineseVerbatim() {
        setChinese()
        XCTAssertEqual(L.subscribe(), "订阅")
        XCTAssertEqual(L.subscribed(), "已订阅")
        XCTAssertEqual(L.subscribing(), "订阅中…")
        XCTAssertEqual(L.install(), "安装到服务器")
        XCTAssertEqual(L.installed(), "已安装")
        XCTAssertEqual(L.run(), "运行…")
        XCTAssertEqual(L.useInChat(), "在对话中用")
        XCTAssertEqual(L.blockedNameConflict(), "名字冲突")
        XCTAssertEqual(L.blockedNameFirst(), "先起个名字")
    }

    func testEnglish_marketButtonsAreEnglish() {
        setEnglish()
        for s in [L.subscribe(), L.subscribed(), L.subscribing(),
                  L.subscribeDaily("06:30"), L.install(), L.installed(),
                  L.installing(), L.run(), L.runNow(), L.useInChat(),
                  L.blockedNameConflict(), L.blockedNameFirst()] {
            XCTAssertFalse(containsCJK(s), "market button still Chinese under English: \(s)")
        }
        // A parameterized label must still carry its value.
        XCTAssertTrue(L.subscribeDaily("06:30").contains("06:30"),
                      "the armed hour must survive the language switch")
    }

    // MARK: - Market: the blocked-subscribe reason the ROW prints

    /// `blockedLabel` is the exact string the row's disabled button shows; it is
    /// a server-state method, so this is the label the view actually renders.
    func testEnglish_blockedLabelIsEnglish() {
        setEnglish()
        // Two nameless rows collide onto the shared bucket → .unnamedBucket.
        let state = WorkflowMarketServerState(profile: nil, secret: "")
        var spec = WorkflowSpec()
        spec.name = ""                       // nameless → the unnamed-bucket dead end
        let item = WorkflowMarketItem.wrapping(spec: spec)
        state.schedules = [scheduleNamed(spec.scheduleName)]
        let label = state.blockedLabel(item)
        XCTAssertNotNil(label, "precondition: a nameless row with a matching bucket is blocked")
        XCTAssertFalse(containsCJK(label ?? ""),
                       "the blocked-subscribe label the row shows is still Chinese: \(label ?? "")")
    }

    /// The sentence UNDER a blocked button (why + the fix) — the "中文说明" the
    /// user saw on the Workflows side actually originates here.
    func testEnglish_subscriptionNoteIsEnglish() {
        setEnglish()
        let state = WorkflowMarketServerState(profile: nil, secret: "")
        var spec = WorkflowSpec()
        spec.name = ""
        let item = WorkflowMarketItem.wrapping(spec: spec)
        state.schedules = [scheduleNamed(spec.scheduleName)]
        let note = state.subscriptionNote(item)
        XCTAssertNotNil(note, "precondition: the blocked row prints an explanation")
        XCTAssertFalse(containsCJK(note ?? ""),
                       "the sentence under the blocked button is still Chinese: \(note ?? "")")
    }

    // MARK: - Market: toasts

    func testEnglish_marketToastsAreEnglish() {
        setEnglish()
        XCTAssertFalse(containsCJK(L.toastAlreadySubscribed()))
        XCTAssertFalse(containsCJK(L.toastInstalled()))
    }
    func testChinese_marketToastsStayChineseVerbatim() {
        setChinese()
        XCTAssertEqual(L.toastAlreadySubscribed(), "已订阅过了,无需重复")
        XCTAssertEqual(L.toastInstalled(), "已安装到服务器模板库")
    }

    // MARK: - Market: shelves + footers + intro

    func testEnglish_marketShelvesAndFootersAreEnglish() {
        setEnglish()
        for s in [L.marketIntro(), L.shelfPublications(), L.shelfCapabilities(),
                  L.publicationFooterNoProfile(), L.publicationFooterProfiled(),
                  L.capabilityFooterNoProfile(), L.capabilityFooterEmpty(),
                  L.capabilityFooterMixed(), L.chipMine(), L.chipPlaybook(),
                  L.charCount(1200), L.buildWithClaudeTitle(),
                  L.buildWithClaudeSubtitle()] {
            XCTAssertFalse(containsCJK(s), "market shelf/footer still Chinese: \(s)")
        }
        XCTAssertTrue(L.charCount(1200).contains("1200"), "the count must survive")
    }

    // MARK: - Market detail: presentation chips + action copy

    func testEnglish_marketDetailCopyIsEnglish() {
        setEnglish()
        for s in [L.chipPublish("~/.pervio/archives/x"), L.chipFold("A, B"),
                  L.chipActions(3), L.subscribeDetailNote("06:30"),
                  L.installDetailNote(), L.customize(), L.customizeNote(),
                  L.customizeTo(), L.changeProjectDir(),
                  L.runSheetEmptyDirFooter(), L.runSheetReadyFooter("prod-1")] {
            XCTAssertFalse(containsCJK(s), "market detail copy still Chinese: \(s)")
        }
        XCTAssertTrue(L.runSheetReadyFooter("prod-1").contains("prod-1"),
                      "the server name must survive the switch")
        XCTAssertTrue(L.subscribeDetailNote("06:30").contains("06:30"))
    }

    // MARK: - Editor: publish section + save-as-template

    func testEnglish_editorPublishAndTemplateCopyIsEnglish() {
        setEnglish()
        for s in [L.publishSectionOffLabel(),
                  L.publishSectionOffFooter(PublicationTarget.root),
                  L.templateMenuHint(), L.templateSavedAlert()] {
            XCTAssertFalse(containsCJK(s), "editor copy still Chinese: \(s)")
        }
        XCTAssertTrue(L.publishSectionOffFooter("~/x").contains("~/x"),
                      "the archive root must survive the switch")
    }

    // MARK: - Schedule first-issue toasts (subscribe + editor Save share these)

    /// The 今天/明天 toasts are produced by `ScheduleFirstIssue.settle` — the
    /// ONE place both the market's 订阅 and the editor's Save print from — so
    /// driving the real enum tests both screens' toast at once. Since
    /// 2026-09-01 settle never fires; 印制中 belongs to the explicit
    /// 现在来一期 verb and is pinned on its L strings directly.
    func testEnglish_firstIssueToastsFromSettleAreEnglish() async {
        setEnglish()
        let ahead = await settleLine(clock: "00:00", time: "00:01")
        XCTAssertFalse(containsCJK(ahead), "'scheduled today' toast still Chinese: \(ahead)")
        XCTAssertTrue(ahead.contains("00:01"), "the armed hour must survive")

        let passed = await settleLine(clock: "23:59", time: "23:59")
        XCTAssertFalse(containsCJK(passed), "'tomorrow' toast still Chinese: \(passed)")
        XCTAssertTrue(passed.contains("23:59"), "the armed hour must survive here too")

        XCTAssertFalse(containsCJK(L.runIssueNow()),
                       "the 来一期 verb still Chinese: \(L.runIssueNow())")
        XCTAssertFalse(containsCJK(L.issuePrinting()),
                       "the printing toast still Chinese: \(L.issuePrinting())")
    }

    func testChinese_firstIssueToastsStayChineseVerbatim() async {
        setChinese()
        let ahead = await settleLine(clock: "00:00", time: "00:01")
        XCTAssertEqual(ahead, "已订阅,首期今天 00:01 自动送达")
        let passed = await settleLine(clock: "23:59", time: "23:59")
        XCTAssertEqual(passed, "已订阅,下期明天 23:59 自动送达")
        XCTAssertEqual(L.runIssueNow(), "现在来一期")
        XCTAssertEqual(L.issuePrinting(), "这一期正在印制 — 稍后见首页卡片")
    }

    // MARK: - Publication badge (one word, many screens)

    /// `PublicationTarget.badge` is read by every 刊物 chip (market, Workflows
    /// list, editor step row) — one source, so the switch reaches all of them.
    func testEnglish_publicationBadgeAndCardAreEnglish() {
        setEnglish()
        XCTAssertFalse(containsCJK(PublicationTarget.badge),
                       "the 刊物 chip word (shared by every screen) is still Chinese: \(PublicationTarget.badge)")
        for s in [L.publicationCardTitle(), L.publicationCardWhere(),
                  L.publicationCardStep("summary")] {
            XCTAssertFalse(containsCJK(s), "publication card copy still Chinese: \(s)")
        }
    }
    func testChinese_publicationBadgeStaysChineseVerbatim() {
        setChinese()
        XCTAssertEqual(PublicationTarget.badge, "刊物")
    }

    // MARK: - Settings picker value names are the language's OWN name (never translated)

    func testDisplayNamesAreAlwaysTheLanguagesOwnName() {
        // Under English, "中文" must still read 中文 (a native name, not "Chinese").
        setEnglish()
        XCTAssertEqual(PromptLanguage.chinese.displayName, "中文")
        XCTAssertEqual(PromptLanguage.english.displayName, "English")
    }

    // MARK: - Workflows list: delete confirmations follow the language

    /// These are read straight off `WorkflowsView.PendingDelete.prompt` — the
    /// exact title + confirm the irreversible dialog shows. Default = Chinese
    /// (the switch now governs the whole UI); English pins the original text.
    func testEnglish_deleteConfirmationsAreEnglish() {
        setEnglish()
        let run = WorkflowsView.PendingDelete.run("wf-1").prompt
        let sub = WorkflowsView.PendingDelete.schedule(id: "s", publishes: true).prompt
        let sch = WorkflowsView.PendingDelete.schedule(id: "s", publishes: false).prompt
        for s in [run.title, run.confirm, sub.title, sub.confirm, sch.title, sch.confirm] {
            XCTAssertFalse(containsCJK(s), "delete confirmation still Chinese under English: \(s)")
        }
        XCTAssertEqual(sub.confirm, "Delete subscription", "the original verb must survive verbatim")
    }

    func testChinese_deleteConfirmationsAreChinese() {
        setChinese()
        // Explicit zh — an absent setting has meant English since 2026-09-01.
        let run = WorkflowsView.PendingDelete.run("wf-1").prompt
        let sub = WorkflowsView.PendingDelete.schedule(id: "s", publishes: true).prompt
        let sch = WorkflowsView.PendingDelete.schedule(id: "s", publishes: false).prompt
        XCTAssertTrue(containsCJK(run.title) && containsCJK(run.confirm),
                      "the delete-run dialog must be Chinese by default")
        XCTAssertTrue(containsCJK(sub.title), "the delete-subscription dialog must be Chinese by default")
        XCTAssertTrue(containsCJK(sch.title), "the delete-schedule dialog must be Chinese by default")
    }

    // MARK: - Group 1: Permission approval sheet (safety-critical)

    func testEnglish_permissionSheetCopyIsEnglish() {
        setEnglish()
        for s in [L.permStartWorkflow(), L.permRerunWorkflow(),
                  L.permEditSubscription(), L.permRecordFeedback(),
                  L.permSpendsQuota(),
                  L.permLabelTemplate(), L.permLabelDir(), L.permLabelSourceRun(),
                  L.permLabelSubscription(), L.permLabelAction(), L.permLabelTime(),
                  L.permLabelDays(), L.permLabelKeepRuns(), L.permLabelStatus(),
                  L.permLabelPaper(), L.permLabelVerdict(), L.permLabelNote(),
                  L.permActionUpdate(), L.permActionPause(), L.permActionResume(),
                  L.permActionDelete(), L.permActionCreate(),
                  L.permStatusEnabled(), L.permStatusPaused(),
                  L.permWeekday(1), L.permWeekday(7),
                  L.permSpecNamed("Digest"), L.permSpecSize(1200)] {
            XCTAssertFalse(containsCJK(s), "permission-sheet copy still Chinese: \(s)")
        }
        // The workflow name and the char count must survive the switch.
        XCTAssertTrue(L.permSpecNamed("Digest").contains("Digest"))
        XCTAssertTrue(L.permSpecSize(1200).contains("1200"))
    }

    /// Safety copy must stay byte-for-byte in the shipped (Chinese) default:
    /// "delete" can never blur into "pause", and the spend warning can't vanish.
    func testChinese_permissionSheetSafetyCopyIsChineseVerbatim() {
        setChinese()
        XCTAssertEqual(L.permStartWorkflow(), "启动工作流")
        XCTAssertEqual(L.permActionDelete(), "删除")
        XCTAssertEqual(L.permActionPause(), "暂停")
        XCTAssertNotEqual(L.permActionDelete(), L.permActionPause(),
                          "delete and pause must never render the same word")
        XCTAssertEqual(L.permSpendsQuota(), "将消耗模型额度")
        XCTAssertEqual(L.permWeekday(1), "周一")
        XCTAssertEqual(L.permWeekday(7), "周日")
    }

    /// The composer's ＋ menu entries and the user-bubble rewind verb. Photo and
    /// File shipped as hardcoded English Labels for weeks — every zh user read
    /// two English words in an otherwise Chinese menu — so ALL four entries are
    /// pinned in both directions now.
    func testEnglish_composerMenuAndRewindAreEnglish() {
        setEnglish()
        for s in [L.attachPhoto(), L.attachFile(), L.attachServerFile(),
                  L.attachContext(), L.restateFromHere()] {
            XCTAssertFalse(containsCJK(s), "composer/rewind copy still Chinese: \(s)")
        }
    }

    func testChinese_composerMenuIsChinese() {
        // The default (key absent) IS Chinese — assert via explicit lang so this
        // never depends on the device defaults the suite runs under.
        XCTAssertEqual(L.attachPhoto(.chinese), "照片")
        XCTAssertEqual(L.attachFile(.chinese), "文件")
        XCTAssertEqual(L.attachServerFile(.chinese), "服务器文件…")
    }

    // MARK: - Group 2: Context picker + server file browser

    func testEnglish_contextPickerCopyIsEnglish() {
        setEnglish()
        for s in [L.contextTitle(), L.browseServerFiles(),
                  L.noConversationsOnServer(), L.contextProjectsFooter(40),
                  L.searchAllProjects(), L.noConversationMentions("foo"),
                  L.contextSearchFooter(40), L.currentConversation(),
                  L.thisProject(), L.sessionCount(3),
                  L.noConversationsInProject(), L.contextSessionFooter(40),
                  L.searchFailed()] {
            XCTAssertFalse(containsCJK(s), "context-picker copy still Chinese: \(s)")
        }
        XCTAssertTrue(L.contextSessionFooter(40).contains("300KB"), "the size cap is what the footer quotes now (the document carries the count and range)")
        XCTAssertTrue(L.noConversationMentions("foo").contains("foo"), "the query must survive")
        XCTAssertTrue(L.sessionCount(3).contains("3"), "the count must survive")
    }

    func testEnglish_serverFileBrowserCopyIsEnglish() {
        setEnglish()
        for s in [L.serverFilesTitle(), L.goUpOneLevel(), L.handOffDirectory(),
                  L.handoffDirFooter(), L.directoryEmpty(), L.onlyHiddenItems(),
                  L.directoryCapped(900), L.showHiddenItems(),
                  L.fileBrowserFooter(), L.directoryReadFailed()] {
            XCTAssertFalse(containsCJK(s), "file-browser copy still Chinese: \(s)")
        }
        XCTAssertTrue(L.directoryCapped(900).contains("900"), "the total must survive")
    }

    // MARK: - Group 3: system bubbles + SSHService errors

    func testEnglish_systemBubblesAreEnglish() {
        setEnglish()
        for s in [L.bubbleNotConnectedContext(),
                  L.bubbleContextEmpty(), L.bubbleContextFailed(),
                  L.bubbleNotConnectedFile(), L.bubbleFileUnparseable(),
                  L.bubbleFileNoPath(), L.bubbleFileReadFailed()] {
            XCTAssertFalse(containsCJK(s), "system bubble still Chinese: \(s)")
        }
    }

    /// `serverFsErrorText` is the exact string the browser rows and attach paths
    /// render, so drive the real switch (every code) — not the L helper directly.
    func testEnglish_serverFsErrorTextIsEnglish() {
        setEnglish()
        for code in ["not-found", "not-dir", "not-file", "permission",
                     "binary", "unreadable", "weird-unknown-code"] {
            let s = SSHService.serverFsErrorText(code)
            XCTAssertFalse(containsCJK(s), "fs error [\(code)] still Chinese: \(s)")
        }
    }

    func testChinese_serverFsErrorTextStaysChineseVerbatim() {
        setChinese()
        XCTAssertEqual(SSHService.serverFsErrorText("not-found"), "路径不存在(可能已被移动或删除)。")
        XCTAssertEqual(SSHService.serverFsErrorText("permission"), "没有权限读取该路径。")
    }

    func testEnglish_sshListErrorsAreEnglish() {
        setEnglish()
        for s in [L.listNoContent(), L.listUnparseable(), L.desktopViewNoAddress()] {
            XCTAssertFalse(containsCJK(s), "ssh error still Chinese: \(s)")
        }
    }

    // MARK: - Group 3b: the connect refusal (English-authored copy, both ways)

    /// `ConnectionError.message` IS the user's screen at the moment the app
    /// refuses to talk to a server: `pervioErrorText` (PervioApp.swift) shows it
    /// verbatim. This copy was authored in English, so the switch has to reach
    /// it from the OTHER side — under the shipped default a Chinese-speaking
    /// user must not be handed an English man-in-the-middle warning, which is
    /// precisely the one refusal they have to understand and not click past.
    ///
    /// Driven through the REAL seams, never the `L` helper: `connect` for the
    /// three refusals that happen before a socket, one real dial at a dead port,
    /// and `classifyConnectFailure` fed the actual Citadel errors (constructed
    /// here — no server needed). Only `.hostNotFound` is left to the sandbox
    /// suite (ConnectFailureTests), because it needs a resolver.
    func testChinese_connectRefusalsAreChinese() async {
        setChinese()
        for (what, s) in await allRefusals() {
            XCTAssertTrue(containsCJK(s),
                          "the \(what) refusal is still English under the shipped "
                          + "Chinese default: \(s)")
        }
    }

    /// The same six refusals under English: the original wording, verbatim — a
    /// translation must not quietly drop the fingerprint command or the
    /// authorized_keys hint, which are the only actionable parts.
    func testEnglish_connectRefusalsKeepTheirOriginalEnglish() async {
        setEnglish()
        let byName = Dictionary(uniqueKeysWithValues: await allRefusals())
        for (what, s) in byName {
            XCTAssertFalse(containsCJK(s), "the \(what) refusal is not English: \(s)")
        }
        XCTAssertTrue(byName["noPin"]?.contains("man-in-the-middle") == true,
                      "the unpinned refusal must name the attack it prevents: \(byName["noPin"] ?? "")")
        XCTAssertTrue(byName["hostKeyMismatch"]?.contains("ssh-keygen -lf") == true,
                      "the mismatch refusal must keep the command that verifies the fingerprint")
        XCTAssertTrue(byName["authRejected"]?.contains("authorized_keys") == true,
                      "the credential refusal must keep the file the user has to fix")
    }

    /// Safety, in BOTH languages: a translated refusal that no longer names the
    /// machine, the port or the account is unactionable, and two refusals that
    /// read the same put the user back where ConnectFailureTests started.
    func testConnectRefusalsStayActionableInEitherLanguage() async {
        for lang in ["zh", "en"] {
            if lang == "en" { setEnglish() } else { UserDefaults.standard.removeObject(forKey: key) }
            let byName = Dictionary(uniqueKeysWithValues: await allRefusals())
            XCTAssertEqual(Set(byName.values).count, byName.count,
                           "[\(lang)] two refusals read the same, so the user can't tell them "
                           + "apart: \(byName)")
            XCTAssertTrue(byName["portClosed"]?.contains("\(Self.deadPort)") == true,
                          "[\(lang)] the dead-port refusal must name the port: \(byName["portClosed"] ?? "")")
            XCTAssertTrue(byName["authRejected"]?.contains("nobody") == true,
                          "[\(lang)] the credential refusal must name the account: \(byName["authRejected"] ?? "")")
            XCTAssertTrue(byName["hostKeyMismatch"]?.contains("127.0.0.1:\(Self.deadPort)") == true,
                          "[\(lang)] the mismatch refusal must name the address that answered")
            for (what, s) in byName {
                XCTAssertGreaterThan(s.count, 12, "[\(lang)] the \(what) refusal explains nothing")
            }
        }
    }

    // MARK: - Group 4: archive reader, playbook, folds

    func testEnglish_archiveReaderCopyIsEnglish() {
        setEnglish()
        for s in [L.openOnComputer(), L.desktopReady(), L.copyAddress(),
                  L.copied(), L.desktopAddressNote()] {
            XCTAssertFalse(containsCJK(s), "archive-reader copy still Chinese: \(s)")
        }
    }

    func testEnglish_playbookCopyIsEnglish() {
        setEnglish()
        for s in [L.playbookNature(), L.playbookUseExplainer(),
                  L.playbookSmuggledSteps(), L.bodyLabel(), L.playbookUseFooter()] {
            XCTAssertFalse(containsCJK(s), "playbook copy still Chinese: \(s)")
        }
    }

    /// Drive the REAL render seams: `MarkdownBlock.collapsed` builds the "expand
    /// N" fold summary, and `parseBlocks` builds a bare `<details>`'s default
    /// summary — so these assert the strings the viewer actually emits, not just
    /// the L helper.
    func testEnglish_richTextFoldSummariesFromRealSeamsAreEnglish() {
        setEnglish()
        // collapseSections fold → "expand N entries" summary.
        let md = "## Picks\n- a\n- b\n- c\n"
        let blocks = MarkdownBlock.collapsed(MarkdownBlock.parse(md), sections: ["Picks"])
        let expandSummary = blocks.compactMap { b -> String? in
            if case .details(let s, _) = b { return s } else { return nil }
        }.first
        XCTAssertNotNil(expandSummary, "precondition: the section folded into a details block")
        XCTAssertFalse(containsCJK(expandSummary ?? ""),
                       "the 'expand N' fold summary is still Chinese: \(expandSummary ?? "")")
        XCTAssertTrue((expandSummary ?? "").contains("3"), "the entry count must survive")

        // A bare <details> with no <summary> → the default summary.
        let detailsMD = "<details>\nbody line\n</details>\n"
        let defaultSummary = MarkdownBlock.parse(detailsMD).compactMap { b -> String? in
            if case .details(let s, _) = b { return s } else { return nil }
        }.first
        XCTAssertNotNil(defaultSummary, "precondition: the <details> parsed to a details block")
        XCTAssertFalse(containsCJK(defaultSummary ?? ""),
                       "the default <details> summary is still Chinese: \(defaultSummary ?? "")")
    }

    func testChinese_richTextFoldsStayChineseVerbatim() {
        setChinese()
        XCTAssertEqual(L.expandEntries(5), "展开 5 篇")
        XCTAssertEqual(L.detailsDefaultSummary(), "详情")
    }

    // MARK: - Settings: the switch that drives it all

    func testEnglish_settingsCopyIsEnglish() {
        setEnglish()
        for s in [L.settingsTitle(), L.done(), L.settingsLanguageLabel(),
                  L.settingsLanguageFooter()] {
            XCTAssertFalse(containsCJK(s), "settings copy still Chinese under English: \(s)")
        }
        // The label no longer says "Prompt" — the switch governs the whole app.
        XCTAssertTrue(L.settingsLanguageLabel().localizedCaseInsensitiveContains("App language"),
                      "the setting now governs the whole UI, so its label must say so")
    }

    // MARK: - The "task finished" banner

    /// The one piece of chrome that reaches the user with the app CLOSED, and the
    /// last one still hard-coded in English: a Chinese user's lock screen read
    /// "Task finished". It now follows the same toggle as everything else, and the
    /// Chinese half is pinned verbatim so it can't drift away from the Mac's own
    /// push wording (pervio-run `_push_text`), which the user reads interchangeably.
    func testChinese_completionBannerCopyIsChineseVerbatim() {
        setChinese()
        XCTAssertEqual(L.taskFinishedTitle(), "任务完成")
        XCTAssertEqual(L.taskFailedTitle(), "任务失败")
        XCTAssertEqual(L.taskFinishedBody(), "这一轮跑完了。")
        XCTAssertEqual(L.taskFailedBody(), "这一轮以错误结束。")
        XCTAssertEqual(L.workflowFallbackName(), "工作流")
        XCTAssertEqual(L.workflowStepsFinishedBody(3), "3 步全部完成")
        XCTAssertEqual(L.workflowFinishedBody(), "这条工作流跑完了")
        XCTAssertEqual(L.workflowFailedBody(), "这条工作流失败了")
    }

    func testEnglish_completionBannerCopyIsEnglish() {
        setEnglish()
        for s in [L.taskFinishedTitle(), L.taskFailedTitle(), L.taskFinishedBody(),
                  L.taskFailedBody(), L.workflowFallbackName(),
                  L.workflowStepsFinishedBody(3), L.workflowFinishedBody(),
                  L.workflowFailedBody()] {
            XCTAssertFalse(containsCJK(s), "banner copy still Chinese under English: \(s)")
        }
        XCTAssertEqual(L.taskFinishedTitle(), "Task finished")
        XCTAssertEqual(L.workflowStepsFinishedBody(3), "3 steps finished")
    }

    // MARK: - The entry page (the redesigned home + the servers page it pushes)

    /// The home page used to be English-only chrome: a Chinese user opened the
    /// app to "Good afternoon" and "Read →". Every word on it now switches.
    func testChinese_entryPageStaysChineseVerbatim() {
        setChinese()
        XCTAssertEqual(L.greetingAfternoon(), "下午好")
        XCTAssertEqual(L.homeComposerPlaceholder(), "问点什么,或让 Claude 开工…")
        XCTAssertEqual(L.homeChipNewChat(), "＋ 新对话")
        XCTAssertEqual(L.homeChipWorkflows(), "工作流")
        XCTAssertEqual(L.homeChipBuild(), "搭建工作流")
        XCTAssertEqual(L.readCue(), "阅读 →")
        XCTAssertEqual(L.recentHeader(), "最近")
        XCTAssertEqual(L.serversTitle(), "服务器")
        XCTAssertEqual(L.homeServerBadge(), "主服务器")
    }

    func testEnglish_entryPageCopyIsEnglish() {
        setEnglish()
        for s in [L.greetingMorning(), L.greetingAfternoon(), L.greetingEvening(),
                  L.greetingLate(), L.homeComposerPlaceholder(), L.homeChipNewChat(),
                  L.homeChipWorkflows(), L.homeChipBuild(), L.readCue(),
                  L.publicationLoadingTeaser(), L.missedIssue(), L.reprint(),
                  L.reprinting(), L.homeUnreachable(), L.homeReprintFailed(),
                  L.recentHeader(), L.serversTitle(), L.noServersTitle(),
                  L.noServersBody(), L.edit(), L.setAsHomeServer(), L.editServer(),
                  L.deleteServer(), L.deleteServerTitle(), L.homeServerBadge()] {
            XCTAssertFalse(containsCJK(s), "entry-page copy still Chinese under English: \(s)")
        }
        XCTAssertEqual(L.readCue(), "Read →")
    }

    /// The page's DATES follow the same toggle. Foundation formats them, so
    /// without this seam a Chinese app on an English phone still printed
    /// "Wednesday, Aug 12" — the very split the one-toggle rule forbids.
    func testEntryPageDatesFollowTheAppLanguage() {
        let when = Date(timeIntervalSince1970: 1_786_545_000)   // 2026-08-12 14:30Z
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day()
        style.timeZone = TimeZone(secondsFromGMT: 0)!

        setChinese()
        // Foundation normalizes the identifier (zh_Hans_CN → zh_CN), so pin the
        // language, not the spelling.
        XCTAssertTrue(L.locale().identifier.hasPrefix("zh"),
                      "the Chinese formatting locale must be Chinese: \(L.locale().identifier)")
        let zh = when.formatted(style.locale(L.locale()))
        XCTAssertTrue(containsCJK(zh), "the home date line must be Chinese under zh: \(zh)")

        setEnglish()
        XCTAssertTrue(L.locale().identifier.hasPrefix("en"),
                      "the English formatting locale must be English: \(L.locale().identifier)")
        let en = when.formatted(style.locale(L.locale()))
        XCTAssertFalse(containsCJK(en), "the home date line must switch to English: \(en)")
        XCTAssertTrue(en.contains("Wednesday"), "…and still name the right day: \(en)")
    }

    // MARK: helpers

    /// Nothing listens on port 2 — every refusal below is aimed there, so not
    /// one of these tests needs a server (or the e2e sandbox) to run.
    private static let deadPort = 2

    private func deadProfile(pin: String) -> ServerProfile {
        var p = ServerProfile()
        p.host = "127.0.0.1"
        p.port = Self.deadPort
        p.username = "nobody"
        p.pinnedHostKey = pin
        return p
    }

    /// One message per connect failure, each taken from the path that really
    /// produces it. `rogueHostKeyLine()` is a parseable line for a key nobody
    /// serves, so it carries `connect` PAST the pin check and on to the dial.
    private func allRefusals() async -> [(String, String)] {
        let good = HostIdentityTests.wellFormedEd25519Key
        let rogue = SandboxEndpoint.rogueHostKeyLine()
        return [
            ("noPin",           await refusal(deadProfile(pin: ""), good)),
            ("unusablePin",     await refusal(deadProfile(pin: "ssh-dss AAAAB3NzaC1kc3M="), good)),
            ("badPrivateKey",   await refusal(deadProfile(pin: rogue), "-----BEGIN? not a key.")),
            ("portClosed",      await refusal(deadProfile(pin: rogue), good)),
            // Citadel's `InvalidHostKey` can't be constructed outside its own
            // module, so the mismatch refusal is read from the factory
            // `classifyConnectFailure` returns for it; that the classifier
            // really returns THAT for a rejected pin is what the sandbox suite
            // (HostIdentityTests / JumpChainTests) proves against a real
            // handshake.
            ("hostKeyMismatch", SSHService.hostKeyMismatchRefusal(
                profile: deadProfile(pin: "")).message),
            ("authRejected",    classified(SSHClientError.allAuthenticationOptionsFailed)),
        ]
    }

    private func refusal(_ profile: ServerProfile, _ secret: String,
                         file: StaticString = #filePath, line: UInt = #line) async -> String {
        let service = SSHService()
        do {
            try await service.connect(profile: profile, secret: secret)
            XCTFail("precondition: this connect must be refused", file: file, line: line)
            return ""
        } catch let e as SSHService.ConnectionError {
            return e.message
        } catch {
            XCTFail("expected the app's own ConnectionError, got \(error)", file: file, line: line)
            return ""
        }
    }

    /// The two Citadel errors that normally need a live handshake, run through
    /// the classifier directly.
    private func classified(_ error: Error) -> String {
        let out = SSHService.classifyConnectFailure(error, profile: deadProfile(pin: ""))
        guard let conn = out as? SSHService.ConnectionError else {
            XCTFail("precondition: \(type(of: error)) must classify into a ConnectionError")
            return ""
        }
        return conn.message
    }

    private func scheduleNamed(_ name: String) -> WorkflowSchedule {
        FakeSSH.scheduleRow(id: "s-\(name)", name: name, time: "06:30")
    }

    private func settleLine(clock: String, time: String) async -> String {
        let fake = FakeSSH()
        fake.script("date", clock)
        return await ScheduleFirstIssue.settle(ssh: fake, time: time,
                                               phoneClock: { (12, 0) })
    }
}
