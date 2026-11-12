#if DEBUG
import AppKit
import SwiftUI
import StylePolishCore

extension FixtureCapture {
    @MainActor static func captureHabits(to directory: URL) throws {
        let root = RuntimeStorage.root.appendingPathComponent("habits-fixture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        var lines = Data()
        func append(_ original: String, _ replacement: String, _ kind: String, _ action: String, _ count: Int, days: Double = 0) throws {
            for _ in 0..<count {
                let object = ["ts": ISO8601DateFormatter().string(from: now.addingTimeInterval(-days * 86400)), "original": original,
                              "replacement": replacement, "kind": kind, "action": action, "sentence": "fixture"]
                lines.append(try JSONSerialization.data(withJSONObject: object)); lines.append(0x0A)
            }
        }
        try append("在", "再", "typo", "accept", 5)
        try append("之需要", "只需要", "typo", "accept", 2)
        try append("非长", "非常", "typo", "accept", 2)
        for i in 0..<9 { try append("示例错字\(i)", "示例改字\(i)", "typo", "accept", 1) }
        try append("示例长句", "示例顺句", "fluency", "accept", 25)
        try append("示例语气", "示例语气建议", "tone", "ignore", 1)
        try append("月底1收拾", "月底收拾", "tone", "ignore", 2, days: 8)
        for i in 0..<3 { try append("其他措辞\(i)", "其他措辞建议\(i)", "tone", "ignore", 1, days: 8) }
        for i in 0..<21 { try append("上周示例\(i)", "上周修正\(i)", "typo", "accept", 1, days: 8) }
        let history = HistoryStore(directory: root)
        try lines.write(to: history.file)
        let settings = SettingsStore(defaults: MemoryDefaults(), credentialHome: root, history: HistoryStore(directory: root))
        let habits = HabitsView(settings: settings).frame(width: 560, height: 740)
        let report = WeeklyReportView(report: settings.history.habits.report(now: now)).frame(width: 720, height: 740)
        try render(habits, size: NSSize(width: 560, height: 740), to: directory.appendingPathComponent("my-habits.png"))
        try render(report, size: NSSize(width: 720, height: 740), to: directory.appendingPathComponent("weekly-report.png"))
        let comparison = HStack(alignment: .top, spacing: 40) {
            habits.clipShape(RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(HabitStyle.line))
            report.clipShape(RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(HabitStyle.line))
        }.padding(40).background(Color(red: 0.95, green: 0.94, blue: 0.91))
        try render(comparison, size: NSSize(width: 1400, height: 820), to: directory.appendingPathComponent("habits-and-weekly-report.png"))
        try render(SettingsView(settings: settings, openHistory: {}, clearHistory: {}, permission: {}, fixture: true, showingHabits: true), size: NSSize(width: 560, height: 740), to: directory.appendingPathComponent("settings-habits.png"))
        settings.habitsEnabled = false
        if let entry = settings.history.habits.typos.first { try settings.history.setHabit(entry.id, deleted: true) }
        try render(HabitsView(settings: settings), size: NSSize(width: 560, height: 740), to: directory.appendingPathComponent("habits-disabled-restore.png"))
        let empty = SettingsStore(defaults: MemoryDefaults(), credentialHome: root, history: HistoryStore(directory: root.appendingPathComponent("empty")))
        try render(HabitsView(settings: empty), size: NSSize(width: 560, height: 740), to: directory.appendingPathComponent("habits-empty.png"))
        try render(WeeklyReportView(report: empty.history.habits.report(now: now)), size: NSSize(width: 720, height: 740), to: directory.appendingPathComponent("weekly-report-empty.png"))
    }
}
#endif
