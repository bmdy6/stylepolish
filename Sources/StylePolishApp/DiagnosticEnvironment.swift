import Foundation

struct DiagnosticEnvironment {
    static func launch(bundle: Bundle = .main) -> DiagnosticEvent {
        var event = DiagnosticEvent(event: "app_launch", bundleID: bundle.bundleIdentifier ?? "org.bmdy6.StylePolish")
        event.version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        event.commit = bundle.object(forInfoDictionaryKey: "StylePolishCommit") as? String ?? "dev"
        event.installationPath = bundle.bundleURL.path
        event.translocated = bundle.bundleURL.path.contains("/AppTranslocation/")
        event.macOS = ProcessInfo.processInfo.operatingSystemVersionString
        // Read-only signature inspection; no signing, Keychain or password access.
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--verbose=2", bundle.bundleURL.path]
        let pipe = Pipe(); process.standardError = pipe; process.standardOutput = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            event.signing = process.terminationStatus != 0 ? "unsigned" : output.contains("Signature=adhoc") ? "ad-hoc" : output.contains("Authority=") ? "fixed" : "unknown"
        } else { event.signing = "unknown" }
        return event
    }
    static func summary(_ launch: DiagnosticEvent) -> [String: String] {
        ["version": launch.version ?? "unknown", "commit": launch.commit ?? "unknown", "signing": launch.signing ?? "unknown", "macOS": launch.macOS ?? "unknown", "translocated": String(launch.translocated ?? false)]
    }
}
