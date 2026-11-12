#if DEBUG
import AppKit
import StylePolishCore

/// Production views and a loopback fixture only. The backing windows are never ordered onscreen.
@MainActor enum InviteCapture {
    static func run(directory: String, base: String) async throws {
        guard let url = URL(string: base), url.host == "127.0.0.1", url.scheme == "http" else { throw PolishFailure(message: "离屏邀请码渲染只允许本地假服务") }
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let home = RuntimeStorage.root.appendingPathComponent("invite-render")
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = SettingsStore(defaults: MemoryDefaults(), credentialHome: home)
        settings.engine = .invite; settings.relayBase = base
        func render(_ filename: String) throws {
            let model = OnboardingModel(settings: settings, trusted: true)
            model.state.engine = .invite
            try V4Capture.render(OnboardingView(model: model, settings: settings, permission: {}, finish: {}, fixture: true), height: 560, to: output.appendingPathComponent(filename))
        }
        try render("D1-invite.png")
        await settings.invite.verify("SP-GGGG-2345", base: base)
        guard settings.invite.remainingPercent == 92, settings.invite.canUse(base: base) else { throw PolishFailure(message: "本地假服务未返回 D2 的有效状态") }
        try render("D2-active.png")
        await settings.invite.verify("SP-JJJJ-2345", base: base)
        guard settings.invite.blockedReason == .inviteExhausted else { throw PolishFailure(message: "本地假服务未返回 D3 的耗尽状态") }
        try render("D3-exhausted.png")
        try V4Capture.render(SettingsView(settings: settings, openHistory: {}, clearHistory: {}, permission: {}, fixture: true, fixtureTrusted: true, advanced: true), to: output.appendingPathComponent("E-settings.png"))
    }
}
#endif
