//
//  StoryboardView.swift
//  ClipStudio — Features/AI (Part 5)
//
//  AI Storyboard: write an idea, pick photos / videos, choose length and tone →
//  the AI proposes ordered scenes (purpose, shot from your media with exact
//  times, on-screen text, voice-over line). Every scene is editable (text,
//  duration, order, delete, add) before a new Pro Studio project is built from it.
//  Part 6: optional generated voiceover for every scene's voice-over line.
//

import SwiftUI

struct StoryboardView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var idea = ""
    @State private var duration: Double = 30
    @State private var tone = "حماسي"
    @State private var aspect: AspectRatio = .portrait9x16
    @State private var media: [MediaAsset] = []
    @State private var picking = false
    @State private var working = false
    @State private var board: Storyboard?
    @State private var refs: [AIMediaReference] = []
    @State private var note: String?
    @State private var provider: AIProviderKind?
    @State private var consent: AIConsentRequest?
    @State private var task: Task<Void, Never>?
    // Part 6: generated voiceover for the scenes' voice-over lines.
    @State private var withVoiceover = false
    @State private var voiceOptions = VoiceoverOptions()
    @State private var workingText = "يكتب القصة المصورة…"

    static let tones = ["حماسي", "هادئ", "مضحك", "تعليمي", "سينمائي", "عاطفي", "إعلاني"]

    var body: some View {
        Form {
            if let board {
                resultSections(board)
            } else {
                inputSections
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("القصة المصورة")
        .keyboardDoneToolbar()
        .toolbar {
            if board != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("بداية جديدة") { board = nil; note = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("إنشاء المشروع") { createProject() }.fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $picking) {
            MediaPickerSheet(title: "الوسائط", kinds: [.video, .image], allowsMultiple: true, confirmTitle: "إضافة") { assets in
                media += assets.filter { asset in !media.contains { $0.id == asset.id } }
            }
        }
        .aiConsent($consent)
        .overlay {
            if working {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(workingText).font(.callout)
                        Button("إلغاء") { task?.cancel(); working = false }.font(.caption)
                    }
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(.ultraThinMaterial))
                }
            }
        }
        .onDisappear { task?.cancel() }
    }

    // MARK: Input

    @ViewBuilder
    private var inputSections: some View {
        Section {
            TextField("مثال: إعلان لمقهى جديد يركز على القهوة المختصة والجلسات الخارجية", text: $idea, axis: .vertical)
                .lineLimit(3...6)
        } header: {
            Text("الفكرة")
        }
        Section {
            Button { picking = true } label: { Label(media.isEmpty ? "اختر الصور والفيديوهات" : "إضافة المزيد", systemImage: "photo.stack") }
            ForEach(media) { asset in
                HStack(spacing: 10) {
                    MediaThumbnailView(source: .asset(asset, env.library.url(for: asset), 0.5)).frame(width: 56, height: 36)
                    Text(asset.displayName).lineLimit(1)
                    Spacer()
                    Text(asset.kind == .image ? "صورة" : asset.durationText).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .onDelete { media.remove(atOffsets: $0) }
        } header: {
            Text("الوسائط (" + Fmt.int(media.count) + ")")
        } footer: {
            Text("بدون وسائط تُقترح مشاهد عامة تملؤها لاحقًا.")
        }
        Section {
            PrecisionSlider(title: "المدة", value: $duration, range: 10...180, defaultValue: 30, step: 5, format: { Fmt.duration($0) })
            Picker("النبرة", selection: $tone) { ForEach(Self.tones, id: \.self) { Text($0).tag($0) } }
            Picker("المقاس", selection: $aspect) {
                ForEach([AspectRatio.portrait9x16, .landscape16x9, .square, .portrait4x5], id: \.self) { Text($0.title).tag($0) }
            }
        }
        Section {
            Button {
                generate()
            } label: {
                Label("اكتب القصة المصورة", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(.csPrimary)
            .listRowBackground(Color.clear)
            .disabled(working || (idea.trimmingCharacters(in: .whitespaces).isEmpty && media.isEmpty))
        } footer: {
            HStack { AIProviderBadge(task: .storyboard); Spacer() }
        }
    }

    // MARK: Result

    @ViewBuilder
    private func resultSections(_ current: Storyboard) -> some View {
        Section {
            TextField("العنوان", text: Binding(get: { board?.title ?? "" }, set: { board?.title = $0 }))
                .font(.headline)
            if !current.summary.isEmpty { Text(current.summary).font(.caption).foregroundStyle(Theme.Palette.textSecondary) }
            LabeledContent("المدة", value: Fmt.duration(current.duration))
            if !current.musicMood.isEmpty { LabeledContent("مزاج الموسيقى", value: current.musicMood) }
            if let note { Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(Theme.Palette.warning) }
            if let provider { StatusPill(text: provider.title, systemImage: provider == .gemini ? "sparkles" : "iphone") }
        }
        Section {
            Toggle("تعليق صوتي مولّد من نصوص المشاهد", isOn: $withVoiceover)
        } footer: {
            Text(withVoiceover ? "يُنشأ صوت لكل مشهد فيه تعليق ويُوضع على مسار «تعليق صوتي» في وقته." : "النصوص تبقى علامات على الخط الزمني.")
        }
        if withVoiceover {
            VoiceoverOptionsSection(options: $voiceOptions)
        }
        Section {
            ForEach(Array(current.scenes.enumerated()), id: \.element.id) { index, scene in
                sceneEditor(index: index, scene: scene)
            }
            .onMove { board?.scenes.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { board?.scenes.remove(atOffsets: $0) }
            Button {
                board?.scenes.append(StoryboardScene(purpose: .main, description: "مشهد جديد", duration: 3, onScreenText: "", voiceover: "", shot: nil))
            } label: { Label("إضافة مشهد", systemImage: "plus") }
        } header: {
            Text("المشاهد (" + Fmt.int(current.scenes.count) + ")")
        } footer: {
            Text("اسحب لإعادة الترتيب. المشهد بدون لقطة يصير خلفية داكنة تستبدلها لاحقًا، والتعليق الصوتي يُحفظ كعلامة على الخط الزمني.")
        }
    }

    private func sceneEditor(index: Int, scene: StoryboardScene) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(Fmt.int(index + 1)).font(.headline.monospacedDigit()).foregroundStyle(Theme.Palette.accent)
                Picker("", selection: Binding(get: { scene.purpose }, set: { value in update(scene.id) { $0.purpose = value } })) {
                    ForEach(StoryboardPurpose.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                Spacer()
                Stepper(Fmt.seconds(scene.duration, digits: 1),
                        value: Binding(get: { scene.duration }, set: { value in update(scene.id) { $0.duration = value } }),
                        in: 0.5...60, step: 0.5)
                    .fixedSize()
            }
            TextField("الوصف", text: Binding(get: { scene.description }, set: { value in update(scene.id) { $0.description = value } }),
                      axis: .vertical)
                .lineLimit(1...3)
            TextField("نص على الشاشة", text: Binding(get: { scene.onScreenText }, set: { value in update(scene.id) { $0.onScreenText = value } }))
            TextField("تعليق صوتي", text: Binding(get: { scene.voiceover }, set: { value in update(scene.id) { $0.voiceover = value } }),
                      axis: .vertical)
                .lineLimit(1...3)
            if let shot = scene.shot, let ref = refs.first(where: { $0.ref.lowercased() == shot.mediaRef.lowercased() }) {
                HStack(spacing: 8) {
                    if let asset = env.library.asset(ref.assetID) {
                        MediaThumbnailView(source: .asset(asset, env.library.url(for: asset), shot.start)).frame(width: 52, height: 32)
                    }
                    Text(ref.name).font(.caption).lineLimit(1)
                    Spacer()
                    if ref.kind != .image {
                        Text(Fmt.durationPrecise(shot.start) + " ← " + Fmt.durationPrecise(shot.end))
                            .font(Theme.Typo.mono).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Button { update(scene.id) { $0.shot = nil } } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func update(_ id: UUID, _ change: (inout StoryboardScene) -> Void) {
        guard let index = board?.scenes.firstIndex(where: { $0.id == id }) else { return }
        change(&board!.scenes[index])
    }

    // MARK: Actions

    private func generate() {
        let references = AIFeatureService.mediaReferences(media)
        let videoCount = references.filter { $0.kind == .video }.count
        let imageCount = references.filter { $0.kind == .image }.count
        let frames = min(24, videoCount * 4 + imageCount)
        withAIConsent(task: .storyboard, sendsMedia: frames > 0,
                      summary: AIFeatureService.uploadSummary(frames: frames, hasText: true, videoSeconds: nil),
                      present: { consent = $0 }) { forceLocal in
            run(references: references, forceLocal: forceLocal)
        }
    }

    private func run(references: [AIMediaReference], forceLocal: Bool) {
        working = true
        let length = duration
        let library = env.library
        task = Task {
            let frames = forceLocal || !AISettings.shared.cloudAvailable
                ? [] : await AIFeatureService.frameParts(references, library: library, perVideo: 4, maxTotal: 24)
            let request = AIFeatureService.storyboardRequest(idea: idea, duration: length, tone: tone, refs: references, frames: frames)
            do {
                let result = try await AIFeatureService.storyboard(request, refs: references, duration: length, forceLocal: forceLocal)
                if Task.isCancelled { return }
                refs = references
                board = result.board
                note = result.response.note
                provider = result.response.provider
                Haptics.success()
            } catch {
                if !Task.isCancelled {
                    env.toasts.show((error as? LocalizedError)?.errorDescription ?? error.localizedDescription, style: .warning, duration: 3)
                }
            }
            working = false
        }
    }

    private func createProject() {
        guard let board, !board.scenes.isEmpty else { return }
        let settings = ProjectSettings(aspect: aspect)
        var built = AIFeatureService.timeline(for: board, refs: refs, settings: settings)
        let lines = board.scenes.enumerated().compactMap { index, scene -> (time: Double, text: String)? in
            let text = scene.voiceover.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, index < built.markers.count else { return nil }
            return (time: built.markers[index].time.seconds, text: text)
        }
        guard withVoiceover, !lines.isEmpty else {
            finish(board: board, built: built, settings: settings, voiceFailures: 0)
            return
        }
        let options = voiceOptions
        let library = env.library
        workingText = "يولّد التعليق الصوتي…"
        working = true
        task = Task {
            var clips: [Clip] = []
            var failures = 0
            for (number, line) in lines.enumerated() {
                if Task.isCancelled { break }
                workingText = "تعليق صوتي " + Fmt.int(number + 1) + " من " + Fmt.int(lines.count) + "…"
                do {
                    let url = try await SpeechSynthesis.synthesize(line.text, options: options)
                    let asset = try await library.registerGenerated(file: url, displayName: "تعليق — " + CaptionBuilder.shortName(line.text), kind: .audio)
                    let fps = Double(max(1, settings.frameRate))
                    let length = max(1 / fps, ((asset.durationSeconds ?? 1) * fps).rounded(.down) / fps)
                    clips.append(Clip(name: asset.displayName, source: .media(asset.id), start: TimeValue(seconds: line.time),
                                      duration: TimeValue(seconds: length), sourceRange: TimeRangeValue(startSeconds: 0, endSeconds: length)))
                } catch {
                    failures += 1
                }
            }
            working = false
            workingText = "يكتب القصة المصورة…"
            guard !Task.isCancelled else { return }
            if !clips.isEmpty {
                var track = Track(kind: .audio, name: "تعليق صوتي", clips: [])
                // Lines that run into the next one move later instead of overlapping.
                var reach = 0.0
                for var clip in clips.sorted(by: { $0.start < $1.start }) {
                    if clip.start.seconds < reach { clip.start = TimeValue(seconds: reach) }
                    reach = clip.end.seconds
                    track.clips.append(clip)
                }
                built.timeline.tracks.append(track)
                var durations: [UUID: Double] = [:]
                for ref in refs where ref.kind == .video { durations[ref.assetID] = ref.duration }
                for clip in clips { if case .media(let id) = clip.source { durations[id] = clip.duration.seconds } }
                TimelineEngine.finalize(&built.timeline, context: EditContext(assetDurations: durations,
                                                                               frameRate: Double(max(1, settings.frameRate)), magnetic: true))
            }
            finish(board: board, built: built, settings: settings, voiceFailures: failures)
        }
    }

    private func finish(board: Storyboard, built: (timeline: Timeline, markers: [TimelineMarker]), settings: ProjectSettings, voiceFailures: Int) {
        let project = env.projects.create(kind: .pro, name: board.title, settings: settings) { project in
            project.timeline = built.timeline
            project.markers = built.markers
            project.coverAssetID = refs.first?.assetID
        }
        Haptics.success()
        var message = "أُنشئ المشروع من " + Fmt.int(board.scenes.count) + " مشهد"
        if voiceFailures > 0 { message += " • تعذّر " + Fmt.int(voiceFailures) + " تعليق صوتي" }
        env.toasts.show(message, style: voiceFailures > 0 ? .warning : .success)
        env.router.openStudio(project.id)
    }
}
