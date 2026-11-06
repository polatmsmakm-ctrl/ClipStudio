//
//  StudioTimelineView.swift
//  ClipStudio — Features/ProStudio
//
//  Multi-track timeline with a fixed center playhead (the touch-friendly model):
//  drag horizontally to scrub (with momentum), vertically to scroll tracks, pinch to
//  zoom. Track headers (lock / hide / mute / volume / rename / reorder), ruler with
//  adaptive ticks, markers and in/out range, snapping guide, drag ghosts for moves
//  between tracks and Apple Pencil / pointer hover scrubbing. Always left → right.
//

import SwiftUI

struct TimelineRow: Identifiable, Hashable {
    let id: UUID
    let index: Int
    let y: CGFloat
    let height: CGFloat
}

enum TimelineLayout {
    static let spacing: CGFloat = 4
    static let groupGap: CGFloat = 10
    static let topPadding: CGFloat = 4

    static func rows(for timeline: Timeline, trackHeight: TrackHeightOption) -> [TimelineRow] {
        var y = topPadding
        var rows: [TimelineRow] = []
        var previousVisual: Bool?
        for index in TimelineEngine.displayOrder(timeline) {
            let track = timeline.tracks[index]
            if let previousVisual, previousVisual != track.kind.isVisual { y += groupGap }
            let height = trackHeight.height(for: track.kind)
            rows.append(TimelineRow(id: track.id, index: index, y: y, height: height))
            y += height + spacing
            previousVisual = track.kind.isVisual
        }
        return rows
    }
}

struct StudioTimelineView: View {
    @Bindable var vm: StudioViewModel
    var compact: Bool

    @State private var panAxis: Axis?
    @State private var panStartTime: Double = 0
    @State private var panStartOffset: CGFloat = 0
    @State private var zoomStart: Double?

    private var headerWidth: CGFloat { compact ? 56 : 136 }
    private let rulerHeight: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            let laneWidth = max(1, geo.size.width - headerWidth)
            let rows = TimelineLayout.rows(for: vm.timeline, trackHeight: vm.prefs.trackHeight)
            let contentHeight = (rows.last.map { $0.y + $0.height } ?? 0) + 40
            let viewport = max(1, geo.size.height - rulerHeight)
            let maxOffset = max(0, contentHeight - viewport)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    TimelineCornerMenu(vm: vm, compact: compact)
                        .frame(width: headerWidth, height: rulerHeight)
                    TimelineRuler(vm: vm, laneWidth: laneWidth)
                        .frame(width: laneWidth, height: rulerHeight)
                }
                ZStack(alignment: .topLeading) {
                    TimelineLanes(vm: vm, rows: rows, laneWidth: laneWidth, headerWidth: headerWidth, compact: compact)
                        .offset(y: -min(vm.verticalOffset, maxOffset))

                    if vm.timeline.isEmpty {
                        Text("أضف وسائط من المكتبة لتظهر هنا")
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .frame(width: laneWidth, height: 60)
                            .offset(x: headerWidth, y: 40)
                            .allowsHitTesting(false)
                    }

                    verticalLine(at: headerWidth + laneWidth / 2, color: Theme.Palette.accent, width: 2)
                    if let guide = vm.snapGuide {
                        verticalLine(at: headerWidth + x(for: guide, laneWidth: laneWidth),
                                     color: Theme.Palette.textPrimary.opacity(0.8), width: 1)
                    }
                    if let hover = vm.hoverTime {
                        verticalLine(at: headerWidth + x(for: hover, laneWidth: laneWidth),
                                     color: Theme.Palette.textSecondary, width: 1)
                    }
                }
                .frame(width: geo.size.width, height: viewport, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .gesture(panGesture(maxOffset: maxOffset))
                .simultaneousGesture(zoomGesture)
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let location):
                        let laneX = location.x - headerWidth
                        guard laneX >= 0 else {
                            vm.hoverScrub(to: nil)
                            return
                        }
                        vm.hoverScrub(to: vm.currentTime + Double(laneX - laneWidth / 2) / vm.pixelsPerSecond)
                    case .ended:
                        vm.hoverScrub(to: nil)
                    }
                }
            }
            .onAppear { vm.laneWidth = laneWidth }
            .onChange(of: laneWidth) { _, newValue in vm.laneWidth = newValue }
        }
        .background(Theme.Palette.surface)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func x(for time: Double, laneWidth: CGFloat) -> CGFloat {
        laneWidth / 2 + CGFloat((time - vm.currentTime) * vm.pixelsPerSecond)
    }

    private func verticalLine(at x: CGFloat, color: Color, width: CGFloat) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .offset(x: x - width / 2)
            .allowsHitTesting(false)
    }

    private func panGesture(maxOffset: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if panAxis == nil {
                    panAxis = abs(value.translation.width) >= abs(value.translation.height) ? .horizontal : .vertical
                    panStartTime = vm.currentTime
                    panStartOffset = min(vm.verticalOffset, maxOffset)
                    if panAxis == .horizontal { vm.beginScrub() }
                }
                if panAxis == .horizontal {
                    vm.scrub(to: panStartTime - Double(value.translation.width) / vm.pixelsPerSecond)
                } else {
                    vm.verticalOffset = min(max(0, panStartOffset - value.translation.height), maxOffset)
                }
            }
            .onEnded { value in
                if panAxis == .horizontal {
                    let current = panStartTime - Double(value.translation.width) / vm.pixelsPerSecond
                    let predicted = panStartTime - Double(value.predictedEndTranslation.width) / vm.pixelsPerSecond
                    let fling = abs(predicted - current) * vm.pixelsPerSecond > 60
                    vm.endScrub(glideTo: fling ? current + (predicted - current) * 0.6 : nil)
                }
                panAxis = nil
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomStart == nil { zoomStart = vm.pixelsPerSecond }
                vm.setZoom((zoomStart ?? vm.pixelsPerSecond) * Double(value.magnification))
            }
            .onEnded { _ in zoomStart = nil }
    }
}

