import XCTest
@testable import Pervio

/// The app's own injections — the attached-files list, a handed-over
/// directory's reading guidance, Claude Code's image placeholder — are the
/// agent's business. The person sees chips, live and after a reload alike
/// (2026-10-15: "不要做成显示 injection").
@MainActor
final class InjectionFoldTests: XCTestCase {

    private func file(_ name: String, _ path: String, image: Bool = false, context: Bool = false) -> Attachment {
        Attachment(name: name, path: path, isImage: image, isContext: context)
    }

    func testAttachedFilesFoldIntoChipsAndKeepTheAsk() {
        let wire = ChatStore.wireText("fix the bug", attachments: [
            file("a.swift", "/Users/me/.pervio/uploads/a.swift"),
            file("shot.jpg", "/Users/me/.pervio/uploads/shot.jpg", image: true),
            file("📄 README.md", "/srv/p/README.md", context: true),
            file("🧵 past · chat", "/Users/me/.pervio/uploads/context-abcd1234.md", context: true),
        ])
        XCTAssertTrue(wire.hasPrefix(ChatStore.attachedFilesHeader))
        let f = ChatStore.foldInjections(wire)
        XCTAssertEqual(f.chips, ["📎 a.swift", "🖼 shot.jpg", "📄 README.md", "🧵 " + L.chipContextGeneric()])
        XCTAssertEqual(f.text, "fix the bug")
        XCTAssertFalse(f.hidden)
    }

    func testTheDefaultAskFoldsToNothing() {
        let wire = ChatStore.wireText("", attachments: [file("a.pdf", "/Users/me/.pervio/uploads/a.pdf")])
        let f = ChatStore.foldInjections(wire)
        XCTAssertEqual(f.chips, ["📎 a.pdf"])
        XCTAssertEqual(f.text, "")
    }

    func testAHandedOverDirectoryIsAFolderChipInEitherLanguage() {
        for lang in [PromptLanguage.chinese, .english] {
            let wire = ChatStore.projectHandoffText("/srv/work/app", language: lang) + "\n看看这个项目"
            let f = ChatStore.foldInjections(wire)
            XCTAssertEqual(f.chips, ["📁 app"], "\(lang)")
            XCTAssertEqual(f.text, "看看这个项目", "\(lang)")
        }
    }

    func testADirectoryAttachmentRidesTheWireAsGuidanceNotAsAFileLine() {
        let dir = Attachment(name: "📁 app", path: "/srv/work/app", isImage: false, isContext: true, isDirectory: true)
        let wire = ChatStore.wireText("", attachments: [dir])
        XCTAssertTrue(wire.contains("/srv/work/app"))
        XCTAssertFalse(wire.contains("- /srv/work/app"), "a directory is not a file to Read")
        XCTAssertFalse(wire.contains(ChatStore.attachedFilesHeader))
        let f = ChatStore.foldInjections(wire)
        XCTAssertEqual(f.chips, ["📁 app"]); XCTAssertEqual(f.text, "")
    }

    func testClaudeCodesImagePlaceholderTurnIsHidden() {
        let f = ChatStore.foldInjections("[Image: original 943x2048, displayed at 921x2000. Multiply coordinates by 1.02 to map to original image.]")
        XCTAssertTrue(f.hidden)
    }

    func testPlainWordsPassThroughUntouched() {
        let f = ChatStore.foldInjections("背景项目是什么意思?\n- 第一点\n- 第二点")
        XCTAssertEqual(f.chips, [])
        XCTAssertEqual(f.text, "背景项目是什么意思?\n- 第一点\n- 第二点")
        XCTAssertFalse(f.hidden)
    }

    func testLegacyInlinedFramesStillFold() {
        let f = ChatStore.foldInjections("[附件 old.md]\nlots of text\n[附件结束]\n问题")
        XCTAssertTrue(f.text.contains("(背景附件,已折叠)"))
        XCTAssertTrue(f.text.hasSuffix("问题"))
    }

    func testTheWorkflowBuilderPromptIsAChipAndTheRequestStays() {
        for lang in [PromptLanguage.chinese, .english] {
            let wire = ChatStore.wireText("做一个每天 8 点的晨报", attachments: [
                Attachment(name: "x", path: "", isImage: false, isContext: true, inlinePrompt: WorkflowBuilderPrompt.text(for: lang))])
            XCTAssertTrue(wire.hasSuffix("\n做一个每天 8 点的晨报"), "the request follows the prompt's trailing marker line (\(lang))")
            let f = ChatStore.foldInjections(wire)
            XCTAssertEqual(f.chips, ["🧩 " + L.chipBuildWorkflow()], "\(lang)")
            XCTAssertEqual(f.text, "做一个每天 8 点的晨报", "\(lang)")
        }
    }

    func testTheWorkflowReviserPromptFoldsToANamedChip() {
        for lang in [PromptLanguage.chinese, .english] {
            let prompt = WorkflowBuilderPrompt.revise(name: "每日晨报", file: "daily.json", for: lang)
            let f = ChatStore.foldInjections(prompt + "\n改成 7 点")
            XCTAssertEqual(f.chips, ["🧩 " + L.chipReviseWorkflow("每日晨报")], "\(lang)")
            XCTAssertEqual(f.text, "改成 7 点", "\(lang)")
        }
        XCTAssertNil(ChatStore.foldWorkflowPrompt("你是谁?"), "ordinary words are not a builder turn")
    }

    func testSendingWithAttachmentsShowsChipsNotTheWire() async {
        let fake = FakeSSH()
        fake.script("--session 'sess-1'", TestFactory.transcriptJSON([("user", "earlier")]))
        fake.script("context --dir", "{}")
        fake.script("pervio-sessions usage", "{}")
        var p = TestFactory.profile(); p.runMode = false
        let s = ChatStore(profile: p, secret: "s", resumeSessionId: "sess-1", ssh: fake)
        await s.start()
        s.attachments = [file("notes.txt", "/Users/me/.pervio/uploads/notes.txt")]
        s.attachDirectory("/srv/work/app")
        fake.chatEvents([.result(text: "ok", sessionId: "sess-1", costUSD: nil, isError: false, contextWindow: nil)])
        await s.send("look")
        let mine = s.messages.last { $0.role == .user }
        XCTAssertEqual(mine?.text, "look")
        XCTAssertEqual(mine?.chips, ["📎 notes.txt", "📁 app"])
        XCTAssertTrue(mine?.wireText?.contains(ChatStore.attachedFilesHeader) == true)
        XCTAssertTrue(mine?.wireText?.contains("/srv/work/app") == true)
        XCTAssertTrue(fake.chatPrompts.last?.contains("- /Users/me/.pervio/uploads/notes.txt") == true, "the agent still gets the paths")
    }
}
