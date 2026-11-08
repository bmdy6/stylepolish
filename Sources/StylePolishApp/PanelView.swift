import SwiftUI
import AppKit
import StylePolishCore

enum PanelPhase { case loading, preview, edit, error, notice }
@MainActor final class PanelModel: ObservableObject {
    @Published var phase: PanelPhase = .loading
    @Published var appName = ""
    @Published var input = ""
    @Published var output = ""
    @Published var edited = ""
    @Published var message = ""
    @Published var showOriginal = false
    @Published var latencyMS = 0
    var accept: (() -> Void)?
    var edit: (() -> Void)?
    var toggle: (() -> Void)?
    var cancel: (() -> Void)?
    var retry: (() -> Void)?
}
private enum Palette {
    static let panel = Color(red: 251/255, green: 251/255, blue: 252/255)
    static let line = Color(red: 227/255, green: 229/255, blue: 233/255)
    static let muted = Color(red: 122/255, green: 127/255, blue: 136/255)
    static let accent = Color(red: 59/255, green: 108/255, blue: 246/255)
    static let deletion = Color(red: 194/255, green: 65/255, blue: 12/255)
    static let insertion = Color(red: 21/255, green: 128/255, blue: 61/255)
}
struct PanelView: View {
    @ObservedObject var state: PanelModel
    @FocusState private var editorFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(state.phase == .error ? Palette.deletion : state.phase == .edit ? Palette.accent : Palette.insertion).frame(width: 8, height: 8)
                Text(state.appName).fontWeight(.semibold).lineLimit(1)
                if state.phase == .preview || state.phase == .edit {
                    Text(state.phase == .edit ? "修改中" : state.showOriginal ? "原文" : "最少修改")
                        .font(.system(size: 11)).foregroundColor(Palette.accent).padding(.horizontal, 8).padding(.vertical, 2).background(Color(red: 238/255, green: 242/255, blue: 1)).clipShape(Capsule())
                }
                Spacer(minLength: 0)
                Text(status).foregroundColor(Palette.muted).font(.system(size: 11))
            }.font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 12)
            Rectangle().fill(Palette.line).frame(height: 1)
            if state.phase == .loading { ProgressView().progressViewStyle(.linear).tint(Palette.accent).frame(height: 3) }
            ScrollView {
                Group {
                    if state.phase == .edit {
                        TextEditor(text: $state.edited).font(.system(size: 15)).scrollContentBackground(.hidden)
                            .padding(8).frame(minHeight: 96).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.accent, lineWidth: 1.5))
                            .focused($editorFocused).accessibilityLabel("修改润色结果")
                    } else if state.phase == .preview {
                        (state.showOriginal ? Text(state.input) : diffText).font(.system(size: 15)).lineSpacing(7).frame(maxWidth: .infinity, alignment: .leading)
                    } else if state.phase == .loading {
                        Text(state.output.isEmpty ? state.input : state.output).font(.system(size: 15)).foregroundColor(Palette.muted).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(state.message).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            }
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 12) {
                if state.phase == .preview {
                    hint("Enter", state.input.utf16.elementsEqual(state.output.utf16) ? "关闭" : "写回", state.accept)
                    hint("E", "修改", state.edit)
                    hint("O", state.showOriginal ? "看对比" : "看原文", state.toggle)
                } else if state.phase == .edit { hint("⌘Enter", "写回", state.accept) }
                else if state.phase == .error { hint("R", "重试", state.retry) }
                hint("Esc", state.phase == .edit ? "返回预览" : state.phase == .notice ? "关闭" : "取消", state.cancel)
                Spacer(minLength: 0)
            }.padding(.horizontal, 14).padding(.vertical, 10).background(Color(red: 245/255, green: 246/255, blue: 248/255))
        }
        .frame(width: 440).background(Palette.panel).clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 1))
        .foregroundColor(Color(red: 29/255, green: 31/255, blue: 35/255)).environment(\.colorScheme, .light)
        .onChange(of: state.phase) { phase in editorFocused = phase == .edit }
    }
    private var status: String {
        switch state.phase {
        case .loading: return "润色中…"
        case .preview: return "\(state.input.utf16.elementsEqual(state.output.utf16) ? "不用改" : "改了 \(CharacterDiff(state.input, state.output).changeCount) 处") · \(String(format: "%.1f", Double(state.latencyMS) / 1000))s"
        case .edit: return "你的修改会被记下"
        case .error: return "没改动输入框"
        case .notice: return "StylePolish"
        }
    }
    private var diffText: Text {
        CharacterDiff(state.input, state.output).parts.reduce(Text("")) { result, part in
            switch part.kind {
            case .equal: return result + Text(part.text)
            case .delete: return result + Text(part.text).foregroundColor(Palette.deletion).strikethrough()
            case .insert: return result + Text(part.text).foregroundColor(Palette.insertion).underline()
            }
        }
    }
    private func hint(_ key: String, _ label: String, _ action: (() -> Void)?) -> some View {
        Button(action: { action?() }) {
            HStack(spacing: 4) {
                Text(key).font(.system(size: 10, weight: .medium)).padding(.horizontal, 4).padding(.vertical, 2).background(Color.white).cornerRadius(4).overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.line))
                Text(label).font(.system(size: 11)).foregroundColor(Palette.muted)
            }
        }.buttonStyle(.plain).accessibilityLabel("\(label)，\(key)")
    }
}

final class PolishPanel: NSPanel {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { return }
        super.keyDown(with: event)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    init(model: PanelModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 220), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating; isFloatingPanel = true; hidesOnDeactivate = false
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: PanelView(state: model))
        appearance = NSAppearance(named: .aqua)
    }
    func position(bounds: CGRect?, fallbackWindow: CGRect? = nil, height: CGFloat) {
        // AX coordinates have their origin at the top-left of the primary display.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let rect = bounds.map { CGRect(x: $0.minX, y: primaryTop - $0.maxY, width: $0.width, height: $0.height) }
        let point = rect.map { NSPoint(x: $0.minX, y: $0.minY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let h = min(320, max(140, height))
        var y = point.y - h - 8
        if y < visible.minY { y = (rect?.maxY ?? point.y) + 8 }
        let fallback = fallbackWindow.map { AccessibilityAccess.appKitRect($0) }
        let desiredX = bounds == nil ? fallback.map { $0.midX - 220 } ?? point.x : point.x
        if bounds == nil, let fallback { y = fallback.minY + fallback.height * 0.25 - h / 2 }
        let x = min(max(desiredX, visible.minX + 8), visible.maxX - 448)
        y = min(max(y, visible.minY + 8), visible.maxY - h - 8)
        setFrame(NSRect(x: x, y: y, width: 440, height: h), display: true)
    }
}
