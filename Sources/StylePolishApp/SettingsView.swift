import SwiftUI
import AppKit
import StylePolishCore

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    var openHistory: () -> Void
    var clearHistory: () -> Void
    var permission: () -> Void
    var guide: () -> Void = {}
    var sizeChanged: (CGFloat) -> Void = { _ in }
    var fixture = false
    var fixtureTrusted = false
    @State var advanced = false
    @State var showingHabits = false
    @State private var confirmClear = false
    @State private var trusted = false
    private let permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("设置页面", selection: $showingHabits) {
                Text("通用").tag(false); Text("我的习惯").tag(true)
            }.pickerStyle(.segmented)
            if showingHabits {
                ScrollView { HabitsView(settings: settings) }.frame(height: 650)
            } else {
                HStack(alignment: .top, spacing: 26) {
                    polishing.frame(maxWidth: .infinity, alignment: .leading)
                    enabledApps.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(alignment: .top, spacing: 26) {
                    permissions.frame(maxWidth: .infinity, alignment: .leading)
                    advancedSummary.frame(maxWidth: .infinity, alignment: .leading)
                }
                if advanced { Divider(); advancedFields }
            }
        }.padding(.vertical, 22).padding(.horizontal, 26).frame(width: 560)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in Color.clear.preference(key: SettingsHeight.self, value: proxy.size.height) })
            .onPreferenceChange(SettingsHeight.self, perform: sizeChanged)
            .background(.white).foregroundColor(PolishTheme.ink).font(.system(size: 13))
            .buttonStyle(PolishButton(compact: true)).controlSize(.small)
            .tint(PolishTheme.indigo).environment(\.colorScheme, .light)
            .onAppear { trusted = fixture ? fixtureTrusted : AccessibilityAccess.trusted() }
            .onReceive(permissionTimer) { _ in if !fixture { trusted = AccessibilityAccess.trusted() } }
            .confirmationDialog("清空所有本地润色记录和习惯调整？此操作无法撤销。", isPresented: $confirmClear) {
                Button("清空记录", role: .destructive, action: clearHistory); Button("取消", role: .cancel) {}
            }
    }
    private func title(_ text: String) -> some View { Text(text).font(.system(size: 12, weight: .semibold)).foregroundColor(PolishTheme.sub).padding(.bottom, 4) }
    private var polishing: some View {
        VStack(alignment: .leading, spacing: 9) {
            title("润色方式")
            HStack {
                Text("方式"); Spacer(minLength: 4)
                Picker("润色方式", selection: $settings.engine) {
                    ForEach(PolishEngine.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 176).accessibilityLabel("润色方式")
            }
            Divider()
            HStack {
                Text("严格程度"); Spacer(minLength: 4)
                PolishSegments(values: Strictness.allCases, selection: $settings.level, title: { $0.title }).frame(width: 148).accessibilityLabel("严格程度")
            }
            Divider()
            HStack(spacing: 6) {
                Text("停笔多久后检查").font(.system(size: 12)).fixedSize()
                Text(String(format: "%.1f 秒", settings.pauseSeconds)).font(.system(size: 12)).monospacedDigit().fixedSize()
                Slider(value: $settings.pauseSeconds, in: 0.5...3, step: 0.1).accessibilityLabel("停笔多久后检查")
            }
            Divider()
            if settings.engine == .invite {
                Text("文字会经过作者的服务器转发给模型，服务器不保存内容。")
                    .font(.system(size: 12)).foregroundColor(PolishTheme.sub).fixedSize(horizontal: false, vertical: true)
                InviteSetupView(settings: settings, invite: settings.invite, fixture: fixture)
            }
            if settings.engine == .ai { KeySetupView(settings: settings, fixture: fixture) }
            Text("AI 不可用时")
            Text("自动改用本地规则").font(.system(size: 12)).foregroundColor(PolishTheme.sub)
            if !settings.disabledKinds.isEmpty { Button("恢复当前档位已关闭的类别") { settings.disabledKinds = [] } }
        }
    }
    private var enabledApps: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("支持的 App")
            Text("目前只支持微信")
        }
    }
    private var permissions: some View {
        VStack(alignment: .leading, spacing: 9) {
            title("权限与说明")
            HStack {
                Text("辅助功能"); Spacer()
                if trusted { Text("已授权").font(.system(size: 12, weight: .semibold)).foregroundColor(PolishTheme.green).padding(.horizontal, 8).padding(.vertical, 3).background(PolishTheme.green.opacity(0.1)).clipShape(Capsule()) }
                else { Button("去授权 ›", action: permission) }
            }
            Divider()
            HStack { Text("使用说明"); Spacer(); Button("重新打开引导", action: guide) }
            Divider()
            Text("本地记录")
            HStack { Button("打开文件夹", action: openHistory); Button("清空", role: .destructive) { confirmClear = true } }
        }
    }
    private var advancedSummary: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button { advanced.toggle() } label: {
                HStack { Image(systemName: advanced ? "chevron.down" : "chevron.right"); title("高级（默认折叠）"); Spacer() }
            }.buttonStyle(.plain).accessibilityLabel(advanced ? "折叠高级" : "展开高级")
            HStack {
                Text("API Key")
                Spacer(minLength: 0)
                Text(settings.credentials.current.key.isEmpty ? "未配置" : "…\(settings.credentials.current.key.suffix(4)) ✓").foregroundColor(PolishTheme.sub)
                Button("重新读取") { if !fixture { settings.reloadCredentials() } }
            }.font(.system(size: 11))
            Divider()
            Text("接口地址 / 模型 / 速度").font(.system(size: 12))
            Text("\(URL(string: settings.base)?.host ?? settings.base) · \(settings.model) · \(settings.serviceTier == "priority" ? "快速" : settings.serviceTier == "default" ? "标准" : "兼容")").font(.system(size: 11)).foregroundColor(PolishTheme.sub).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("口吻档案 / 个人词表").font(.system(size: 12))
            Text("⌥ Space 备用弹窗 · \(settings.legacyShortcut ? "开" : "关")").font(.system(size: 11)).foregroundColor(PolishTheme.sub)
        }
    }
    private var advancedFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            row("API Key") { KeySetupView(settings: settings, advanced: true, fixture: fixture) }
            row("中转地址") { TextField(InviteService.defaultBase, text: $settings.relayBase).accessibilityLabel("中转地址") }
            row("接口地址") { TextField("https://api.openai.com/v1", text: $settings.base).accessibilityLabel("接口地址") }
            row("模型 / 速度") {
                HStack {
                    TextField("gpt-6-luna", text: $settings.model).accessibilityLabel("模型")
                    Picker("处理模式", selection: $settings.serviceTier) { Text("快速 Fast").tag("priority"); Text("标准").tag("default"); Text("兼容（不指定速度）").tag("") }.labelsHidden().frame(width: 165)
                }
            }
            row("口吻档案") {
                HStack {
                    TextField("可选，本地 Markdown 文件", text: $settings.profile).accessibilityLabel("口吻档案路径")
                    Button("选择…", action: chooseProfile)
                }
            }
            row("个人词表") {
                HStack { Text("~/.style-polish/lexicon.json").font(.system(size: 11, design: .monospaced)); Button("打开文件夹") { NSWorkspace.shared.open(PolishClient.defaultLexiconURL.deletingLastPathComponent()) } }
            }
            row("调试模式") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("在本机记录正文，方便排查", isOn: $settings.debugMode)
                        .accessibilityLabel("调试模式（在本机记录正文，方便排查）")
                    Text("只存本机，不上传。排查后请关闭；导出诊断包会包含调试期间记录的正文。")
                        .font(.system(size: 11)).foregroundColor(PolishTheme.sub).fixedSize(horizontal: false, vertical: true)
                }
            }
            row("快捷键") {
                VStack(alignment: .leading, spacing: 4) { Text("⌥ Enter · 全部采纳"); Toggle("启用 ⌥ Space 备用弹窗", isOn: $settings.legacyShortcut) }
            }
        }.textFieldStyle(.roundedBorder)
    }
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow(alignment: .top) { Text(label).foregroundColor(PolishTheme.sub).frame(width: 76, alignment: .leading); content().frame(maxWidth: .infinity, alignment: .leading) }
    }
    private func chooseProfile() {
        guard !fixture else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        if panel.runModal() == .OK { settings.profile = panel.url?.path ?? "" }
    }
}

private struct SettingsHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
