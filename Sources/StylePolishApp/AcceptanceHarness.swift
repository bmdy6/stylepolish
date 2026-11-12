#if DEBUG
import AppKit
import StylePolishCore

/// Explicit developer-only mode: uses only an app-owned editor and temporary preferences/history.
/// Never reads a user's editor, keychain, profile or configured model service.
@MainActor enum AcceptanceHarness {
    static var window: NSWindow?
    static var runner: AutomaticPolish?
    static func run(directory: String, base: String) {
        NSApp.setActivationPolicy(.regular)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 180))
        textView.font = NSFont.systemFont(ofSize: 20)
        textView.string = "这个的话我看了一下。下一句没有问题。"
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 540, height: 210), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "StylePolish · 合成验收输入框"
        let scroll = NSScrollView(frame: NSRect(x: 10, y: 10, width: 520, height: 180)); scroll.documentView = textView
        window.contentView?.addSubview(scroll); self.window = window
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(textView); NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            var lines: [String] = []
            func check(_ condition: Bool, _ label: String) throws {
                lines.append("\(condition ? "PASS" : "FAIL") \(label)")
                if !condition { throw PolishFailure(message: label) }
            }
            func waitUntil(_ condition: () -> Bool) async throws {
                let deadline = Date().addingTimeInterval(4)
                while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
            }
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let suite = "org.bmdy6.StylePolish.acceptance." + UUID().uuidString
            let defaults = MemoryDefaults()
            defer { defaults.removePersistentDomain(forName: suite); runner?.stop(); runner = nil; window.orderOut(nil) }
            do {
                try await Task.sleep(nanoseconds: 700_000_000)
                window.makeKeyAndOrderFront(nil); window.makeFirstResponder(textView)
                NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
                try await Task.sleep(nanoseconds: 500_000_000)
                let bundle = NSRunningApplication.current.bundleIdentifier ?? ""
                let access = AccessibilityAccess(testingApp: bundle)
                let settings = SettingsStore(defaults: defaults)
                settings.base = base; settings.model = "harness"
                let history = HistoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("StylePolish-harness-" + UUID().uuidString))
                let automatic = AutomaticPolish(access: access, settings: settings, history: history); runner = automatic
                automatic.trace = { lines.append("TRACE " + $0) }
                automatic.configurationProvider = { PolishConfiguration(base: base, model: "harness", key: "synthetic-test-value", profile: "") }
                let capture = access.automaticCapture()
                try check(capture != nil, "AX captures the app-owned native editor")
                automatic.start()
                try await waitUntil { automatic.session.suggestions.count == 1 }
                try check(automatic.session.suggestions.count == 1, "one-second debounce and local JSON/SSE produce one suggestion")
                let item = automatic.session.suggestions[0]
                try check(access.rangeBounds(item.edit.range, in: capture!.element) != nil, "AX bounds for UTF-16 range available")
                let accepted = await automatic.accept(item.id)
                try check(accepted, "guarded AX segment replacement succeeds")
                try check(textView.string == "这个我看了一下。下一句没有问题。", "only the suggested segment changed")
                try await Task.sleep(nanoseconds: 1_600_000_000)
                try check(automatic.session.suggestions.isEmpty, "clean text has no suggestions")
                // Cache must avoid re-requesting the unchanged second sentence (server log is checked separately).
                textView.string = "这个的话我看了一下。下一句没有问题。"
                textView.didChangeText()
                automatic.sample(force: true)
                try await waitUntil { automatic.session.suggestions.count == 1 }
                lines.append("Cache restore source: \(automatic.session.text); suggestions=\(automatic.session.suggestions.count)")
                try check(automatic.session.suggestions.count == 1, "cached original sentence restores suggestion")
                let stale = automatic.session.suggestions[0]
                textView.string = "用户现在自己改了这句话。下一句没有问题。"
                let acceptedStale = await automatic.accept(stale.id)
                try check(!acceptedStale, "stale source refuses AX write")
                try check(textView.string.hasPrefix("用户现在自己改了"), "stale write leaves editor untouched")
                try await Task.sleep(nanoseconds: 1_500_000_000)
                let historyText = (try? String(contentsOf: history.file, encoding: .utf8)) ?? ""
                try check(historyText.contains("\"action\":\"accept\""), "accept event persisted")
                try check(historyText.contains("\"action\":\"expired\""), "stale suggestion emits expired event")
                try Data(contentsOf: history.file).write(to: output.appendingPathComponent("harness-history.jsonl"))
                try FileManager.default.removeItem(at: history.directory)
                lines.append("Scope: synthetic app-owned NSTextView only; not real apps or real-model acceptance.")
                try lines.joined(separator: "\n").write(to: output.appendingPathComponent("harness.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            } catch {
                lines.append("Error: \(error.localizedDescription)")
                try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("harness.txt"), atomically: true, encoding: .utf8)
                fputs(lines.joined(separator: "\n") + "\n", stderr); exit(1)
            }
        }
    }
}

#endif
