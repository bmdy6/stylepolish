import Foundation
import Combine
import Darwin
import StylePolishCore

enum InviteService {
    static let defaultBase = "https://relay.invalid"
    static func validCode(_ code: String) -> Bool {
        code.range(of: #"\ASP-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}\z"#, options: .regularExpression) != nil
    }
    static func endpoint(_ base: String) throws -> URL {
        guard var url = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")),
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw PolishFailure(message: "中转地址无效，请使用 HTTPS（本机服务可使用 HTTP）")
        }
        if url.host?.lowercased() == "relay.invalid" { throw failure("trial_unavailable")! }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path
        url = components.url!
        if !url.path.hasSuffix("/v1") { url.appendPathComponent("v1") }
        return url
    }
    static func failure(_ code: String?, status: Int? = nil) -> PolishFailure? {
        let text: String
        switch code {
        case "invite_invalid": text = "邀请码无效"
        case "invite_exhausted": text = "试用额度用完"
        case "monthly_cap_reached": text = "本月试用已满"
        case "rate_limited": text = "稍后再试（这次用本地规则）"
        case "input_too_long": text = "这段太长，用本地规则"
        case "upstream_error": text = "网络不通（这次用本地规则）"
        case "trial_unavailable": text = "试用服务还没开放"
        case "invite_unverified": text = "请先验证邀请码"
        default: return nil
        }
        return PolishFailure(message: text, httpStatus: status, code: code)
    }
}

/// File-only credentials and quota metadata. Never reads the author's API credential.
final class InviteAccess: ObservableObject {
    private struct Record: Codable {
        var code: String
        var endpoint: String
        var remaining: Int?
        var blocked: FallbackReason?
        var lowQuotaWarned: Bool
    }
    let directory: URL
    let codeURL: URL
    let deviceURL: URL
    let deviceID: String
    @Published private(set) var code = ""
    @Published private(set) var remainingPercent: Int?
    @Published private(set) var blockedReason: FallbackReason? = .inviteUnverified
    @Published private(set) var message = ""
    @Published private(set) var validating = false
    private(set) var verifiedEndpoint = ""
    private var lowQuotaWarned = false
    private var lowQuotaPending = false
    private var generation = UUID()

