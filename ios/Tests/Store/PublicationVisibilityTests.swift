import XCTest
@testable import Pervio

/// U2: "this workflow produces a home card" was invisible. The only switch is
/// `Publish as home card`, buried inside one step's detail page — the user found
/// it by hunting. Nothing at the top of the editor, nothing on the workflow
/// list, nothing on a market row said a word about it.
///
/// These tests pin the three DECISIONS behind that visibility, because copy in a
/// SwiftUI body can't be asserted here:
///   * where the issues actually land (the line the editor's block prints),
///   * which workflows earn the 刊物 badge (and, just as important, which don't),
///   * which subscription rows on the Workflows screen are publications at all —
///     `schedule list` never says, so the badge has to come from the archives
///     join or it would be a guess.
@MainActor
final class PublicationVisibilityTests: XCTestCase {

    // MARK: - Where the issues land

    /// The default directory is the SERVER's rule (`_publish_slug`): lowercase,
    /// runs of non-alphanumerics collapse to "-", and it is Unicode-aware — a
    /// Chinese name keeps its characters. The app already has an ASCII-only
    /// slugger (SSHService.templateSlug, for filenames) that answers "workflow"
    /// for every Chinese name; reusing it here would tell the user their issues
    /// go somewhere they don't.
    func testU2_theDefaultArchiveDirIsTheOneTheServerWritesInto() {
        XCTAssertEqual(PublicationTarget.archiveDir(workflowName: "论文晨报", publishDir: nil),
                       "~/.pervio/archives/论文晨报",
                       "the server slugs Chinese names verbatim (str.isalnum); pointing the "
                       + "user at ~/.pervio/archives/workflow would be a lie they can check")
        XCTAssertEqual(PublicationTarget.archiveDir(workflowName: "GitHub 热点日报", publishDir: nil),
                       "~/.pervio/archives/github-热点日报")
        XCTAssertEqual(PublicationTarget.archiveDir(workflowName: "Weekly  Report!", publishDir: nil),
                       "~/.pervio/archives/weekly-report",
                       "runs of non-alphanumerics collapse to one dash and the edges are trimmed")
        XCTAssertEqual(PublicationTarget.archiveDir(workflowName: "", publishDir: nil),
                       "~/.pervio/archives/workflow",
                       "an unnamed workflow lands in the server's shared fallback dir")
    }

    func testU2_aStepThatNamesItsOwnDirectoryKeepsThatDirectoryVerbatim() {
        XCTAssertEqual(PublicationTarget.archiveDir(workflowName: "论文晨报",
                                                    publishDir: "~/.pervio/papers/archive"),
                       "~/.pervio/papers/archive",
                       "the paper digest publishes into its own state dir — the block must "
                       + "print where the issues really go, not the default it isn't using")
    }

    // MARK: - What the editor's top-level block says

    private func publishingSpec(name: String = "论文晨报",
                                publishDir: String? = nil) -> WorkflowSpec {
        var fetch = WorkflowStep(id: "fetch", backend: .claude, prompt: "")
        fetch.command = "pervio-arxiv-fetch"
        var digest = WorkflowStep(id: "digest", backend: .claude, prompt: "写晨报",
                                  dependsOn: ["fetch"])
        digest.publishEnabled = true
        digest.publishDir = publishDir
        var spec = WorkflowSpec()
        spec.name = name
        spec.steps = [fetch, digest]
        return spec
    }

    func testU2_aSpecThatPublishesCanSayWhichStepAndWhere() {
        guard let n = publishingSpec().publicationNotice else {
            return XCTFail("a publishing spec must be able to describe its publication — "
                           + "that description IS the editor's top-level block")
        }
        XCTAssertEqual(n.stepId, "digest", "the block names the step that prints the card")
        XCTAssertEqual(n.archiveDir, "~/.pervio/archives/论文晨报")

        var plain = WorkflowSpec()
        plain.name = "整理下载目录"
        plain.steps = [WorkflowStep(id: "tidy", backend: .claude, prompt: "整理")]
        XCTAssertNil(plain.publicationNotice,
                     "a workflow that publishes nothing must not claim a home card")
    }

    /// The two judgments have to agree: anything on the 刊物 shelf can say where
    /// its issues land, and anything that can say so belongs on the shelf.
    /// Includes the legacy `display.archiveDir` templates still carry.
    func testU2_theShelfJudgmentAndTheBlockNeverDisagree() {
        var legacy = WorkflowSpec()
        legacy.name = "老模板"
        legacy.steps = [WorkflowStep(id: "write", backend: .claude, prompt: "写")]
        legacy.display = WorkflowDisplay(archiveDir: "~/.pervio/legacy/archive")

        for spec in [publishingSpec(), legacy] {
            XCTAssertEqual(spec.publishes, spec.publicationNotice != nil,
                           "\(spec.name): the shelf says publishes=\(spec.publishes) while the "
                           + "editor block says \(spec.publicationNotice == nil ? "nothing" : "yes")")
        }
        XCTAssertEqual(legacy.publicationNotice?.archiveDir, "~/.pervio/legacy/archive",
                       "a legacy template's declared dir is where its issues are")
    }

