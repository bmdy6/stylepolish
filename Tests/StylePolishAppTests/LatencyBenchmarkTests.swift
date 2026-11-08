import XCTest
import StylePolishCore
@testable import StylePolishApp

/// Explicit paid, read-only harness. Synthetic inputs only; never touches another app.
final class LatencyBenchmarkTests: XCTestCase {
    @MainActor func testBenchmark() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["STYLEPOLISH_BENCHMARK_OUTPUT"] else { throw XCTSkip("Explicit paid benchmark opt-in required") }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "org.bmdy6.StylePolish")!)
        var config = PolishConfiguration(base: settings.base, model: settings.model, key: settings.credentials.current.key, profile: settings.profile, serviceTier: settings.serviceTier)
        if env["STYLEPOLISH_BENCHMARK_DEFAULT_EFFORT"] == "1" { config.reasoningEffort = nil }
        let samples = [
            "这个方案非长好，我们明天在讨论。",
            "我以经把资料发给你了，麻烦查收一下。",
            "这个问题的话，就是我们需要先确认一下原因。",
            "请在周五前完成 API v2 验证，预算是 300 元。",
            "我觉得可以先试一周，再决定要不要继续。",
            "这个方案非长好，我们明天在讨论。我以经把资料发给你了，麻烦查收一下。这个问题的话，就是我们需要先确认一下原因。请在周五前完成 API v2 验证，预算是 300 元。我觉得可以先试一周，再决定要不要继续。今天先把测试结果整理好，明天开会的时候一起看，有不确定的地方就直接标出来，不用着急下结论。"
            ,"这次要确认的是这个书架如何固定。",
            "通过这次讨论，使我明白了问题的原因。",
            "我们需要提高这个问题的解决效率和成本。",
            "小王告诉小李，他的方案需要修改。",
            "对于这个方案能不能在明天之前把它完成这件事，我想知道一下。"
        ]
        let url = URL(fileURLWithPath: output)
        FileManager.default.createFile(atPath: output, contents: nil)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        for run in 1...3 {
            for (index, sample) in samples.enumerated() {
                let start = Date()
                var records: [[String: Any]] = []
                for sentence in Sentence.split(sample) {
                    var timing = RequestMetrics()
                    let sentenceStart = Date()
                    var firstSuggestionMS: Int?
                    let edits = try await PolishClient().suggestions(sentence.text, config: config, metrics: { timing = $0 }, update: { edits in
                        if !edits.isEmpty && firstSuggestionMS == nil { firstSuggestionMS = Int(Date().timeIntervalSince(sentenceStart) * 1000) }
                    })
                    let raw = "(see parsed suggestions)"
                    records.append(["input": sentence.text, "metrics": try JSONSerialization.jsonObject(with: JSONEncoder().encode(timing)), "raw": raw, "firstSuggestionMS": firstSuggestionMS as Any? ?? NSNull(), "suggestions": edits.map { ["original": $0.original, "replacement": $0.replacement, "kind": $0.kind.rawValue] }])
                }
                let record: [String: Any] = ["run": run, "sample": index + 1, "input": sample, "totalMS": Int(Date().timeIntervalSince(start) * 1000), "requests": records]
                try handle.write(contentsOf: JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])); try handle.write(contentsOf: Data([10]))
                print("BENCH sample=\(index+1) run=\(run) ms=\(record["totalMS"]!)")
            }
        }
    }
}