// MARK: - Lanes

struct TimelineLanes: View {
    @Bindable var vm: StudioViewModel
    let rows: [TimelineRow]
    let laneWidth: CGFloat
    let headerWidth: CGFloat
    let compact: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(rows) { row in
                if vm.timeline.tracks.indices.contains(row.index) {
                    let track = vm.timeline.tracks[row.index]
                    HStack(spacing: 0) {
                        TrackHeaderView(vm: vm, track: track, index: row.index, height: row.height, compact: compact)
                            .frame(width: headerWidth, height: row.height)
                        TrackLaneView(vm: vm, track: track, trackIndex: row.index, height: row.height,
                                      laneWidth: laneWidth, rowPitch: averagePitch)
                            .frame(width: laneWidth, height: row.height)
                    }
                    .offset(y: row.y)
                }
            }
            ghosts
        }
        .frame(width: headerWidth + laneWidth, alignment: .topLeading)
    }

    private var averagePitch: CGFloat {
        guard !rows.isEmpty else { return 50 }
        return rows.map(\.height).reduce(0, +) / CGFloat(rows.count) + TimelineLayout.spacing
    }

    /// Previews of clips being dragged to another time / track.
    @ViewBuilder
    private var ghosts: some View {
        if let drag = vm.moveDrag {
            ForEach(Array(drag.clipIDs), id: \.self) { id in
                if let clip = TimelineEngine.clip(id, in: vm.timeline), let previewRow = vm.previewRow(for: id) {
                    let y = ghostY(previewRow)
                    let height = ghostHeight(previewRow, fallbackClip: id)
                    let x = laneWidth / 2 + CGFloat((clip.start.seconds + drag.timeDelta - vm.currentTime) * vm.pixelsPerSecond)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.Palette.accent.opacity(0.28))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.Palette.accent, lineWidth: 2))
                        .overlay(alignment: .leading) {
                            Text(clip.name).font(.caption2.weight(.semibold)).lineLimit(1).padding(.horizontal, 6)
                                .foregroundStyle(Theme.Palette.textPrimary)
                        }
                        .frame(width: max(4, CGFloat(clip.duration.seconds * vm.pixelsPerSecond)), height: height - 6)
                        .offset(x: headerWidth + x, y: y + 3)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func ghostY(_ row: Int) -> CGFloat {
        if row < 0 { return (rows.first?.y ?? 0) - 44 }
        if row >= rows.count { return (rows.last.map { $0.y + $0.height } ?? 0) + TimelineLayout.spacing }
        return rows[row].y
    }

    private func ghostHeight(_ row: Int, fallbackClip: UUID) -> CGFloat {
        if rows.indices.contains(row) { return rows[row].height }
        return 44
    }
}

struct TrackLaneView: View {
    @Bindable var vm: StudioViewModel
    let track: Track
    let trackIndex: Int
    let height: CGFloat
    let laneWidth: CGFloat
    let rowPitch: CGFloat

    @State private var isDropTargeted = false

