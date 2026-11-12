import SwiftUI

/// Shared file-only save and connection test for onboarding and settings.
struct KeySetupView: View {
    @ObservedObject var settings: SettingsStore
    var advanced = false
    var fixture = false
    @State private var key = ""
    @State private var message = ""
    @State private var testing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !advanced && !settings.credentials.current.key.isEmpty {
                Text("已找到 Key …\(settings.credentials.current.key.suffix(4)) ✓").font(.system(size: 12)).foregroundColor(PolishTheme.green)
            }
            if advanced || settings.credentials.current.key.isEmpty {
                HStack {
                    SecureField("粘贴 API Key", text: $key).accessibilityLabel("API Key")
                    if advanced { Button("保存") { save() }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fixture) }
                    Button(testing ? "测试中…" : "测试连接") { test() }.disabled(testing || fixture || (key.isEmpty && settings.credentials.current.key.isEmpty))
                }
            }
            if advanced {
                Text(settings.credentials.current.status).font(.caption).foregroundColor(.secondary)
                HStack {
                    TextField("vault Key 名称", text: $settings.vaultKeyName).accessibilityLabel("vault Key 名称")
                    Button("重新读取") { if !fixture { settings.reloadCredentials(); message = "已重新读取" } }
                }
                if settings.credentials.current.key.isEmpty { Link("获取 OpenAI API Key", destination: URL(string: "https://platform.openai.com/api-keys")!) }
                ForEach(settings.credentials.current.warnings, id: \.self) { Text($0).font(.caption).foregroundColor(.orange) }
            }
            if !message.isEmpty { Text(message).font(.caption).fixedSize(horizontal: false, vertical: true).accessibilityLabel(message) }
        }.textFieldStyle(.roundedBorder)
    }
    private func save() {
        do { try settings.saveKey(key); key = ""; message = "已保存到本地文件；ai-vault 优先" }
        catch { message = "无法保存本地 Key 文件，请检查目录权限。" }
    }
    private func test() {
        if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            save()
            guard key.isEmpty else { return }
        }
        testing = true; message = "正在连接…"
        let config = PolishConfiguration(base: settings.base, model: settings.model, key: settings.credentials.current.key, profile: "", serviceTier: settings.serviceTier, level: settings.level)
        Task { @MainActor in
            defer { testing = false }
            do { let ms = try await PolishClient().testConnection(config: config); message = "连接成功 · \(config.model) · \(ms) ms" }
            catch { message = error.localizedDescription }
        }
    }
}
