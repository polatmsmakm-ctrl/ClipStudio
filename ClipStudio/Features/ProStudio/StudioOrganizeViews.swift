//
//  StudioOrganizeViews.swift
//  ClipStudio — Features/ProStudio (Part 3)
//
//  • ProjectSummarySheet — totals and per-track statistics (clips, coverage,
//    transitions, gaps), with one-tap gap closing.
//  • MotionPresetsSheet — built-in and saved motion presets: apply to the
//    selection, save the selected clip's animation, rename and delete.
//  • ClipPreviewCard — the long-press preview of a timeline clip (looping video,
//    still, rendered text/graphic, or audio details).
//

import SwiftUI
import AVFoundation

// MARK: - Project summary

struct ProjectSummarySheet: View {
    let vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let data = vm.projectSummary
        NavigationStack {
            List {
                Section("المشروع") {
                    row("المدة", Fmt.durationPrecise(data.duration), "clock")
                    row("اللوحة", Fmt.resolution(vm.settings.canvasWidth, vm.settings.canvasHeight) + " • " + Fmt.fps(vm.frameRate), "rectangle")
                    row("المسارات", Fmt.int(data.tracks.count), "square.stack.3d.up")
                    row("المقاطع", Fmt.int(data.clipCount), "film.stack")
                    row("الانتقالات", Fmt.int(data.transitions), "rectangle.portrait.and.arrow.right")
                    row("العلامات", Fmt.int(data.markers), "bookmark")
                    row("ملفات الوسائط", Fmt.int(data.mediaFiles) + (data.missingFiles > 0 ? " (" + Fmt.int(data.missingFiles) + " مفقود)" : ""),
                        "folder")
                }
                Section("المحتوى") {
                    row("فيديو", Fmt.int(data.videoClips), "film")
                    row("صور", Fmt.int(data.imageClips), "photo")
                    row("صوت", Fmt.int(data.audioClips), "waveform")
                    row("نصوص وعناوين", Fmt.int(data.textLayers), "textformat")
                    row("ترجمة", Fmt.int(data.captions), "captions.bubble")
                    row("أشكال وملصقات", Fmt.int(data.graphics), "square.on.circle")
                    row("طبقات تعديل", Fmt.int(data.adjustmentLayers), "slider.horizontal.3")
                    row("مقاطع متحركة (إطارات مفتاحية)", Fmt.int(data.animatedClips), "diamond")
                    row("تأثيرات مفعّلة", Fmt.int(data.effects), "sparkles")
                    row("مقاطع ملوّنة", Fmt.int(data.gradedClips), "camera.filters")
                    row("مقاطع بمعالجة صوت", Fmt.int(data.audioProcessedClips), "slider.vertical.3")
                }
                Section("المسارات") {
                    ForEach(data.tracks) { track in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(track.color?.color ?? Theme.Palette.textTertiary)
                                    .frame(width: 4, height: 22)
                                Image(systemName: track.kind.symbol).foregroundStyle(Theme.Palette.accent)
                                Text(track.name).font(.subheadline.weight(.semibold))
                                if track.isMuted { Image(systemName: "speaker.slash").font(.caption) }
                                if track.isHidden { Image(systemName: "eye.slash").font(.caption) }
                                if track.isLocked { Image(systemName: "lock").font(.caption) }
                                Spacer()
                                Text(Fmt.int(track.clipCount) + " مقطع").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                            }
                            HStack(spacing: 14) {
                                stat("المحتوى", Fmt.durationPrecise(track.coveredDuration))
                                stat("الانتقالات", Fmt.int(track.transitions))
                                stat("الفراغات", track.gapCount == 0 ? "0" : Fmt.int(track.gapCount) + " • " + Fmt.durationPrecise(track.gapDuration))
                                stat("النهاية", Fmt.durationPrecise(track.end))
                            }
                            if track.gapCount > 0 && !track.isLocked {
                                Button {
                                    vm.closeGaps(onTrack: track.index)
                                } label: {
                                    Label("حذف فراغات هذا المسار", systemImage: "arrow.left.and.right.square")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                                .tint(Theme.Palette.accent)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("ملخص المشروع")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() }.fontWeight(.semibold) }
            }
            .screenBackground()
        }
    }

    private func row(_ title: String, _ value: String, _ symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol).foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.Palette.accent)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(Theme.Palette.textTertiary)
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(Theme.Palette.textPrimary)
        }
    }
}

// MARK: - Motion presets

struct MotionPresetsSheet: View {
    let vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showSave = false
    @State private var name = ""
    @State private var renaming: MotionPreset?

