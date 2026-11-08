import Foundation

enum ActivityStatus: Equatable {
    case disabled, idle, checking, unclear, suggestions(Int), failure(String)
    static func completed(count: Int, unclear: Bool) -> Self {
        count > 0 ? .suggestions(count) : (unclear ? .unclear : .idle)
    }
    var title: String {
        switch self {
        case .disabled: return "未启用此 App"
        case .idle: return "空闲"
        case .unclear: return "读不通"
        case .checking: return "检查中"
        case .suggestions(let count): return "有 \(count) 条建议"
        case .failure(let reason): return "失败：\(reason)"
        }
    }
    var help: String { self == .unclear ? "这句读不通，检查一下？" : "StylePolish · " + title }
    var symbol: String {
        switch self {
        case .disabled: return "pause.circle"
        case .idle: return "text.badge.checkmark"
        case .unclear: return "questionmark.circle"
        case .checking: return "ellipsis.circle"
        case .suggestions: return "text.badge.plus"
        case .failure: return "exclamationmark.triangle"
        }
    }
}
