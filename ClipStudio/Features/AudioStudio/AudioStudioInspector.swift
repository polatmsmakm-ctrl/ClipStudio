//
//  AudioStudioInspector.swift
//  ClipStudio — Features/AudioStudio (Part 3)
//
//  The clip "Audio" inspector tab: mute, keyframable volume, gain up to +24 dB,
//  fades, balance, quick presets, 5-band parametric EQ with an interactive response
//  graph, high-pass, noise reduction, voice enhancement, compressor, limiter,
//  loudness normalization, audio extraction and detach. Effect changes are heard
//  immediately during playback (live processing parameters).
//

import SwiftUI

struct AudioInspector: View {
    let vm: StudioViewModel
    let clipID: UUID

    @State private var showEQ = false
    @State private var showDynamics = false

    private var editor: ClipEditor { ClipEditor(vm: vm, clipID: clipID) }

    var body: some View {
        if let clip = editor.clip {
            let hasAudio = vm.asset(for: clip).map { $0.hasAudio || $0.kind == .audio } ?? false
            VStack(spacing: 12) {
                if !hasAudio {
                    InspectorSection(title: "الصوت", systemImage: "speaker.slash") {
                        Text("هذا المقطع بدون صوت.").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    }
                } else {
                    levelSection(clip)
                    presetsSection(clip)
                    eqSection(clip)
                    cleanupSection(clip)
                    dynamicsSection(clip)
                    actionsSection(clip)
                }
            }
        }
    }

    // MARK: Bindings

    private func effect(_ name: String, key: String, _ path: WritableKeyPath<AudioEffects, Double>) -> Binding<Double> {
        editor.binding(name, key: "fx-" + key, read: { $0.audio.effects[keyPath: path] },
                       write: { $0.audio.effects[keyPath: path] = $1 })
    }

    private func effectToggle(_ name: String, _ path: WritableKeyPath<AudioEffects, Bool>) -> Binding<Bool> {
        Binding(get: { editor.clip?.audio.effects[keyPath: path] ?? false },
                set: { value in
                    editor.update(name, key: "fx-toggle-" + name) { $0.audio.effects[keyPath: path] = value }
                    vm.endContinuousEdit()
                })
    }

    // MARK: Sections

