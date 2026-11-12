import Foundation
import CryptoKit

/// Only the v2 decision fields are projected. Sentences and v1 text never enter the profile.
struct HabitRecord: Decodable {
    let ts: String, original: String, replacement: String
    let kind: SuggestionKind
    let action: SuggestionEvent.Action
    var date: Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: ts) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: ts)
    }
}

public struct HabitEntry: Identifiable, Equatable {
    public enum Group: String { case typo, suppressed, reminder }
    public let id: String, group: Group, original: String, replacement: String, kind: SuggestionKind
    public let count: Int, latest: Date, message: String
    static func id(_ parts: [String]) -> String {
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct HabitProfile {
    struct Key: Hashable { let original: String, replacement: String, kind: SuggestionKind }
    struct Pair: Hashable { let original: String, replacement: String }
    struct Count { var accept = 0, ignore = 0; var latest = Date.distantPast
        mutating func add(_ action: SuggestionEvent.Action, date: Date) {
            if action == .accept { accept += 1 } else { ignore += 1 }
            latest = max(latest, date)
        }
    }
    private var counts: [Key: Count] = [:]
    private var pairs: [Pair: Count] = [:]
    private var kinds: [SuggestionKind: Count] = [:]
    private var recent: [HabitRecord] = []
    private let loadedAt: Date
    public var excludedIDs: Set<String> = []
    public private(set) var eventCount = 0
    public private(set) var revision = 0
    public init(now: Date = Date()) { loadedAt = now }

    public mutating func ingest(line: Data) {
        guard let record = try? JSONDecoder().decode(HabitRecord.self, from: line) else { return }
        ingest(record)
    }
    public mutating func ingest(_ event: SuggestionEvent) {
        // Same tolerant projection for startup and incremental appends.
        if let line = try? JSONEncoder().encode(event) { ingest(line: line) }
    }
    private mutating func ingest(_ r: HabitRecord) {
        guard let date = r.date else { return }
        eventCount += 1
        guard r.action == .accept || r.action == .ignore else { return }
        let key = Key(original: r.original, replacement: r.replacement, kind: r.kind)
        counts[key, default: Count()].add(r.action, date: date)
        pairs[Pair(original: r.original, replacement: r.replacement), default: Count()].add(r.action, date: date)
        kinds[r.kind, default: Count()].add(r.action, date: date)
        if date >= loadedAt.addingTimeInterval(-14 * 86400) { recent.append(r) }
        revision += 1
    }
    private func sorted(_ entries: [HabitEntry]) -> [HabitEntry] {
        Array(entries.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            if $0.latest != $1.latest { return $0.latest > $1.latest }
            return $0.id < $1.id
        }.prefix(20))
    }
    private var learnedTypoCandidates: [HabitEntry] {
        counts.compactMap { key, c in
            guard key.kind == .typo, c.accept >= 2, c.ignore == 0, !key.original.isEmpty, key.original != key.replacement else { return nil }
            let needsContext = key.original.count < 2
            // Retain the existing ID so deleted habits stay deleted after reclassification.
            return HabitEntry(id: HabitEntry.id(["typo", key.original, key.replacement, key.kind.rawValue]), group: needsContext ? .reminder : .typo,
                              original: key.original, replacement: key.replacement, kind: key.kind, count: c.accept, latest: c.latest,
                              message: needsContext ? "这个用户常把『\(key.replacement)』误写成『\(key.original)』，结合语境判断。" : "")
        }
    }
    /// Candidates remain available to the settings UI for individual restore.
    public var typoCandidates: [HabitEntry] { sorted(learnedTypoCandidates.filter { $0.group == .typo }) }
    public var suppressionCandidates: [HabitEntry] {
        sorted(pairs.compactMap { key, c in
            guard c.ignore >= 2, c.accept == 0 else { return nil }
            return HabitEntry(id: HabitEntry.id(["suppressed", key.original, key.replacement]), group: .suppressed,
                              original: key.original, replacement: key.replacement, kind: .tone, count: c.ignore, latest: c.latest, message: "")
        })
    }
    public var reminderCandidates: [HabitEntry] {
        let categories: [HabitEntry] = kinds.compactMap { kind, c in
            let total = c.accept + c.ignore
            guard total >= 5, Double(c.accept) / Double(total) < 0.2 else { return nil }
            return HabitEntry(id: HabitEntry.id(["reminder", kind.rawValue]), group: .reminder, original: "", replacement: "", kind: kind,
                              count: total, latest: c.latest, message: "\(kind.title)建议你很少采纳，请谨慎提出这类建议，保留原意和口吻。")
        }
        return sorted(categories + learnedTypoCandidates.filter { $0.group == .reminder })
    }
    public var typos: [HabitEntry] { typoCandidates.filter { !excludedIDs.contains($0.id) } }
    public var suppressed: [HabitEntry] { suppressionCandidates.filter { !excludedIDs.contains($0.id) } }
    public var reminders: [HabitEntry] { reminderCandidates.filter { !excludedIDs.contains($0.id) } }
    public var learnedCount: Int { typos.count + suppressed.count + reminders.count }
    public var personalTypos: [String: String] {
        let grouped = Dictionary(grouping: typos, by: \.original)
        return grouped.compactMapValues { rows in Set(rows.map(\.replacement)).count == 1 ? rows.first?.replacement : nil }
    }
    public func suppresses(original: String, replacement: String) -> Bool {
        suppressed.contains { $0.original == original && $0.replacement == replacement }
    }
    /// Counts may change the report without changing check behavior. Keep settled
    /// text cached until the effective rules/reminders actually change.
    public var configurationID: String {
        let dictionary = personalTypos
        let pairs = dictionary.keys.sorted().flatMap { [$0, dictionary[$0]!] }
        return HabitEntry.id(pairs + suppressed.map(\.id).sorted() + promptLines.sorted())
    }
    public var promptLines: [String] { Array(reminders.map(\.message).prefix(10)) }
    public func effective(enabled: Bool) -> HabitProfile { enabled ? self : HabitProfile(now: loadedAt) }
    public func report(now: Date = Date()) -> WeeklyReport { WeeklyReport(records: recent, now: now) }
}
