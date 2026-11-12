import StylePolishCore
import XCTest
@testable import StylePolishApp

/// Explicit paid API-only acceptance. Never initializes AppKit windows or input hooks.
final class UnclearLiveTests: XCTestCase {
    @MainActor func testClassificationThreeTimes() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["STYLEPOLISH_LIVE"] == "1", let output = env["STYLEPOLISH_UNCLEAR_RESULTS"] else {
            throw XCTSkip("Explicit paid request opt-in and results path required")
        }
        let settings = SettingsStore(defaults: RuntimeStorage.defaults)
        guard settings.credentials.current.source.hasPrefix("ai-vault · ") else { throw PolishFailure(message: "Live acceptance requires ai-vault") }
        let config = PolishConfiguration(base: settings.base, model: "gpt-6-luna", key: settings.credentials.current.key,
            profile: settings.profile, serviceTier: settings.serviceTier, level: settings.level)
        let samples: [(String, Bool)] = [
            ("13萨地方发生地方", true), ("那个就是然后的话我们三点它", true),
            ("7桌蓝所以把的昨天下", true), ("然后把那个九鱼因为去的了", true),
            ("明天下午三点开会", false), ("好的我晚点看一下", false), ("这个方案我觉得可以", false),
            ("我先跑一下 test，晚点把结果发你", false), ("OK，那我们明天再聊", false),
            ("那个 PR 我看过了，没啥问题", false)
        ]
        var records: [[String: Any]] = []
        for (input, expected) in samples {
            var passed = 0
            for run in 1...3 {
                var timing = RequestMetrics()
                var record: [String: Any] = ["input": input, "expectedUnclear": expected, "run": run,
                    "model": config.model, "serviceTier": config.serviceTier, "reasoningEffort": config.reasoningEffort ?? "default",
                    "level": config.level.rawValue]
                let start = Date()
                do {
                    let raw = try await PolishClient().polish(input, config: config, structured: true, metrics: { timing = $0 }) { _ in }
                    record["raw"] = raw
                    let result = try WholePolishResult(raw: raw, source: input)
                    record["unclear"] = result.unclear
                    // An unknown meaning must not turn into an invented rewrite.
                    let valid = result.unclear == expected && (!expected || (result.text == input && result.suggestions.isEmpty))
                    record["passed"] = valid
                    if valid { passed += 1 }
                } catch { record["error"] = error.localizedDescription; record["passed"] = false }
                record["ms"] = Int(Date().timeIntervalSince(start) * 1000)
                record["metrics"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(timing))
                records.append(record)
                try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                    .write(to: URL(fileURLWithPath: output), options: .atomic)
                print("UNCLEAR run=\(run) ms=\(record["ms"]!) passed=\(record["passed"]!)")
            }
            XCTAssertGreaterThanOrEqual(passed, expected ? 2 : 3, "Classification threshold: \(input)")
        }
    }
}
