import XCTest
import StylePolishCore
@testable import StylePolishApp

final class CheckEngineTests: XCTestCase {
    let config = PolishConfiguration(base: "https://invalid.example", model: "synthetic", key: "", profile: "")
    func testLocalDoesNotInvokeTransport() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"aliases":{"错名":"术语"},"contextual_aliases":[{"term":"CAD","aliases":["c a d"]}]}"#.write(to: url, atomically: true, encoding: .utf8)
        let runner = CheckEngine(client: PolishClient(lexiconURL: url), ai: { _, _ in XCTFail("Local must not request AI"); throw URLError(.badURL) })
        let aliases = try await runner.check("错名 c a d", engine: .local, config: config)
        XCTAssertEqual(aliases.suggestions.count, 1); XCTAssertEqual(aliases.suggestions.first?.replacement, "术语")
        let result = try await runner.check("我因该在在回复，，", engine: .local, config: config)
        XCTAssertEqual(result.suggestions.count, 3); XCTAssertEqual(result.fallback, .none)
    }
    func testFailuresFallbackAndNextCheckRetriesAI() async throws {
        let cases: [(Error, FallbackReason, String)] = [
            (PolishFailure(message: "synthetic", httpStatus: 401), .key, "Key 无效"),
            (PolishFailure(message: "synthetic", httpStatus: 403), .key, "Key 无效"),
            (PolishFailure(message: "synthetic", httpStatus: 429), .quota, "额度用完"),
            (PolishFailure(message: "synthetic", httpStatus: 400, code: "insufficient_quota"), .quota, "额度用完"),
            (URLError(.timedOut), .network, "网络不通"),
            (URLError(.notConnectedToInternet), .network, "网络不通"),
            (URLError(.dnsLookupFailed), .network, "网络不通"),
            (PolishFailure(message: "synthetic", httpStatus: 500), .other, "AI 出错")]
        for (error, reason, title) in cases {
            var calls = 0
            let runner = CheckEngine(ai: { _, _ in
                calls += 1
                if calls == 1 { throw error }
                return try WholePolishResult(raw: #"{"text":"我应该回复","edits":[]}"#, source: "我应该回复")
            })
            let fallback = try await runner.check("我因该回复", engine: .ai, config: config)
            XCTAssertEqual(fallback.failureSummary, (error as? PolishFailure)?.message ?? "AI 请求失败")
            XCTAssertEqual(fallback.fallback, reason); XCTAssertEqual(fallback.suggestions.count, 1)
            XCTAssertEqual(ActivityStatus.fallback(reason).title, title)
            let success = try await runner.check("我应该回复", engine: .ai, config: config)
            XCTAssertEqual(success.fallback, .none); XCTAssertEqual(calls, 2)
        }
        XCTAssertEqual(ActivityStatus.fallback(.permission).title, "需要授权")
        XCTAssertEqual(FallbackReason.permission.menuTitle, "没有辅助功能权限 · 去授权 ›")
        XCTAssertEqual(ActivityStatus.local.title, "本地规则")
    }
    func testCancellationDoesNotFallback() async {
        let runner = CheckEngine(ai: { _, _ in throw CancellationError() })
        do { _ = try await runner.check("我因该回复", engine: .ai, config: config); XCTFail("must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testLocalRespectsSessionIgnoreAndDisabledKind() async throws {
        let result = try await CheckEngine().check("我因该回复然后然后", engine: .local, config: config, disabledKinds: ["filler"])
        XCTAssertEqual(result.suggestions.count, 1)
        var session = SuggestionSession()
        session.set(result.suggestions.filter { $0.kind != .filler }, text: "我因该回复然后然后", sentence: "我因该回复然后然后", offset: 0)
        XCTAssertEqual(session.suggestions.count, 1)
        session.ignore(session.suggestions[0].edit, sentence: "我因该回复然后然后")
        session.replaceSuggestions()
        session.set(result.suggestions.filter { $0.kind != .filler }, text: "我因该回复然后然后", sentence: "我因该回复然后然后", offset: 0)
        XCTAssertTrue(session.suggestions.isEmpty)
    }
    @MainActor func testSettingsEngineMigrationAndPersistence() throws {
        let name = UUID().uuidString
        let defaults = MemoryDefaults()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: home) }
        let first = SettingsStore(defaults: defaults, credentialHome: home)
        XCTAssertEqual(first.engine, .local)
        try first.saveKey("synthetic-test-key")
        XCTAssertEqual(SettingsStore(defaults: defaults, credentialHome: home).engine, .ai)
        first.engine = .local
        XCTAssertEqual(SettingsStore(defaults: defaults, credentialHome: home).engine, .local)
    }
    func testOfflineHarnessDiagnostics() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = Diagnostics(directory: dir)
        let result = try await CheckEngine().check("我因该明天在在给你回复，，文件以经发了", engine: .local, config: config)
        log.record(DiagnosticEvent(event: "result", bundleID: "offline-harness", textLength: 23, engine: "local", fallback: result.fallback))
        log.flush()
        let value = try String(contentsOf: log.url)
        XCTAssertFalse(value.contains("因该")); XCTAssertTrue(value.contains("local")); XCTAssertEqual(result.suggestions.count, 4)
        print("Offline local harness: " + value)
    }
}
