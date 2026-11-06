//
//  SmartToolsSheet.swift
//  ClipStudio — Features/Intelligence (Part 4)
//
//  Smart tools for one video clip, all on device:
//  • smart reframe — the crop follows faces / people / the most salient object
//    so a landscape shot fills a vertical canvas (or any canvas);
//  • object tracking — draw a box around anything, Vision follows it; reframe on
//    it or make a title / sticker move with it;
//  • stabilization — camera-shake removal with adjustable strength and zoom.
//  Part 4 suggestions: subject masks / spotlight, privacy blur that follows every
//  face, horizon leveling and a before / after comparison (SmartToolsExtras).
//

import SwiftUI
import AVFoundation

struct SmartToolsSheet: View {
    @Bindable var vm: StudioViewModel
    let clipID: UUID
    @Environment(\.dismiss) private var dismiss

    @State private var mode: SubjectMode = .auto
    @State private var smoothing: Double = 0.8
    @State private var zoom: Double = 1
    @State private var track: SubjectTrack?
    @State private var strength: Double = 0.6
    @State private var followTarget: UUID?
    @State private var selectionImage: UIImage?
    @State private var showSelection = false
    @State private var loadingFrame = false

    private var clip: Clip? { TimelineEngine.clip(clipID, in: vm.timeline) }
    private var asset: MediaAsset? { clip.flatMap { vm.asset(for: $0) } }

    private var isVideo: Bool { asset?.kind == .video }

    private var sourceAspect: Double? {
        guard let w = asset?.pixelWidth, let h = asset?.pixelHeight, h > 0 else { return nil }
        return Double(w) / Double(h)
    }

    private var canvasAspect: Double { Double(vm.canvasSize.width / max(1, vm.canvasSize.height)) }