    // MARK: - The editor, working off its draft (not a built spec)

    private func draft(_ stepIds: [String], publishing: String?,
                       publishDir: String = "") -> [DraftStage] {
        stepIds.map { id in
            var s = DraftStep(stepId: id)
            if id == publishing {
                s.publishEnabled = true
                s.publishDir = publishDir
            }
            return DraftStage(steps: [s])
        }
    }

    func testU2_theEditorSpotsAPublishToggleOnAnyStepNotJustTheLast() {
        // The toggle is per-step and lives behind a push — the top-level block
        // exists precisely because nobody scrolls every step to find it.
        for publisher in ["one", "two", "three"] {
            let n = WorkflowEditorView.publicationNotice(
                stages: draft(["one", "two", "three"], publishing: publisher),
                name: "论文晨报", legacyArchiveDir: nil)
            XCTAssertEqual(n?.stepId, publisher,
                           "publish is on “\(publisher)” and the editor's top-level block "
                           + "missed it — the user is back to hunting through steps")
            XCTAssertEqual(n?.archiveDir, "~/.pervio/archives/论文晨报")
        }
    }

    func testU2_anEditorWithNoPublishingStepShowsNoPublicationBlock() {
        XCTAssertNil(WorkflowEditorView.publicationNotice(
            stages: draft(["one", "two"], publishing: nil),
            name: "整理下载目录", legacyArchiveDir: nil),
                     "claiming a home card the workflow doesn't produce is worse than "
                     + "saying nothing — the user waits every morning for an issue that "
                     + "never comes")
    }

    func testU2_theEditorFollowsTheStepsOwnDirectoryAndTheLegacyOne() {
        let custom = WorkflowEditorView.publicationNotice(
            stages: draft(["fetch", "digest"], publishing: "digest",
                          publishDir: "~/.pervio/papers/archive"),
            name: "论文晨报", legacyArchiveDir: nil)
        XCTAssertEqual(custom?.archiveDir, "~/.pervio/papers/archive")

        // A seed that only carries the legacy display key still publishes; the
        // editor keeps that key verbatim through buildSpec, so the block has to
        // know about it too.
        let legacy = WorkflowEditorView.publicationNotice(
            stages: draft(["write"], publishing: nil),
            name: "老模板", legacyArchiveDir: "~/.pervio/legacy/archive")
        XCTAssertEqual(legacy?.archiveDir, "~/.pervio/legacy/archive",
                       "a legacy publishing template opened in the editor showed no block at "
                       + "all — it publishes, and the user can't see why")
    }

    // MARK: - Badges: who gets one, and who must not

    private func templateJSON(spec: WorkflowSpec?, name: String, file: String,
                              ok: Bool = true, kind: String? = nil,
                              body: String? = nil) -> String {
        var entry: [String: Any] = ["file": file, "mtime": 1, "ok": ok, "name": name]
        if let spec {
            let obj = try! JSONSerialization.jsonObject(with: try! JSONEncoder().encode(spec))
            entry["spec"] = obj
            entry["steps"] = spec.steps.count
        }
        if let kind { entry["kind"] = kind }
        if let body { entry["body"] = body }
        if !ok { entry["error"] = "not valid JSON" }
        return String(decoding: try! JSONSerialization.data(withJSONObject: entry), as: UTF8.self)
    }

    private func template(_ json: String) -> ServerTemplate {
        try! JSONDecoder().decode(ServerTemplate.self, from: Data(json.utf8))
    }

    func testU2_onlyRowsThatReallyPublishWearTheBadge() {
        let publishing = template(templateJSON(spec: publishingSpec(), name: "论文晨报",
                                               file: "papers.json"))
        XCTAssertTrue(publishing.isPublication, "it has a publish step")

        var plain = WorkflowSpec()
        plain.name = "整理下载目录"
        plain.steps = [WorkflowStep(id: "tidy", backend: .claude, prompt: "整理")]
        XCTAssertFalse(template(templateJSON(spec: plain, name: "整理下载目录",
                                             file: "tidy.json")).isPublication,
                       "a badge on a workflow that prints no card teaches the user the "
                       + "badge means nothing")

        XCTAssertFalse(template(templateJSON(spec: nil, name: "复盘剧本", file: "p.json",
                                             kind: "playbook", body: "# 剧本")).isPublication,
                       "a playbook has no spec at all — it can't publish anything")
        XCTAssertFalse(template(templateJSON(spec: publishingSpec(), name: "坏的",
                                             file: "bad.json", ok: false)).isPublication,
                       "the file didn't parse server-side; nothing about its spec is known")
    }

    // MARK: - The Workflows screen's subscription rows

    private func publicationJSON(name: String, dir: String, scheduleId: String?) -> String {
        var entry: [String: Any] = ["name": name, "dir": dir, "files": []]
        if let scheduleId { entry["scheduleId"] = scheduleId }
        return String(decoding: try! JSONSerialization.data(withJSONObject: entry), as: UTF8.self)
    }

