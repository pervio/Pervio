import Foundation
import SwiftUI

/// 首连体检(roadmap 3.3)。一个陌生人第一次连自己的 Mac,十有八九卡在四件事
/// 之一:SSH 没通、Claude 没装、Claude 没登录、python3 缺席。今天的报错只有一句
/// "连不上服务器" —— 对开发者是日志,对新用户是天书。体检把这四件事逐项探测,
/// 每项给"人话结论 + 怎么修",绿灯的也照样列出来,让人知道检查过什么。
///
/// 结构上照 ServerProvisioner 的样子:注入 `any SSHCommanding`,测试用 FakeSSH
/// 按命令串答题;探测服务器状态只用 ONE 条聚合命令(SSH 往返贵,四条变一条),
/// 输出 KEY=VALUE 行,解析端逐键裁定。SSH 连接本身失败时,按错误文案分类成
/// 拒绝/超时/认证三类常见病,各配处方;分类不了就原样给出错误加通用建议 ——
/// 猜错病因比不猜更糟。
@MainActor
final class ConnectDoctor: ObservableObject {

    enum Verdict { case pass, fail, skipped }

    struct Check: Identifiable {
        let id: String
        let title: String
        let verdict: Verdict
        let detail: String
    }

    @Published private(set) var checks: [Check] = []
    @Published private(set) var running = false

    private let ssh: any SSHCommanding

    init(ssh: (any SSHCommanding)? = nil) {
        self.ssh = ssh ?? SSHService()
    }

