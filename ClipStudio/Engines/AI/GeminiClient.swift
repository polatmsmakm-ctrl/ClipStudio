//
//  GeminiClient.swift
//  ClipStudio — Engines/AI (Part 5)
//
//  Google Gemini REST client (no SDK), used only with the user's own API key:
//  • GET  /v1beta/models                         — model list for the picker;
//  • POST /v1beta/models/{m}:generateContent      — text, images, uploaded video,
//    structured JSON output (responseSchema) and function calling;
//  • POST /v1beta/models/{m}:streamGenerateContent?alt=sse — streamed replies;
//  • Files API (resumable upload, state polling, delete) for video analysis.
//  The key is sent in the x-goog-api-key header, never in URLs or logs.
//  Every failure maps to a clear Arabic message (GeminiError).
//

import Foundation

struct GeminiModelInfo: Codable, Hashable, Identifiable {
    /// "gemini-2.5-flash" (without "models/").
    var id: String
    var displayName: String
    var inputTokenLimit: Int
    var outputTokenLimit: Int
    var methods: [String]

    var supportsGenerate: Bool { methods.contains("generateContent") }
}

struct GeminiFile: Codable, Hashable {
    /// "files/abc123".
    var name: String
    var uri: String
    var mimeType: String
    var state: String
    var expirationTime: String?
}

enum GeminiError: LocalizedError, Equatable {
    case noKey
    case offline
    case timeout
    case invalidKey
    case permissionDenied(String)
    case modelUnavailable(String)
    case rateLimited(retryAfter: Double?)
    case quotaExceeded
    case blocked(String)
    case server(Int, String)
    case badResponse
    case uploadFailed(String)
    case fileProcessingFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noKey: "لا يوجد مفتاح Gemini — أضفه من الإعدادات ← الذكاء الاصطناعي."
        case .offline: "لا يوجد اتصال بالإنترنت. الأدوات التي تعمل على جهازك ما زالت متاحة."
        case .timeout: "انتهت مهلة الاتصال بـ Gemini. حاول مرة أخرى."
        case .invalidKey: "مفتاح Gemini غير صحيح أو أُلغي. تحقق منه في الإعدادات."
        case .permissionDenied(let message): "ليست لديك صلاحية لهذا الطلب" + (message.isEmpty ? "." : ": " + message)
        case .modelUnavailable(let model): "النموذج «" + model + "» غير متاح لمفتاحك — اختر نموذجًا آخر من الإعدادات."
        case .rateLimited(let wait):
            if let wait, wait > 0 { "تجاوزت حد الطلبات المجاني مؤقتًا — انتظر " + Fmt.int(Int(wait.rounded(.up))) + " ثانية ثم حاول." }
            else { "تجاوزت حد الطلبات المجاني مؤقتًا — انتظر قليلًا ثم حاول." }
        case .quotaExceeded: "انتهت حصتك اليومية في Gemini. حاول غدًا أو استخدم الأدوات على الجهاز."
        case .blocked(let reason): "رفض Gemini الطلب لأسباب أمان المحتوى" + (reason.isEmpty ? "." : " (" + reason + ").")
        case .server(let code, _): "خطأ من خوادم Gemini (" + String(code) + "). حاول بعد قليل."
        case .badResponse: "رد غير مفهوم من Gemini. حاول مرة أخرى."
        case .uploadFailed(let message): "تعذر رفع الملف إلى Gemini" + (message.isEmpty ? "." : ": " + message)
        case .fileProcessingFailed: "لم يتمكن Gemini من معالجة الملف المرفوع."
        case .cancelled: "تم الإلغاء."
        }
    }

    /// Errors after which the on-device provider is a sensible fallback.
    var allowsLocalFallback: Bool {
        switch self {
        case .offline, .timeout, .rateLimited, .quotaExceeded, .server, .badResponse, .noKey: true
        default: false
        }
    }
}

enum GeminiStreamEvent {
    case text(String)
    case functionCall(AIFunctionCall)
    case usage(AIUsageInfo)
}

final class GeminiClient: @unchecked Sendable {
    static let base = URL(string: "https://generativelanguage.googleapis.com")!

    let apiKey: String
    private let session: URLSession