    private func levelSection(_ clip: Clip) -> some View {
        InspectorSection(title: "المستوى", systemImage: "speaker.wave.2") {
            Toggle(isOn: Binding(get: { clip.audio.isMuted }, set: { value in
                editor.update("كتم الصوت", key: "mute") { $0.audio.isMuted = value }
                vm.endContinuousEdit()
            })) {
                Label("كتم صوت المقطع", systemImage: "speaker.slash")
            }
            .tint(Theme.Palette.accent)
            PrecisionSlider(title: "مستوى الصوت", value: editor.keyframed("مستوى الصوت", key: "volume", \Clip.audio.volume),
                            range: 0...1, defaultValue: 1,
                            format: { Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                            keyframe: editor.keyframeControl(.volume), onEditingChanged: editor.editingChanged)
            PrecisionSlider(title: "تضخيم (dB)", value: effect("تضخيم الصوت", key: "gain", \.gainDB),
                            range: -24...24, defaultValue: 0, step: 0.5,
                            format: { ($0 > 0 ? "+" : "") + Fmt.number($0, digits: 1) }, onEditingChanged: editor.editingChanged)
            PrecisionSlider(title: "التوازن", value: effect("توازن الصوت", key: "pan", \.pan),
                            range: -1...1, defaultValue: 0,
                            format: { value in
                                if abs(value) < 0.01 { return "وسط" }
                                return (value < 0 ? "يسار " : "يمين ") + Fmt.number(abs(value) * 100, digits: 0)
                            }, onEditingChanged: editor.editingChanged)
            let fadeLimit = max(0.1, min(10, clip.duration.seconds / 2))
            PrecisionSlider(title: "تلاشي الدخول", value: editor.binding("تلاشي الدخول", key: "fade-in",
                                                                          read: { $0.audio.fadeIn },
                                                                          write: { $0.audio.fadeIn = min($1, $0.duration.seconds / 2) }),
                            range: 0...fadeLimit, defaultValue: 0, step: 0.05,
                            format: { Fmt.seconds($0, digits: 2) }, onEditingChanged: editor.editingChanged)
            PrecisionSlider(title: "تلاشي الخروج", value: editor.binding("تلاشي الخروج", key: "fade-out",
                                                                          read: { $0.audio.fadeOut },
                                                                          write: { $0.audio.fadeOut = min($1, $0.duration.seconds / 2) }),
                            range: 0...fadeLimit, defaultValue: 0, step: 0.05,
                            format: { Fmt.seconds($0, digits: 2) }, onEditingChanged: editor.editingChanged)
            Toggle(isOn: Binding(get: { vm.showsVolumeAutomation }, set: { vm.showsVolumeAutomation = $0 })) {
                Label("رسم مستوى الصوت على الخط الزمني", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            }
            .tint(Theme.Palette.accent)
            .font(.subheadline)
        }
    }

    private func presetsSection(_ clip: Clip) -> some View {
        InspectorSection(title: "إعدادات سريعة", systemImage: "wand.and.stars") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AudioEffectPreset.allCases) { preset in
                        ChipButton(title: preset.title, systemImage: preset.symbol, isSelected: false) {
                            vm.applyAudioPreset(preset, clipID: clipID)
                        }
                    }
                }
            }
            if !clip.audio.effects.activeNames.isEmpty {
                Text("مفعّل: " + clip.audio.effects.activeNames.joined(separator: " • "))
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func eqSection(_ clip: Clip) -> some View {
        InspectorSection(title: "المعادل (EQ)", systemImage: "slider.vertical.3",
                         trailing: AnyView(Toggle("", isOn: effectToggle("المعادل", \.eqEnabled)).labelsHidden().tint(Theme.Palette.accent))) {
            EQGraphView(effects: clip.audio.effects) { index, frequency, gain in
                editor.update("المعادل", key: "fx-eq-drag-" + String(index)) { c in
                    c.audio.effects.eqEnabled = true
                    c.audio.effects.eq[index].frequency = frequency
                    c.audio.effects.eq[index].gainDB = gain
                }
            } onEnd: {
                vm.endContinuousEdit()
            }
            .frame(height: 150)
            DisclosureGroup("ضبط الحزم بدقة", isExpanded: $showEQ) {
                ForEach(clip.audio.effects.eq) { band in
                    VStack(spacing: 4) {
                        PrecisionSlider(title: band.title + " (dB)",
                                        value: editor.binding("المعادل", key: "eq-gain-" + String(band.id),
                                                              read: { $0.audio.effects.eq[band.id].gainDB },
                                                              write: { clip, value in
                                                                  clip.audio.effects.eqEnabled = true
                                                                  clip.audio.effects.eq[band.id].gainDB = value
                                                              }),
                                        range: -15...15, defaultValue: 0, step: 0.5,
                                        format: { ($0 > 0 ? "+" : "") + Fmt.number($0, digits: 1) },
                                        onEditingChanged: editor.editingChanged)
                        PrecisionSlider(title: "التردد (Hz)",
                                        value: editor.binding("المعادل", key: "eq-freq-" + String(band.id),
                                                              read: { $0.audio.effects.eq[band.id].frequency },
                                                              write: { $0.audio.effects.eq[band.id].frequency = $1 }),
                                        range: band.frequencyRange, defaultValue: EQBand.defaults[band.id].frequency,
                                        format: { EQGraphView.frequencyText($0) }, onEditingChanged: editor.editingChanged)
                        if band.kind == .peak {
                            PrecisionSlider(title: "العرض (Q)",
                                            value: editor.binding("المعادل", key: "eq-q-" + String(band.id),
                                                                  read: { $0.audio.effects.eq[band.id].q },
                                                                  write: { $0.audio.effects.eq[band.id].q = $1 }),
                                            range: 0.3...6, defaultValue: 1, step: 0.05,
                                            format: { Fmt.number($0, digits: 2) }, onEditingChanged: editor.editingChanged)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Button("تصفير المعادل") {
                    editor.update("تصفير المعادل", key: "eq-reset") { $0.audio.effects.eq = EQBand.defaults }
                    vm.endContinuousEdit()
                }
                .font(.caption.weight(.semibold))
            }
            .font(.subheadline)
        }
    }

    private func cleanupSection(_ clip: Clip) -> some View {
        InspectorSection(title: "تنظيف الصوت", systemImage: "wind") {
            PrecisionSlider(title: "إزالة الضوضاء", value: effect("إزالة الضوضاء", key: "nr", \.noiseReduction),
                            range: 0...1, defaultValue: 0,
                            format: { $0 < 0.001 ? "إيقاف" : Fmt.number($0 * 100, digits: 0) + "%" }, displayScale: 100,
                            onEditingChanged: editor.editingChanged)
            PrecisionSlider(title: "قطع الترددات المنخفضة", value: effect("قطع المنخفض", key: "hpf", \.highPassHz),
                            range: 0...400, defaultValue: 0, step: 5,
                            format: { $0 < 1 ? "إيقاف" : Fmt.number($0, digits: 0) + " Hz" },
                            onEditingChanged: editor.editingChanged)
            Toggle(isOn: effectToggle("تحسين الصوت", \.voiceEnhance)) {
                Label("تحسين وضوح الكلام", systemImage: "person.wave.2")
            }
            .tint(Theme.Palette.accent)
            Text("تقليل الضوضاء يتعلّم صوت الخلفية تلقائيًا خلال أول ثانية من المقطع ويعمل على جهازك.")
                .font(.caption2)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private func dynamicsSection(_ clip: Clip) -> some View {
        InspectorSection(title: "الديناميكية", systemImage: "waveform.path.ecg",
                         trailing: AnyView(Toggle("", isOn: effectToggle("الضاغط", \.compressorEnabled)).labelsHidden().tint(Theme.Palette.accent))) {
            DisclosureGroup("الضاغط", isExpanded: $showDynamics) {
                PrecisionSlider(title: "العتبة (dB)", value: compressor("العتبة", key: "threshold", \.thresholdDB),
                                range: -50...0, defaultValue: -20, format: { Fmt.number($0, digits: 1) },
                                onEditingChanged: editor.editingChanged)
                PrecisionSlider(title: "النسبة", value: compressor("النسبة", key: "ratio", \.ratio),
                                range: 1...20, defaultValue: 3, step: 0.1, format: { Fmt.number($0, digits: 1) + ":1" },
                                onEditingChanged: editor.editingChanged)
                PrecisionSlider(title: "الهجوم (ms)", value: compressor("الهجوم", key: "attack", \.attackMS),
                                range: 0.5...100, defaultValue: 10, format: { Fmt.number($0, digits: 1) },
                                onEditingChanged: editor.editingChanged)
                PrecisionSlider(title: "التحرير (ms)", value: compressor("التحرير", key: "release", \.releaseMS),
                                range: 20...1000, defaultValue: 150, format: { Fmt.number($0, digits: 0) },
                                onEditingChanged: editor.editingChanged)
                PrecisionSlider(title: "التعويض (dB)", value: compressor("التعويض", key: "makeup", \.makeupDB),
                                range: 0...24, defaultValue: 3, step: 0.5, format: { Fmt.number($0, digits: 1) },
                                onEditingChanged: editor.editingChanged)
            }
            .font(.subheadline)
            Toggle(isOn: effectToggle("المحدّد", \.limiter)) {
                Label("منع التشويش (محدّد عند −1 dB)", systemImage: "rectangle.compress.vertical")
            }
            .tint(Theme.Palette.accent)
        }
    }

    private func compressor(_ name: String, key: String, _ path: WritableKeyPath<CompressorSettings, Double>) -> Binding<Double> {
        editor.binding(name, key: "comp-" + key, read: { $0.audio.effects.compressor[keyPath: path] },
                       write: { clip, value in
                           clip.audio.effects.compressorEnabled = true
                           clip.audio.effects.compressor[keyPath: path] = value
                       })
    }

    private func actionsSection(_ clip: Clip) -> some View {
        InspectorSection(title: "أدوات", systemImage: "wrench.and.screwdriver") {
            Menu {
                ForEach(LoudnessTarget.allCases) { target in
                    Button(target.title) {
                        if !vm.selection.contains(clipID) { vm.select(clipID) }
                        vm.normalizeLoudness(target: target)
                    }
                }
            } label: {
                Label("تسوية مستوى الصوت (LUFS)", systemImage: "chart.bar.xaxis").frame(maxWidth: .infinity)
            }
            .buttonStyle(.csSecondary)
            Button { vm.extractAudio(clipID: clipID) } label: {
                Label("استخراج الصوت إلى ملف", systemImage: "square.and.arrow.down.on.square").frame(maxWidth: .infinity)
            }
            .buttonStyle(.csSecondary)
            if let track = vm.track(of: clipID), track.kind.isVisual {
                Button {
                    vm.select(clipID)
                    vm.detachAudio()
                } label: {
                    Label("فصل الصوت إلى مسار مستقل", systemImage: "waveform.badge.minus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.csSecondary)
            }
            Button { vm.activeSheet = .mixer } label: {
                Label("المكسر", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
            }
            .buttonStyle(.csSecondary)
        }
    }
}

// MARK: - EQ graph

/// Response curve of the clip's EQ (+ high-pass) with draggable band handles.
struct EQGraphView: View {
    let effects: AudioEffects
    let onChange: (Int, Double, Double) -> Void
    let onEnd: () -> Void

    private static let minFrequency = 20.0
    private static let maxFrequency = 20_000.0
    private static let range = 18.0
    private static let sampleRate = 48_000.0

    static func frequencyText(_ value: Double) -> String {
        value >= 1000 ? Fmt.number(value / 1000, digits: value >= 10_000 ? 0 : 1) + " kHz" : Fmt.number(value, digits: 0) + " Hz"
    }

    private func x(for frequency: Double, width: CGFloat) -> CGFloat {
        let t = log10(frequency / Self.minFrequency) / log10(Self.maxFrequency / Self.minFrequency)
        return CGFloat(t) * width
    }

    private func frequency(at x: CGFloat, width: CGFloat) -> Double {
        let t = Double(min(max(x / max(width, 1), 0), 1))
        return Self.minFrequency * pow(Self.maxFrequency / Self.minFrequency, t)
    }

    private func y(for gain: Double, height: CGFloat) -> CGFloat {
        CGFloat(0.5 - gain / (2 * Self.range)) * height
    }

    private func response(at frequency: Double) -> Double {
        var total = 0.0
        if effects.eqEnabled {
            for band in effects.eq where abs(band.gainDB) > 0.05 {
                total += BiquadCoefficients.band(band, sampleRate: Self.sampleRate).magnitudeDB(at: frequency, sampleRate: Self.sampleRate)
            }
        }
        if effects.highPassHz >= 1 {
            total += BiquadCoefficients.highPass(frequency: effects.highPassHz, sampleRate: Self.sampleRate)
                .magnitudeDB(at: frequency, sampleRate: Self.sampleRate)
        }
        return total
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35))
                // Grid
                Path { path in
                    for f in [100.0, 1_000, 10_000] {
                        let gx = x(for: f, width: w)
                        path.move(to: CGPoint(x: gx, y: 0))
                        path.addLine(to: CGPoint(x: gx, y: h))
                    }
                    for g in [-12.0, 0, 12] {
                        let gy = y(for: g, height: h)
                        path.move(to: CGPoint(x: 0, y: gy))
                        path.addLine(to: CGPoint(x: w, y: gy))
                    }
                }
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                // Curve
                Path { path in
                    let steps = 120
                    for step in 0...steps {
                        let px = CGFloat(step) / CGFloat(steps) * w
                        let gain = min(Self.range, max(-Self.range, response(at: frequency(at: px, width: w))))
                        let point = CGPoint(x: px, y: y(for: gain, height: h))
                        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(effects.eqEnabled || effects.highPassHz >= 1 ? Theme.Palette.accent : Theme.Palette.textTertiary, lineWidth: 2)
                // Handles
                ForEach(effects.eq) { band in
                    Circle()
                        .fill(effects.eqEnabled ? Theme.Palette.accent : Theme.Palette.textTertiary)
                        .frame(width: 16, height: 16)
                        .overlay(Text(String(band.id + 1)).font(.system(size: 9, weight: .bold)).foregroundStyle(Color.black))
                        .position(x: x(for: band.frequency, width: w), y: y(for: band.gainDB, height: h))
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let range = band.frequencyRange
                                let f = min(max(frequency(at: value.location.x, width: w), range.lowerBound), range.upperBound)
                                let g = min(max((0.5 - Double(value.location.y / max(h, 1))) * 2 * Self.range, -15), 15)
                                onChange(band.id, (f).rounded(), (g * 2).rounded() / 2)
                            }
                            .onEnded { _ in onEnd() })
                        .accessibilityLabel(band.title)
                }
                // Labels
                HStack {
                    Text("20 Hz")
                    Spacer()
                    Text("1 kHz")
                    Spacer()
                    Text("20 kHz")
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.horizontal, 6)
                .frame(width: w, height: h, alignment: .bottom)
                .padding(.bottom, 2)
            }
            .environment(\.layoutDirection, .leftToRight)
        }
    }
}
