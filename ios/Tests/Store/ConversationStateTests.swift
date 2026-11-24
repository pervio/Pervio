import XCTest
@testable import Pervio

/// What the phone remembers about a conversation — the folders it may write
/// to, its workflow switch, its waiting follow-ups, its model and permission —
/// belongs to the conversation ON ITS COMPUTER. It used to be filed under the
/// conversation's id alone, and an id is only what a computer says: with two
/// computers saved, one that answered with the other's id was handed that
/// conversation's folders, its permission mode and — worst — the follow-up the
/// person had typed for the other machine (security review 2026-11-22, #3).
@MainActor
final class ConversationStateTests: XCTestCase {

    private let sid = "0f2b6c1e-conv-state-test"

    /// Two computers: each proved a host key of its own.
    private func mac(_ key: String, user: String = "me", host: String = "10.0.0.2") -> ServerProfile {
        var p = TestFactory.profile()
        p.host = host; p.username = user
        p.pinnedHostKey = "ssh-ed25519 \(key)"
        return p
    }
    private var a: ServerProfile { mac("AAAAC3NzaC1lZDI1NTE5AAAAIA-mini") }
    private var b: ServerProfile { mac("AAAAC3NzaC1lZDI1NTE5AAAAIB-other", host: "evil.example") }
    private func scope(_ p: ServerProfile) -> String { ConversationState.scope(of: p) }

    private var appSupport: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    private func queueFile(_ p: ServerProfile, _ sid: String) -> URL {
        appSupport.appendingPathComponent(ConversationState.queueFileName(scope: scope(p), sid: sid))
    }
    private var legacyQueueFile: URL { appSupport.appendingPathComponent(ConversationState.legacyQueueFileName(sid: sid)!) }

    private func wipe() {
        let d = UserDefaults.standard
        for p in [a, b] {
            for slot in ConversationState.Slot.allCases { d.removeObject(forKey: ConversationState.key(slot, scope: scope(p), sid: sid)) }
            try? FileManager.default.removeItem(at: queueFile(p, sid))
        }
        for slot in ConversationState.Slot.allCases { d.removeObject(forKey: ConversationState.legacyKey(slot, sid: sid)) }
        d.removeObject(forKey: ConversationState.legacyQueueDefaultsKey(sid: sid))
        try? FileManager.default.removeItem(at: legacyQueueFile)
    }
    override func setUp() async throws { wipe() }
    override func tearDown() async throws { wipe() }

    private func store(_ p: ServerProfile, only: Bool, ssh: FakeSSH? = nil) -> ChatStore {
        ChatStore(profile: p, secret: "s", resumeSessionId: sid, ssh: ssh ?? FakeSSH(), onlyComputerSaved: only)
    }

    // MARK: - which computer

    func testTheComputerIsTheMachineThatProvedItselfAndTheAccount() {
        var renamed = a; renamed.name = "at the office"; renamed.host = "192.0.2.9"; renamed.port = 2222
        renamed.projectDir = "~/other"; renamed.id = UUID()
        XCTAssertEqual(scope(renamed), scope(a), "another address, another name, another saved entry: the same computer")
        var commented = a; commented.pinnedHostKey = a.pinnedHostKey + "  root@mini\n"
        XCTAssertEqual(scope(commented), scope(a), "the comment after a key is not identity")
        XCTAssertNotEqual(scope(b), scope(a), "another machine")
        XCTAssertNotEqual(scope(mac("AAAAC3NzaC1lZDI1NTE5AAAAIA-mini", user: "guest")), scope(a), "another account on the same machine")
        var unpinnedA = TestFactory.profile(); unpinnedA.pinnedHostKey = ""
        var unpinnedB = TestFactory.profile(); unpinnedB.pinnedHostKey = "  "
        XCTAssertNotEqual(scope(unpinnedA), scope(unpinnedB), "two entries nobody pinned are not thereby the same computer")
    }

