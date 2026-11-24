import XCTest
@testable import Pervio

/// The Workflows page can move a schedule to another time, and the market can
/// delete a template of mine (2026-10-20).
@MainActor
final class ScheduleTimeAndTemplateDeleteTests: XCTestCase {
    private func listStore(_ fake: FakeSSH) -> WorkflowListStore {
        WorkflowListStore(profile: TestFactory.profile(), secret: "secret", ssh: fake)
    }
    private func template(_ file: String, name: String) throws -> ServerTemplate {
        try JSONDecoder().decode(ServerTemplate.self, from: Data(#"{"file":"\#(file)","name":"\#(name)","ok":true,"steps":2}"#.utf8))
    }

    func testChangingTheTimeShowsAtOnceAndReachesTheMac() async {
        let fake = FakeSSH()
        fake.schedules = [FakeSSH.scheduleRow(id: "sched-1", name: "morning", time: "06:30")]
        let store = listStore(fake)
        await store.load()
        await store.updateScheduleTime("sched-1", "07:15")
        XCTAssertEqual(fake.scheduleTimes.map { "\($0.id)=\($0.time)" }, ["sched-1=07:15"], "schedule update, same id")
        XCTAssertEqual(store.schedules.first?.time, "07:15", "the row shows the new time")
        XCTAssertEqual(store.schedules.first?.id, "sched-1", "it is the same schedule, not a second one")
        XCTAssertNil(store.errorText)
    }

    func testAFailedTimeChangeFallsBackToTheTruthAndSaysWhy() async {
        let fake = FakeSSH()
        fake.schedules = [FakeSSH.scheduleRow(id: "sched-1", name: "morning", time: "06:30")]
        fake.updateScheduleTimeError = FakeSSH.Boom(message: "ssh dropped")
        let store = listStore(fake)
        await store.load()
        await store.updateScheduleTime("sched-1", "07:15")
        XCTAssertEqual(store.schedules.first?.time, "06:30", "the optimistic time is taken back")
        XCTAssertNotNil(store.errorText, "the person is told the change did not land")
    }

    func testTheWheelSpeaksTheServersClock() {
        XCTAssertEqual(ScheduleTime.hhmm(from: ScheduleTime.date(from: "07:05")), "07:05")
        XCTAssertEqual(ScheduleTime.hhmm(from: ScheduleTime.date(from: "23:59")), "23:59")
        XCTAssertEqual(ScheduleTime.hhmm(from: ScheduleTime.date(from: "garbage")), "06:30", "an unreadable time opens the wheel at the usual default")
    }

    func testDeletingATemplateOfMineRemovesTheRowAndTheFile() async throws {
        let fake = FakeSSH()
        fake.templates = [try template("mine-one.json", name: "mine one"), try template("keep.json", name: "keep")]
        let server = WorkflowMarketServerState(profile: TestFactory.profile(), secret: "s", makeSSH: { fake })
        await server.refresh()
        XCTAssertEqual(server.templates.count, 2)
        let line = await server.deleteTemplate(server.templates[0])
        XCTAssertNil(line)
        XCTAssertEqual(fake.deletedTemplates, ["mine-one.json"], "templates remove --file, the bare filename")
        XCTAssertEqual(server.templates.map(\.file), ["keep.json"], "the row is gone at once")
        await server.refresh()
        XCTAssertEqual(server.templates.map(\.file), ["keep.json"], "and stays gone on the next pull")
    }

    func testAFailedDeleteKeepsTheRowAndSaysWhy() async throws {
        let fake = FakeSSH()
        fake.templates = [try template("mine-one.json", name: "mine one")]
        fake.deleteTemplateError = FakeSSH.Boom(message: "ssh dropped")
        let server = WorkflowMarketServerState(profile: TestFactory.profile(), secret: "s", makeSSH: { fake })
        await server.refresh()
        let line = await server.deleteTemplate(server.templates[0])
        XCTAssertNotNil(line)
        XCTAssertEqual(server.templates.count, 1, "nothing was lost")
    }

    func testTheWireRefusesAPathOrANonTime() async {
        let svc = SSHService()
        let p = TestFactory.profile()
        do { try await svc.deleteTemplate(profile: p, file: "../precious.json"); XCTFail("a path must be refused before it reaches the Mac") } catch {}
        do { try await svc.deleteTemplate(profile: p, file: "nojson"); XCTFail("only .json files are templates") } catch {}
        do { try await svc.updateScheduleTime(profile: p, id: "s", time: "7:5"); XCTFail("the Mac wants HH:MM") } catch {}
    }
}
