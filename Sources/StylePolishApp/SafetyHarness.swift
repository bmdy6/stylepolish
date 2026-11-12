#if DEBUG
import AppKit
import StylePolishCore

private final class UnreadableEditor: NSTextView {
    override func accessibilityValue() -> String? { nil }
}

// Isolated local simulation. Never targets WeChat or sends a network request.
@MainActor enum SafetyHarness {
    private static var window: NSWindow?
    static func run(directory: String) {
        NSApp.setActivationPolicy(.regular)
        let editor = UnreadableEditor(frame: NSRect(x: 16, y: 16, width: 540, height: 180))
        editor.font = .systemFont(ofSize: 20)
        editor.string = "这个的话我觉得然后明天在做吧"
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 572, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "StylePolish · AXValue 不可读安全验收（模拟）"
        window.contentView?.addSubview(editor); self.window = window
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor); NSApp.activate(ignoringOtherApps: true)
        let saved = ClipboardTransaction.snapshot()
        var clipboardTouched = false
        Task { @MainActor in
            var lines: [String] = []
            let output = URL(fileURLWithPath: directory)
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            func check(_ result: Bool, _ name: String) throws {
                lines.append("\(result ? "PASS" : "FAIL") \(name)")
                if !result { throw PolishFailure(message: name) }
            }
            defer { if clipboardTouched, NSPasteboard.general.string(forType: .string) == "simulation sentinel" { ClipboardTransaction.restore(saved, ifOwned: NSPasteboard.general.changeCount) } }
            do {
                NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
                try await Task.sleep(nanoseconds: 1_000_000_000)
                lines.append("AX trusted: \(AccessibilityAccess.trusted()); front: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"); self: \(ProcessInfo.processInfo.processIdentifier)")
                let access = AccessibilityAccess(testingApp: NSRunningApplication.current.bundleIdentifier ?? "")
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier else { throw PolishFailure(message: "BLOCKED: another app or system permission dialog owns focus") }
                guard let (_, focused) = access.focused() else { throw PolishFailure(message: "AX focus unavailable; authorize accessibility") }
                try check(access.attribute(focused, kAXValueAttribute) == nil, "custom native editor hides AXValue")
                clipboardTouched = true
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString("simulation sentinel", forType: .string)
                let capture = try await access.capture(forceWholeClipboard: true)
                try check(capture.input == editor.string, "Cmd-A/C captures entire unreadable editor")
                try check(NSPasteboard.general.string(forType: .string) == "simulation sentinel", "clipboard restored after capture")
                let model = PanelModel(); model.appName = "模拟输入框"; model.input = capture.input; model.output = "我觉得明天再做吧"; model.phase = .preview
                let panel = PolishPanel(model: model); panel.position(bounds: capture.bounds, height: 190); panel.makeKeyAndOrderFront(nil)
                try await Task.sleep(nanoseconds: 200_000_000)
                try check(panel.isKeyWindow, "preview is key window")
                // An actual key press is safe here: both windows belong to this harness.
                let source = CGEventSource(stateID: .hidSystemState)
                for code: CGKeyCode in [36, 76] {
                    CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.postToPid(ProcessInfo.processInfo.processIdentifier)
                    CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.postToPid(ProcessInfo.processInfo.processIdentifier)
                }
                try await Task.sleep(nanoseconds: 200_000_000)
                try check(editor.string == capture.input, "Return and keypad Enter never reach lower editor")
                panel.orderOut(nil); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
                try await Task.sleep(nanoseconds: 100_000_000)
                try check(try await access.write(model.output, to: capture), "guarded Cmd-A/V writes unreadable editor")
                try check(editor.string == model.output, "exact rewritten text matches")
                try check(NSPasteboard.general.string(forType: .string) == "simulation sentinel", "clipboard restored after write")
                lines.append("No real app or external service used; synthetic editor only.")
            } catch { lines.append("ERROR " + error.localizedDescription) }
            try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("safety-harness.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}

#endif
