//
//  AIModelManager.swift
//  ClipStudio — Engines/AI (Part 5)
//
//  Model IDs change often, so none is hard-wired: the list comes from
//  GET /v1beta/models (only models that support generateContent), is cached, and
//  "automatic" picks the newest stable "flash" model (lite / preview / special
//  purpose models rank lower). A fallback ID is used only before the first list.
//

import Foundation

@MainActor
@Observable
final class AIModelManager {
    static let shared = AIModelManager()
    static let fallbackModel = "gemini-2.5-flash"
    private static let cacheKey = "ai.modelList"
    private static let refreshedKey = "ai.modelListDate"

    private(set) var models: [GeminiModelInfo] = []
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    private(set) var lastError: String?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([GeminiModelInfo].self, from: data) {
            models = cached
        }
        lastRefresh = UserDefaults.standard.object(forKey: Self.refreshedKey) as? Date
    }

    /// The model every request uses.
    var resolvedModel: String {
        let selected = AISettings.shared.selectedModel
        if !selected.isEmpty, models.isEmpty || models.contains(where: { $0.id == selected }) { return selected }
        return Self.bestFlash(models) ?? Self.fallbackModel
    }

    var automaticModel: String { Self.bestFlash(models) ?? Self.fallbackModel }

    /// Text-capable models sorted for the picker (best first).
    var pickerModels: [GeminiModelInfo] {
        models.filter { Self.isTextModel($0.id) }.sorted { Self.score($0.id) > Self.score($1.id) }
    }

    func refresh() async {
        guard let key = AISettings.shared.effectiveKey else {
            lastError = GeminiError.noKey.errorDescription
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let list = try await GeminiClient(apiKey: key).listModels()
            models = list
            lastRefresh = Date()
            lastError = nil
            if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: Self.cacheKey) }
            UserDefaults.standard.set(lastRefresh, forKey: Self.refreshedKey)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Refreshes at most once a day (silently).
    func refreshIfStale() async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 86_400, !models.isEmpty { return }
        guard AISettings.shared.cloudAvailable else { return }
        await refresh()
    }

    // MARK: Ranking (pure)

    nonisolated static func isTextModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        guard lower.hasPrefix("gemini") else { return false }
        let excluded = ["image", "tts", "audio", "live", "embedding", "aqa", "vision", "native", "robotics", "computer-use"]
        return !excluded.contains { lower.contains($0) }
    }

    nonisolated static func version(_ id: String) -> Double {
        let pattern = try? NSRegularExpression(pattern: "gemini-(\\d+(?:\\.\\d+)?)")
        let range = NSRange(id.startIndex..., in: id)
        guard let match = pattern?.firstMatch(in: id, range: range), let r = Range(match.range(at: 1), in: id) else { return 0 }
        return Double(id[r]) ?? 0
    }

    nonisolated static func score(_ id: String) -> Double {
        let lower = id.lowercased()
        var value = version(id) * 100
        if lower.contains("flash") { value += 30 }
        if lower.contains("lite") { value -= 25 }
        if lower.contains("preview") || lower.contains("exp") { value -= 8 }
        if lower.contains("latest") { value += 1 }
        if lower.contains("pro") { value -= 5 }
        // Dated snapshots ("-001", "-0520") rank just below the plain alias.
        if lower.range(of: "-\\d{3,4}$", options: .regularExpression) != nil { value -= 1 }
        return value
    }

    /// Newest "flash" text model in the list.
    nonisolated static func bestFlash(_ models: [GeminiModelInfo]) -> String? {
        models.filter { isTextModel($0.id) && $0.id.lowercased().contains("flash") && $0.supportsGenerate }
            .max { score($0.id) < score($1.id) }?.id
    }
}
