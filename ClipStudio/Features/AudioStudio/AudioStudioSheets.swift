//
//  AudioStudioSheets.swift
//  ClipStudio — Features/AudioStudio (Part 3)
//
//  • MixerSheet — every sound track as a channel strip: live level meter, volume,
//    balance, mute, solo, plus audio-only export of the mix.
//  • VoiceoverSheet — record narration over the timeline (count-in, level meter).
//  • SoundEffectsSheet — the built-in synthesized sound-effects library.
//  • DuckingSheet — automatic music ducking under speech.
//

import SwiftUI
import AVFoundation

// MARK: - Mixer

struct MixerSheet: View {
    let vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var exportedURL: URL?
    @State private var useInOut = false

    private var channels: [IndexedTrack] {
        TimelineEngine.displayOrder(vm.timeline).compactMap { index -> IndexedTrack? in
            let track = vm.timeline.tracks[index]
            return track.carriesAudio ? IndexedTrack(index: index, track: track) : nil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    transport
                    if channels.isEmpty {
                        EmptyStateView(systemImage: "slider.horizontal.3", title: "لا توجد مسارات صوت",
                                       message: "أضف فيديو أو صوتًا للخط الزمني.")
                    }
                    ForEach(channels) { channel in
                        MixerChannelStrip(vm: vm, index: channel.index, track: channel.track)
                    }
                    exportSection
                }
                .padding()
            }
            .navigationTitle("المكسر")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() }.fontWeight(.semibold) }
                if vm.timeline.tracks.contains(where: \.isSolo) {
                    ToolbarItem(placement: .cancellationAction) { Button("إلغاء العزل") { vm.clearSolo() } }
                }
            }
            .screenBackground()
        }
        .presentationDetents([.medium, .large])
    }

    private var transport: some View {
        HStack(spacing: 16) {
            Button { vm.togglePlay() } label: {
                Image(systemName: vm.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Theme.Palette.accent))
                    .foregroundStyle(Color(hex: 0x1A1408))
            }
            .accessibilityLabel(vm.player.isPlaying ? "إيقاف" : "تشغيل")
            Text(Fmt.timecode(vm.currentTime, fps: vm.frameRate))
                .font(Theme.Typo.monoLarge)
                .foregroundStyle(Theme.Palette.textPrimary)
                .environment(\.layoutDirection, .leftToRight)
            Spacer()
        }
    }

    private var exportSection: some View {
        InspectorSection(title: "تصدير الصوت فقط", systemImage: "square.and.arrow.up") {
            if vm.inOutRange != nil {
                Toggle("من نقطة البداية إلى النهاية فقط", isOn: $useInOut).tint(Theme.Palette.accent)
            }
            Button {
                vm.exportAudioMix(useInOut: useInOut) { exportedURL = $0 }
            } label: {
                Label("تصدير M4A", systemImage: "waveform").frame(maxWidth: .infinity)
            }
            .buttonStyle(.csSecondary)
            if let exportedURL {
                ShareLink(item: exportedURL) {
                    Label("مشاركة " + exportedURL.lastPathComponent, systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(.csSecondary)
            }
        }
    }
}

struct MixerChannelStrip: View {
    let vm: StudioViewModel
    let index: Int
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(track.color?.color ?? Theme.Palette.textTertiary)
                    .frame(width: 4, height: 28)
                Image(systemName: track.kind.symbol).foregroundStyle(Theme.Palette.accent)
                Text(track.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Button { vm.toggleMuted(index) } label: {
                    Text("M").font(.caption.weight(.heavy))
                        .frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(track.isMuted ? Theme.Palette.danger : Theme.Palette.surfaceHighlight))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(track.isMuted ? "إلغاء الكتم" : "كتم")
                Button { vm.toggleSolo(index) } label: {
                    Text("S").font(.caption.weight(.heavy))
                        .frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(track.isSolo ? Theme.Palette.accent : Theme.Palette.surfaceHighlight))
                        .foregroundStyle(track.isSolo ? Color(hex: 0x1A1408) : Theme.Palette.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(track.isSolo ? "إلغاء العزل" : "عزل")
            }
            LevelMeterView(vm: vm, trackID: track.id)
                .frame(height: 8)
            PrecisionSlider(title: "المستوى", value: Binding(get: { track.volume }, set: { vm.setTrackVolume(index, $0) }),
                            range: 0...1, defaultValue: 1, format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                            onEditingChanged: { if !$0 { vm.endContinuousEdit() } })
            PrecisionSlider(title: "التوازن", value: Binding(get: { track.pan }, set: { vm.setTrackPan(index, $0) }),
                            range: -1...1, defaultValue: 0,
                            format: { value in
                                if abs(value) < 0.01 { return "وسط" }
                                return (value < 0 ? "يسار " : "يمين ") + Fmt.number(abs(value) * 100, digits: 0)
                            },
                            onEditingChanged: { if !$0 { vm.endContinuousEdit() } })
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.Palette.surface))
        .opacity(track.isMuted ? 0.6 : 1)
    }
}