    /// An id is whatever the computer says. None — dots, slashes, another
    /// conversation's whole key — may make one conversation's key or file spell
    /// another's, an old one's, or a path.
    func testNoIdCanSpellAnotherConversationsKeyOrAPath() {
        let hostile = ["\(scope(a)).\(sid)", "on.\(sid)", "\(scope(a))-\(sid)", "../../Library/Preferences/x",
                       "a/b", ".", "", sid + ".json"]
        for slot in ConversationState.Slot.allCases {
            let real = ConversationState.key(slot, scope: scope(a), sid: sid)
            for evil in hostile {
                XCTAssertNotEqual(ConversationState.key(slot, scope: scope(b), sid: evil), real, evil)
                XCTAssertNotEqual(ConversationState.legacyKey(slot, sid: evil), real,
                                  "what an old build would have called \(evil.debugDescription) must not be a new key")
            }
        }
        let realFile = ConversationState.queueFileName(scope: scope(a), sid: sid)
        for evil in hostile {
            let name = ConversationState.queueFileName(scope: scope(b), sid: evil)
            XCTAssertNotEqual(name, realFile, evil)
            XCTAssertFalse(name.contains("/") || name.contains(".."), "a file name, not a path: \(name)")
            if let old = ConversationState.legacyQueueFileName(sid: evil) {
                XCTAssertNotEqual(old, realFile, evil)
                XCTAssertFalse(old.contains("/") || old.contains(".."), old)
            }
        }
        XCTAssertNil(ConversationState.legacyQueueFileName(sid: "../x"), "an id that is not a plain word had no old file")
        XCTAssertNotNil(ConversationState.legacyQueueFileName(sid: sid))
    }

    func testOnlyOneComputerSavedIsToldFromSeveral() throws {
        func saved(_ list: [ServerProfile]) throws -> Data { try JSONEncoder().encode(list) }
        var second = a; second.id = UUID(); second.projectDir = "~/b"          // the same Mac, twice
        XCTAssertTrue(ConversationState.isOnlyScope(scope(a), profilesData: try saved([a, second])))
        XCTAssertFalse(ConversationState.isOnlyScope(scope(a), profilesData: try saved([a, b])))
        XCTAssertFalse(ConversationState.isOnlyScope(scope(b), profilesData: try saved([a])), "…asked of a computer that is not the saved one")
        XCTAssertTrue(ConversationState.isOnlyScope(scope(a), profilesData: nil))
    }

    // MARK: - the folders a conversation may write to

    /// The same id on two computers is two conversations: a folder handed to
    /// one is not writable in the other.
    func testAFolderHandedOverOnOneComputerIsNotHandedOverOnAnother() async {
        let onA = store(a, only: false)
        onA.attachDirectory("/Users/me/secrets")
        let fake = FakeSSH()
        fake.script("pervio-sessions usage", "{}")
        fake.chatEvents([.result(text: "ok", sessionId: sid, costUSD: nil, isError: false, contextWindow: nil)])
        let sender = store(a, only: false, ssh: fake)
        await sender.connect()
        sender.attachDirectory("/Users/me/secrets")
        await sender.send("work here")
        XCTAssertEqual(store(a, only: false).conversationDirs, ["/Users/me/secrets"], "precondition: the conversation on A keeps its folder")

        XCTAssertEqual(store(b, only: false).conversationDirs, [],
                       "a computer that answers with the same id was handed A's folder as writable")
        XCTAssertNil(UserDefaults.standard.object(forKey: ConversationState.legacyKey(.granted, sid: sid)),
                     "nothing is filed under the id alone any more")
    }

    func testTheWorkflowSwitchIsPerComputerToo() {
        let onA = store(a, only: false)
        XCTAssertFalse(onA.pervioContext)
        onA.togglePervioContext()
        XCTAssertTrue(store(a, only: false).pervioContext, "precondition: it sticks to the conversation on A")
        XCTAssertFalse(store(b, only: false).pervioContext, "the same id on another computer had the workflow tools switched on for it")
    }

    // MARK: - what an older build left under the id alone

