//
//  HighlightsView.swift
//  ClipStudio — Features/AI (Part 5)
//
//  Smart Highlights: choose a long video → scene cuts, loudness and speech are
//  measured on device; Gemini (frames, or a compressed copy when "whole video"
//  is on) or the on-device scorer picks the best moments. Review, untick, then
//  build one highlight reel or a separate project per moment.
//

import SwiftUI

struct HighlightsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var asset: MediaAsset?
    @State private var picking = false
    @State private var count = 5
    @State private var length: Double = 8
    @State private var aspect: AspectRatio = .portrait9x16
    @State private var withTitles = true
    @State private var moments: [HighlightMoment] = []
    @State private var selected: Set<UUID> = []
    @State private var progress: Double?
    @State private var stage = ""
    @State private var note: String?
    @State private var provider: AIProviderKind?
    @State private var consent: AIConsentRequest?
    @State private var control: RenderControl?
    @State private var task: Task<Void, Never>?

    private var deep: Bool { AISettings.shared.deepVideoAnalysis }

    var body: some View {
        Form {
            Section {
                Button { picking = true } label: {
                    HStack(spacing: 10) {
                        if let asset {
                            MediaThumbnailView(source: .asset(asset, env.library.url(for: asset), 1)).frame(width: 64, height: 40)
                            VStack(alignment: .leading) {
                                Text(asset.displayName).lineLimit(1)
                                Text(asset.durationText).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                            }
                        } else {
                            Label("اختر فيديو طويل", systemImage: "film")
                        }
                    }
                }
            } header: {
                Text("الفيديو")
            }
            Section {
                Stepper("عدد اللحظات: " + Fmt.int(count), value: $count, in: 1...15)
                PrecisionSlider(title: "طول اللحظة", value: $length, range: 3...30, defaultValue: 8, step: 1, format: { Fmt.seconds($0, digits: 0) })
                Picker("المقاس", selection: $aspect) {
                    ForEach([AspectRatio.portrait9x16, .landscape16x9, .square, .portrait4x5], id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("عنوان قصير على كل لحظة", isOn: $withTitles)
                Button { analyze() } label: { Label("ابحث عن أفضل اللحظات", systemImage: "sparkles").frame(maxWidth: .infinity) }
                    .buttonStyle(.csPrimary)
                    .listRowBackground(Color.clear)
                    .disabled(asset == nil || progress != nil)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { AIProviderBadge(task: .highlights); Spacer() }
                    Text(deep && AISettings.shared.cloudAvailable
                         ? "وضع «الفيديو كامل» مفعّل: تُرفع نسخة مضغوطة لتحليل أدق."
                         : "تُحلل اللقطات والصوت على جهازك، ومع Gemini تُرسل صور مصغرة فقط.")
                }
            }
            if let progress {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(stage).font(.caption)
                        HStack {
                            ProgressBarView(progress: progress)
                            Button("إلغاء") { control?.cancel(); task?.cancel(); self.progress = nil }.font(.caption)
                        }
                    }
                }
            }
            if !moments.isEmpty { resultSection }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("أفضل اللقطات")
        .sheet(isPresented: $picking) {
            MediaPickerSheet(title: "فيديو", kinds: [.video], allowsMultiple: false, confirmTitle: "اختيار") { assets in
                asset = assets.first
                moments = []
            }
        }
        .aiConsent($consent)
        .onDisappear { control?.cancel(); task?.cancel() }
    }

    private var resultSection: some View {
        Section {
            if let note { Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(Theme.Palette.warning) }
            ForEach(moments) { moment in
                Button {
                    if selected.contains(moment.id) { selected.remove(moment.id) } else { selected.insert(moment.id) }
                    Haptics.selection()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selected.contains(moment.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(moment.id) ? Theme.Palette.accent : Theme.Palette.textTertiary)
                        if let asset {
                            MediaThumbnailView(source: .asset(asset, env.library.url(for: asset), moment.start + 0.3))
                                .frame(width: 72, height: 44)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(moment.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(Fmt.durationPrecise(moment.start) + " ← " + Fmt.durationPrecise(moment.end))
                                .font(Theme.Typo.mono).foregroundStyle(Theme.Palette.textSecondary)
                            if !moment.reason.isEmpty {
                                Text(moment.reason).font(.caption2).foregroundStyle(Theme.Palette.textTertiary).lineLimit(2)
                            }
                        }
                        Spacer()
                        Text(Fmt.int(Int(moment.score.rounded()))).font(.headline.monospacedDigit()).foregroundStyle(Theme.Palette.accent)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button { buildReel() } label: { Label("مقطع مجمّع من المحدد", systemImage: "film.stack") }
                .disabled(selected.isEmpty)
            Button { buildSeparate() } label: { Label("مشروع لكل لحظة", systemImage: "square.on.square") }
                .disabled(selected.isEmpty)
        } header: {
            HStack {
                Text("النتائج (" + Fmt.int(moments.count) + ")")
                Spacer()
                if let provider { Text(provider.title) }
            }
        }
    }

    // MARK: Actions

    private func analyze() {
        guard let asset else { return }
        let cloud = AISettings.shared.cloudAvailable
        let summary = AIFeatureService.uploadSummary(frames: deep ? 0 : 40, hasText: true,
                                                     videoSeconds: deep ? asset.durationSeconds : nil)
        withAIConsent(task: .highlights, sendsMedia: cloud, summary: summary, present: { consent = $0 }) { forceLocal in
            run(asset: asset, forceLocal: forceLocal)
        }
    }

    private func run(asset: MediaAsset, forceLocal: Bool) {
        guard let url = env.library.url(forID: asset.id) else { return }
        let control = RenderControl()
        self.control = control
        progress = 0
        stage = "تحليل اللقطات والصوت على جهازك…"
        let relay = ProgressRelay { value in progress = value }
        let library = env.library
        let wanted = count, targetLength = length
        let useDeep = deep && !forceLocal && AISettings.shared.cloudAvailable
        task = Task {
            do {
                var uploaded: UploadedAIFile?
                if useDeep {
                    stage = "تجهيز ورفع نسخة مضغوطة…"
                    uploaded = try await AIRequestRouter.shared.uploadVideo(asset: asset, url: url, control: control,
                                                                            progress: { relay.send($0 * 0.5) })
                    stage = "تحليل اللقطات والصوت على جهازك…"
                }
                let base = useDeep ? 0.5 : 0
                let request = await AIFeatureService.highlightsRequest(asset: asset, url: url, count: wanted, length: targetLength,
                                                                       uploaded: uploaded, library: library,
                                                                       progress: { relay.send(base + $0 * (1 - base) * 0.9) })
                if control.isCancelled { progress = nil; return }
                stage = "اختيار أفضل اللحظات…"
                let result = try await AIFeatureService.highlights(request, duration: asset.durationSeconds ?? 0, count: wanted,
                                                                   forceLocal: forceLocal)
                moments = result.moments
                selected = Set(result.moments.map(\.id))
                note = result.response.note
                provider = result.response.provider
                Haptics.success()
            } catch {
                if !control.isCancelled {
                    env.toasts.show((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, style: .warning, duration: 3)
                }
            }
            progress = nil
        }
    }

    private var chosen: [HighlightMoment] { moments.filter { selected.contains($0.id) } }

    private func buildReel() {
        guard let asset else { return }
        let settings = ProjectSettings(aspect: aspect)
        let timeline = AIFeatureService.reel(chosen, asset: asset, settings: settings, withTitles: withTitles)
        let project = env.projects.create(kind: .pro, name: "أفضل لقطات — " + asset.displayName, settings: settings) { project in
            project.timeline = timeline
            project.coverAssetID = asset.id
        }
        Haptics.success()
        env.router.openStudio(project.id)
    }

    private func buildSeparate() {
        guard let asset else { return }
        let settings = ProjectSettings(aspect: aspect)
        for moment in chosen {
            let timeline = AIFeatureService.reel([moment], asset: asset, settings: settings, withTitles: withTitles)
            _ = env.projects.create(kind: .pro, name: moment.title, settings: settings) { project in
                project.timeline = timeline
                project.coverAssetID = asset.id
            }
        }
        Haptics.success()
        env.toasts.show("أُنشئ " + Fmt.int(chosen.count) + " مشروع في الاستوديو", style: .success)
    }
}
