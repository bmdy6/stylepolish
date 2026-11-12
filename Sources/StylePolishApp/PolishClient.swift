import Foundation
import StylePolishCore

struct PolishFailure: LocalizedError {
    let message: String
    var detail: String? = nil
    var httpStatus: Int? = nil
    var code: String? = nil
    var parameter: String? = nil
    var errorDescription: String? { message }
}
struct PolishConfiguration { let base: String; let model: String; let key: String; let profile: String; var serviceTier: String = "priority"; var credentialError: String? = nil; var reasoningEffort: String? = "none"; var level: Strictness = .standard; var inviteDeviceID: String? = nil; var inviteBlocked: FallbackReason? = nil; var habits = HabitProfile() }
struct RequestMetrics: Codable {
    var firstTokenMS: Int? = nil
    var totalMS = 0
    var completionTokens: Int? = nil
    var reasoningTokens: Int? = nil
    var promptTokens: Int? = nil
    var totalTokens: Int? = nil
    var httpStatus: Int? = nil
    var errorCategory: String? = nil
    // Transient; only DiagnosticTrace.result forwards this through the debug gate.
    var modelResponse: String? = nil
    private enum CodingKeys: String, CodingKey {
        case firstTokenMS, totalMS, completionTokens, reasoningTokens, promptTokens, totalTokens, httpStatus, errorCategory
    }
}
struct PolishClient {
    var lexiconURL: URL = Self.defaultLexiconURL
    #if DEBUG
    /// Evaluation-only prompt injection; release always uses bundled rules.
    var promptDirectory: URL? = nil
    #endif
    static var defaultLexiconURL: URL {
        RuntimeStorage.home.appendingPathComponent(".style-polish/lexicon.json")
    }
    // Establish TLS/HTTP connection while the app is idle. No text, credential or paid
    // model request is sent; even a 401 response warms the same connection pool.
    func warmConnection(config: PolishConfiguration) async {
        guard config.inviteDeviceID == nil else { return }
        guard var request = try? makeRequest("", config: config, structured: false) else { return }
        request.url = request.url?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("models")
        request.httpMethod = "GET"; request.httpBody = nil; request.timeoutInterval = 5
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Accept")
        _ = try? await PolishTransport.session.data(for: request)
    }