    func testWithOneComputerSavedOldStateIsItsOwn() {
        let d = UserDefaults.standard
        d.set(["/srv/a"], forKey: ConversationState.legacyKey(.granted, sid: sid))
        d.set(["/srv/parked"], forKey: ConversationState.legacyKey(.parked, sid: sid))
        d.set(true, forKey: ConversationState.legacyKey(.workflows, sid: sid))
        let s = store(a, only: true)
        XCTAssertEqual(s.grantedDirs, ["/srv/a"], "an update must not make a one-computer phone hand its folders over again")
        XCTAssertEqual(s.excludedDirs, ["/srv/parked"])
        XCTAssertTrue(s.pervioContext)
        for slot in ConversationState.Slot.allCases {
            XCTAssertNil(d.object(forKey: ConversationState.legacyKey(slot, sid: sid)), "moved, not copied: \(slot)")
        }
        XCTAssertEqual(store(a, only: true).grantedDirs, ["/srv/a"], "…and it is still there the next time")
    }

    /// With several computers saved nobody can say whose an old entry was: it
    /// is not given to either on a guess, and it is gone — never left for the
    /// next computer to try.
    func testWithSeveralComputersSavedOldStateIsHandedToNoOne() {
        let d = UserDefaults.standard
        d.set(["/Users/me/secrets"], forKey: ConversationState.legacyKey(.granted, sid: sid))
        d.set(true, forKey: ConversationState.legacyKey(.workflows, sid: sid))
        let first = store(b, only: false)
        XCTAssertEqual(first.grantedDirs, [])
        XCTAssertFalse(first.pervioContext)
        XCTAssertNil(d.object(forKey: ConversationState.legacyKey(.granted, sid: sid)))
        XCTAssertEqual(store(a, only: false).grantedDirs, [], "the second to ask gets nothing either")
        XCTAssertEqual(store(a, only: true).grantedDirs, [], "…even if it is later the only one saved")
    }

    /// Switching to a conversation in the drawer is a way in too.
    func testOpeningAConversationFromTheDrawerFollowsTheSameRule() async {
        let other = sid + "-other"
        let d = UserDefaults.standard
        defer {
            d.removeObject(forKey: ConversationState.legacyKey(.granted, sid: other))
            d.removeObject(forKey: ConversationState.key(.granted, scope: scope(a), sid: other))
        }
        for (only, want) in [(true, ["/srv/x"]), (false, [])] as [(Bool, [String])] {
            d.removeObject(forKey: ConversationState.key(.granted, scope: scope(a), sid: other))
            d.set(["/srv/x"], forKey: ConversationState.legacyKey(.granted, sid: other))
            let fake = FakeSSH()
            fake.script("pervio-sessions usage", "{}"); fake.script("pervio-sessions context", "{}")
            fake.script("transcript", TestFactory.transcriptJSON([("user", "hi")]))
            let s = store(a, only: only, ssh: fake)
            await s.connect()
            await s.open(sessionId: other)
            XCTAssertEqual(s.grantedDirs, want, only ? "one computer: its own" : "several: handed to no one")
            XCTAssertNil(d.object(forKey: ConversationState.legacyKey(.granted, sid: other)))
        }
    }

    // MARK: - follow-ups waiting to be sent

    private func write(_ words: [String], to url: URL) throws {
        try JSONEncoder().encode(words).write(to: url)
    }
    private func offline() -> FakeSSH { let f = FakeSSH(); f.connectError = FakeSSH.Boom(message: "offline"); return f }

    /// The worst of it: a follow-up typed for one computer, sent to another.
    func testAFollowUpWaitingOnOneComputerIsNotSentOnAnother() async throws {
        try write(["deploy to production"], to: queueFile(a, sid))
        let onB = store(b, only: false, ssh: offline())
        await onB.start()
        XCTAssertEqual(onB.queuedCount, 0, "B was about to send what was typed for A")
        XCTAssertFalse(onB.messages.contains { $0.text.contains("deploy to production") })
        let onA = store(a, only: false, ssh: offline())
        await onA.start()
        XCTAssertEqual(onA.queuedCount, 1, "…and A still has it")
    }