    init(apiKey: String) {
        self.apiKey = apiKey
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 900
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    // MARK: Models

    func listModels() async throws -> [GeminiModelInfo] {
        var models: [GeminiModelInfo] = []
        var pageToken: String?
        repeat {
            var query = [URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let data = try await send(request("v1beta/models", query: query))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GeminiError.badResponse }
            for item in json["models"] as? [[String: Any]] ?? [] {
                guard let name = item["name"] as? String else { continue }
                models.append(GeminiModelInfo(id: name.replacingOccurrences(of: "models/", with: ""),
                                              displayName: item["displayName"] as? String ?? name,
                                              inputTokenLimit: item["inputTokenLimit"] as? Int ?? 0,
                                              outputTokenLimit: item["outputTokenLimit"] as? Int ?? 0,
                                              methods: item["supportedGenerationMethods"] as? [String] ?? []))
            }
            pageToken = json["nextPageToken"] as? String
        } while pageToken?.isEmpty == false
        return models.filter(\.supportsGenerate)
    }

    // MARK: Generate

    static func body(for request: AIRequest) -> [String: Any] {
        var body: [String: Any] = [:]
        body["contents"] = request.messages.map { message -> [String: Any] in
            ["role": message.role.rawValue, "parts": message.parts.map(partJSON)]
        }
        if !request.systemInstruction.isEmpty {
            body["systemInstruction"] = ["parts": [["text": request.systemInstruction]]]
        }
        var generation: [String: Any] = ["temperature": request.temperature]
        if let schema = request.responseSchema {
            generation["responseMimeType"] = "application/json"
            generation["responseSchema"] = schema
        }
        body["generationConfig"] = generation
        if !request.functions.isEmpty {
            body["tools"] = [["functionDeclarations": request.functions.map { function -> [String: Any] in
                var declaration: [String: Any] = ["name": function.name, "description": function.description]
                if let parameters = function.parameters { declaration["parameters"] = parameters }
                return declaration
            }]]
            body["toolConfig"] = ["functionCallingConfig": ["mode": "AUTO"]]
        }
        return body
    }

    private static func partJSON(_ part: AIPart) -> [String: Any] {
        switch part {
        case .text(let text): ["text": text]
        case .inlineData(let mime, let data): ["inlineData": ["mimeType": mime, "data": data.base64EncodedString()]]
        case .fileData(let mime, let uri): ["fileData": ["mimeType": mime, "fileUri": uri]]
        }
    }

    func generate(model: String, request aiRequest: AIRequest) async throws -> AIResponse {
        var urlRequest = request("v1beta/models/" + model + ":generateContent", method: "POST")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.body(for: aiRequest))
        let data = try await send(urlRequest)
        return try Self.parse(data, model: model)
    }

