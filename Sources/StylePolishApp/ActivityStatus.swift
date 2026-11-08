import Foundation

enum ActivityStatus: Equatable {
    case disabled, idle, checking, suggestions(Int), failure(String)
    var title: String {
        switch self {
        case .disabled: return "未启用此 App"
        case .idle: return "空闲"
        case .checking: return "检查中"
        case .suggestions(let count): return "有 \(count) 条建议"
        case .failure(let reason): return "失败：\(reason)"
        }
    }
    var symbol: String {
        switch self {
        case .disabled: return "pause.circle"
        case .idle: return "text.badge.checkmark"
        case .checking: return "ellipsis.circle"
        case .suggestions: return "text.badge.plus"
        case .failure: return "exclamationmark.triangle"
        }
    }
}
