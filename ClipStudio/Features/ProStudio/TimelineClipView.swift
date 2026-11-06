//
//  TimelineClipView.swift
//  ClipStudio — Features/ProStudio
//
//  One clip on the timeline: filmstrip thumbnails (only the visible part is drawn,
//  so very long clips at high zoom stay cheap), audio waveform, badges (speed,
//  reverse, nested sequence, transition, disabled), keyframe ticks, fades, trim
//  handles, and its gestures: tap to select / blade-cut, drag a selected clip to move
//  it (in time and between tracks), drag the edges to trim, double-tap to open a
//  nested sequence, long press for the context menu with a live preview.
//  Part 3: label / track color stripe, audio-effects badge, volume automation line.
//  Part 4: stabilized / tracked / horizon badges; smart tools, voice separation
//  and "match every shot's color to this one" menu items.
//  Part 6: VoiceOver value + custom actions (select, split, delete, nudge),
//  larger trim handles option (Settings › Accessibility).
//

import SwiftUI

struct TimelineClipView: View {
    @Bindable var vm: StudioViewModel
    let clip: Clip
    let trackKind: TrackKind
    let isLocked: Bool
    let isTrackMuted: Bool
    let height: CGFloat
    /// Clip start x in lane coordinates (unclamped).
    let clipX: CGFloat
    /// Full clip width (unclamped).
    let clipWidth: CGFloat
    let laneWidth: CGFloat
    let rowPitch: CGFloat
    /// Organizational color of the clip's track (Part 3).
    var trackColor: RGBAColor? = nil

    private let margin: CGFloat = 60
    @AppStorage(AccessibilityPrefs.largeHandlesKey) private var largeHandles = false

    private var visibleX0: CGFloat { max(clipX, -margin) }
    private var visibleX1: CGFloat { min(clipX + clipWidth, laneWidth + margin) }
    private var drawnWidth: CGFloat { max(3, visibleX1 - visibleX0) }
    /// Offset of the drawn region from the clip start (for content alignment).
    private var contentOffset: CGFloat { visibleX0 - clipX }
    private var isSelected: Bool { vm.selection.contains(clip.id) }
    private var startVisible: Bool { clipX >= -margin }
    private var endVisible: Bool { clipX + clipWidth <= laneWidth + margin }
    private var isDragSource: Bool { vm.moveDrag?.clipIDs.contains(clip.id) == true }

    private var baseColor: Color {
        switch trackKind {
        case .video: Color(hex: 0x2B3140)
        case .overlay: Color(hex: 0x332F40)
        case .audio: Color(hex: 0x223430)
        case .adjustment: Color(hex: 0x3B3424)
        case .text, .subtitle: Color(hex: 0x2E2E37)
        }
    }

    private var clipOpacity: Double { clip.isEnabled ? (isDragSource ? 0.45 : 1) : 0.4 }
    private var moveGestureMask: GestureMask { isSelected && !isLocked && vm.tool == .select && !showsAutomation ? .all : .subviews }
    private var secondFrames: Int { Int(vm.frameRate.rounded()) }

    var body: some View {
        framed
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(clip.name + "، " + Fmt.durationPrecise(clip.duration.seconds))
            .accessibilityValue(AccessibilityPrefs.clipDescription(clip, trackKind: trackKind, locked: isLocked))
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            .accessibilityAction(named: "تحديد") { vm.selection = [clip.id] }
            .accessibilityAction(named: "تشغيل من هنا") { vm.seek(to: clip.start.seconds) }
            .accessibilityAction(named: "قص عند رأس التشغيل") {
                vm.selection = [clip.id]
                vm.splitAtPlayhead()
            }
            .accessibilityAction(named: "تحريك ثانية للأمام") {
                vm.selection = [clip.id]
                vm.nudgeSelection(frames: secondFrames)
            }
            .accessibilityAction(named: "تحريك ثانية للخلف") {
                vm.selection = [clip.id]
                vm.nudgeSelection(frames: -secondFrames)
            }
            .accessibilityAction(named: "حذف") {
                vm.selection = [clip.id]
                vm.deleteSelection()
            }
    }

