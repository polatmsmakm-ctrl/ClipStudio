//
//  MusicSyncSheet.swift
//  ClipStudio — Features/Intelligence (Part 4)
//
//  Music intelligence: analyze a music clip on device (tempo, beats, downbeats,
//  energy, sections, the drop), cut a track's clips on the beat with optional
//  beat-centred transitions, and add beat markers that clips snap to.
//  Part 4 suggestions: make the song end with the video (on a bar / keep the
//  ending / loop bars).
//

import SwiftUI

struct MusicSyncSheet: View {
    @Bindable var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var musicID: UUID?
    @State private var analysis: MusicAnalysis?
    @State private var trackIndex: Int?
    @State private var options = BeatSyncOptions()
    @State private var everyBeatMarkers = false
    @State private var fitMode: MusicFitMode = .endOnBar
    @State private var fadeOut: Double = 1.5

    private var candidates: [Clip] { vm.musicCandidates }
    private var musicClip: Clip? { musicID.flatMap { TimelineEngine.clip($0, in: vm.timeline) } }

    var body: some View {
        NavigationStack {
            Form {
                if candidates.isEmpty {
                    Section {
                        EmptyStateView(systemImage: "music.note", title: "لا توجد موسيقى",
                                       message: "أضف ملف موسيقى على مسار صوت، ثم ارجع هنا لتحليل الإيقاع.")
                    }
                } else {
                    musicSection
                    if let analysis, let musicClip {
                        resultSection(analysis, clip: musicClip)
                        cutSection(analysis)
                        fitSection(analysis)
                        markerSection(analysis)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .studioBusyOverlay(vm)
            .navigationTitle("الموسيقى والإيقاع")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
            .onAppear(perform: setup)
            .onChange(of: musicID) { _, _ in
                analysis = musicClip.flatMap(vm.cachedMusic(for:))
            }
        }
    }

    private func setup() {
        if musicID == nil {
            musicID = candidates.first { vm.cachedMusic(for: $0) != nil }?.id ?? candidates.first?.id
        }
        analysis = musicClip.flatMap(vm.cachedMusic(for:))
        if trackIndex == nil {
            trackIndex = vm.beatSyncTargets.first?.index
        }
    }

    private var musicSection: some View {
        Section {
            Picker("الموسيقى", selection: $musicID) {
                ForEach(candidates) { clip in
                    Text(clip.name + " (" + Fmt.duration(clip.duration.seconds) + ")").tag(Optional(clip.id))
                }
            }
            if analysis == nil {
                Button {
                    guard let musicID else { return }
                    Task { analysis = await vm.analyzeMusic(clipID: musicID) }
                } label: {
                    Label("حلّل الإيقاع", systemImage: "metronome")
                }
                .disabled(vm.busy != nil || musicID == nil)
            }
        } header: {
            Text("مقطع الموسيقى")
        } footer: {
            Text("التحليل محلي ويُحفظ للملف، فلا يتكرر.")
        }
    }

    private func resultSection(_ analysis: MusicAnalysis, clip: Clip) -> some View {
        Section("النتيجة") {
            HStack(spacing: 10) {
                StatBadge(title: "الإيقاع", value: Fmt.number(analysis.bpm, digits: 0) + " BPM", systemImage: "metronome")
                StatBadge(title: "الضربات", value: Fmt.int(analysis.beats.count), systemImage: "waveform.path")
                StatBadge(title: "الأقسام", value: Fmt.int(analysis.sections.count), systemImage: "rectangle.split.3x1")
            }
            .listRowBackground(Color.clear)
            MusicEnergyView(analysis: analysis, usedRange: clip.sourceRange.map { ($0.start.seconds, $0.end.seconds) })
                .frame(height: 90)
                .listRowBackground(Color.clear)
            if let drop = analysis.dropTime {
                Button {
                    if let local = SpeedMapping.localTime(of: clip, sourceTime: drop) { vm.seek(to: clip.start.seconds + local) }
                } label: {
                    Label("انتقل للذروة (" + Fmt.durationPrecise(drop) + ")", systemImage: "bolt.fill")
                }
                .disabled(SpeedMapping.localTime(of: clip, sourceTime: drop) == nil)
            }
        }
    }

    private func cutSection(_ analysis: MusicAnalysis) -> some View {
        Section {
            Picker("المسار", selection: $trackIndex) {
                ForEach(vm.beatSyncTargets) { pair in
                    Text(pair.track.name + " (" + Fmt.int(pair.track.clips.count) + ")").tag(Optional(pair.index))
                }
            }
            Picker("الإيقاع", selection: $options.grid) {
                ForEach(BeatGrid.allCases) { grid in Text(grid.title).tag(grid) }
            }
            Toggle("على الضربات القوية فقط", isOn: $options.downbeatsOnly)
                .disabled(analysis.downbeats.count < 2)
            Picker("الانتقالات", selection: $options.transitionEvery) {
                Text("بدون").tag(0)
                Text("كل قطع").tag(1)
                Text("كل قطعين").tag(2)
                Text("كل 4 قطع").tag(4)
            }
            if options.transitionEvery > 0 {
                Picker("نوع الانتقال", selection: $options.transitionKind) {
                    ForEach(TransitionKind.allCases.filter { $0 != .none }) { kind in Text(kind.title).tag(kind) }
                }
                PrecisionSlider(title: "مدة الانتقال", value: $options.transitionDuration, range: 0.1...1.2, defaultValue: 0.3,
                                step: 0.05, format: { Fmt.seconds($0, digits: 2) })
            }
            Button {
                guard let musicID, let trackIndex else { return }
                vm.cutToBeats(musicClipID: musicID, analysis: analysis, trackIndex: trackIndex, options: options)
            } label: {
                Label("قص المقاطع على الإيقاع", systemImage: "scissors")
            }
            .disabled(trackIndex == nil)
        } header: {
            Text("القص على الإيقاع")
        } footer: {
            Text("تُعاد توقيتات المقاطع بالترتيب ليقع كل قطع على ضربة. المقطع الذي لا يملك مصدرًا كافيًا يتوقف عند آخر ضربة ممكنة. الانتقالات تتوسط الضربة. خطوة تراجع واحدة.")
        }
    }

    private func fitSection(_ analysis: MusicAnalysis) -> some View {
        Section {
            Picker("الطريقة", selection: $fitMode) {
                ForEach(MusicFitMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if fitMode != .keepEnding {
                PrecisionSlider(title: "التلاشي في النهاية", value: $fadeOut, range: 0...5, defaultValue: 1.5, step: 0.1,
                                format: { Fmt.seconds($0, digits: 1) })
            }
            LabeledContent("نهاية الفيديو", value: Fmt.durationPrecise(vm.pictureEnd))
            Button {
                guard let musicID else { return }
                vm.fitMusic(clipID: musicID, analysis: analysis, mode: fitMode, fadeOut: fadeOut)
            } label: {
                Label("لائم الموسيقى مع الفيديو", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .disabled(musicID == nil || vm.timeline.isEmpty)
        } header: {
            Text("إنهاء الموسيقى مع الفيديو")
        } footer: {
            Text("القص والتكرار يتمان على حدود المازورات حتى يبقى الإيقاع سليمًا. خطوة تراجع واحدة.")
        }
    }

    private func markerSection(_ analysis: MusicAnalysis) -> some View {
        Section {
            Toggle("علامة لكل ضربة (وليس القوية فقط)", isOn: $everyBeatMarkers)
            Button {
                guard let musicID else { return }
                vm.addBeatMarkers(musicClipID: musicID, analysis: analysis, everyBeat: everyBeatMarkers)
            } label: {
                Label("أضف علامات الإيقاع", systemImage: "bookmark")
            }
            if vm.beatMarkerCount > 0 {
                Button(role: .destructive) { vm.removeBeatMarkers() } label: {
                    Label("حذف علامات الإيقاع (" + Fmt.int(vm.beatMarkerCount) + ")", systemImage: "bookmark.slash")
                }
            }
        } header: {
            Text("العلامات")
        } footer: {
            Text("المقاطع تلتصق بالعلامات أثناء السحب والقص — مفيد للتعديل اليدوي على الإيقاع.")
        }
    }
}

// MARK: - Energy view

struct MusicEnergyView: View {
    let analysis: MusicAnalysis
    /// Source seconds the clip uses (highlighted).
    var usedRange: (Double, Double)?

    var body: some View {
        Canvas { context, size in
            let duration = max(0.1, analysis.duration)
            func x(_ t: Double) -> CGFloat { CGFloat(t / duration) * size.width }
            // Used range.
            if let usedRange {
                let rect = CGRect(x: x(usedRange.0), y: 0, width: max(1, x(usedRange.1) - x(usedRange.0)), height: size.height)
                context.fill(Path(rect), with: .color(Theme.Palette.accent.opacity(0.08)))
            }
            // Sections.
            for (index, section) in analysis.sections.enumerated() {
                let rect = CGRect(x: x(section.start), y: size.height - 6, width: max(1, x(section.end) - x(section.start)), height: 6)
                let shade = 0.25 + 0.6 * section.energy
                context.fill(Path(roundedRect: rect.insetBy(dx: 1, dy: 0), cornerRadius: 2),
                             with: .color((index % 2 == 0 ? Theme.Palette.accent : Theme.Palette.accentDeep).opacity(shade)))
            }
            // Energy envelope.
            if analysis.energy.count > 1 {
                var path = Path()
                let usable = size.height - 12
                for (index, value) in analysis.energy.enumerated() {
                    let point = CGPoint(x: x(Double(index) / analysis.energyRate), y: usable - CGFloat(value) * usable + 2)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(Theme.Palette.accent), lineWidth: 1.4)
            }
            // Beats.
            let downbeats = Set(analysis.downbeats.map { ($0 * 100).rounded() })
            for beat in analysis.beats {
                let strong = downbeats.contains((beat * 100).rounded())
                let rect = CGRect(x: x(beat), y: 0, width: strong ? 1.5 : 0.75, height: strong ? 14 : 7)
                context.fill(Path(rect), with: .color(Theme.Palette.textPrimary.opacity(strong ? 0.8 : 0.35)))
            }
            if let drop = analysis.dropTime {
                let rect = CGRect(x: x(drop) - 1, y: 0, width: 2, height: size.height - 8)
                context.fill(Path(rect), with: .color(Theme.Palette.warning))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(Theme.Palette.surfaceRaised.opacity(0.7)))
        .accessibilityLabel("منحنى طاقة الموسيقى والإيقاعات")
    }
}
