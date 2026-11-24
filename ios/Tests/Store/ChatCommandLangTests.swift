import XCTest
@testable import Pervio

/// L2: the pervio-context pointer is server-built prose, so "switch it to
/// English" is a WIRE FLAG: with the Settings language on English, the same
/// send now carries `--lang en` next to `--pervio-context` — and ONLY then.
/// Default sends must stay byte-compatible with older servers, whose pervio-chat
/// hard-rejects unknown args.
@MainActor
final class ChatCommandLangTests: XCTestCase {

    private let svc = SSHService()
    private let profile = TestFactory.profile()

    private func chatCommand(context: Bool, language: PromptLanguage) -> String {
        svc.buildChatCommand(profile: profile, prompt: "hi", resume: nil,
                             approveSid: nil, pervioContext: context,
                             language: language)
    }

    func testChatCommand_englishRidesOnlyWithTheContextFlag() {
        let en = chatCommand(context: true, language: .english)
        XCTAssertTrue(en.contains("--pervio-context --lang en"),
                      "English + chip ON must ask the server for the English pointer: \(en)")

        let zh = chatCommand(context: true, language: .chinese)
        XCTAssertFalse(zh.contains("--lang"),
                       "the default language sends NO flag — older servers reject unknown args: \(zh)")

        let off = chatCommand(context: false, language: .english)
        XCTAssertFalse(off.contains("--lang"),
                       "chip OFF = zero injection: there is no pointer to translate: \(off)")
        XCTAssertFalse(off.contains("--pervio-context"))
    }

    /// A run is tagged with the phone and the server entry that started it, so
    /// its completion push goes to this phone only and a tapped notification
    /// reopens that entry (谁发的推给谁, 2026-10-15).
    func testStartRunCommand_namesThePhoneAndTheEntryThatStartedIt() {
        let cmd = svc.buildStartRunCommand(profile: profile, prompt: "hi", resume: nil, pervioContext: false)
        XCTAssertTrue(cmd.contains("--device '\(PushTokenStore.currentDeviceId)'"), cmd)
        XCTAssertTrue(cmd.contains("--origin '\(profile.id.uuidString)'"), cmd)
    }