    private var framed: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(baseColor)
            content
            fadeOverlay
            badges
            keyframeTicks
            colorStripe
            if showsAutomation {
                VolumeAutomationOverlay(vm: vm, clip: clip, contentOffset: contentOffset, width: drawnWidth, height: height)
            }
        }
        .frame(width: drawnWidth, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? Theme.Palette.accent : Color.white.opacity(0.10), lineWidth: isSelected ? 2 : 1)
        )
        .overlay(alignment: .leading) {
            if isSelected && startVisible && !isLocked { trimHandle(.start) }
        }
        .overlay(alignment: .trailing) {
            if isSelected && endVisible && !isLocked { trimHandle(.end) }
        }
        .overlay(alignment: .leading) { transitionBadge }
        .opacity(clipOpacity)
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture().onEnded { value in
                let time = clip.start.seconds + Double(contentOffset + value.location.x) / vm.pixelsPerSecond
                vm.tapClip(clip.id, atTime: time)
            }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { doubleTap() })
        .highPriorityGesture(moveGesture, including: moveGestureMask)
        .contextMenu { contextMenuItems } preview: { ClipPreviewCard(vm: vm, clip: clip, trackKind: trackKind) }
        .offset(x: visibleX0)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch clip.source {
        case .media(let assetID):
            if let asset = vm.env.library.asset(assetID) {
                let url = vm.env.library.url(for: asset)
                if trackKind == .audio || asset.kind == .audio {
                    if vm.prefs.showWaveforms {
                        WaveformStripView(assetID: assetID, url: url, clip: clip, pixelsPerSecond: vm.pixelsPerSecond,
                                          offset: contentOffset, width: drawnWidth, height: height,
                                          color: Theme.Palette.success.opacity(isTrackMuted || clip.audio.isMuted ? 0.3 : 0.75))
                    }
                    clipTitle
                } else {
                    VStack(spacing: 0) {
                        if vm.prefs.showFilmstrips {
                            FilmstripView(asset: asset, url: url, clip: clip, pixelsPerSecond: vm.pixelsPerSecond,
                                          offset: contentOffset, width: drawnWidth, height: stripHeight)
                        } else {
                            Color.clear.frame(height: stripHeight)
                        }
                        if showsInlineWaveform(asset) {
                            WaveformStripView(assetID: assetID, url: url, clip: clip, pixelsPerSecond: vm.pixelsPerSecond,
                                              offset: contentOffset, width: drawnWidth, height: height - stripHeight,
                                              color: Theme.Palette.success.opacity(isTrackMuted || clip.audio.isMuted ? 0.25 : 0.6))
                                .background(Color.black.opacity(0.25))
                        }
                    }
                    clipTitle
                }
            } else {
                missingContent
            }
        case .image(let assetID), .freezeFrame(let assetID, _):
            if let asset = vm.env.library.asset(assetID) {
                FilmstripView(asset: asset, url: vm.env.library.url(for: asset), clip: clip, pixelsPerSecond: vm.pixelsPerSecond,
                              offset: contentOffset, width: drawnWidth, height: height)
                clipTitle
            } else {
                missingContent
            }
        case .solidColor(let color):
            color.color.opacity(0.9)
            clipTitle
        default:
            clipTitle
        }
    }

    private var stripHeight: CGFloat { height * (vm.prefs.showWaveforms ? 0.68 : 1) }

    private func showsInlineWaveform(_ asset: MediaAsset) -> Bool {
        vm.prefs.showWaveforms && asset.hasAudio && height >= 38
    }

    private var clipTitle: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(clip.name).font(.system(size: 10, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .foregroundStyle(Theme.Palette.textPrimary)
        .padding(4)
        .frame(maxWidth: drawnWidth, alignment: .leading)
        .allowsHitTesting(false)
    }

    private var icon: String {
        if vm.compound(for: clip) != nil { return "square.stack.3d.up.fill" }
        switch clip.source {
        case .media: return trackKind == .audio ? "waveform" : "film"
        case .image: return "photo"
        case .freezeFrame: return "pause.rectangle"
        case .text: return "textformat"
        case .shape: return "square.on.circle"
        case .sticker: return "face.smiling"
        case .solidColor: return "square.fill"
        case .adjustment: return "slider.horizontal.3"
        }
    }

    private var missingContent: some View {
        ZStack {
            Theme.Palette.danger.opacity(0.25)
            Label("مفقود", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.Palette.danger)
        }
    }

    // MARK: Decorations

    @ViewBuilder
    private var badges: some View {
        let items = badgeTexts
        if !items.isEmpty {
            HStack(spacing: 3) {
                ForEach(items, id: \.self) { text in
                    Text(text)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.Palette.accent))
                        .foregroundStyle(Color(hex: 0x1A1408))
                }
            }
            .padding(4)
            .frame(width: drawnWidth, height: height, alignment: .bottomTrailing)
            .allowsHitTesting(false)
        }
    }

    private var showsAutomation: Bool {
        guard vm.showsVolumeAutomation, !isLocked, clip.mediaAssetID != nil else { return false }
        if trackKind == .audio { return true }
        return vm.asset(for: clip)?.hasAudio == true
    }

    @ViewBuilder
    private var colorStripe: some View {
        if let color = clip.label ?? trackColor {
            Rectangle()
                .fill(color.color)
                .frame(width: drawnWidth, height: 3)
                .allowsHitTesting(false)
        }
    }

    private var badgeTexts: [String] {
        var result: [String] = []
        if !clip.audio.effects.isNeutral { result.append("FX") }
        if !clip.speed.ramp.isEmpty {
            result.append("منحنى")
        } else if abs(clip.speed.rate - 1) > 0.001 {
            result.append(Fmt.number(clip.speed.rate, digits: clip.speed.rate < 1 ? 2 : 1) + "×")
        }
        if clip.speed.isReversed { result.append("↺") }
        if clip.chromaKey?.isEnabled == true { result.append("كروما") }
        if clip.stabilization?.isEnabled == true { result.append("ثابت") }
        if clip.crop.isAnimated || clip.mask?.followsSubject == true { result.append("تتبع") }
        if clip.horizon?.isEnabled == true { result.append("أفق") }
        if !clip.isEnabled { result.append("معطّل") }
        return result
    }

    @ViewBuilder
    private var keyframeTicks: some View {
        if isSelected {
            let times = clip.allKeyframeTimes
            if !times.isEmpty {
                Canvas { context, size in
                    for time in times {
                        let x = CGFloat(time * vm.pixelsPerSecond) - contentOffset
                        guard x >= -4 && x <= size.width + 4 else { continue }
                        var diamond = Path()
                        diamond.move(to: CGPoint(x: x, y: size.height - 9))
                        diamond.addLine(to: CGPoint(x: x + 4, y: size.height - 5))
                        diamond.addLine(to: CGPoint(x: x, y: size.height - 1))
                        diamond.addLine(to: CGPoint(x: x - 4, y: size.height - 5))
                        diamond.closeSubpath()
                        context.fill(diamond, with: .color(Theme.Palette.accent))
                    }
                }
                .frame(width: drawnWidth, height: height)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var fadeOverlay: some View {
        if clip.audio.fadeIn > 0 || clip.audio.fadeOut > 0 {
            Canvas { context, size in
                let pps = vm.pixelsPerSecond
                var path = Path()
                if clip.audio.fadeIn > 0 {
                    let x0 = -contentOffset
                    let x1 = x0 + CGFloat(clip.audio.fadeIn * pps)
                    path.move(to: CGPoint(x: x0, y: size.height))
                    path.addLine(to: CGPoint(x: x1, y: 2))
                }
                if clip.audio.fadeOut > 0 {
                    let xEnd = CGFloat(clip.duration.seconds * pps) - contentOffset
                    let xStart = xEnd - CGFloat(clip.audio.fadeOut * pps)
                    path.move(to: CGPoint(x: xStart, y: 2))
                    path.addLine(to: CGPoint(x: xEnd, y: size.height))
                }
                context.stroke(path, with: .color(Theme.Palette.textPrimary.opacity(0.7)), lineWidth: 1)
            }
            .frame(width: drawnWidth, height: height)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var transitionBadge: some View {
        if let transition = clip.transitionIn, startVisible {
            Button {
                vm.select(clip.id)
                vm.activeSheet = .transitions(clip.id)
            } label: {
                Image(systemName: transition.kind.symbol)
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.Palette.accent))
                    .foregroundStyle(Color(hex: 0x1A1408))
            }
            .buttonStyle(.plain)
            .padding(.leading, max(0, CGFloat(transition.duration.seconds * vm.pixelsPerSecond) / 2 - 9 - contentOffset))
            .accessibilityLabel("انتقال: " + transition.kind.title)
        }
    }

    private func trimHandle(_ edge: TrimEdge) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Theme.Palette.accent)
            .frame(width: largeHandles ? 20 : 12, height: height)
            .overlay(
                Capsule().fill(Color(hex: 0x1A1408).opacity(0.7)).frame(width: 2, height: height * 0.4)
            )
            .contentShape(Rectangle().inset(by: largeHandles ? -12 : -6))
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if vm.trimDrag == nil { vm.beginTrim(clip.id, edge: edge) }
                        vm.updateTrim(rawDelta: Double(value.translation.width) / vm.pixelsPerSecond)
                    }
                    .onEnded { _ in vm.commitTrim() }
            )
            .accessibilityLabel(edge == .start ? "قص البداية" : "قص النهاية")
    }

    // MARK: Gestures

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if vm.moveDrag == nil { vm.beginMove(anchor: clip.id) }
                let rows = Int((value.translation.height / max(rowPitch, 1)).rounded())
                vm.updateMove(rawDelta: Double(value.translation.width) / vm.pixelsPerSecond, rowDelta: rows)
            }
            .onEnded { _ in vm.commitMove() }
    }

    private func doubleTap() {
        if vm.compound(for: clip) != nil {
            vm.openCompound(for: clip.id)
        } else {
            vm.select(clip.id)
            if UIDevice.current.userInterfaceIdiom == .phone { vm.activeSheet = .inspector }
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button { vm.select(clip.id) } label: { Label("تحديد", systemImage: "checkmark.circle") }
        Button { prepare(); vm.splitAtPlayhead() } label: { Label("تقسيم عند رأس التشغيل", systemImage: "scissors") }
        Button { prepare(); vm.duplicateSelection() } label: { Label("تكرار", systemImage: "plus.square.on.square") }
        Button { prepare(); vm.copySelection() } label: { Label("نسخ", systemImage: "doc.on.doc") }
        Button { prepare(); vm.copyAttributes() } label: { Label("نسخ الخصائص", systemImage: "paintbrush") }
        if vm.clipboard.hasAttributes {
            Button { prepare(); vm.activeSheet = .pasteAttributes } label: { Label("لصق الخصائص…", systemImage: "paintbrush.pointed") }
        }
        if !clip.source.assetIDs.isEmpty {
            Button { vm.selectSameSource(as: clip.id) } label: { Label("تحديد كل مقاطع نفس الملف", systemImage: "square.on.square.dashed") }
        }
        if trackKind.isVisual {
            Menu {
                ForEach(MotionPresetStore.shared.all) { preset in
                    Button { prepare(); vm.applyMotionPreset(preset) } label: { Label(preset.name, systemImage: preset.symbol) }
                }
            } label: {
                Label("حركة جاهزة", systemImage: "wand.and.rays")
            }
        }
        if clip.mediaAssetID != nil, vm.asset(for: clip).map({ $0.hasAudio || $0.kind == .audio }) == true {
            Button { vm.extractAudio(clipID: clip.id) } label: { Label("استخراج الصوت إلى ملف", systemImage: "square.and.arrow.down.on.square") }
            Button { prepare(); vm.activeSheet = .separation(clip.id) } label: { Label("فصل الكلام عن الخلفية…", systemImage: "person.wave.2") }
        }
        if clip.mediaAssetID != nil, trackKind.isVisual, vm.asset(for: clip)?.kind == .video {
            Button { prepare(); vm.activeSheet = .smartTools(clip.id) } label: { Label("تتبع وإعادة تأطير وتثبيت…", systemImage: "wand.and.stars") }
        }
        if trackKind.isVisual, clip.source.isPicture {
            Button { prepare(); vm.matchAllColors(to: clip.id, strength: 0.85) } label: {
                Label("طابق ألوان كل اللقطات مع هذه", systemImage: "paintpalette")
            }
        }
        if clip.mediaAssetID != nil && trackKind.isVisual {
            Button { prepare(); vm.detachAudio() } label: { Label("فصل الصوت", systemImage: "waveform.badge.minus") }
            Button { prepare(); vm.insertFreezeFrame() } label: { Label("إطار ثابت", systemImage: "pause.rectangle") }
            Button { vm.toggleReverse(clipID: clip.id) } label: {
                Label(clip.speed.isReversed ? "إلغاء العكس" : "عكس المقطع", systemImage: "arrow.uturn.backward")
            }
        }
        if vm.compound(for: clip) != nil {
            Button { vm.openCompound(for: clip.id) } label: { Label("فتح التسلسل المتداخل", systemImage: "square.stack.3d.up") }
            Button { vm.expandCompound(clipID: clip.id) } label: { Label("تفكيك التسلسل", systemImage: "square.stack.3d.down.right") }
        }
        Button { prepare(); vm.activeSheet = .replaceMedia(clip.id) } label: { Label("استبدال…", systemImage: "arrow.triangle.2.circlepath") }
        Button { prepare(); vm.toggleEnabled() } label: {
            Label(clip.isEnabled ? "تعطيل" : "تفعيل", systemImage: clip.isEnabled ? "eye.slash" : "eye")
        }
        Divider()
        Button(role: .destructive) { prepare(); vm.deleteSelection(ripple: false) } label: { Label("حذف", systemImage: "trash") }
        Button(role: .destructive) { prepare(); vm.deleteSelection(ripple: true) } label: { Label("حذف متموّج", systemImage: "delete.backward") }
    }

    /// Context-menu actions apply to this clip (adding it to a multi-selection when relevant).
    private func prepare() {
        if !vm.selection.contains(clip.id) { vm.selection = [clip.id] }
        if let index = TimelineEngine.trackIndex(of: clip.id, in: vm.timeline) { vm.selectedTrackIndex = index }
    }
}

