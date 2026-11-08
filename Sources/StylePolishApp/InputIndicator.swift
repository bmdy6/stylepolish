import AppKit
import SwiftUI

// Separate from suggestion underlines so watching, unreadable and zero-edit states remain visible.
enum InputIndicatorState: Equatable {
    case watching, checking, clean, suggestions(Int), warning(String), modelFailure(String)
    var help: String {
        switch self {
        case .watching: return "已启用，正在看"
        case .checking: return "正在检查"
        case .clean: return "没问题"
        case .suggestions(let n): return "有 \(n) 条建议，点击打开列表"
        case .warning(let reason): return reason
        case .modelFailure(let reason): return "模型请求失败：" + reason
        }
    }
}
private struct IndicatorSpinner: View {
    @State private var spinning = false
    var body: some View {
        Circle().trim(from: 0.05, to: 0.8)
            .stroke(Color(nsColor: .labelColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 13, height: 13).rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true } }
    }
}
struct IndicatorView: View {
    let state: InputIndicatorState
    let click: () -> Void
    var body: some View {
        Button(action: click) {
            ZStack {
                Circle().fill(color)
                switch state {
                case .checking: IndicatorSpinner()
                case .clean: Text("✓").foregroundColor(.white)
                case .suggestions(let n): Text(String(n)).foregroundColor(.white)
                case .modelFailure: Text("⚠").foregroundColor(.white)
                case .warning: Text("⚠").foregroundColor(.black)
                case .watching: Circle().fill(.white.opacity(0.8)).frame(width: 5, height: 5)
                }
            }.font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24)
        }.buttonStyle(.plain).help(state.help).accessibilityLabel(state.help)
    }
    private var color: Color {
        switch state {
        case .watching: return .gray
        case .checking: return Color(nsColor: .windowBackgroundColor)
        case .clean: return .green
        case .suggestions: return .red
        case .warning: return .yellow
        case .modelFailure: return .red
        }
    }
}
@MainActor final class InputIndicator {
    private let panel = InlinePanel(frame: .zero)
    private(set) var state: InputIndicatorState?
    private var fade: Task<Void, Never>?
    var click: (() -> Void)?
    private var transition: Task<Void, Never>?
    private var pending: InputIndicatorState?
    private var latestBounds: CGRect?
    func hide() { schedule(nil, rawField: nil) }
    func show(_ next: InputIndicatorState, rawField: CGRect?) { schedule(next, rawField: rawField) }
    private func schedule(_ next: InputIndicatorState?, rawField: CGRect?) {
        latestBounds = rawField
        // Validated model edits already passed the controller's generation/focus checks.
        // Publish each streamed count immediately; keep debounce for focus/error flicker.
        if let next, case .suggestions = next {
            transition?.cancel(); transition = nil; pending = next
            publish(next, rawField: rawField)
            return
        }
        if state == next, let next { publish(next, rawField: rawField) }
        guard pending != next || (transition == nil && state != next) else { return }
        transition?.cancel(); pending = next
        if state == next { return }
        transition = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000); try Task.checkCancellation() } catch { return }
            guard let self else { return }
            self.transition = nil
            if let next { self.publish(next, rawField: self.latestBounds) } else { self.hideNow() }
        }
    }
    private func hideNow() { fade?.cancel(); fade = nil; state = nil; panel.orderOut(nil) }
    private func publish(_ next: InputIndicatorState, rawField: CGRect?) {
        guard let placement = OverlayPlacement.resolve(rawField: rawField, screens: NSScreen.screens.map(\.visibleFrame), preferredPoint: NSEvent.mouseLocation) else { hide(); return }
        let field = placement.field
        let rect = CGRect(x: field.maxX - 24, y: field.minY, width: 24, height: 24)
        panel.setFrame(rect, display: true)
        guard state != next else { return } // A clean indicator stays faded until new input.
        fade?.cancel(); state = next; panel.alphaValue = 1
        panel.contentView = NSHostingView(rootView: IndicatorView(state: next, click: { [weak self] in self?.click?() }))
        panel.orderFrontRegardless()
        if next == .clean {
            fade = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 1_000_000_000); try Task.checkCancellation() } catch { return }
                guard let self else { return }
                await NSAnimationContext.runAnimationGroup { context in context.duration = 0.25; self.panel.animator().alphaValue = 0 }
            }
        }
    }
}

// Empty text is readable; only a continuously unreadable ordinary field warns.
struct InputReadGate {
    private var since: Date?
    mutating func reset() { since = nil }
    mutating func warning(enabled: Bool, ordinary: Bool, readable: Bool, now: Date) -> Bool {
        guard enabled, ordinary, !readable else { reset(); return false }
        if since == nil { since = now }
        return now.timeIntervalSince(since!) > 2
    }
}
