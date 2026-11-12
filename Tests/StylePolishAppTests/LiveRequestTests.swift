import XCTest
import StylePolishCore
@testable import StylePolishApp

private protocol EvaluationResult {
    var text: String { get }
    var suggestions: [Suggestion] { get }
    var isRewrite: Bool { get }
    var unclear: Bool { get }
}
extension WholePolishResult: EvaluationResult {}
extension PlainTextCandidateResult: EvaluationResult { var unclear: Bool { false } }

private func evaluate(_ raw: String, source: String, scheme: String) throws -> any EvaluationResult {
    if scheme == "B" { return try PlainTextCandidateResult(output: raw, source: source) }
    return try WholePolishResult(raw: raw, source: source)
}

/// Only synthetic smoke inputs live in the repository. Private evaluation sets
/// are explicitly loaded from an external task directory and never bundled.
private struct LiveCase: Decodable {
    let id: String
    let input: String
    var exact: String? = nil
    var containsAll: [String]? = nil
    var containsAny: [String]? = nil
    var forbids: [String]? = nil
    var counts: [String: Int]? = nil
    var rewrite: Bool? = nil
    var minSuggestions: Int? = nil
    var unclear: Bool? = nil

    func failures(for result: any EvaluationResult) -> [String] {
        var failures: [String] = []
        let text = result.text.lowercased()
        if let exact, text != exact.lowercased() { failures.append("exact output differs") }
        for word in containsAll ?? [] where !text.contains(word.lowercased()) { failures.append("missing required fragment: " + word) }
        if let containsAny, !containsAny.contains(where: { text.contains($0.lowercased()) }) { failures.append("no accepted alternative") }
        for word in forbids ?? [] where text.contains(word.lowercased()) { failures.append("forbidden fragment: " + word) }
        for (word, count) in counts ?? [:] where text.components(separatedBy: word.lowercased()).count - 1 != count { failures.append("wrong occurrence count: " + word) }
        if result.unclear != (unclear ?? false) { failures.append("wrong unclear classification") }
        if let rewrite, result.isRewrite != rewrite { failures.append("wrong routing") }
        if let minSuggestions, result.suggestions.count < minSuggestions { failures.append("too few suggestions") }
        return failures
    }
}

