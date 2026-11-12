import Foundation

/// The target editor, not successful event dispatch, decides whether a write succeeded.
@MainActor struct SuggestionWriter {
    enum Outcome: String {
        case ax, attachmentAX = "attachment_ranges", axLate = "ax_late", clipboard, unverified = "clipboard_unverified", attachmentCopy = "attachment_copy", failed
        var confirmed: Bool { self == .ax || self == .attachmentAX || self == .axLate || self == .clipboard }
    }
    var isCurrent: (String) -> Bool
    var writeAX: () -> Bool
    var paste: (String, () -> Bool) async throws -> Void
    var pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 50_000_000) }

    var attachmentEvidence: () -> AttachmentEvidence = { .plain }
    var writeProtected: ((String, String) -> Bool)? = nil
    var copyResult: (String) -> Void = { ClipboardTransaction.copyResult($0) }

    func write(source: String, output: String, valid: () -> Bool) async -> Outcome {
        func live() -> Bool { !Task.isCancelled && valid() }
        guard live(), isCurrent(source) else { return .failed }
        func protected() -> Outcome {
            guard live(), isCurrent(source) else { return .failed }
            if let writeProtected, writeProtected(source, output), live(), isCurrent(output) { return .attachmentAX }
            guard live() else { return .failed }
            copyResult(AttachmentSafety.clipboardText(output))
            return .attachmentCopy
        }
        let evidence = attachmentEvidence()
        if evidence.requiresProtection || source.contains("\u{FFFC}") { return protected() }
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
            // A user can add an attachment without changing AXValue. Re-check after every wait.
            let fresh = attachmentEvidence()
            if fresh.requiresProtection { return protected() }
            try await paste(output, { live() && isCurrent(source) && !attachmentEvidence().requiresProtection })
            for _ in 0..<10 {
                guard live() else { return .failed }
                if isCurrent(output) { return .clipboard }
                try await pause()
            }
            guard live() else { return .failed }
            return isCurrent(output) ? .clipboard : .unverified
        } catch {
            if live(), isCurrent(source), attachmentEvidence().requiresProtection { return protected() }
            return live() && isCurrent(output) ? .clipboard : .failed
        }
    }
}
