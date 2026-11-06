//
//  CaptionTranslateSheet.swift
//  ClipStudio — Features/AI (Part 6 suggestions)
//
//  Translate the captions into another language: Gemini (caption text only), or
//  Apple's on-device Translation on iOS 18+ when Gemini isn't set up. Review and
//  fix any line, then add the result as a NEW captions track (same timing and
//  style); the original track can be hidden, never deleted.
//

import SwiftUI
#if canImport(Translation)
import Translation
#endif

struct CaptionTranslateSheet: View {
    @Bindable var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("translate.target") private var targetCode = "en"
    @State private var hideOriginal = true
    @State private var useApple = false
    @State private var lines: [String] = []
    @State private var entries: [CaptionEntry] = []
    @State private var progress: Double?
    @State private var error: String?
    @State private var appleJob: AppleTranslationJob?
    @State private var task: Task<Void, Never>?
    @State private var settings = AISettings.shared

    private var target: TranslationTarget { TranslationTarget.target(targetCode) ?? TranslationTarget.all[0] }

    private var appleAvailable: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    private var canTranslate: Bool { settings.cloudAvailable || appleAvailable }

    var body: some View {
        NavigationStack {
            Group {
                if vm.captionEntries.isEmpty {
                    EmptyStateView(systemImage: "captions.bubble", title: "لا توجد ترجمة نصية",
                                   message: "أنشئ الترجمة التلقائية من كلام الفيديو أو استورد ملف SRT أولًا.",
                                   actionTitle: "الترجمة التلقائية") { vm.activeSheet = .captions }
                } else {
                    form
                }
            }
            .screenBackground()
            .navigationTitle("ترجمة إلى لغة أخرى")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { task?.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("أضف المسار") { apply() }
                        .fontWeight(.semibold)
                        .disabled(lines.isEmpty || lines.count != entries.count)
                }
            }
            .appleTranslation(job: $appleJob) { result, failure in
                progress = nil
                if let result {
                    lines = result
                    Haptics.success()
                } else {
                    error = failure ?? "تعذّرت الترجمة على الجهاز."
                }
            }
            .onDisappear { task?.cancel() }
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker("إلى", selection: $targetCode) {
                    ForEach(TranslationTarget.all) { item in
                        Text(item.title).tag(item.code)
                    }
                }
                .onChange(of: targetCode) { _, _ in lines = [] }
                Toggle("إخفاء الترجمة الأصلية", isOn: $hideOriginal)
                if settings.cloudAvailable && appleAvailable {
                    Toggle("ترجمة Apple على الجهاز بدل Gemini", isOn: $useApple)
                }
                Button { translate() } label: {
                    HStack {
                        Label(lines.isEmpty ? "ترجم " + Fmt.int(vm.captionEntries.count) + " سطر" : "ترجم من جديد", systemImage: "character.book.closed")
                        Spacer()
                        if progress != nil { ProgressView() }
                    }
                }
                .disabled(progress != nil || !canTranslate)
                if let progress { ProgressBarView(progress: progress) }
                if let error { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.Palette.warning) }
            } header: {
                Text("اللغة")
            } footer: {
                Text(engineNote)
            }
            if !lines.isEmpty, lines.count == entries.count {
                Section {
                    ForEach(entries.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entries[index].text).font(.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2)
                            TextField("الترجمة", text: Binding(get: { lines[index] }, set: { lines[index] = $0 }), axis: .vertical)
                                .environment(\.layoutDirection, target.isRightToLeft ? .rightToLeft : .leftToRight)
                        }
                    }
                } header: {
                    Text("راجع الترجمة (" + Fmt.int(lines.count) + ")")
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var engineNote: String {
        if settings.cloudAvailable && !useApple { return "يُرسل نص الترجمة فقط إلى Gemini. يُضاف الناتج كمسار ترجمة جديد بنفس التوقيت والشكل." }
        if appleAvailable { return "ترجمة Apple على جهازك (قد يطلب تنزيل اللغة أول مرة). يُضاف الناتج كمسار ترجمة جديد." }
        return "الترجمة تحتاج مفتاح Gemini على هذا الإصدار من iOS (أو iOS 18 للترجمة على الجهاز)."
    }

    private func translate() {
        let current = vm.captionEntries
        entries = current
        let originals = current.map(\.text)
        error = nil
        progress = 0
        if settings.cloudAvailable && !useApple {
            let goal = target
            task = Task {
                do {
                    lines = try await CaptionTranslator.translateWithGemini(originals, target: goal) { progress = $0 }
                    Haptics.success()
                } catch {
                    if !(error is CancellationError) {
                        self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
                progress = nil
            }
        } else if appleAvailable {
            let source = String(vm.transcriptLocaleID.prefix(2))
            appleJob = AppleTranslationJob(lines: originals, source: source == target.code ? nil : source, target: target.code)
        } else {
            progress = nil
        }
    }

    private func apply() {
        vm.addTranslatedCaptions(entries: entries, texts: lines, target: target, hideOriginal: hideOriginal)
        dismiss()
    }
}

// MARK: - Apple Translation (iOS 18+)

struct AppleTranslationJob: Identifiable, Equatable {
    let id = UUID()
    let lines: [String]
    let source: String?
    let target: String
}

extension View {
    /// Runs `job` with Apple's on-device Translation when available (iOS 18+).
    @ViewBuilder
    func appleTranslation(job: Binding<AppleTranslationJob?>, onDone: @escaping ([String]?, String?) -> Void) -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            modifier(AppleTranslationRunner(job: job, onDone: onDone))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
private struct AppleTranslationRunner: ViewModifier {
    @Binding var job: AppleTranslationJob?
    let onDone: ([String]?, String?) -> Void
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                guard let current = job else { return }
                do {
                    let requests = current.lines.enumerated().map {
                        TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
                    }
                    let responses = try await session.translations(from: requests)
                    var output = current.lines
                    for response in responses {
                        if let id = response.clientIdentifier, let index = Int(id), index < output.count {
                            output[index] = response.targetText
                        }
                    }
                    onDone(output, nil)
                } catch {
                    onDone(nil, error.localizedDescription)
                }
                job = nil
            }
            .onChange(of: job) { _, newJob in
                guard let newJob else { return }
                let source = newJob.source.map { Locale.Language(identifier: $0) }
                let target = Locale.Language(identifier: newJob.target)
                if let existing = configuration, existing.source == source, existing.target == target {
                    configuration?.invalidate()
                } else {
                    configuration = TranslationSession.Configuration(source: source, target: target)
                }
            }
    }
}
#endif
