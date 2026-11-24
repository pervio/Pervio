import XCTest
@testable import Pervio

/// The checkup's probe, run for real on the sandbox's sshd — by the account's
/// own shell, with the bare PATH an SSH session has and a home of its own.
///
/// `ConnectDoctorTests` judge what the probe prints; they cannot prove that
/// the probe FINDS a `claude` that is there. It did not: Claude Code's
/// installer puts it in ~/.local/bin, the probe looked in three other
/// folders, and a Mac the app was working on read "No claude command found"
/// (the person's screenshot, 2026-11-22).
@MainActor
final class DoctorProbeTransportTests: XCTestCase {

    private func probe(in home: String, on ssh: SSHService) async throws -> [ConnectDoctor.Check] {
        let q = SSHService.shellQuote
        // The account's shell runs the command an SSH exec hands it; here that
        // shell is given the home under test and nothing on PATH but the system's.
        let out = try await ssh.runCommand(
            "env -i HOME=\(q(home)) PATH=/usr/bin:/bin:/usr/sbin:/sbin SHELL=/bin/sh \"${SHELL:-/bin/zsh}\" -c \(q(ConnectDoctor.probeCommand))")
        return ConnectDoctor.judge(probeOutput: out)
    }

    func testClaudeIsFoundWhereItsInstallerPutsIt() async throws {
        let endpoint = try SandboxEndpoint.discover()
        let ssh = SSHService()
        try await ssh.connect(profile: endpoint.profile, secret: endpoint.privateKey)
        defer { Task { await ssh.disconnect() } }
        let base = try await ssh.runCommand("printf %s \"$HOME\"").trimmingCharacters(in: .whitespacesAndNewlines)
            + "/doctor-probe-\(UUID().uuidString.prefix(8))"
        let q = SSHService.shellQuote
        defer { Task { _ = try? await ssh.runCommand("rm -rf \(q(base))") } }

        for place in [".local/bin", ".nvm/versions/node/v22.1.0/bin", "Library/pnpm"] {
            let home = base + "/" + place.replacingOccurrences(of: "/", with: "_")
            _ = try await ssh.runCommand("mkdir -p \(q(home + "/" + place)) && printf '#!/bin/sh\\n' > \(q(home + "/" + place + "/claude")) && chmod +x \(q(home + "/" + place + "/claude"))")
            let checks = try await probe(in: home, on: ssh)
            let claude = try XCTUnwrap(checks.first { $0.id == "claude" })
            XCTAssertEqual(claude.verdict, .pass, "claude sits in ~/\(place) and the checkup says it is not installed: \(claude.detail)")
            XCTAssertEqual(claude.detail, home + "/" + place + "/claude")
        }

        // …and where there is none, it still says so (a home with nothing in it).
        let empty = base + "/empty"
        _ = try await ssh.runCommand("mkdir -p \(q(empty))")
        let checks = try await probe(in: empty, on: ssh)
        XCTAssertEqual(checks.first { $0.id == "claude" }?.verdict, .fail)
        XCTAssertEqual(checks.first { $0.id == "python" }?.verdict, .pass, "the other lines of the probe still answer")
    }
}
