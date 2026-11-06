//
//  InspectorView.swift
//  ClipStudio — Features/ProStudio/Inspector
//
//  Clip inspector container: tabs depend on the clip type (video, image, audio,
//  adjustment, generated). With several clips selected, edits apply to all of them
//  (multi-clip apply). Also defines the shared ClipEditor helper (keyframe-aware
//  bindings) and ClipFrameLoader (frames for the visual editors).
//

import SwiftUI
import CoreImage

struct InspectorView: View {
    @Bindable var vm: StudioViewModel
    var onDone: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            if let clip = vm.primaryClip, let kind = vm.primaryTrackKind {
                let tabs = InspectorTab.available(for: clip, trackKind: kind)
                let current = tabs.contains(vm.inspectorTab) ? vm.inspectorTab : (tabs.first ?? .info)
                tabBar(tabs, current: current)
                ScrollView {
                    VStack(spacing: 12) {
                        if vm.selection.count > 1 && current.supportsMultiApply {
                            Label("التعديل يُطبّق على " + Fmt.int(vm.selection.count) + " مقاطع محددة", systemImage: "square.stack")
                                .font(.caption)
                                .foregroundStyle(Theme.Palette.accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        tabContent(current, clip: clip)
                    }
                    .padding(12)
                    .padding(.bottom, 30)
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                ScrollView {
                    EmptyStateView(systemImage: "cursorarrow.rays", title: "لا يوجد مقطع محدد",
                                   message: "اضغط على مقطع في الخط الزمني لتعديل خصائصه، أو اسحب مقبضيه لقصّه.")
                    projectSummary
                }
            }
        }
        .background(Theme.Palette.surface)
        .keyboardDoneToolbar()
    }

    private var header: some View {
        HStack {
            if let clip = vm.primaryClip {
                Image(systemName: vm.primaryTrackKind?.symbol ?? "film").foregroundStyle(Theme.Palette.accent)
                Text(vm.selection.count > 1 ? Fmt.int(vm.selection.count) + " مقاطع" : clip.name)
                    .font(.headline)
                    .lineLimit(1)
            } else {
                Text("المفتش").font(.headline)
            }
            Spacer()
            if let onDone {
                Button("تم", action: onDone).fontWeight(.semibold)
            }
        }
        .foregroundStyle(Theme.Palette.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func tabBar(_ tabs: [InspectorTab], current: InspectorTab) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs) { tab in
                    Button {
                        vm.inspectorTab = tab
                        Haptics.selection()
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: tab.symbol).font(.system(size: 15, weight: .medium))
                            Text(tab.title).font(.system(size: 10, weight: .semibold))
                        }
                        .frame(minWidth: 52, minHeight: 44)
                        .padding(.horizontal, 4)
                        .foregroundStyle(tab == current ? Color(hex: 0x1A1408) : Theme.Palette.textPrimary)
                        .background(RoundedRectangle(cornerRadius: 10).fill(tab == current ? Theme.Palette.accent : Theme.Palette.surfaceHighlight))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func tabContent(_ tab: InspectorTab, clip: Clip) -> some View {
        switch tab {
        case .text: TextInspector(vm: vm, clipID: clip.id)
        case .graphic: GraphicsInspector(vm: vm, clipID: clip.id)
        case .transform: TransformInspector(vm: vm, clipID: clip.id)
        case .crop: CropInspector(vm: vm, clipID: clip.id)
        case .color: ColorQuickInspector(vm: vm, clipID: clip.id)
        case .effects: EffectsInspector(vm: vm, clipID: clip.id)
        case .speed: SpeedInspector(vm: vm, clipID: clip.id)
        case .audio: AudioInspector(vm: vm, clipID: clip.id)
        case .mask: MaskInspector(vm: vm, clipID: clip.id)
        case .chroma: ChromaKeyInspector(vm: vm, clipID: clip.id)
        case .transition: TransitionInspector(vm: vm, clipID: clip.id)
        case .info: ClipInfoInspector(vm: vm, clipID: clip.id)
        }
    }

    private var projectSummary: some View {
        VStack(spacing: 10) {
            StatBadge(title: "المدة", value: Fmt.duration(vm.duration), systemImage: "clock")
            StatBadge(title: "المقاطع", value: Fmt.int(vm.timeline.clipCount), systemImage: "film.stack")
            StatBadge(title: "المسارات", value: Fmt.int(vm.timeline.tracks.count), systemImage: "square.stack.3d.up")
            StatBadge(title: "اللوحة", value: Fmt.resolution(vm.settings.canvasWidth, vm.settings.canvasHeight) + " • " + Fmt.fps(vm.frameRate),
                      systemImage: "rectangle")
            Button {
                vm.activeSheet = .summary
            } label: {
                Label("ملخص المشروع", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(Theme.Palette.accent)
        }
        .padding(14)
    }
}

extension InspectorTab {
    var supportsMultiApply: Bool {
        switch self {
        case .text, .graphic, .transform, .color, .effects, .audio, .mask, .chroma: true
        default: false
        }
    }
}

// MARK: - Clip editor helper

/// Reads a clip fresh from the view model and writes changes through undoable edits.
/// When several clips are selected (and this clip is one of them), writes apply to all.
@MainActor
struct ClipEditor {
    let vm: StudioViewModel
    let clipID: UUID

    var clip: Clip? { TimelineEngine.clip(clipID, in: vm.timeline) }
    var local: Double { clip.map { vm.localTime(for: $0) } ?? 0 }
    var appliesToSelection: Bool { vm.selection.count > 1 && vm.selection.contains(clipID) }

    func update(_ name: String, key: String, _ change: @escaping (inout Clip) -> Void) {
        if appliesToSelection {
            vm.updateSelection(name, coalesce: key + "-multi", change)
        } else {
            vm.updateClip(clipID, name: name, coalesce: key + "-" + clipID.uuidString, change)
        }
    }

    /// Change with each clip's own playhead-local time (keyframe-aware writes).
    func updateTimed(_ name: String, key: String, _ change: @escaping (inout Clip, Double) -> Void) {
        let now = vm.currentTime
        let frame = vm.frameDuration
        update(name, key: key) { clip in
            let local = min(max(now - clip.start.seconds, 0), max(0, clip.duration.seconds - frame))
            change(&clip, local)
        }
    }

    func binding(_ name: String, key: String, read: @escaping (Clip) -> Double,
                 write: @escaping (inout Clip, Double) -> Void) -> Binding<Double> {
        Binding(get: { clip.map(read) ?? 0 },
                set: { value in update(name, key: key) { write(&$0, value) } })
    }

    /// Binding for a keyframed Double: reads at the playhead, writes a keyframe when animated.
    func keyframed(_ name: String, key: String, _ path: WritableKeyPath<Clip, KeyframedValue<Double>>) -> Binding<Double> {
        Binding(get: {
            guard let clip else { return 0 }
            return clip[keyPath: path].value(at: vm.localTime(for: clip))
        }, set: { value in
            updateTimed(name, key: key) { clip, local in clip[keyPath: path].set(value, at: local) }
        })
    }

    func keyframeControl(_ property: KeyframeProperty) -> KeyframeControl? {
        guard let clip, !appliesToSelection else { return nil }
        return KeyframeControl(isOnKeyframe: vm.hasKeyframe(property, clip: clip), isAnimated: clip.isAnimated(property),
                               toggle: { vm.toggleKeyframe(property, clipID: clipID) })
    }

    func editingChanged(_ editing: Bool) {
        if !editing { vm.endContinuousEdit() }
    }
}

// MARK: - Frame loader

/// Loads the clip's ungraded frame for crop/mask/chroma/color editors.
@MainActor
@Observable
final class ClipFrameLoader {
    private(set) var ciImage: CIImage?
    private(set) var image: UIImage?
    private(set) var isLoading = false

    func load(vm: StudioViewModel, clip: Clip, maxDimension: CGFloat = 900) async {
        isLoading = true
        let frame = await vm.baseFrame(for: clip, maxDimension: maxDimension)
        ciImage = frame
        image = frame.flatMap { FramePreviewRenderer.shared.uiImage($0) }
        isLoading = false
    }
}

/// A frame displayed aspect-fit with an overlay drawn in the image's coordinate space.
struct FrameCanvas<Overlay: View>: View {
    let image: UIImage?
    let isLoading: Bool
    @ViewBuilder var overlay: (CGRect) -> Overlay

    var body: some View {
        GeometryReader { geo in
            let size = image?.size ?? CGSize(width: 16, height: 9)
            let rect = AVMakeRectCompat.fit(size, in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                Color.black
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                } else if isLoading {
                    ProgressView().tint(Theme.Palette.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                overlay(rect)
            }
            .environment(\.layoutDirection, .leftToRight)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }
}

enum AVMakeRectCompat {
    static func fit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }
}
