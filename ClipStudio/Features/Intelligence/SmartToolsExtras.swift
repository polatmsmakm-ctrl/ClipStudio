//
//  SmartToolsExtras.swift
//  ClipStudio — Features/Intelligence (Part 4 suggestions)
//
//  Extra sections of the smart tools sheet:
//  • SubjectMaskSection — a mask that follows the tracked subject, or a spotlight
//    (background black & white, subject in color);
//  • PrivacyBlurSection — blur / pixelate every face, each following its motion;
//  • HorizonSection — level a tilted horizon;
//  • BeforeAfterCompareView — original frame vs. the result, side by side or split.
//

import SwiftUI
import CoreImage

struct SubjectMaskSection: View {
    @Bindable var vm: StudioViewModel
    let clipID: UUID
    let track: SubjectTrack?
    @State private var padding: Double = 1.4
    @State private var invert = false

    private var clip: Clip? { TimelineEngine.clip(clipID, in: vm.timeline) }

    var body: some View {
        Section {
            if let track {
                PrecisionSlider(title: "حجم القناع حول العنصر", value: $padding, range: 0.8...3, defaultValue: 1.4, step: 0.05,
                                format: { Fmt.number($0, digits: 2) + "×" })
                Toggle("عكس القناع (إخفاء العنصر)", isOn: $invert)
                Button {
                    vm.applySubjectMask(clipID: clipID, track: track, padding: padding, invert: invert)
                } label: {
                    Label("قناع يتبع العنصر", systemImage: "circle.dashed.inset.filled")
                }
                Button {
                    vm.addSpotlight(clipID: clipID, track: track, padding: max(padding, 1.6))
                } label: {
                    Label("إبراز العنصر (الخلفية أبيض وأسود)", systemImage: "circle.lefthalf.filled")
                }
                if clip?.mask?.followsSubject == true {
                    Button(role: .destructive) { vm.removeSubjectMask(clipID: clipID) } label: {
                        Label("إيقاف تتبع القناع", systemImage: "xmark.circle")
                    }
                }
            } else {
                Text("حلّل العنصر أو تتبّع عنصرًا تختاره أولاً (من الأقسام أعلاه).")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        } header: {
            Text("قناع يتبع العنصر")
        } footer: {
            Text("التأثيرات والألوان تنطبق على العنصر فقط والقناع يتحرك معه. الإبراز يضيف نسخة صامتة فوق المقطع.")
        }
    }
}

struct PrivacyBlurSection: View {
    @Bindable var vm: StudioViewModel
    let clipID: UUID
    @State private var faces: [SubjectTrack] = []
    @State private var selected: Set<Int> = []
    @State private var style: PrivacyStyle = .pixelate
    @State private var amount: Double = 0.8
    @State private var padding: Double = 1.6
    @State private var analyzed = false

