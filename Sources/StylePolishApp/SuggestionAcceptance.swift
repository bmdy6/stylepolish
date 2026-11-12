import Foundation
import StylePolishCore

/// Commit history and the accepted snapshot together, only after target readback.
/// This boundary is shared by AutomaticPolish and the offline writeback harness.
enum SuggestionAcceptance {
    @discardableResult static func commit(outcome: SuggestionWriter.Outcome, accepted: [LocatedSuggestion],
        snapshot: SuggestionPreview, all: Bool, settle: Bool, unclear: Bool,
        session: inout SuggestionSession, cache: inout SentenceCache,
        record: (LocatedSuggestion) -> Void) -> Bool {
        guard outcome.confirmed, !accepted.isEmpty else { return false }
        for item in accepted { record(item) }
        if all {
            if settle {
                if unclear { cache.store([], for: snapshot.output, unclear: true) }
                else { cache.settle(snapshot.output) }
            }
            session.replaceSuggestions(); session.reconcile(snapshot.output)
        } else {
            session.remove(accepted[0].id)
            session.didAccept(accepted[0].edit, updated: snapshot.output)
            if session.suggestions.isEmpty && settle { cache.store([], for: snapshot.output, unclear: unclear) }
        }
        return true
    }
}