    func testAnOldQueueIsSentAsBeforeWhenOnlyOneComputerIsSaved() async throws {
        try write(["and then run the tests"], to: legacyQueueFile)
        let s = store(a, only: true, ssh: offline())
        await s.start()
        XCTAssertEqual(s.queuedCount, 1, "an update must not lose a waiting follow-up on a one-computer phone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyQueueFile.path), "moved to its own place")
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueFile(a, sid).path))
    }

    /// Several computers saved: which one the waiting words were for is
    /// anyone's guess. They are not sent; they are put on the page, in full,
    /// for the person to send again — and the old file is gone.
    func testAnOldQueueIsShownNotSentWhenSeveralComputersAreSaved() async throws {
        try write(["rm -rf the build folder", "then deploy"], to: legacyQueueFile)
        UserDefaults.standard.set(["an even older copy"], forKey: ConversationState.legacyQueueDefaultsKey(sid: sid))
        let s = store(b, only: false, ssh: offline())
        await s.start()
        XCTAssertEqual(s.queuedCount, 0, "sent to whichever computer happened to open the id first")
        let note = s.messages.last { $0.text.contains("rm -rf the build folder") }?.text ?? ""
        XCTAssertTrue(note.contains(L.queueNotResent(2)) && note.contains("then deploy"), "the words are shown, with why: \(s.messages.map(\.text))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyQueueFile.path), "not left for the next computer")
        XCTAssertNil(UserDefaults.standard.object(forKey: ConversationState.legacyQueueDefaultsKey(sid: sid)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueFile(b, sid).path))
        let again = store(a, only: false, ssh: offline())
        await again.start()
        XCTAssertEqual(again.queuedCount, 0)
        XCTAssertFalse(again.messages.contains { $0.text.contains("then deploy") }, "said once, where it was found")
    }

    // MARK: - model, effort, permission

    func testAConversationsSettingsBelongToItsComputer() {
        let app = AppStore()
        defer { app.removeParams(for: sid, on: a); app.removeParams(for: sid, on: b) }
        app.removeParams(for: sid, on: a); app.removeParams(for: sid, on: b)
        var loud = a; loud.permissionMode = "bypassPermissions"; loud.model = "opus"
        app.saveParams(ConvParams(loud), for: sid, on: a)
        XCTAssertEqual(app.params(for: sid, on: a)?.permissionMode, "bypassPermissions")
        XCTAssertNil(app.params(for: sid, on: b), "the same id on another computer came up with A's permission mode")
        var onB = b
        app.restoreKnobs(into: &onB, sessionId: sid)
        XCTAssertNotEqual(onB.permissionMode, "bypassPermissions")
        var entry2 = a; entry2.id = UUID(); entry2.name = "the same Mac, another folder"
        XCTAssertEqual(app.params(for: sid, on: entry2)?.model, "opus", "two entries for one Mac are the same conversations")
        // A fresh AppStore reads the same table back.
        XCTAssertEqual(AppStore().params(for: sid, on: a)?.permissionMode, "bypassPermissions")
        app.removeParams(for: sid, on: a)
        XCTAssertNil(app.params(for: sid, on: a))
    }

    /// What an older build saved goes to the first computer that opens the
    /// conversation — in every honest case its owner — and to no second one.
    func testOldSettingsGoToTheFirstComputerThatOpensTheConversationAndNoOther() {
        let app = AppStore()
        defer { app.removeParams(for: sid, on: a); app.removeParams(for: sid, on: b); app.sessionParams[sid] = nil }
        app.removeParams(for: sid, on: a); app.removeParams(for: sid, on: b)
        var old = a; old.model = "haiku"; old.effort = "low"
        app.sessionParams[sid] = ConvParams(old)
        XCTAssertEqual(app.params(for: sid, on: a)?.model, "haiku", "an update keeps a conversation's own model")
        XCTAssertNil(app.sessionParams[sid], "moved out of the old table")
        XCTAssertNil(app.params(for: sid, on: b), "…so the same id elsewhere does not get it as well")
        // Saving under the new key also retires an old entry nobody had asked for yet.
        app.removeParams(for: sid, on: a)
        app.sessionParams[sid] = ConvParams(old)
        app.saveParams(ConvParams(b), for: sid, on: b)
        XCTAssertNil(app.sessionParams[sid])
        XCTAssertNil(app.params(for: sid, on: a))
    }
}
