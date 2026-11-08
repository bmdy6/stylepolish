#if DEBUG
import AppKit
import StylePolishCore

/// Explicit paid smoke. A separate signed app process owns the synthetic editor:
/// querying our own AX server from the main thread would distort latency.
@MainActor enum LatencyHarness {
    private static var window: NSWindow?
    private static var runner: AutomaticPolish?
    private static let source = "这个方案非长好，我们明天在讨论。"
    static func showEditor() {
        NSApp.setActivationPolicy(.regular)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 160))
        editor.font = .systemFont(ofSize: 20); editor.string = source
        let window = NSWindow(contentRect: NSRect(x: 250, y: 250, width: 540, height: 160), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "StylePolish · 独立合成输入框"
        window.contentView = editor; self.window = window
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
        NSApp.activate(ignoringOtherApps: true)
    }
    static func run(directory: String) {
        Task { @MainActor in
            var lines: [String] = []
            let url = URL(fileURLWithPath: directory)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let suite = "org.bmdy6.StylePolish.latency." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            let history = HistoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
            var fixture: NSRunningApplication?
            defer {
                runner?.stop(); runner = nil; fixture?.terminate()
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: history.directory)
            }
            do {
                let access = AccessibilityAccess()
                let live = SettingsStore()
                let config = PolishConfiguration(base: live.base, model: live.model, key: live.credentials.current.key, profile: live.profile, serviceTier: live.serviceTier)
                let warmStart = Date()
                await PolishClient().warmConnection(config: config)
                lines.append("startup-connection-warmup-ms=\(Int(Date().timeIntervalSince(warmStart) * 1000))")
                let launch = NSWorkspace.OpenConfiguration()
                launch.createsNewApplicationInstance = true
                launch.arguments = ["--latency-editor"]
                fixture = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: launch)
                guard let fixture, fixture.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                    throw PolishFailure(message: "Synthetic editor did not start in a separate process")
                }
                // Launch completion can precede the child window/AX server becoming ready.
                // Wait for the exact synthetic field; never substitute another front app.
                let readyStart = Date()
                var readyCapture: CapturedInput?
                while Date().timeIntervalSince(readyStart) < 4 {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier,
                       let capture = access.automaticCapture(enabled: [fixture.bundleIdentifier ?? ""]), capture.input == source {
                        readyCapture = capture; break
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                guard let capture = readyCapture else {
                    lines.append("fixture-pid=\(fixture.processIdentifier) front-pid=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1) ax-trusted=\(AccessibilityAccess.trusted())")
                    throw PolishFailure(message: "Synthetic editor unavailable or lost focus")
                }
                lines.append("fixture-ready-ms=\(Int(Date().timeIntervalSince(readyStart) * 1000))")
                let settings = SettingsStore(defaults: defaults)
                settings.apps = [fixture.bundleIdentifier ?? ""]
                let automatic = AutomaticPolish(access: access, settings: settings, history: history)
                let keyboard = KeyboardController()
                keyboard.acceptAll = { automatic.acceptAll() }
                keyboard.handle = { code, flags in automatic.key(code, flags) }
                keyboard.start()
                defer { withExtendedLifetime(keyboard) {} }
                runner = automatic; automatic.configurationProvider = { config }
                var complete = false, cacheHits = 0
                let start = Date()
                automatic.trace = { trace in
                    lines.append("TRACE \(Int(Date().timeIntervalSince(start) * 1000)) \(trace)")
                    if trace.hasPrefix("published ") { complete = true }
                    if trace.hasPrefix("cache hit") { cacheHits += 1 }
                }
                automatic.start()
                var firstVisible: Int?
                while (!complete || firstVisible == nil), Date().timeIntervalSince(start) < 30 {
                    if automatic.overlay.previewVisible, firstVisible == nil {
                        firstVisible = Int(Date().timeIntervalSince(start) * 1000)
                    }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                guard complete, let visible = firstVisible else { throw PolishFailure(message: "No visible result within 30s") }
                lines += ["model=\(config.model)", "stop-to-visible-ms=\(visible)", "complete-ms=\(Int(Date().timeIntervalSince(start) * 1000))", "suggestions=\(automatic.session.suggestions.count)", "source-unchanged=\(access.isCurrent(capture, text: source))"]
                lines += ["preview-visible=\(automatic.overlay.previewVisible)", "preview-source-matches=\(automatic.overlay.preview?.source == source)", "front-fixture=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier)"]
                if !CommandLine.arguments.contains("--skip-harness-screenshot") {
                    let shotStatus = FixtureCapture.screenshot(to: url.appendingPathComponent("preview-screen.png"), rect: automatic.overlay.previewFrame)
                    lines.append("screenshot-exit=\(shotStatus)")
                } else { lines.append("screenshot-skipped=explicit-headless-retest") }
                // A synthetic typing event exercises the real event tap; never target
                // WeChat/Linear. Verify focus remains in this fixture first.
                if access.isCurrent(capture, text: source) {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
                    var chars = Array("啊".utf16)
                    event?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
                    event?.post(tap: .cghidEventTap)
                    CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)?.post(tap: .cghidEventTap)
                    try await Task.sleep(nanoseconds: 100_000_000)
                    let updated = access.attribute(capture.element, kAXValueAttribute) as? String ?? ""
                    lines += ["typing-reached-fixture=\(updated.contains("啊"))", "old-preview-invalidated=\(automatic.overlay.preview?.source != source)"]
                    // Restore only our synthetic editor so the cache measurement uses
                    // the same source; this is never used on real application fields.
                    _ = AXUIElementSetAttributeValue(capture.element, kAXValueAttribute as CFString, source as CFString)
                }
                let cachedStart = Date(); complete = false
                automatic.sample(force: true)
                while !complete, Date().timeIntervalSince(cachedStart) < 3 { try await Task.sleep(nanoseconds: 10_000_000) }
                lines += ["cache-complete=\(complete)", "cache-ms=\(Int(Date().timeIntervalSince(cachedStart) * 1000))", "cache-hits=\(cacheHits)", "WeChat-Linear-writes=0"]
                if automatic.overlay.previewVisible, access.isCurrent(capture, text: source) {
                    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
                    CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
                    try await Task.sleep(nanoseconds: 100_000_000)
                    automatic.sample()
                    lines.append("escape-keeps-preview-hidden=\(!automatic.overlay.previewVisible)")
                    automatic.sample(force: true)
                    let refresh = Date()
                    while !automatic.overlay.previewVisible, Date().timeIntervalSince(refresh) < 3 { try await Task.sleep(nanoseconds: 20_000_000) }
                }
                if let snapshot = automatic.overlay.preview, access.isCurrent(capture, text: source) {
                    for down in [true, false] {
                        let event = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down)
                        event?.flags = .maskAlternate; event?.post(tap: .cghidEventTap)
                    }
                    try await Task.sleep(nanoseconds: 200_000_000)
                    lines += ["option-enter-accepted-all=\(access.isCurrent(capture, text: snapshot.output))", "event-tap=\(keyboard.interceptionAvailable)"]
                }
                try lines.joined(separator: "\n").write(to: url.appendingPathComponent("latency-harness.txt"), atomically: true, encoding: .utf8)
                Diagnostics.shared.flush()
                runner?.stop(); fixture.terminate()
                for _ in 0..<10 where !fixture.isTerminated { try await Task.sleep(nanoseconds: 50_000_000) }
                if !fixture.isTerminated { fixture.forceTerminate() }
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: history.directory)
                NSApp.terminate(nil)
            } catch {
                lines.append("ERROR \(error.localizedDescription)")
                try? lines.joined(separator: "\n").write(to: url.appendingPathComponent("latency-harness.txt"), atomically: true, encoding: .utf8)
                runner?.stop(); fixture?.forceTerminate()
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: history.directory)
                fputs(lines.joined(separator: "\n") + "\n", stderr); exit(1)
            }
        }
    }
}

#endif
