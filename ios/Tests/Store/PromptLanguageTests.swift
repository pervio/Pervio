import XCTest
@testable import Pervio

/// L1: every prompt the APP injects into the model follows the Settings
/// "Prompt language" choice (`pervio.promptLanguage`: absent/"en" = English —
/// the shipped default since 2026-09-01; "zh" = Chinese). UI copy is deliberately NOT covered —
/// only wire-facing text is. Server-side templates (晨报 etc.), playbook
/// BODIES and pervio-mcp tool descriptions are out of scope (boundary: they
/// live on the server and are switched — if ever — server-side).
///
/// These tests pin the WIRE text at the seams the app already exposes, so
/// "the same action now emits English" is measured on what actually rides to
/// the model, not on a resource table.
@MainActor
final class PromptLanguageTests: XCTestCase {

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

    /// THE default contract (2026-09-01): absent setting = English. Every
    /// per-string content pin lives in explicit-language tests; this is the
    /// single place the routing itself is nailed down.
    func testDefault_languageIsEnglish() {
        XCTAssertEqual(PromptLanguage.current, .english)
    }

    /// True when the string still carries CJK ideographs or full-width CJK
    /// punctuation (「」、:; etc.) — i.e. it did NOT switch to English.
    private func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value)      // ideographs
            || (0x3000...0x303F).contains($0.value)   // CJK punctuation 「」【】、
            || (0xFF00...0xFFEF).contains($0.value)   // full-width forms :;()
        }
    }

    // MARK: Build-with-Claude seed (main injection path #2)

    func testChinese_builderSeedStaysChinese() {
        setChinese()
        XCTAssertTrue(containsCJK(WorkflowBuilderPrompt.text),
                      "with no setting the seed must stay the shipped Chinese text")
        XCTAssertTrue(WorkflowBuilderPrompt.text.hasSuffix("我的需求:"),
                      "the trailing ask line the user appends to must survive")
    }

    func testEnglish_builderSeedIsEnglish() {
        setEnglish()
        let t = WorkflowBuilderPrompt.text
        XCTAssertFalse(containsCJK(t),
                       "English setting, but the Build-with-Claude seed still "
                       + "carries Chinese: \(t.prefix(120))")
        // The load-bearing contract must survive translation: where templates
        // land, how they are verified, and the trailing line the user appends to.
        XCTAssertTrue(t.contains("~/.pervio/templates/"), "template landing path lost")
        XCTAssertTrue(t.contains("pervio-orchestrate templates list"), "verification command lost")
        XCTAssertTrue(t.hasSuffix("My request:"), "the trailing ask line must ask in English")
    }

    // MARK: Directory handoff (「把此目录交给对话」)

    func testEnglish_projectHandoffIsEnglish() {
        setEnglish()
        let t = ChatStore.projectHandoffText("/srv/proj")
        XCTAssertTrue(t.contains("/srv/proj"), "the path must ride the guidance")
        XCTAssertFalse(containsCJK(t), "English setting, Chinese handoff: \(t)")
    }

    // MARK: 背景 transcript document (provenance header + role labels)

    func testEnglish_contextDocumentIsEnglish() throws {
        setEnglish()
        let json = TestFactory.transcriptJSON([("user", "hello"), ("assistant", "world")])
        let turns = try JSONDecoder().decode([TranscriptTurn].self, from: Data(json.utf8))
        let window = TurnsWindow(total: 2, from: 1, to: 2, files: ["/old/proj/.claude/x.jsonl"], turns: turns)
        let doc = ChatStore.contextDocument(projectPath: "/old/proj", sessionId: "sess-1", backend: .claude,
                                            window: window, launcher: "/Users/me/.pervio/bin/pervio-sessions", byteCap: 60_000)
        XCTAssertTrue(doc.contains("/old/proj") && doc.contains("sess-1"),
                      "provenance must survive the language switch")
        XCTAssertFalse(containsCJK(doc), "English setting, Chinese document: \(doc.prefix(200))")
    }

    // MARK: 背景 attachment turn — whole-turn wire text
    //
    // The document no longer rides the wire on EITHER backend (it is a file in
    // ~/.pervio/uploads and the wire carries its path), so what is left to check
    // here is the app-authored wrapper + the ask line the app supplies when the
    // user attaches without typing anything.

    func testEnglish_attachmentTurnWireIsEnglish() async {
        setEnglish()
        let fake = FakeSSH()
        var profile = TestFactory.profile()
        profile.backend = .codex
        let store = ChatStore(profile: profile, secret: "secret", ssh: fake)
        await store.connect()
        store.attachments.append(Attachment(name: "notes",
                                            path: "/home/u/.pervio/uploads/context-1.md",
                                            isImage: false, isContext: true))
        await store.send("")                   // attachment-only turn: the app asks
        let wire = fake.chatPrompts.last ?? ""
        XCTAssertTrue(wire.contains("/home/u/.pervio/uploads/context-1.md"),
                      "the path must ride the wire: \(wire.prefix(200))")
        XCTAssertFalse(containsCJK(wire),
                       "English setting, but the attachment wrapper / ask line on the "
                       + "wire is still Chinese: \(wire.prefix(200))")
    }

    /// Reopening a conversation sent by an OLDER build (which inlined the 背景
    /// document into the wire under an English frame) must still fold it away.
    func testEnglish_legacyInlineFrameStillFoldsOnReload() {
        setEnglish()
        let wire = "[Attachment notes]\nplain body\n[End of attachment]\n\ncontinue"
        let folded = ChatStore.foldContextFrames(wire)
        XCTAssertFalse(folded.contains("plain body"),
                       "the English frame did not fold back on reload: \(folded.prefix(200))")
        XCTAssertTrue(folded.hasSuffix("continue"), "the user's own text must survive the fold")
        XCTAssertFalse(containsCJK(folded),
                       "English transcript folded with a Chinese note: \(folded.prefix(120))")
    }

    // MARK: Discuss seeds (reader / monitor entry points)

    func testChinese_discussSeedsStayChineseVerbatim() {
        setChinese()
        XCTAssertEqual(Prompts.readerDiscuss(dir: "d", file: "f.md"),
                       "请先读 d/f.md 这期报告,读完等我提问。我的问题:")
        XCTAssertEqual(Prompts.monitorDiscuss(title: "t", wfId: "w"),
                       "请先读工作流「t」(run w)的账本 ~/.pervio/wf/w/ledger.json,了解各步骤输出,读完等我提问。我的问题:")
    }

    func testEnglish_discussSeedsAreEnglish() {
        setEnglish()
        let r = Prompts.readerDiscuss(dir: "~/.pervio/archives/x", file: "2026-08-10.md")
        XCTAssertTrue(r.contains("~/.pervio/archives/x/2026-08-10.md"),
                      "the issue path must survive the language switch")
        XCTAssertFalse(containsCJK(r), "English setting, Chinese reader seed: \(r)")
        let m = Prompts.monitorDiscuss(title: "daily", wfId: "wf-1")
        XCTAssertTrue(m.contains("~/.pervio/wf/wf-1/ledger.json"),
                      "the ledger path must survive the language switch")
        XCTAssertFalse(containsCJK(m), "English setting, Chinese monitor seed: \(m)")
    }

    // MARK: Playbook load prefix (market 在对话中用)

    func testEnglish_playbookLoadPrefixIsEnglish() {
        setEnglish()
        let t = ServerTemplate.playbookLoadText(name: "deep-review", body: "STEP ONE")
        XCTAssertTrue(t.hasSuffix("STEP ONE"), "the body must ride verbatim")
        XCTAssertTrue(t.contains("deep-review"), "the playbook name must ride the prefix")
        XCTAssertFalse(containsCJK(t), "English setting, Chinese load prefix: \(t)")
    }

    func testDefault_playbookLoadPrefixIsEnglish() {
        // 2026-09-01: first-run audience went global — absent setting = English.
        let t = ServerTemplate.playbookLoadText(name: "n", body: "b")
        XCTAssertTrue(t.hasSuffix("b"))
        XCTAssertFalse(containsCJK(t), "shipped default is English now: \(t)")
    }

    func testChinese_playbookLoadPrefixStaysVerbatim() {
        XCTAssertEqual(ServerTemplate.playbookLoadText(name: "n", body: "b", language: .chinese),
                       "【载入剧本:n】以下是本对话要遵循的剧本,读完直接开始执行第一步,不要复述剧本内容:\n\n" + "b",
                       "the Chinese 载入前缀 is a fixed contract — it must not drift")
    }
}
