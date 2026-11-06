//
//  AIRequestRouter.swift
//  ClipStudio — Engines/AI (Part 5)
//
//  The single entry point for AI requests. It decides who answers (Gemini when
//  enabled and a key exists, otherwise the on-device provider), applies the daily
//  limit and rate-limit cool-down, serves the response cache, streams text when
//  asked, records usage, and falls back to the on-device provider when Gemini is
//  unreachable or rate-limited (the result says so). Media uploads also go through
//  here so already-uploaded videos are reused.
//

import Foundation

@MainActor
final class AIRequestRouter {
    static let shared = AIRequestRouter()

    private var settings: AISettings { .shared }
    private var usage: AIUsageManager { .shared }
    private var models: AIModelManager { .shared }

    /// Who will answer `task` right now.
    func provider(for task: AITask) -> AIProviderKind {
        settings.cloudAvailable ? .gemini : .local
    }

    /// Runs a request. `onText` receives streamed text when Gemini answers.
    /// - Parameter forceLocal: the user chose the on-device provider (e.g. declined an upload).
    func perform(_ request: AIRequest, forceLocal: Bool = false, stream: Bool = false,
                 onText: ((String) -> Void)? = nil) async throws -> AIResponse {
        guard !forceLocal, provider(for: request.task) == .gemini, let key = settings.effectiveKey else {
            return try await local(request, note: nil)
        }
        if let blocked = usage.blockReason(limit: settings.dailyLimit) {
            return try await fallback(request, error: blocked)
        }
        let model = models.resolvedModel
        let cacheKey = request.cacheKey(model: model)
        if settings.cacheResponses, !stream, let cached = AICacheManager.response(for: cacheKey) {
            usage.record(cached)
            return cached
        }
        let client = GeminiClient(apiKey: key)
        do {
            var response: AIResponse
            if stream, let onText {
                response = AIResponse(provider: .gemini, model: model, text: "", functionCalls: [], usage: AIUsageInfo())
                for try await event in client.stream(model: model, request: request) {
                    switch event {
                    case .text(let delta):
                        response.text += delta
                        onText(delta)
                    case .functionCall(let call):
                        response.functionCalls.append(call)
                    case .usage(let info):
                        response.usage = info
                    }
                }
            } else {
                response = try await GeminiProvider(client: client).generate(request, model: model)
            }
            usage.record(response)
            if settings.cacheResponses { AICacheManager.store(response, for: cacheKey) }
            return response
        } catch let error as GeminiError {
            if case .rateLimited(let wait) = error { usage.setCooldown(seconds: wait ?? 30) }
            return try await fallback(request, error: error)
        } catch is CancellationError {
            throw GeminiError.cancelled
        }
    }

    private func fallback(_ request: AIRequest, error: GeminiError) async throws -> AIResponse {
        guard error.allowsLocalFallback, settings.localFallback, request.task.hasLocalFallback, request.localInput != nil else {
            throw error
        }
        return try await local(request, note: (error.errorDescription ?? "") + " — استُخدم المعالج على الجهاز.")
    }

    private func local(_ request: AIRequest, note: String?) async throws -> AIResponse {
        var response = try await LocalAIProvider().generate(request, model: "on-device")
        response.note = note
        usage.record(response)
        return response
    }

    // MARK: Uploads

    /// Uploads a compressed copy of a video (or reuses one uploaded in the last ~46 h).
    func uploadVideo(asset: MediaAsset, url: URL, control: RenderControl?,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> UploadedAIFile {
        guard let key = settings.effectiveKey, settings.useCloud else { throw GeminiError.noKey }
        let registryKey = asset.fingerprint + "-proxy640"
        if let existing = AICacheManager.upload(for: registryKey) { return existing }
        let proxy = try await AIMediaPreparer.proxyVideo(url: url, control: control, progress: { progress($0 * 0.4) })
        defer { try? FileManager.default.removeItem(at: proxy) }
        if control?.isCancelled == true { throw GeminiError.cancelled }
        let bytes = AIMediaPreparer.fileSize(proxy)
        let file = try await GeminiClient(apiKey: key).upload(fileURL: proxy, mimeType: "video/mp4", displayName: asset.displayName,
                                                              progress: { progress(0.4 + $0 * 0.6) })
        usage.recordUpload(bytes: bytes)
        let record = UploadedAIFile(name: file.name, uri: file.uri, mimeType: file.mimeType, uploadedAt: Date())
        AICacheManager.remember(record, for: registryKey)
        return record
    }

    // MARK: Speech (Part 6)

    /// Gemini text-to-speech → WAV data (long texts are spoken in parts and joined).
    func speech(text: String, voice: String) async throws -> Data {
        guard let key = settings.effectiveKey, settings.useCloud else { throw GeminiError.noKey }
        if let blocked = usage.blockReason(limit: settings.dailyLimit) { throw blocked }
        let model = models.ttsModel
        let client = GeminiClient(apiKey: key)
        var pcm = Data()
        var rate = 24_000
        do {
            for part in SpeechSynthesis.chunks(text) {
                try Task.checkCancellation()
                let result = try await client.speech(model: model, text: part, voice: voice)
                pcm.append(result.pcm)
                rate = result.sampleRate
                usage.record(AIResponse(provider: .gemini, model: model, text: "", functionCalls: [], usage: result.usage))
            }
        } catch let error as GeminiError {
            if case .rateLimited(let wait) = error { usage.setCooldown(seconds: wait ?? 30) }
            throw error
        } catch is CancellationError {
            throw GeminiError.cancelled
        }
        return SpeechSynthesis.wav(pcm16: pcm, sampleRate: rate, channels: 1)
    }

    /// Quick key + model check for the settings screen.
    func testConnection() async -> Result<String, Error> {
        guard let key = settings.effectiveKey else { return .failure(GeminiError.noKey) }
        let request = AIRequest(task: .connectionTest, systemInstruction: AIPromptManager.system(for: .connectionTest, language: settings.language),
                                messages: [AIMessage(role: .user, parts: [.text("اختبار")])], responseSchema: nil, temperature: 0)
        do {
            await models.refreshIfStale()
            let response = try await GeminiClient(apiKey: key).generate(model: models.resolvedModel, request: request)
            usage.record(response)
            return .success(models.resolvedModel + " — " + response.text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failure(error)
        }
    }
}
