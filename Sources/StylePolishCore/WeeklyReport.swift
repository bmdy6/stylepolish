import Foundation

public struct WeeklyReport {
    public struct KindCount: Identifiable { public var id: String { kind.rawValue }; public let kind: SuggestionKind, count: Int }
    public struct Frequent: Identifiable { public var id: String { HabitEntry.id([original, replacement]) }; public let original: String, replacement: String; public let count: Int }
    public let start: Date, end: Date
    public let accepted: Int, ignored: Int, previousTypos: Int, currentTypos: Int
    public let byKind: [KindCount], frequent: [Frequent]
    public var acceptanceRate: Double { accepted + ignored == 0 ? 0 : Double(accepted) / Double(accepted + ignored) }
    public var smallSample: Bool { accepted + ignored < 5 }
    public var typoDelta: Int { currentTypos - previousTypos }
    public var nextWeekTip: String {
        guard let first = frequent.first else { return "暂时没有反复出现的错字" }
        let pair = "「\(first.original) → \(first.replacement)」"
        return Self.tip(original: first.original, replacement: first.replacement).map { pair + "——" + $0 } ?? pair
    }
    init(records: [HabitRecord], now: Date) {
        let calendar = Calendar.current
        // Today and the six preceding local dates; the comparison window is adjacent.
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!
        end = now; self.start = start
        let previous = calendar.date(byAdding: .day, value: -7, to: start)!
        let current = records.filter { r in r.date.map { $0 >= start && $0 <= now } ?? false }
        accepted = current.filter { $0.action == .accept }.count
        ignored = current.filter { $0.action == .ignore }.count
        // Count confirmed typo corrections, matching the accepted-type bars and top mistakes.
        let typos = current.filter { $0.kind == .typo && $0.action == .accept }
        currentTypos = typos.count
        previousTypos = records.filter { r in r.kind == .typo && r.action == .accept && (r.date.map { $0 >= previous && $0 < start } ?? false) }.count
        byKind = SuggestionKind.allCases.map { kind in KindCount(kind: kind, count: current.filter { $0.kind == kind && $0.action == .accept }.count) }.sorted {
            $0.count == $1.count ? $0.kind.rawValue < $1.kind.rawValue : $0.count > $1.count
        }
        let groups = Dictionary(grouping: typos, by: { HabitProfile.Pair(original: $0.original, replacement: $0.replacement) })
        let ranked: [Frequent] = groups.map { pair, values in
            Frequent(original: pair.original, replacement: pair.replacement, count: values.count)
        }
        frequent = Array(ranked.sorted { left, right in
            if left.count != right.count { return left.count > right.count }
            return left.id < right.id
        }.prefix(3))
    }
    private static let tips: [String: String] = {
        let url = Bundle.main.url(forResource: "habit-tips", withExtension: "json") ?? Bundle.module.url(forResource: "habit-tips", withExtension: "json")
        guard let url, let data = try? Data(contentsOf: url), let tips = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return tips
    }()
    public static func tip(original: String, replacement: String) -> String? { tips[original + "/" + replacement] }
}
