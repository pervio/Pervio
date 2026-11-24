import XCTest
@testable import Pervio

/// Wire-contract tests: every fixture is fed to the Swift model the app decodes
/// it with, plus the degradation cases (a missing field, an unknown field, one
/// broken row) that decide whether a server hiccup shows up as a degraded row or
/// as a silently empty screen.
final class DecodingTests: XCTestCase {

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

    // MARK: - pervio-sessions projects / list / transcript / search

    func testProjectsFixtureDecodes() throws {
        let projects = try Fixture.decode([ProjectInfo].self, "projects")
        XCTAssertEqual(projects.map(\.path), ["/home/pervio/app", "/home/pervio/notes", "/home/pervio"])
        XCTAssertEqual(projects[0].sessions, 3)   // two Claude conversations + the Codex thread in the same folder
        XCTAssertEqual(projects[0].modified, 1785549600)
        XCTAssertEqual(projects[0].modifiedDate, Date(timeIntervalSince1970: 1785549600))
        XCTAssertEqual(projects[0].id, projects[0].path)   // Identifiable key
    }

    /// `pervio-sessions home`: the folders under the default folder, each with
    /// its newest rows, and the default folder's own chats — one round trip.
    func testHomeFixtureDecodes() throws {
        let feed = try Fixture.decode(HomeFeed.self, "home")
        XCTAssertEqual(feed.dir, "/home/pervio")
        XCTAssertEqual(feed.projects.map(\.path), ["/home/pervio/app", "/home/pervio/notes"],
                       "newest-active first, the default folder itself never a project")
        XCTAssertEqual(feed.projects[0].name, "app")
        XCTAssertEqual(feed.projects[0].sessions, 3)
        XCTAssertEqual(feed.projects[0].recent.map(\.agent), [.claude, .claude, .codex], "newest first, both backends")
        XCTAssertEqual(feed.projects[1].recent.count, 1)
        XCTAssertEqual(feed.recent.map(\.title), ["随手问一句:今天天气如何"], "the default folder's own chat, not the projects'")
    }