    private var store: MotionPresetStore { MotionPresetStore.shared }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(vm.selection.isEmpty ? "حدّد مقطعًا أو أكثر في الخط الزمني ثم اختر حركة."
                                              : "تُطبّق على " + Fmt.int(vm.selection.count) + " مقطع محدد وتستبدل حركة الموضع والحجم والدوران والشفافية التي تغيّرها.")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    if let clip = vm.primaryClip {
                        Button {
                            name = clip.name
                            showSave = true
                        } label: {
                            Label("حفظ حركة «" + clip.name + "» كقالب", systemImage: "square.and.arrow.down")
                        }
                        .disabled(MotionPreset.capture(from: clip, name: "") == nil)
                        Button(role: .destructive) { vm.clearMotion() } label: {
                            Label("إزالة الحركة من المحدد", systemImage: "xmark.circle")
                        }
                    }
                }
                Section("حركات جاهزة") {
                    ForEach(MotionPreset.builtIns) { preset in presetRow(preset) }
                }
                if !store.userPresets.isEmpty {
                    Section("حركاتي") {
                        ForEach(store.userPresets) { preset in
                            presetRow(preset)
                                .swipeActions {
                                    Button(role: .destructive) { store.delete(preset.id) } label: { Label("حذف", systemImage: "trash") }
                                    Button {
                                        name = preset.name
                                        renaming = preset
                                    } label: { Label("تسمية", systemImage: "pencil") }
                                }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("الحركات الجاهزة")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() }.fontWeight(.semibold) }
            }
            .screenBackground()
            .alert("حفظ الحركة", isPresented: $showSave) {
                TextField("اسم الحركة", text: $name)
                Button("حفظ") {
                    if let id = vm.primaryClip?.id { vm.saveMotionPreset(from: id, name: name) }
                }
                Button("إلغاء", role: .cancel) {}
            }
            .alert("تسمية الحركة", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("الاسم", text: $name)
                Button("حفظ") {
                    if let preset = renaming { store.rename(preset.id, to: name) }
                    renaming = nil
                }
                Button("إلغاء", role: .cancel) { renaming = nil }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func presetRow(_ preset: MotionPreset) -> some View {
        Button {
            vm.applyMotionPreset(preset)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: preset.symbol)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Palette.accentSoft))
                    .foregroundStyle(Theme.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.Palette.textPrimary)
                    Text(preset.propertySummary).font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .disabled(vm.selection.isEmpty)
    }
}

// MARK: - Clip preview (long press)

struct ClipPreviewCard: View {
    let vm: StudioViewModel
    let clip: Clip
    let trackKind: TrackKind

    @State private var looper: ClipLooper?

    private var aspect: CGFloat {
        let size = vm.canvasSize
        return size.height > 0 ? size.width / size.height : 16 / 9
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            visual
                .aspectRatio(aspect, contentMode: .fit)
                .frame(width: aspect >= 1 ? 320 : 200)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(Fmt.timecode(clip.start.seconds, fps: vm.frameRate) + " • " + Fmt.durationPrecise(clip.duration.seconds))
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .padding(.horizontal, 4)
        }
        .padding(10)
        .background(Theme.Palette.surface)
        .onDisappear {
            looper?.stop()
            looper = nil
        }
    }

    @ViewBuilder
    private var visual: some View {
        switch clip.source {
        case .media(let assetID):
            if let asset = vm.env.library.asset(assetID), asset.kind == .video, let range = clip.sourceRange {
                ZStack(alignment: .bottomLeading) {
                    if let looper {
                        PlayerSurface(player: looper.player)
                    } else {
                        Color.black
                    }
                    Image(systemName: "speaker.slash.fill")
                        .font(.caption)
                        .padding(6)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .onAppear {
                    looper = ClipLooper(url: vm.env.library.url(for: asset), start: range.start.seconds, end: range.end.seconds,
                                        rate: clip.speed.ramp.isEmpty ? clip.speed.rate : clip.speed.ramp.averageRateValue)
                }
            } else if let asset = vm.env.library.asset(assetID) {
                ZStack {
                    LinearGradient(colors: [Color(hex: 0x223430), Color(hex: 0x15161B)], startPoint: .top, endPoint: .bottom)
                    VStack(spacing: 6) {
                        Image(systemName: "waveform").font(.system(size: 36)).foregroundStyle(Theme.Palette.success)
                        Text(asset.displayName).font(.caption).lineLimit(1)
                        if !clip.audio.effects.activeNames.isEmpty {
                            Text(clip.audio.effects.activeNames.joined(separator: " • ")).font(.caption2).foregroundStyle(Theme.Palette.accent)
                        }
                    }
                    .padding()
                }
            } else {
                Theme.Palette.danger.opacity(0.3)
            }
        case .image(let assetID), .freezeFrame(let assetID, _):
            if let asset = vm.env.library.asset(assetID) {
                let time: Double = { if case .freezeFrame(_, let t) = clip.source { return t.seconds }; return 0 }()
                MediaThumbnailView(source: .asset(asset, vm.env.library.url(for: asset), time), cornerRadius: 0, contentMode: .fit)
            } else {
                Theme.Palette.danger.opacity(0.3)
            }
        case .solidColor(let color):
            color.color
        case .adjustment:
            ZStack {
                Theme.Palette.surfaceRaised
                Image(systemName: "slider.horizontal.3").font(.largeTitle).foregroundStyle(Theme.Palette.accent)
            }
        case .text(let content):
            generated(.text(content))
        case .shape(let shape):
            generated(.shape(shape))
        case .sticker(let sticker):
            generated(.sticker(sticker))
        }
    }

    private func generated(_ content: GeneratedContent) -> some View {
        ZStack {
            Color.black
            let canvas = CGSize(width: 640, height: 640 / max(aspect, 0.1))
            if let image = GeneratedContentRenderer.shared.image(for: content, canvas: canvas, localTime: min(1.5, clip.duration.seconds / 2),
                                                                 clipDuration: clip.duration.seconds),
               let ui = FramePreviewRenderer.shared.uiImage(image) {
                Image(uiImage: ui).resizable().scaledToFit().padding(8)
            }
        }
    }
}

extension Array where Element == SpeedRampPoint {
    /// Average playback rate of a speed ramp (for previews).
    var averageRateValue: Double {
        guard !isEmpty else { return 1 }
        return reduce(0) { $0 + $1.rate } / Double(count)
    }
}

/// Plays a source range in a muted loop.
@MainActor
final class ClipLooper {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(url: URL, start: Double, end: Double, rate: Double) {
        let item = AVPlayerItem(url: url)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                end: CMTime(seconds: max(start + 0.1, end), preferredTimescale: 600))
        looper = AVPlayerLooper(player: player, templateItem: item, timeRange: range)
        player.isMuted = true
        player.defaultRate = Float(min(max(rate, 0.25), 2))
        player.play()
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}
