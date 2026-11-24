import XCTest
@testable import Pervio

/// B2, the half the count-for-count contract cannot see.
///
/// `ReportActionContractTests` proves the phone and pervio-view put the same
/// number of rating menus in the same places on the real issues. They do — but
/// only because the published spec's regex captures `\d{4}\.\d{4,5}`. The two
/// renderers do NOT share the rule that decides whether a hit is allowed to
/// become a button:
///
///   * pervio-view (`_argv_safe`) refuses a group that starts with `-`. The
///     group is substituted into the run template as an ARGV ELEMENT, so
///     `--force` would be read as a FLAG by whatever program the template names,
///     and there is no `--` separator to hide behind (pervio-feedback dies on a
///     bare `--`). The Mac draws no buttons and `/score` refuses the pair.
///   * the phone has no such rule. It draws the menu and builds the command,
///     shell-quoting the value — which makes it ONE word, not a harmless one.
///
/// So the agreement pinned next door is contingent on a pattern, and this file
/// says so out loud: it pins what each screen does today, and it pins the
/// property that keeps the published spec on the safe side of the gap. Ship a
/// publication whose regex can capture a dash and the second test goes red
/// BEFORE the two screens quietly disagree.
final class ReportActionSafetyTests: XCTestCase {

    // MARK: - what each screen does with a dash-capturing action

    /// Both halves come from ios/Tests/Fixtures/reports/actions-contract.json:
    /// the markdown, the action spec and the server's numbers were produced by
    /// the REAL pervio-view (make_actions_contract.py). The phone's numbers are
    /// recomputed here from the shipping parser.
    func testKnownDivergence_phoneOffersARatingTheMacRefuses() throws {
        let argv = try ReportFixture.contract().argvSafety

        // 1. The two regex engines agree about WHICH blocks hit. If they ever
        //    stop agreeing, the divergence below is no longer the one described.
        let phone = ReportFixture.phoneHits(argv.markdown, argv.actions)
        XCTAssertEqual(phone.map(\.groups), argv.regexHitGroups,
                       "the phone and the Mac no longer hit the same blocks")
        XCTAssertEqual(argv.regexHitCount, 2, "fixture assumption: two hits, one of them dashed")
        XCTAssertEqual(argv.regexHitGroups, [["--force"], ["ok123"]])

        // 2. The Mac turns only the safe one into buttons.
        XCTAssertEqual(argv.buttonGroupCount, 1,
                       "pervio-view stopped refusing dash-leading capture groups — "
                       + "if that is deliberate, this whole file should be rewritten")
        XCTAssertEqual(argv.buttonGroupCount, argv.rawSpanCount)
        XCTAssertEqual(argv.buttonGroups.map(\.groups), [["ok123"]])

        // 3. The phone turns BOTH into menus — the divergence, stated as a
        //    number so it cannot widen or vanish unnoticed.
        XCTAssertEqual(phone.count, 2)
        XCTAssertEqual(phone.count - argv.buttonGroupCount, 1,
                       "one rating menu exists on the phone and not on the Mac")

        // 4. …and the command it would send. Quoting makes it one word; it is
        //    still a word beginning with `--`, which is the whole point of the
        //    Mac's refusal.
        let compiled = CompiledAction.compile(argv.actions)
        let hit = try XCTUnwrap(CompiledAction.firstHit(in: "甲 [--force] 一", compiled))
        XCTAssertEqual(hit.groups, ["--force"])
        XCTAssertEqual(ActionCommand.build(run: hit.action.run, groups: hit.groups,
                                           choice: "👍"),
                       "pervio-feedback --id '--force'")
    }

    // MARK: - why the published spec is safe today

    /// The forward guard. Every capture group the SHIPPED action produces on
    /// every frozen issue is argv-safe, and the pattern itself cannot produce
    /// anything else. This is what makes the count-for-count agreement next
    /// door a fact about the spec rather than a coincidence — and it is the
    /// assertion that goes red the day a publication ships a looser regex.
    func testTheShippedActionCannotCaptureAFlagLikeGroup() throws {
        let actions = try ReportFixture.actions()

        // Every group on every real issue, checked the way the Mac checks it.
        var groups: [String] = []
        for name in ReportFixture.all {
            groups += ReportFixture.phoneHits(try ReportFixture.markdown(name), actions)
                .flatMap(\.groups)
        }
        XCTAssertEqual(groups.count, 94, "the frozen issues changed shape")
        XCTAssertTrue(groups.allSatisfy { !$0.hasPrefix("-") },
                      "a published issue produced a flag-like capture group: "
                      + (groups.first { $0.hasPrefix("-") } ?? ""))

        // And not just on these issues: the pattern is digits-and-a-dot, so no
        // input can make it capture a leading dash. Fed lines built to do
        // exactly that, it either misses or captures something safe.
        let compiled = CompiledAction.compile(actions)
        for line in ["https://arxiv.org/abs/-608.04788",
                     "https://arxiv.org/abs/--force",
                     "见 https://arxiv.org/abs/2608.04788 --rm-rf",
                     "[x](https://arxiv.org/abs/2608.04788) -n"] {
            if let hit = CompiledAction.firstHit(in: line, compiled) {
                XCTAssertTrue(hit.groups.allSatisfy { !$0.hasPrefix("-") },
                              "\(line) captured \(hit.groups)")
            }
        }
    }
}
