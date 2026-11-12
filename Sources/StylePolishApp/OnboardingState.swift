import Foundation
import StylePolishCore

struct OnboardingState {
    enum Step: Int { case permission = 1, engine, trial }
    static let sample = "我因该明天在在给你回复，，文件以经发了"
    var step: Step
    var trusted: Bool
    var engine: PolishEngine
    var text = sample
    var pending: [Suggestion] = []
    var checking = false
    var didCheck = false
    private var grantedAt: TimeInterval?
    init(trusted: Bool, hasKey: Bool) {
        self.trusted = trusted
        step = trusted ? .engine : .permission
        engine = hasKey ? .ai : .local
    }
    mutating func permissionChanged(_ value: Bool, now: TimeInterval) {
        trusted = value
        if !value { grantedAt = nil; step = .permission; return }
        guard step == .permission else { return }
        if grantedAt == nil { grantedAt = now }
        if now - (grantedAt ?? now) >= 1 { step = .engine }
    }
    var canFinish: Bool {
        step == .trial && didCheck && !checking && pending.isEmpty && text != Self.sample
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && LocalRules.check(text, level: .standard).isEmpty
    }
}
