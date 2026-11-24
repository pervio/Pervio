import XCTest
@testable import Pervio

/// Codex's default mode is full access, as in the Codex app (2026-10-18): a new
/// profile starts there, the picker leads with it, the wire carries it, and
/// profiles / conversation params saved under the old workspace-write default
/// are lifted once — a read-only choice is kept.
@MainActor
final class CodexSandboxDefaultTests: XCTestCase {
    private let profilesKey = "pervio.profiles.v1"
    private let paramsKey = "pervio.sessionParams.v1"
    private let flagKey = "pervio.codexSandboxDefault.2026-10"
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for k in [profilesKey, paramsKey, flagKey] { saved[k] = UserDefaults.standard.object(forKey: k) }
    }

    override func tearDown() {
        for (k, v) in saved {
            if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    func testFreshProfileIsFullAccessAndThePickerLeadsWithIt() {
        XCTAssertEqual(ServerProfile().codexSandbox, "danger-full-access")
        XCTAssertEqual(CodexSandboxOption.all.first?.value, "danger-full-access", "the Codex app's order: Full access first")
        var odd = ServerProfile(); odd.codexSandbox = "nonsense"
        XCTAssertEqual(CodexSandboxOption.mode(of: odd).value, "danger-full-access", "an unknown value falls back to the default")
        XCTAssertEqual(CodexSandboxOption.all.map(\.title), ["Full access", "Approve for me", "Ask for approval", "Read-only"], "the Codex app's names, its order")
        XCTAssertEqual(CodexSandboxOption.headless.map(\.title), ["Full access", "Approve for me", "Read-only"], "a workflow step has nobody to ask")
    }

    func testAskForApprovalIsWorkspaceWritePlusThePhoneAsReviewer() {
        var p = TestFactory.profile(); p.backend = .codex
        let ask = CodexSandboxOption.all[2]
        ask.apply(to: &p)
        XCTAssertEqual(p.codexSandbox, "workspace-write"); XCTAssertEqual(p.codexReviewer, "user")
        XCTAssertEqual(CodexSandboxOption.mode(of: p).title, "Ask for approval")
        XCTAssertFalse(CodexSandboxOption.all[1].matches(p), "same sandbox, different reviewer — a different row")
        CodexSandboxOption.all[1].apply(to: &p)
        XCTAssertEqual(p.codexReviewer, "auto", "leaving Ask resets who reviews")
        XCTAssertEqual(CodexSandboxOption.mode(of: p).title, "Approve for me")
        var full = p; full.codexSandbox = "danger-full-access"; full.codexReviewer = "user"
        XCTAssertEqual(CodexSandboxOption.mode(of: full).title, "Full access", "the reviewer is meaningless off workspace-write")
    }

    func testAskRidesTheWireAsReviewerUserOnlyWhenChosen() {
        var p = TestFactory.profile(); p.backend = .codex
        CodexSandboxOption.all[2].apply(to: &p)
        let chat = SSHService().buildChatCommand(profile: p, prompt: "hi", resume: nil, approveSid: "s", pervioContext: false)
        XCTAssertTrue(chat.contains("--sandbox 'workspace-write'") && chat.contains("--reviewer user"), chat)
        let run = SSHService().buildStartRunCommand(profile: p, prompt: "hi", resume: nil, pervioContext: false)
        XCTAssertTrue(run.contains("--reviewer user"), "a run carries it too; the Mac knows nobody can answer there: \(run)")
        CodexSandboxOption.all[1].apply(to: &p)
        let auto = SSHService().buildChatCommand(profile: p, prompt: "hi", resume: nil, approveSid: "s", pervioContext: false)
        XCTAssertFalse(auto.contains("--reviewer"), "codex's own reviewer is the Mac's default, unsaid: \(auto)")
    }

    func testConversationParamsRememberTheReviewer() throws {
        var p = TestFactory.profile(); p.backend = .codex
        CodexSandboxOption.all[2].apply(to: &p)
        let data = try JSONEncoder().encode(ConvParams(p))
        let back = try JSONDecoder().decode(ConvParams.self, from: data)
        var q = TestFactory.profile(); q.backend = .codex
        back.apply(to: &q)
        XCTAssertEqual(CodexSandboxOption.mode(of: q).title, "Ask for approval")
        // params saved before the reviewer existed still decode and leave the default alone
        let old = try JSONDecoder().decode(ConvParams.self, from: Data(#"{"model":"","effort":"","runMode":true,"permissionMode":"default","codexSandbox":"workspace-write"}"#.utf8))
        var r = TestFactory.profile(); r.backend = .codex
        old.apply(to: &r)
        XCTAssertEqual(CodexSandboxOption.mode(of: r).title, "Approve for me")
    }

    func testFreshCodexProfileSendsFullAccessOnTheWire() {
        var p = TestFactory.profile(); p.backend = .codex; p.codexSandbox = ServerProfile().codexSandbox
        let chat = SSHService().buildChatCommand(profile: p, prompt: "hi", resume: nil, approveSid: "s", pervioContext: false)
        XCTAssertTrue(chat.contains("--sandbox 'danger-full-access'"), "the server maps full access to approval never (CXA6c): \(chat)")
        let run = SSHService().buildStartRunCommand(profile: p, prompt: "hi", resume: nil, pervioContext: false)
        XCTAssertTrue(run.contains("--sandbox 'danger-full-access'"), run)
    }

    func testOldWorkspaceWriteDefaultIsLiftedOnceReadOnlyKept() throws {
        var a = TestFactory.profile(); a.backend = .codex; a.codexSandbox = "workspace-write"
        var b = TestFactory.profile(); b.backend = .codex; b.codexSandbox = "read-only"
        var pa = ConvParams(a); pa.codexSandbox = "workspace-write"
        var pb = ConvParams(b); pb.codexSandbox = "read-only"
        UserDefaults.standard.set(try JSONEncoder().encode([a, b]), forKey: profilesKey)
        UserDefaults.standard.set(try JSONEncoder().encode(["sid-a": pa, "sid-b": pb]), forKey: paramsKey)
        UserDefaults.standard.removeObject(forKey: flagKey)

        let store = AppStore()
        XCTAssertEqual(store.profiles.map(\.codexSandbox), ["danger-full-access", "read-only"],
                       "the old default is lifted; a read-only choice is kept")
        XCTAssertEqual(store.sessionParams["sid-a"]?.codexSandbox, "danger-full-access", "a conversation's remembered params too")
        XCTAssertEqual(store.sessionParams["sid-b"]?.codexSandbox, "read-only")
        XCTAssertEqual(store.params(for: "sid-a", on: a)?.codexSandbox, "danger-full-access",
                       "…and that is what the conversation gets when it is next opened")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: flagKey), "done once")

        // Afterwards workspace-write is a choice again and survives a relaunch.
        var again = store.profiles[0]; again.codexSandbox = "workspace-write"
        UserDefaults.standard.set(try JSONEncoder().encode([again, store.profiles[1]]), forKey: profilesKey)
        XCTAssertEqual(AppStore().profiles.map(\.codexSandbox), ["workspace-write", "read-only"])
    }
}
