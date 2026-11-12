import XCTest
import StylePolishCore
@testable import StylePolishApp

final class HabitsIntegrationTests: XCTestCase {
    @MainActor func testSettingsAndRealLocalModelConsumersHonorSwitchAndSuppression() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = HistoryStore(directory: root)
        let defaults = MemoryDefaults()
        let settings = SettingsStore(defaults: defaults, credentialHome: root, history: history)
        XCTAssertTrue(settings.habitsEnabled)
        func append(_ before: String, _ after: String, _ kind: SuggestionKind, _ action: SuggestionEvent.Action, count: Int) throws {
            for _ in 0..<count { try history.append(SuggestionEvent(appBundleID: "fixture", sentence: "fixture", suggestion: Suggestion(range: NSRange(location: 0, length: before.utf16.count), original: before, replacement: after, kind: kind, why: ""), action: action, level: .standard, model: "offline")) }
        }
        try append("错词", "新词", .typo, .accept, count: 2)
        try append("在", "再", .typo, .accept, count: 2)
        try append("非长好", "非常好", .typo, .ignore, count: 2)
        try append("x", "y", .tone, .ignore, count: 5)
        let runner = CheckEngine(client: PolishClient(lexiconURL: root.appendingPathComponent("absent.json")), ai: { _, _ in
            try WholePolishResult(raw: #"{"text":"非常好","edits":[{"original":"非长好","replacement":"非常好"}]}"#, source: "非长好")
        })
        var hidden = 0
        let learned = try await runner.check("错词", engine: .local, config: settings.configuration())
        XCTAssertEqual(learned.suggestions.first?.replacement, "新词")
        let validSentence = try await runner.check("我在家", engine: .local, config: settings.configuration())
        XCTAssertTrue(validSentence.suggestions.isEmpty)
        XCTAssertTrue(settings.configuration().habits.promptLines.contains { $0.contains("『再』误写成『在』") })
        for engine in [PolishEngine.local, .ai] {
            let result = try await runner.check("非长好", engine: engine, config: settings.configuration(), hidden: { edits in
                hidden += edits.count
                for edit in edits { try! history.append(SuggestionEvent(appBundleID: "fixture", sentence: "fixture", suggestion: edit, action: .hidden, level: .standard, model: "offline")) }
            })
            XCTAssertTrue(result.suggestions.isEmpty)
        }
        XCTAssertGreaterThanOrEqual(hidden, 2)
        XCTAssertEqual(history.habits.suppressed.first(where: { $0.original == "非长好" })?.count, 2, "hidden never trains")
        settings.habitsEnabled = false
        let offConfig = settings.configuration()
        XCTAssertTrue(offConfig.habits.promptLines.isEmpty)
        let offLocal = try await runner.check("错词", engine: .local, config: offConfig)
        XCTAssertTrue(offLocal.suggestions.isEmpty)
        let offAI = try await runner.check("非长好", engine: .ai, config: offConfig)
        XCTAssertEqual(offAI.suggestions.count, 1)
        try append("错词", "新词", .typo, .accept, count: 1)
        XCTAssertEqual(history.habits.typos.first?.count, 3)
        XCTAssertFalse(SettingsStore(defaults: defaults, credentialHome: root, history: history).habitsEnabled)
    }
    func testPromptUsesContextAndKindRemindersBeforeVoiceProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let voice = root.appendingPathComponent("voice.md"); try "fixture voice".write(to: voice, atomically: true, encoding: .utf8)
        var profile = HabitProfile()
        let edit = Suggestion(range: NSRange(location: 0, length: 1), original: "private-original", replacement: "private-replacement", kind: .tone, why: "")
        for _ in 0..<5 { profile.ingest(SuggestionEvent(appBundleID: "fixture", sentence: "private-sentence", suggestion: edit, action: .ignore, level: .standard, model: "offline")) }
        let single = Suggestion(range: NSRange(location: 0, length: 1), original: "在", replacement: "再", kind: .typo, why: "")
        for _ in 0..<2 { profile.ingest(SuggestionEvent(appBundleID: "fixture", sentence: "private-sentence", suggestion: single, action: .accept, level: .standard, model: "offline")) }
        var config = PolishConfiguration(base: "https://example.com/v1", model: "offline", key: "synthetic", profile: voice.path, habits: profile)
        let client = PolishClient(lexiconURL: root.appendingPathComponent("absent.json"))
        func prompt() throws -> String {
            let request = try client.makeRequest("fixture", config: config, structured: true)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            return (body["messages"] as! [[String: String]])[0]["content"]!
        }
        let on = try prompt()
        XCTAssertLessThan(try XCTUnwrap(on.range(of: "这个用户的习惯：")?.lowerBound), try XCTUnwrap(on.range(of: "口吻档案：")?.lowerBound))
        XCTAssertFalse(on.contains("private-"))
        XCTAssertTrue(on.contains("这个用户常把『再』误写成『在』，结合语境判断。"))
        config.habits = profile.effective(enabled: false)
        XCTAssertFalse(try prompt().contains("这个用户的习惯："))
    }
    @MainActor func testSuppressedRowOffersRestoreAndStopsSuppressingAfterAction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = HistoryStore(directory: root)
        let edit = Suggestion(range: NSRange(location: 0, length: 2), original: "收拾", replacement: "收尾", kind: .tone, why: "")
        for _ in 0..<2 { try history.append(SuggestionEvent(appBundleID: "fixture", sentence: "fixture", suggestion: edit, action: .ignore, level: .standard, model: "offline")) }
        let entry = try XCTUnwrap(history.habits.suppressionCandidates.first)
        let row = HabitRow(entry: entry, deleted: false) { try! history.setHabit(entry.id, deleted: true) }
        XCTAssertEqual(row.actionTitle, "恢复")
        row.toggle()
        XCTAssertFalse(history.habits.suppresses(original: "收拾", replacement: "收尾"))
    }
    func testWeeklyReportDisplayedDatesMatchSevenDayWindow() {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 12))!
        let report = HabitProfile(now: now).report(now: now)
        XCTAssertEqual(WeeklyReportView(report: report).dateRange, "11/06 – 11/12 · 微信")
    }
}
