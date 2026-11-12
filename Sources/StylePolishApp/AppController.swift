import AppKit
import SwiftUI
import Combine
import StylePolishCore

@MainActor final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let settings = SettingsStore()
    let state = PanelModel()
    let access = AccessibilityAccess()
    let keyboard = KeyboardController()
    var history: HistoryStore { settings.history }
    lazy var automatic = AutomaticPolish(access: access, settings: settings, history: history)
    lazy var panel = PolishPanel(model: state)
    var inviteSubscription: AnyCancellable?
    var settingsSubscription: AnyCancellable?
    private var activationObserver: NSObjectProtocol?
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var reportWindow: NSWindow?
    lazy var onboarding = OnboardingController(settings: settings, permission: { [weak self] in self?.permission() })
    var capture: CapturedInput?
    var request: Task<Void, Never>?
    var requestID = UUID()
    private var diagnosticTrace: DiagnosticTrace?
    private var launchDiagnostic: DiagnosticEvent?
    private var exportStatus = ""
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
                    let config = fromStdin ? PolishConfiguration(base: settings.base, model: settings.model, key: key, profile: settings.profile, serviceTier: settings.serviceTier) : settings.configuration()
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
        #endif
        if let i = CommandLine.arguments.firstIndex(of: "--probe-model-bundle"), CommandLine.arguments.count > i + 1 {
            Task { @MainActor in
                do {
                    guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[i + 1]).first else { throw PolishFailure(message: "App 未运行") }
                    try await Task.sleep(nanoseconds: 500_000_000)
                    let config = settings.configuration()
                    try await InputProbe.modelCheck(access: access, target: target, config: config)
                    NSApp.terminate(nil)
                } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--probe-bundle"), CommandLine.arguments.count > i + 1 {
            do {
                guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[i + 1]).first else { throw PolishFailure(message: "App 未运行") }
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
            for id in SupportedApps.all {
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
        var launch = DiagnosticEnvironment.launch(); launch.trusted = AccessibilityAccess.trusted(); launch.debugEnabled = settings.debugMode; launch.engine = settings.engine.rawValue
        launchDiagnostic = launch; Diagnostics.shared.record(launch); Diagnostics.shared.permissionChanged(launch.trusted ?? false)
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
        keyboard.pointer = { [weak self] point in
            guard let self, self.access.targetSupported else { return false }
            return self.automatic.overlay.click(at: point)
        }
        keyboard.scrolled = { [weak self] in
            guard self?.automatic.overlay.hideForScroll(at: NSEvent.mouseLocation) == true else { return }
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
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.access.targetSupported { self.cancelSession() }
                self.keyboard.start(legacyEnabled: self.shortcutEnabled)
            }
        }
        keyboard.start(legacyEnabled: shortcutEnabled)
        automatic.start()
        settingsSubscription = settings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in guard let self else { return }; self.keyboard.start(legacyEnabled: self.shortcutEnabled); self.refreshStatus() }
        }
        inviteSubscription = settings.invite.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStatus() }
        }
        if settings.engine == .invite { Task { await settings.invite.refresh(base: settings.relayBase) } }
        if CommandLine.arguments.contains("--show-settings") { showSettings() }
        else if !settings.onboarded || !AccessibilityAccess.trusted() { showGuide() }
        refreshStatus()
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        Diagnostics.shared.flush()
    }
    var shortcutEnabled: Bool {
        // Live foreground identity: cached automatic.frontApp can still name WeChat after a switch.
        enabled && SupportedApps.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
    var displayStatus: ActivityStatus {
        if !AccessibilityAccess.trusted() { return .fallback(.permission) }
        if !enabled { return .disabled }
        if settings.engine == .local { return .local }
        if settings.engine == .invite, let blocked = settings.invite.block(for: settings.relayBase) { return .fallback(blocked) }
        if automatic.fallbackReason != .none { return .fallback(automatic.fallbackReason) }
        if settings.engine == .invite, let remaining = settings.invite.remainingPercent { return .trial(remaining) }
        return automatic.status
    }
    func refreshStatus() {
        let status = displayStatus
        statusItem.button?.image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: "StylePolish · " + status.title)
        statusItem.button?.title = " " + status.title
        statusItem.button?.toolTip = status.help
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        automatic.sample()
        menu.removeAllItems()
        for item in makeMenu(showLowQuotaWarning: true).items { item.menu?.removeItem(item); menu.addItem(item) }
    }
    func makeMenu(showLowQuotaWarning: Bool = false) -> NSMenu {
        let menu = NSMenu(); menu.delegate = self
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        let commit = Bundle.main.object(forInfoDictionaryKey: "StylePolishCommit") as? String ?? "dev"
        menu.addItem(withTitle: "StylePolish \(version) · \(commit)", action: nil, keyEquivalent: "")
        if settings.debugMode { menu.addItem(withTitle: "⚠ 调试模式已开启 · 正文只存本机，不上传", action: nil, keyEquivalent: "") }
        if !exportStatus.isEmpty { menu.addItem(withTitle: exportStatus, action: nil, keyEquivalent: "") }
        let status = displayStatus
        let reason: FallbackReason? = { if case .fallback(let reason) = status { return reason }; return nil }()
        let detail = reason == .other ? automatic.fallbackSummary.map { $0 + "，已改用本地规则 · 去设置 ›" } : nil
        if showLowQuotaWarning, settings.engine == .invite, let warning = settings.invite.consumeLowQuotaWarning() {
            let item = NSMenuItem(title: warning, action: #selector(showSettings), keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        let statusRow = NSMenuItem(title: detail ?? reason?.menuTitle ?? status.title, action: reason == .network || reason == nil ? nil : #selector(repairStatus), keyEquivalent: "")
        statusRow.target = self; menu.addItem(statusRow)
        menu.addItem(withTitle: "目前只支持微信", action: nil, keyEquivalent: "")
        let engineItem = NSMenuItem(title: "润色方式：" + settings.engine.title, action: nil, keyEquivalent: "")
        let engines = NSMenu()
        for engine in PolishEngine.allCases {
            let item = NSMenuItem(title: engine.title, action: #selector(changeEngine(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = engine.rawValue; item.state = settings.engine == engine ? .on : .off; engines.addItem(item)
        }
        engineItem.submenu = engines; menu.addItem(engineItem)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: enabled ? "✓ 自动检查 · ⌥ Enter 全部采纳" : "已暂停", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self; menu.addItem(toggle); menu.addItem(.separator())
        for (title, selector) in [("本周表达报告", #selector(showWeeklyReport)), ("导出诊断包…", #selector(exportDiagnostics)), ("使用说明…", #selector(showGuide)), ("设置…", #selector(showSettings)), ("打开记录文件夹", #selector(openHistory)), ("在访达中显示诊断日志", #selector(openDiagnostics)), ("探测当前输入框 · ⌃⌥P", #selector(probeInput)), ("退出", #selector(quit))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    @objc func changeEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let engine = PolishEngine(rawValue: raw) else { return }
        settings.engine = engine; automatic.sample(force: true); refreshStatus()
    }
    @objc func repairStatus() {
        if case .fallback(.permission) = displayStatus { showGuide() } else { showSettings() }
    }
    @objc func showGuide() { onboarding.show() }
    @objc func toggleEnabled() { enabled.toggle(); automatic.enabled = enabled; if !enabled { cancelSession() }; refreshStatus() }
    @objc func quit() { automatic.stop(); cancelSession(); NSApp.terminate(nil) }
    @objc func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(settings: settings, openHistory: { [weak self] in self?.openHistory() }, clearHistory: { [weak self] in self?.clearHistory() }, permission: { [weak self] in self?.showGuide() }, guide: { [weak self] in self?.showGuide() }, sizeChanged: { [weak self] height in
                DispatchQueue.main.async {
                    guard let window = self?.settingsWindow, height > 0 else { return }
                    let top = window.frame.maxY
                    window.setContentSize(NSSize(width: 560, height: height))
                    window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
                }
            })
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "StylePolish · 设置"; window.contentView = host; window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua); window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func showWeeklyReport() {
        // Recreate on open so the rolling time window advances even without new events.
        if reportWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 780), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "StylePolish · 本周表达报告"; window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua); window.center(); reportWindow = window
        }
        reportWindow?.contentView = NSHostingView(rootView: WeeklyReportWindowContent(settings: settings))
        NSApp.activate(ignoringOtherApps: true); reportWindow?.makeKeyAndOrderFront(nil)
    }
    func permission() {
        _ = AccessibilityAccess.trusted(prompt: true)
        keyboard.start(legacyEnabled: shortcutEnabled)
        if !AccessibilityAccess.trusted(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    @objc func probeInput() {
        guard access.targetSupported else { return }
        do { _ = try InputProbe.write(access: access) }
        catch { Diagnostics.shared.record(DiagnosticEvent(event: "probe_failed", bundleID: automatic.frontApp?.bundleIdentifier ?? "", error: "focus_unavailable")) }
    }
    @objc func exportDiagnostics() {
        let summary = settings.diagnosticSummary.merging(DiagnosticEnvironment.summary(launchDiagnostic ?? DiagnosticEnvironment.launch())) { _, value in value }
        guard let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first else { exportStatus = "导出失败：找不到桌面"; return }
        exportStatus = "正在导出诊断包…"
        Task {
            do {
                _ = try await Task.detached { try Diagnostics.shared.export(to: desktop, summary: summary) }.value
                exportStatus = "诊断包已保存到桌面"
            } catch { exportStatus = "导出失败：请检查桌面写入权限" }
        }
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
                let captured = try await self.access.capture()
                guard self.shortcutEnabled, !Task.isCancelled else { return }
                self.capture = captured; self.state.appName = captured.appName; self.state.input = captured.input
                self.state.output = ""; self.state.showOriginal = false
                self.startPolish()
            } catch { if self.shortcutEnabled { self.showError(error.localizedDescription) } }
        }
    }
    func startPolish() {
        guard shortcutEnabled, let capture, SupportedApps.contains(capture.bundleID) else { return }
        request?.cancel(); requestID = UUID(); let id = requestID
        let diagnostics = DiagnosticTrace(bundleID: capture.bundleID)
        diagnosticTrace = diagnostics
        diagnostics.capture(text: capture.input, role: access.attribute(capture.element, kAXRoleAttribute) as? String, writable: access.settable(capture.element, kAXValueAttribute) || access.settable(capture.element, kAXSelectedTextAttribute), selection: capture.range, attachment: capture.attachments, hasPosition: capture.bounds != nil)
        diagnostics.started(engine: settings.engine, level: settings.level, cacheHit: false)
        state.phase = .loading; state.output = ""; state.latencyMS = 0; resize()
        panel.makeKeyAndOrderFront(nil)
        let config = settings.configuration()
        let engine = settings.engine
        requestModel = engine == .local ? "local-rules" : config.model
        let start = Date()
        Diagnostics.shared.record(DiagnosticEvent(event: "shortcut_request", bundleID: capture.bundleID, textLength: capture.input.utf16.count, traceID: diagnostics.id, debounceMS: 0, engine: engine.rawValue, fallback: FallbackReason.none))
        request = Task { [weak self] in
            guard let self else { return }
            do {
                var fallbackReason = FallbackReason.none
                var fallbackSummary: String?
                let result: String
                var diagnosticEdits: [Suggestion]?
                if engine == .local {
                    let local = try await CheckEngine().check(capture.input, engine: .local, config: config, disabledKinds: self.settings.disabledKinds)
                    diagnosticEdits = local.suggestions
                    result = SuggestionPreview(source: capture.input, edits: local.suggestions)?.output ?? capture.input
                } else {
                    do {
                        result = try await PolishClient().polish(capture.input, config: config, metrics: { diagnostics.metrics($0, model: config.model) }) { [weak self] partial in
                            guard let self, self.requestID == id, self.shortcutEnabled else { return }; self.state.output = partial
                        }
                    } catch {
                        try Task.checkCancellation()
                        guard self.shortcutEnabled else { return }
                        if error is CancellationError { throw error }
                        fallbackReason = FallbackReason.classify(error)
                        fallbackSummary = (error as? PolishFailure)?.message ?? "AI 请求失败"
                        let fallback = try await CheckEngine().check(capture.input, engine: .local, config: config, disabledKinds: self.settings.disabledKinds)
                        diagnosticEdits = fallback.suggestions
                        result = SuggestionPreview(source: capture.input, edits: fallback.suggestions)?.output ?? capture.input
                        self.requestModel = "local-rules"
                        Diagnostics.shared.record(DiagnosticEvent(event: "shortcut_fallback", bundleID: capture.bundleID, traceID: diagnostics.id, engine: engine.rawValue, fallback: fallbackReason))
                    }
                }
                guard !Task.isCancelled, self.requestID == id, self.shortcutEnabled else { return }
                self.settings.checked(CheckResult(suggestions: diagnosticEdits ?? [], fallback: fallbackReason, failureSummary: fallbackSummary), config: config)
                self.automatic.updateFallback(fallbackReason, summary: fallbackSummary)
                self.state.output = result; self.state.edited = result
                self.state.latencyMS = Int(Date().timeIntervalSince(start) * 1000)
                let edits = diagnosticEdits ?? (result.utf16.elementsEqual(capture.input.utf16) ? [] : [Suggestion(range: NSRange(location: 0, length: capture.input.utf16.count), original: capture.input, replacement: result, kind: .fluency, why: "")])
                diagnostics.result(source: capture.input, suggestions: edits, engine: engine, fallback: fallbackReason, unclear: engine != .local && fallbackReason == .none ? nil : false, requestMS: self.state.latencyMS, resultMS: self.state.latencyMS)
                diagnostics.presented("shortcut_panel", mode: "twoLine", hasPosition: capture.bounds != nil, count: edits.count)
                self.state.phase = .preview; self.resize()
                Diagnostics.shared.record(DiagnosticEvent(event: "shortcut_result", bundleID: capture.bundleID, traceID: diagnostics.id, requestMS: self.state.latencyMS, resultMS: self.state.latencyMS, engine: engine.rawValue, fallback: fallbackReason))
            } catch {
                guard !Task.isCancelled, self.requestID == id, self.shortcutEnabled else { return }
                self.state.latencyMS = Int(Date().timeIntervalSince(start) * 1000)
                Diagnostics.shared.record(DiagnosticEvent(event: "shortcut_failed", bundleID: capture.bundleID, traceID: diagnostics.id, requestMS: self.state.latencyMS, error: "check_failed"))
                self.showError(error.localizedDescription)
            }
        }
    }
    func retry() {
        guard !busy else { return }
        if capture != nil { startPolish() } else { panel.orderOut(nil); trigger() }
    }
    func edit() {
        guard shortcutEnabled else { return }
        guard state.phase == .preview else { return }
        state.edited = state.output; state.phase = .edit; resize()
        // A nonactivating panel may become key for typing without activating the app.
        panel.makeKey()
    }
    func key(_ code: CGKeyCode, _ flags: CGEventFlags) -> Bool {
        guard access.targetSupported else { return false }
        if onboarding.isKeyWindow { return false }
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
        diagnosticTrace?.action("escape"); diagnosticTrace = nil
        requestID = UUID(); request?.cancel(); request = nil
        var historyFailed = false
        if capture != nil { do { try record(action: .cancel, final: nil) } catch { historyFailed = true } }
        capture = nil; panel.orderOut(nil); automatic.enabled = enabled
        if historyFailed { showNotice("已取消，但本地记录写入失败，请检查磁盘权限") }
    }
    func accept() {
        guard shortcutEnabled else { cancelSession(); return }
        guard !busy, state.phase == .preview || state.phase == .edit, let captured = capture else { return }
        let diagnostics = diagnosticTrace
        diagnostics?.action("accept_all", count: 1)
        let edited = state.phase == .edit
        let final = edited ? state.edited : state.output
        guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { showError("结果为空，请重试"); return }
        panel.orderOut(nil)
        if !edited && final.utf16.elementsEqual(captured.input.utf16) {
            diagnostics?.write(source: captured.input, expected: final, readback: captured.input, method: "none", attachment: captured.attachments)
            do { try record(action: .accept, final: final); capture = nil; panel.orderOut(nil); automatic.enabled = enabled }
            catch { capture = nil; showNotice("不用改；本地记录写入失败") }
            return
        }
        busy = true
        request = Task { [weak self] in
            guard let self else { return }; defer { self.busy = false }
            do {
                // A switch to another app must not write the editor or clipboard.
                guard self.shortcutEnabled else { self.cancelSession(); return }
                let written = try await self.access.write(final, to: captured, diagnostics: diagnostics)
                guard self.shortcutEnabled else { self.cancelSession(); return }
                if written {
                    do { try self.record(action: edited ? .edit : .accept, final: final); self.capture = nil; self.panel.orderOut(nil); self.automatic.enabled = self.enabled }
                    catch { self.capture = nil; self.showNotice("已写回，但本地记录写入失败，请检查磁盘权限") }
                } else {
                    ClipboardTransaction.copyResult(final)
                    var message = "输入框已变化，已复制"
                    do { try self.record(action: .cancel, final: nil) } catch { message += "；本地记录写入失败" }
                    self.capture = nil; self.showNotice(message)
                }
            } catch { if self.shortcutEnabled { self.showError(error.localizedDescription) } }
        }
    }
    func resize() {
        let text = state.phase == .preview ? state.input + state.output : state.phase == .edit ? state.edited : state.input + state.message
        let rect = (text as NSString).boundingRect(with: NSSize(width: 408, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 15)])
        panel.position(bounds: capture?.bounds, fallbackWindow: capture.flatMap { SupportedApps.contains($0.bundleID) ? access.windowBounds($0.element) : nil }, height: state.phase == .edit ? 240 : ceil(rect.height) + 130)
    }
    func showError(_ message: String) { guard access.targetSupported else { return }; state.message = message; state.phase = .error; if capture == nil { state.appName = "StylePolish"; state.input = "" }; resize(); panel.makeKeyAndOrderFront(nil) }
    func showNotice(_ message: String) { guard access.targetSupported else { return }; state.message = message; state.phase = .notice; resize(); panel.makeKeyAndOrderFront(nil) }
}