    func testSessionsListFixtureDecodesBothBackends() throws {
        let sessions = try Fixture.decode([SessionSummary].self, "sessions-list")
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions[0].id, "1a2b3c4d-0000-4000-8000-00000000aaaa")
        XCTAssertEqual(sessions[0].preview, "帮我把 Pervio 的登录流程理一遍")
        XCTAssertEqual(sessions[0].bytes, 1150)
        XCTAssertEqual(sessions[0].agent, .claude)
        // Newest first, and the codex thread rides the same shape as the claude rows.
        XCTAssertEqual(sessions.map(\.modified), [1785549600, 1785546000, 1785544200])
        let codex = try XCTUnwrap(sessions.last)
        XCTAssertEqual(codex.agent, .codex)
        XCTAssertEqual(codex.title, "codex 也看看 pervio 的连接层")
    }

    func testTranscriptFixtureKeepsBlockOrderAndToolDetail() throws {
        let turns = try Fixture.decode([TranscriptTurn].self, "transcript")
        XCTAssertEqual(turns.map(\.role), ["user", "assistant", "user"])
        let assistant = turns[1]
        XCTAssertEqual(assistant.thinking, "先看 ServerProfile 再看 Keychain")
        XCTAssertEqual(assistant.tools, ["Edit  .../Sources/Login.swift"])
        // Ordered blocks are what the phone renders — thinking, text, tool, text.
        let blocks = try XCTUnwrap(assistant.blocks)
        XCTAssertEqual(blocks.map(\.t), ["thinking", "text", "tool", "text"])
        let tool = try XCTUnwrap(blocks.first { $0.t == "tool" })
        XCTAssertEqual(tool.id, "toolu_01")
        XCTAssertEqual(tool.name, "Edit")
        XCTAssertEqual(tool.filePath, "/home/pervio/app/Sources/Login.swift")
        XCTAssertEqual(tool.toolCall.name, "Edit")
        XCTAssertEqual(tool.toolCall.toolUseId, "toolu_01")
        // The session file's truncated line and its <ide_context> wrapper never
        // become turns — a corrupt line must not blank the reloaded chat.
        XCTAssertFalse(turns.contains { $0.text.contains("ide_context") })
    }

    func testSearchFixtureDecodesHitsAcrossBackends() throws {
        let hits = try Fixture.decode([SessionSearchHit].self, "search")
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits[0].project, "/home/pervio/app")
        XCTAssertEqual(hits[0].projectName, "app")
        XCTAssertEqual(hits[0].snippet, "帮我把 Pervio 的登录流程理一遍")
        XCTAssertEqual(hits[0].agent, .claude)
        XCTAssertEqual(hits.last?.agent, .codex)
        // A picked hit rides the browse-pick attach flow as a SessionSummary.
        let summary = hits[0].summary
        XCTAssertEqual(summary.id, hits[0].id)
        XCTAssertEqual(summary.backend, hits[0].backend)
    }

    // MARK: - pervio-sessions usage (incl. the model-scoped pool)

    func testUsageFixtureDecodesScopedPool() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase   // as ChatStore.loadUsage does
        let usage = try decoder.decode(UsageInfo.self, from: try Fixture.data("usage"))
        XCTAssertEqual(usage.fiveHour?.utilization, 37.5)
        XCTAssertEqual(usage.fiveHour?.resetsAt, "2026-08-01T12:00:00Z")
        XCTAssertEqual(usage.sevenDay?.utilization, 51.0)
        // The Fable-style scoped pool is the whole point: 91% critical while the
        // 7-day window still looks calm.
        let scoped = try XCTUnwrap(usage.scoped)
        XCTAssertEqual(scoped.count, 1)
        XCTAssertEqual(scoped[0].name, "Fable")
        XCTAssertEqual(scoped[0].percent, 91.0)
        XCTAssertEqual(scoped[0].severity, "critical")
    }

    // MARK: - pervio-orchestrate templates / archives / schedules

    func testTemplatesFixtureDecodesWorkflowsPlaybookAndBrokenRow() throws {
        let items = try Fixture.decode([ServerTemplate].self, "templates")
        XCTAssertEqual(items.map(\.file),
                       ["daily-brief.json", "code-review.json", "debug-playbook.json", "broken.json"])

        let digest = items[0]
        XCTAssertTrue(digest.ok)
        XCTAssertEqual(digest.steps, 2)
        XCTAssertEqual(digest.spec?.name, "每日晨报")
        XCTAssertEqual(digest.spec?.steps.map(\.id), ["fetch", "write"])
        XCTAssertTrue(digest.spec?.steps[0].isCommand == true)
        XCTAssertEqual(digest.spec?.display?.archiveDir, "~/.pervio/archives/daily-brief")
        XCTAssertEqual(digest.spec?.actions?.first?.menu, ["精读", "存档"])
        XCTAssertFalse(digest.isPlaybook)

        // A wrapper file: summary from the wrapper, spec from the inner object;
        // `publish: "<dir>"` fuses into publishEnabled + publishDir.
        let review = items[1]
        XCTAssertEqual(review.summary, "codex 扫 + claude 汇总,结果归档。")
        let report = try XCTUnwrap(review.spec?.steps.last)
        XCTAssertTrue(report.publishEnabled)
        XCTAssertEqual(report.publishDir, "~/.pervio/archives/reviews")
        XCTAssertEqual(review.spec?.steps.first?.backend, .codex)
        XCTAssertEqual(review.spec?.steps.first?.sandbox, "read-only")

        // A playbook is loaded into a conversation, never started.
        let playbook = items[2]
        XCTAssertTrue(playbook.isPlaybook)
        XCTAssertTrue(playbook.isUsablePlaybook)
        XCTAssertNil(playbook.spec)
        let load = try XCTUnwrap(playbook.playbookLoadText)
        XCTAssertTrue(load.hasPrefix("【载入剧本:抓虫剧本】"))
        XCTAssertTrue(load.hasSuffix(try XCTUnwrap(playbook.body)))

        // A file that doesn't parse is LISTED with its error, not hidden.
        let broken = items[3]
        XCTAssertFalse(broken.ok)
        XCTAssertEqual(broken.error, "not valid JSON")
        XCTAssertNil(broken.spec)
    }

    func testArchivesFixtureDecodesScheduleJoin() throws {
        let pubs = try Fixture.decode([ArchivePublication].self, "archives")
        XCTAssertEqual(pubs.map(\.dir),
                       ["~/.pervio/archives/daily-brief", "~/.pervio/archives/reviews"])

        let brief = pubs[0]
        XCTAssertEqual(brief.name, "每日晨报")
        XCTAssertEqual(brief.files.map(\.file), ["2026-08-01.md", "2026-07-31.md"])
        XCTAssertEqual(brief.display?.collapseSections, ["原始数据"])
        // The schedule join — what lets the home card say "today's issue is done"
        // without a second round trip.
        XCTAssertEqual(brief.scheduleId, "5ced0000a11e")
        XCTAssertEqual(brief.scheduleEnabled, true)
        XCTAssertEqual(brief.lastStatus, "done")
        XCTAssertEqual(brief.lastFiredAt, 1785565800)
        XCTAssertEqual(brief.nextDue, 1785652200)
        XCTAssertEqual(brief.lastFiredDate, Date(timeIntervalSince1970: 1785565800))

        // The publish-step publication has no unambiguous schedule → no join.
        let reviews = pubs[1]
        XCTAssertNil(reviews.scheduleId)
        XCTAssertNil(reviews.lastStatus)
        XCTAssertEqual(reviews.files.count, 1)
    }

    func testSchedulesFixtureDecodes() throws {
        let schedules = try Fixture.decode([WorkflowSchedule].self, "schedules")
        let s = try XCTUnwrap(schedules.first)
        XCTAssertEqual(s.id, "5ced0000a11e")
        XCTAssertEqual(s.time, "06:30")
        XCTAssertTrue(s.enabled)
        XCTAssertEqual(s.keepRuns, 7)
        XCTAssertEqual(s.lastStatus, "done")
        XCTAssertEqual(s.lastWfId, "wf0000000001")
        XCTAssertEqual(s.tz, "+0000")
        XCTAssertEqual(s.nextDueDate, Date(timeIntervalSince1970: 1785652200))
        XCTAssertEqual(s.lastFiredDate, Date(timeIntervalSince1970: 1785565800))
    }

    // MARK: - pervio-run list

    func testRunsListFixtureDecodesStates() throws {
        let runs = try Fixture.decode([RunInfo].self, "runs-list")
        XCTAssertEqual(runs.map(\.runId), ["a10000000002", "a10000000001", "a10000000003"])
        XCTAssertEqual(runs.map(\.state), ["running", "done", "failed"])
        XCTAssertTrue(runs[0].isRunning)
        XCTAssertEqual(runs[0].agent, .codex)         // meta.backend = "codex"
        XCTAssertEqual(runs[1].agent, .claude)        // "" = older run = claude
        XCTAssertTrue(runs[2].isFailed)
        XCTAssertEqual(runs[1].sessionId, "1a2b3c4d-0000-4000-8000-00000000aaaa")
        XCTAssertEqual(runs[1].title, "整理今天的论文")
    }

    // MARK: - the embedded server-fs script (ls / file)

    func testServerFsListingDecodesHostileNames() throws {
        let listing = try Fixture.decode(ServerDirListing.self, "serverfs-ls")
        XCTAssertNil(listing.error)
        XCTAssertEqual(listing.path, "/home/pervio/browse")
        XCTAssertEqual(listing.truncated, false)
        XCTAssertEqual(listing.total, 8)
        let entries = try XCTUnwrap(listing.entries)
        // Directories first, hidden entries last within each group.
        XCTAssertEqual(entries.first?.name, "docs")
        XCTAssertEqual(entries.first?.isDir, true)
        XCTAssertEqual(entries.last?.name, ".hidden.env")
        // Names that would break a naive pipeline survive the round trip intact.
        XCTAssertTrue(entries.contains { $0.name == "it's [a] tricky.md" })
        XCTAssertTrue(entries.contains { $0.name == "two\nline.md" })
        XCTAssertTrue(entries.contains { $0.name == "设计 稿 v2.md" })
        let notes = try XCTUnwrap(entries.first { $0.name == "notes.md" })
        XCTAssertEqual(notes.size, 48)
        XCTAssertEqual(notes.modifiedDate, Date(timeIntervalSince1970: 1785562400))
    }

    func testServerFsInBandErrorsDecodeInsteadOfThrowing() throws {
        let missing = try Fixture.decode(ServerDirListing.self, "serverfs-ls-missing")
        XCTAssertEqual(missing.error, "not-found")
        XCTAssertNil(missing.entries)
        XCTAssertEqual(SSHService.serverFsErrorText("not-found"), "路径不存在(可能已被移动或删除)。")

        let binary = try Fixture.decode(ServerFsAttachResult.self, "serverfs-file-binary")
        XCTAssertEqual(binary.error, "binary")
        XCTAssertNil(binary.path)
    }

    // MARK: - R7: a decode failure is NOT an empty list
    //
    // market/home clear themselves on an empty list and keep the previous rows on
    // a throw (see WorkflowMarketStore.refresh / HomePublicationsStore.load, which
    // already say "unreachable ≠ no publications"). So the ONE thing the decode
    // step must never do is turn "I couldn't read the answer" into "the server has
    // nothing" — that silently wipes the user's templates / publications /
    // schedules and, on the market, then clears knownInstalled/knownSubscribed too.

    /// `SSHService.decodeList` is the single decode step `listTemplates`,
    /// `listArchives`, `listSchedules` and `listWorkflows` each call — these tests
    /// exercise it directly because those four need a live SSH channel.
    func testR7_realServerListingDecodesThroughTheListSeam() throws {
        let items = try SSHService.decodeList(ServerTemplate.self, from: try Fixture.text("templates"))
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.first?.file, "daily-brief.json")
        // Stray bytes around the JSON (a login banner, a warning line) stay tolerated.
        let noisy = "WARNING: locale not set\n" + (try Fixture.text("schedules")) + "\n"
        XCTAssertEqual(try SSHService.decodeList(WorkflowSchedule.self, from: noisy).count, 1)
    }

    func testR7_truncatedOutputThrowsInsteadOfReportingAnEmptyList() throws {
        // A dropped SSH channel / maxResponseSize clip: half a real listing.
        let full = try Fixture.text("archives")
        let truncated = String(full.prefix(full.count / 2))
        XCTAssertThrowsError(try SSHService.decodeList(ArchivePublication.self, from: truncated)) {
            XCTAssertFalse(($0 as? SSHService.ConnectionError)?.message.isEmpty ?? true)
        }
    }

    func testR7_errorObjectThrowsInsteadOfReportingAnEmptyList() throws {
        // An older/newer server answering an object where the app expects a list.
        XCTAssertThrowsError(try SSHService.decodeList(ServerTemplate.self,
                                                       from: #"{"error": "no such command"}"#))
    }

    func testR7_emptyOutputThrowsInsteadOfReportingAnEmptyList() throws {
        // `pervio-orchestrate: command not found` → stdout is empty. "Nothing came
        // back" is not "you have no schedules".
        XCTAssertThrowsError(try SSHService.decodeList(WorkflowSchedule.self, from: ""))
        XCTAssertThrowsError(try SSHService.decodeList(WorkflowSchedule.self, from: "   \n"))
    }

    func testR7_emptyListIsStillAnEmptyList() throws {
        // The honest empty answer must keep decoding to zero rows — the throw is
        // only for payloads we could not read.
        XCTAssertEqual(try SSHService.decodeList(ServerTemplate.self, from: "[]\n").count, 0)
    }

    func testR7_oneBrokenRowDegradesButKeepsTheOtherRows() throws {
        // Row-level tolerance must survive the change: a single bad record still
        // degrades to defaults instead of throwing the whole listing away.
        var rows = try Fixture.rows("templates")
        rows[1]["file"] = 12345                      // wrong type where a String is expected
        rows[1]["ok"] = "yes"
        let text = String(decoding: try Fixture.bytes(rows), as: UTF8.self)
        let items = try SSHService.decodeList(ServerTemplate.self, from: text)
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[1].file, "")            // the broken row degraded…
        XCTAssertFalse(items[1].ok)
        XCTAssertEqual(items[0].file, "daily-brief.json")   // …its neighbours are intact
        XCTAssertEqual(items[3].file, "broken.json")
    }

    // MARK: - missing / unknown fields (older and newer servers)

    func testMissingFieldsDegradeToDefaults() throws {
        var rows = try Fixture.rows("templates")
        rows[0].removeValue(forKey: "ok")            // a server that can't say it's ok
        rows[0].removeValue(forKey: "steps")
        rows[0].removeValue(forKey: "mtime")
        let items = try JSONDecoder().decode([ServerTemplate].self, from: try Fixture.bytes(rows))
        XCTAssertFalse(items[0].ok)                  // default false: never open the editor blind
        XCTAssertNil(items[0].steps)
        XCTAssertNil(items[0].mtimeDate)

        var pubs = try Fixture.rows("archives")
        pubs[0].removeValue(forKey: "files")         // older server, no issues key
        pubs[0].removeValue(forKey: "scheduleId")    // older server, no schedule join
        let decoded = try JSONDecoder().decode([ArchivePublication].self, from: try Fixture.bytes(pubs))
        XCTAssertEqual(decoded[0].files, [])
        XCTAssertNil(decoded[0].scheduleId)
        XCTAssertEqual(decoded[0].dir, "~/.pervio/archives/daily-brief")

        var runs = try Fixture.rows("runs-list")
        runs[0].removeValue(forKey: "backend")       // pre-codex run
        let decodedRuns = try JSONDecoder().decode([RunInfo].self, from: try Fixture.bytes(runs))
        XCTAssertEqual(decodedRuns[0].agent, .claude)
    }

    func testUnknownFieldsAndFutureEnumValuesAreIgnored() throws {
        var rows = try Fixture.rows("sessions-list")
        rows[0]["somethingNewInV2"] = ["nested": true]
        rows[1]["backend"] = "gemini"                // a backend this build has never heard of
        let sessions = try JSONDecoder().decode([SessionSummary].self, from: try Fixture.bytes(rows))
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions[0].preview, "帮我把 Pervio 的登录流程理一遍")
        XCTAssertNil(sessions[1].backend)            // unknown enum degrades…
        XCTAssertEqual(sessions[1].agent, .claude)   // …to the safe default, no throw

        var turns = try Fixture.rows("transcript")
        turns[1]["futureKey"] = 7
        var blocks = try XCTUnwrap(turns[1]["blocks"] as? [[String: Any]])
        blocks[0]["futureBlockKey"] = "x"
        turns[1]["blocks"] = blocks
        let decoded = try JSONDecoder().decode([TranscriptTurn].self, from: try Fixture.bytes(turns))
        XCTAssertEqual(decoded[1].blocks?.count, 4)
        XCTAssertEqual(decoded[1].thinking, "先看 ServerProfile 再看 Keychain")
    }

    func testCorruptRowInATranscriptDoesNotBlankTheChat() throws {
        // The reload path that once blanked a whole conversation: one unreadable
        // turn must cost only itself.
        var turns = try Fixture.rows("transcript")
        turns[1]["role"] = 42
        turns[1]["tools"] = "Edit"                   // a String where a [String] is expected
        let decoded = try JSONDecoder().decode([TranscriptTurn].self, from: try Fixture.bytes(turns))
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[1].role, "")
        XCTAssertEqual(decoded[1].tools, [])
        XCTAssertEqual(decoded[0].text, "帮我把 Pervio 的登录流程理一遍")
        XCTAssertEqual(decoded[2].text, "再讲讲 pervio 的后台运行")
    }

    /// R12 (partial — see the honest gap below). The browser addresses a row by
    /// re-joining the listing's `path` with the entry's `name`, so a name the
    /// listing had to alter is a name the app can no longer open. This pins the
    /// half this host can prove: a file whose name genuinely CONTAINS U+FFFD is
    /// listed verbatim and stays addressable by exactly the string the picker
    /// builds — the replacement character is not, by itself, a broken name.
    ///
    /// NOT covered, and not faked: a name with invalid UTF-8 bytes (which `ls`
    /// replaces with U+FFFD, making display ≠ real name). APFS refuses to create
    /// such a file — `open(b"bad-\xff.txt")` → OSError 92 "Illegal byte sequence"
    /// — so neither the fixture nor a red test can be produced on this machine
    /// without inventing server output. The two entries below are byte-identical
    /// on the wire, which is precisely why the app cannot tell them apart and why
    /// the fix belongs on the server side (carry the raw name bytes).
    func testR12_realReplacementCharInAFilenameStaysAddressable() throws {
        let listing = try Fixture.decode(ServerDirListing.self, "serverfs-ls")
        let entries = try XCTUnwrap(listing.entries)
        let odd = try XCTUnwrap(entries.first { $0.name.unicodeScalars.contains("\u{FFFD}") })
        XCTAssertEqual(odd.name, "replacement-\u{FFFD}-name.md")
        // The exact path ContextPickerSheet hands to the attach call.
        let addressed = (try XCTUnwrap(listing.path) as NSString)
            .appendingPathComponent(odd.name)
        XCTAssertEqual(addressed, "/home/pervio/browse/replacement-\u{FFFD}-name.md")
        // …and the server answered that address with the file, not "not-found":
        // this fixture IS `file <that path>` run against the real script.
        let attach = try Fixture.decode(ServerFsAttachResult.self, "serverfs-file-fffd")
        XCTAssertNil(attach.error)
        XCTAssertEqual(attach.name, odd.name)
        XCTAssertEqual(attach.size, odd.size)
    }

    func testServerFsAttachFixtureDecodes() throws {
        let attach = try Fixture.decode(ServerFsAttachResult.self, "serverfs-file")
        XCTAssertNil(attach.error)
        XCTAssertEqual(attach.name, "notes.md")
        XCTAssertEqual(attach.size, 48)
        XCTAssertEqual(attach.truncated, false)
        // The doc lands in ~/.pervio/uploads — the one path both backends reference.
        let path = try XCTUnwrap(attach.path)
        XCTAssertTrue(path.contains("/.pervio/uploads/"), path)
        XCTAssertTrue(path.hasSuffix(".md"), path)
    }
}