/// Live peak/RMS meter fed by the preview's processing taps (≈ 30 updates per second).
struct LevelMeterView: View {
    let vm: StudioViewModel
    let trackID: UUID

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let level = vm.meterLevel(trackID: trackID)
            GeometryReader { geo in
                let w = geo.size.width
                let rms = CGFloat(Self.scale(level.rms))
                let peak = CGFloat(Self.scale(level.peak))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [Theme.Palette.success, Theme.Palette.accent, Theme.Palette.danger],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, w * rms))
                        .mask(alignment: .leading) { Rectangle().frame(width: max(0, w * rms)) }
                    Rectangle().fill(Color.white.opacity(0.9))
                        .frame(width: 2)
                        .offset(x: max(0, w * peak - 2))
                        .opacity(peak > 0.01 ? 1 : 0)
                }
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .accessibilityHidden(true)
    }

    /// −60…0 dBFS → 0…1.
    static func scale(_ value: Float) -> Double {
        guard value > 0 else { return 0 }
        let db = 20 * log10(Double(value))
        return min(1, max(0, (db + 60) / 60))
    }
}

// MARK: - Voiceover

struct VoiceoverSheet: View {
    let vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var recorder = VoiceoverRecorder()
    @State private var countIn = true
    @State private var playTimeline = true
    @State private var muteTimeline = true
    @State private var startTime: Double = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer(minLength: 8)
                ZStack {
                    Circle()
                        .fill(Theme.Palette.danger.opacity(0.15))
                        .frame(width: 180, height: 180)
                        .scaleEffect(1 + recorder.level * 0.35)
                        .animation(.easeOut(duration: 0.1), value: recorder.level)
                    statusContent
                }
                .frame(height: 220)
                Text(Fmt.durationPrecise(recorder.elapsed))
                    .font(Theme.Typo.monoLarge)
                    .environment(\.layoutDirection, .leftToRight)
                if !recorder.inputName.isEmpty {
                    Label(recorder.inputName, systemImage: "mic").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
                if recorder.permissionDenied {
                    Text("لم يُسمح بالميكروفون. فعّله من الإعدادات ← ClipStudio ← الميكروفون.")
                        .font(.callout)
                        .foregroundStyle(Theme.Palette.danger)
                        .multilineTextAlignment(.center)
                }
                if !recorder.isActive {
                    VStack(spacing: 10) {
                        Toggle("عد تنازلي 3 ثوانٍ", isOn: $countIn)
                        Toggle("تشغيل الفيديو أثناء التسجيل", isOn: $playTimeline)
                        if playTimeline { Toggle("كتم صوت الفيديو أثناء التسجيل", isOn: $muteTimeline) }
                    }
                    .tint(Theme.Palette.accent)
                    .padding(.horizontal)
                    Text("يبدأ التعليق عند رأس التشغيل (" + Fmt.timecode(vm.currentTime, fps: vm.frameRate)
                         + ") ويوضع في مسار «تعليق صوتي». يُفضّل استخدام سماعة لتجنب الصدى.")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Spacer()
                controls
            }
            .padding()
            .navigationTitle("تعليق صوتي")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") {
                        stopPlayback()
                        recorder.cancel()
                        dismiss()
                    }
                }
            }
            .screenBackground()
            .interactiveDismissDisabled(recorder.isActive)
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch recorder.phase {
        case .countdown(let value):
            Text(String(value)).font(.system(size: 72, weight: .heavy)).foregroundStyle(Theme.Palette.textPrimary)
        case .recording:
            Image(systemName: "waveform").font(.system(size: 56, weight: .semibold)).foregroundStyle(Theme.Palette.danger)
                .symbolEffect(.variableColor.iterative, isActive: true)
        case .finished:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(Theme.Palette.success)
        case .idle:
            Image(systemName: "mic.fill").font(.system(size: 56)).foregroundStyle(Theme.Palette.textPrimary)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch recorder.phase {
        case .idle:
            Button {
                startTime = vm.currentTime
                Task {
                    await recorder.start(countIn: countIn) {
                        if playTimeline {
                            vm.player.player.isMuted = muteTimeline
                            if !vm.player.isPlaying { vm.togglePlay() }
                        }
                    }
                }
            } label: {
                Label("ابدأ التسجيل", systemImage: "record.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Palette.danger)
            .controlSize(.large)
        case .countdown, .recording:
            Button {
                stopPlayback()
                if let take = recorder.stop() {
                    vm.placeVoiceover(fileURL: take.url, at: startTime, duration: take.duration)
                    recorder.reset()
                    dismiss()
                }
            } label: {
                Label("إيقاف وإضافة", systemImage: "stop.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.Palette.accent)
            .controlSize(.large)
        case .finished:
            EmptyView()
        }
    }

    private func stopPlayback() {
        if vm.player.isPlaying { vm.togglePlay() }
        vm.player.player.isMuted = false
    }
}

// MARK: - Sound effects

struct SoundEffectsSheet: View {
    let vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var previewPlayer: AVAudioPlayer?
    @State private var playing: SoundEffect?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("مؤثرات مُولّدة على جهازك. اضغط ▶︎ للاستماع، و«إضافة» لوضعها عند رأس التشغيل في مسار المؤثرات.")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                ForEach(SoundEffectCategory.allCases) { category in
                    Section(category.title) {
                        ForEach(SoundEffect.allCases.filter { $0.category == category }) { effect in
                            HStack(spacing: 12) {
                                Button { preview(effect) } label: {
                                    Image(systemName: playing == effect ? "stop.circle.fill" : "play.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(Theme.Palette.accent)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("استماع " + effect.title)
                                Image(systemName: effect.symbol).frame(width: 24).foregroundStyle(Theme.Palette.textSecondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(effect.title).font(.subheadline.weight(.semibold))
                                    Text(Fmt.seconds(effect.duration, digits: 2)).font(.caption2).foregroundStyle(Theme.Palette.textTertiary)
                                }
                                Spacer()
                                Button("إضافة") {
                                    vm.addSoundEffect(effect)
                                    vm.env.toasts.show("تمت إضافة «" + effect.title + "»", style: .success, duration: 1.2)
                                }
                                .buttonStyle(.bordered)
                                .tint(Theme.Palette.accent)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("المؤثرات الصوتية")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() }.fontWeight(.semibold) }
            }
            .screenBackground()
            .onDisappear { previewPlayer?.stop() }
        }
        .presentationDetents([.medium, .large])
    }

    private func preview(_ effect: SoundEffect) {
        if playing == effect {
            previewPlayer?.stop()
            playing = nil
            return
        }
        Task {
            guard let url = try? await SoundEffectsLibrary.shared.previewURL(for: effect),
                  let player = try? AVAudioPlayer(contentsOf: url) else { return }
            previewPlayer?.stop()
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            player.play()
            previewPlayer = player
            playing = effect
            try? await Task.sleep(nanoseconds: UInt64((effect.duration + 0.1) * 1_000_000_000))
            if playing == effect { playing = nil }
        }
    }
}

// MARK: - Ducking

struct DuckingSheet: View {
    let vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings = DuckingSettings()
    @State private var loaded = false

    private var audioTracks: [IndexedTrack] {
        vm.timeline.tracks.enumerated().compactMap { pair -> IndexedTrack? in
            pair.element.carriesAudio && !pair.element.clips.isEmpty ? IndexedTrack(index: pair.offset, track: pair.element) : nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("تنخفض الموسيقى تلقائيًا كلما ظهر كلام في مسارات الصوت، وترجع بعده بنعومة. النتيجة نقاط مستوى صوت تقدر تعدّلها على الخط الزمني.")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Section("مسارات الكلام") {
                    ForEach(audioTracks) { pair in
                        Toggle(pair.track.name, isOn: membership(\.triggerTrackIDs, pair.track.id))
                    }
                }
                Section("مسارات الموسيقى (تُخفض)") {
                    ForEach(audioTracks.filter { $0.track.kind == .audio }) { pair in
                        Toggle(pair.track.name, isOn: membership(\.targetTrackIDs, pair.track.id))
                    }
                }
                Section("الضبط") {
                    PrecisionSlider(title: "مقدار الخفض (dB)", value: $settings.reductionDB, range: 3...30, defaultValue: 12, step: 0.5,
                                    format: { Fmt.number($0, digits: 1) })
                    PrecisionSlider(title: "حساسية الكلام (dBFS)", value: $settings.thresholdDB, range: -60 ... -10, defaultValue: -36,
                                    format: { Fmt.number($0, digits: 0) })
                    PrecisionSlider(title: "الانخفاض قبل الكلام", value: $settings.attack, range: 0.05...1.5, defaultValue: 0.25, step: 0.05,
                                    format: { Fmt.seconds($0, digits: 2) })
                    PrecisionSlider(title: "الرجوع بعد الكلام", value: $settings.release, range: 0.1...3, defaultValue: 0.6, step: 0.05,
                                    format: { Fmt.seconds($0, digits: 2) })
                    PrecisionSlider(title: "تجاهل الوقفات الأقصر من", value: $settings.hold, range: 0...2, defaultValue: 0.5, step: 0.05,
                                    format: { Fmt.seconds($0, digits: 2) })
                }
                Section {
                    Text("يستبدل نقاط مستوى الصوت الحالية في مقاطع الموسيقى. تقدر تتراجع بخطوة واحدة.")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("خفض الموسيقى تلقائيًا")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("تطبيق") {
                        vm.applyDucking(settings)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(settings.triggerTrackIDs.isEmpty || settings.targetTrackIDs.isEmpty)
                }
            }
            .screenBackground()
            .onAppear {
                guard !loaded else { return }
                settings = vm.defaultDuckingSettings()
                loaded = true
            }
        }
    }

    private func membership(_ path: WritableKeyPath<DuckingSettings, Set<UUID>>, _ id: UUID) -> Binding<Bool> {
        Binding(get: { settings[keyPath: path].contains(id) },
                set: { on in
                    if on { settings[keyPath: path].insert(id) } else { settings[keyPath: path].remove(id) }
                })
    }
}
