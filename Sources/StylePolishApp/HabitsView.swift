import SwiftUI
import StylePolishCore

/// Shared by settings and offscreen fixtures; no history or model work happens in the view.
struct HabitsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("我的习惯").font(.system(size: 22, weight: .bold))
                    Text("只根据本机记录整理，不上传；清空记录会一起清空").font(.system(size: 13)).foregroundColor(HabitStyle.secondary)
                }
                Spacer(minLength: 8)
                Toggle("根据我的记录调整建议", isOn: $settings.habitsEnabled)
                    .labelsHidden().toggleStyle(HabitToggleStyle())
                    .accessibilityLabel("根据我的记录调整建议")
            }
            Text("根据我的记录调整建议 · 已学到 \(settings.history.habits.learnedCount) 条")
                .font(.system(size: 13)).foregroundColor(HabitStyle.secondary)
            if !settings.habitsEnabled {
                Text("已暂停调整建议，记录照常保存。")
                    .font(.system(size: 13)).foregroundColor(HabitStyle.secondary)
            }
            group("常写错（直接在本地标出，不等模型）", entries: settings.history.habits.typoCandidates)
            group("不想被改（以后不再提示）", entries: settings.history.habits.suppressionCandidates)
            group("提醒模型注意", entries: settings.history.habits.reminderCandidates)
            if let error { Text(error).font(.system(size: 12)).foregroundColor(.red) }
            Spacer(minLength: 0)
        }.padding(30).foregroundColor(HabitStyle.ink).background(.white)
    }
    private func group(_ title: String, entries: [HabitEntry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15)).foregroundColor(HabitStyle.secondary)
            if entries.isEmpty {
                Text("记录还不多，多用几天再看").font(.system(size: 13)).foregroundColor(HabitStyle.secondary)
            }
            ForEach(entries) { entry in
                HabitRow(entry: entry, deleted: settings.history.habits.excludedIDs.contains(entry.id)) {
                    let deleted = settings.history.habits.excludedIDs.contains(entry.id)
                    do { try settings.history.setHabit(entry.id, deleted: !deleted); error = nil }
                    catch { self.error = "习惯更改保存失败，请重试" }
                }
            }
        }
    }
}

private struct HabitToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule().fill(configuration.isOn ? HabitStyle.green : Color.gray.opacity(0.35))
                .frame(width: 44, height: 24)
                .overlay(Circle().fill(.white).frame(width: 18, height: 18).padding(3), alignment: configuration.isOn ? .trailing : .leading)
        }.buttonStyle(.plain).accessibilityLabel("根据我的记录调整建议")
            .accessibilityValue(configuration.isOn ? "开启" : "关闭")
    }
}

struct HabitRow: View {
    let entry: HabitEntry
    let deleted: Bool
    let toggle: () -> Void
    var actionTitle: String { deleted || entry.group == .suppressed ? "恢复" : "删除" }
    private var countTitle: String { (entry.group == .typo ? "采纳" : "忽略") + " \(entry.count) 次" }
    private var accessibilityTitle: String { actionTitle + (entry.group == .reminder ? entry.message : entry.original + "到" + entry.replacement) }
    var body: some View {
        VStack(spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if entry.group == .reminder {
                    Text(entry.message).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
                } else {
                    HabitPair(original: entry.original, replacement: entry.replacement)
                    Text(countTitle).font(.system(size: 13)).foregroundColor(HabitStyle.secondary)
                }
                Spacer(minLength: 8)
                Button(actionTitle, action: toggle).buttonStyle(.plain).font(.system(size: 13)).foregroundColor(HabitStyle.secondary)
                    .accessibilityLabel(accessibilityTitle)
            }.opacity(deleted ? 0.5 : 1)
            Rectangle().fill(HabitStyle.line).frame(height: 1)
        }
    }
}

enum HabitStyle {
    static let green = Color(red: 0.18, green: 0.43, blue: 0.33)
    static let red = Color(red: 0.88, green: 0.23, blue: 0.15)
    static let ink = PolishTheme.ink
    static let secondary = Color(red: 0.48, green: 0.46, blue: 0.42)
    static let line = Color(red: 0.90, green: 0.87, blue: 0.82)
}
struct HabitPair: View {
    let original: String, replacement: String
    var body: some View {
        (Text(original).foregroundColor(HabitStyle.red).strikethrough()
         + Text(" → ").foregroundColor(HabitStyle.ink)
         + Text(replacement.isEmpty ? "（删除）" : replacement).foregroundColor(HabitStyle.green).bold())
            .font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
    }
}
