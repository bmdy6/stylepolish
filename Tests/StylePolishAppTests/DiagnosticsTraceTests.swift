import XCTest
import StylePolishCore
@testable import StylePolishApp

final class DiagnosticsTraceTests: XCTestCase {
    func testDefaultDropsBodyAndDebugRedactsKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = Diagnostics(directory: root)
        log.configure(debug: false, secrets: ["test-secret-key-1234"])
        var event = DiagnosticEvent(event: "capture", bundleID: "synthetic")
        event.source = "私密正文 test-secret-key-1234"
        log.record(event); log.flush()
        XCTAssertFalse(try String(contentsOf: log.url).contains("私密正文"))
        log.configure(debug: true, secrets: [])
        log.record(event); log.flush()
        let text = try String(contentsOf: log.url)
        XCTAssertTrue(text.contains("私密正文"))
        XCTAssertFalse(text.contains("test-secret-key-1234"))
    }

    func testRotationKeepsFiveBoundedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = Diagnostics(directory: root, maxFileBytes: 600)
        for _ in 0..<40 { log.record(DiagnosticEvent(event: "capture", bundleID: "synthetic", textLength: 100)) }
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 5)
        for file in files {
            XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 600)
            XCTAssertNoThrow(try String(contentsOf: file).split(separator: "\n").forEach {
                _ = try JSONSerialization.jsonObject(with: Data($0.utf8))
            })
        }
    }
}

