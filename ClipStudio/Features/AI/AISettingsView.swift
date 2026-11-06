//
//  AISettingsView.swift
//  ClipStudio — Features/AI (Part 5)
//
//  Settings → AI: the Gemini API key (Keychain, paste + test), model picker
//  filled from the live model list (automatic = newest flash), privacy switches
//  (ask before any upload, on-device fallback), language, daily limit, usage of
//  the last 7 days and the response cache.
//

import SwiftUI

struct AISettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var settings = AISettings.shared
    @State private var models = AIModelManager.shared
    @State private var usage = AIUsageManager.shared
    @State private var keyDraft = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testFailed = false
    @State private var confirmRemoveKey = false
    @State private var cacheSize: Int64 = 0

    var body: some View {
        Form {
            keySection
            modelSection
            privacySection
            usageSection
            Section {
                Button("إعادة الإعدادات الافتراضية", role: .destructive) { settings.resetPreferences() }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("الذكاء الاصطناعي")
        .keyboardDoneToolbar()
        .task {
            cacheSize = AICacheManager.sizeInBytes
            await models.refreshIfStale()
        }
        .confirmationDialog("حذف مفتاحك؟", isPresented: $confirmRemoveKey, titleVisibility: .visible) {
            Button("حذف المفتاح", role: .destructive) {
                settings.removeKey()
                testResult = nil
            }
        } message: {
            Text("يُحذف من سلسلة المفاتيح في جهازك. الأدوات تعمل بعدها على الجهاز فقط (أو بالمفتاح الافتراضي إن وُجد).")
        }
    }

    // MARK: Key

    private var keySection: some View {
        Section {
            HStack {
                Label("المصدر", systemImage: "key")
                Spacer()
                StatusPill(text: settings.keySource.title,
                           color: settings.keySource == .none ? Theme.Palette.textTertiary : Theme.Palette.success)
            }
            if settings.keySource != .none {
                LabeledContent("المفتاح", value: settings.maskedKey)
            }
            SecureField("الصق مفتاح Gemini هنا", text: $keyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
            HStack {
                Button {
                    if let text = UIPasteboard.general.string { keyDraft = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                } label: { Label("لصق", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.bordered)
                Spacer()
                Button {
                    if settings.saveKey(keyDraft) {
                        keyDraft = ""
                        Haptics.success()
                        env.toasts.show("حُفظ المفتاح في سلسلة المفاتيح", style: .success)
                        Task { await models.refresh(); await test() }
                    } else {
                        env.toasts.show("تعذر حفظ المفتاح.", style: .error)
                    }
                } label: { Label("حفظ", systemImage: "checkmark") }
                    .buttonStyle(.borderedProminent)
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 20)
            }
            Button {
                Task { await test() }
            } label: {
                HStack {
                    Label("اختبار الاتصال", systemImage: "bolt.horizontal")
                    Spacer()
                    if testing { ProgressView() }
                }
            }
            .disabled(testing || settings.keySource == .none)
            if let testResult {
                Label(testResult, systemImage: testFailed ? "xmark.octagon" : "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(testFailed ? Theme.Palette.danger : Theme.Palette.success)
            }
            if settings.hasUserKey {
                Button("حذف مفتاحك", role: .destructive) { confirmRemoveKey = true }
            }
        } header: {
            Text("مفتاح Google Gemini")
        } footer: {
            Text("احصل على مفتاح مجاني من Google AI Studio ← Get API key. يُحفظ في سلسلة المفاتيح على جهازك فقط، ولا يدخل النسخ الاحتياطية ولا يُرسل إلا إلى Google.")
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        switch await AIRequestRouter.shared.testConnection() {
        case .success(let text):
            testFailed = false
            testResult = "يعمل: " + text
        case .failure(let error):
            testFailed = true
            testResult = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Model

    private var modelSection: some View {
        Section {
            Picker("النموذج", selection: $settings.selectedModel) {
                Text("تلقائي (" + models.automaticModel + ")").tag("")
                ForEach(models.pickerModels) { model in
                    Text(model.displayName + " — " + model.id).tag(model.id)
                }
            }
            HStack {
                Button {
                    Task { await models.refresh() }
                } label: {
                    Label("تحديث قائمة النماذج", systemImage: "arrow.clockwise")
                }
                .disabled(models.isRefreshing || settings.keySource == .none)
                Spacer()
                if models.isRefreshing { ProgressView() }
            }
            if let date = models.lastRefresh {
                LabeledContent("آخر تحديث", value: Fmt.relative(date))
            }
            if let error = models.lastError {
                Text(error).font(.caption).foregroundStyle(Theme.Palette.warning)
            }
            Picker("لغة النتائج", selection: $settings.language) {
                ForEach(AIResponseLanguage.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("النموذج")
        } footer: {
            Text("أسماء النماذج تتغير باستمرار، لذلك تُجلب القائمة من Google. «تلقائي» يختار أحدث نموذج flash سريع ومجاني.")
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            Toggle(isOn: $settings.useCloud) { Label("استخدام Gemini عند توفر مفتاح", systemImage: "cloud") }
            Toggle(isOn: $settings.askBeforeUpload) { Label("اسألني قبل إرسال أي وسائط", systemImage: "hand.raised") }
            Toggle(isOn: $settings.localFallback) { Label("استخدم المعالج على الجهاز عند تعذّر Gemini", systemImage: "iphone") }
            Toggle(isOn: $settings.deepVideoAnalysis) { Label("تحليل الفيديو كاملًا لأفضل اللقطات (رفع نسخة مضغوطة)", systemImage: "film") }
            Toggle(isOn: $settings.cacheResponses) { Label("حفظ النتائج لتوفير الطلبات", systemImage: "tray.full") }
        } header: {
            Text("الخصوصية والسلوك")
        } footer: {
            Text("بدون Gemini: القصة المصورة وأفضل اللقطات والمحتوى والمساعد وتنظيف الكلام تعمل على جهازك بنتائج أبسط. مع Gemini تُرسل صور مصغرة أو نسخة مضغوطة فقط — والأصل لا يُرفع أبدًا.")
        }
    }

    // MARK: Usage

    private var usageSection: some View {
        Section {
            let today = usage.today
            LabeledContent("طلبات اليوم", value: Fmt.int(today.requests) + " / " + Fmt.int(settings.dailyLimit))
            LabeledContent("الرموز اليوم", value: Fmt.int(today.promptTokens + today.outputTokens))
            LabeledContent("من الذاكرة المؤقتة", value: Fmt.int(today.cachedHits))
            LabeledContent("على الجهاز", value: Fmt.int(today.localRequests))
            if today.uploads > 0 {
                LabeledContent("رفع اليوم", value: Fmt.int(today.uploads) + " • " + Fmt.bytes(today.uploadBytes))
            }
            if usage.cooldownRemaining > 0 {
                Label("انتظار بسبب حد الطلبات: " + Fmt.int(Int(usage.cooldownRemaining.rounded(.up))) + " ث", systemImage: "hourglass")
                    .foregroundStyle(Theme.Palette.warning)
            }
            Stepper(value: $settings.dailyLimit, in: 0...2000, step: 25) {
                LabeledContent("الحد اليومي", value: settings.dailyLimit == 0 ? "بدون حد" : Fmt.int(settings.dailyLimit))
            }
            LabeledContent("حجم الذاكرة المؤقتة", value: Fmt.bytes(cacheSize))
            Button("مسح الذاكرة المؤقتة") {
                AICacheManager.clear()
                cacheSize = 0
                env.toasts.show("تم المسح", style: .success)
            }
            Button("تصفير الإحصاءات", role: .destructive) { usage.reset() }
        } header: {
            Text("الاستخدام")
        } footer: {
            Text("الحد اليومي يحميك من استهلاك الحصة المجانية. عند رسالة «تجاوزت الحد» ينتظر التطبيق المدة التي تطلبها Google تلقائيًا.")
        }
    }
}

// MARK: - Upload consent

/// What a pending AI action will send (for the consent dialog).
struct AIConsentRequest: Identifiable {
    let id = UUID()
    var summary: String
    var proceed: () -> Void
    var useLocal: () -> Void
}

struct AIConsentModifier: ViewModifier {
    @Binding var request: AIConsentRequest?

    func body(content: Content) -> some View {
        content.confirmationDialog("إرسال إلى Gemini؟",
                                   isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                                   titleVisibility: .visible, presenting: request) { pending in
            Button("متابعة") { pending.proceed() }
            Button("استخدم المعالج على الجهاز بدلًا") { pending.useLocal() }
            Button("إلغاء", role: .cancel) {}
        } message: { pending in
            Text(pending.summary)
        }
    }
}

extension View {
    func aiConsent(_ request: Binding<AIConsentRequest?>) -> some View {
        modifier(AIConsentModifier(request: request))
    }
}

/// Shows which provider will answer.
struct AIProviderBadge: View {
    let task: AITask

    var body: some View {
        let kind = AIRequestRouter.shared.provider(for: task)
        StatusPill(text: kind == .gemini ? "Gemini • " + AIModelManager.shared.resolvedModel : "على الجهاز",
                   color: kind == .gemini ? Theme.Palette.accent : Theme.Palette.textSecondary,
                   systemImage: kind == .gemini ? "sparkles" : "iphone")
    }
}

/// Runs `action` after consent when cloud AI will receive media; directly otherwise.
@MainActor
func withAIConsent(task: AITask, sendsMedia: Bool, summary: @autoclosure () -> String,
                   present: (AIConsentRequest) -> Void, action: @escaping (_ forceLocal: Bool) -> Void) {
    let cloud = AIRequestRouter.shared.provider(for: task) == .gemini
    guard cloud, sendsMedia, AISettings.shared.askBeforeUpload else {
        action(false)
        return
    }
    present(AIConsentRequest(summary: summary(), proceed: { action(false) }, useLocal: { action(true) }))
}