// MARK: - Filmstrip

struct FilmstripView: View {
    let asset: MediaAsset
    let url: URL
    let clip: Clip
    let pixelsPerSecond: Double
    /// Distance from the clip start to the drawn region (points).
    let offset: CGFloat
    let width: CGFloat
    let height: CGFloat

    private var tileWidth: CGFloat {
        let aspect = CGFloat(asset.pixelWidth ?? 16) / CGFloat(max(asset.pixelHeight ?? 9, 1))
        return max(24, height * min(max(aspect, 0.5), 2.4))
    }

    var body: some View {
        let tile = tileWidth
        let first = Int((offset / tile).rounded(.down))
        let last = Int(((offset + width) / tile).rounded(.up))
        ZStack(alignment: .topLeading) {
            ForEach(first..<max(first + 1, last), id: \.self) { index in
                let localX = CGFloat(index) * tile + tile / 2
                let seconds = sourceSeconds(local: Double(localX) / pixelsPerSecond)
                FilmstripTile(asset: asset, url: url, seconds: seconds)
                    .frame(width: tile, height: height)
                    .clipped()
                    .offset(x: CGFloat(index) * tile - offset)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
    }

    private func sourceSeconds(local: Double) -> Double {
        switch clip.source {
        case .freezeFrame(_, let time): return time.seconds
        case .image: return 0
        default:
            let clamped = min(max(local, 0), clip.duration.seconds)
            return SpeedMapping.sourceTime(of: clip, local: clamped) ?? 0
        }
    }
}

struct FilmstripTile: View {
    let asset: MediaAsset
    let url: URL
    let seconds: Double

    @State private var image: UIImage?

    /// Thumbnails are quantized to 0.5 s so neighbouring zoom levels reuse the cache.
    private var bucket: Int { asset.kind == .image ? 0 : Int((seconds * 2).rounded()) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .task(id: bucket) {
            let key = asset.id.uuidString + "-strip-" + String(bucket)
            image = await ThumbnailService.shared.thumbnail(url: url, kind: asset.kind, cacheKey: key,
                                                            at: Double(bucket) / 2, maxPixel: 180)
        }
    }
}

// MARK: - Waveform

struct WaveformStripView: View {
    let assetID: UUID
    let url: URL
    let clip: Clip
    let pixelsPerSecond: Double
    let offset: CGFloat
    let width: CGFloat
    let height: CGFloat
    let color: Color

    @State private var waveform: Waveform?

    var body: some View {
        Canvas { context, size in
            guard let waveform, !waveform.isEmpty else { return }
            let step: CGFloat = 2
            let midY = size.height / 2
            let gain = clip.audio.isMuted ? 0.15 : min(1, clip.audio.volume.base) * 0.95 + 0.05
            var path = Path()
            var x: CGFloat = 0
            while x < size.width {
                let localA = Double(offset + x) / pixelsPerSecond
                let localB = Double(offset + x + step) / pixelsPerSecond
                if localA > clip.duration.seconds { break }
                let a = SpeedMapping.sourceTime(of: clip, local: max(0, localA)) ?? 0
                let b = SpeedMapping.sourceTime(of: clip, local: min(clip.duration.seconds, localB)) ?? a
                let peak = Double(waveform.peak(from: min(a, b), to: max(a, b) + 0.0001))
                let amplitude = CGFloat(sqrt(peak) * gain) * (size.height / 2 - 1)
                path.move(to: CGPoint(x: x, y: midY - amplitude))
                path.addLine(to: CGPoint(x: x, y: midY + amplitude))
                x += step
            }
            context.stroke(path, with: .color(color), lineWidth: 1.2)
        }
        .frame(width: width, height: max(1, height))
        .task(id: assetID) {
            waveform = await WaveformService.shared.waveform(assetID: assetID, url: url)
        }
        .allowsHitTesting(false)
    }
}
