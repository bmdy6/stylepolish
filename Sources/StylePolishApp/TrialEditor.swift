import AppKit
import SwiftUI
import StylePolishCore

/// A real NSTextView; edits never leave this view through AX or the clipboard.
struct TrialEditor: NSViewRepresentable {
    var text: String
    var suggestions: [Suggestion]
    var edited: (String) -> Void
    var select: (UUID) -> Void
    var acceptAll: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.borderType = .noBorder; scroll.hasVerticalScroller = true
        let view = TrialTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 80)); view.isRichText = false; view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false; view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false; view.isAutomaticTextReplacementEnabled = false
        view.font = .systemFont(ofSize: 16); view.textColor = .labelColor
        view.backgroundColor = NSColor(calibratedRed: 252/255, green: 252/255, blue: 254/255, alpha: 1)
        view.textContainerInset = NSSize(width: 12, height: 14)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator; view.setAccessibilityLabel("试一句，真实可编辑文本框")
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? TrialTextView else { return }
        context.coordinator.parent = self
        if view.string != text {
            let selection = view.selectedRange(); view.string = text
            view.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        view.setAccessibilityCustomActions(suggestions.map { edit in
            NSAccessibilityCustomAction(name: edit.canApply ? edit.original + "，" + edit.replacement : edit.why) { select(edit.id); return true }
        })
        view.suggestions = suggestions; view.select = select; view.acceptAll = acceptAll
        view.needsDisplay = true
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TrialEditor
        init(_ parent: TrialEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { parent.edited(view.string) }
        }
    }
}
final class TrialTextView: NSTextView {
    var suggestions: [Suggestion] = []
    var select: ((UUID) -> Void)?
    var acceptAll: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.option, .command, .control, .shift]) == .option { acceptAll?(); return }
        super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if let edit = suggestions.first(where: { NSLocationInRange(index, $0.range) || NSLocationInRange(max(0, index - 1), $0.range) }) { select?(edit.id) }
        super.mouseDown(with: event)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layoutManager, let textContainer else { return }
        NSColor.systemRed.setStroke()
        for edit in suggestions where edit.matches(string) {
            let glyphs = layoutManager.glyphRange(forCharacterRange: edit.range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { [self] rect, _ in
                let r = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
                let path = NSBezierPath(); path.lineWidth = 1.3
                var x = r.minX; path.move(to: NSPoint(x: x, y: r.maxY - 1))
                while x < r.maxX { x += 2; path.line(to: NSPoint(x: min(x, r.maxX), y: r.maxY - 1 + (Int((x - r.minX) / 2) % 2 == 0 ? 1.5 : -1.5))) }
                path.stroke()
            }
        }
    }
}
