//
//  CaptionsSheet.swift
//  ClipStudio — Features/Captions (Part 3)
//
//  Dynamic captions in four tabs:
//  • Create — language, source tracks, privacy (on-device vs Apple servers),
//    layout (characters per line, lines, duration), style; transcribes and builds.
//  • Edit — every caption: text, jump, split before a word, merge, delete, sync offset.
//  • Style — caption looks with live previews (word highlight, karaoke, box…).
//  • Files — SRT / WebVTT import and export.
//

import SwiftUI
import UniformTypeIdentifiers

enum CaptionsTab: String, CaseIterable, Identifiable {
    case create, edit, style, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .create: "إنشاء"
        case .edit: "تعديل"
        case .style: "النمط"
        case .files: "ملفات"
        }
    }
}

struct CaptionsSheet: View {
    let vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var tab: CaptionsTab = .create
    @AppStorage("captions.locale") private var localeID = "ar-SA"
    @AppStorage("captions.allowServer") private var allowServer = false
    @AppStorage("captions.lastStyle") private var styleID = "bold"
    @State private var sources: Set<UUID> = []
    @State private var layout = CaptionLayoutOptions()
    @State private var onlyInOut = false
    @State private var replaceExisting = true
    @State private var resetPositions = false
    @State private var showImporter = false
    @State private var exportedURL: URL?
    @State private var loaded = false