    var body: some View {
        let pps = vm.pixelsPerSecond
        let now = vm.currentTime
        let halfSpan = Double(laneWidth / 2) / pps
        let windowStart = now - halfSpan - 2
        let windowEnd = now + halfSpan + 2
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(vm.selectedTrackIndex == trackIndex ? Theme.Palette.accentSoft.opacity(0.5) : Color.white.opacity(0.025))
                .contentShape(Rectangle())
                .onTapGesture {
                    vm.deselectAll()
                    vm.selectTrack(trackIndex)
                }
            ForEach(track.clips) { stored in
                let clip = vm.trimDrag?.clipID == stored.id ? (vm.trimDrag?.preview ?? stored) : stored
                if clip.end.seconds >= windowStart && clip.start.seconds <= windowEnd {
                    let clipX = laneWidth / 2 + CGFloat((clip.start.seconds - now) * pps)
                    let clipWidth = max(3, CGFloat(clip.duration.seconds * pps))
                    TimelineClipView(vm: vm, clip: clip, trackKind: track.kind, isLocked: track.isLocked,
                                     isTrackMuted: track.isMuted, height: height - 6,
                                     clipX: clipX, clipWidth: clipWidth, laneWidth: laneWidth, rowPitch: rowPitch,
                                     trackColor: track.color)
                        .offset(y: 3)
                }
            }
            if track.isLocked {
                Rectangle()
                    .fill(Color.black.opacity(0.25))
                    .allowsHitTesting(false)
            }
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.Palette.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .allowsHitTesting(false)
            }
        }
        .clipped()
        .dropDestination(for: String.self) { items, location in
            let ids = items.compactMap { UUID(uuidString: $0) }
            let time = vm.currentTime + Double(location.x - laneWidth / 2) / vm.pixelsPerSecond
            return vm.drop(assetIDs: ids, onTrack: trackIndex, at: time)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
    }
}

// MARK: - Track header

struct TrackHeaderView: View {
    @Bindable var vm: StudioViewModel
    let track: Track
    let index: Int
    let height: CGFloat
    let compact: Bool

    @State private var renaming = false
    @State private var nameDraft = ""