    /// Parses a generateContent response (or one SSE chunk).
    static func parse(_ data: Data, model: String) throws -> AIResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GeminiError.badResponse }
        if let feedback = json["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
            throw GeminiError.blocked(reason)
        }
        var text = ""
        var calls: [AIFunctionCall] = []
        let candidates = json["candidates"] as? [[String: Any]] ?? []
        if let first = candidates.first {
            if let reason = first["finishReason"] as? String, ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST", "SPII"].contains(reason),
               (first["content"] as? [String: Any]) == nil {
                throw GeminiError.blocked(reason)
            }
            let parts = (first["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            for part in parts {
                if let value = part["text"] as? String, part["thought"] as? Bool != true { text += value }
                if let call = part["functionCall"] as? [String: Any], let name = call["name"] as? String {
                    let args = call["args"] as? [String: Any] ?? [:]
                    let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
                    calls.append(AIFunctionCall(name: name, arguments: argsData))
                }
            }
        }
        var usage = AIUsageInfo()
        if let meta = json["usageMetadata"] as? [String: Any] {
            usage.promptTokens = meta["promptTokenCount"] as? Int ?? 0
            usage.outputTokens = (meta["candidatesTokenCount"] as? Int ?? 0) + (meta["thoughtsTokenCount"] as? Int ?? 0)
        }
        return AIResponse(provider: .gemini, model: model, text: text, functionCalls: calls, usage: usage)
    }

    // MARK: Speech (Part 6)

    /// Text-to-speech with a Gemini TTS model: 16-bit mono PCM and its sample rate.
    func speech(model: String, text: String, voice: String) async throws -> (pcm: Data, sampleRate: Int, usage: AIUsageInfo) {
        var urlRequest = request("v1beta/models/" + model + ":generateContent", method: "POST")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.speechBody(text: text, voice: voice))
        let data = try await send(urlRequest)
        return try Self.parseSpeech(data)
    }

    static func speechBody(text: String, voice: String) -> [String: Any] {
        let content: [String: Any] = ["role": "user", "parts": [["text": text]]]
        let speech: [String: Any] = ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice]]]
        let generation: [String: Any] = ["responseModalities": ["AUDIO"], "speechConfig": speech]
        return ["contents": [content], "generationConfig": generation]
    }

    /// Reads the base64 PCM ("audio/L16;codec=pcm;rate=24000") from a TTS response.
    static func parseSpeech(_ data: Data) throws -> (pcm: Data, sampleRate: Int, usage: AIUsageInfo) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GeminiError.badResponse }
        if let feedback = json["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
            throw GeminiError.blocked(reason)
        }
        let candidates = json["candidates"] as? [[String: Any]] ?? []
        let parts = ((candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        var pcm = Data()
        var rate = 24_000
        for part in parts {
            guard let inline = part["inlineData"] as? [String: Any], let base64 = inline["data"] as? String,
                  let chunk = Data(base64Encoded: base64) else { continue }
            pcm.append(chunk)
            let mime = inline["mimeType"] as? String ?? ""
            if let range = mime.range(of: "rate=") {
                let digits = mime[range.upperBound...].prefix { $0.isNumber }
                if let value = Int(digits), value > 0 { rate = value }
            }
        }
        guard !pcm.isEmpty else {
            if let reason = candidates.first?["finishReason"] as? String, reason != "STOP" { throw GeminiError.blocked(reason) }
            throw GeminiError.badResponse
        }
        var usage = AIUsageInfo()
        if let meta = json["usageMetadata"] as? [String: Any] {
            usage.promptTokens = meta["promptTokenCount"] as? Int ?? 0
            usage.outputTokens = meta["candidatesTokenCount"] as? Int ?? 0
        }
        return (pcm: pcm, sampleRate: rate, usage: usage)
    }

    /// Streams text deltas, function calls and the final usage.
    func stream(model: String, request aiRequest: AIRequest) -> AsyncThrowingStream<GeminiStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    var urlRequest = request("v1beta/models/" + model + ":streamGenerateContent", method: "POST",
                                             query: [URLQueryItem(name: "alt", value: "sse")])
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: Self.body(for: aiRequest))
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else { throw GeminiError.badResponse }
                    if !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes { body.append(byte); if body.count > 64_000 { break } }
                        throw Self.error(status: http.statusCode, data: body, headers: http, model: model)
                    }
                    var lastUsage = AIUsageInfo()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { continue }
                        let chunk = try Self.parse(data, model: model)
                        if !chunk.text.isEmpty { continuation.yield(.text(chunk.text)) }
                        for call in chunk.functionCalls { continuation.yield(.functionCall(call)) }
                        if chunk.usage.totalTokens > 0 { lastUsage = chunk.usage }
                    }
                    continuation.yield(.usage(lastUsage))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapTransport(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Files API

    /// Resumable upload of a local file; returns once the file is ACTIVE.
    func upload(fileURL: URL, mimeType: String, displayName: String,
                progress: @escaping @Sendable (Double) -> Void) async throws -> GeminiFile {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw GeminiError.uploadFailed("الملف فارغ") }
        var start = request("upload/v1beta/files", method: "POST")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(size), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": displayName]])
        let (startData, startResponse) = try await perform(start)
        guard let http = startResponse as? HTTPURLResponse else { throw GeminiError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, data: startData, headers: http, model: "")
        }
        guard let uploadURLString = http.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadURLString) else { throw GeminiError.uploadFailed("لا يوجد رابط رفع") }

        var upload = URLRequest(url: uploadURL)
        upload.httpMethod = "POST"
        upload.timeoutInterval = 900
        upload.setValue(String(size), forHTTPHeaderField: "Content-Length")
        upload.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        upload.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        let delegate = UploadProgressDelegate(progress: progress)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: upload, fromFile: fileURL, delegate: delegate)
        } catch {
            throw Self.mapTransport(error)
        }
        guard let uploadHTTP = response as? HTTPURLResponse, (200..<300).contains(uploadHTTP.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw GeminiError.uploadFailed("HTTP " + String(status))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fileJSON = json["file"] as? [String: Any], let file = Self.file(from: fileJSON) else {
            throw GeminiError.badResponse
        }
        return try await waitUntilActive(file)
    }

    private static func file(from json: [String: Any]) -> GeminiFile? {
        guard let name = json["name"] as? String, let uri = json["uri"] as? String else { return nil }
        return GeminiFile(name: name, uri: uri, mimeType: json["mimeType"] as? String ?? "video/mp4",
                          state: json["state"] as? String ?? "PROCESSING", expirationTime: json["expirationTime"] as? String)
    }

    func fileStatus(_ name: String) async throws -> GeminiFile {
        let data = try await send(request("v1beta/" + name))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let file = Self.file(from: json) else {
            throw GeminiError.badResponse
        }
        return file
    }

    func waitUntilActive(_ file: GeminiFile, timeout: Double = 300) async throws -> GeminiFile {
        var current = file
        let deadline = Date().addingTimeInterval(timeout)
        while current.state == "PROCESSING" || current.state == "STATE_UNSPECIFIED" {
            try Task.checkCancellation()
            guard Date() < deadline else { throw GeminiError.fileProcessingFailed }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            current = try await fileStatus(file.name)
        }
        guard current.state == "ACTIVE" else { throw GeminiError.fileProcessingFailed }
        return current
    }

    func deleteFile(_ name: String) async {
        _ = try? await perform(request("v1beta/" + name, method: "DELETE"))
    }

    // MARK: Transport

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw Self.mapTransport(error)
        }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw GeminiError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let model = request.url?.lastPathComponent.components(separatedBy: ":").first ?? ""
            throw Self.error(status: http.statusCode, data: data, headers: http, model: model)
        }
        return data
    }

    static func mapTransport(_ error: Error) -> Error {
        if error is GeminiError { return error }
        if error is CancellationError { return GeminiError.cancelled }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                return GeminiError.offline
            case .timedOut: return GeminiError.timeout
            case .cancelled: return GeminiError.cancelled
            default: return GeminiError.server(url.errorCode, url.localizedDescription)
            }
        }
        return error
    }

    /// Maps an HTTP error to a GeminiError (reads Google's error JSON and RetryInfo).
    static func error(status: Int, data: Data, headers: HTTPURLResponse?, model: String) -> GeminiError {
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
        let message = json?["message"] as? String ?? ""
        let statusText = json?["status"] as? String ?? ""
        switch status {
        case 400:
            if message.localizedCaseInsensitiveContains("API key") { return .invalidKey }
            if statusText == "FAILED_PRECONDITION" { return .permissionDenied(message) }
            return .server(400, message)
        case 401: return .invalidKey
        case 403:
            if message.localizedCaseInsensitiveContains("API key") { return .invalidKey }
            return .permissionDenied(message)
        case 404: return .modelUnavailable(model)
        case 429:
            if message.localizedCaseInsensitiveContains("per day") || message.localizedCaseInsensitiveContains("daily") {
                return .quotaExceeded
            }
            return .rateLimited(retryAfter: retryDelay(json: json, headers: headers))
        default:
            return .server(status, message)
        }
    }

    static func retryDelay(json: [String: Any]?, headers: HTTPURLResponse?) -> Double? {
        if let header = headers?.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(header) { return seconds }
        for detail in json?["details"] as? [[String: Any]] ?? [] {
            if let delay = detail["retryDelay"] as? String {
                let digits = delay.trimmingCharacters(in: CharacterSet(charactersIn: "s "))
                if let seconds = Double(digits) { return seconds }
            }
        }
        return nil
    }
}

/// Reports upload progress (0…1).
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