    private var preset: CaptionStylePreset { CaptionStylePreset.preset(styleID) }
    private var onDevice: Bool { TranscriptionService.supportsOnDevice(localeID) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("القسم", selection: $tab) {
                    ForEach(CaptionsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()
                switch tab {
                case .create: createTab
                case .edit: CaptionCueList(vm: vm)
                case .style: styleTab
                case .files: filesTab
                }
            }
            .navigationTitle("الترجمة التلقائية")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() }.fontWeight(.semibold) }
            }
            .screenBackground()
            .keyboardDoneToolbar()
            .onAppear {
                guard !loaded else { return }
                loaded = true
                sources = vm.defaultCaptionSources()
                layout = CaptionLayoutOptions.defaults(for: vm.settings)
                if !vm.captionEntries.isEmpty { tab = .edit }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.subtitleTypes) { result in
                if case .success(let url) = result { vm.importSubtitles(from: url, preset: preset) }
            }
        }
    }

    static var subtitleTypes: [UTType] {
        [UTType(filenameExtension: "srt"), UTType(filenameExtension: "vtt"), .plainText].compactMap { $0 }
    }

    // MARK: Create

    private var createTab: some View {
        Form {
            Section {
                Picker("لغة الكلام", selection: $localeID) {
                    ForEach(TranscriptionLanguage.available) { Text($0.title).tag($0.id) }
                }
                if onDevice {
                    Label("يتم التعرّف على الكلام على جهازك فقط.", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.success)
                } else {
                    Toggle("السماح بإرسال الصوت إلى خوادم Apple", isOn: $allowServer).tint(Theme.Palette.accent)
                    Text("هذه اللغة غير متاحة على جهازك. عند التفعيل يُرسل صوت المقاطع المختارة إلى Apple لتحويله لنص (حسب سياسة خصوصية Apple). لا يُرسل الفيديو، ولا يُرسل شيء بدون موافقتك.")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.warning)
                }
            } header: {
                Text("اللغة والخصوصية")
            }
            Section {
                ForEach(vm.captionSourceTracks) { pair in
                    Toggle(isOn: Binding(get: { sources.contains(pair.track.id) },
                                         set: { on in if on { sources.insert(pair.track.id) } else { sources.remove(pair.track.id) } })) {
                        Label(pair.track.name, systemImage: pair.track.kind.symbol)
                    }
                    .tint(Theme.Palette.accent)
                }
                if vm.captionSourceTracks.isEmpty {
                    Text("لا توجد مقاطع فيها صوت.").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
                let pending = vm.untranscribedSeconds(localeID: localeID, sourceTrackIDs: sources)
                Text(pending > 0.5 ? "يحتاج تفريغ " + Fmt.durationPrecise(pending) + " من الصوت (يُحفظ ولا يتكرر)."
                                   : "الصوت مفرّغ مسبقًا — الإنشاء فوري.")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            } header: {
                Text("مصدر الكلام")
            }
            Section("التقسيم") {
                if vm.inOutRange != nil {
                    Toggle("من نقطة البداية إلى النهاية فقط", isOn: $onlyInOut).tint(Theme.Palette.accent)
                }
                Stepper("أحرف السطر: " + Fmt.int(layout.maxCharsPerLine), value: $layout.maxCharsPerLine, in: 10...60, step: 2)
                Picker("الأسطر", selection: $layout.maxLines) {
                    Text("سطر واحد").tag(1)
                    Text("سطران").tag(2)
                }
                .pickerStyle(.segmented)
                PrecisionSlider(title: "أطول مدة للترجمة", value: $layout.maxDuration, range: 1...8, defaultValue: 4, step: 0.1,
                                format: { Fmt.seconds($0, digits: 1) })
                PrecisionSlider(title: "وقفة تبدأ ترجمة جديدة", value: $layout.pauseBreak, range: 0.2...2, defaultValue: 0.6, step: 0.05,
                                format: { Fmt.seconds($0, digits: 2) })
                Toggle("استبدال الترجمة الحالية", isOn: $replaceExisting).tint(Theme.Palette.accent)
            }
            Section("النمط") {
                Picker("النمط", selection: $styleID) {
                    ForEach(CaptionStylePreset.all) { Text($0.title).tag($0.id) }
                }
                CaptionStylePreview(preset: preset, aspect: vm.canvasSize)
                    .frame(height: 110)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                Button {
                    vm.generateCaptions(CaptionGenerationOptions(localeID: localeID, allowServer: allowServer, sourceTrackIDs: sources,
                                                                 preset: preset, layout: layout, onlyInOut: onlyInOut,
                                                                 replaceExisting: replaceExisting))
                    dismiss()
                } label: {
                    Label("إنشاء الترجمة", systemImage: "captions.bubble.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)
                .foregroundStyle(Color(hex: 0x1A1408))
                .disabled(sources.isEmpty || (!onDevice && !allowServer))
            }
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Style

    private var styleTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("إعادة موضع الترجمة حسب النمط", isOn: $resetPositions).tint(Theme.Palette.accent)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(CaptionStylePreset.all) { item in
                        Button {
                            styleID = item.id
                            vm.restyleCaptions(item, resetPosition: resetPositions)
                        } label: {
                            VStack(spacing: 6) {
                                CaptionStylePreview(preset: item, aspect: vm.canvasSize)
                                    .frame(height: 96)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12)
                                        .stroke(item.id == styleID ? Theme.Palette.accent : .clear, lineWidth: 2))
                                Text(item.title + " • " + item.highlight.title).font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.Palette.textPrimary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                ColorPicker("لون التمييز لكل الترجمة", selection: Binding(get: { preset.highlightColor.color },
                                                                          set: { vm.setCaptionHighlightColor(RGBAColor($0)) }))
                Text("لتعديل خط ترجمة واحدة أو حجمها: اختر مقطعها في الخط الزمني وافتح تبويب «النص».")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding()
        }
    }

    // MARK: Files

    private var filesTab: some View {
        Form {
            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("استيراد ملف SRT أو VTT", systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text("تُضاف في مسار ترجمة جديد بنمط «" + preset.title + "».")
            }
            Section("تصدير") {
                ForEach(SubtitleFormat.allCases) { format in
                    Button {
                        exportedURL = vm.exportSubtitles(format: format)
                    } label: {
                        Label("حفظ " + format.title, systemImage: "doc.text")
                    }
                }
                if let exportedURL {
                    ShareLink(item: exportedURL) {
                        Label("مشاركة " + exportedURL.lastPathComponent, systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section {
                Text("الترجمة على الخط الزمني تُدمج في الفيديو عند التصدير. ملف SRT مفيد لرفعه كترجمة منفصلة في يوتيوب وغيره.")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Style preview

/// Renders a sample caption with the real renderer (second word highlighted).
struct CaptionStylePreview: View {
    let preset: CaptionStylePreset
    let aspect: CGSize

    private var image: UIImage? {
        let words = ["هذا", "مثال", "للترجمة", "التلقائية"].enumerated().map { index, text in
            CaptionWord(text: text, start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.35)
        }
        var info = CaptionInfo(words: words)
        info.highlight = preset.highlight
        info.highlightColor = preset.highlightColor
        info.boxColor = preset.boxColor
        var content = TextContent(text: info.composedText, style: preset.style, animationIn: .none, animationOut: .none)
        content.caption = info
        let landscape = aspect.width >= aspect.height
        let canvas = landscape ? CGSize(width: 640, height: 360) : CGSize(width: 360, height: 640)
        guard let rendered = GeneratedContentRenderer.shared.image(for: .text(content), canvas: canvas, localTime: 0.5, clipDuration: 2)
        else { return nil }
        return FramePreviewRenderer.shared.uiImage(rendered)
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x3A4152), Color(hex: 0x1B1D24)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Image(uiImage: image).resizable().scaledToFit().padding(10)
            }
        }
    }
}

// MARK: - Caption list editor

struct CaptionCueList: View {
    let vm: StudioViewModel
    @State private var drafts: [UUID: String] = [:]

    var body: some View {
        let entries = vm.captionEntries
        List {
            if entries.isEmpty {
                EmptyStateView(systemImage: "captions.bubble", title: "لا توجد ترجمة",
                               message: "أنشئ الترجمة من تبويب «إنشاء» أو استورد ملف SRT.")
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    HStack {
                        Text("مزامنة كل الترجمة").font(.subheadline)
                        Spacer()
                        Button("−0.1 ث") { vm.shiftCaptions(by: -0.1) }.buttonStyle(.bordered)
                        Button("+0.1 ث") { vm.shiftCaptions(by: 0.1) }.buttonStyle(.bordered)
                    }
                    .tint(Theme.Palette.accent)
                }
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button {
                            vm.seek(to: entry.clip.start.seconds + 0.01)
                            vm.select(entry.clip.id)
                        } label: {
                            Text(Fmt.timecode(entry.clip.start.seconds, fps: vm.frameRate) + " ← " + Fmt.durationPrecise(entry.clip.duration.seconds))
                                .font(Theme.Typo.mono)
                                .foregroundStyle(isCurrent(entry) ? Theme.Palette.accent : Theme.Palette.textSecondary)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Menu {
                            if let words = entry.caption?.words, words.count > 1 {
                                Menu("تقسيم قبل كلمة") {
                                    ForEach(Array(words.enumerated()).dropFirst(), id: \.offset) { index, word in
                                        Button("قبل «" + word.text + "»") { vm.splitCaption(entry.clip.id, beforeWord: index) }
                                    }
                                }
                            }
                            Button { vm.mergeCaptionWithNext(entry.clip.id) } label: { Label("دمج مع التالية", systemImage: "arrow.merge") }
                            Button(role: .destructive) { vm.deleteCaption(entry.clip.id) } label: { Label("حذف", systemImage: "trash") }
                        } label: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    TextField("نص الترجمة", text: Binding(get: { drafts[entry.id] ?? entry.text },
                                                         set: { drafts[entry.id] = $0 }), axis: .vertical)
                        .lineLimit(1...4)
                        .onSubmit { commit(entry) }
                        .submitLabel(.done)
                    if let draft = drafts[entry.id], draft != entry.text {
                        Button("حفظ التعديل") { commit(entry) }
                            .font(.caption.weight(.semibold))
                            .tint(Theme.Palette.accent)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func isCurrent(_ entry: CaptionEntry) -> Bool {
        vm.currentTime >= entry.clip.start.seconds && vm.currentTime < entry.clip.end.seconds
    }

    private func commit(_ entry: CaptionEntry) {
        guard let draft = drafts[entry.id] else { return }
        vm.updateCaptionText(entry.clip.id, text: draft)
        vm.endContinuousEdit()
        drafts[entry.id] = nil
    }
}