extension DiagnosticsTraceTests {
    private func events(_ log: Diagnostics) throws -> [[String: Any]] {
        log.flush()
        return try String(contentsOf: log.url).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }
    @MainActor func testHeadlessEditorFullFlowUsesOneTraceAndNoBody() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = Diagnostics(directory: root)
        let result = try await DiagnosticsHarness.run(log: log)
        XCTAssertEqual(result.output, "我应该明天回复")
        XCTAssertEqual(result.suggestions, 1)
        let rows = try events(log)
        XCTAssertEqual(rows.compactMap { $0["event"] as? String }, ["capture", "check_started", "result", "indicator_shown", "user_action", "write"])
        XCTAssertEqual(Set(rows.compactMap { $0["traceID"] as? String }), [result.traceID])
        XCTAssertTrue(rows.last?["readbackMatches"] as? Bool == true)
        let json = try String(contentsOf: log.url)
        XCTAssertFalse(json.contains(result.source)); XCTAssertFalse(json.contains(result.output))
        for field in ["source", "output", "modelResponse"] { XCTAssertFalse(rows.contains { $0[field] != nil }) }
    }
    @MainActor func testDebugIncludesCaptureModelResponseAndWriteAndStopsImmediately() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = Diagnostics(directory: root)
        let secret = "private-credential-1234"
        log.configure(debug: true, secrets: [secret])
        let trace = DiagnosticTrace(bundleID: "synthetic", log: log)
        trace.capture(text: "原文 \(secret)", role: "AXTextArea", writable: true, selection: NSRange(location: 2, length: 0), attachment: .plain, hasPosition: true)
        var timing = RequestMetrics(); timing.modelResponse = "模型返回 \(secret)"; timing.httpStatus = 200
        trace.metrics(timing, model: "synthetic")
        trace.result(source: "原文", suggestions: [], engine: .ai, fallback: .none, unclear: false, requestMS: 1, resultMS: 1)
        trace.write(source: "原文", expected: "写回后", readback: "写回后", method: "selected_range", attachment: .plain)
        log.configure(debug: false, secrets: [])
        trace.capture(text: "关闭后正文", role: "AXTextArea", writable: true, selection: nil, attachment: .plain, hasPosition: false)
        let rows = try events(log)
        XCTAssertEqual(rows[0]["source"] as? String, "原文 [REDACTED]")
        XCTAssertEqual(rows[2]["modelResponse"] as? String, "模型返回 [REDACTED]")
        XCTAssertEqual(rows[3]["output"] as? String, "写回后")
        XCTAssertNil(rows.last?["source"])
        let json = try String(contentsOf: log.url)
        XCTAssertFalse(json.contains(secret)); XCTAssertFalse(json.contains("关闭后正文"))
    }
    @MainActor func testFailedWriteAndActionsRemainOnOriginalTrace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = Diagnostics(directory: root)
        let trace = DiagnosticTrace(bundleID: "synthetic", log: log)
        for action in ["accept_one", "ignore", "escape", "typing_invalidated"] { trace.action(action, count: 1) }
        trace.write(source: "old", expected: "new text", readback: "old", method: "clipboard", attachment: .plain)
        trace.write(source: "old", expected: "new text", readback: nil, method: "none", attachment: .unknown, error: "stale_input")
        let rows = try events(log)
        XCTAssertEqual(Set(rows.compactMap { $0["traceID"] as? String }), [trace.id])
        XCTAssertEqual(rows[4]["beforeLength"] as? Int, 3)
        XCTAssertEqual(rows[4]["afterLength"] as? Int, 3)
        XCTAssertEqual(rows[4]["expectedLength"] as? Int, 8)
        XCTAssertEqual(rows[4]["readbackMatches"] as? Bool, false)
        XCTAssertEqual(rows[4]["error"] as? String, "write_readback_mismatch")
        XCTAssertNil(rows[5]["afterLength"])
        XCTAssertEqual(rows[5]["error"] as? String, "stale_input")
    }
    func testPermissionTransitionsAreDeduplicatedInBothDirections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = Diagnostics(directory: root)
        for trusted in [false, false, true, true, false] { log.permissionChanged(trusted) }
        let rows = try events(log)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.compactMap { $0["previousTrusted"] as? Bool }, [false, true])
        XCTAssertEqual(rows.compactMap { $0["trusted"] as? Bool }, [true, false])
    }
    @MainActor func testSettingsDefaultPersistenceAndCredentialSummaryExcludeValues() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = Diagnostics(directory: root.appendingPathComponent("logs"))
        let suite = "diagnostics-" + UUID().uuidString
        let defaults = MemoryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, credentialHome: root, diagnostics: log)
        XCTAssertFalse(settings.debugMode)
        settings.debugMode = true
        try settings.saveKey("private-test-key-7788")
        settings.base = "https://example.invalid/private-endpoint"
        settings.profile = "/private/profile.md"
        settings.level = .strict
        let restored = SettingsStore(defaults: defaults, credentialHome: root, diagnostics: log)
        XCTAssertTrue(restored.debugMode)
        let summary = try JSONSerialization.data(withJSONObject: settings.diagnosticSummary)
        let summaryText = String(decoding: summary, as: UTF8.self)
        XCTAssertFalse(summaryText.contains("7788")); XCTAssertFalse(summaryText.contains("private-endpoint")); XCTAssertFalse(summaryText.contains("/private/"))
        let rows = try events(log)
        XCTAssertTrue(rows.contains { $0["setting"] as? String == "base" })
        XCTAssertTrue(rows.contains { $0["credentialSource"] as? String == "local_file" && $0["keySuffix"] as? String == "7788" })
        XCTAssertFalse(try String(contentsOf: log.url).contains("private-test-key-7788"))
    }
    @MainActor func testCaptureGateRejectsPasswordsAndDisabledApps() {
        XCTAssertFalse(DiagnosticTrace.permitsCapture(enabled: false, ordinary: true))
        XCTAssertFalse(DiagnosticTrace.permitsCapture(enabled: true, ordinary: false))
        XCTAssertTrue(DiagnosticTrace.permitsCapture(enabled: true, ordinary: true))
    }
    func testZipSnapshotContainsOnlyRecentLogsAndSafeSummary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = Diagnostics(directory: root.appendingPathComponent("logs"), maxFileBytes: 600)
        log.configure(debug: true, secrets: ["private-key-9999"])
        for _ in 0..<25 { log.record(DiagnosticEvent(event: "capture", bundleID: "synthetic", textLength: 12)) }
        // Neither arbitrary history nor credential files may be included.
        log.flush()
        try Data("private-key-9999".utf8).write(to: log.directory.appendingPathComponent("history.jsonl"))
        let zip = try log.export(to: root, summary: ["version": "test", "model": "echo-private-key-9999"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: zip.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let extracted = root.appendingPathComponent("extracted")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, extracted.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let files = FileManager.default.enumerator(at: extracted, includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" || $0.pathExtension == "json" }
        XCTAssertEqual(files.count, 6)
        XCTAssertFalse(files.contains { $0.lastPathComponent == "history.jsonl" })
        for file in files { XCTAssertFalse(try String(contentsOf: file).contains("private-key-9999")) }
    }
}

extension DiagnosticsTraceTests {
    @MainActor func testOnboardingProductionActionsKeepCheckTraceWithoutWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = Diagnostics(directory: root.appendingPathComponent("logs"))
        let suite = "trace-onboarding-" + UUID().uuidString
        let defaults = MemoryDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, credentialHome: root, diagnostics: log)
        let model = OnboardingModel(settings: settings, trusted: true)
        model.opened(); model.state.step = .trial
        await model.checkTrial()
        XCTAssertFalse(model.state.pending.isEmpty)
        model.accept(try XCTUnwrap(model.state.pending.first?.id)); model.acceptAll()
        model.closed(completed: true); model.stop()
        let rows = try events(log)
        let checkEvents = rows.filter { $0["traceID"] != nil }
        XCTAssertEqual(Set(checkEvents.compactMap { $0["traceID"] as? String }).count, 1)
        XCTAssertEqual(checkEvents.filter { $0["event"] as? String == "write" }.count, 2)
        XCTAssertEqual(checkEvents.filter { $0["event"] as? String == "user_action" }.compactMap { $0["action"] as? String }, ["accept_one", "accept_all"])
        XCTAssertEqual(rows.filter { $0["event"] as? String == "onboarding_step" }.compactMap { $0["step"] as? Int }, [2, 3])
        XCTAssertEqual(rows.last?["action"] as? String, "completed")
    }
    @MainActor func testPresentationCacheAndUnclearFallbackMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = Diagnostics(directory: root)
        let trace = DiagnosticTrace(bundleID: "synthetic", log: log)
        trace.started(engine: .ai, level: .strict, cacheHit: true)
        trace.result(source: "合成文字", suggestions: [], engine: .ai, fallback: .quota, unclear: true, requestMS: 0, resultMS: 0)
        for _ in 0..<10 { trace.presented("preview_bar", mode: "twoLine", hasPosition: false, count: 0) }
        let rows = try events(log)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0]["cacheHit"] as? Bool, true)
        XCTAssertEqual(rows[0]["level"] as? String, "strict")
        XCTAssertEqual(rows[1]["fallback"] as? String, "quota")
        XCTAssertEqual(rows[1]["unclear"] as? Bool, true)
        XCTAssertEqual(rows[2]["previewMode"] as? String, "twoLine")
        XCTAssertEqual(rows[2]["event"] as? String, "preview_shown")
    }
    func testRequestMetricsCodableNeverPersistsTransientModelBody() throws {
        var timing = RequestMetrics(); timing.modelResponse = "不应该被默认指标序列化的正文"
        let encoded = String(decoding: try JSONEncoder().encode(timing), as: UTF8.self)
        XCTAssertFalse(encoded.contains("modelResponse")); XCTAssertFalse(encoded.contains("正文"))
    }
    func testLaunchEnvironmentUsesMetadataWithoutCredentials() {
        let event = DiagnosticEnvironment.launch()
        XCTAssertEqual(event.event, "app_launch")
        XCTAssertNotNil(event.version); XCTAssertNotNil(event.commit)
        XCTAssertNotNil(event.macOS); XCTAssertNotNil(event.installationPath)
        XCTAssertTrue(["unsigned", "ad-hoc", "fixed", "unknown"].contains(event.signing ?? ""))
    }
}