    init(home: URL = RuntimeStorage.home) {
        directory = home.appendingPathComponent(".config/stylepolish")
        codeURL = directory.appendingPathComponent("invite.json")
        deviceURL = directory.appendingPathComponent("device-id")
        // Reuse an existing UUID; never mint a different identity per request.
        let saved = (try? String(contentsOf: deviceURL))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = saved.flatMap(UUID.init(uuidString:))?.uuidString ?? UUID().uuidString
        do {
            try Self.write(Data(id.utf8), to: deviceURL)
            deviceID = id
        } catch { deviceID = ""; message = "无法保存设备标识，请检查本地目录权限" }
        if let data = try? Data(contentsOf: codeURL), let record = try? JSONDecoder().decode(Record.self, from: data), InviteService.validCode(record.code) {
            code = record.code; remainingPercent = record.remaining; verifiedEndpoint = record.endpoint
            blockedReason = record.blocked; lowQuotaWarned = record.lowQuotaWarned
            lowQuotaPending = (record.remaining ?? 100) < 10 && !record.lowQuotaWarned && record.blocked == nil
            // Enforce permissions on legacy files too.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: codeURL.path)
        }
    }
    private static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default, directory = url.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temp = directory.appendingPathComponent(".invite-" + UUID().uuidString)
        guard fm.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? fm.removeItem(at: temp) }
        try data.write(to: temp)
        guard rename(temp.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    private func persist() throws {
        let record = Record(code: code, endpoint: verifiedEndpoint, remaining: remainingPercent, blocked: blockedReason, lowQuotaWarned: lowQuotaWarned)
        try Self.write(JSONEncoder().encode(record), to: codeURL)
    }
    func block(for base: String) -> FallbackReason? {
        guard let endpoint = try? InviteService.endpoint(base).absoluteString else { return .trialUnavailable }
        if code.isEmpty { return .inviteUnverified }
        return endpoint == verifiedEndpoint ? blockedReason : .inviteUnverified
    }
    func canUse(base: String) -> Bool { block(for: base) == nil && !deviceID.isEmpty }
    func resetVerification() {
        generation = UUID(); validating = false; blockedReason = .inviteUnverified
        verifiedEndpoint = ""; remainingPercent = nil; message = "请先验证邀请码"
        try? persist()
    }
    @MainActor func verify(_ raw: String, base: String) async {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard InviteService.validCode(normalized) else { message = "邀请码格式不对，请使用 SP-XXXX-XXXX（不含 0 O 1 I）"; return }
        generation = UUID(); code = normalized; verifiedEndpoint = ""; remainingPercent = nil
        blockedReason = .inviteUnverified; lowQuotaWarned = false; lowQuotaPending = false
        do { try persist() } catch { message = "无法保存邀请码，请检查本地目录权限"; return }
        await fetch(base: base)
    }
    @MainActor func refresh(base: String) async {
        guard !code.isEmpty, !validating else { return }
        await fetch(base: base)
    }
    @MainActor private func fetch(base: String) async {
        let id = generation, savedCode = code
        validating = true; message = "正在验证…"
        defer { if generation == id { validating = false } }
        do {
            let endpoint = try InviteService.endpoint(base)
            guard !deviceID.isEmpty else { throw PolishFailure(message: "无法保存设备标识，请检查本地目录权限") }
            var request = URLRequest(url: endpoint.appendingPathComponent("invite"), timeoutInterval: 10)
            request.setValue("Bearer " + savedCode, forHTTPHeaderField: "Authorization")
            request.setValue(deviceID, forHTTPHeaderField: "X-StylePolish-Device")
            let (bytes, response) = try await PolishTransport.session.bytes(for: request)
            guard generation == id, code == savedCode else { return }
            guard let response = response as? HTTPURLResponse else { throw PolishFailure(message: "试用服务响应无效") }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= 16_384 else { throw PolishFailure(message: "试用服务响应无效") }
            }
            try Task.checkCancellation()
            guard generation == id, code == savedCode else { return }
            if response.statusCode != 200 {
                let error = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? [String: Any]
                throw InviteService.failure(error?["code"] as? String, status: response.statusCode)
                    ?? PolishFailure(message: "试用服务暂时不可用", httpStatus: response.statusCode)
            }
            struct Status: Decodable { let status: String; let remaining_percent: Int }
            let status = try JSONDecoder().decode(Status.self, from: data)
            guard ["active", "exhausted", "revoked"].contains(status.status), (0...100).contains(status.remaining_percent) else { throw PolishFailure(message: "试用服务响应无效") }
            verifiedEndpoint = endpoint.absoluteString; remainingPercent = status.remaining_percent
            blockedReason = status.status == "revoked" ? .inviteInvalid : status.status == "exhausted" || status.remaining_percent == 0 ? .inviteExhausted : nil
            message = blockedReason?.title ?? "有效"
            lowQuotaPending = blockedReason == nil && status.remaining_percent < 10 && !lowQuotaWarned
            try persist()
        } catch {
            guard generation == id, code == savedCode else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { message = "验证已取消"; return }
            let reason = FallbackReason.classify(error)
            if reason.blocksInvite {
                verifiedEndpoint = (try? InviteService.endpoint(base).absoluteString) ?? ""
                blockedReason = reason; try? persist()
            }
            message = (error as? PolishFailure)?.message ?? (error is URLError ? "网络不通（这次用本地规则）" : "试用服务响应无效")
        }
    }
    /// Called only for the matching request snapshot; terminal failures survive restart.
    func checked(fallback: FallbackReason, code requestCode: String, base: String) {
        guard requestCode == code, (try? InviteService.endpoint(base).absoluteString) == verifiedEndpoint else { return }
        if fallback.blocksInvite {
            // A GET begun before this POST failure must not reactivate the code.
            generation = UUID(); validating = false
            blockedReason = fallback; message = fallback.title
            try? persist()
        }
    }
    func consumeLowQuotaWarning() -> String? {
        guard lowQuotaPending, blockedReason == nil else { return nil }
        lowQuotaPending = false; lowQuotaWarned = true; try? persist()
        return "试用额度不足 10% · 换邀请码 / 用自己的 Key ›"
    }
}
