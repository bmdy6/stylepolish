#if DEBUG
import Foundation
import StylePolishCore

/// Explicitly opt-in, offline and copy-only. Detailed output stays in a private temporary file.
enum HabitsHarness {
    static func run(copy: String, output: String) throws {
        let input = URL(fileURLWithPath: copy).resolvingSymlinksInPath()
        let destination = URL(fileURLWithPath: output).resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        guard input.path.hasPrefix(temporary), destination.path.hasPrefix(temporary), input != destination else {
            throw CocoaError(.fileReadNoPermission)
        }
        let data = try Data(contentsOf: input)
        var profile = HabitProfile()
        let lines = data.split(separator: 0x0A)
        for line in lines { profile.ingest(line: Data(line)) }
        let report = profile.report()
        func rows(_ entries: [HabitEntry]) -> [[String: Any]] {
            entries.map { ["original": $0.original, "replacement": $0.replacement, "kind": $0.kind.rawValue, "count": $0.count, "message": $0.message] }
        }
        let stats: [String: Any] = ["lines": lines.count, "v2Events": profile.eventCount, "skipped": lines.count - profile.eventCount,
            "learnedTypos": profile.typos.count, "suppressedPairs": profile.suppressed.count, "reminders": profile.reminders.count,
            "accepted": report.accepted, "ignored": report.ignored, "acceptanceRate": report.acceptanceRate,
            "currentTypos": report.currentTypos, "previousTypos": report.previousTypos, "typoDelta": report.typoDelta,
            "smallSample": report.smallSample, "frequentEntries": report.frequent.count,
            "byKind": Dictionary(uniqueKeysWithValues: report.byKind.map { ($0.kind.rawValue, $0.count) })]
        let details: [String: Any] = ["statistics": stats, "typos": rows(profile.typos), "suppressed": rows(profile.suppressed), "reminders": rows(profile.reminders),
            "topMistakes": report.frequent.map { ["original": $0.original, "replacement": $0.replacement, "count": $0.count] as [String: Any] }, "nextWeekTip": report.nextWeekTip]
        guard !FileManager.default.fileExists(atPath: destination.path),
              FileManager.default.createFile(atPath: destination.path, contents: try JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys]), attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        print(String(decoding: try JSONSerialization.data(withJSONObject: stats, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
#endif