    /// The one aggregated server-side probe. Plain POSIX shell only — on a
    /// broken machine there are no helper scripts to lean on. Every line is
    /// KEY=VALUE; absence of a key is itself a verdict (probe never ran).
    ///
    /// `claude` is looked for exactly where the launcher looks (pervio-chat's
    /// `find_cli`): the PATH an SSH session has, then the places installers put
    /// it — `~/.local/bin` first, where Claude Code's own installer does —
    /// then the person's login shell. The probe used to check three folders
    /// and not that one, so a Mac the app was working on read "No claude
    /// command found" (the person's screenshot, 2026-11-22). A test holds the
    /// two lists together. Run by /bin/sh from a here-document: the account's
    /// own shell may be zsh, where a pattern that matches nothing (no nvm) is
    /// an error that would skip the whole list.
    static let probeCommand = #"""
    /bin/sh <<'PERVIO_PROBE'
    find_cli() {
      p="$(command -v "$1" 2>/dev/null)"
      if [ -z "$p" ]; then
        for c in "$HOME/.local/bin/$1" /opt/homebrew/bin/"$1" /usr/local/bin/"$1" \
                 "$HOME/.npm-global/bin/$1" "$HOME/.bun/bin/$1" /snap/bin/"$1" \
                 "$HOME/.volta/bin/$1" "$HOME/.yarn/bin/$1" "$HOME/.cargo/bin/$1" \
                 "$HOME/Library/pnpm/$1" /opt/local/bin/"$1" "$HOME/.claude/local/$1" \
                 "$HOME"/.nvm/versions/node/*/bin/"$1" "$HOME"/.local/share/fnm/node-versions/*/installation/bin/"$1" \
                 "$HOME"/.fnm/node-versions/*/installation/bin/"$1"; do
          [ -x "$c" ] && p="$c"
        done
      fi
      if [ -z "$p" ]; then
        p="$("${SHELL:-/bin/zsh}" -lic "command -v $1" 2>/dev/null </dev/null | tail -n 1)"
        case "$p" in /*) [ -x "$p" ] || p="" ;; *) p="" ;; esac
      fi
      printf '%s' "$p"
    }
    echo "CLAUDE=$(find_cli claude)"
    echo "CREDS=$( { [ -s "$HOME/.claude/.credentials.json" ] || [ -s "$HOME/.claude.json" ]; } && echo yes || echo no)"
    echo "PYTHON=$(command -v python3)"
    echo "SCRIPTS=$( [ -s "$HOME/.pervio/bin/.pervio-rev" ] && echo yes || echo no)"
    PERVIO_PROBE
    """#

    func run(profile: ServerProfile, secret: String) async {
        running = true
        checks = []
        defer { running = false }

        do {
            try await ssh.connect(profile: profile, secret: secret)
        } catch {
            checks = [Self.sshFailure(error)] + [
                Check(id: "claude", title: L.doctorClaudeTitle(), verdict: .skipped, detail: L.doctorSkipped()),
                Check(id: "creds", title: L.doctorCredsTitle(), verdict: .skipped, detail: L.doctorSkipped()),
                Check(id: "python", title: L.doctorPythonTitle(), verdict: .skipped, detail: L.doctorSkipped()),
            ]
            return
        }
        var out = ""
        do {
            out = try await ssh.runCommand(Self.probeCommand)
        } catch {
            // Connected but the exec channel died — rare; report honestly.
            checks = [Check(id: "ssh", title: L.doctorSSHTitle(), verdict: .fail,
                            detail: pervioErrorText(error, L.doctorExecFailed()))]
            await ssh.disconnect()
            return
        }
        await ssh.disconnect()
        checks = [Check(id: "ssh", title: L.doctorSSHTitle(), verdict: .pass,
                        detail: L.doctorSSHPass())] + Self.judge(probeOutput: out)
    }

    // MARK: - Pure verdict logic (what the tests pin)

    nonisolated static func judge(probeOutput: String) -> [Check] {
        var kv: [String: String] = [:]
        for line in probeOutput.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            kv[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        let claudePath = kv["CLAUDE"] ?? ""
        var out: [Check] = []
        out.append(claudePath.isEmpty
            ? Check(id: "claude", title: L.doctorClaudeTitle(), verdict: .fail, detail: L.doctorClaudeMissing())
            : Check(id: "claude", title: L.doctorClaudeTitle(), verdict: .pass, detail: claudePath))
        // Login state is a heuristic (credential files), so the words say
        // "似乎" — an honest maybe beats a confident wrong.
        if claudePath.isEmpty {
            out.append(Check(id: "creds", title: L.doctorCredsTitle(), verdict: .skipped, detail: L.doctorSkipped()))
        } else {
            out.append(kv["CREDS"] == "yes"
                ? Check(id: "creds", title: L.doctorCredsTitle(), verdict: .pass, detail: L.doctorCredsPass())
                : Check(id: "creds", title: L.doctorCredsTitle(), verdict: .fail, detail: L.doctorCredsMissing()))
        }
        out.append((kv["PYTHON"] ?? "").isEmpty
            ? Check(id: "python", title: L.doctorPythonTitle(), verdict: .fail, detail: L.doctorPythonMissing())
            : Check(id: "python", title: L.doctorPythonTitle(), verdict: .pass, detail: kv["PYTHON"] ?? ""))
        // Server scripts: informational only — the provisioner paves them on the
        // next healthy connect, so a "no" here is a forecast, not a failure.
        if kv["SCRIPTS"] == "no" {
            out.append(Check(id: "scripts", title: L.doctorScriptsTitle(), verdict: .pass,
                             detail: L.doctorScriptsWillPave()))
        }
        return out
    }

    nonisolated static func sshFailure(_ error: Error) -> Check {
        let raw = (error as? SSHService.ConnectionError)?.message ?? String(describing: error)
        let lower = raw.lowercased()
        let detail: String
        if lower.contains("refused") {
            detail = L.doctorSSHRefused()
        } else if lower.contains("timed out") || lower.contains("timeout") {
            detail = L.doctorSSHTimeout()
        } else if lower.contains("auth") || lower.contains("password") || lower.contains("key") {
            detail = L.doctorSSHAuth()
        } else {
            detail = raw + "\n" + L.doctorSSHGeneric()
        }
        return Check(id: "ssh", title: L.doctorSSHTitle(), verdict: .fail, detail: detail)
    }
}

/// The doctor's sheet: one row per check, verdicts as plain colored glyphs,
/// each failing row carrying its fix instruction right below the title.
struct ConnectDoctorView: View {
    let profile: ServerProfile
    let secret: String
    @StateObject private var doctor = ConnectDoctor()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if doctor.running && doctor.checks.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(L.doctorRunning()).foregroundStyle(.secondary)
                    }
                }
                ForEach(doctor.checks) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            switch c.verdict {
                            case .pass:
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .fail:
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            case .skipped:
                                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                            }
                            Text(c.title).font(.subheadline.weight(.semibold))
                        }
                        if !c.detail.isEmpty {
                            Text(c.detail)
                                .font(.caption)
                                .foregroundStyle(c.verdict == .fail ? .primary : .secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle(L.doctorTitle())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.doctorClose()) { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(L.doctorRerun()) {
                        Task { await doctor.run(profile: profile, secret: secret) }
                    }
                    .disabled(doctor.running)
                }
            }
            .task { await doctor.run(profile: profile, secret: secret) }
        }
    }
}
