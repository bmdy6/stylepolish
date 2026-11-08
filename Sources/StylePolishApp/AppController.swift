import AppKit
import SwiftUI
import Combine
import StylePolishCore

@MainActor final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = SettingsStore()
    let state = PanelModel()
    let access = AccessibilityAccess()
    let keyboard = KeyboardController()
    let history = HistoryStore()
    lazy var automatic = AutomaticPolish(access: access, settings: settings, history: history)
    lazy var panel = PolishPanel(model: state)
    var settingsSubscription: AnyCancellable?
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var capture: CapturedInput?
    var request: Task<Void, Never>?
    var requestID = UUID()
    var requestModel = ""
    var busy = false
    var enabled = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--import-key-stdin") {
            do {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !key.isEmpty else { throw PolishFailure(message: "没有输入 Key") }
                try settings.saveKey(key)
                print("Key saved to local file")
                NSApp.terminate(nil)
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--test-connection") {
            Task { @MainActor in
                do {
                    let fromStdin = CommandLine.arguments.contains("--key-stdin")
                    let key = fromStdin ? (String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : settings.credentials.current.key
                    let config = PolishConfiguration(base: settings.base, model: settings.model, key: key, profile: settings.profile, serviceTier: settings.serviceTier, credentialError: fromStdin ? nil : settings.credentials.current.warnings.first)
                    let ms = try await PolishClient().testConnection(config: config)
                    print("Connection OK: \(settings.model), \(settings.serviceTier), \(ms) ms")
                    NSApp.terminate(nil)
                } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            }
            return
        }
        #if DEBUG
        if CommandLine.arguments.contains("--latency-editor") {
            LatencyHarness.showEditor(); return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--latency-harness"), CommandLine.arguments.count > i + 1 {
            LatencyHarness.run(directory: CommandLine.arguments[i + 1]); return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--acceptance-harness"), CommandLine.arguments.count > i + 2 {
            AcceptanceHarness.run(directory: CommandLine.arguments[i + 1], base: CommandLine.arguments[i + 2]); return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--probe-notes"), CommandLine.arguments.count > i + 1 {
            do { try AcceptanceHarness.probeNotes(path: CommandLine.arguments[i + 1]); NSApp.terminate(nil) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            return
        }
        #endif
        if let i = CommandLine.arguments.firstIndex(of: "--probe-model-bundle"), CommandLine.arguments.count > i + 1 {
            Task { @MainActor in
                do {
                    guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[i + 1]).first else { throw PolishFailure(message: "App 未运行") }
                    access.activateAccessibility(for: target)
                    try await Task.sleep(nanoseconds: 500_000_000)
                    let config = PolishConfiguration(base: settings.base, model: settings.model, key: settings.credentials.current.key, profile: settings.profile, serviceTier: settings.serviceTier)
                    try await InputProbe.modelCheck(access: access, target: target, config: config)
                    NSApp.terminate(nil)
                } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--probe-bundle"), CommandLine.arguments.count > i + 1 {
            do {
                guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[i + 1]).first else { throw PolishFailure(message: "App 未运行") }
                access.activateAccessibility(for: target)
                print(try InputProbe.write(access: access, target: target).path); Diagnostics.shared.flush(); NSApp.terminate(nil)
            } catch { fputs("Target probe failed\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--probe-current") {
            do { print(try InputProbe.write(access: access).path); Diagnostics.shared.flush(); NSApp.terminate(nil) }
            catch { fputs("Focus probe failed\n", stderr); exit(1) }
            return
        }
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--safety-harness"), CommandLine.arguments.count > i + 1 {
            SafetyHarness.run(directory: CommandLine.arguments[i + 1]); return
        }
        #endif
        if CommandLine.arguments.contains("--diagnostics") {
            print("AX trusted: \(AccessibilityAccess.trusted())")
            for id in ["com.apple.Notes", "com.tencent.xinWeChat", "com.electron.lark", "com.anthropic.claudefordesktop", "com.apple.Safari", "com.google.Chrome"] {
                print("\(id): \(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) == nil ? "not installed" : "installed")")
            }
            NSApp.terminate(nil); return
        }
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--capture-fixtures"), CommandLine.arguments.count > i + 1 {
            do { try FixtureCapture.run(directory: CommandLine.arguments[i + 1]); NSApp.terminate(nil) }
            catch { fputs("Fixture capture failed\n", stderr); exit(1) }
            return
        }
        #endif
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: "StylePolish")
        statusItem.menu = makeMenu()
        state.accept = { [weak self] in self?.accept() }
        state.cancel = { [weak self] in self?.escape() }
        state.edit = { [weak self] in self?.edit() }
        state.toggle = { [weak self] in self?.state.showOriginal.toggle() }
        state.retry = { [weak self] in self?.retry() }
        keyboard.probe = { [weak self] in self?.probeInput() }
        keyboard.trigger = { [weak self] in self?.trigger() }
        keyboard.handle = { [weak self] code, flags in self?.key(code, flags) ?? false }
        keyboard.acceptAll = { [weak self] in self?.automatic.acceptAll() }
        keyboard.pointer = { [weak self] point in self?.automatic.overlay.click(at: point) ?? false }
        keyboard.scrolled = { [weak self] in
            guard self?.automatic.overlay.pointerOverPreview != true else { return }
            self?.automatic.overlay.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.automatic.sample() }
        }
        automatic.statusChanged = { [weak self] in
            guard let self else { return }
            self.refreshStatus()
            self.keyboard.start(legacyEnabled: self.shortcutEnabled)
        }
        automatic.openSettings = { [weak self] in self?.showSettings() }
        automatic.shortcutChanged = { [weak self] in guard let self else { return }; self.keyboard.start(legacyEnabled: self.shortcutEnabled) }
        NSLog("StylePolish credentials loaded: %@", settings.credentials.current.key.isEmpty ? "missing" : (settings.credentials.current.source.hasPrefix("ai-vault") ? "ai-vault" : "local file"))
        keyboard.start(legacyEnabled: shortcutEnabled)
        automatic.start()
        settingsSubscription = settings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in guard let self else { return }; self.keyboard.start(legacyEnabled: self.shortcutEnabled) }
        }
        if CommandLine.arguments.contains("--show-settings") || !UserDefaults.standard.bool(forKey: "onboarded") { showSettings(); UserDefaults.standard.set(true, forKey: "onboarded") }
    }
    var shortcutEnabled: Bool {
        settings.legacyShortcut || (settings.apps.contains("com.tencent.xinWeChat") && automatic.frontApp?.bundleIdentifier == "com.tencent.xinWeChat") || access.fallbackApps.contains(automatic.frontApp?.bundleIdentifier ?? "")
    }
    func refreshStatus() {
        let status = enabled ? automatic.status : .disabled
        statusItem.button?.image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: "StylePolish · " + status.title)
        if case .failure = status { statusItem.button?.title = " 失败" } else { statusItem.button?.title = " " + status.title }
        statusItem.button?.toolTip = status.help
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        automatic.sample()
        menu.removeAllItems()
        for item in makeMenu().items { item.menu?.removeItem(item); menu.addItem(item) }
    }
    @objc func toggleFrontApp() {
        guard let id = automatic.frontApp?.bundleIdentifier else { return }
        if settings.apps.contains(id) { settings.apps.removeAll { $0 == id } } else { settings.apps.append(id) }
        automatic.sample(force: true)
    }
    func makeMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        let commit = Bundle.main.object(forInfoDictionaryKey: "StylePolishCommit") as? String ?? "dev"
        menu.addItem(withTitle: "StylePolish \(version) · \(commit)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: (enabled ? automatic.status : .disabled).title, action: nil, keyEquivalent: "")
        if let app = automatic.frontApp, let id = app.bundleIdentifier {
            let active = settings.apps.contains(id)
            menu.addItem(withTitle: "当前 App：\(app.localizedName ?? id) · \(active ? "已启用" : "未启用")", action: nil, keyEquivalent: "")
            let item = NSMenuItem(title: active ? "停用此 App" : "启用此 App", action: #selector(toggleFrontApp), keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: enabled ? "✓ 自动检查 · ⌥ Enter 全部采纳" : "已暂停", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self; menu.addItem(toggle); menu.addItem(.separator())
        for (title, selector) in [("设置…", #selector(showSettings)), ("打开记录文件夹", #selector(openHistory)), ("在访达中显示诊断日志", #selector(openDiagnostics)), ("探测当前输入框 · ⌃⌥P", #selector(probeInput)), ("退出", #selector(quit))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc func toggleEnabled() { enabled.toggle(); automatic.enabled = enabled; if !enabled { cancelSession() }; refreshStatus() }
    @objc func quit() { automatic.stop(); cancelSession(); NSApp.terminate(nil) }
    @objc func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, openHistory: { [weak self] in self?.openHistory() }, clearHistory: { [weak self] in self?.clearHistory() }, permission: { [weak self] in self?.permission() })
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "StylePolish · 设置"; window.contentView = host; window.isReleasedWhenClosed = false; window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func permission() {
        _ = AccessibilityAccess.trusted(prompt: true)
        keyboard.start(legacyEnabled: shortcutEnabled)
        if !AccessibilityAccess.trusted(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    @objc func probeInput() {
        do { _ = try InputProbe.write(access: access) }
        catch { Diagnostics.shared.record(DiagnosticEvent(event: "probe_failed", bundleID: automatic.frontApp?.bundleIdentifier ?? "", error: "focus_unavailable")) }
    }
    @objc func openDiagnostics() {
        do { try Diagnostics.shared.prepare(); NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.shared.url]) }
        catch { showError("无法显示诊断日志") }
    }
    @objc func openHistory() {
        do { try history.prepare(); NSWorkspace.shared.open(history.directory) } catch { showError("无法打开记录文件夹") }
    }
    func clearHistory() { do { try history.clear() } catch { showError("无法清空记录文件") } }
    func trigger() {
        guard enabled, shortcutEnabled, !busy else { return }
        if panel.isVisible { cancelSession() }
        automatic.enabled = false
        keyboard.start(legacyEnabled: shortcutEnabled)
        guard keyboard.interceptionAvailable else { showError("没有键盘监听权限，请在系统设置中授权辅助功能，必要时授权输入监控并重启 App"); return }
        busy = true
        request = Task { [weak self] in
            guard let self else { return }; defer { self.busy = false }
            do {
                let captured = try await self.access.capture(enabled: self.settings.apps)
                self.capture = captured; self.state.appName = captured.appName; self.state.input = captured.input
                self.state.output = ""; self.state.showOriginal = false
                self.startPolish()
            } catch { self.showError(error.localizedDescription) }
        }
    }
    func startPolish() {
        guard let capture else { return }
        request?.cancel(); requestID = UUID(); let id = requestID
        state.phase = .loading; state.output = ""; state.latencyMS = 0; resize()
        panel.makeKeyAndOrderFront(nil)
        let config = PolishConfiguration(base: settings.base, model: settings.model, key: settings.credentials.current.key, profile: settings.profile, serviceTier: settings.serviceTier, credentialError: settings.credentials.current.warnings.first)
        requestModel = config.model
        let start = Date()
        Diagnostics.shared.record(DiagnosticEvent(event: "shortcut_request", bundleID: capture.bundleID, textLength: capture.input.utf16.count, traceID: id.uuidString, debounceMS: 0))
        request = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await PolishClient().polish(capture.input, config: config) { [weak self] partial in
                    guard let self, self.requestID == id else { return }; self.state.output = partial
                }
                guard !Task.isCancelled, self.requestID == id else { return }
                self.state.output = result; self.state.edited = result
                self.state.latencyMS = Int(Date().timeIntervalSince(start) * 1000)
                self.state.phase = .preview; self.resize()
                Diagnostics.shared.record(DiagnosticEvent(event: "shortcut_result", bundleID: capture.bundleID, traceID: id.uuidString, requestMS: self.state.latencyMS, resultMS: self.state.latencyMS))
            } catch {
                guard !Task.isCancelled, self.requestID == id else { return }
                self.state.latencyMS = Int(Date().timeIntervalSince(start) * 1000)
                Diagnostics.shared.record(DiagnosticEvent(event: "shortcut_failed", bundleID: capture.bundleID, traceID: id.uuidString, requestMS: self.state.latencyMS, error: error.localizedDescription))
                self.showError(error.localizedDescription)
            }
        }
    }
    func retry() {
        guard !busy else { return }
        if capture != nil { startPolish() } else { panel.orderOut(nil); trigger() }
    }
    func edit() {
        guard state.phase == .preview else { return }
        state.edited = state.output; state.phase = .edit; resize()
        // A nonactivating panel may become key for typing without activating the app.
        panel.makeKey()
    }
    func key(_ code: CGKeyCode, _ flags: CGEventFlags) -> Bool {
        guard panel.isVisible else { return automatic.key(code, flags) }
        if (code == 36 || code == 76), !panel.isKeyWindow { return true }
        if busy { return [36, 76, 53].contains(code) }
        if code == 53 { escape(); return true }
        if state.phase == .edit {
            if (code == 36 || code == 76), flags.contains(.maskCommand) { accept(); return true }
            return false
        }
        guard flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty else { return false }
        if code == 36 || code == 76 { if state.phase == .preview { accept() }; return true }
        if code == 14, state.phase == .preview { edit(); return true }
        if code == 31, state.phase == .preview { state.showOriginal.toggle(); return true }
        if code == 15, state.phase == .error { retry(); return true }
        return false
    }
    func escape() {
        guard !busy else { return }
        if state.phase == .edit { state.phase = .preview; panel.makeKey(); resize() }
        else { cancelSession() }
    }
    func record(action: HistoryEntry.Action, final: String?) throws {
        guard let capture else { return }
        try history.append(HistoryEntry(appBundleID: capture.bundleID, input: capture.input, output: state.output, final: final, action: action, model: requestModel, latencyMS: state.latencyMS))
    }
    func cancelSession() {
        requestID = UUID(); request?.cancel(); request = nil
        var historyFailed = false
        if capture != nil { do { try record(action: .cancel, final: nil) } catch { historyFailed = true } }
        capture = nil; panel.orderOut(nil); automatic.enabled = enabled
        if historyFailed { showNotice("已取消，但本地记录写入失败，请检查磁盘权限") }
    }
    func accept() {
        guard !busy, state.phase == .preview || state.phase == .edit, let captured = capture else { return }
        let edited = state.phase == .edit
        let final = edited ? state.edited : state.output
        guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { showError("结果为空，请重试"); return }
        panel.orderOut(nil)
        if !edited && final.utf16.elementsEqual(captured.input.utf16) {
            do { try record(action: .accept, final: final); capture = nil; panel.orderOut(nil); automatic.enabled = enabled }
            catch { capture = nil; showNotice("不用改；本地记录写入失败") }
            return
        }
        busy = true
        request = Task { [weak self] in
            guard let self else { return }; defer { self.busy = false }
            do {
                // No automatic app activation: a switch to another app must stay a copy-only action.
                let written = try await self.access.write(final, to: captured)
                if written {
                    do { try self.record(action: edited ? .edit : .accept, final: final); self.capture = nil; self.panel.orderOut(nil); self.automatic.enabled = self.enabled }
                    catch { self.capture = nil; self.showNotice("已写回，但本地记录写入失败，请检查磁盘权限") }
                } else {
                    ClipboardTransaction.copyResult(final)
                    var message = "输入框已变化，已复制"
                    do { try self.record(action: .cancel, final: nil) } catch { message += "；本地记录写入失败" }
                    self.capture = nil; self.showNotice(message)
                }
            } catch { self.showError(error.localizedDescription) }
        }
    }
    func resize() {
        let text = state.phase == .preview ? state.input + state.output : state.phase == .edit ? state.edited : state.input + state.message
        let rect = (text as NSString).boundingRect(with: NSSize(width: 408, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 15)])
        panel.position(bounds: capture?.bounds, fallbackWindow: capture.flatMap { $0.bundleID == "com.tencent.xinWeChat" ? access.windowBounds($0.element) : nil }, height: state.phase == .edit ? 240 : ceil(rect.height) + 130)
    }
    func showError(_ message: String) { state.message = message; state.phase = .error; if capture == nil { state.appName = "StylePolish"; state.input = "" }; resize(); panel.makeKeyAndOrderFront(nil) }
    func showNotice(_ message: String) { state.message = message; state.phase = .notice; resize(); panel.makeKeyAndOrderFront(nil) }
}
