import SwiftUI

/// The same verification and replacement controls appear in onboarding and settings.
struct InviteSetupView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var invite: InviteAccess
    var fixture = false
    var initialCode = ""
    @State private var code = ""
    @State private var replacing = false
    init(settings: SettingsStore, invite: InviteAccess, fixture: Bool = false, initialCode: String = "") {
        self.settings = settings; self.invite = invite; self.fixture = fixture; self.initialCode = initialCode
        _code = State(initialValue: initialCode.isEmpty ? invite.code : initialCode)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if invite.canUse(base: settings.relayBase) && !replacing {
                    Text(invite.code).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Text("有效").font(.system(size: 12, weight: .semibold)).foregroundColor(PolishTheme.green)
                    Button("更换") { replacing = true; code = "" }.disabled(fixture)
                } else {
                    TextField("输入邀请码，例如 SP-7K2M-9QXD", text: $code).accessibilityLabel("邀请码")
                        .font(.system(size: 12)).textFieldStyle(.roundedBorder)
                        .onSubmit { verify() }
                    Button(invite.validating ? "验证中…" : "验证") { verify() }
                        .disabled(invite.validating || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || fixture)
                }
                if invite.blockedReason?.blocksInvite == true {
                    Text(invite.blockedReason == .inviteExhausted ? "额度已用完" : invite.blockedReason!.title)
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(.orange).fixedSize()
                }
            }
            if let remaining = invite.remainingPercent, invite.canUse(base: settings.relayBase) {
                Text("剩余额度 \(remaining)% · 用完后自动改用本地规则").foregroundColor(PolishTheme.sub)
            } else if !invite.message.isEmpty {
                Text(invite.message).foregroundColor(invite.blockedReason?.blocksInvite == true ? Color.orange : PolishTheme.sub)
            }
            if invite.blockedReason?.blocksInvite == true {
                Text("可以换一个邀请码，或改用本地规则 / 自己的 Key。").foregroundColor(PolishTheme.sub)
            }
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            .onAppear { code = initialCode.isEmpty ? invite.code : initialCode }
    }
    private func verify() {
        guard !fixture, !invite.validating else { return }
        let value = code, base = settings.relayBase
        // Register before the first request: diagnostics must never retain an invite literal.
        settings.diagnostics.configure(debug: settings.debugMode, secrets: [value, value.uppercased()])
        Task { @MainActor in
            await invite.verify(value, base: base)
            settings.configureSecrets()
            if invite.canUse(base: base) { replacing = false }
        }
    }
}
