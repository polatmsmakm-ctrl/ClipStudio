//
//  SeriesBuilderView.swift
//  ClipStudio — Features/Intelligence (Part 6 suggestions)
//
//  Episode series in one go: choose several videos, a style, an optional song
//  and the intro / outro text → one Studio project per video ("الحلقة 1، 2…"),
//  all with the same look. Optionally queue every episode for export with the
//  default export settings. The original media is never modified.
//

import SwiftUI

struct SeriesBuilderView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var videos: [MediaAsset] = []
    @State private var music: MediaAsset?
    @State private var styleID: UUID?
    @State private var aspect: AspectRatio = .portrait9x16
    @State private var options = SeriesOptions()
    @State private var limitDuration = false
    @State private var maxDuration: Double = 60
    @State private var queueExport = false
    @State private var pickingVideos = false
    @State private var pickingMusic = false
    @State private var working = false
    @State private var stage = ""
    @State private var created: [EditProject] = []

    private var styles: [EditingDNA] { EditingDNAStore.shared.all }
    private var style: EditingDNA? { styleID.flatMap { id in styles.first { $0.id == id } } }

    var body: some View {
        Form {
            Section {
                Button { pickingVideos = true } label: {
                    Label(videos.isEmpty ? "اختر الحلقات (فيديوهات)" : "الحلقات: " + Fmt.int(videos.count), systemImage: "film.stack")
                }
                ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                    HStack {
                        Text(SeriesBuilder.episodeLabel(options, index: index)).font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.accent)
                        Text(video.displayName).lineLimit(1)
                        Spacer()
                        Text(video.durationText).font(.caption.monospacedDigit()).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .onMove { videos.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { videos.remove(atOffsets: $0) }
            } header: {
                Text("الحلقات بالترتيب")
            } footer: {
                Text("اسحب لتغيير الترتيب — الترقيم يتبع الترتيب.")
            }
            Section("العنوان") {
                TextField("اسم السلسلة", text: $options.seriesName)
                TextField("صيغة الحلقة ({n} = الرقم)", text: $options.episodeFormat)
                Stepper("يبدأ الترقيم من " + Fmt.int(options.startNumber), value: $options.startNumber, in: 1...999)
                PrecisionSlider(title: "بطاقة المقدمة", value: $options.introDuration, range: 0...6, defaultValue: 2.5, step: 0.5,
                                format: { $0 < 0.1 ? "بدون (عنوان فوق الفيديو)" : Fmt.seconds($0, digits: 1) })
                TextField("نص الخاتمة (اختياري): تابعونا…", text: $options.outroText)
            }
            Section("الشكل") {
                Picker("المقاس", selection: $aspect) {
                    ForEach([AspectRatio.portrait9x16, .landscape16x9, .square, .portrait4x5], id: \.self) { Text($0.title).tag($0) }
                }
                Picker("الأسلوب", selection: $styleID) {
                    Text("بدون أسلوب").tag(UUID?.none)
                    ForEach(styles) { item in Text(item.name).tag(Optional(item.id)) }
                }
                Picker("الانتقال", selection: $options.transition) {
                    ForEach([TransitionKind.none, .crossDissolve, .fadeBlack, .zoomIn, .slideLeft], id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("حد أقصى لطول الحلقة", isOn: $limitDuration)
                if limitDuration {
                    PrecisionSlider(title: "الحد الأقصى", value: $maxDuration, range: 10...600, defaultValue: 60, step: 5,
                                    format: { Fmt.duration($0) })
                }
            }
            Section {
                Button { pickingMusic = true } label: {
                    Label(music?.displayName ?? "موسيقى مشتركة (اختياري)", systemImage: "music.note")
                }
                if music != nil {
                    PrecisionSlider(title: "مستوى الموسيقى", value: $options.musicVolume, range: 0.05...1, defaultValue: 0.25, step: 0.05,
                                    format: { Fmt.percent($0) })
                    Button("بدون موسيقى", role: .destructive) { music = nil }
                }
            } header: {
                Text("الموسيقى")
            } footer: {
                Text("إذا كانت الأغنية محللة (الموسيقى والإيقاع) تنتهي على مازورة أو تتكرر حتى نهاية كل حلقة.")
            }
            Section {
                Toggle("أضف كل الحلقات للتصدير", isOn: $queueExport)
                Button { build() } label: {
                    HStack {
                        Label("أنشئ " + Fmt.int(videos.count) + " حلقة", systemImage: "square.stack.3d.down.right")
                        Spacer()
                        if working { ProgressView() }
                    }
                }
                .disabled(videos.isEmpty || working)
                if working { Text(stage).font(.caption).foregroundStyle(Theme.Palette.textSecondary) }
            } footer: {
                Text(queueExport ? "يستخدم إعدادات التصدير الافتراضية من الإعدادات." : "تجد الحلقات في الاستوديو والمشاريع.")
            }
            if !created.isEmpty {
                Section("تم الإنشاء") {
                    ForEach(created) { project in
                        Button { env.router.openStudio(project.id) } label: {
                            Label(project.name, systemImage: "film")
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .screenBackground()
        .navigationTitle("سلسلة حلقات")
        .keyboardDoneToolbar()
        .toolbar { EditButton().disabled(videos.isEmpty) }
        .sheet(isPresented: $pickingVideos) {
            MediaPickerSheet(title: "الحلقات", kinds: [.video], allowsMultiple: true, confirmTitle: "إضافة") { assets in
                videos += assets.filter { asset in !videos.contains { $0.id == asset.id } }
            }
        }
        .sheet(isPresented: $pickingMusic) {
            MediaPickerSheet(title: "الموسيقى", kinds: [.audio], allowsMultiple: false, confirmTitle: "اختيار") { assets in
                music = assets.first
            }
        }
    }

    private func build() {
        working = true
        created = []
        var seriesOptions = options
        seriesOptions.maximumDuration = limitDuration ? maxDuration : nil
        let settings = ProjectSettings(aspect: aspect)
        let chosenStyle = style
        let song = music
        let library = env.library
        let list = videos
        Task {
            var analysis: MusicAnalysis?
            if let song {
                analysis = MusicAnalyzer.cached(assetID: song.id)
                if analysis == nil, let url = library.url(forID: song.id) {
                    stage = "تحليل الموسيقى…"
                    analysis = try? await MusicAnalyzer.analyze(assetID: song.id, url: url, control: nil, progress: { _ in })
                }
            }
            var projects: [EditProject] = []
            var failed = 0
            for (index, video) in list.enumerated() {
                stage = "إنشاء " + SeriesBuilder.episodeLabel(seriesOptions, index: index) + "…"
                await Task.yield()
                do {
                    let timeline = try SeriesBuilder.episode(video: video, index: index, options: seriesOptions, style: chosenStyle,
                                                             music: song, musicAnalysis: analysis, settings: settings)
                    let title = [seriesOptions.seriesName.trimmingCharacters(in: .whitespacesAndNewlines),
                                 SeriesBuilder.episodeLabel(seriesOptions, index: index)].filter { !$0.isEmpty }.joined(separator: " — ")
                    let project = env.projects.create(kind: .pro, name: title, settings: settings) { project in
                        project.timeline = timeline
                        project.coverAssetID = video.id
                    }
                    projects.append(project)
                } catch {
                    failed += 1
                }
            }
            if queueExport, !projects.isEmpty {
                let exportSettings = env.settings.defaultExport
                let jobs = projects.map { project -> ExportJob in
                    let payload = RenderPayload(timeline: project.timeline, projectSettings: project.settings, range: nil)
                    var job = ExportJob(title: project.name, outputBaseName: project.name, payload: .render(payload), settings: exportSettings)
                    let size = ExportGeometry.outputSize(canvas: project.settings.canvasSize, resolution: exportSettings.resolution)
                    let fps = exportSettings.frameRate.value ?? project.settings.frameRate
                    let bitrate = BitrateCalculator.videoBitrate(size: size, fps: fps, settings: exportSettings)
                    job.estimatedBytes = BitrateCalculator.estimatedBytes(durationSeconds: project.timeline.duration.seconds,
                                                                          videoBitrate: bitrate, audioKbps: exportSettings.audioBitrateKbps)
                    return job
                }
                env.exportQueue.enqueue(jobs)
            }
            created = projects
            working = false
            Haptics.success()
            var message = "أُنشئت " + Fmt.int(projects.count) + " حلقة"
            if failed > 0 { message += " • تعذّرت " + Fmt.int(failed) }
            if queueExport && !projects.isEmpty { message += " • أُضيفت للتصدير" }
            env.toasts.show(message, style: failed > 0 ? .warning : .success, duration: 3)
        }
    }
}
