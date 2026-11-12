import XCTest
import StylePolishCore
@testable import StylePolishApp

final class ProgressiveCheckTests: XCTestCase {
    private let source = "我因该回复"
    private let config = PolishConfiguration(base: "https://invalid.example", model: "synthetic", key: "", profile: "")

    @MainActor func testAIAndInvitePublishLocalBeforeTransportThenReplaceWithoutDuplicates() async throws {
        for engine in [PolishEngine.ai, .invite] {
            var displayed: [Suggestion] = []
            let runner = CheckEngine(ai: { text, _ in
                await MainActor.run {
                    XCTAssertEqual(displayed.map(\.original), ["因该"], "Local must be visible before AI begins")
                }
                return try WholePolishResult(raw: #"{"text":"我应该答复","edits":[]}"#, source: text)
            })
            let result = try await runner.check(source, engine: engine, config: config, progress: { displayed = $0 })
            displayed = result.suggestions
            XCTAssertEqual(displayed.count, 1)
            XCTAssertEqual(displayed[0].replacement, "我应该答复")
            XCTAssertEqual(result.fallback, .none)
        }
    }
    @MainActor func testFailureKeepsSameLocalSnapshotAndFallbackReason() async throws {
        for engine in [PolishEngine.ai, .invite] {
            var displayed: [Suggestion] = []
            let runner = CheckEngine(ai: { _, _ in throw URLError(.timedOut) })
            let result = try await runner.check(source, engine: engine, config: config, progress: { displayed = $0 })
            XCTAssertEqual(displayed, result.suggestions, "Keep IDs and content on failure")
            XCTAssertEqual(result.fallback, .network)
        }
    }
    @MainActor func testCleanAIResultRemovesProvisionalLocalAndDisabledKindsStayHidden() async throws {
        let runner = CheckEngine(ai: { text, _ in
            try WholePolishResult(raw: #"{"text":"我因该回复","edits":[]}"#, source: text)
        })
        var displayed: [Suggestion] = []
        let result = try await runner.check(source, engine: .ai, config: config, progress: { displayed = $0 })
        XCTAssertEqual(displayed.count, 1)
        displayed = result.suggestions
        XCTAssertTrue(displayed.isEmpty)
        _ = try await runner.check(source, engine: .ai, config: config, disabledKinds: ["typo"], progress: { XCTAssertTrue($0.isEmpty) })
    }
    @MainActor func testCancelledNoncooperativeAIHasNoRemainingLocalResult() async throws {
        var displayed: [Suggestion] = []
        var response: CheckedContinuation<WholePolishResult, Never>?
        let started = expectation(description: "transport suspended after local publication")
        let runner = CheckEngine(ai: { _, _ in
            await withCheckedContinuation { continuation in
                response = continuation
                started.fulfill()
            }
        })
        let request = Task {
            try await runner.check(source, engine: .ai, config: config, progress: { displayed = $0 })
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(displayed.count, 1)
        request.cancel()
        response?.resume(returning: try WholePolishResult(raw: #"{"text":"我应该回复","edits":[]}"#, source: source))
        do { _ = try await request.value; XCTFail("Must cancel") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(displayed.isEmpty)
    }
}

@MainActor private final class SuspendedAI {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<WholePolishResult, Error>?
    init(_ started: XCTestExpectation) { self.started = started }
    func result(_ text: String) async throws -> WholePolishResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func finish(_ result: Result<WholePolishResult, Error>) { continuation?.resume(with: result); continuation = nil }
}

extension ProgressiveCheckTests {
    @MainActor private func trial(_ ai: SuspendedAI, text: String = "我因该回复") -> OnboardingModel {
        let settings = SettingsStore(defaults: MemoryDefaults(), credentialHome: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        settings.engine = .ai
        let model = OnboardingModel(settings: settings, trusted: true)
        model.state.engine = .ai; model.state.text = text
        model.checkEngine = CheckEngine(ai: { text, _ in try await ai.result(text) })
        return model
    }
    @MainActor func testTrialPublishesWhileWaitingThenAIReplacesOrFailureRetains() async throws {
        for fail in [false, true] {
            let started = expectation(description: "trial AI waiting")
            let ai = SuspendedAI(started)
            let model = trial(ai)
            defer { model.stop() }
            let task = Task { await model.checkTrial() }
            await fulfillment(of: [started], timeout: 2)
            XCTAssertTrue(model.state.checking)
            XCTAssertFalse(model.state.didCheck)
            let provisional = model.state.pending
            XCTAssertEqual(provisional.map(\.original), ["因该"])
            if fail { ai.finish(.failure(URLError(.timedOut))) }
            else { ai.finish(.success(try WholePolishResult(raw: #"{"text":"我应该答复","edits":[]}"#, source: source))) }
            await task.value
            XCTAssertFalse(model.state.checking)
            XCTAssertTrue(model.state.didCheck)
            if fail { XCTAssertEqual(model.state.pending, provisional); XCTAssertTrue(model.message.contains("网络不通")) }
            else { XCTAssertEqual(model.state.pending.count, 1); XCTAssertEqual(model.state.pending.first?.replacement, "我应该答复") }
        }
    }
    @MainActor func testTrialStopClearsImmediatelyAndLateResponseCannotResurrect() async throws {
        let started = expectation(description: "trial AI waiting")
        let ai = SuspendedAI(started)
        let model = trial(ai)
        let task = Task { await model.checkTrial() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(model.state.pending.isEmpty)
        model.stop()
        XCTAssertTrue(model.state.pending.isEmpty)
        XCTAssertFalse(model.state.checking)
        ai.finish(.success(try WholePolishResult(raw: #"{"text":"我应该回复","edits":[]}"#, source: source)))
        await task.value
        XCTAssertTrue(model.state.pending.isEmpty)
    }
    @MainActor func testTrialTypingInvalidatesLocalAndLateResponseCannotOverwriteNewCheck() async throws {
        let started = expectation(description: "old request waiting")
        let ai = SuspendedAI(started)
        let model = trial(ai)
        defer { model.stop() }
        let task = Task { await model.checkTrial() }
        await fulfillment(of: [started], timeout: 2)
        model.edited("收到")
        XCTAssertTrue(model.state.pending.isEmpty)
        model.state.engine = .local
        await model.checkTrial()
        ai.finish(.failure(URLError(.timedOut)))
        await task.value
        XCTAssertEqual(model.state.text, "收到")
        XCTAssertTrue(model.state.pending.isEmpty)
        XCTAssertTrue(model.message.isEmpty, "Old fallback must not overwrite the new check")
    }
    @MainActor func testTrialCannotAcceptAdviceButCanStillApplyConcreteDeletion() async throws {
        let started = XCTestExpectation(description: "unused transport")
        let model = trial(SuspendedAI(started), text: String(repeating: "文", count: 26))
        defer { model.stop() }
        model.state.engine = .local; model.settings.level = .strict
        await model.checkTrial()
        let hint = try XCTUnwrap(model.state.pending.first)
        XCTAssertFalse(hint.canApply)
        model.accept(hint.id); model.acceptAll()
        XCTAssertEqual(model.state.text, String(repeating: "文", count: 26))
        XCTAssertEqual(model.state.pending.map(\.id), [hint.id])
        model.state.text = "买点水果啥的"
        await model.checkTrial()
        let deletion = try XCTUnwrap(model.state.pending.first)
        XCTAssertTrue(deletion.canApply)
        model.accept(deletion.id)
        XCTAssertEqual(model.state.text, "买点水果")
    }
}
