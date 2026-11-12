import AppKit
import Sparkle

enum UpdateAvailability: Equatable {
    case unconfigured
    case moveToApplications
    case available

    static func forBundle(at url: URL, configured: Bool) -> Self {
        guard configured else { return .unconfigured }
        let installedPath = URL(fileURLWithPath: "/Applications/StylePolish.app")
            .resolvingSymlinksInPath().path
        return url.resolvingSymlinksInPath().path == installedPath ? .available : .moveToApplications
    }
}

@MainActor
final class AppUpdates: NSObject {
    private let availability: UpdateAvailability
    private let updater: SPUStandardUpdaterController?

    init(bundle: Bundle) {
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let configured = feed.flatMap { URL(string: $0) }?.scheme == "https"
            && publicKey.flatMap { Data(base64Encoded: $0) }?.count == 32
        availability = .forBundle(at: bundle.bundleURL, configured: configured)
        updater = availability == .available
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
        super.init()
    }

    func menuItem() -> NSMenuItem? {
        if let updater {
            let item = NSMenuItem(title: "检查更新…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
            item.target = updater
            return item
        }
        guard availability == .moveToApplications else { return nil }
        let item = NSMenuItem(title: "检查更新…", action: #selector(showInstallLocation), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showInstallLocation() {
        let alert = NSAlert()
        alert.messageText = "请从「应用程序」打开 StylePolish"
        alert.informativeText = "将 StylePolish.app 移到「应用程序」，再从那里打开并检查更新。"
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
