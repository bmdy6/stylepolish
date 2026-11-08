import SwiftUI
import AppKit
import StylePolishCore


struct OverlayPlacement {
    let field: CGRect
    let canUnderline: Bool
    @MainActor static func resolve(rawField: CGRect?, screens: [CGRect], preferredPoint: CGPoint) -> OverlayPlacement? {
        if let rawField, rawField.width > 0, rawField.height > 0 {
            let field = AccessibilityAccess.appKitRect(rawField)
            guard screens.contains(where: { $0.intersects(field) }) else { return nil }
            return OverlayPlacement(field: field, canUnderline: true)
        }
        guard let screen = screens.first(where: { $0.contains(preferredPoint) }) ?? screens.first else { return nil }
        // No AX position: keep the status near the pointer, inside the current screen.
        return OverlayPlacement(field: CGRect(x: min(screen.maxX - 30, max(screen.minX, preferredPoint.x + 14)), y: min(screen.maxY - 26, max(screen.minY, preferredPoint.y - 30)), width: 26, height: 26), canUnderline: false)
    }
}

struct WaveMark: Equatable {
    let id: UUID
    let rect: CGRect // AppKit screen coordinates
    let kind: SuggestionKind
}
@MainActor final class WaveView: NSView {
    var marks: [WaveMark] = []
    var highlighted: UUID?
    override func draw(_ dirtyRect: NSRect) {
        for mark in marks {
            let rect = mark.rect.offsetBy(dx: -window!.frame.minX, dy: -window!.frame.minY)
            if highlighted == mark.id {
                NSColor(calibratedRed: 1, green: 0.89, blue: 0.89, alpha: 0.85).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            }
            let color = mark.kind == .typo || mark.kind == .filler ? NSColor(calibratedRed: 229/255, green: 72/255, blue: 77/255, alpha: 1) : NSColor(calibratedRed: 245/255, green: 158/255, blue: 11/255, alpha: 1)
            color.setStroke(); let path = NSBezierPath(); path.lineWidth = 1.5
            let y = rect.minY - 1.5
            path.move(to: NSPoint(x: rect.minX, y: y))
            var x = rect.minX
            while x < rect.maxX {
                let next = min(x + 4, rect.maxX)
                path.curve(to: NSPoint(x: next, y: y), controlPoint1: NSPoint(x: x + 1, y: y + 2.5), controlPoint2: NSPoint(x: next - 1, y: y - 2.5)); x = next
            }
            path.stroke()
        }
    }
}
final class InlinePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; level = .floating; hasShadow = true
        hidesOnDeactivate = false; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }
}
@MainActor final class InlineOverlay {
    private let waves = InlinePanel(frame: .zero)
    private let drawing = WaveView()
    private let popup = InlinePanel(frame: .zero)
    private let previewPanel = InlinePanel(frame: .zero)
    private(set) var preview: SuggestionPreview?
    var previewFrame: CGRect { previewPanel.frame }
    var previewVisible: Bool { previewPanel.isVisible }
    var pointerOverPreview: Bool { previewVisible && previewPanel.frame.contains(NSEvent.mouseLocation) }
    private let badge = InlinePanel(frame: .zero)
    private var marks: [WaveMark] = []
    private var items: [LocatedSuggestion] = []
    private var field = CGRect.zero
    private var hover: UUID?
    private var hoverStart = Date()
    private var timer: Timer?
    private var openID: UUID?
    var accept: ((UUID) -> Void)?
    var ignore: ((UUID) -> Void)?
    var disable: ((SuggestionKind) -> Void)?
    var acceptAll: (() -> Void)?
    init() {
        // Scroll long diffs without activation; the panel still cannot become key/main.
        previewPanel.ignoresMouseEvents = false
        waves.ignoresMouseEvents = true; waves.hasShadow = false; waves.contentView = drawing
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.trackHover() } }
    }
    func hide() {
        hidePreview()
        waves.orderOut(nil); popup.orderOut(nil); badge.orderOut(nil)
        marks = []; items = []; hover = nil; openID = nil
    }
    func show(items: [LocatedSuggestion], field: CGRect, marks: [WaveMark]?) {
        guard !items.isEmpty else {
            waves.orderOut(nil); popup.orderOut(nil); badge.orderOut(nil)
            self.items = []; self.marks = []; hover = nil; openID = nil
            return
        }
        let same = self.items.map(\.id) == items.map(\.id) && self.field == field && self.marks == (marks ?? [])
        self.items = items; self.field = field
        guard !same else { return }
        popup.orderOut(nil); openID = nil; drawing.highlighted = nil
        self.marks = marks ?? []
        if let marks, !marks.isEmpty {
            badge.orderOut(nil)
            waves.setFrame(field.insetBy(dx: -4, dy: -5), display: false)
            drawing.frame = CGRect(origin: .zero, size: waves.frame.size); drawing.marks = marks; drawing.needsDisplay = true
            waves.orderFrontRegardless()
        } else {
            waves.orderOut(nil)
            let host = NSHostingView(rootView: Button("● \(items.count) 处") { [weak self] in self?.showList() }.font(.system(size: 11)).foregroundColor(InlinePalette.red).buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 4).background(.white).clipShape(Capsule()))
            badge.contentView = host
            badge.setFrame(clamped(CGRect(x: field.maxX - 70, y: field.minY - 12, width: 70, height: 26)), display: true)
            badge.orderFrontRegardless()
        }
    }
    func hidePreview() { previewPanel.orderOut(nil); preview = nil }
    func showPreview(_ snapshot: SuggestionPreview?, field: CGRect) {
        guard let snapshot else { hidePreview(); return }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(field) })?.visibleFrame ?? NSScreen.main?.visibleFrame ?? field
        let width = min(850, screen.width - 16)
        if preview != snapshot {
            let host = NSHostingView(rootView: AutomaticPreviewBar(preview: snapshot, width: width).frame(width: width))
            previewPanel.contentView = host
            previewPanel.setContentSize(NSSize(width: width, height: host.fittingSize.height))
            preview = snapshot
        }
        var frame = previewPanel.frame
        frame.origin = CGPoint(x: field.minX, y: field.minY - frame.height - 8)
        if frame.minY < screen.minY { frame.origin.y = field.maxY + 8 }
        previewPanel.setFrame(clamped(frame), display: true)
        previewPanel.orderFrontRegardless()
    }
    // Called by the event tap; only the narrow underline hit region consumes a click.
    func click(at point: CGPoint) -> Bool {
        guard let mark = hit(point) else { return false }
        open(mark.id); return true
    }
    private func hit(_ point: CGPoint) -> WaveMark? {
        guard waves.isVisible else { return nil }
        return marks.first { CGRect(x: $0.rect.minX - 2, y: $0.rect.minY - 5, width: max(6, $0.rect.width + 4), height: 8).contains(point) }
    }
    private func trackHover() {
        guard NSApp.currentEvent?.type != .rightMouseDown else { return }
        let point = NSEvent.mouseLocation
        if let mark = hit(point) {
            if hover != mark.id { hover = mark.id; hoverStart = Date() }
            else if Date().timeIntervalSince(hoverStart) >= 0.3, openID != mark.id { open(mark.id) }
        } else {
            hover = nil
            if popup.isVisible, !(openID == nil && badge.isVisible && badge.frame.union(popup.frame).insetBy(dx: -18, dy: -18).contains(point)), !popup.frame.insetBy(dx: -18, dy: -18).contains(point), !marks.contains(where: { $0.id == openID && $0.rect.insetBy(dx: -18, dy: -18).contains(point) }) {
                popup.orderOut(nil); openID = nil; drawing.highlighted = nil; drawing.needsDisplay = true
            }
        }
    }
    private func open(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), let mark = marks.first(where: { $0.id == id }) else { return }
        openID = id; drawing.highlighted = id; drawing.needsDisplay = true
        let card = SuggestionCard(suggestion: item.edit, accept: { [weak self] in self?.accept?(id) }, ignore: { [weak self] in self?.ignore?(id) }, disable: { [weak self] in self?.disable?(item.edit.kind) }, sizeChanged: { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.resizePopup(above: mark.rect) }
        })
        present(card, above: mark.rect, width: 240)
    }
    func showList() {
        guard !items.isEmpty else { return }
        present(SuggestionList(suggestions: items, accept: { [weak self] in self?.accept?($0) }, ignore: { [weak self] in self?.ignore?($0) }, acceptAll: { [weak self] in self?.acceptAll?() }), above: field, width: 280)
    }
    private func present<V: View>(_ view: V, above rect: CGRect, width: CGFloat) {
        let host = NSHostingView(rootView: view)
        popup.contentView = host
        let height = host.fittingSize.height
        var frame = CGRect(x: rect.minX, y: rect.maxY + 10, width: width, height: height)
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) })?.visibleFrame ?? NSScreen.main!.visibleFrame
        if frame.maxY > screen.maxY { frame.origin.y = rect.minY - height - 10 }
        popup.setFrame(clamped(frame), display: true); popup.orderFrontRegardless()
    }
    private func resizePopup(above rect: CGRect) {
        guard popup.isVisible, let host = popup.contentView else { return }
        var frame = popup.frame; frame.size.height = host.fittingSize.height
        frame.origin.y = rect.maxY + 10
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) })?.visibleFrame
        if let screen, frame.maxY > screen.maxY { frame.origin.y = rect.minY - frame.height - 10 }
        popup.setFrame(clamped(frame), display: true)
    }
    private func clamped(_ rect: CGRect) -> CGRect {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else { return rect }
        let visible = screen.visibleFrame
        var result = rect; result.origin.x = max(visible.minX, min(result.minX, visible.maxX - result.width)); result.origin.y = max(visible.minY, min(result.minY, visible.maxY - result.height)); return result
    }
}
