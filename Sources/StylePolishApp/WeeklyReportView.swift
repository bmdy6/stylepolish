import SwiftUI
import StylePolishCore

struct WeeklyReportView: View {
    let report: WeeklyReport
    var dateRange: String {
        let format = DateFormatter(); format.dateFormat = "MM/dd"
        return format.string(from: report.start) + " – " + format.string(from: report.end) + " · 微信"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("本周表达报告").font(.system(size: 22, weight: .bold))
                Text(dateRange).font(.system(size: 13)).foregroundColor(HabitStyle.secondary)
            }
            HStack(alignment: .top, spacing: 26) {
                metric("\(report.accepted)", "采纳")
                metric("\(report.ignored)", "忽略")
                metric(report.accepted + report.ignored == 0 ? "—" : "\(Int((report.acceptanceRate * 100).rounded()))%", "采纳率")
                metric(String(format: "%+d", report.typoDelta), "错字比上周")
            }
            if report.smallSample {
                Text("记录还不多，多用几天再看").font(.system(size: 14)).foregroundColor(HabitStyle.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                label("建议类型（已采纳）")
                ForEach(report.byKind) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(row.kind.title) \(row.count)").font(.system(size: 13)).foregroundColor(HabitStyle.secondary)
                        GeometryReader { geometry in
                            Capsule().fill(HabitStyle.green)
                                .frame(width: row.count == 0 ? 0 : max(8, geometry.size.width * Double(row.count) / Double(max(1, report.byKind.map(\.count).max() ?? 1))), height: 10)
                        }.frame(height: 10)
                    }.accessibilityElement(children: .combine)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                label("最常犯的 3 个")
                if report.frequent.isEmpty { Text("暂时没有已采纳的错字记录").font(.system(size: 13)).foregroundColor(HabitStyle.secondary) }
                ForEach(report.frequent) { entry in
                    VStack(spacing: 10) {
                        HStack {
                            HabitPair(original: entry.original, replacement: entry.replacement)
                            Spacer()
                            Text("\(entry.count) 次").font(.system(size: 13)).foregroundColor(HabitStyle.secondary)
                        }
                        Rectangle().fill(HabitStyle.line).frame(height: 1)
                    }
                }
            }
            Text("下周留意：" + report.nextWeekTip)
                .font(.system(size: 13)).foregroundColor(HabitStyle.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.padding(30).foregroundColor(HabitStyle.ink).background(.white)
    }
    private func label(_ text: String) -> some View { Text(text).font(.system(size: 15)).foregroundColor(HabitStyle.secondary) }
    private func metric(_ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 34, weight: .bold)).monospacedDigit()
            Text(title).font(.system(size: 14)).foregroundColor(HabitStyle.secondary)
        }.accessibilityElement(children: .combine)
    }
}

struct WeeklyReportWindowContent: View {
    @ObservedObject var settings: SettingsStore
    var body: some View { WeeklyReportView(report: settings.history.habits.report()).frame(width: 720, height: 780) }
}
