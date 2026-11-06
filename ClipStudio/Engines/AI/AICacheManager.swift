//
//  AICacheManager.swift
//  ClipStudio — Engines/AI (Part 5)
//
//  • Response cache: identical requests (same task, model, prompt and media) are
//    answered from Caches/AI for 7 days — saves quota and time.
//  • Upload registry: videos already uploaded with the Files API are reused while
//    Google keeps them (≈48 h), keyed by the media fingerprint + proxy settings.
//  Both are plain files; clearing them never loses user data.
//

import Foundation

struct CachedAIResponse: Codable {
    struct Call: Codable {
        var name: String
        var arguments: Data
    }

    var model: String
    var text: String
    var calls: [Call]
    var promptTokens: Int
    var outputTokens: Int
    var date: Date
}

struct UploadedAIFile: Codable, Hashable {
    var name: String
    var uri: String
    var mimeType: String
    var uploadedAt: Date
}

enum AICacheManager {
    static let responseLifetime: Double = 7 * 86_400
    /// Google deletes uploads after 48 h; reuse them a little less than that.
    static let uploadLifetime: Double = 46 * 3_600

    static var directory: URL { StorageManager.shared.cachesDirectory.appendingPathComponent("AI", isDirectory: true) }
    private static var uploadsURL: URL { StorageManager.shared.stateDirectory.appendingPathComponent("ai-uploads.json") }

    // MARK: Responses

    static func response(for key: String) -> AIResponse? {
        let url = directory.appendingPathComponent(key + ".json")
        guard let cached = JSONStore.load(CachedAIResponse.self, from: url) else { return nil }
        guard Date().timeIntervalSince(cached.date) < responseLifetime else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return AIResponse(provider: .gemini, model: cached.model, text: cached.text,
                          functionCalls: cached.calls.map { AIFunctionCall(name: $0.name, arguments: $0.arguments) },
                          usage: AIUsageInfo(promptTokens: cached.promptTokens, outputTokens: cached.outputTokens),
                          fromCache: true)
    }

    static func store(_ response: AIResponse, for key: String) {
        guard response.provider == .gemini, !response.fromCache else { return }
        let cached = CachedAIResponse(model: response.model, text: response.text,
                                      calls: response.functionCalls.map { CachedAIResponse.Call(name: $0.name, arguments: $0.arguments) },
                                      promptTokens: response.usage.promptTokens, outputTokens: response.usage.outputTokens,
                                      date: Date())
        try? JSONStore.save(cached, to: directory.appendingPathComponent(key + ".json"))
    }

    // MARK: Uploads

    static func upload(for key: String) -> UploadedAIFile? {
        let registry = JSONStore.load([String: UploadedAIFile].self, from: uploadsURL) ?? [:]
        guard let file = registry[key], Date().timeIntervalSince(file.uploadedAt) < uploadLifetime else { return nil }
        return file
    }

    static func remember(_ file: UploadedAIFile, for key: String) {
        var registry = JSONStore.load([String: UploadedAIFile].self, from: uploadsURL) ?? [:]
        registry = registry.filter { Date().timeIntervalSince($0.value.uploadedAt) < uploadLifetime }
        registry[key] = file
        try? JSONStore.save(registry, to: uploadsURL)
    }

    static func forgetUpload(_ key: String) {
        var registry = JSONStore.load([String: UploadedAIFile].self, from: uploadsURL) ?? [:]
        registry.removeValue(forKey: key)
        try? JSONStore.save(registry, to: uploadsURL)
    }

    // MARK: Maintenance

    static var sizeInBytes: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: uploadsURL)
    }
}
