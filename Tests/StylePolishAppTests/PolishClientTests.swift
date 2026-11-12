import XCTest
import StylePolishCore
@testable import StylePolishApp

final class PolishClientTests: XCTestCase {
    func testExternalPlainTextCandidateUsesSameRequestAndStreamingTransport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "只输出处理后的正文，不要解释".write(to: directory.appendingPathComponent("polish.md"), atomically: true, encoding: .utf8)
        var client = PolishClient(lexiconURL: directory.appendingPathComponent("absent.json"))
        client.promptDirectory = directory
        let config = PolishConfiguration(base: base, model: "success", key: "synthetic-test-value", profile: "")
        let request = try client.makeRequest("你好", config: config, structured: false)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages[0]["content"], "只输出处理后的正文，不要解释")
        XCTAssertEqual(messages[1]["content"], "你好")
        let result = try await client.polish("你好", config: config) { _ in }
        XCTAssertEqual(result, "你好")
    }
    func testWholeContextAndOptionalLexiconInRequest() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = PolishClient(lexiconURL: url)
        let input = "第一句。第二句\n最后一段🙂"
        let config = PolishConfiguration(base: "https://example.com/v1", model: "synthetic", key: "synthetic", profile: "")
        func messages() throws -> [[String: String]] {
            let request = try client.makeRequest(input, config: config, structured: true)
            return (try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any])["messages"] as! [[String: String]]
        }
        let without = try messages()
        XCTAssertEqual(without.count, 2)
        XCTAssertEqual(without[1]["content"], input)
        XCTAssertTrue(without[0]["content"]!.contains("整段润色后的正文"))
        let words = #"{"aliases":{"测试别名":"测试专名"}}"#
        try words.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(try messages()[0]["content"]!.contains(words))
        try "broken json".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try messages(), without)
    }
    private var server: Process!
    private var base: String!
    override func setUpWithError() throws {
        server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", #"""
import http.server,json
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a): pass
 def do_GET(self):
  Handler.warmed=(self.path.endswith('/models') and 'Authorization' not in self.headers and self.headers.get('Content-Length','0')=='0')
  self.send_response(200);self.end_headers()
 def do_POST(self):
  body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  if body.get('max_completion_tokens')!=2048 or 'max_output_tokens' in body or body['stream'] is not True or body['messages'][0]['role']!='system' or '只输出' not in body['messages'][0]['content']:
   self.send_response(400);self.end_headers();return
  mode=body['model']
  if mode=='warmcheck' and not getattr(Handler,'warmed',False):self.send_response(400);self.end_headers();return
  if mode=='compatible' and 'service_tier' in body:self.send_response(400);self.end_headers();return
  if mode in ['fast','compatible'] and '只输出 JSON' not in body['messages'][0]['content']:self.send_response(400);self.end_headers();return
  if mode=='fast' and body.get('service_tier')!='priority':self.send_response(400);self.end_headers();return
  if mode=='unsupported':
   self.send_response(400);self.end_headers();self.wfile.write(json.dumps({'error':{'code':'unknown_parameter','param':'bad_param','message':'Unknown parameter and '+self.headers['Authorization']}}).encode());return
  if mode=='missing400':
   self.send_response(400);self.end_headers();self.wfile.write(json.dumps({'error':{'code':'model_not_found','message':'do not show raw server messages'}}).encode());return
  if mode=='quota':
   self.send_response(400);self.end_headers();self.wfile.write(b'{"error":{"code":"insufficient_quota"}}');return
  if mode=='missing':self.send_response(404);self.end_headers();return
  if mode=='limited':self.send_response(429);self.end_headers();return
  if mode=='invalid':self.send_response(401);self.end_headers();return
  if mode=='forbidden':self.send_response(403);self.end_headers();return
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
  if mode=='malformed':self.wfile.write(b'data: nope\n\n');return
  if mode=='structured':
   if '只输出 JSON' not in body['messages'][0]['content']:
    self.wfile.write(b'data: nope\n\n');return
   chunks=[json.dumps({'text':'非常好。','edits':[{'original':'非长','replacement':'非常','kind':'typo','why':'错别字'}]},ensure_ascii=False)]
  elif mode in ['fast','compatible']:chunks=['{"edits":[]}']
  elif mode=='incremental':
   import time
   first=json.dumps({'original':'非长','replacement':'非常','kind':'typo','why':'错字'},ensure_ascii=False)
   text='{"edits":['+first
   self.wfile.write(('data: '+json.dumps({'choices':[{'delta':{'content':text}}]},ensure_ascii=False)+'\n\n').encode());self.wfile.flush()
   time.sleep(0.5)
   chunks=[']}']
  elif mode=='usage':
   self.wfile.write(('data: '+json.dumps({'choices':[],'usage':{'completion_tokens':100,'completion_tokens_details':{'reasoning_tokens':20}}})+'\n\n').encode())
   chunks=['好']
  elif mode=='slow':
   import time
   time.sleep(2)
   chunks=['你好']
  else:chunks=[' 你好','。 ']
  for text in chunks:
   self.wfile.write(('data: '+json.dumps({'choices':[{'delta':{'content':text}}]},ensure_ascii=False)+'\n\n').encode());self.wfile.flush()
  if mode!='truncated':self.wfile.write(b'data: [DONE]\n\n');self.wfile.flush()
