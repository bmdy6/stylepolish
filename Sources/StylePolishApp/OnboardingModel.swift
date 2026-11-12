import SwiftUI
import Combine
import StylePolishCore

@MainActor final class OnboardingModel: ObservableObject {
    @Published var state: OnboardingState { didSet {
        if state.step != oldValue.step { logStep() }
    } }
    private var diagnostics: DiagnosticTrace?
    @Published var selected: UUID?
    @Published var message = ""
    let settings: SettingsStore
    private var timer: Timer?
    private var inviteSubscription: AnyCancellable?
    private var request: Task<Void, Never>?
    private var generation = UUID()
    private var session = SuggestionSession()
    var checkEngine = CheckEngine()
    private var showingLocal = false
    init(settings: SettingsStore, trusted: Bool) {
        self.settings = settings
        state = OnboardingState(trusted: trusted, hasKey: !settings.credentials.current.key.isEmpty)
        if settings.engine == .invite { state.engine = .invite }
        inviteSubscription = settings.invite.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    private func logStep() {
        var event = DiagnosticEvent(event: "onboarding_step", bundleID: "org.bmdy6.StylePolish")
        event.step = state.step.rawValue; settings.diagnostics.record(event)
    }
    func opened() { logStep() }
    func closed(completed: Bool) {
        var event = DiagnosticEvent(event: "onboarding_closed", bundleID: "org.bmdy6.StylePolish")
        event.step = state.step.rawValue; event.action = completed ? "completed" : "closed"; settings.diagnostics.record(event)
    }
    func startPolling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state.permissionChanged(AccessibilityAccess.trusted(), now: Date().timeIntervalSinceReferenceDate)
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func stop() {
        timer?.invalidate(); timer = nil; request?.cancel(); generation = UUID()
        session.replaceSuggestions(); state.pending = []; state.checking = false; selected = nil; showingLocal = false
    }
    var canContinue: Bool { state.engine == .local || (state.engine == .ai ? !settings.credentials.current.key.isEmpty : settings.invite.canUse(base: settings.relayBase)) }
    func next() {
        guard state.trusted else { return }
        guard canContinue else { return }
        settings.engine = state.engine; state.step = .trial
        request?.cancel(); request = Task { await checkTrial() }
    }
    func edited(_ text: String) {
        diagnostics?.action("typing_invalidated", count: state.pending.count)
        request?.cancel(); generation = UUID(); state.text = text; state.didCheck = false
        if showingLocal { session.replaceSuggestions(); showingLocal = false }
        session.reconcile(text); state.pending = session.suggestions.map(\.edit); selected = nil
        request = Task {
            do { try await Task.sleep(nanoseconds: 300_000_000); try Task.checkCancellation(); await checkTrial() } catch {}
        }
    }
    func checkTrial() async {
        let id = UUID(); generation = id
        let trace = DiagnosticTrace(bundleID: "org.bmdy6.StylePolish.trial", log: settings.diagnostics)
        diagnostics = trace
        let started = Date()
        trace.capture(text: state.text, role: "trial_editor", writable: true, selection: nil, attachment: .plain, hasPosition: true)
        trace.started(engine: state.engine, level: settings.level, cacheHit: false)
        let text = state.text; state.checking = true; message = ""
        let config = settings.configuration(engine: state.engine)
        do {
            let result = try await checkEngine.check(text, engine: state.engine, config: config, disabledKinds: settings.disabledKinds, progress: { [weak self] edits in
                guard let self, self.generation == id, self.state.text.utf16.elementsEqual(text.utf16) else { return }
                self.session.replaceSuggestions()
                self.session.set(edits.filter { self.settings.level.includes($0.kind) }, text: text, sentence: text, offset: 0)
                self.state.pending = self.session.suggestions.map(\.edit)
                self.selected = self.state.pending.first?.id
                self.showingLocal = !edits.isEmpty
            }, metrics: { trace.metrics($0, model: config.model) })
            guard generation == id, !Task.isCancelled else { return }
            showingLocal = false
            settings.checked(result, config: config)
            session.replaceSuggestions()
            session.set(result.suggestions.filter { settings.level.includes($0.kind) && !settings.disabledKinds.contains($0.kind.rawValue) }, text: text, sentence: text, offset: 0)
            state.pending = session.suggestions.map(\.edit); state.didCheck = true; state.checking = false
            trace.result(source: text, suggestions: state.pending, engine: state.engine, fallback: result.fallback, unclear: result.unclear, requestMS: Int(Date().timeIntervalSince(started) * 1000), resultMS: Int(Date().timeIntervalSince(started) * 1000))
            if !state.pending.isEmpty { trace.presented("underline", hasPosition: true, count: state.pending.count) }
            selected = state.pending.first?.id
            if result.fallback != .none { message = result.fallback.menuTitle }
        } catch {
            guard generation == id else { return }
            session.replaceSuggestions(); state.pending = []; selected = nil; showingLocal = false
            state.checking = false
        }
    }
    func accept(_ id: UUID) {
        guard let edit = state.pending.first(where: { $0.id == id }), let preview = SuggestionPreview(source: state.text, edits: [edit]) else { return }
        diagnostics?.action("accept_one", count: 1)
        let source = state.text
        request?.cancel(); generation = UUID()
        session.remove(id); session.didAccept(edit, updated: preview.output)
        state.text = preview.output; state.pending = session.suggestions.map(\.edit)
        diagnostics?.write(source: source, expected: preview.output, readback: state.text, method: "trial_editor", attachment: .plain)
        state.checking = false; selected = state.pending.first?.id
    }
    func acceptAll() {
        let applicable = state.pending.filter(\.canApply)
        guard let preview = SuggestionPreview(source: state.text, edits: applicable) else { return }
        diagnostics?.action("accept_all", count: state.pending.count)
        let source = state.text
        request?.cancel(); generation = UUID()
        for edit in applicable { session.remove(edit.id) }
        session.reconcile(preview.output)
        state.text = preview.output; state.pending = session.suggestions.map(\.edit); state.checking = false; selected = nil
        diagnostics?.write(source: source, expected: preview.output, readback: state.text, method: "trial_editor", attachment: .plain)
    }
    func ignore(_ id: UUID) {
        guard let edit = state.pending.first(where: { $0.id == id }) else { return }
        diagnostics?.action("ignore", count: 1)
        session.ignore(edit, sentence: state.text); session.remove(id)
        state.pending = session.suggestions.map(\.edit); selected = state.pending.first?.id
    }
}
