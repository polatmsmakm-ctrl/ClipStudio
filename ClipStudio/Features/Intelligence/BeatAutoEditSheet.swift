//
//  BeatAutoEditSheet.swift
//  ClipStudio — Features/Intelligence (Part 4 suggestions)
//
//  "Auto edit to the beat": choose photos / videos (in order), a song, a style
//  and a frame size → the song is analyzed on device and a new Pro Studio project
//  is built with every cut on the beat (AutoEditBuilder), then opened.
//

import SwiftUI

struct BeatAutoEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var store = EditingDNAStore.shared
    @State private var visuals: [MediaAsset] = []
    @State private var music: MediaAsset?
    @State private var styleID: UUID = EditingDNA.fastReels.id
    @State private var aspect: AspectRatio = .portrait9x16
    @State private var name = ""
    @State private var keepClipAudio = false
    @State private var limitDuration = false
    @State private var maximumDuration: Double = 30
    @State private var pickingVisuals = false
    @State private var pickingMusic = false
    @State private var progress: Double?
    @State private var control: RenderControl?

    private var style: EditingDNA { store.style(styleID) ?? .fastReels }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { pickingVisuals = true } label: {
                        Label(visuals.isEmpty ? "اختر الصور والفيديوهات" : "إضافة المزيد", systemImage: "photo.stack")
                    }
                    ForEach(visuals) { asset in
                        HStack(spacing: 10) {
                            MediaThumbnailView(source: .asset(asset, env.library.url(for: asset), 0.5))
                                .frame(width: 56, height: 36)
                            Text(asset.displayName).lineLimit(1)
                            Spacer()
                            Text(asset.kind == .image ? "صورة" : asset.durationText)
                                .font(.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    .onMove { visuals.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { visuals.remove(atOffsets: $0) }
                    if visuals.count > 1 {
                        Button { visuals.shuffle() } label: { Label("ترتيب عشوائي", systemImage: "shuffle") }
                    }
                } header: {
                    Text("اللقطات بالترتيب (" + Fmt.int(visuals.count) + ")")
                } footer: {
                    Text("اسحب لإعادة الترتيب. الفيديو يُؤخذ من منتصفه، والقصير يأخذ ضربات أقل.")
                }

                Section("الموسيقى") {
                    Button { pickingMusic = true } label: {
                        HStack {
                            Label(music?.displayName ?? "اختر أغنية", systemImage: "music.note")
                            Spacer()
                            if let music { Text(music.durationText).foregroundStyle(Theme.Palette.textSecondary) }
                        }
                    }
                }

                Section {
                    Picker("الأسلوب", selection: $styleID) {
                        ForEach(store.all) { dna in Text(dna.name).tag(dna.id) }
                    }
                    Text(style.summary).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    Picker("المقاس", selection: $aspect) {
                        ForEach([AspectRatio.portrait9x16, .landscape16x9, .square, .portrait4x5], id: \.self) { ratio in
                            Text(ratio.title).tag(ratio)
                        }
                    }
                    Toggle("الحد الأقصى للمدة", isOn: $limitDuration)
                    if limitDuration {
                        PrecisionSlider(title: "المدة", value: $maximumDuration, range: 5...180, defaultValue: 30, step: 1,
                                        format: { Fmt.duration($0) })
                    }
                    Toggle("إبقاء صوت الفيديوهات", isOn: $keepClipAudio)
                } header: {
                    Text("الأسلوب")
                }

                Section("اسم المشروع") {
                    TextField("مونتاج على الإيقاع", text: $name)
                        .submitLabel(.done)
                }

                if let progress {
                    Section {
                        HStack {
                            ProgressBarView(progress: progress)
                            Button("إلغاء") { control?.cancel() }.font(.caption)
                        }
                        Text("تحليل الإيقاع على جهازك…").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("مونتاج تلقائي على الإيقاع")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { control?.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("إنشاء") { create() }
                        .fontWeight(.semibold)
                        .disabled(visuals.isEmpty || music == nil || progress != nil)
                }
            }
            .sheet(isPresented: $pickingVisuals) {
                MediaPickerSheet(title: "اللقطات", kinds: [.video, .image], allowsMultiple: true, confirmTitle: "إضافة") { assets in
                    visuals += assets.filter { asset in !visuals.contains { $0.id == asset.id } }
                }
            }
            .sheet(isPresented: $pickingMusic) {
                MediaPickerSheet(title: "الموسيقى", kinds: [.audio], allowsMultiple: false, confirmTitle: "اختيار") { assets in
                    music = assets.first
                }
            }
            .interactiveDismissDisabled(progress != nil)
        }
    }

    private func create() {
        guard let music, let url = env.library.url(forID: music.id) else { return }
        let control = RenderControl()
        self.control = control
        progress = 0
        let relay = ProgressRelay { value in progress = value }
        let dna = style
        let settings = ProjectSettings(aspect: aspect)
        let chosen = visuals
        let keepAudio = keepClipAudio
        let limit = limitDuration ? maximumDuration : nil
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let analysis = try await MusicAnalyzer.analyze(assetID: music.id, url: url, control: control,
                                                               progress: { relay.send($0) })
                var report = AutoEditReport()
                let timeline = try AutoEditBuilder.build(visuals: chosen, music: music, analysis: analysis, dna: dna,
                                                         settings: settings, keepClipAudio: keepAudio,
                                                         maximumDuration: limit, report: &report)
                let project = env.projects.create(kind: .pro, name: title.isEmpty ? "مونتاج على الإيقاع" : title,
                                                  settings: settings) { project in
                    project.timeline = timeline
                    project.coverAssetID = chosen.first?.id
                }
                var text = Fmt.int(report.shots) + " لقطة • كل " + Fmt.int(report.beatsPerShot) + " ضربات • "
                    + Fmt.duration(report.duration)
                if report.unused > 0 { text += " • " + Fmt.int(report.unused) + " لم تُستخدم (انتهت الموسيقى)" }
                env.toasts.show(text, style: .success, duration: 3.2)
                Haptics.success()
                progress = nil
                dismiss()
                env.router.openStudio(project.id)
            } catch {
                progress = nil
                if !control.isCancelled {
                    env.toasts.show((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, style: .warning)
                }
            }
        }
    }
}
