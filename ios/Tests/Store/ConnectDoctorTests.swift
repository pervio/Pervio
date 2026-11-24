import XCTest
@testable import Pervio

/// 首连体检(roadmap 3.3)的裁定逻辑。这些钉子保证:体检永远说人话、永远
/// 诚实 —— 探针没跑到的项标"跳过"而不是猜,登录态只说"似乎",分类不了的
/// SSH 错误原样端出而不是硬套一个病名。
@MainActor
final class ConnectDoctorTests: XCTestCase {

    // The zh copy pins in this suite predate the English default flip
    // (2026-09-01): an ABSENT language key used to mean Chinese and now means
    // English. Pin zh explicitly; put the user's real setting back afterwards.
    private var savedLang: Any?
    override func setUp() {
        super.setUp()
        savedLang = UserDefaults.standard.object(forKey: PromptLanguage.defaultsKey)
        UserDefaults.standard.set("zh", forKey: PromptLanguage.defaultsKey)
    }
    override func tearDown() {
        if let savedLang { UserDefaults.standard.set(savedLang, forKey: PromptLanguage.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: PromptLanguage.defaultsKey) }
        super.tearDown()
    }

    private func kv(_ claude: String, creds: String, python: String,
                    scripts: String = "yes") -> String {
        """
        CLAUDE=\(claude)
        CREDS=\(creds)
        PYTHON=\(python)
        SCRIPTS=\(scripts)
        """
    }

    func testHealthyMachinePassesEverything() {
        let checks = ConnectDoctor.judge(probeOutput:
            kv("/opt/homebrew/bin/claude", creds: "yes", python: "/usr/bin/python3"))
        XCTAssertEqual(checks.map(\.id), ["claude", "creds", "python"])
        XCTAssertTrue(checks.allSatisfy { $0.verdict == .pass })
        // The pass detail for claude is the PATH — evidence, not applause.
        XCTAssertEqual(checks[0].detail, "/opt/homebrew/bin/claude")
    }

    func testMissingClaudeFailsAndSkipsLogin() {
        let checks = ConnectDoctor.judge(probeOutput: kv("", creds: "no", python: "/usr/bin/python3"))
        XCTAssertEqual(checks[0].verdict, .fail)
        XCTAssertTrue(checks[0].detail.contains("npm install"))
        // No claude ⇒ login can't be judged; an honest skip, not a guess.
        XCTAssertEqual(checks[1].verdict, .skipped)
    }

    func testSignedOutClaudeGetsTheSignInInstruction() {
        let checks = ConnectDoctor.judge(probeOutput:
            kv("/usr/local/bin/claude", creds: "no", python: "/usr/bin/python3"))
        XCTAssertEqual(checks[1].verdict, .fail)
        XCTAssertTrue(checks[1].detail.contains("claude"))
    }

    func testMissingPythonNamesTheFix() {
        let checks = ConnectDoctor.judge(probeOutput:
            kv("/usr/local/bin/claude", creds: "yes", python: ""))
        XCTAssertEqual(checks[2].verdict, .fail)
        XCTAssertTrue(checks[2].detail.contains("xcode-select"))
    }

    func testUnpavedScriptsAreForecastNotFailure() {
        let checks = ConnectDoctor.judge(probeOutput:
            kv("/usr/local/bin/claude", creds: "yes", python: "/usr/bin/python3", scripts: "no"))
        let scripts = checks.first { $0.id == "scripts" }
        XCTAssertEqual(scripts?.verdict, .pass)
        XCTAssertTrue((scripts?.detail ?? "").contains("自动"))
    }

    func testGarbageProbeOutputFailsEverythingLoudly() {
        // A dead exec channel or hostile output must not fake a healthy verdict.
        let checks = ConnectDoctor.judge(probeOutput: "segfault nonsense")
        XCTAssertEqual(checks.first { $0.id == "claude" }?.verdict, .fail)
        XCTAssertEqual(checks.first { $0.id == "python" }?.verdict, .fail)
    }

    func testSSHFailureClassification() {
        let refused = ConnectDoctor.sshFailure(
            SSHService.ConnectionError(message: "Connection refused by peer"))
        XCTAssertTrue(refused.detail.contains("远程登录"))

        let timeout = ConnectDoctor.sshFailure(
            SSHService.ConnectionError(message: "operation timed out"))
        XCTAssertTrue(timeout.detail.contains("同一个网络"))

        let auth = ConnectDoctor.sshFailure(
            SSHService.ConnectionError(message: "all authentication methods failed"))
        XCTAssertTrue(auth.detail.contains("凭据"))

        // Unknown errors surface verbatim — the raw message must survive.
        let weird = ConnectDoctor.sshFailure(
            SSHService.ConnectionError(message: "flux capacitor misaligned"))
        XCTAssertEqual(weird.verdict, .fail)
        XCTAssertTrue(weird.detail.contains("flux capacitor misaligned"))
    }

    func testProbeCommandIsPlainShellWithAllKeys() {
        // The probe must run on a VIRGIN Mac: no helper scripts, no bashisms
        // beyond command -v, and every key the judge reads must be emitted.
        let cmd = ConnectDoctor.probeCommand
        for key in ["CLAUDE=", "CREDS=", "PYTHON=", "SCRIPTS="] {
            XCTAssertTrue(cmd.contains(key), key)
        }
        XCTAssertFalse(cmd.contains(".pervio/bin/pervio-"), "must not depend on paved scripts")
    }

    /// The checkup must find `claude` wherever the launcher finds it — or it
    /// calls a Mac the app is working on "not installed". It did: its own
    /// three folders did not include ~/.local/bin, where Claude Code's
    /// installer puts it (the person's screenshot, 2026-11-22). This reads the
    /// launcher's own list (server/bin/pervio-chat, `find_cli`) and holds the
    /// probe to every place on it, and to the login-shell fallback after it.
    func testTheCheckupLooksForClaudeWhereTheLauncherLooks() throws {
        let launcher = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/bin/pervio-chat")
        let script = try String(contentsOf: launcher, encoding: .utf8)
        let start = try XCTUnwrap(script.range(of: "find_cli() {"))
        let body = String(script[start.upperBound...].prefix(4000))
        let loop = try XCTUnwrap(body.range(of: "for c in "))
        let end = try XCTUnwrap(body.range(of: "; do", range: loop.upperBound..<body.endIndex))
        let places = body[loop.upperBound..<end.lowerBound]
            .replacingOccurrences(of: "\\\n", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init).filter { !$0.isEmpty }
        XCTAssertGreaterThan(places.count, 8, "could not read the launcher's list: \(places)")
        let probe = ConnectDoctor.probeCommand
        for place in places {
            let asProbeSaysIt = place.replacingOccurrences(of: "$name", with: "$1")
            XCTAssertTrue(probe.contains(asProbeSaysIt), "the launcher looks in \(place); the checkup does not")
        }
        XCTAssertTrue(places.contains { $0.contains(".local/bin") }, "\(places)")
        XCTAssertTrue(body.contains("-lic \"command -v $name\"") && probe.contains("-lic \"command -v $1\""),
                      "both ask the person's login shell last")
        XCTAssertTrue(probe.hasPrefix("/bin/sh <<'"), "run by sh, whatever the account's shell: in zsh a pattern matching nothing skips the whole list")
    }
}