s=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
print(s.server_port,flush=True)
s.serve_forever()
"""#]
        let pipe = Pipe(); server.standardOutput = pipe; server.standardError = FileHandle.nullDevice
        try server.run()
        let data = pipe.fileHandleForReading.availableData
        guard let port = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), Int(port) != nil else { throw CocoaError(.fileReadUnknown) }
        base = "http://127.0.0.1:" + port
    }
    override func tearDown() { if server?.isRunning == true { server.terminate(); server.waitUntilExit() } }
    func testRequestConstructionHasOneOwner() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/StylePolishApp/PolishClient.swift")
        let code = try String(contentsOf: source)
        XCTAssertEqual(code.components(separatedBy: "URLRequest(url:").count - 1, 1)
        XCTAssertEqual(code.components(separatedBy: "JSONSerialization.data(withJSONObject: body)").count - 1, 1)
        let config = PolishConfiguration(base: base, model: "gpt-6-luna", key: "synthetic-test-value", profile: "", serviceTier: "priority")
        let request = try PolishClient().makeRequest("测试", config: config, structured: true)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertTrue(request.url!.path.hasSuffix("/chat/completions"))
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 2048)
        XCTAssertNil(body["max_output_tokens"])
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
        XCTAssertEqual((body["stream_options"] as? [String: Bool])?["include_usage"], true)
        XCTAssertEqual(body["service_tier"] as? String, "priority")
    }
    func testDeepSeekRequestsDisableThinking() throws {
        for model in ["deepseek-flash", "deepseek-chat", "deepseek-reasoner"] {
            for structured in [false, true] {
                let config = PolishConfiguration(base: base, model: model, key: "synthetic-test-value", profile: "", serviceTier: "", level: .strict)
                let request = try PolishClient().makeRequest("这个方案非长好。", config: config, structured: structured)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                XCTAssertEqual(body["thinking"] as? [String: String], ["type": "disabled"], model)
                XCTAssertNil(body["reasoning_effort"], model)
            }
        }
    }
    func testOtherModelsOmitThinkingAndPreserveLunaReasoningEffort() throws {
        for model in ["gpt-6-luna", "gpt-6-luna-preview", "gpt-4.1", "synthetic", "vendor/deepseek-flash"] {
            for effort: String? in ["none", "low", nil] {
                let config = PolishConfiguration(base: base, model: model, key: "synthetic-test-value", profile: "", reasoningEffort: effort)
                let request = try PolishClient().makeRequest("测试", config: config, structured: true)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
                XCTAssertNil(body["thinking"], model)
                XCTAssertEqual(body["reasoning_effort"] as? String, model.hasPrefix("gpt-6-luna") ? effort : nil, model)
            }
        }
    }
    func testRealHTTPStreamingAndMissingProfile() async throws {
        let result = try await PolishClient().polish("你好", config: PolishConfiguration(base: base, model: "success", key: "synthetic-test-value", profile: "/nonexistent/style-polish-profile.md")) { _ in }
        XCTAssertEqual(result, "你好")
    }
    func testParameterFailureKeepsSafeReasonAndRedactsCredential() async throws {
        do {
            _ = try await PolishClient().suggestions("测试", config: PolishConfiguration(base: base, model: "unsupported", key: "synthetic-test-value", profile: ""))
            XCTFail("Expected parameter failure")
        } catch let error as PolishFailure {
            XCTAssertEqual(error.message, "参数不支持")
            XCTAssertEqual(error.httpStatus, 400)
            XCTAssertEqual(error.parameter, "bad_param")
            XCTAssertEqual(error.code, "unknown_parameter")
            XCTAssertFalse(error.detail?.contains("synthetic-test-value") ?? true)
        }
    }
    func testErrorsAndTruncatedStream() async {
        for (model, expected) in [("invalid", "Key 无效"), ("forbidden", "没有权限"), ("missing", "模型不存在"), ("missing400", "模型不存在"), ("limited", "额度"), ("malformed", "格式无效"), ("truncated", "响应中断")] {
            do {
                _ = try await PolishClient().polish("测试文本", config: PolishConfiguration(base: base, model: model, key: "synthetic-test-value", profile: "")) { _ in }
                XCTFail("Expected failure for \(model)")
            } catch { XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription) }
        }
    }
    func testMissingKeyAndUnsafeURLRejected() async {
        for config in [PolishConfiguration(base: base, model: "test", key: "", profile: ""), PolishConfiguration(base: "http://example.com", model: "test", key: "synthetic-test-value", profile: "")] {
            do { _ = try await PolishClient().polish("测试文本", config: config) { _ in }; XCTFail("Should reject") }
            catch { XCTAssertTrue(error is PolishFailure) }
        }
    }
    func testStructuredStreamingPreservesPunctuationAndMetadata() async throws {
        let result = try await PolishClient().suggestions("非长好。", config: PolishConfiguration(base: base, model: "structured", key: "synthetic-test-value", profile: ""))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.original, "长")
        XCTAssertEqual(result.first?.replacement, "常")
        XCTAssertEqual(result.first?.kind, .typo)
    }
    func testFastConnectionUsesSameStreamingClient() async throws {
        let ms = try await PolishClient().testConnection(config: PolishConfiguration(base: base, model: "fast", key: "synthetic-test-value", profile: "", serviceTier: "priority"))
        XCTAssertGreaterThanOrEqual(ms, 0)
    }
    func testCompatibleEndpointCanOmitServiceTier() async throws {
        _ = try await PolishClient().testConnection(config: PolishConfiguration(base: base, model: "compatible", key: "synthetic-test-value", profile: "", serviceTier: ""))
    }
    @MainActor func testSuggestionPublishedBeforeStreamCompletes() async throws {
        let start = Date()
        var first: TimeInterval?
        let edits = try await PolishClient().suggestions("非长好。", config: PolishConfiguration(base: base, model: "incremental", key: "synthetic-test-value", profile: ""), update: { edits in
            if !edits.isEmpty && first == nil { first = Date().timeIntervalSince(start) }
        })
        XCTAssertEqual(edits.count, 1)
        XCTAssertLessThan(try XCTUnwrap(first), Date().timeIntervalSince(start) - 0.3)
    }
    @MainActor func testUsageOnlyChunkCaptured() async throws {
        var timing = RequestMetrics()
        _ = try await PolishClient().polish("好", config: PolishConfiguration(base: base, model: "usage", key: "synthetic-test-value", profile: ""), metrics: { timing = $0 }) { _ in }
        XCTAssertEqual(timing.completionTokens, 100)
        XCTAssertEqual(timing.reasoningTokens, 20)
        XCTAssertNotNil(timing.firstTokenMS)
    }
    func testStartupWarmupSendsNoKeyOrInput() async throws {
        let config = PolishConfiguration(base: base, model: "warmcheck", key: "synthetic-test-value", profile: "")
        await PolishClient().warmConnection(config: config)
        let result = try await PolishClient().polish("你好", config: config) { _ in }
        XCTAssertEqual(result, "你好")
    }
    func testCancellationDoesNotInvalidateOtherRequests() async throws {
        let slow = Task { try await PolishClient().polish("测试", config: PolishConfiguration(base: base, model: "slow", key: "synthetic-test-value", profile: "")) { _ in } }
        try await Task.sleep(nanoseconds: 60_000_000)
        slow.cancel()
        _ = try? await slow.value
        let fast = try await PolishClient().polish("你好", config: PolishConfiguration(base: base, model: "success", key: "synthetic-test-value", profile: "")) { _ in }
        XCTAssertEqual(fast, "你好")
    }
    func testCancellationStopsInFlightRequest() async throws {
        let config = PolishConfiguration(base: base, model: "slow", key: "synthetic-test-value", profile: "")
        let request = Task { try await PolishClient().suggestions("测试文本", config: config) }
        try await Task.sleep(nanoseconds: 80_000_000)
        let start = Date(); request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled request returned suggestions") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testHTTPMetadataDrivesLocalFallback() async throws {
        for (model, reason) in [("invalid", FallbackReason.key), ("forbidden", .key), ("limited", .quota), ("quota", .quota), ("missing", .other)] {
            let config = PolishConfiguration(base: base, model: model, key: "synthetic-test-value", profile: "")
            let result = try await CheckEngine().check("我因该回复", engine: .ai, config: config)
            XCTAssertEqual(result.fallback, reason, model)
            XCTAssertEqual(result.suggestions.first?.replacement, "应该")
        }
    }

    @MainActor func testDiagnosticMetricsCoverHTTPFailureAndSuccessfulUsage() async throws {
        var metrics: [RequestMetrics] = []
        let bad = PolishConfiguration(base: base, model: "invalid", key: "synthetic-test-value", profile: "")
        let fallback = try await CheckEngine().check("我因该回复", engine: .ai, config: bad, metrics: { metrics.append($0) })
        XCTAssertEqual(fallback.fallback, .key)
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].httpStatus, 401)
        XCTAssertEqual(metrics[0].errorCategory, "http")
        metrics = []
        _ = try await PolishClient().polish("好", config: PolishConfiguration(base: base, model: "usage", key: "synthetic-test-value", profile: ""), metrics: { metrics.append($0) }) { _ in }
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].httpStatus, 200)
        XCTAssertEqual(metrics[0].completionTokens, 100)
        XCTAssertNil(metrics[0].errorCategory)
    }
    @MainActor func testInvalidStructuredResponseEmitsOneValidationMetric() async throws {
        var metrics: [RequestMetrics] = []
        let result = try await CheckEngine().check("我因该回复", engine: .ai, config: PolishConfiguration(base: base, model: "success", key: "synthetic-test-value", profile: ""), metrics: { metrics.append($0) })
        XCTAssertEqual(result.fallback, .other)
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].httpStatus, 200)
        XCTAssertEqual(metrics[0].errorCategory, "response_validation")
        XCTAssertNotNil(metrics[0].modelResponse)
    }
    @MainActor func testMissingKeyAndCancelledRequestHaveDiagnosticCategories() async throws {
        var metrics: [RequestMetrics] = []
        _ = try await CheckEngine().check("我因该回复", engine: .ai, config: PolishConfiguration(base: base, model: "success", key: "", profile: ""), metrics: { metrics.append($0) })
        XCTAssertEqual(metrics.count, 1); XCTAssertNil(metrics[0].httpStatus)
        XCTAssertEqual(metrics[0].errorCategory, "missing_key")
        metrics = []
        let task = Task {
            try await PolishClient().polish("测试", config: PolishConfiguration(base: base, model: "slow", key: "synthetic-test-value", profile: ""), metrics: { metrics.append($0) }) { _ in }
        }
        try await Task.sleep(nanoseconds: 50_000_000); task.cancel()
        _ = try? await task.value
        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics[0].errorCategory, "cancelled")
    }

    @MainActor func testFullAIFlowSharesTraceThroughRequestAndWriteWithoutBody() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = Diagnostics(directory: root)
        log.configure(debug: false, secrets: ["synthetic-test-value"])
        let trace = DiagnosticTrace(bundleID: "synthetic", log: log)
        var editor = "非长好。"
        let source = editor
        trace.capture(text: editor, role: "AXTextArea", writable: true, selection: nil, attachment: .plain, hasPosition: false)
        trace.started(engine: .ai, level: .standard, cacheHit: false)
        let result = try await CheckEngine().check(editor, engine: .ai, config: PolishConfiguration(base: base, model: "structured", key: "synthetic-test-value", profile: ""), metrics: { trace.metrics($0, model: "structured") })
        trace.result(source: source, suggestions: result.suggestions, engine: .ai, fallback: result.fallback, unclear: result.unclear, requestMS: 1, resultMS: 1)
        let preview = try XCTUnwrap(SuggestionPreview(source: source, edits: result.suggestions))
        trace.presented("preview_bar", mode: preview.mode.rawValue, hasPosition: false, count: result.suggestions.count)
        trace.action("accept_all", count: result.suggestions.count)
        let writer = SuggestionWriter(isCurrent: { editor == $0 }, writeAX: { editor = preview.output; return true }, paste: { _, _ in XCTFail("No paste") })
        let outcome = await writer.write(source: source, output: preview.output, valid: { true })
        XCTAssertTrue(outcome.confirmed)
        trace.write(source: source, expected: preview.output, readback: editor, method: "selected_range", attachment: .plain)
        log.flush()
        let json = try String(contentsOf: log.url)
        let rows = try json.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(rows.compactMap { $0["event"] as? String }, ["capture", "check_started", "request_metrics", "result", "preview_shown", "user_action", "write"])
        XCTAssertEqual(Set(rows.compactMap { $0["traceID"] as? String }), [trace.id])
        XCTAssertEqual(rows[2]["httpStatus"] as? Int, 200)
        XCTAssertEqual(rows.last?["readbackMatches"] as? Bool, true)
        XCTAssertFalse(json.contains(source)); XCTAssertFalse(json.contains(preview.output)); XCTAssertFalse(json.contains("synthetic-test-value"))
    }

}