    var body: some View {
        let selected = vm.selectedTrackIndex == index
        HStack(spacing: 4) {
            Rectangle()
                .fill(selected ? Theme.Palette.accent : (track.color?.color ?? Color.clear))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: track.kind.symbol)
                        .font(.caption)
                        .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textSecondary)
                    if !compact {
                        Text(track.name).font(.caption2.weight(.semibold)).lineLimit(1)
                            .foregroundStyle(Theme.Palette.textPrimary)
                    }
                }
                if height >= 40 || !compact {
                    HStack(spacing: compact ? 2 : 6) {
                        if track.kind.isVisual {
                            headerToggle(track.isHidden ? "eye.slash" : "eye", active: track.isHidden, label: "إخفاء") {
                                vm.toggleHidden(index)
                            }
                        }
                        if track.kind == .audio || track.kind == .video || track.kind == .overlay {
                            headerToggle(track.isMuted ? "speaker.slash" : "speaker.wave.2", active: track.isMuted, label: "كتم") {
                                vm.toggleMuted(index)
                            }
                            if !compact || track.kind == .audio {
                                headerToggle(track.isSolo ? "s.circle.fill" : "s.circle", active: track.isSolo, label: "عزل") {
                                    vm.toggleSolo(index)
                                }
                            }
                        }
                        if !compact {
                            headerToggle(track.isLocked ? "lock.fill" : "lock.open", active: track.isLocked, label: "قفل") {
                                vm.toggleLock(index)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .background(selected ? Theme.Palette.surfaceHighlight : Theme.Palette.surfaceRaised)
        .contentShape(Rectangle())
        .onTapGesture { vm.selectTrack(index) }
        .contextMenu {
            Button { nameDraft = track.name; renaming = true } label: { Label("إعادة تسمية", systemImage: "pencil") }
            Button { vm.toggleLock(index) } label: {
                Label(track.isLocked ? "فتح القفل" : "قفل المسار", systemImage: track.isLocked ? "lock.open" : "lock")
            }
            if track.kind != .adjustment && track.kind != .text {
                Menu {
                    ForEach([0, 25, 50, 75, 100], id: \.self) { percent in
                        Button(Fmt.int(percent) + "%") { vm.setTrackVolume(index, Double(percent) / 100) }
                    }
                } label: {
                    Label("مستوى صوت المسار: " + Fmt.percent(track.volume), systemImage: "speaker.wave.2")
                }
            }
            Menu {
                Button { vm.setTrackColor(index, nil) } label: { Label("بدون لون", systemImage: "nosign") }
                ForEach(StudioViewModel.trackPalette, id: \.self) { hex in
                    Button { vm.setTrackColor(index, RGBAColor(hex: hex)) } label: {
                        Label(track.color == RGBAColor(hex: hex) ? "✓ اللون" : "لون", systemImage: "circle.fill")
                    }
                    .tint(Color(hex: hex))
                }
            } label: {
                Label("لون المسار", systemImage: "paintpalette")
            }
            if track.carriesAudio {
                Button { vm.toggleSolo(index) } label: {
                    Label(track.isSolo ? "إلغاء العزل" : "عزل المسار (سماعه وحده)", systemImage: "s.circle")
                }
            }
            if vm.gapCount(onTrack: index) > 0 && !track.isLocked {
                Button { vm.closeGaps(onTrack: index) } label: {
                    Label("حذف الفراغات (" + Fmt.int(vm.gapCount(onTrack: index)) + ")", systemImage: "arrow.left.and.right.square")
                }
            }
            if track.kind.isVisual {
                Button { vm.moveTrack(index, up: true) } label: { Label("رفع الطبقة", systemImage: "arrow.up") }
                Button { vm.moveTrack(index, up: false) } label: { Label("خفض الطبقة", systemImage: "arrow.down") }
            }
            Button { vm.selectTrack(index); vm.selectForward(allTracks: false) } label: {
                Label("تحديد ما بعد رأس التشغيل", systemImage: "arrow.right.to.line")
            }
            Divider()
            Button(role: .destructive) { vm.requestRemoveTrack(index) } label: { Label("حذف المسار", systemImage: "trash") }
        }
        .alert("اسم المسار", isPresented: $renaming) {
            TextField("الاسم", text: $nameDraft)
            Button("حفظ") { vm.renameTrack(index, nameDraft) }
            Button("إلغاء", role: .cancel) {}
        }
    }

    private func headerToggle(_ symbol: String, active: Bool, label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Theme.Palette.warning : Theme.Palette.textSecondary)
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct TimelineCornerMenu: View {
    @Bindable var vm: StudioViewModel
    let compact: Bool

    var body: some View {
        Menu {
            Section("مسار جديد") {
                Button { vm.addTrack(.video) } label: { Label("فيديو", systemImage: TrackKind.video.symbol) }
                Button { vm.addTrack(.overlay) } label: { Label("طبقة علوية", systemImage: TrackKind.overlay.symbol) }
                Button { vm.addTrack(.audio) } label: { Label("صوت", systemImage: TrackKind.audio.symbol) }
                Button { vm.addTrack(.adjustment) } label: { Label("طبقة تعديل", systemImage: TrackKind.adjustment.symbol) }
                Button { vm.addTrack(.text) } label: { Label("نصوص", systemImage: TrackKind.text.symbol) }
                Button { vm.addTrack(.subtitle) } label: { Label("ترجمة", systemImage: TrackKind.subtitle.symbol) }
            }
            Section("الصوت") {
                Button { vm.showsVolumeAutomation.toggle() } label: {
                    Label(vm.showsVolumeAutomation ? "إخفاء خط مستوى الصوت" : "رسم مستوى الصوت",
                          systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                if vm.timeline.tracks.contains(where: \.isSolo) {
                    Button { vm.clearSolo() } label: { Label("إلغاء عزل كل المسارات", systemImage: "s.circle") }
                }
            }
            Section("التكبير") {
                Button { vm.zoom(by: 1.5) } label: { Label("تكبير", systemImage: "plus.magnifyingglass") }
                Button { vm.zoom(by: 1 / 1.5) } label: { Label("تصغير", systemImage: "minus.magnifyingglass") }
                Button { vm.zoomToFit() } label: { Label("ملاءمة الخط الزمني", systemImage: "arrow.left.and.right") }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus.square.on.square")
                if !compact { Text("مسار").font(.caption2) }
            }
            .foregroundStyle(Theme.Palette.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Palette.surfaceRaised)
        .accessibilityLabel("إضافة مسار")
    }
}

// MARK: - Ruler

struct TimelineRuler: View {
    @Bindable var vm: StudioViewModel
    let laneWidth: CGFloat

    @State private var editingMarker: TimelineMarker?
    @State private var markerName = ""
    @State private var draggingMarker: UUID?
    @State private var markerDragStart: Double?

    var body: some View {
        let pps = vm.pixelsPerSecond
        let now = vm.currentTime
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                drawTicks(context: context, size: size, pps: pps, now: now)
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    vm.seek(to: now + Double(value.location.x - laneWidth / 2) / pps)
                }
            )

            if let range = vm.inOutRange {
                let x0 = laneWidth / 2 + CGFloat((range.0 - now) * pps)
                let x1 = laneWidth / 2 + CGFloat((range.1 - now) * pps)
                Rectangle()
                    .fill(Theme.Palette.accent.opacity(0.22))
                    .frame(width: max(1, x1 - x0), height: 6)
                    .offset(x: x0, y: 24)
                    .allowsHitTesting(false)
            }

            ForEach(vm.markers) { marker in
                let mx = laneWidth / 2 + CGFloat((marker.time.seconds - now) * pps)
                if mx > -20 && mx < laneWidth + 20 {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: draggingMarker == marker.id ? 14 : 11))
                        .foregroundStyle(marker.color.color)
                        .frame(width: 26, height: 22)
                        .contentShape(Rectangle())
                        .overlay(alignment: .top) {
                            if draggingMarker == marker.id {
                                Text(Fmt.timecode(marker.time.seconds, fps: vm.frameRate))
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .padding(.horizontal, 4)
                                    .background(Capsule().fill(Theme.Palette.accent))
                                    .foregroundStyle(Color(hex: 0x1A1408))
                                    .fixedSize()
                                    .offset(y: 20)
                            }
                        }
                        .onTapGesture { vm.seek(to: marker.time.seconds) }
                        .gesture(DragGesture(minimumDistance: 3)
                            .onChanged { value in
                                if draggingMarker != marker.id {
                                    draggingMarker = marker.id
                                    markerDragStart = marker.time.seconds
                                }
                                let start = markerDragStart ?? marker.time.seconds
                                vm.moveMarker(marker.id, to: start + Double(value.translation.width) / pps, final: false)
                            }
                            .onEnded { value in
                                let start = markerDragStart ?? marker.time.seconds
                                vm.moveMarker(marker.id, to: start + Double(value.translation.width) / pps, final: true)
                                draggingMarker = nil
                                markerDragStart = nil
                            })
                        .offset(x: mx - 13, y: 4)
                    .contextMenu {
                        Text(marker.name)
                        Button { markerName = marker.name; editingMarker = marker } label: { Label("إعادة تسمية", systemImage: "pencil") }
                        Button(role: .destructive) { vm.removeMarker(marker.id) } label: { Label("حذف", systemImage: "trash") }
                    }
                    .accessibilityLabel("علامة " + marker.name)
                }
            }

            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.accent)
                .offset(x: laneWidth / 2 - 6, y: 16)
                .allowsHitTesting(false)
        }
        .frame(width: laneWidth)
        .background(Theme.Palette.surfaceRaised)
        .clipped()
        .alert("اسم العلامة", isPresented: Binding(get: { editingMarker != nil }, set: { if !$0 { editingMarker = nil } })) {
            TextField("الاسم", text: $markerName)
            Button("حفظ") {
                if let marker = editingMarker { vm.renameMarker(marker.id, to: markerName) }
                editingMarker = nil
            }
            Button("إلغاء", role: .cancel) { editingMarker = nil }
        }
    }

    private func drawTicks(context: GraphicsContext, size: CGSize, pps: Double, now: Double) {
        let fps = vm.frameRate
        let candidates: [Double] = [1 / fps, 2 / fps, 5 / fps, 10 / fps, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        let major = candidates.first { $0 * pps >= 74 } ?? 3600
        let minor = major / (major < 1 ? 2 : 5)
        let halfSpan = Double(size.width / 2) / pps
        let start = max(0, ((now - halfSpan) / minor).rounded(.down) * minor)
        let end = now + halfSpan
        var t = start
        var guardCount = 0
        var path = Path()
        while t <= end && guardCount < 2000 {
            let x = size.width / 2 + CGFloat((t - now) * pps)
            let isMajor = abs((t / major).rounded() * major - t) < minor * 0.01
            path.move(to: CGPoint(x: x, y: size.height))
            path.addLine(to: CGPoint(x: x, y: size.height - (isMajor ? 12 : 5)))
            if isMajor {
                let label = major < 1 ? Self.shortTimecode(t, fps: fps) : Fmt.duration(t)
                context.draw(Text(label).font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textSecondary),
                             at: CGPoint(x: x + 3, y: 9), anchor: .leading)
            }
            t += minor
            guardCount += 1
        }
        context.stroke(path, with: .color(Theme.Palette.textTertiary), lineWidth: 1)
    }

    static func shortTimecode(_ seconds: Double, fps: Double) -> String {
        let full = Fmt.timecode(seconds, fps: fps)
        return full.hasPrefix("00:") ? String(full.dropFirst(3)) : full
    }
}