final class LiveRequestTests: XCTestCase {
    @MainActor private func run(_ cases: [LiveCase]) async throws {
        let settings = SettingsStore(defaults: RuntimeStorage.defaults)
        guard settings.credentials.current.source.hasPrefix("ai-vault · ") else { throw PolishFailure(message: "Live acceptance requires ai-vault") }
        var config = PolishConfiguration(base: settings.base, model: settings.model, key: settings.credentials.current.key, profile: settings.profile, serviceTier: settings.serviceTier, level: settings.level)
        let env = ProcessInfo.processInfo.environment
        let scheme = env["STYLEPOLISH_SCHEME"] ?? "A"
        guard ["A", "B"].contains(scheme) else { throw PolishFailure(message: "Invalid evaluation scheme") }
        var client = PolishClient()
        if scheme == "B" || env["STYLEPOLISH_PROMPT_DIRECTORY"] != nil {
            guard let path = env["STYLEPOLISH_PROMPT_DIRECTORY"] else { throw XCTSkip("B requires frozen external prompts") }
            let directory = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            guard !directory.path.hasPrefix(repository.path + "/"), directory != repository else { throw XCTSkip("Experimental prompts must be external") }
            client.promptDirectory = directory
        }
        if let effort = env["STYLEPOLISH_EFFORT"] {
            guard ["none", "low", "minimal"].contains(effort) else { throw PolishFailure(message: "Invalid evaluation effort") }
            config.reasoningEffort = effort
        }
        let repetitions = min(3, max(1, Int(env["STYLEPOLISH_REPETITIONS"] ?? "1") ?? 1))
        var records: [[String: Any]] = []
        for repetition in 1...repetitions {
            for sample in cases {
                var timing = RequestMetrics()
                let start = Date()
                var record: [String: Any] = ["id": sample.id, "scheme": scheme, "repetition": repetition, "input": sample.input, "model": config.model, "serviceTier": config.serviceTier, "reasoningEffort": config.reasoningEffort ?? "default"]
                do {
                    let raw = try await client.polish(sample.input, config: config, structured: scheme == "A", metrics: { timing = $0 }) { _ in }
                    record["raw"] = raw
                    let result = try evaluate(raw, source: sample.input, scheme: scheme)
                    let failures = sample.failures(for: result)
                    record.merge(["raw": raw, "unclear": result.unclear, "output": result.text, "rewrite": result.isRewrite, "suggestions": result.suggestions.map { ["original": $0.original, "replacement": $0.replacement] }, "failures": failures, "passed": failures.isEmpty, "firstTokenMS": timing.firstTokenMS ?? -1]) { _, new in new }
                } catch {
                    if let failure = error as? PolishFailure {
                        record["httpStatus"] = failure.httpStatus
                        record["errorCode"] = failure.code
                        record["parameter"] = failure.parameter
                        record["detail"] = failure.detail
                    }
                    record["passed"] = false
                    record["failures"] = [error.localizedDescription]
                }
                record["reasoningTokens"] = timing.reasoningTokens
                record["completionTokens"] = timing.completionTokens
                record["ms"] = Int(Date().timeIntervalSince(start) * 1000)
                records.append(record)
                if let path = ProcessInfo.processInfo.environment["STYLEPOLISH_RESULTS"] {
                    try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: URL(fileURLWithPath: path))
                }
                print("LIVE case=\(sample.id) ms=\(record["ms"]!) passed=\(record["passed"]!)")
            }
        }
        XCTAssertTrue(records.allSatisfy { $0["passed"] as? Bool == true }, "Live evaluation failures are recorded in the external results file")
    }

    /// Revalidate captured model responses after parser-only boundary fixes,
    /// without another paid request or storing private inputs in the repository.
    func testExternalResponseReplay() throws {
        guard let path = ProcessInfo.processInfo.environment["STYLEPOLISH_REPLAY_RESULTS"] else { throw XCTSkip("External response replay opt-in required") }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard !url.path.hasPrefix(repository.path + "/") else { throw XCTSkip("Captured responses must live outside the repository") }
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        var replayed = 0
        for record in records {
            guard let raw = record["raw"] as? String, let input = record["input"] as? String else { continue }
            let result = try evaluate(raw, source: input, scheme: record["scheme"] as? String ?? "A")
            XCTAssertEqual(result.text, record["output"] as? String)
            XCTAssertEqual(result.unclear, record["unclear"] as? Bool ?? false)
            XCTAssertEqual(result.isRewrite, record["rewrite"] as? Bool)
            XCTAssertEqual(result.suggestions.map { ["original": $0.original, "replacement": $0.replacement] }, record["suggestions"] as? [[String: String]])
            replayed += 1
        }
        XCTAssertGreaterThan(replayed, 0)
        print("Replayed captured responses: \(replayed)")
    }

    @MainActor func testSyntheticCases() async throws {
        guard ProcessInfo.processInfo.environment["STYLEPOLISH_LIVE"] == "1" else { throw XCTSkip("Explicit paid request opt-in required") }
        try await run([
            LiveCase(id: "synthetic-typo", input: "我以经订好明天的车票了", containsAll: ["已经"], forbids: ["以经"], rewrite: false, minSuggestions: 1),
            LiveCase(id: "synthetic-clean", input: "电池充好后，把充电器收进抽屉", exact: "电池充好后，把充电器收进抽屉", rewrite: false)
        ])
    }

    @MainActor func testExternalEvaluationCases() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["STYLEPOLISH_LIVE"] == "1", let path = env["STYLEPOLISH_LIVE_CASES"] else { throw XCTSkip("Explicit paid request opt-in and external case file required") }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        guard !url.path.hasPrefix(repository.path + "/") else { throw XCTSkip("Private evaluation cases must live outside the repository") }
        let cases = try JSONDecoder().decode([LiveCase].self, from: Data(contentsOf: url))
        XCTAssertFalse(cases.isEmpty)
        try await run(cases)
    }
}
