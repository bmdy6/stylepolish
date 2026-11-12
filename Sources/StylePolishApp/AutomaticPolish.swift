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
    private var diagnosticTrace: DiagnosticTrace?
    private(set) var fallbackSummary: String?
    private(set) var fallbackReason = FallbackReason.none
    private var unclear = false
    private var showingLocal = false
    private var previewReady = false
    private(set) var previewDismissed = false
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
        indicator.didShow = { [weak self] state, positioned in
            guard let self else { return }
            self.diagnosticTrace?.presented("indicator", hasPosition: positioned, count: self.session.suggestions.count, state: state.diagnosticName)
        }
        indicator.click = { [weak self] in
            guard let self, self.access.targetSupported else { return }
            if case .modelFailure = self.indicator.state { self.openSettings?() }
            else { self.overlay.showList(from: self.indicator.frame) }
        }
        observer.changed = { [weak self] in self?.sample() }
        overlay.accept = { [weak self] id in Task { await self?.accept(id) } }
        overlay.ignore = { [weak self] in self?.ignore($0) }
        overlay.disable = { [weak self] in self?.disable($0) }
        overlay.listOpened = { [weak self] in
            guard let self, self.previewDismissed else { return }
            self.previewDismissed = false
            self.previewReady = false
        }
        overlay.acceptAll = { [weak self] in Task { await self?.acceptAll() } }
    }
    func start() {
        let config = configurationProvider?() ?? settings.configuration()
        if settings.engine == .ai { warmup = Task { await PolishClient().warmConnection(config: config) } }
        observer.start(); sample(force: true)
        subscription = settings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.settings.engine == .local { self.warmup?.cancel(); self.warmup = nil }
                self.sample(force: true)
            }
        }
    }
    func suspend(hideIndicator: Bool = true) {
        if hideIndicator { readGate.reset(); unreadableElement = nil; unreadablePID = nil }
        trace?("suspend")
        diagnosticTrace = nil
        unclear = false; previewReady = false; previewDismissed = false
        generation = UUID(); writing = false; request?.cancel(); request = nil; debounce.cancel(); overlay.hide(); if hideIndicator { indicator.hide() }
        capture = nil; showingLocal = false; session.replaceSuggestions(); observer.watch(nil)
    }
    func updateFallback(_ reason: FallbackReason, summary: String? = nil) {
        fallbackReason = reason; fallbackSummary = summary
        status = reason == .none ? .idle : .fallback(reason)
    }
    func waitForConnectionWarmup() async { await warmup?.value }
    func stop() { warmup?.cancel(); warmup = nil; suspend(); observer.stop(); subscription = nil }
    func sample(force: Bool = false) {
        Diagnostics.shared.permissionChanged(AccessibilityAccess.trusted())
        frontApp = NSWorkspace.shared.frontmostApplication
        guard enabled else { status = .disabled; return }
        guard let frontApp, access.supports(frontApp.bundleIdentifier) else { suspend(); status = .disabled; return }
        guard !writing else { return }
        guard AccessibilityAccess.trusted() else {
            suspend(); status = .fallback(.permission)
            indicator.hide()
            if lastProbe != "permission" { Diagnostics.shared.record(DiagnosticEvent(event: "capture", bundleID: frontApp.bundleIdentifier ?? "", traceID: UUID().uuidString, error: "ax_permission_denied")); lastProbe = "permission" }
            return
        }
        let focus = access.focused()
        let role = focus.flatMap { access.attribute($0.1, kAXRoleAttribute) as? String }
        let allowed = focus.map { access.allowed($0.1) } ?? false
        let writable = allowed && (focus.map { access.settable($0.1, kAXValueAttribute) || (access.settable($0.1, kAXSelectedTextAttribute) && access.settable($0.1, kAXSelectedTextRangeAttribute)) } ?? false)
        let value = allowed ? focus.flatMap { access.attribute($0.1, kAXValueAttribute) as? String } : nil
        let rawBounds = focus.flatMap { access.bounds($0.1) }
        let attachmentProbe = value.flatMap { text in focus.map { access.attachmentEvidence($0.1, text: text) } }
        let focusID = focus.map { CFHash($0.1) } ?? 0
        let probe = "\(focusID):\(frontApp.processIdentifier):\(role ?? "none"):\(allowed):\(value?.utf16.count ?? -1):\(rawBounds != nil):\(attachmentProbe?.hasAttachment ?? false):\(attachmentProbe?.complete ?? false)"
        var captureFailure: DiagnosticTrace?
        // A secure field is excluded even in debug mode. Non-enabled apps returned above.
        if DiagnosticTrace.permitsCapture(enabled: true, ordinary: allowed), value == nil || !writable, probe != lastProbe || force {
            let trace = DiagnosticTrace(bundleID: frontApp.bundleIdentifier ?? "")
            trace.capture(text: value, role: role, writable: writable, selection: focus.flatMap { access.selection($0.1) }, attachment: attachmentProbe ?? .unknown, hasPosition: rawBounds != nil)
            captureFailure = trace
        }
        lastProbe = probe
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
        guard let fresh = access.automaticCapture() else {
            let failureTrace = captureFailure ?? (allowed ? diagnosticTrace : nil)
            suspend(hideIndicator: false)
            diagnosticTrace = failureTrace
            if unreadable {
                status = .failure("读不到这个输入框")
                indicatorState = .warning("读不到这个输入框")
                indicator.show(indicatorState, rawField: rawBounds)
            } else { status = .idle; indicator.hide() }
            return
        }
        let configID = [settings.engine.rawValue, settings.disabledKinds.sorted().joined(separator: ","), fresh.bundleID, settings.base, settings.relayBase, settings.invite.code, settings.invite.block(for: settings.relayBase)?.rawValue ?? "active", settings.model, settings.profile, settings.serviceTier, settings.level.rawValue, PolishClient.lexiconRevision, String(settings.habitsEnabled), settings.effectiveHabits.configurationID].joined(separator: "\u{0}")
        let configurationChanged = configuration != configID
        if configurationChanged { configuration = configID; hidden.removeAll(); session.replaceSuggestions() }
        observer.watch(fresh)
        let sameField = capture.map { $0.pid == fresh.pid && CFEqual($0.element, fresh.element) } ?? false
        let changed = !sameField || !session.text.utf16.elementsEqual(fresh.input.utf16) || force || configurationChanged
        if !sameField { session.replaceSuggestions(); hidden.removeAll() }
        if changed {
            if sameField, capture != nil, !session.text.utf16.elementsEqual(fresh.input.utf16) { diagnosticTrace?.action("typing_invalidated", count: session.suggestions.count) }
            diagnosticTrace = DiagnosticTrace(bundleID: fresh.bundleID)
            diagnosticTrace?.capture(text: fresh.input, role: role, writable: true, selection: fresh.range, attachment: fresh.attachments, hasPosition: fresh.bounds != nil)
        }
        capture = fresh
        guard changed else { render(); return }
        unclear = false; previewReady = false; previewDismissed = false; overlay.hidePreview()
        changedAt = Date(); indicatorState = .watching
        trace?("sample changed force=\(force)")
        generation = UUID(); request?.cancel(); request = nil; debounce.cancel()
        if showingLocal { session.replaceSuggestions(); showingLocal = false }
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
        guard let capture, generation == id, access.isCurrent(capture, text: session.text) else { trace?("check stale at start"); return }
        trace?("check started"); status = .checking
        indicatorState = .checking; render()
        guard let diagnostics = diagnosticTrace else { return }
        let started = Date()
        let engine = settings.engine
        let bundleID = capture.bundleID
        let debounceMS = Int(started.timeIntervalSince(changedAt) * 1000)
        diagnostics.started(engine: engine, level: settings.level, cacheHit: cache.result(for: capture.input) != nil, debounceMS: debounceMS)
        let text = capture.input
        let config = configurationProvider?() ?? settings.configuration()
        eventModel = engine == .local ? "local-rules" : config.model; eventLevel = settings.level
        do {
            let edits: [Suggestion]
            var fallback = FallbackReason.none
            var summary: String?
            if let cached = cache.result(for: text) { edits = cached.edits; unclear = cached.unclear; trace?("cache hit edits=\(edits.count)") }
            else {
                let result = try await CheckEngine().check(text, engine: engine, config: config, disabledKinds: settings.disabledKinds, hidden: { [weak self] edits in
                    guard let self, self.generation == id else { return }
                    for edit in edits { self.recordHidden(LocatedSuggestion(edit: edit, sentence: text)) }
                }, progress: { [weak self] edits in
                    guard let self, self.generation == id, self.access.isCurrent(capture, text: text) else { return }
                    self.session.replaceSuggestions()
                    self.session.set(edits, text: text, sentence: text, offset: 0)
                    self.showingLocal = !edits.isEmpty
                    self.eventModel = "local-rules"
                    self.filterHidden(); self.previewReady = false
                    self.render()
                }, metrics: { timing in
                    diagnostics.metrics(timing, model: config.model, engine: engine)
                })
                guard generation == id, !Task.isCancelled else { return }
                edits = result.suggestions
                settings.checked(result, config: config)
                unclear = result.unclear; fallback = result.fallback; summary = result.failureSummary
                if fallback != .none { eventModel = "local-rules" }
                // Never cache a fallback as an AI success: the next pause retries AI.
                if fallback == .none { cache.store(edits, for: text, unclear: unclear) }
            }
            guard generation == id, !Task.isCancelled, access.isCurrent(capture, text: text) else { return }
            showingLocal = false
            eventModel = engine == .local || fallback != .none ? "local-rules" : config.model
            publish(edits, text: text, capture: capture, id: id)
            diagnostics.result(source: session.text, suggestions: session.suggestions.map(\.edit), engine: engine, fallback: fallback, unclear: unclear, requestMS: Int(Date().timeIntervalSince(started) * 1000), resultMS: Int(Date().timeIntervalSince(changedAt) * 1000), debounceMS: debounceMS)
            fallbackReason = fallback; fallbackSummary = summary
            filterHidden(); indicatorState = .completed(count: session.suggestions.count, unclear: unclear); trace?("published \(session.suggestions.count)"); failed?(false); status = fallback == .none ? .completed(count: session.suggestions.count, unclear: unclear) : .fallback(fallback); render()
        } catch {
            guard generation == id, access.isCurrent(capture, text: text) else { return }
            if Task.isCancelled || error is CancellationError {
                showingLocal = false; session.replaceSuggestions(); previewReady = false
                status = .idle; indicatorState = .watching; render()
                return
            }
            Diagnostics.shared.record(DiagnosticEvent(event: "check_failed", bundleID: bundleID, traceID: diagnostics.id, requestMS: Int(Date().timeIntervalSince(started) * 1000), resultMS: Int(Date().timeIntervalSince(changedAt) * 1000), error: "check_failed", httpStatus: (error as? PolishFailure)?.httpStatus, errorCode: "check_failed"))
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
    }
    private func isVisible(_ edit: Suggestion) -> Bool {
        settings.level.includes(edit.kind) && !settings.disabledKinds.contains(edit.kind.rawValue)
            && !settings.effectiveHabits.suppresses(original: edit.original, replacement: edit.replacement)
    }
    private func recordHidden(_ item: LocatedSuggestion) {
        let key = [item.sentence, String(item.edit.range.location), item.edit.original, item.edit.replacement, item.edit.kind.rawValue, settings.level.rawValue, PolishClient.lexiconRevision].joined(separator: "\u{0}")
        if hidden.insert(key).inserted { record(item, action: .hidden) }
    }
    private func filterHidden() {
        for item in session.suggestions where !isVisible(item.edit) {
            recordHidden(item)
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
        let preview = previewReady && !previewDismissed ? SuggestionPreview.wholeRewrite(source: session.text, edits: session.suggestions.map(\.edit)) : nil
        overlay.showPreview(preview, field: field)
        if let preview { diagnosticTrace?.presented("preview_bar", mode: preview.mode.rawValue, hasPosition: rawField != nil, count: session.suggestions.count) }
        let inlineItems = session.suggestions.filter { !($0.edit.canApply && [.fluency, .order].contains($0.edit.kind) && $0.edit.original == session.text) }
        var marks: [WaveMark] = [], valid = placement.canUnderline
        guard placement.canUnderline else {
            overlay.show(items: inlineItems, field: field, marks: nil, listItems: session.suggestions)
            if !inlineItems.isEmpty { diagnosticTrace?.presented("badge", hasPosition: rawField != nil, count: inlineItems.count) }
            return
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
        overlay.show(items: inlineItems, field: field, marks: valid ? marks : nil, listItems: session.suggestions)
        if !inlineItems.isEmpty { diagnosticTrace?.presented(valid && !marks.isEmpty ? "underline" : "badge", hasPosition: rawField != nil, count: inlineItems.count) }
    }
    /// Invalidates the old preview before a key reaches the target editor. No typing
    /// event is consumed; subsequent AX changes schedule a fresh check.
    func key(_ code: CGKeyCode, _ flags: CGEventFlags) -> Bool {
        guard access.targetSupported else { suspend(); return false }
        // The event tap passes the shortcut through unless it can act on this exact field.
        if [36, 76].contains(code), flags.intersection([.maskAlternate, .maskCommand, .maskControl, .maskShift]) == .maskAlternate {
            guard canAcceptAll else { return false }
            Task { await self.acceptAll() }; return true
        }
        guard overlay.previewVisible else { return false }
        if code == 53 { dismissPreview(); return true }
        diagnosticTrace?.action("typing_invalidated", count: session.suggestions.count)
        previewReady = false; overlay.hidePreview()
        return false
    }
    func dismissPreview() {
        diagnosticTrace?.action("escape", count: session.suggestions.count)
        previewDismissed = true; overlay.hidePreview()
    }
    var canAcceptAll: Bool {
        guard enabled, !writing, !previewDismissed, let capture,
              access.supports(capture.bundleID),
              SuggestionPreview(source: session.text, edits: session.suggestions.map(\.edit)) != nil else { return false }
        return access.isCurrent(capture, text: session.text)
    }
    @discardableResult func acceptAll() async -> Bool {
        guard canAcceptAll else { return false }
        return await apply(session.suggestions.filter { $0.edit.canApply }, all: true)
    }
    @discardableResult func accept(_ id: UUID, reschedule: Bool = true) async -> Bool {
        guard let item = session.suggestions.first(where: { $0.id == id }), item.edit.canApply, isVisible(item.edit) else { return false }
        return await apply([item], all: false, reschedule: reschedule)
    }
    private func apply(_ accepted: [LocatedSuggestion], all: Bool, reschedule: Bool = true) async -> Bool {
        guard enabled, !writing, let capture, access.supports(capture.bundleID),
              let snapshot = SuggestionPreview(source: session.text, edits: accepted.map(\.edit)),
              access.isCurrent(capture, text: snapshot.source) else { return false }
        let wasProvisional = showingLocal
        let diagnostics = diagnosticTrace
        diagnostics?.action(all ? "accept_all" : "accept_one", count: accepted.count)
        writing = true
        generation = UUID(); let operation = generation
        request?.cancel(); debounce.cancel()
        previewReady = false; overlay.hide()
        let edit = all ? Suggestion(range: NSRange(location: 0, length: snapshot.source.utf16.count), original: snapshot.source, replacement: snapshot.output, kind: .fluency, why: "全部采纳") : accepted[0].edit
        let evidence = access.attachmentEvidence(capture.element, text: snapshot.source)
        var axMethod = "none"
        let writer = SuggestionWriter(
            isCurrent: { [access] in access.isCurrent(capture, text: $0) },
            writeAX: { [access] in access.writeSuggestion(edit, source: snapshot.source, to: capture, traceID: diagnostics?.id, methodReported: { axMethod = $0 }) },
            paste: { output, valid in try await ClipboardTransaction.paste(output, selectAll: true, validate: valid) },
            attachmentEvidence: { [access] in
                let fresh = access.attachmentEvidence(capture.element, text: access.attribute(capture.element, kAXValueAttribute) as? String ?? snapshot.source)
                return capture.attachments.requiresProtection ? capture.attachments : fresh
            },
            writeProtected: { [access] source, output in access.writeAttachmentText(source: source, output: output, to: capture, traceID: diagnostics?.id) }
        )
        let result = await writer.write(source: snapshot.source, output: snapshot.output, valid: { [self] in
            enabled && generation == operation && access.targetSupported && access.supports(capture.bundleID) && accepted.allSatisfy { isVisible($0.edit) }
        })
        let readback = access.allowed(capture.element) ? access.attribute(capture.element, kAXValueAttribute) as? String : nil
        let method: String
        switch result {
        case .ax, .axLate: method = axMethod
        case .clipboard, .unverified: method = "clipboard"
        case .attachmentAX: method = "attachment_ranges"
        case .attachmentCopy: method = "copy_only"
        case .failed: method = "none"
        }
        let writeError = result.confirmed ? nil : generation != operation || !enabled ? "cancelled_or_superseded" : result == .failed && !access.isCurrent(capture, text: snapshot.source) ? "stale_input" : result.rawValue
        diagnostics?.write(source: snapshot.source, expected: snapshot.output, readback: readback, method: method, attachment: evidence, error: writeError)
        // A pause or newer session owns the state now; never commit the old operation into it.
        guard generation == operation else { return false }
        writing = false
        let finalEvidence = access.attachmentEvidence(capture.element, text: access.attribute(capture.element, kAXValueAttribute) as? String ?? snapshot.source)
        Diagnostics.shared.record(DiagnosticEvent(event: all ? "accept_all" : "accept_one", bundleID: capture.bundleID, textLength: snapshot.output.utf16.count, hasAttachment: finalEvidence.hasAttachment || evidence.hasAttachment || capture.attachments.hasAttachment, attachmentEvidenceComplete: evidence.complete, writeMethod: result == .attachmentCopy ? "copy_only" : result.rawValue, axAttribute: result.rawValue, traceID: diagnostics?.id, error: result.confirmed ? nil : result.rawValue))
        guard result.confirmed else {
            if result == .attachmentCopy {
                let message = finalEvidence.hasAttachment || evidence.hasAttachment || capture.attachments.hasAttachment ? AttachmentSafety.copyMessage : AttachmentSafety.unknownMessage
                status = .failure(message); indicatorState = .warning(message); failed?(true); render()
            } else if access.isCurrent(capture, text: snapshot.source) {
                let message = result == .unverified ? "未确认写回，请检查输入框后重试" : "未能写回，请检查输入框后重试"
                status = .failure(message); indicatorState = .warning(message); failed?(true)
                render()
            } else { sample(force: true) }
            return false
        }
        // Use local values to avoid overlapping inout access through the cache property.
        var committedSession = session, committedCache = cache
        SuggestionAcceptance.commit(outcome: result, accepted: accepted, snapshot: snapshot, all: all,
                                    settle: fallbackReason == .none && !wasProvisional, unclear: unclear,
                                    session: &committedSession, cache: &committedCache) { record($0, action: .accept) }
        session = committedSession; cache = committedCache
        status = .completed(count: session.suggestions.count, unclear: unclear)
        indicatorState = .completed(count: session.suggestions.count, unclear: unclear)
        failed?(false); render()
        if reschedule { sample(force: true) }
        return true
    }
    private func ignore(_ id: UUID) {
        guard let item = session.suggestions.first(where: { $0.id == id }) else { return }
        diagnosticTrace?.action("ignore", count: 1)
        session.ignore(item.edit, sentence: item.sentence); record(item, action: .ignore); session.remove(id); status = .completed(count: session.suggestions.count, unclear: unclear); indicatorState = .completed(count: session.suggestions.count, unclear: unclear); render()
    }
    private func disable(_ kind: SuggestionKind) {
        if !settings.disabledKinds.contains(kind.rawValue) { settings.disabledKinds.append(kind.rawValue) }
        filterHidden()
        switch indicatorState {
        case .suggestions, .clean, .unclear:
            status = .completed(count: session.suggestions.count, unclear: unclear)
            indicatorState = .completed(count: session.suggestions.count, unclear: unclear)
        default: break
        }
        render()
    }
    private func record(_ item: LocatedSuggestion, action: SuggestionEvent.Action) {
        guard let capture else { return }
        do { try history.append(SuggestionEvent(appBundleID: capture.bundleID, sentence: item.sentence, suggestion: item.edit, action: action, level: action == .hidden ? settings.level : eventLevel, model: eventModel)) }
        catch { status = .failure("本地记录写入失败"); failed?(true) }
    }
}