    func testConnection(config: PolishConfiguration) async throws -> Int {
        let start = Date()
        _ = try await suggestions("这个方案非长好。", config: config)
        return Int(Date().timeIntervalSince(start) * 1000)
    }
    static var lexiconRevision: String {
        let path = defaultLexiconURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return "absent" }
        return "\(attrs[.modificationDate] ?? ""):\(attrs[.size] ?? "")"
    }
    private static var resourceBundle: Bundle {
        #if DEBUG
        return Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
        #else
        // Release is distributed as an app; do not embed SwiftPM's absolute build path.
        return Bundle.main
        #endif
    }
    static var promptURL: URL? {
        resourceBundle.url(forResource: "polish", withExtension: "md", subdirectory: "prompts")
    }
    func suggestions(_ input: String, config: PolishConfiguration, metrics: @escaping @MainActor (RequestMetrics) -> Void = { _ in }, update: @escaping @MainActor ([Suggestion]) -> Void = { _ in }) async throws -> [Suggestion] {
        var published = ""
        let raw = try await polish(input, config: config, structured: true, metrics: metrics) { partial in
            let edits = SuggestionParser.partial(partial, source: input)
            let signature = edits.map { "\($0.range.location):\($0.original):\($0.replacement):\($0.kind.rawValue)" }.joined(separator: "\u{0}")
            if signature != published { published = signature; update(edits) }
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any], object["edits"] is [Any] else {
            throw PolishFailure(message: "模型建议格式无效，请重试")
        }
        let result = Array(SuggestionParser.parse(raw, source: input).prefix(3))
        await update(result)
        return result
    }
    @MainActor func wholeResult(_ input: String, config: PolishConfiguration, metrics: @escaping @MainActor (RequestMetrics) -> Void = { _ in }) async throws -> WholePolishResult {
        let started = Date()
        var timing = RequestMetrics()
        do {
            let raw = try await polish(input, config: config, structured: true, metrics: { timing = $0 }) { _ in }
            do {
                let result = try WholePolishResult(raw: raw, source: input)
                timing.totalMS = Int(Date().timeIntervalSince(started) * 1000); metrics(timing)
                return result
            } catch {
                timing.errorCategory = "response_validation"
                throw error
            }
        } catch {
            timing.totalMS = Int(Date().timeIntervalSince(started) * 1000); metrics(timing)
            throw error
        }
    }
    static func resource(_ name: String) throws -> String {
        guard let url = resourceBundle.url(forResource: name, withExtension: "md", subdirectory: "prompts") else {
            throw PolishFailure(message: "找不到内置润色规则，请重新安装")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
    private func promptResource(_ name: String) throws -> String {
        #if DEBUG
        if let promptDirectory {
            return try String(contentsOf: promptDirectory.appendingPathComponent(name + ".md"), encoding: .utf8)
        }
        #endif
        return try Self.resource(name)
    }
    func makeRequest(_ input: String, config: PolishConfiguration, structured: Bool) throws -> URLRequest {
        if config.inviteDeviceID != nil {
            _ = try InviteService.endpoint(config.base)
            if let blocked = config.inviteBlocked { throw PolishFailure(message: blocked.title, code: blocked.inviteCode) }
            guard InviteService.validCode(config.key) else { throw InviteService.failure("invite_invalid")! }
            guard UUID(uuidString: config.inviteDeviceID!) != nil else { throw PolishFailure(message: "设备标识无效") }
        }
        guard !config.key.isEmpty else { throw PolishFailure(message: config.credentialError ?? "没有 API Key，请在设置里填写", code: "missing_key") }
        guard var url = URL(string: config.base), url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")), url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw PolishFailure(message: "接口地址无效，请使用 HTTPS（本机服务可使用 HTTP）")
        }
        url.appendPathComponent("chat/completions")
        var prompt = try promptResource("polish")
        if structured { prompt += "\n" + (try promptResource("automatic")) + "\n" + (try promptResource(config.level.rawValue)) }
        if let data = try? Data(contentsOf: lexiconURL), data.count <= 64_000,
           (try? JSONSerialization.jsonObject(with: data)) != nil,
           let words = String(data: data, encoding: .utf8) {
            prompt += "\n" + (try promptResource("lexicon")) + "\n" + words
        }
        if !config.habits.promptLines.isEmpty {
            prompt += "\n\n" + (try promptResource("habits")) + "\n" + config.habits.promptLines.prefix(10).joined(separator: "\n")
        }
        let path = (config.profile as NSString).expandingTildeInPath
        if !path.isEmpty, let profile = try? String(contentsOfFile: path, encoding: .utf8) { prompt += "\n\n口吻档案：\n" + profile }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer " + config.key, forHTTPHeaderField: "Authorization")
        if let device = config.inviteDeviceID { request.setValue(device, forHTTPHeaderField: "X-StylePolish-Device") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body: [String: Any] = ["model": config.model, "stream": true, "max_completion_tokens": 2048,
            "stream_options": ["include_usage": true],
            "messages": [["role": "system", "content": prompt], ["role": "user", "content": input]]]
        if config.model.hasPrefix("gpt-6-luna"), let effort = config.reasoningEffort { body["reasoning_effort"] = effort }
        if config.model.hasPrefix("deepseek") { body["thinking"] = ["type": "disabled"] }
        if !config.serviceTier.isEmpty { body["service_tier"] = config.serviceTier }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    func polish(_ input: String, config: PolishConfiguration, structured: Bool = false, metrics: @escaping @MainActor (RequestMetrics) -> Void = { _ in }, update: @escaping @MainActor (String) -> Void) async throws -> String {
        let started = Date()
        do {
            return try await performPolish(input, config: config, structured: structured, metrics: metrics, update: update)
        } catch {
            let failure = error as? PolishFailure
            var timing = RequestMetrics()
            timing.totalMS = Int(Date().timeIntervalSince(started) * 1000)
            timing.httpStatus = failure?.httpStatus
            timing.errorCategory = error is CancellationError ? "cancelled" : failure?.code == "missing_key" ? "missing_key" : failure?.code == "network" ? "network" : failure?.code == "response" ? "response" : failure?.httpStatus != nil ? "http" : "response_or_configuration"
            await metrics(timing)
            throw error
        }
    }
    private func performPolish(_ input: String, config: PolishConfiguration, structured: Bool, metrics: @escaping @MainActor (RequestMetrics) -> Void, update: @escaping @MainActor (String) -> Void) async throws -> String {
        let started = Date()
        let request = try makeRequest(input, config: config, structured: structured)
        // Reuse the connection pool across keystrokes. Request/task cancellation is isolated;
        // invalidating a shared session would abort checks in other editors.
        let session = PolishTransport.session
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { [request] in
                var status: Int?
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let response = response as? HTTPURLResponse else { throw PolishFailure(message: "服务响应无效") }
                    status = response.statusCode
                    if !(200...299).contains(response.statusCode) {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= 16_384 { break }
                        }
                        let error = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? [String: Any]
                        let code = error?["code"] as? String
                        if config.inviteDeviceID != nil, let failure = InviteService.failure(code, status: response.statusCode) { throw failure }
                        let parameter = error?["param"] as? String
                        if String(data: body, encoding: .utf8)?.contains("insufficient_quota") == true { throw PolishFailure(message: "额度用完", httpStatus: response.statusCode, code: "insufficient_quota") }
                        if code == "model_not_found" || (response.statusCode == 400 && parameter == "model") {
                            throw PolishFailure(message: "模型不存在或不可用，请检查模型名称", httpStatus: response.statusCode, code: code)
                        }
                        switch response.statusCode {
                        case 401: throw PolishFailure(message: "Key 无效，请检查设置", httpStatus: response.statusCode, code: code)
                        case 403: throw PolishFailure(message: "模型服务没有权限，请检查 Key 和模型", httpStatus: response.statusCode, code: code)
                        case 404: throw PolishFailure(message: "模型不存在或不可用，请检查模型名称", httpStatus: response.statusCode, code: code)
                        case 429: throw PolishFailure(message: "额度不足或请求过频，请检查账户额度后重试", httpStatus: response.statusCode, code: code)
                        case 400: throw PolishFailure(message: "参数不支持", detail: String(data: body, encoding: .utf8)?.replacingOccurrences(of: config.key, with: "[REDACTED]"), httpStatus: response.statusCode, code: code, parameter: parameter)
                        default: throw PolishFailure(message: "模型服务返回 HTTP \(response.statusCode)", httpStatus: response.statusCode, code: code)
                        }
                    }
                    var timing = RequestMetrics(); timing.httpStatus = response.statusCode
                    var parser = SSEParser(), result = ""
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if line.hasPrefix("data:"), let data = String(line.dropFirst(5)).data(using: .utf8),
                           let chunk = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                           let usage = chunk["usage"] as? [String: Any] {
                            timing.promptTokens = usage["prompt_tokens"] as? Int
                            timing.totalTokens = usage["total_tokens"] as? Int
                            timing.completionTokens = usage["completion_tokens"] as? Int
                            timing.reasoningTokens = (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int
                        }
                        if let part = try parser.consume(line) {
                            if !part.isEmpty && timing.firstTokenMS == nil { timing.firstTokenMS = Int(Date().timeIntervalSince(started) * 1000) }
                            result += part
                            guard result.utf8.count <= 1_000_000 else { throw PolishFailure(message: "模型结果过长，请缩短原文") }
                            await update(result)
                        }
                        if parser.isDone { break }
                    }
                    guard parser.isDone else { throw PolishFailure(message: "响应中断，请重试") }
                    let cleaned = structured ? result.trimmingCharacters(in: .whitespacesAndNewlines) : postprocess(result)
                    guard !cleaned.isEmpty else { throw PolishFailure(message: "模型返回了空内容，请重试") }
                    timing.totalMS = Int(Date().timeIntervalSince(started) * 1000)
                    timing.modelResponse = result
                    await metrics(timing)
                    return cleaned
                } catch let error as PolishFailure {
                    throw PolishFailure(message: error.message, detail: error.detail, httpStatus: error.httpStatus ?? status, code: error.code ?? (status.map { (200...299).contains($0) } == true ? "response" : nil), parameter: error.parameter)
                } catch is CancellationError { throw CancellationError() }
                catch let error as URLError {
                    if error.code == .cancelled { throw CancellationError() }
                    throw PolishFailure(message: error.code == .timedOut ? "接口超时（30s），原文没动" : "网络失败，请检查连接", code: "network")
                } catch is DecodingError { throw PolishFailure(message: "模型响应格式无效，请检查兼容接口", httpStatus: status, code: "response") }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw PolishFailure(message: "接口超时（30s），原文没动", code: "network")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum PolishTransport {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 30
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()
}
