import XCTest
@testable import Pervio

/// Codex over app-server asks the phone the way Claude's approval mode does
/// (2026-10-18): pervio-codex-app blocks the item, writes a `permission_request`
/// line onto the codex stream, and waits for `respond` on the turn's sid. These
/// pin the phone's half: the line parses to the same event Claude's does, and a
/// codex chat turn carries the sid that makes the Mac ask at all.
@MainActor
final class CodexApprovalTests: XCTestCase {

    func testCodexPermissionRequestParsesLikeClaudes() throws {
        let line = #"{"type": "permission_request", "request_id": "codex-0", "tool_use_id": "exec-73ea", "tool_name": "Bash", "input": {"command": "/bin/zsh -lc 'curl -sI https://example.com | head -1'", "cwd": "/w", "reason": "network"}}"#
        let codex = AgentEvent.parse(line: line, backend: .codex)
        let claude = AgentEvent.parse(line: line, backend: .claude)
        guard case .permissionRequest(let rid, let call)? = codex.first else {
            return XCTFail("a codex permission_request must raise the Allow/Deny sheet, got \(codex)")
        }
        XCTAssertEqual(rid, "codex-0", "the id the phone's respond must echo")
        XCTAssertEqual(call.name, "Bash")
        XCTAssertEqual(call.command, "/bin/zsh -lc 'curl -sI https://example.com | head -1'")
        XCTAssertEqual(call.toolUseId, "exec-73ea", "ties the sheet to the command row already on screen")
        guard case .permissionRequest(let rid2, let call2)? = claude.first else { return XCTFail("\(claude)") }
        XCTAssertEqual(rid2, rid); XCTAssertEqual(call2.label, call.label, "one shape, one sheet, whichever engine asks")
    }

    func testCodexFileChangeApprovalIsAnEditRequest() throws {
        let line = #"{"type": "permission_request", "request_id": "codex-1", "tool_use_id": "patch-1", "tool_name": "Edit", "input": {"file_path": "/Users/me/elsewhere", "reason": "writes outside the workspace"}}"#
        guard case .permissionRequest(_, let call)? = AgentEvent.parse(line: line, backend: .codex).first else {
            return XCTFail("a patch outside the workspace must ask too")
        }
        XCTAssertEqual(call.name, "Edit")
        XCTAssertEqual(call.filePath, "/Users/me/elsewhere", "the root codex wants to write under")
    }

    func testCodexPermissionResolvedIsTheAnswerEventNotABubble() {
        let line = #"{"type": "permission_resolved", "request_id": "codex-0", "behavior": "allow"}"#
        let evs = AgentEvent.parse(line: line, backend: .codex)
        guard case .permissionResolved(let rid)? = evs.first else { return XCTFail("the answer line dismisses a replayed request (2026-10-19): \(evs)") }
        XCTAssertEqual(rid, "codex-0")
        let claude = AgentEvent.parse(line: line, backend: .claude)
        guard case .permissionResolved(let rid2)? = claude.first else { return XCTFail("\(claude)") }
        XCTAssertEqual(rid2, "codex-0", "one shape on both engines")
    }

    func testApproveSidRidesCodexChatTurnsNotCursors() {
        let svc = SSHService()
        var codex = TestFactory.profile(); codex.backend = .codex
        let cx = svc.buildChatCommand(profile: codex, prompt: "hi", resume: nil, approveSid: "sid-1", pervioContext: false)
        XCTAssertTrue(cx.contains("--approve-sid 'sid-1'"), "codex can ask now, so the turn needs its answer channel: \(cx)")
        var claude = TestFactory.profile(); claude.backend = .claude
        let cl = svc.buildChatCommand(profile: claude, prompt: "hi", resume: nil, approveSid: "sid-1", pervioContext: false)
        XCTAssertTrue(cl.contains("--approve-sid 'sid-1'"), cl)
        var cursor = TestFactory.profile(); cursor.backend = .cursor
        let cu = svc.buildChatCommand(profile: cursor, prompt: "hi", resume: nil, approveSid: "sid-1", pervioContext: false)
        XCTAssertFalse(cu.contains("--approve-sid"), "Cursor never asks, so no channel: \(cu)")
        let none = svc.buildChatCommand(profile: codex, prompt: "hi", resume: nil, approveSid: nil, pervioContext: false)
        XCTAssertFalse(none.contains("--approve-sid"), "no sid (a reattach, a probe) = headless, as before: \(none)")
    }
}