    private func publications(_ jsons: [String]) -> [ArchivePublication] {
        jsons.map { try! JSONDecoder().decode(ArchivePublication.self, from: Data($0.utf8)) }
    }

    /// `schedule list` carries no spec, so the Workflows screen cannot tell which
    /// of its daily jobs prints a home card. `archives list` can: it joins a
    /// publication to the ONE schedule that publishes into it.
    func testU2_onlySchedulesJoinedToAPublicationAreBadged() async {
        let index = SchedulePublicationIndex {
            self.publications([
                self.publicationJSON(name: "论文晨报", dir: "~/.pervio/papers/archive",
                                     scheduleId: "sched-1"),
                // No schedule publishes here (or several do — the server leaves
                // the join out either way): absent, and the blank an older /
                // future server could spell it as.
                self.publicationJSON(name: "孤儿刊物", dir: "~/.pervio/archives/orphan",
                                     scheduleId: nil),
                self.publicationJSON(name: "空 id", dir: "~/.pervio/archives/blank",
                                     scheduleId: ""),
            ])
        }

        await index.refresh()

        XCTAssertTrue(index.publishes("sched-1"),
                      "this daily job prints the home card and its row said nothing")
        XCTAssertEqual(index.publication(for: "sched-1")?.dir, "~/.pervio/papers/archive",
                       "the row can name where the issues land")
        XCTAssertFalse(index.publishes("sched-2"),
                       "a schedule with no publication must not be badged 刊物")
        XCTAssertFalse(index.publishes(""),
                       "an unjoined publication must not collapse onto the empty id and "
                       + "badge every row on the screen")
    }

    /// The Workflows screen asks for this three ways — `.task`, `.onAppear` and
    /// pull-to-refresh — and the first two both fire when it opens. Each load is
    /// its own SSH connection, so an unguarded one dials the server twice for
    /// the same answer every single visit.
    func testU2_twoTriggersOnOneVisitDontOpenTwoConnections() async {
        var calls = 0
        var gates: [CheckedContinuation<Void, Never>] = []
        let index = SchedulePublicationIndex {
            calls += 1
            await withCheckedContinuation { gates.append($0) }
            return []
        }

        let first = Task { await index.refresh() }
        await TestFactory.settle()
        let second = Task { await index.refresh() }      // .onAppear, same instant
        await TestFactory.settle()

        XCTAssertEqual(calls, 1,
                       "the second trigger opened its own connection while the first was "
                       + "still in flight — two SSH dials per visit for one listing")

        gates.forEach { $0.resume() }
        await first.value
        await second.value
    }

    /// The badge is decoration: an archives call that fails must not blank the
    /// badges that were already right (rows flickering between 刊物 and nothing
    /// on every flaky refresh is worse than a stale badge).
    func testU2_aFailedArchivesRefreshKeepsTheBadgesItAlreadyHad() async {
        var answers: [() throws -> [ArchivePublication]] = [
            { self.publications([self.publicationJSON(name: "论文晨报",
                                                      dir: "~/.pervio/papers/archive",
                                                      scheduleId: "sched-1")]) },
            { throw FakeSSH.Boom(message: "server unreachable") },
        ]
        let index = SchedulePublicationIndex { try answers.removeFirst()() }

        await index.refresh()
        XCTAssertTrue(index.publishes("sched-1"), "precondition: badged")

        await index.refresh()

        XCTAssertTrue(index.publishes("sched-1"),
                      "one unreachable refresh dropped the badge off a subscription that "
                      + "is still printing a card every morning")
    }

    /// Two different names never share a template file; the same name always
    /// lands on the same file (2026-10-20).
    func testTemplateFilenamesDoNotCollideAcrossNamesAndStayStableForOne() {
        let a = SSHService.templateFilename(for: "GitHub 热点日报")
        let b = SSHService.templateFilename(for: "GitHub 周报")
        let c = SSHService.templateFilename(for: "论文晨报")
        let d = SSHService.templateFilename(for: "会议放榜速览")
        XCTAssertEqual(Set([a, b, c, d]).count, 4, "\([a, b, c, d])")
        XCTAssertTrue(a.hasPrefix("github-") && a.hasSuffix(".json"), a)
        XCTAssertTrue(c.hasPrefix("workflow-"), "an all-Chinese name keeps the old floor word plus its own hash: \(c)")
        XCTAssertEqual(a, SSHService.templateFilename(for: "GitHub 热点日报"), "same name, same file")
        XCTAssertEqual(SSHService.templateFilename(for: "Daily Digest"), "daily-digest.json", "a plain ASCII name is just its slug")
        XCTAssertEqual(SSHService.templateFilename(for: "  Daily Digest  "), "daily-digest.json")
        XCTAssertTrue(SSHService.templateFilename(for: "").hasPrefix("workflow-"), "an empty name still gets a file of its own")
    }
}
