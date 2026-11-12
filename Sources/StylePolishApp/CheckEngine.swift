import Foundation
import StylePolishCore

enum PolishEngine: String, CaseIterable { case local, invite, ai
    var title: String { switch self { case .local: return "本地规则"; case .invite: return "邀请码"; case .ai: return "自己的 Key" } }
}
enum FallbackReason: String, Codable, CaseIterable {
    case none, permission, key, quota, network, other
    case inviteInvalid, inviteExhausted, monthlyCap, rateLimited, inputTooLong, trialUnavailable, inviteUnverified
    static func classify(_ error: Error) -> Self {
        if let error = error as? URLError { return error.code == .cancelled ? .other : .network }
        guard let error = error as? PolishFailure else { return .other }
        switch error.code {
        case "invite_invalid": return .inviteInvalid
        case "invite_exhausted": return .inviteExhausted
        case "monthly_cap_reached": return .monthlyCap
        case "rate_limited": return .rateLimited
        case "input_too_long": return .inputTooLong
        case "upstream_error": return .network
        case "trial_unavailable": return .trialUnavailable
        case "invite_unverified": return .inviteUnverified
        default: break
        }
        if error.code == "insufficient_quota" { return .quota }
        if error.httpStatus == 429 { return .quota }
        if [401, 403].contains(error.httpStatus ?? 0) || error.code == "missing_key" { return .key }
        if error.code == "network" { return .network }
        if error.code == "ax_permission_denied" { return .permission }
        return .other
    }
    var blocksInvite: Bool { [.inviteInvalid, .inviteExhausted, .monthlyCap].contains(self) }
    var title: String {
        switch self { case .none: return ""; case .permission: return "需要授权"; case .key: return "Key 无效"; case .quota: return "额度用完"; case .network: return "网络不通"; case .other: return "AI 出错"
        case .inviteInvalid: return "邀请码无效"
        case .inviteExhausted: return "试用额度用完"
        case .monthlyCap: return "本月试用已满"
        case .rateLimited: return "稍后再试"
        case .inputTooLong: return "这段太长"
        case .trialUnavailable: return "试用服务还没开放"
        case .inviteUnverified: return "请先验证邀请码"
        }
    }
    var menuTitle: String {
        switch self {
        case .none: return ""
        case .permission: return "没有辅助功能权限 · 去授权 ›"
        case .key: return "Key 无效，已改用本地规则 · 去设置 ›"
        case .quota: return "额度用完，已改用本地规则"
        case .network: return "网络不通，已改用本地规则"
        case .other: return "AI 出错，已改用本地规则 · 去设置 ›"
        case .inviteInvalid, .inviteExhausted, .monthlyCap:
            return title + "，已改用本地规则 · 换邀请码 / 用自己的 Key ›"
        case .rateLimited: return "稍后再试（这次用本地规则）"
        case .inputTooLong: return "这段太长，用本地规则"
        case .trialUnavailable: return "试用服务还没开放 · 可先用本地规则"
        case .inviteUnverified: return "请先验证邀请码 · 去设置 ›"
        }
    }
}
struct CheckResult {
    var suggestions: [Suggestion]
    var unclear = false
    var fallback = FallbackReason.none
    var failureSummary: String? = nil
}
/// Shared by automatic checks, the onboarding editor and the offline harness.
struct CheckEngine {
    var client = PolishClient()
    var ai: ((String, PolishConfiguration) async throws -> WholePolishResult)?
    func check(_ text: String, engine: PolishEngine, config: PolishConfiguration, disabledKinds: [String] = [],
               hidden: @escaping @MainActor ([Suggestion]) -> Void = { _ in },
               progress: @escaping @MainActor ([Suggestion]) -> Void = { _ in },
               metrics: @escaping @MainActor (RequestMetrics) -> Void = { _ in }) async throws -> CheckResult {
        try Task.checkCancellation()
        func local(_ reason: FallbackReason = .none, summary: String? = nil) -> CheckResult {
            CheckResult(suggestions: LocalRules.check(text, level: config.level, aliases: client.localAliases(), personalTypos: config.habits.personalTypos).filter { !disabledKinds.contains($0.kind.rawValue) }, fallback: reason, failureSummary: summary)
        }
        func filtered(_ result: CheckResult) async -> CheckResult {
            var result = result
            let suppressed = result.suggestions.filter { config.habits.suppresses(original: $0.original, replacement: $0.replacement) }
            await hidden(suppressed)
            result.suggestions.removeAll { edit in suppressed.contains { $0.id == edit.id } }
            return result
        }
        let localResult = await filtered(local())
        guard engine != .local else { return localResult }
        if engine == .invite, let blocked = config.inviteBlocked {
            var result = localResult; result.fallback = blocked; result.failureSummary = blocked.menuTitle
            return result
        }
        do {
            await progress(localResult.suggestions)
            try Task.checkCancellation()
            let result: WholePolishResult
            if let ai { result = try await ai(text, config) }
            else { result = try await client.wholeResult(text, config: config, metrics: metrics) }
            try Task.checkCancellation()
            // Success replaces the provisional snapshot, including a clean AI
            // result. Do not append local duplicates or resurrect rejected advice.
            var unique: [Suggestion] = []
            for edit in result.suggestions where !disabledKinds.contains(edit.kind.rawValue) {
                if !unique.contains(where: { $0.kind == edit.kind && ($0.range == edit.range || NSIntersectionRange($0.range, edit.range).length > 0) }) { unique.append(edit) }
            }
            return await filtered(CheckResult(suggestions: unique, unclear: result.unclear))
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                await progress([])
                throw CancellationError()
            }
            // Only locally authored messages; never expose HTTP bodies, URL errors or detail.
            let summary = (error as? PolishFailure)?.message ?? "AI 请求失败"
            var result = localResult
            result.fallback = FallbackReason.classify(error); result.failureSummary = String(summary.prefix(120))
            return result
        }
    }
}
extension PolishClient {
    func localAliases() -> [String: String] {
        guard let data = try? Data(contentsOf: lexiconURL), data.count <= 64_000,
              let tree = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return tree["aliases"] as? [String: String] ?? [:]
    }
}

extension FallbackReason {
    var inviteCode: String {
        switch self {
        case .inviteInvalid: return "invite_invalid"
        case .inviteExhausted: return "invite_exhausted"
        case .monthlyCap: return "monthly_cap_reached"
        case .trialUnavailable: return "trial_unavailable"
        default: return "invite_unverified"
        }
    }
}
