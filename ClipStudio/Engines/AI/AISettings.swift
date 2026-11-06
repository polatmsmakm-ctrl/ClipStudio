//
//  AISettings.swift
//  ClipStudio — Engines/AI (Part 5)
//
//  User choices for the AI layer. The Gemini key lives in the Keychain (never in
//  UserDefaults, files or backups). An optional default key can be injected at
//  build time from the GEMINI_API_KEY repository secret (BuildSecrets); a key the
//  user enters always wins. Without any key every AI tool still works with the
//  on-device provider.
//

import Foundation

enum AIKeySource: Hashable {
    case user, build, none

    var title: String {
        switch self {
        case .user: "مفتاحك"
        case .build: "مفتاح افتراضي من البناء"
        case .none: "لا يوجد مفتاح"
        }
    }
}

enum AIResponseLanguage: String, CaseIterable, Identifiable, Hashable {
    case arabic = "ar", english = "en"

    var id: String { rawValue }
    var title: String { self == .arabic ? "العربية" : "English" }
    var instruction: String {
        self == .arabic ? "اكتب كل النصوص الموجهة للمستخدم بالعربية الفصحى المبسطة." : "Write every user-facing text in English."
    }
}

@MainActor
@Observable
final class AISettings {
    static let shared = AISettings()
    private static let keyAccount = "gemini.apiKey"
    private let defaults = UserDefaults.standard

    enum Keys {
        static let useCloud = "ai.useCloud"
        static let askBeforeUpload = "ai.askBeforeUpload"
        static let model = "ai.model"
        static let cache = "ai.cacheResponses"
        static let language = "ai.language"
        static let dailyLimit = "ai.dailyLimit"
        static let fallback = "ai.localFallback"
        static let deepVideo = "ai.deepVideo"
    }

    /// Use Gemini when a key exists (off = everything on device).
    var useCloud: Bool { didSet { defaults.set(useCloud, forKey: Keys.useCloud) } }
    /// Show exactly what will be uploaded and ask every time media leaves the device.
    var askBeforeUpload: Bool { didSet { defaults.set(askBeforeUpload, forKey: Keys.askBeforeUpload) } }
    /// "" = automatic (newest flash model).
    var selectedModel: String { didSet { defaults.set(selectedModel, forKey: Keys.model) } }
    var cacheResponses: Bool { didSet { defaults.set(cacheResponses, forKey: Keys.cache) } }
    var language: AIResponseLanguage { didSet { defaults.set(language.rawValue, forKey: Keys.language) } }
    /// Soft daily request limit (protects the free tier).
    var dailyLimit: Int { didSet { defaults.set(dailyLimit, forKey: Keys.dailyLimit) } }
    /// When Gemini fails (offline, limits), use the on-device provider automatically.
    var localFallback: Bool { didSet { defaults.set(localFallback, forKey: Keys.fallback) } }
    /// Upload a compressed copy of the whole video for highlights (more accurate, uses more quota).
    var deepVideoAnalysis: Bool { didSet { defaults.set(deepVideoAnalysis, forKey: Keys.deepVideo) } }

    private(set) var hasUserKey: Bool

    private init() {
        let d = UserDefaults.standard
        useCloud = d.object(forKey: Keys.useCloud) as? Bool ?? true
        askBeforeUpload = d.object(forKey: Keys.askBeforeUpload) as? Bool ?? true
        selectedModel = d.string(forKey: Keys.model) ?? ""
        cacheResponses = d.object(forKey: Keys.cache) as? Bool ?? true
        language = AIResponseLanguage(rawValue: d.string(forKey: Keys.language) ?? "") ?? .arabic
        dailyLimit = d.object(forKey: Keys.dailyLimit) as? Int ?? 200
        localFallback = d.object(forKey: Keys.fallback) as? Bool ?? true
        deepVideoAnalysis = d.object(forKey: Keys.deepVideo) as? Bool ?? false
        hasUserKey = !(KeychainStore.read(Self.keyAccount) ?? "").isEmpty
    }

    var keySource: AIKeySource {
        if hasUserKey { return .user }
        if !BuildSecrets.geminiDefaultKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .build }
        return .none
    }

    /// The key to use (user key first, then the build-time default).
    var effectiveKey: String? {
        if let user = KeychainStore.read(Self.keyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty {
            return user
        }
        let build = BuildSecrets.geminiDefaultKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return build.isEmpty ? nil : build
    }

    /// Whether cloud AI can be used right now.
    var cloudAvailable: Bool { useCloud && effectiveKey != nil }

    /// Last 4 characters, for display only.
    var maskedKey: String {
        guard let key = effectiveKey, key.count > 4 else { return "—" }
        return "••••" + String(key.suffix(4))
    }

    func saveKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let saved = KeychainStore.write(trimmed, account: Self.keyAccount)
        hasUserKey = saved
        return saved
    }

    func removeKey() {
        KeychainStore.delete(Self.keyAccount)
        hasUserKey = false
    }

    func resetPreferences() {
        useCloud = true
        askBeforeUpload = true
        selectedModel = ""
        cacheResponses = true
        language = .arabic
        dailyLimit = 200
        localFallback = true
        deepVideoAnalysis = false
    }
}
