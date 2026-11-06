//
//  AudioSeparationSheet.swift
//  ClipStudio — Features/Intelligence (Part 4)
//
//  Splits a clip's sound into "voice" and "background" stems on device and places
//  them on new audio tracks (the original sound is muted, never deleted).
//  VoiceSeparationModelView (Settings) imports an optional Core ML mask model.
//

import SwiftUI
import UniformTypeIdentifiers

struct AudioSeparationSheet: View {
    @Bindable var vm: StudioViewModel
    let clipID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var method: SeparationMethod = .automatic
    @State private var duckBackground = true

    private var clip: Clip? { TimelineEngine.clip(clipID, in: vm.timeline) }

    private var methods: [SeparationMethod] {
        VoiceSeparationModelStore.isInstalled ? SeparationMethod.allCases : SeparationMethod.allCases.filter { $0 != .coreML }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let clip {
                    Section {
                        LabeledContent("المقطع", value: clip.name)
                        LabeledContent("المدة", value: Fmt.durationPrecise(clip.duration.seconds))
                    }
                    Section {
                        Picker("الطريقة", selection: $method) {
                            ForEach(methods) { option in Text(option.title).tag(option) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        Text(method.detail)
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    } header: {
                        Text("طريقة الفصل")
                    } footer: {
                        if !VoiceSeparationModelStore.isInstalled {
                            Text("لنتيجة أدق في الأغاني المعقدة: استورد نموذج فصل Core ML من الإعدادات ← الذكاء على الجهاز.")
                        }
                    }
                    Section {
                        Toggle("خفّض الخلفية والموسيقى تحت الكلام تلقائيًا", isOn: $duckBackground)
                    } footer: {
                        Text("يضيف منحنى صوت للخلفية ومسارات الموسيقى ينخفض كلما تكلّم أحد — قابل للتعديل من «خفض الموسيقى».")
                    }
                    Section {
                        Label("ينتج ملفين في المكتبة: «الكلام» و«الخلفية»، ويوضعان على مسارات صوت جديدة بنفس التوقيت.", systemImage: "square.split.1x2")
                        Label("صوت المقطع الأصلي يُكتم فقط ويبقى كما هو.", systemImage: "speaker.slash")
                        Label("الكلام + الخلفية = الصوت الأصلي تمامًا، فلا يضيع شيء.", systemImage: "equal.circle")
                        Label("كل المعالجة على جهازك.", systemImage: "lock.shield")
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    Section {
                        EmptyStateView(systemImage: "waveform.slash", title: "المقطع غير موجود", message: "اختر مقطعًا فيه صوت.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("فصل الكلام عن الخلفية")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("فصل") {
                        vm.separateAudio(clipID: clipID, method: method, duckBackground: duckBackground)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(clip == nil)
                }
            }
        }
    }
}

// MARK: - Optional Core ML model (Settings)

struct VoiceSeparationModelView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var installed = VoiceSeparationModelStore.isInstalled
    @State private var showImporter = false
    @State private var working = false
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Label("نموذج فصل الصوت", systemImage: "cpu")
                    Spacer()
                    StatusPill(text: installed ? "مثبّت" : "غير مثبّت",
                               color: installed ? Theme.Palette.success : Theme.Palette.textTertiary)
                }
                Text("الفصل يعمل بدون نموذج (فصل المنتصف للستيريو، وعزل الكلام عن الضوضاء للأحادي). النموذج اختياري ويعطي نتيجة أدق للأغاني.")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Section {
                Button {
                    showImporter = true
                } label: {
                    HStack {
                        Label(installed ? "استبدال النموذج" : "استيراد نموذج (.mlmodel / .mlpackage)", systemImage: "square.and.arrow.down")
                        Spacer()
                        if working { ProgressView() }
                    }
                }
                .disabled(working)
                if installed {
                    Button(role: .destructive) { confirmRemove = true } label: { Label("حذف النموذج", systemImage: "trash") }
                }
            } footer: {
                Text("شروط التوافق: مدخل باسم «magnitude» بشكل [1, 1025, T] (طيف STFT بحجم 2048 وقفزة 512 على 44.1 kHz)، ومخرج باسم «mask» بنفس الشكل وقيم من 0 إلى 1 تمثل الكلام. يُتحقق من الشكل عند الاستيراد.")
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("الذكاء على الجهاز")
        .fileImporter(isPresented: $showImporter, allowedContentTypes: modelTypes) { result in
            guard case .success(let url) = result else { return }
            install(url)
        }
        .confirmationDialog("حذف نموذج الفصل؟", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("حذف", role: .destructive) {
                VoiceSeparationModelStore.remove()
                installed = VoiceSeparationModelStore.isInstalled
            }
        }
    }

    private var modelTypes: [UTType] {
        var types: [UTType] = []
        if let model = UTType(filenameExtension: "mlmodel") { types.append(model) }
        if let package = UTType(filenameExtension: "mlpackage") { types.append(package) }
        types.append(.package)
        types.append(.data)
        return types
    }

    private func install(_ url: URL) {
        working = true
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                // Copy first: compiling straight from a security-scoped location can fail.
                let staged = StorageManager.shared.stagingDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: staged)
                try FileManager.default.copyItem(at: url, to: staged)
                defer { try? FileManager.default.removeItem(at: staged) }
                try await VoiceSeparationModelStore.install(from: staged)
                Haptics.success()
                env.toasts.show("تم تثبيت النموذج والتحقق منه", style: .success)
            } catch {
                env.toasts.show((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, style: .error)
            }
            installed = VoiceSeparationModelStore.isInstalled
            working = false
        }
    }
}
