import Foundation
import Darwin

struct LoadedCredential {
    var key = ""
    var source = "未配置"
    var warnings: [String] = []
    var status: String { key.isEmpty ? "填一次 Key 即可" : "Key 来源：\(source) ✓ · …\(key.suffix(4))" }
}

/// Reads local files only at construction or explicit reload; requests use the snapshot.
final class CredentialStore {
    let vaultURL: URL
    let localURL: URL
    private(set) var current = LoadedCredential()
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, keyName: String = "OPENAI_PLATFORM_API_KEY") {
        vaultURL = home.appendingPathComponent(".config/ai-vault/vault.json")
        localURL = home.appendingPathComponent(".config/stylepolish/openai-key")
        reload(keyName: keyName)
    }
    func reload(keyName: String) {
        var result = LoadedCredential()
        if FileManager.default.fileExists(atPath: vaultURL.path) {
            checkPermissions(vaultURL, into: &result)
            do {
                let json = try JSONSerialization.jsonObject(with: Data(contentsOf: vaultURL))
                guard let tree = json as? [String: Any] else { throw CocoaError(.propertyListReadCorrupt) }
                if let key = Self.find(keyName, in: tree) {
                    result.key = key; result.source = "ai-vault · \(keyName)"
                    current = result; return
                }
                result.warnings.append("ai-vault 中未找到 \(keyName)，尝试本地文件。")
            } catch { result.warnings.append("ai-vault JSON 损坏或无法读取，尝试本地文件。") }
        }
        if FileManager.default.fileExists(atPath: localURL.path) {
            checkPermissions(localURL, into: &result)
            do {
                result.key = try String(contentsOf: localURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                if !result.key.isEmpty { result.source = "本地文件" }
            } catch { result.warnings.append("无法读取本地 Key 文件，请重新保存。") }
        }
        current = result
    }
    private static func find(_ name: String, in tree: [String: Any]) -> String? {
        if let entry = tree[name] as? [String: Any], let value = entry["value"] as? String {
            let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { return key }
        }
        for nameInTree in tree.keys.sorted() {
            if let child = tree[nameInTree] as? [String: Any], let key = find(name, in: child) { return key }
        }
        return nil
    }
    private func checkPermissions(_ url: URL, into result: inout LoadedCredential) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if (attrs?[.posixPermissions] as? NSNumber)?.intValue != 0o600 {
            result.warnings.append("\(url.lastPathComponent) 权限不是 600，建议执行 chmod 600（仍可使用）。")
        }
    }
    func saveLocal(_ rawKey: String, keyName: String) throws {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw PolishFailure(message: "请填写 Key") }
        let fm = FileManager.default
        let directory = localURL.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".openai-key-" + UUID().uuidString)
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw PolishFailure(message: "无法创建本地 Key 文件")
        }
        defer { try? fm.removeItem(at: temporary) }
        try Data(key.utf8).write(to: temporary)
        guard rename(temporary.path, localURL.path) == 0 else { throw PolishFailure(message: "无法保存本地 Key 文件") }
        reload(keyName: keyName)
    }
}
