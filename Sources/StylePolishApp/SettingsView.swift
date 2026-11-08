import SwiftUI
import AppKit
import StylePolishCore

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    var openHistory: () -> Void
    var clearHistory: () -> Void
    var permission: () -> Void
    var fixture = false
    @State private var testing = false
    @State private var connectionMessage = ""
    @State private var key = ""
    @State private var message = ""
    @State private var newBundleID = ""
    @State private var confirmClear = false
    @State private var trusted = false
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置").font(.system(size: 19, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
                row("接口地址") { TextField("https://api.openai.com/v1", text: $settings.base).accessibilityLabel("接口地址") }
                row("API Key") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(settings.credentials.current.status).font(.system(size: 12))
                        HStack {
                            SecureField("填一次 Key 即可", text: $key).accessibilityLabel("API Key")
                            Button("保存") {
                                do {
                                    if !fixture { try settings.saveKey(key) }
                                    key = ""
                                    message = "已保存到本地文件；ai-vault 优先"
                                } catch { message = "无法保存本地 Key 文件，请检查目录权限。" }
                            }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        HStack {
                            TextField("OPENAI_PLATFORM_API_KEY", text: $settings.vaultKeyName).accessibilityLabel("vault Key 名称")
                            Button("重新读取") { if !fixture { settings.reloadCredentials(); key = ""; message = "已重新读取" } }
                        }
                        if settings.credentials.current.key.isEmpty {
                            Link("获取 OpenAI API Key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                        }
                        ForEach(settings.credentials.current.warnings, id: \.self) { Text($0).font(.system(size: 11)).foregroundColor(.orange) }
                    }
                }
                row("模型") { TextField("gpt-6-luna", text: $settings.model).accessibilityLabel("模型") }
                row("速度") {
                    Picker("处理模式", selection: $settings.serviceTier) {
                        Text("快速 Fast").tag("priority")
                        Text("标准").tag("default")
                        Text("兼容（不指定速度）").tag("")
                    }.labelsHidden()
                }
                row("连接") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Button(testing ? "测试中…" : "测试连接") {
                                testing = true; connectionMessage = "正在连接…"
                                let config = PolishConfiguration(base: settings.base, model: settings.model, key: key.isEmpty ? settings.credentials.current.key : key, profile: "", serviceTier: settings.serviceTier, credentialError: key.isEmpty ? settings.credentials.current.warnings.first : nil, level: settings.level)
                                Task { @MainActor in
                                    defer { testing = false }
                                    do {
                                        let ms = try await PolishClient().testConnection(config: config)
                                        connectionMessage = "连接成功 · \(config.model) · \(ms) ms"
                                    } catch { connectionMessage = error.localizedDescription }
                                }
                            }.disabled(testing || fixture)
                            Text("使用已读取的 Key；新粘贴的 Key 请先保存").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        if !connectionMessage.isEmpty {
                            Text(connectionMessage).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).accessibilityLabel(connectionMessage)
                        }
                    }
                }
                row("停笔多久后检查") {
                    HStack {
                        Slider(value: $settings.pauseSeconds, in: 0.5...3, step: 0.1).accessibilityLabel("停笔多久后检查")
                        Text(String(format: "%.1f 秒", settings.pauseSeconds)).monospacedDigit().frame(width: 54)
                    }
                }
                row("严格程度") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("严格程度", selection: $settings.level) { ForEach(Strictness.allCases, id: \.self) { Text($0.title).tag($0) } }.labelsHidden().pickerStyle(.segmented)
                        Text("宽松：错别字 · 标准：加赘词、通顺 · 严格：加书面表达").font(.system(size: 11)).foregroundColor(.secondary)
                        if !settings.disabledKinds.isEmpty { Button("恢复当前档位已关闭的类别") { settings.disabledKinds = [] } }
                    }
                }
                row("快捷键") {
                    VStack(alignment: .leading) {
                        Text("⌥ Enter · 全部采纳")
                        Toggle("启用 ⌥ Space 备用弹窗", isOn: $settings.legacyShortcut)
                    }
                }
                row("口吻档案") {
                    HStack {
                        TextField("可选，本地 Markdown 文件", text: $settings.profile).accessibilityLabel("口吻档案路径")
                        Button("选择…") { let panel = NSOpenPanel(); panel.canChooseDirectories = false; if panel.runModal() == .OK { settings.profile = panel.url?.path ?? "" } }
                    }
                }
                row("启用的 App") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(settings.apps, id: \.self) { id in
                            HStack { Text(id).font(.system(size: 11, design: .monospaced)); Spacer(); Button { settings.apps.removeAll { $0 == id } } label: { Image(systemName: "xmark.circle") }.accessibilityLabel("移除 \(id)") }
                        }
                        HStack {
                            TextField("bundle id", text: $newBundleID).accessibilityLabel("新 App bundle id")
                            Button("添加") { let id = newBundleID.trimmingCharacters(in: .whitespacesAndNewlines); if !id.isEmpty && !settings.apps.contains(id) { settings.apps.append(id); newBundleID = "" } }
                            Button("选择 App…") {
                                let panel = NSOpenPanel(); panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.allowedContentTypes = [.application]; panel.canChooseDirectories = false
                                if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier, !settings.apps.contains(id) { settings.apps.append(id) }
                            }
                        }
                        Text("浏览器中的 Linear：请添加你使用的浏览器。启用后该浏览器的所有普通文字输入框均可使用。").font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                row("辅助功能权限") {
                    HStack { Text(trusted ? "● 已授权" : "● 未授权").foregroundColor(trusted ? .green : .orange)
                        Button("授权 / 刷新") { permission(); trusted = AccessibilityAccess.trusted() }
                    }
                }
            }.textFieldStyle(.roundedBorder)
            Text("文字会发给你配置的模型服务；历史只保存在本机。修改设置会自动保存，API Key 请单独点保存。").font(.system(size: 11)).foregroundColor(.secondary)
            HStack { Button("打开记录文件夹", action: openHistory); Button("清空记录", role: .destructive) { confirmClear = true }; Spacer() }
            if !message.isEmpty { Text(message).font(.system(size: 12)).accessibilityLabel(message) }
        }
        .padding(22).frame(width: 570).background(Color(red: 251/255, green: 251/255, blue: 252/255))
        }.frame(width: 570, height: min(760, (NSScreen.main?.visibleFrame.height ?? 850) - 90))
        .environment(\.colorScheme, .light)
        .onAppear { if !fixture { trusted = AccessibilityAccess.trusted() } }
        .confirmationDialog("清空所有本地润色记录？此操作无法撤销。", isPresented: $confirmClear) { Button("清空记录", role: .destructive, action: clearHistory); Button("取消", role: .cancel) {} }
    }
    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow(alignment: .top) { Text(label).foregroundColor(.secondary).frame(width: 90, alignment: .leading); content().frame(maxWidth: .infinity, alignment: .leading) }
    }
}