    var body: some View {
        Section {
            if !analyzed {
                Button {
                    Task {
                        if let result = await vm.detectFaces(clipID: clipID) {
                            faces = result
                            selected = Set(result.indices)
                            analyzed = true
                        }
                    }
                } label: {
                    Label("ابحث عن الوجوه", systemImage: "person.crop.circle.badge.questionmark")
                }
                .disabled(vm.busy != nil)
            } else if faces.isEmpty {
                Text("لا توجد وجوه في هذا المقطع.").foregroundStyle(Theme.Palette.textSecondary)
            } else {
                ForEach(faces.indices, id: \.self) { index in
                    let face = faces[index]
                    Toggle(isOn: Binding(get: { selected.contains(index) },
                                         set: { if $0 { selected.insert(index) } else { selected.remove(index) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("وجه " + Fmt.int(index + 1))
                            Text(Fmt.durationPrecise(face.samples.first?.time ?? 0) + " ← "
                                 + Fmt.durationPrecise(face.samples.last?.time ?? 0) + " (من الملف)")
                                .font(.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                }
                Picker("النوع", selection: $style) {
                    ForEach(PrivacyStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                PrecisionSlider(title: "القوة", value: $amount, range: 0.2...1, defaultValue: 0.8, step: 0.05, format: { Fmt.percent($0) })
                PrecisionSlider(title: "حجم المنطقة", value: $padding, range: 1...3, defaultValue: 1.6, step: 0.05,
                                format: { Fmt.number($0, digits: 2) + "×" })
                Button {
                    let chosen = faces.indices.filter { selected.contains($0) }.map { faces[$0] }
                    vm.addPrivacyBlur(clipID: clipID, tracks: chosen, style: style, amount: amount, padding: padding)
                } label: {
                    Label("موّه الوجوه المختارة", systemImage: "eye.slash")
                }
                .disabled(selected.isEmpty)
            }
        } header: {
            Text("تمويه الوجوه للخصوصية")
        } footer: {
            Text("كل وجه يُتتبع وحده، والتمويه يتحرك معه ويختفي إذا خرج الوجه. لعنصر آخر (لوحة سيارة مثلًا) استخدم «تتبع عنصر تختاره» ثم «قناع يتبع العنصر» مع عكس… أو أضف تمويه من التأثيرات على نسخة بالقناع.")
        }
    }
}

struct HorizonSection: View {
    @Bindable var vm: StudioViewModel
    let clipID: UUID
    @State private var strength: Double = 1

    private var clip: Clip? { TimelineEngine.clip(clipID, in: vm.timeline) }

    var body: some View {
        Section {
            if let settings = clip?.horizon {
                Toggle("ضبط الأفق مفعّل", isOn: Binding(get: { settings.isEnabled },
                                                       set: { value in vm.setHorizon(clipID: clipID) { $0.isEnabled = value }; vm.endContinuousEdit() }))
                PrecisionSlider(title: "القوة", value: Binding(get: { settings.strength },
                                                              set: { value in vm.setHorizon(clipID: clipID) { $0.strength = value } }),
                                range: 0...1, defaultValue: 1, step: 0.01, format: { Fmt.percent($0) },
                                onEditingChanged: { if !$0 { vm.endContinuousEdit() } })
                PrecisionSlider(title: "النعومة", value: Binding(get: { settings.smoothing },
                                                                set: { value in vm.setHorizon(clipID: clipID) { $0.smoothing = value } }),
                                range: 0...3, defaultValue: 0.6, step: 0.05, format: { Fmt.seconds($0, digits: 2) },
                                onEditingChanged: { if !$0 { vm.endContinuousEdit() } })
                Button("إزالة ضبط الأفق", role: .destructive) { vm.removeHorizon(clipID: clipID) }
            } else {
                PrecisionSlider(title: "القوة", value: $strength, range: 0...1, defaultValue: 1, step: 0.01, format: { Fmt.percent($0) })
                Button {
                    vm.levelHorizon(clipID: clipID, strength: strength)
                } label: {
                    Label("اضبط الأفق", systemImage: "level")
                }
                .disabled(vm.busy != nil)
            }
        } header: {
            Text("ضبط الأفق")
        } footer: {
            Text("يقيس ميلان الأفق ويدوّر الصورة بالعكس مع تكبير بسيط يخفي الزوايا.")
        }
    }
}

// MARK: - Before / after

struct BeforeAfterCompareView: View {
    @Bindable var vm: StudioViewModel
    let clipID: UUID
    @State private var time: Double = 0
    @State private var before: UIImage?
    @State private var after: UIImage?
    @State private var split: Double = 0.5
    @State private var sideBySide = false
    @State private var renderTask: Task<Void, Never>?

    private var clip: Clip? { TimelineEngine.clip(clipID, in: vm.timeline) }

    private var previewCanvas: CGSize {
        let canvas = vm.canvasSize
        let scale = min(1, 720 / max(canvas.width, canvas.height))
        return CGSize(width: (canvas.width * scale).rounded(), height: (canvas.height * scale).rounded())
    }

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            Picker("العرض", selection: $sideBySide) {
                Text("خط فاصل").tag(false)
                Text("جنبًا إلى جنب").tag(true)
            }
            .pickerStyle(.segmented)
            Group {
                if sideBySide {
                    HStack(spacing: 8) {
                        panel(before, title: "قبل")
                        panel(after, title: "بعد")
                    }
                } else {
                    splitView
                }
            }
            .frame(maxHeight: .infinity)
            if let clip {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Fmt.durationPrecise(time)).font(Theme.Typo.mono).foregroundStyle(Theme.Palette.textSecondary)
                    Slider(value: $time, in: 0...max(0.01, clip.duration.seconds), onEditingChanged: { editing in
                        if !editing { render() }
                    })
                    .environment(\.layoutDirection, .leftToRight)
                }
            }
        }
        .padding(Theme.Space.md)
        .screenBackground()
        .navigationTitle("قبل / بعد")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let clip {
                let local = vm.currentTime - clip.start.seconds
                time = (0...clip.duration.seconds).contains(local) ? local : clip.duration.seconds / 2
            }
            render()
        }
        .onDisappear { renderTask?.cancel() }
    }

    private func panel(_ image: UIImage?, title: String) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
            Text(title).font(.caption.weight(.bold)).padding(6).background(Capsule().fill(.black.opacity(0.55))).padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
    }

    private var splitView: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let after {
                    Image(uiImage: after).resizable().scaledToFit()
                }
                if let before {
                    Image(uiImage: before).resizable().scaledToFit()
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: geo.size.width * split)
                        }
                }
                Rectangle()
                    .fill(Theme.Palette.accent)
                    .frame(width: 2)
                    .position(x: geo.size.width * split, y: geo.size.height / 2)
                HStack {
                    Text("قبل").font(.caption.weight(.bold)).padding(6).background(Capsule().fill(.black.opacity(0.55)))
                    Spacer()
                    Text("بعد").font(.caption.weight(.bold)).padding(6).background(Capsule().fill(.black.opacity(0.55)))
                }
                .padding(8)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                split = min(1, max(0, value.location.x / max(1, geo.size.width)))
            })
        }
        .environment(\.layoutDirection, .leftToRight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
    }

    /// Renders the source frame (before) and the processed layer on the canvas (after).
    private func render() {
        guard let clip else { return }
        renderTask?.cancel()
        let media = vm.env.library.urlMap()
        let canvas = previewCanvas
        let local = time
        renderTask = Task {
            if let stabilization = clip.stabilization { StabilizationStore.shared.preload([stabilization.assetID]) }
            if let horizon = clip.horizon { HorizonStore.shared.preload([horizon.assetID]) }
            guard let source = await FramePreviewRenderer.shared.sourceFrame(for: clip, localTime: local, media: media,
                                                                           canvas: canvas, maxDimension: 900) else { return }
            if Task.isCancelled { return }
            var plain = clip
            plain.stabilization = nil
            plain.horizon = nil
            plain.crop = KeyframedValue(RectValue.full)
            plain.fitMode = .fit
            let canvasRect = CGRect(origin: .zero, size: canvas)
            let black = CIImage(color: .black).cropped(to: canvasRect)
            let beforeImage = LayerRenderer.render(source: source, clip: plain, role: .media, localTime: local,
                                                   clipDuration: clip.duration.seconds, canvas: canvas)
                .composited(over: black).cropped(to: canvasRect)
            let afterImage = LayerRenderer.render(source: source, clip: clip, role: .media, localTime: local,
                                                  clipDuration: clip.duration.seconds, canvas: canvas)
                .composited(over: black).cropped(to: canvasRect)
            let renderedBefore = FramePreviewRenderer.shared.uiImage(beforeImage)
            let renderedAfter = FramePreviewRenderer.shared.uiImage(afterImage)
            if Task.isCancelled { return }
            before = renderedBefore
            after = renderedAfter
        }
    }
}
