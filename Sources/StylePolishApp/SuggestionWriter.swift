import Foundation

/// The target editor, not successful event dispatch, decides whether a write succeeded.
@MainActor struct SuggestionWriter {
    enum Outcome: String {
        case ax, axLate = "ax_late", clipboard, unverified = "clipboard_unverified", failed
        var confirmed: Bool { self == .ax || self == .axLate || self == .clipboard }
    }
    var isCurrent: (String) -> Bool
    var writeAX: () -> Bool
    var paste: (String, () -> Bool) async throws -> Void
    var pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 50_000_000) }

    func write(source: String, output: String, valid: () -> Bool) async -> Outcome {
        func live() -> Bool { !Task.isCancelled && valid() }
        guard live(), isCurrent(source) else { return .failed }
        if writeAX(), live(), isCurrent(output) { return .ax }
        do {
            for _ in 0..<3 {
                guard live() else { return .failed }
                if isCurrent(output) { return .axLate }
                try await pause()
            }
            guard live() else { return .failed }
            if isCurrent(output) { return .axLate }
            guard isCurrent(source) else { return .failed }
            try await paste(output, { live() && isCurrent(source) })
            for _ in 0..<10 {
                guard live() else { return .failed }
                if isCurrent(output) { return .clipboard }
                try await pause()
            }
            guard live() else { return .failed }
            return isCurrent(output) ? .clipboard : .unverified
        } catch {
            return live() && isCurrent(output) ? .clipboard : .failed
        }
    }
}
