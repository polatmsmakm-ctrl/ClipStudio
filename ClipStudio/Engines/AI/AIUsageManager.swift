//
//  AIUsageManager.swift
//  ClipStudio — Engines/AI (Part 5)
//
//  Counts AI requests, tokens and uploads per day (State/ai-usage.json), enforces
//  the user's soft daily limit and the cool-down Gemini asks for after a 429, so
//  the free tier isn't hammered with retries.
//

import Foundation

struct AIDayUsage: Codable, Hashable {
    var requests = 0
    var cachedHits = 0
    var localRequests = 0
    var promptTokens = 0
    var outputTokens = 0
    var uploads = 0
    var uploadBytes: Int64 = 0
}

struct AIUsageFile: Codable {
    var days: [String: AIDayUsage] = [:]
    var cooldownUntil: Date?
}

@MainActor
@Observable
final class AIUsageManager {
    static let shared = AIUsageManager()
    private var file: AIUsageFile
    private static var url: URL { StorageManager.shared.stateDirectory.appendingPathComponent("ai-usage.json") }

    private init() {
        file = JSONStore.load(AIUsageFile.self, from: Self.url) ?? AIUsageFile()
        prune()
    }

    nonisolated static func dayKey(_ date: Date = Date()) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    var today: AIDayUsage { file.days[Self.dayKey()] ?? AIDayUsage() }

    var lastSevenDays: [(day: String, usage: AIDayUsage)] {
        (0..<7).map { offset -> (day: String, usage: AIDayUsage) in
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let key = Self.dayKey(date)
            return (day: key, usage: file.days[key] ?? AIDayUsage())
        }
    }

    /// Seconds left in a rate-limit cool-down (0 = none).
    var cooldownRemaining: Double {
        guard let until = file.cooldownUntil else { return 0 }
        return max(0, until.timeIntervalSinceNow)
    }

    /// Why a cloud request can't be sent now (nil = OK).
    func blockReason(limit: Int) -> GeminiError? {
        if cooldownRemaining > 0 { return .rateLimited(retryAfter: cooldownRemaining) }
        if limit > 0, today.requests >= limit { return .quotaExceeded }
        return nil
    }

    func record(_ response: AIResponse) {
        update { day in
            if response.fromCache {
                day.cachedHits += 1
            } else if response.provider == .local {
                day.localRequests += 1
            } else {
                day.requests += 1
                day.promptTokens += response.usage.promptTokens
                day.outputTokens += response.usage.outputTokens
            }
        }
    }

    func recordUpload(bytes: Int64) {
        update { day in
            day.uploads += 1
            day.uploadBytes += bytes
        }
    }

    func setCooldown(seconds: Double) {
        file.cooldownUntil = Date().addingTimeInterval(min(600, max(5, seconds)))
        save()
    }

    func reset() {
        file = AIUsageFile()
        save()
    }

    private func update(_ change: (inout AIDayUsage) -> Void) {
        let key = Self.dayKey()
        var day = file.days[key] ?? AIDayUsage()
        change(&day)
        file.days[key] = day
        save()
    }

    private func prune() {
        let keep = Set((0..<30).map { Self.dayKey(Calendar.current.date(byAdding: .day, value: -$0, to: Date()) ?? Date()) })
        file.days = file.days.filter { keep.contains($0.key) }
    }

    private func save() {
        try? JSONStore.save(file, to: Self.url)
    }
}
