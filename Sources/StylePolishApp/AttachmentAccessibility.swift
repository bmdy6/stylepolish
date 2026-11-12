import AppKit
import ApplicationServices

extension AccessibilityAccess {
    /// Read-only evidence. Unsupported, mismatched or incomplete rich text is never treated as plain.
    func attachmentEvidence(_ element: AXUIElement, text: String) -> AttachmentEvidence {
        guard text.utf16.count <= 100_000 else { return .unknown }
        var range = CFRange(location: 0, length: text.utf16.count)
        var raw: CFTypeRef?
        if let value = AXValueCreate(.cfRange, &range) {
            _ = AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString, value, &raw)
        }
        var embedded = 0, complete = true, visited = Set<CFHashCode>()
        var pending = (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        while !pending.isEmpty, visited.count < 256 {
            let child = pending.removeFirst()
            guard visited.insert(CFHash(child)).inserted else { continue }
            let role = attribute(child, kAXRoleAttribute) as? String ?? ""
            if [kAXImageRole, "AXAttachment"].contains(role) { embedded += 1 }
            if let children = attribute(child, kAXChildrenAttribute) as? [AXUIElement] { pending += children }
        }
        if !pending.isEmpty { complete = false }
        return AttachmentEvidence.inspect(text: text, attributed: raw as? NSAttributedString, embeddedChildren: embedded, childrenComplete: complete)
    }

    func writeAttachmentText(source: String, output: String, to capture: CapturedInput, traceID: String? = nil) -> Bool {
        guard isCurrent(capture, text: source) else { return false }
        let evidence = attachmentEvidence(capture.element, text: source)
        guard let edits = AttachmentSafety.plan(source: source, output: output, evidence: evidence),
              settable(capture.element, kAXSelectedTextAttribute), settable(capture.element, kAXSelectedTextRangeAttribute) else { return false }
        let oldSelection = selection(capture.element)
        defer {
            if let oldSelection, isCurrent(capture, text: source) {
                var r = CFRange(location: oldSelection.location, length: oldSelection.length)
                if let v = AXValueCreate(.cfRange, &r) { _ = AXUIElementSetAttributeValue(capture.element, kAXSelectedTextRangeAttribute as CFString, v) }
            }
        }
        var plannedSelection: NSRange?
        let succeeded = AttachmentSafety.apply(edits, source: source, output: output, valid: { !Task.isCancelled }, read: {
            // Identity, focus and rich evidence must remain valid at every boundary.
            guard let value = self.attribute(capture.element, kAXValueAttribute) as? String,
                  self.isCurrent(capture, text: value) else { return nil }
            let fresh = self.attachmentEvidence(capture.element, text: value)
            guard fresh.complete, fresh.hasAttachment, fresh.ranges.count == evidence.ranges.count else { return nil }
            return value
        }, select: { range in
            plannedSelection = range
            var r = CFRange(location: range.location, length: range.length)
            guard let v = AXValueCreate(.cfRange, &r), AXUIElementSetAttributeValue(capture.element, kAXSelectedTextRangeAttribute as CFString, v) == .success else { return false }
            return self.selection(capture.element) == range
        }, selectedText: {
            guard self.selection(capture.element) == plannedSelection else { return nil }
            return self.attribute(capture.element, kAXSelectedTextAttribute) as? String
        }, replace: { text in
            guard self.selection(capture.element) == plannedSelection else { return false }
            return AXUIElementSetAttributeValue(capture.element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        })
        Diagnostics.shared.record(DiagnosticEvent(event: "attachment_write", bundleID: capture.bundleID, hasAttachment: true, writeMethod: "attachment_ranges", traceID: traceID, error: succeeded ? nil : "range_write_unconfirmed"))
        return succeeded
    }
}
