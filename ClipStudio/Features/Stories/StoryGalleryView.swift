//
//  StoryGalleryView.swift
//  ClipStudio — Features/Stories (Story Preview gallery)
//
//  Every resulting clip with thumbnail, number, duration, resolution, file size,
//  preview playback, rename, delete, include/exclude and drag reordering.
//  "Export all" in one action.
//

import SwiftUI

struct StoryGalleryView: View {
    @Environment(AppEnvironment.self) private var env
    private let projectID: UUID?
    @State private var viewModel: SplitterViewModel?
    @State private var ownsViewModel = false

    init(viewModel: SplitterViewModel) {
        self.projectID = nil
        _viewModel = State(initialValue: viewModel)
    }

    init(projectID: UUID) {
        self.projectID = projectID
    }

    var body: some View {
        Group {
            if let viewModel {
                GalleryContent(viewModel: viewModel)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .screenBackground()
        .task {
            guard viewModel == nil, let projectID else { return }
            viewModel = SplitterViewModel(projectID: projectID, env: env)
            ownsViewModel = true
        }
        .onDisappear { if ownsViewModel { viewModel?.close() } }
    }
}

private struct GalleryContent: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var viewModel: SplitterViewModel
    @State private var playing: StorySegment?
    @State private var renaming: StorySegment?
    @State private var renameText = ""
    @State private var editing: StorySegment?
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    StatBadge(title: "المقاطع", value: Fmt.int(viewModel.includedSegments.count), systemImage: "number")
                    StatBadge(title: "المدة", value: Fmt.duration(viewModel.includedSegments.reduce(0) { $0 + $1.range.duration.seconds }), systemImage: "timer")
                    StatBadge(title: "الحجم", value: Fmt.bytes(viewModel.totalEstimatedBytes), systemImage: "externaldrive")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                if viewModel.segments.isEmpty {
                    EmptyStateView(systemImage: "scissors", title: "لا توجد مقاطع", message: "ارجع وغيّر قاعدة التقسيم لإنشاء مقاطع.")
                        .listRowBackground(Color.clear)
                }
                ForEach(Array(viewModel.segments.enumerated()), id: \.element.id) { index, segment in
                    row(segment, number: index + 1)
                        .listRowBackground(Theme.Palette.surface.opacity(0.7))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { viewModel.deleteSegment(segment.id) } label: { Label("حذف", systemImage: "trash") }
                        }
                        .swipeActions(edge: .leading) {
                            Button { viewModel.toggleIncluded(segment.id) } label: {
                                Label(segment.isIncluded ? "استبعاد" : "تضمين", systemImage: segment.isIncluded ? "eye.slash" : "eye")
                            }
                            .tint(Theme.Palette.accentDeep)
                        }
                        .contextMenu {
                            Button { playing = segment } label: { Label("تشغيل", systemImage: "play.fill") }
                            Button {
                                renameText = segment.name
                                renaming = segment
                            } label: { Label("إعادة تسمية", systemImage: "pencil") }
                            Button { editing = segment } label: { Label("تعديل نقاط القطع", systemImage: "slider.horizontal.below.rectangle") }
                            Button { viewModel.toggleIncluded(segment.id) } label: {
                                Label(segment.isIncluded ? "استبعاد من التصدير" : "تضمين في التصدير", systemImage: "eye")
                            }
                            Button(role: .destructive) { viewModel.deleteSegment(segment.id) } label: { Label("حذف", systemImage: "trash") }
                        }
                }
                .onMove { viewModel.moveSegments(from: $0, to: $1) }
                .onDelete { viewModel.deleteSegments(at: $0) }
            } header: {
                Text("اسحب لإعادة الترتيب بعد الضغط على «ترتيب»").textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, $editMode)
        .navigationTitle("معرض المقاطع")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(editMode.isEditing ? "تم" : "ترتيب") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                if viewModel.exportAll() > 0 { Haptics.success() }
            } label: {
                Label("تصدير الكل (" + Fmt.int(viewModel.includedSegments.count) + ")", systemImage: "square.and.arrow.up.on.square.fill")
            }
            .buttonStyle(.csPrimary)
            .disabled(viewModel.includedSegments.isEmpty || viewModel.isSourceMissing)
            .padding(Theme.Space.md)
            .background(.ultraThinMaterial)
        }
        .sheet(item: $playing) { segment in
            SegmentPlayerSheet(viewModel: viewModel, segment: segment)
        }
        .sheet(item: $editing) { segment in
            SegmentEditorSheet(viewModel: viewModel, segmentID: segment.id)
        }
        .alert("اسم المقطع", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("الاسم", text: $renameText)
            Button("حفظ") {
                if let segment = renaming { viewModel.renameSegment(segment.id, to: renameText) }
                renaming = nil
            }
            Button("إلغاء", role: .cancel) { renaming = nil }
        } message: {
            Text("يُستخدم كاسم للملف عند التصدير.")
        }
    }

    private func row(_ segment: StorySegment, number: Int) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                if let asset = viewModel.asset {
                    MediaThumbnailView(source: .asset(asset, env.library.url(for: asset), segment.range.start.seconds + min(0.5, segment.range.duration.seconds / 2)))
                        .frame(width: 112, height: 70)
                }
                Text(Fmt.int(number))
                    .font(.caption.bold())
                    .foregroundStyle(Color(hex: 0x1A1408))
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Circle().fill(Theme.Palette.accent))
                    .padding(4)
            }
            .opacity(segment.isIncluded ? 1 : 0.4)
            .onTapGesture { playing = segment }

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.displayName(for: segment)).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(Fmt.durationPrecise(segment.range.duration.seconds) + " • "
                     + (viewModel.outputSize.map { Fmt.resolution(Int($0.width), Int($0.height)) } ?? "—"))
                    .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                HStack(spacing: 6) {
                    Text(Fmt.bytes(viewModel.estimatedBytes(for: segment))).font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
                    if !segment.isIncluded { StatusPill(text: "مستبعد", color: Theme.Palette.textTertiary) }
                    if viewModel.exceedsDurationLimit(segment) { StatusPill(text: "مدة زائدة", color: Theme.Palette.warning) }
                    if viewModel.exceedsFileLimit(segment) { StatusPill(text: "حجم زائد", color: Theme.Palette.warning) }
                }
            }
            Spacer()
            Button { playing = segment } label: { Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Theme.Palette.accent) }
                .buttonStyle(.plain)
                .accessibilityLabel("تشغيل " + viewModel.displayName(for: segment))
        }
        .padding(.vertical, 4)
    }
}

/// Plays a single segment range from the source.
struct SegmentPlayerSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let viewModel: SplitterViewModel
    let segment: StorySegment
    @State private var player = PlayerController()

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Space.md) {
                VideoPreview(controller: player)
                Text(Fmt.durationPrecise(segment.range.start.seconds) + " → " + Fmt.durationPrecise(segment.range.end.seconds))
                    .font(Theme.Typo.mono).foregroundStyle(Theme.Palette.textSecondary)
                    .environment(\.layoutDirection, .leftToRight)
            }
            .padding(Theme.Space.md)
            .screenBackground()
            .navigationTitle(viewModel.displayName(for: segment))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
            .task {
                guard let asset = viewModel.asset, let url = env.library.url(forID: asset.id) else { return }
                player.frameRate = asset.frameRate ?? 30
                player.load(url: url)
                try? await Task.sleep(nanoseconds: 250_000_000)
                player.playRange(start: segment.range.start.seconds, end: segment.range.end.seconds, loop: true)
            }
            .onDisappear { player.pause() }
        }
        .presentationDetents([.medium, .large])
    }
}