    /// Which entry a finished run comes back to when the starting one is gone:
    /// the one whose scope holds the run's folder, in either spelling.
    func testScopeContainsInEitherSpelling() {
        var p = TestFactory.profile()
        p.projectDir = "~"
        XCTAssertTrue(p.scopeContains("/Users/x/b"))
        p.projectDir = "~/a"
        XCTAssertTrue(p.scopeContains("~/a"))
        XCTAssertTrue(p.scopeContains("~/a/sub"))
        XCTAssertTrue(p.scopeContains("/Users/x/a"))
        XCTAssertTrue(p.scopeContains("/Users/x/a/sub"))
        XCTAssertFalse(p.scopeContains("~/b"))
        XCTAssertFalse(p.scopeContains("/Users/x/ab"))
        let run = try? JSONDecoder().decode(RunInfo.self, from: Data(#"{"runId":"r","sessionId":"s","dir":"~/a","preview":"p","started":1,"state":"done","bytes":0,"origin":"E2E00000-0000-4000-8000-000000000001"}"#.utf8))
        XCTAssertEqual(run?.origin, "E2E00000-0000-4000-8000-000000000001")
    }

    func testStartRunCommand_sameContractAsLiveChat() {
        let en = svc.buildStartRunCommand(profile: profile, prompt: "hi", resume: nil,
                                          pervioContext: true, language: .english)
        XCTAssertTrue(en.contains("--pervio-context --lang en"),
                      "a detached run wraps the same pervio-chat — the flag must ride: \(en)")

        let zh = svc.buildStartRunCommand(profile: profile, prompt: "hi", resume: nil,
                                          pervioContext: true, language: .chinese)
        XCTAssertFalse(zh.contains("--lang"))

        let off = svc.buildStartRunCommand(profile: profile, prompt: "hi", resume: nil,
                                           pervioContext: false, language: .english)
        XCTAssertFalse(off.contains("--lang"))
    }

    /// A folder attached with "+" is handed to the agent as a writable extra
    /// working directory on both paths (2026-10-17); files and prompts are not.
    func testAttachedFoldersRideAsExtraDirsOnBothPaths() {
        let chat = svc.buildChatCommand(profile: profile, prompt: "hi", resume: nil, approveSid: nil,
                                        pervioContext: false, extraDirs: ["/a b/notes", "~/x"])
        XCTAssertTrue(chat.contains("--extra-dir '/a b/notes' --extra-dir '~/x' --prompt-b64"), chat)
        let run = svc.buildStartRunCommand(profile: profile, prompt: "hi", resume: nil, extraDirs: ["/a b/notes"],
                                           pervioContext: false)
        XCTAssertTrue(run.contains("--extra-dir '/a b/notes' --prompt-b64"), run)
        XCTAssertFalse(svc.buildChatCommand(profile: profile, prompt: "hi", resume: nil, approveSid: nil,
                                            pervioContext: false).contains("--extra-dir"))
        let atts = [Attachment(name: "f.txt", path: "/p/f.txt", isImage: false, isContext: true),
                    Attachment(name: "dir", path: "/p/dir", isImage: false, isContext: true, isDirectory: true)]
        XCTAssertEqual(ChatStore.extraDirs(of: atts), ["/p/dir"])
    }

    /// A folder the person handed over with the picker stays writable on every
    /// later turn of the conversation (the agent keeps working there; the
    /// sandbox must not refuse again) — and a folder that is merely NAMED in a
    /// turn's text is handed over by nobody. Until 2026-11-21 the list was read
    /// back out of the text, so a pasted file or web page containing a line
    /// 「附带目录:…」 made that folder writable (security review #3).
    func testOnlyAPickedFolderIsHandedOverAndItStaysForTheWholeConversation() async {
        let keys = [TestFactory.key(.granted, "sess-sticky"), TestFactory.key(.parked, "sess-sticky")]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        let fake = FakeSSH()
        fake.script("pervio-sessions usage", "{}")
        fake.chatEvents([.initialized(sessionId: "sess-sticky", model: nil),
                         .result(text: "ok", sessionId: "sess-sticky", costUSD: nil, isError: false, contextWindow: nil)])
        let store = ChatStore(profile: TestFactory.profile(), secret: "secret", resumeSessionId: "sess-sticky", ssh: fake)
        // What a pasted file, a web page or another conversation's summary can
        // put into a user turn — in the very words the app itself writes:
        var pasted = ChatMessage.user("看看这个")
        pasted.wireText = ChatStore.projectHandoffText("/Users/me/.ssh", language: .chinese) + "\n看看这个"
        var older = ChatMessage.user("old")
        older.wireText = "Background project: /srv/old\nRead this directory…\n\nold"   // the previous wording on disk
        store.messages = [older, pasted]
        XCTAssertEqual(store.extraDirs(adding: []), [], "text names a folder; it does not hand it over")
        XCTAssertEqual(store.formerDirs, ["/srv/old", "/Users/me/.ssh"],
                       "…it is shown as not in use, for the person to decide")
        await store.connect()
        await store.send("继续写")
        XCTAssertEqual(fake.extraDirsSeen.last, [], "\(fake.extraDirsSeen)")
        store.attachDirectory("/srv/new")                           // the picker
        await store.send("再来")
        XCTAssertEqual(fake.extraDirsSeen.last, ["/srv/new"])
        await store.send("第三句")                                   // nothing attached this time
        XCTAssertEqual(fake.extraDirsSeen.last, ["/srv/new"], "handed over once, writable from then on")
        // …and for the same conversation opened again (another page, another launch)
        let again = ChatStore(profile: TestFactory.profile(), secret: "secret", resumeSessionId: "sess-sticky", ssh: FakeSSH())
        XCTAssertEqual(again.conversationDirs, ["/srv/new"])
        XCTAssertEqual(ChatStore.directoryPaths(in: "plain text\n- /a/file.txt"), [])
    }

    /// The list belongs to the conversation, whatever its id: a first turn's
    /// pick is kept under the id the conversation is then given, and an id that
    /// changes mid-way (a resume that forked) takes the list along.
    func testThePickedFoldersFollowTheConversationAcrossItsIds() async {
        let keys = [TestFactory.key(.granted, "sess-first"), TestFactory.key(.granted, "sess-second")]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        let fake = FakeSSH()
        fake.script("pervio-sessions usage", "{}")
        fake.chatEvents([.initialized(sessionId: "sess-first", model: nil),
                         .result(text: "ok", sessionId: "sess-first", costUSD: nil, isError: false, contextWindow: nil)])
        fake.chatEvents([.initialized(sessionId: "sess-second", model: nil),
                         .result(text: "ok", sessionId: "sess-second", costUSD: nil, isError: false, contextWindow: nil)])
        let store = ChatStore(profile: TestFactory.profile(), secret: "secret", ssh: fake)   // a NEW conversation: no id yet
        await store.connect()
        store.attachDirectory("/srv/x")
        await store.send("first")
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: TestFactory.key(.granted, "sess-first")), ["/srv/x"])
        await store.send("second")
        XCTAssertEqual(fake.extraDirsSeen.last, ["/srv/x"])
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: TestFactory.key(.granted, "sess-second")), ["/srv/x"])
        XCTAssertNil(UserDefaults.standard.stringArray(forKey: TestFactory.key(.granted, "sess-first")), "no dead key left behind")
    }

    func testServerFsCommand_carriesTheDocumentLanguage() {
        XCTAssertTrue(SSHService.serverFsCommand("file", path: "/a b", language: .english)
                        .hasSuffix("'/a b' en ''"),
                      "the attach script builds the doc header server-side — it needs the language")
        XCTAssertTrue(SSHService.serverFsCommand("file", path: "/a b", language: .chinese)
                        .hasSuffix("'/a b' zh ''"))
    }

    /// The fourth argv is the scope fence — the server's working directory —
    /// quoted like the path, so a folder name with a space or CJK stays one word.
    func testServerFsCommand_carriesTheScopeFence() {
        XCTAssertTrue(SSHService.serverFsCommand("ls", path: "~/a/b", language: .english, under: "~/a c")
                        .hasSuffix("'~/a/b' en '~/a c'"))
        let listing = try? JSONDecoder().decode(ServerDirListing.self,
                                                from: Data(#"{"path":"/x","entries":[],"total":0,"truncated":false,"atRoot":true}"#.utf8))
        XCTAssertEqual(listing?.atRoot, true)
        let outside = try? JSONDecoder().decode(ServerDirListing.self, from: Data(#"{"error":"outside"}"#.utf8))
        XCTAssertEqual(outside?.error, "outside")
        XCTAssertEqual(SSHService.serverFsErrorText("outside"), L.dirOutsideScope())
    }

    /// The working directory doubles as the server's scope; an empty field means
    /// the home, never "nothing".
    func testScopeDirFallsBackToHome() {
        var p = TestFactory.profile()
        p.projectDir = "  "
        XCTAssertEqual(p.scopeDir, "~")
        p.projectDir = "~/a/"
        XCTAssertEqual(p.scopeDir, "~/a/")
    }
}

/// The conversation's folders on screen and on the Mac's ledger (2026-10-17):
/// the strip lists what earlier turns handed over, "stop using" parks one for
/// this conversation only, the list row carries the person's name and the
/// folders, and a finished turn tells the Mac which folders this conversation
/// uses — once per change.
@MainActor
final class ConversationFoldersTests: XCTestCase {
    func testRowDecodesItsNameAndFolders() throws {
        let json = #"[{"id":"s1","preview":"first words","modified":1,"bytes":2,"title":"第七章 PPT","dirs":["/srv/ppt/v3"]},{"id":"s2","preview":"plain","modified":1,"bytes":2}]"#
        let rows = try JSONDecoder().decode([SessionSummary].self, from: Data(json.utf8))
        XCTAssertEqual(rows[0].title, "第七章 PPT")
        XCTAssertEqual(rows[0].customTitle, "第七章 PPT")
        XCTAssertEqual(rows[0].dirs, ["/srv/ppt/v3"])
        XCTAssertEqual(rows[1].title, "plain", "no name → the first words, as before")
        XCTAssertNil(rows[1].dirs)
    }

    func testStopUsingAFolderParksItForThisConversationOnly() {
        let keys = [TestFactory.key(.parked, "sess-dirs"), TestFactory.key(.granted, "sess-dirs")]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        UserDefaults.standard.set(["/srv/a", "/srv/b"], forKey: TestFactory.key(.granted, "sess-dirs"))   // handed over earlier
        let store = ChatStore(profile: TestFactory.profile(), secret: "s", resumeSessionId: "sess-dirs", ssh: FakeSSH())
        XCTAssertEqual(store.conversationDirs, ["/srv/a", "/srv/b"])
        store.stopUsingDir("/srv/a")
        XCTAssertEqual(store.conversationDirs, ["/srv/b"])
        XCTAssertEqual(store.extraDirs(adding: []), ["/srv/b"], "a parked folder is not sent either")
        let again = ChatStore(profile: TestFactory.profile(), secret: "s", resumeSessionId: "sess-dirs", ssh: FakeSSH())
        XCTAssertEqual(again.conversationDirs, ["/srv/b"], "and stays parked when the conversation is opened again")
        XCTAssertEqual(again.formerDirs, [], "a folder the person parked is not offered back as 'not in use'")
    }

    func testAFinishedTurnTellsTheMacTheFoldersOncePerChange() async {
        let fake = FakeSSH()
        fake.script("pervio-sessions usage", "{}")
        fake.script("meta --session", #"{"id":"sess-note","title":"","dirs":["/srv/a"]}"#)
        fake.chatEvents([.initialized(sessionId: "sess-note", model: nil),
                         .result(text: "ok", sessionId: "sess-note", costUSD: nil, isError: false, contextWindow: nil)])
        let store = ChatStore(profile: TestFactory.profile(), secret: "s", resumeSessionId: "sess-note", ssh: fake)
        await store.connect()
        store.attachDirectory("/srv/a")
        await store.send("go")
        await store.noteDirsIfChanged()
        XCTAssertEqual(fake.commandCalls(containing: "meta --session 'sess-note' --dirs-b64").count, 1, "\(fake.calls)")
        await store.noteDirsIfChanged()
        XCTAssertEqual(fake.commandCalls(containing: "meta --session").count, 1, "unchanged folders are not re-sent")
        let plain = ChatStore(profile: TestFactory.profile(), secret: "s", resumeSessionId: "sess-plain", ssh: fake)
        await plain.noteDirsIfChanged()
        XCTAssertEqual(fake.commandCalls(containing: "meta --session 'sess-plain'").count, 0, "a conversation without folders says nothing")
    }
}
