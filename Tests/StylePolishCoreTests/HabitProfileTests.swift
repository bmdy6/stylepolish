import XCTest
@testable import StylePolishCore

final class HabitProfileTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-11-12T12:00:00Z")!
    func event(_ action: String = "accept", original: String = "非长", replacement: String = "非常", kind: String = "typo", days: Double = 0) -> Data {
        let object: [String: Any] = ["ts": ISO8601DateFormatter().string(from: now.addingTimeInterval(-days * 86400)),
            "sentence": "synthetic", "original": original, "replacement": replacement, "kind": kind, "action": action,
            "unknown_future_field": true]
        return try! JSONSerialization.data(withJSONObject: object)
    }
    func testSmallSamplesConflictsAndNonDecisions() {
        var p = HabitProfile(now: now)
        p.ingest(line: event()); XCTAssertTrue(p.personalTypos.isEmpty)
        p.ingest(line: event()); XCTAssertEqual(p.personalTypos["非长"], "非常")
        for _ in 0..<10 { p.ingest(line: event("expired")); p.ingest(line: event("hidden")) }
        XCTAssertEqual(p.personalTypos["非长"], "非常")
        XCTAssertEqual(p.report(now: now).accepted, 2)
        p.ingest(line: event("ignore")); XCTAssertTrue(p.personalTypos.isEmpty)
    }
    func testSuppressionAcrossKindsAndConflict() {
        var p = HabitProfile(now: now)
        p.ingest(line: event("ignore", kind: "tone"))
        XCTAssertFalse(p.suppresses(original: "非长", replacement: "非常"))
        p.ingest(line: event("ignore", kind: "fluency"))
        XCTAssertTrue(p.suppresses(original: "非长", replacement: "非常"))
        p.ingest(line: event()); XCTAssertFalse(p.suppresses(original: "非长", replacement: "非常"))
    }
    func testSingleCharacterTyposBecomeContextRemindersAndCanBeDeleted() throws {
        for original in ["在", "𠮷", "e\u{301}", "👨‍👩‍👧‍👦"] {
            var p = HabitProfile(now: now)
            p.ingest(line: event(original: original, replacement: "再"))
            XCTAssertTrue(p.promptLines.isEmpty)
            p.ingest(line: event(original: original, replacement: "再"))
            XCTAssertTrue(p.personalTypos.isEmpty, original)
            XCTAssertTrue(p.typoCandidates.isEmpty, original)
            let reminder = try XCTUnwrap(p.reminderCandidates.first)
            XCTAssertEqual(reminder.group, .reminder)
            XCTAssertEqual(p.promptLines, ["这个用户常把『再』误写成『\(original)』，结合语境判断。"])
            XCTAssertEqual(p.learnedCount, 1)
            XCTAssertTrue(LocalRules.check("我在家", level: .standard, personalTypos: p.personalTypos).isEmpty)
            let learned = p.configurationID
            p.excludedIDs.insert(reminder.id)
            XCTAssertTrue(p.promptLines.isEmpty)
            XCTAssertNotEqual(p.configurationID, learned)
            XCTAssertEqual(p.reminderCandidates.first?.id, reminder.id)
            p.excludedIDs.remove(reminder.id)
            XCTAssertEqual(p.configurationID, learned)
            XCTAssertTrue(p.effective(enabled: false).promptLines.isEmpty)
            p.ingest(line: event("ignore", original: original, replacement: "再"))
            XCTAssertTrue(p.promptLines.isEmpty, "Conflicted single-character habits must not train")
        }
    }
    func testCharacterRemindersShareTenLineLimitWithKindReminders() {
        var p = HabitProfile(now: now)
        for scalar in "在的做象那他她它着得地再" {
            for _ in 0..<2 { p.ingest(line: event(original: String(scalar), replacement: "改")) }
        }
        for _ in 0..<5 { p.ingest(line: event("ignore", kind: "tone")) }
        XCTAssertEqual(p.reminderCandidates.count, 13)
        XCTAssertEqual(p.promptLines.count, 10)
        XCTAssertTrue(p.promptLines.contains { $0.contains(SuggestionKind.tone.title) })
        XCTAssertTrue(p.personalTypos.isEmpty)
    }
    func testWeeklyReportIncludesSevenLocalDatesWithAdjacentPreviousWindow() {
        let calendar = Calendar.current
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12))!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6))!
        let previous = calendar.date(byAdding: .day, value: -7, to: start)!
        var p = HabitProfile(now: today)
        func append(at date: Date) {
            let object = ["ts": ISO8601DateFormatter().string(from: date), "original": "非长", "replacement": "非常", "kind": "typo", "action": "accept"]
            p.ingest(line: try! JSONSerialization.data(withJSONObject: object))
        }
        for date in [previous.addingTimeInterval(-1), previous, start.addingTimeInterval(-1), start, today, today.addingTimeInterval(1)] { append(at: date) }
        let report = p.report(now: today)
        XCTAssertEqual(report.start, start)
        XCTAssertEqual(report.end, today)
        XCTAssertEqual(report.accepted, 2)
        XCTAssertEqual(report.currentTypos, 2)
        XCTAssertEqual(report.previousTypos, 2)
        XCTAssertEqual(report.typoDelta, 0)
        XCTAssertEqual(calendar.dateComponents([.day], from: report.start, to: calendar.startOfDay(for: today)).day, 6)
    }
    func testRemindersNeedFiveAndStrictlyBelowTwentyPercent() {
        var p = HabitProfile(now: now)
        for _ in 0..<4 { p.ingest(line: event("ignore", kind: "tone")) }
        XCTAssertTrue(p.reminders.isEmpty)
        p.ingest(line: event("accept", kind: "tone")); XCTAssertTrue(p.reminders.isEmpty)
        p.ingest(line: event("ignore", kind: "tone")); XCTAssertEqual(p.reminders.count, 1)
        XCTAssertLessThanOrEqual(p.promptLines.count, 10)
    }
    func testMixedHistorySkipsV1BadAndUnknownEnums() {
        var p = HabitProfile(now: now)
        for line in [Data("bad".utf8), Data(#"{"input":"x","output":"y","action":"accept"}"#.utf8), event("future"), event(kind: "future")] { p.ingest(line: line) }
        XCTAssertEqual(p.eventCount, 0)
        p.ingest(line: event()); XCTAssertEqual(p.eventCount, 1)
    }
    func testDeleteRestoreAndDisableAllThreeEffects() throws {
        var p = HabitProfile(now: now)
        for _ in 0..<2 { p.ingest(line: event()) }
        for _ in 0..<5 { p.ingest(line: event("ignore", original: "收拾", replacement: "收尾", kind: "tone")) }
        let id = try XCTUnwrap(p.typos.first?.id)
        p.excludedIDs.insert(id); XCTAssertTrue(p.personalTypos.isEmpty)
        p.excludedIDs.remove(id); XCTAssertEqual(p.personalTypos.count, 1)
        let off = p.effective(enabled: false)
        XCTAssertTrue(off.personalTypos.isEmpty); XCTAssertTrue(off.promptLines.isEmpty)
        XCTAssertFalse(off.suppresses(original: "收拾", replacement: "收尾"))
        XCTAssertEqual(p.report(now: now).ignored, 5, "Turning learning off must not clear reporting")
    }
    func testCapsCountsThenRecencyAndAmbiguousReplacement() {
        var p = HabitProfile(now: now)
        for i in 0..<25 { for _ in 0..<2 { p.ingest(line: event(original: "错\(i)", replacement: "对\(i)", days: Double(i))) } }
        XCTAssertEqual(p.typos.count, 20); XCTAssertEqual(p.typos.first?.original, "错0")
        for _ in 0..<2 { p.ingest(line: event(original: "错0", replacement: "另一个")) }
        XCTAssertNil(p.personalTypos["错0"], "Conflicting replacements must not arbitrarily become offline rules")
    }
    func testCheckCacheChangesOnlyWhenEffectiveHabitsChange() {
        var p = HabitProfile(now: now)
        let empty = p.configurationID
        p.ingest(line: event()); XCTAssertEqual(p.configurationID, empty)
        p.ingest(line: event()); XCTAssertNotEqual(p.configurationID, empty)
        let learned = p.configurationID
        p.ingest(line: event()); XCTAssertEqual(p.configurationID, learned)
        p.ingest(line: event("hidden")); XCTAssertEqual(p.configurationID, learned)
        p.excludedIDs.insert(p.typos[0].id); XCTAssertEqual(p.configurationID, empty)
    }
    func testReportExcludesOlderDatesAndFutureEventsAndProvidesLocalTips() {
        var p = HabitProfile(now: now)
        p.ingest(line: event(days: 6)); p.ingest(line: event("ignore", days: 0))
        p.ingest(line: event(days: 13)); p.ingest(line: event(days: 14.1))
        p.ingest(line: event(days: -1))
        let r = p.report(now: now)
        XCTAssertEqual(r.accepted, 1); XCTAssertEqual(r.ignored, 1)
        XCTAssertEqual(r.previousTypos, 1); XCTAssertEqual(r.typoDelta, 0)
        XCTAssertEqual(r.acceptanceRate, 0.5); XCTAssertTrue(r.smallSample)
        XCTAssertTrue(r.nextWeekTip.contains("非长"))
        for pair in [("在", "再"), ("的", "得"), ("做", "作"), ("象", "像"), ("那", "哪")] {
            XCTAssertNotNil(WeeklyReport.tip(original: pair.0, replacement: pair.1))
        }
    }
}