    var body: some View {
        NavigationStack {
            Form {
                if let clip, isVideo {
                    headerSection(clip)
                    reframeSection(clip)
                    objectSection(clip)
                    if !vm.followCandidates(for: clipID).isEmpty, track != nil {
                        followSection
                    }
                    SubjectMaskSection(vm: vm, clipID: clipID, track: track)
                    PrivacyBlurSection(vm: vm, clipID: clipID)
                    stabilizationSection(clip)
                    HorizonSection(vm: vm, clipID: clipID)
                    Section {
                        NavigationLink {
                            BeforeAfterCompareView(vm: vm, clipID: clipID)
                        } label: {
                            Label("مقارنة قبل / بعد", systemImage: "rectangle.split.2x1")
                        }
                    } footer: {
                        Text("قارن الإطار الأصلي مع النتيجة بعد التثبيت وضبط الأفق وإعادة التأطير.")
                    }
                } else {
                    Section {
                        EmptyStateView(systemImage: "video.slash", title: "اختر مقطع فيديو",
                                       message: "الأدوات الذكية تعمل على مقاطع الفيديو الموجودة في المكتبة.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .studioBusyOverlay(vm)
            .navigationTitle("أدوات ذكية")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } }
            }
            .navigationDestination(isPresented: $showSelection) {
                if let image = selectionImage {
                    ObjectSelectionView(image: image) { rect in
                        showSelection = false
                        Task {
                            if let result = await vm.trackObject(clipID: clipID, initial: rect) {
                                track = result
                            }
                        }
                    }
                }
            }
            .onAppear {
                if let settings = clip?.stabilization { strength = settings.strength }
                if let span = clip.flatMap(vm.sourceSpan(of:)), let id = clip?.mediaAssetID {
                    track = SubjectTracker.anyCached(assetID: id, span: span)
                }
            }
        }
    }

    // MARK: Sections

    private func headerSection(_ clip: Clip) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.title2)
                    .foregroundStyle(Theme.accentGradient)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.Palette.accentSoft))
                VStack(alignment: .leading, spacing: 3) {
                    Text(clip.name).font(.headline).lineLimit(1)
                    Text((asset?.resolutionText ?? "—") + " • " + Fmt.durationPrecise(clip.duration.seconds))
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Label("كل التحليل يتم على جهازك عبر Vision — لا يُرفع أي شيء.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private func reframeSection(_ clip: Clip) -> some View {
        Section {
            Picker("العنصر", selection: $mode) {
                ForEach([SubjectMode.auto, .faces, .people, .salient], id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            PrecisionSlider(title: "نعومة حركة الكاميرا", value: $smoothing, range: 0.2...2.5, defaultValue: 0.8, step: 0.05,
                            format: { Fmt.seconds($0, digits: 2) })
            PrecisionSlider(title: "تقريب على العنصر", value: $zoom, range: 1...2.5, defaultValue: 1, step: 0.05,
                            format: { Fmt.number($0, digits: 2) + "×" })
            if let sourceAspect, abs(sourceAspect - canvasAspect) < 0.02, zoom < 1.01 {
                Text("المقطع بنفس مقاس اللوحة — زد التقريب ليظهر أثر التتبع.")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.warning)
            }
            Button {
                Task {
                    if let result = await vm.detectSubject(clipID: clipID, mode: mode) {
                        track = result
                        if result.coverage >= 0.05 {
                            vm.applyReframe(clipID: clipID, track: result, zoom: zoom, smoothing: smoothing)
                        }
                    }
                }
            } label: {
                Label("تحليل وتتبع العنصر", systemImage: "viewfinder")
            }
            .disabled(vm.busy != nil)
            if let track, track.mode != .object {
                Button {
                    vm.applyReframe(clipID: clipID, track: track, zoom: zoom, smoothing: smoothing)
                } label: {
                    Label("إعادة التطبيق بالإعدادات الحالية", systemImage: "arrow.clockwise")
                }
                LabeledContent("تغطية العنصر", value: Fmt.percent(track.coverage))
            }
            HStack {
                Button("قص من الوسط") { vm.centerReframe(clipID: clipID) }
                    .buttonStyle(.bordered)
                Spacer()
                Button("إلغاء القص", role: .destructive) { vm.clearReframe(clipID: clipID) }
                    .buttonStyle(.bordered)
                    .disabled(clip.crop.base.isFull && !clip.crop.isAnimated)
            }
        } header: {
            Text("إعادة التأطير الذكية")
        } footer: {
            Text("يملأ المقطع اللوحة (" + vm.settings.aspect.title + ") والكاميرا الافتراضية تتبع الوجه أو الشخص أو أبرز عنصر بنعومة. النتيجة إطارات مفتاحية للقص تقدر تعدّلها.")
        }
    }

    private func objectSection(_ clip: Clip) -> some View {
        Section {
            Button {
                loadingFrame = true
                Task {
                    selectionImage = await vm.objectSelectionFrame(clipID: clipID)
                    loadingFrame = false
                    if selectionImage != nil { showSelection = true }
                }
            } label: {
                HStack {
                    Label("ارسم مربعًا حول العنصر", systemImage: "rectangle.dashed")
                    Spacer()
                    if loadingFrame { ProgressView() }
                }
            }
            .disabled(vm.busy != nil || loadingFrame)
            if let track, track.mode == .object {
                LabeledContent("مدة التتبع", value: Fmt.percent(track.coverage))
                Button {
                    vm.applyReframe(clipID: clipID, track: track, zoom: max(zoom, 1.2), smoothing: smoothing)
                } label: {
                    Label("إعادة التأطير على العنصر", systemImage: "crop")
                }
            }
        } header: {
            Text("تتبع عنصر تختاره")
        } footer: {
            Text("ترسم المربع على أول إطار في المقطع، ويتتبعه Vision إطارًا بإطار. إذا اختفى العنصر يُثبت آخر موضع.")
        }
    }

    private var followSection: some View {
        Section {
            Picker("الطبقة", selection: $followTarget) {
                Text("اختر").tag(UUID?.none)
                ForEach(vm.followCandidates(for: clipID)) { candidate in
                    Text(candidate.name).tag(Optional(candidate.id))
                }
            }
            Button {
                if let followTarget, let track {
                    vm.followSubject(overlayID: followTarget, baseClipID: clipID, track: track, smoothing: max(0.2, smoothing * 0.5))
                }
            } label: {
                Label("اجعلها تتبع العنصر", systemImage: "point.forward.to.point.capsulepath")
            }
            .disabled(followTarget == nil)
        } header: {
            Text("نص أو ملصق يتبع العنصر")
        } footer: {
            Text("تحافظ الطبقة على مسافتها الحالية من العنصر وتتحرك معه.")
        }
    }

    private func stabilizationSection(_ clip: Clip) -> some View {
        Section {
            if let settings = clip.stabilization {
                Toggle("التثبيت مفعّل", isOn: Binding(get: { settings.isEnabled },
                                                       set: { value in vm.setStabilization(clipID: clipID) { $0.isEnabled = value }; vm.endContinuousEdit() }))
                PrecisionSlider(title: "القوة", value: Binding(get: { settings.strength },
                                                              set: { value in vm.setStabilization(clipID: clipID) { $0.strength = value } }),
                                range: 0...1, defaultValue: 0.6, step: 0.01, format: { Fmt.percent($0) },
                                onEditingChanged: { if !$0 { vm.endContinuousEdit() } })
                PrecisionSlider(title: "التكبير لإخفاء الحواف", value: Binding(get: { settings.zoom },
                                                                               set: { value in vm.setStabilization(clipID: clipID) { $0.zoom = value } }),
                                range: 1...1.5, defaultValue: 1.08, step: 0.005, format: { Fmt.number($0, digits: 3) + "×" },
                                onEditingChanged: { if !$0 { vm.endContinuousEdit() } })
                HStack {
                    Button("التكبير المقترح") {
                        if let suggested = vm.suggestedStabilizationZoom(clipID: clipID) {
                            vm.setStabilization(clipID: clipID) { $0.zoom = suggested }
                            vm.endContinuousEdit()
                        }
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("إزالة التثبيت", role: .destructive) { vm.removeStabilization(clipID: clipID) }
                        .buttonStyle(.bordered)
                }
            } else {
                PrecisionSlider(title: "القوة", value: $strength, range: 0...1, defaultValue: 0.6, step: 0.01, format: { Fmt.percent($0) })
                Button {
                    vm.stabilize(clipID: clipID, strength: strength)
                } label: {
                    Label("ثبّت الفيديو", systemImage: "camera.metering.center.weighted")
                }
                .disabled(vm.busy != nil || !clip.speed.ramp.isEmpty)
            }
        } header: {
            Text("تثبيت الفيديو")
        } footer: {
            Text("يحلل حركة الكاميرا مرة واحدة لكل ملف، ثم يزيل الاهتزاز مع الاحتفاظ بحركة الكاميرا المقصودة. تغيير القوة فوري بدون تحليل جديد.")
        }
    }
}

// MARK: - Object selection

struct ObjectSelectionView: View {
    let image: UIImage
    let onConfirm: (RectValue) -> Void
    @State private var box: CGRect = .zero
    @State private var normalized: RectValue?

    var body: some View {
        VStack(spacing: 14) {
            Text("اسحب لرسم مربع حول العنصر الذي تريد تتبعه")
                .font(.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
            GeometryReader { geo in
                let frame = AVMakeRect(aspectRatio: image.size, insideRect: CGRect(origin: .zero, size: geo.size))
                ZStack(alignment: .topLeading) {
                    Color.black
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                    if box.width > 4, box.height > 4 {
                        Rectangle()
                            .fill(Theme.Palette.accent.opacity(0.18))
                            .overlay(Rectangle().strokeBorder(Theme.Palette.accent, lineWidth: 2))
                            .frame(width: box.width, height: box.height)
                            .position(x: box.midX, y: box.midY)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            let a = clamped(value.startLocation, to: frame)
                            let b = clamped(value.location, to: frame)
                            box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                            normalized = RectValue(x: Double((box.minX - frame.minX) / frame.width),
                                                   y: Double((box.minY - frame.minY) / frame.height),
                                                   width: Double(box.width / frame.width),
                                                   height: Double(box.height / frame.height))
                        }
                )
            }
            .environment(\.layoutDirection, .leftToRight)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            Button {
                if let normalized { onConfirm(normalized) }
            } label: {
                Label("تتبع هذا العنصر", systemImage: "scope")
            }
            .buttonStyle(.csPrimary)
            .disabled((normalized?.width ?? 0) < 0.02 || (normalized?.height ?? 0) < 0.02)
        }
        .padding(Theme.Space.md)
        .screenBackground()
        .navigationTitle("اختيار العنصر")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func clamped(_ point: CGPoint, to frame: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, frame.minX), frame.maxX), y: min(max(point.y, frame.minY), frame.maxY))
    }
}
