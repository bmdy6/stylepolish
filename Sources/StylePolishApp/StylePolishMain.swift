import AppKit
@main struct StylePolishMain {
    @MainActor static func main() {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--habits-harness"), CommandLine.arguments.count > i + 2 {
            do { try HabitsHarness.run(copy: CommandLine.arguments[i + 1], output: CommandLine.arguments[i + 2]) }
            catch { fputs("Offline habits harness failed\n", stderr); exit(1) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--capture-fixtures"), CommandLine.arguments.count > i + 1 {
            NSApplication.shared.setActivationPolicy(.prohibited)
            do { try FixtureCapture.run(directory: CommandLine.arguments[i + 1]) }
            catch { fputs("Offscreen fixtures failed\n", stderr); exit(1) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--diagnostics-harness"), CommandLine.arguments.count > i + 1 {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let log = Diagnostics(directory: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            Task { @MainActor in
                do { _ = try await DiagnosticsHarness.run(log: log); print("Headless diagnostics harness passed"); exit(0) }
                catch { fputs("Headless diagnostics harness failed\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        #endif
        let app = NSApplication.shared
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--render-invite"), CommandLine.arguments.count > i + 2 {
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                do { try await InviteCapture.run(directory: CommandLine.arguments[i + 1], base: CommandLine.arguments[i + 2]); exit(0) }
                catch { fputs("Offscreen invite rendering failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            // Keep AppKit on the OS main thread after async verification resumes.
            RunLoop.main.run()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-v4"), CommandLine.arguments.count > i + 1 {
            app.setActivationPolicy(.prohibited)
            do { try V4Capture.run(directory: CommandLine.arguments[i + 1]) }
            catch { fputs("Offscreen rendering failed: \(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        #endif
        app.setActivationPolicy(.accessory)
        let delegate = AppController()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
