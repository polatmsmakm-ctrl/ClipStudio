//
//  SegmentEditorSheet.swift
//  ClipStudio — Features/Stories
//
//  Frame-accurate manual adjustment of a segment's start/end with exact-frame
//  previews, ±frame/±0.1 s/±1 s nudges, smart snapping and range preview.
//

import SwiftUI

struct SegmentEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: SplitterViewModel
    let segmentID: UUID

    @State private var startFrame: UIImage?
    @State private var endFrame: UIImage?
    @State private var name = ""

    private var segment: StorySegment? { viewModel.segments.first { $0.id == segmentID } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let segment {
                    VStack(spacing: Theme.Space.md) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("اسم المقطع (اختياري)", text: $name)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { viewModel.renameSegment(segmentID, to: name) }
                                HStack {
                                    StatBadge(title: "المدة", value: Fmt.durationPrecise(segment.range.duration.seconds), systemImage: "timer")
                                    StatBadge(title: "الحجم التقريبي", value: Fmt.bytes(viewModel.estimatedBytes(for: segment)), systemImage: "doc")
                                }
                                if viewModel.exceedsDurationLimit(segment) {
                                    StatusPill(text: "أطول من حد المنصة", color: Theme.Palette.warning, systemImage: "exclamationmark.triangle")
                                }
                            }
                        }
                        edgeCard(title: "البداية", edge: .start, time: segment.range.start.seconds, frame: startFrame)
                        edgeCard(title: "النهاية", edge: .end, time: segment.range.end.seconds, frame: endFrame)
                        Button {
                            viewModel.preview(segment)
                        } label: {
                            Label("معاينة المقطع", systemImage: "play.fill")
                        }
                        .buttonStyle(.csPrimary)
                    }
                    .padding(Theme.Space.md)
                    .task(id: segment.range) { await loadFrames(segment) }
                } else {
                    EmptyStateView(systemImage: "scissors", title: "المقطع غير موجود", message: "ربما حُذف من القائمة.")
                }
            }
            .screenBackground()
            .navigationTitle(segment.map { viewModel.displayName(for: $0) } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("تم") {
                        viewModel.renameSegment(segmentID, to: name)
                        dismiss()
                    }
                }
            }
            .onAppear { name = segment?.name ?? "" }
            .keyboardDoneToolbar()
        }
        .presentationDetents([.large])
    }

    private func edgeCard(title: String, edge: SegmentEdge, time: Double, frame: UIImage?) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text(Fmt.timecode(time, fps: viewModel.frameRate)).font(Theme.Typo.monoLarge).foregroundStyle(Theme.Palette.accent)
                        .environment(\.layoutDirection, .leftToRight)
                }
                ZStack {
                    Theme.Palette.surfaceRaised
                    if let frame {
                        Image(uiImage: frame).resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))

                HStack(spacing: 6) {
                    nudge("-1ث", edge: edge, delta: -1)
                    nudge("-0.1", edge: edge, delta: -0.1)
                    nudge("-1إ", edge: edge, delta: -1 / viewModel.frameRate)
                    nudge("+1إ", edge: edge, delta: 1 / viewModel.frameRate)
                    nudge("+0.1", edge: edge, delta: 0.1)
                    nudge("+1ث", edge: edge, delta: 1)
                }
                .environment(\.layoutDirection, .leftToRight)

                HStack {
                    Button {
                        if !viewModel.snapEdge(segmentID, edge: edge) {
                            Haptics.warning()
                        }
                    } label: {
                        Label("التقاط أقرب نقطة ذكية", systemImage: "scope")
                    }
                    .buttonStyle(.csSecondary)
                    Button {
                        let current = viewModel.player.currentTime
                        switch edge {
                        case .start: viewModel.setStart(segmentID, to: current)
                        case .end: viewModel.setEnd(segmentID, to: current)
                        }
                        Haptics.tap()
                    } label: {
                        Label("من موضع التشغيل", systemImage: "playhead.fill")
                    }
                    .buttonStyle(.csSecondary)
                }
            }
        }
    }

    private func nudge(_ title: String, edge: SegmentEdge, delta: Double) -> some View {
        Button(title) { viewModel.nudge(segmentID, edge: edge, by: delta) }
            .font(.caption.weight(.semibold).monospacedDigit())
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Palette.surfaceHighlight))
            .buttonStyle(.plain)
            .accessibilityLabel(title)
    }

    private func loadFrames(_ segment: StorySegment) async {
        guard let asset = viewModel.asset, let url = viewModel.env.library.url(forID: asset.id) else { return }
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard !Task.isCancelled else { return }
        async let start = ThumbnailService.shared.exactFrame(url: url, seconds: segment.range.start.seconds)
        async let end = ThumbnailService.shared.exactFrame(url: url, seconds: max(0, segment.range.end.seconds - 1 / viewModel.frameRate))
        let (s, e) = await (start, end)
        startFrame = s
        endFrame = e
    }
}
