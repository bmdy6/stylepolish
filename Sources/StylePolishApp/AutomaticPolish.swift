import AppKit
import Combine
import StylePolishCore

@MainActor final class AutomaticPolish {
    let access: AccessibilityAccess
    let settings: SettingsStore
    let history: HistoryStore
    let observer = InputObserver()
    let overlay = InlineOverlay()
    let indicator = InputIndicator()
    private var activatedPID: pid_t?
    private var lastProbe = ""
    private var changedAt = Date()
    private var indicatorState: InputIndicatorState = .watching
    var openSettings: (() -> Void)?
    private var unreadableElement: AXUIElement?
    private var unreadablePID: pid_t?
    private var readGate = InputReadGate()
    var shortcutChanged: (() -> Void)?
    let debounce = SuggestionDebouncer()
    private(set) var session = SuggestionSession()
    private var capture: CapturedInput?
    /// Full-field cache per app/model/profile; a changed sentence needs the whole context.
    private var caches: [String: SentenceCache] = [:]
    private var cache: SentenceCache {
        get { caches[configuration] ?? SentenceCache() }
        set { if caches.count >= 20, caches[configuration] == nil { caches.removeAll() }; caches[configuration] = newValue }
    }
    private var request: Task<Void, Never>?
    private var warmup: Task<Void, Never>?
    private var generation = UUID()
    private var previewReady = false
    private var previewDismissed = false
    private var configuration = ""
    private var subscription: AnyCancellable?
    private var hidden = Set<String>()
    private var eventModel = ""
    private var eventLevel = Strictness.standard
    private var writing = false
    var enabled = true { didSet { if enabled { sample(force: true) } else { suspend() } } }
    var trace: ((String) -> Void)?
    var configurationProvider: (() -> PolishConfiguration)?
    var failed: ((Bool) -> Void)?
    var statusChanged: (() -> Void)?
    private(set) var status: ActivityStatus = .idle { didSet { if oldValue != status { statusChanged?() } } }
    private(set) var frontApp: NSRunningApplication? {
        didSet { if oldValue?.processIdentifier != frontApp?.processIdentifier { statusChanged?() } }
    }
    init(access: AccessibilityAccess, settings: SettingsStore, history: HistoryStore) {
        self.access = access; self.settings = settings; self.history = history
        indicator.click = { [weak self] in
            guard let self else { return }
            if case .modelFailure = self.indicator.state { self.openSettings?() }
            else { self.overlay.showList() }
        }
        observer.changed = { [weak self] in self?.sample() }
        overlay.accept = { [weak self] in self?.accept($0) }
        overlay.ignore = { [weak self] in self?.ignore($0) }
        overlay.disable = { [weak self] in self?.disable($0) }
        overlay.acceptAll = { [weak self] in self?.acceptAll() }
    }
    func start() {
        let config = configurationProvider?() ?? PolishConfiguration(base: settings.base, model: settings.model, key: settings.credentials.current.key, profile: settings.profile, serviceTier: settings.serviceTier, level: settings.level)
        warmup = Task { await PolishClient().warmConnection(config: config) }
        observer.start(); sample(force: true)
        subscription = settings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample(force: true) }
        }
    }
    func suspend(hideIndicator: Bool = true) {
        if hideIndicator { readGate.reset(); unreadableElement = nil; unreadablePID = nil }
        trace?("suspend")
        previewReady = false; previewDismissed = false
        generation = UUID(); request?.cancel(); request = nil; debounce.cancel(); overlay.hide(); if hideIndicator { indicator.hide() }
        capture = nil; session.replaceSuggestions(); observer.watch(nil)
    }
    func waitForConnectionWarmup() async { await warmup?.value }
    func stop() { warmup?.cancel(); warmup = nil; suspend(); observer.stop(); subscription = nil }
    func sample(force: Bool = false) {
        if activatedPID != NSWorkspace.shared.frontmostApplication?.processIdentifier { activatedPID = nil }
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { frontApp = app }
        guard enabled else { status = .disabled; return }
        guard !writing else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { suspend(); status = .idle; return }
        guard let frontApp, settings.apps.contains(frontApp.bundleIdentifier ?? "") else { suspend(); status = .disabled; return }
        guard AccessibilityAccess.trusted() else {
            suspend(); status = .failure("请授予辅助功能权限")
            indicator.hide()
            if lastProbe != "permission" { Diagnostics.shared.record(DiagnosticEvent(event: "capture", bundleID: frontApp.bundleIdentifier ?? "", error: "ax_permission_denied")); lastProbe = "permission" }
            return
        }
        if activatedPID != frontApp.processIdentifier {
            activatedPID = frontApp.processIdentifier
            access.activateAccessibility(for: frontApp)
        }
        let focus = access.focused()
        let role = focus.flatMap { access.attribute($0.1, kAXRoleAttribute) as? String }
        let allowed = focus.map { access.allowed($0.1) } ?? false
        let value = allowed ? focus.flatMap { access.attribute($0.1, kAXValueAttribute) as? String } : nil
        let rawBounds = focus.flatMap { access.bounds($0.1) }
        let probe = "\(frontApp.processIdentifier):\(role ?? "none"):\(allowed):\(value?.utf16.count ?? -1):\(rawBounds != nil)"
        if probe != lastProbe || force {
            Diagnostics.shared.record(DiagnosticEvent(event: "capture", bundleID: frontApp.bundleIdentifier ?? "", role: role, textLength: value?.utf16.count, readable: value != nil, hasPosition: rawBounds != nil, error: !allowed ? "no_ordinary_text_focus" : value == nil ? "ax_value_unavailable" : nil))
            lastProbe = probe
        }
        if allowed, value == nil, let bundleID = frontApp.bundleIdentifier {
            let wasFallback = access.fallbackApps.contains(bundleID)
            access.useClipboard(for: bundleID)
            if !wasFallback { shortcutChanged?() }
        }
        if let element = focus?.1, allowed, value == nil {
            if unreadablePID != frontApp.processIdentifier || unreadableElement.map({ !CFEqual($0, element) }) != false {
                readGate.reset()
            }
            unreadableElement = element; unreadablePID = frontApp.processIdentifier
        } else { readGate.reset(); unreadableElement = nil; unreadablePID = nil }
        let unreadable = readGate.warning(enabled: true, ordinary: allowed, readable: value != nil, now: Date())
        guard let fresh = access.automaticCapture(enabled: settings.apps) else {
            suspend(hideIndicator: false)
            if unreadable {
                status = .failure("读不到这个输入框")
                indicatorState = .warning("读不到这个输入框")
                indicator.show(indicatorState, rawField: rawBounds)
            } else { status = .idle; indicator.hide() }
            return
        }
        let configID = [fresh.bundleID, settings.base, settings.model, settings.profile, settings.serviceTier, settings.level.rawValue, PolishClient.lexiconRevision].joined(separator: "\u{0}")
        if configuration != configID { configuration = configID; hidden.removeAll(); session.replaceSuggestions() }
        observer.watch(fresh)
        let sameField = capture.map { $0.pid == fresh.pid && CFEqual($0.element, fresh.element) } ?? false
        let changed = !sameField || !session.text.utf16.elementsEqual(fresh.input.utf16) || force
        if !sameField { session.replaceSuggestions(); hidden.removeAll() }
        capture = fresh
        guard changed else { render(); return }
        previewReady = false; previewDismissed = false; overlay.hidePreview()
        changedAt = Date(); indicatorState = .watching
        trace?("sample changed force=\(force)")
        generation = UUID(); request?.cancel(); request = nil; debounce.cancel()
        session.reconcile(fresh.input)
        for expired in session.drainExpired() { record(expired, action: .expired) }
        filterHidden()
        render()
        guard fresh.input.count >= 4 else { session.replaceSuggestions(); overlay.hide(); status = .idle; render(); return }
        status = .checking
        let id = generation
        debounce.setDelay(seconds: settings.pauseSeconds)
        debounce.schedule { [weak self] in
            guard let self, self.generation == id else { return }
            self.request = Task { [weak self] in await self?.check(id: id) }
        }
    }
    private func check(id: UUID) async {
        guard let capture, generation == id else { trace?("check stale at start"); return }
        trace?("check started"); status = .checking
        indicatorState = .checking; render()
        let started = Date()
        let bundleID = capture.bundleID
        let debounceMS = Int(started.timeIntervalSince(changedAt) * 1000)
        Diagnostics.shared.record(DiagnosticEvent(event: "check_started", bundleID: bundleID, textLength: capture.input.utf16.count, traceID: id.uuidString, debounceMS: debounceMS))
        let text = capture.input
        let config = configurationProvider?() ?? PolishConfiguration(base: settings.base, model: settings.model, key: settings.credentials.current.key, profile: settings.profile, serviceTier: settings.serviceTier, credentialError: settings.credentials.current.warnings.first, level: settings.level)
        eventModel = config.model; eventLevel = settings.level
        do {
            let edits: [Suggestion]
            if let cached = cache.edits(for: text) { edits = cached; trace?("cache hit edits=\(edits.count)") }
            else {
                let result = try await PolishClient().wholeResult(text, config: config, metrics: { timing in
                    Diagnostics.shared.record(DiagnosticEvent(event: "request_metrics", bundleID: bundleID, textLength: text.utf16.count, traceID: id.uuidString, requestMS: timing.totalMS, firstTokenMS: timing.firstTokenMS, completionTokens: timing.completionTokens, reasoningTokens: timing.reasoningTokens))
                })
                guard generation == id, !Task.isCancelled else { return }
                edits = result.suggestions
                cache.store(edits, for: text)
            }
            guard generation == id, !Task.isCancelled, access.isCurrent(capture, text: text) else { return }
            publish(edits, text: text, capture: capture, id: id)
            Diagnostics.shared.record(DiagnosticEvent(event: "result", bundleID: bundleID, traceID: id.uuidString, debounceMS: debounceMS, requestMS: Int(Date().timeIntervalSince(started) * 1000), resultMS: Int(Date().timeIntervalSince(changedAt) * 1000)))
            filterHidden(); indicatorState = session.suggestions.isEmpty ? .clean : .suggestions(session.suggestions.count); trace?("published \(session.suggestions.count)"); failed?(false); status = session.suggestions.isEmpty ? .idle : .suggestions(session.suggestions.count); render()
        } catch {
            guard generation == id, !Task.isCancelled else { return }
            Diagnostics.shared.record(DiagnosticEvent(event: "check_failed", bundleID: bundleID, traceID: id.uuidString, requestMS: Int(Date().timeIntervalSince(started) * 1000), resultMS: Int(Date().timeIntervalSince(changedAt) * 1000), error: error.localizedDescription, httpStatus: (error as? PolishFailure)?.httpStatus, errorCode: (error as? PolishFailure)?.code, parameter: (error as? PolishFailure)?.parameter))
            indicatorState = .modelFailure(error.localizedDescription); indicator.show(indicatorState, rawField: access.bounds(capture.element))
            trace?("check error \(error.localizedDescription)"); session.replaceSuggestions(); overlay.hide(); status = .failure(error.localizedDescription); failed?(true)
        }
    }
    private func publish(_ edits: [Suggestion], text: String, capture: CapturedInput, id: UUID) {
        guard generation == id, !Task.isCancelled, access.isCurrent(capture, text: text) else { return }
        session.replaceSuggestions()
        session.set(edits, text: text, sentence: text, offset: 0)
        filterHidden()
        previewReady = true
        render()
    }
    private func isVisible(_ edit: Suggestion) -> Bool { settings.level.includes(edit.kind) && !settings.disabledKinds.contains(edit.kind.rawValue) }
    private func filterHidden() {
        for item in session.suggestions where !isVisible(item.edit) {
            let key = [item.sentence, String(item.edit.range.location), item.edit.original, item.edit.replacement, item.edit.kind.rawValue, settings.level.rawValue, PolishClient.lexiconRevision].joined(separator: "\u{0}")
            if hidden.insert(key).inserted { record(item, action: .hidden) }
            session.remove(item.id)
        }
    }
    private func render() {
        guard let capture, access.isCurrent(capture, text: session.text) else { overlay.hide(); indicator.hide(); return }
        let rawField = access.bounds(capture.element)
        indicator.show(indicatorState, rawField: rawField)
        let placement = OverlayPlacement.resolve(rawField: rawField, screens: NSScreen.screens.map(\.visibleFrame), preferredPoint: NSEvent.mouseLocation)
        guard let placement else { overlay.hide(); return }
        let field = placement.field
        overlay.showPreview(previewReady && !previewDismissed ? SuggestionPreview.wholeRewrite(source: session.text, edits: session.suggestions.map(\.edit)) : nil, field: field)
        let inlineItems = session.suggestions.filter { !([.fluency, .order].contains($0.edit.kind) && $0.edit.original == session.text) }
        var marks: [WaveMark] = [], valid = placement.canUnderline
        guard placement.canUnderline else {
            overlay.show(items: inlineItems, field: field, marks: nil); return
        }
        for item in inlineItems {
            guard item.edit.matches(session.text) else { valid = false; break }
            var offset = item.edit.range.location
            var rects: [CGRect] = []
            if item.edit.original.isEmpty {
                if let range = item.edit.underlineRange(in: session.text), let rect = access.rangeBounds(range, in: capture.element) { rects = [rect] }
            } else {
                // Query grapheme ranges so multiline edits receive one underline per visible line.
                for char in item.edit.original {
                    let length = String(char).utf16.count
                    guard let rect = access.rangeBounds(NSRange(location: offset, length: length), in: capture.element), (rawField ?? .zero).insetBy(dx: -1, dy: -1).contains(rect) else { valid = false; break }
                    if let last = rects.last, abs(last.minY - rect.minY) < 2, abs(last.maxX - rect.minX) < 4 { rects[rects.count - 1] = last.union(rect) }
                    else { rects.append(rect) }
                    offset += length
                }
            }
            if rects.isEmpty { valid = false }
            for rect in rects {
                guard (rawField ?? .zero).insetBy(dx: -1, dy: -1).contains(rect) else { valid = false; break }
                marks.append(WaveMark(id: item.id, rect: AccessibilityAccess.appKitRect(rect), kind: item.edit.kind))
            }
        }
        overlay.show(items: inlineItems, field: field, marks: valid ? marks : nil)
    }
    /// Invalidates the old preview before a key reaches the target editor. No typing
    /// event is consumed; subsequent AX changes schedule a fresh check.
    func key(_ code: CGKeyCode, _ flags: CGEventFlags) -> Bool {
        guard overlay.previewVisible else { return false }
        if code == 53 { dismissPreview(); return true }
        if [36, 76].contains(code), flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift]) == .maskAlternate {
            acceptAll(); return true
        }
        previewReady = false; overlay.hidePreview()
        return false
    }
    func dismissPreview() {
        previewDismissed = true; overlay.hidePreview()
    }
    func acceptAll() {
        guard enabled, !writing, let capture, let snapshot = SuggestionPreview(source: session.text, edits: session.suggestions.map(\.edit)),
              !previewDismissed, access.isCurrent(capture, text: snapshot.source) else { return }
        writing = true
        generation = UUID(); request?.cancel(); debounce.cancel()
        let edit = Suggestion(range: NSRange(location: 0, length: snapshot.source.utf16.count), original: snapshot.source, replacement: snapshot.output, kind: .fluency, why: "全部采纳")
        let accepted = session.suggestions
        previewReady = false; overlay.hide()
        if access.writeSuggestion(edit, source: snapshot.source, to: capture) {
            finishAcceptAll(snapshot, accepted: accepted, capture: capture, path: "ax")
            return
        }
        // Browser fields often reject AX selection writes or read back late; paste into the same field instead.
        Task { @MainActor [weak self] in
            guard let self else { return }
            var path = "clipboard"
            do {
                // Some editors apply the AX write but expose the new value a moment later.
                for _ in 0..<3 where !self.access.isCurrent(capture, text: snapshot.output) { try await Task.sleep(nanoseconds: 50_000_000) }
                if self.access.isCurrent(capture, text: snapshot.output) { self.finishAcceptAll(snapshot, accepted: accepted, capture: capture, path: "ax_late"); return }
                try await ClipboardTransaction.paste(snapshot.output, selectAll: true, validate: { [access] in access.isCurrent(capture, text: snapshot.source) })
                for _ in 0..<10 where !self.access.isCurrent(capture, text: snapshot.output) { try await Task.sleep(nanoseconds: 50_000_000) }
                if !self.access.isCurrent(capture, text: snapshot.output) { path = "clipboard_unverified" }
            } catch { path = self.access.isCurrent(capture, text: snapshot.output) ? "clipboard" : "failed" }
            self.finishAcceptAll(snapshot, accepted: path == "failed" ? [] : accepted, capture: capture, path: path)
        }
    }
    private func finishAcceptAll(_ snapshot: SuggestionPreview, accepted: [LocatedSuggestion], capture: CapturedInput, path: String) {
        Diagnostics.shared.record(DiagnosticEvent(event: "accept_all", bundleID: capture.bundleID, textLength: snapshot.output.utf16.count, axAttribute: path, error: ["ax", "ax_late", "clipboard"].contains(path) ? nil : path))
        if !accepted.isEmpty {
            for item in accepted { record(item, action: .accept) }
            // Accepted text is final: never send it back to the model.
            cache.settle(snapshot.output)
            session.replaceSuggestions(); session.reconcile(snapshot.output)
        }
        previewReady = false; overlay.hide(); writing = false
        sample(force: true)
    }
    @discardableResult func accept(_ id: UUID, reschedule: Bool = true) -> Bool {
        guard enabled, let capture, let item = session.suggestions.first(where: { $0.id == id }), isVisible(item.edit) else { return false }
        writing = true; defer { writing = false }
        generation = UUID(); request?.cancel(); debounce.cancel()
        guard access.writeSuggestion(item.edit, source: session.text, to: capture) else {
            overlay.hide(); indicator.hide()
            Task { @MainActor [weak self] in self?.sample(force: true) }; return false
        }
        record(item, action: .accept); session.remove(id)
        let updated = (session.text as NSString).replacingCharacters(in: item.edit.range, with: item.edit.replacement)
        // Known programmatic edits shift later ranges without expiring independent suggestions.
        session.didAccept(item.edit, updated: updated)
        if session.suggestions.isEmpty { cache.store([], for: updated) }
        status = session.suggestions.isEmpty ? .idle : .suggestions(session.suggestions.count)
        indicatorState = session.suggestions.isEmpty ? .clean : .suggestions(session.suggestions.count)
        render()
        if reschedule { Task { @MainActor [weak self] in self?.sample(force: true) } }
        return true
    }
    private func ignore(_ id: UUID) {
        guard let item = session.suggestions.first(where: { $0.id == id }) else { return }
        session.ignore(item.edit, sentence: item.sentence); record(item, action: .ignore); session.remove(id); status = session.suggestions.isEmpty ? .idle : .suggestions(session.suggestions.count); indicatorState = session.suggestions.isEmpty ? .clean : .suggestions(session.suggestions.count); render()
    }
    private func disable(_ kind: SuggestionKind) {
        if !settings.disabledKinds.contains(kind.rawValue) { settings.disabledKinds.append(kind.rawValue) }
        filterHidden(); render()
    }
    private func record(_ item: LocatedSuggestion, action: SuggestionEvent.Action) {
        guard let capture else { return }
        do { try history.append(SuggestionEvent(appBundleID: capture.bundleID, sentence: item.sentence, suggestion: item.edit, action: action, level: action == .hidden ? settings.level : eventLevel, model: eventModel)) }
        catch { status = .failure("本地记录写入失败"); failed?(true) }
    }
}
