import AppKit

enum AppIdentity {
    static func url(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }
    static func name(_ id: String) -> String {
        guard let url = url(id), let bundle = Bundle(url: url) else { return id }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }
    static func icon(_ id: String) -> NSImage {
        guard let url = url(id) else { return NSImage(systemSymbolName: "app", accessibilityDescription: id)! }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
