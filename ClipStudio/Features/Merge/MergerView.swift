//
//  MergerView.swift
//  ClipStudio — Features/Merge
//

import SwiftUI

struct MergeHubView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showPicker = false

    private var merges: [ProjectSummary] { env.projects.summaries.filter { $0.kind == .merge } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                ToolTile(title: "دمج جديد", subtitle: "اختر المقاطع بالترتيب الذي تريده", systemImage: "plus.rectangle.on.rectangle") {
                    showPicker = true
                }
                SectionTitle(title: "مشاريع الدمج", subtitle: Fmt.int(merges.count) + " مشروع", systemImage: "folder")
                if merges.isEmpty {
                    EmptyStateView(systemImage: "rectangle.stack.badge.plus", title: "لا توجد مشاريع دمج",
                                   message: "ادمج عدة مقاطع وصور في فيديو واحد مع انتقالات وموسيقى وتوحيد المقاس.")
                } else {
                    ForEach(merges) { summary in
                        Button { env.router.push(.merge(summary.id)) } label: { ProjectRow(summary: summary) }
                            .buttonStyle(.plain)
                    }
                }
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .navigationTitle("الدمج الذكي")
        .sheet(isPresented: $showPicker) {
            MediaPickerSheet(title: "اختر المقاطع بالترتيب", kinds: [.video, .image, .audio], allowsMultiple: true, confirmTitle: "دمج") { assets in
                env.router.push(.merge(ProjectActions.newMerge(assets: assets, env: env)))
            }
        }
    }
}

struct MergerView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.horizontalSizeClass) private var sizeClass
    let projectID: UUID
    @State private var viewModel: MergerViewModel?
    @State private var failed = false

    var body: some View {
        Group {
            if let viewModel {
                MergerContent(viewModel: viewModel, isWide: sizeClass == .regular)
            } else if failed {
                EmptyStateView(systemImage: "exclamationmark.triangle", title: "تعذّر فتح المشروع", message: "جرّب استعادة نسخة سابقة.")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .screenBackground()
        .task {
            guard viewModel == nil else { return }
            if let vm = MergerViewModel(projectID: projectID, env: env) {
                viewModel = vm
                vm.rebuildPreview()
            } else {
                failed = true
            }
        }
        .onDisappear { viewModel?.close() }
    }
}

private struct MergerContent: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var viewModel: MergerViewModel
    let isWide: Bool

    @State private var showAddPicker = false
    @State private var showMusicPicker = false
    @State private var showExportSettings = false
    @State private var trimming: MergeItem?
    @State private var editMode: EditMode = .inactive
    @State private var showRename = false
    @State private var renameText = ""

    private var config: MergeConfig { viewModel.config }

    var body: some View {
        ScrollView {
            if isWide {
                HStack(alignment: .top, spacing: Theme.Space.lg) {
                    VStack(spacing: Theme.Space.md) { previewCard; itemsCard }.frame(maxWidth: .infinity)
                    VStack(spacing: Theme.Space.md) { transitionCard; audioCard; outputCard }.frame(width: 400)
                }
                .padding(Theme.Space.md)
            } else {
                VStack(spacing: Theme.Space.md) {
                    previewCard
                    itemsCard
                    transitionCard
                    audioCard
                    outputCard
                }
                .padding(Theme.Space.md)
            }
        }
        .navigationTitle(viewModel.project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        renameText = viewModel.project.name
                        showRename = true
                    } label: { Label("إعادة تسمية", systemImage: "pencil") }
                    NavigationLink(value: Route.versions(viewModel.project.id)) {
                        Label("سجل الإصدارات", systemImage: "clock.arrow.circlepath")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .safeAreaInset(edge: .bottom) { exportBar }
        .sheet(isPresented: $showAddPicker) {
            MediaPickerSheet(title: "إضافة مقاطع", kinds: [.video, .image], allowsMultiple: true, confirmTitle: "إضافة") { assets in
                viewModel.add(assets)
            }
        }
        .sheet(isPresented: $showMusicPicker) {
            MediaPickerSheet(title: "اختر الموسيقى", kinds: [.audio, .video], allowsMultiple: false) { assets in
                viewModel.setMusic(assets.first)
            }
        }
        .sheet(item: $trimming) { item in
            MergeTrimSheet(viewModel: viewModel, item: item)
        }
        .sheet(isPresented: $showExportSettings) {
            ExportSettingsSheet(title: "إعدادات التصدير", settings: Binding(
                get: { viewModel.config.exportSettings },
                set: { value in viewModel.mutate { $0.exportSettings = value } }),
                durationSeconds: viewModel.totalDuration,
                canvas: viewModel.built?.1.canvasSize)
        }
        .alert("إعادة تسمية", isPresented: $showRename) {
            TextField("الاسم", text: $renameText)
            Button("حفظ") { viewModel.rename(renameText) }
            Button("إلغاء", role: .cancel) {}
        }
        .keyboardDoneToolbar()
    }

    private var previewCard: some View {
        GlassCard {
            VStack(spacing: 10) {
                ZStack {
                    VideoPreview(controller: viewModel.player)
                        .aspectRatio(viewModel.built.map { CGFloat($0.1.canvasSize.width / max(1, $0.1.canvasSize.height)) } ?? 16 / 9,
                                     contentMode: .fit)
                    if viewModel.isBuildingPreview {
                        ProgressView("جارٍ تجهيز المعاينة…").padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .frame(maxHeight: isWide ? 480 : 360)
                if let error = viewModel.previewError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.Palette.warning)
                }
                if viewModel.previewIsStale && !viewModel.isBuildingPreview {
                    Button { viewModel.rebuildPreview() } label: {
                        Label("تحديث المعاينة", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.csSecondary)
                }
            }
        }
    }

    private var itemsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(title: "المقاطع", subtitle: Fmt.int(config.items.count) + " عنصر • " + Fmt.duration(viewModel.totalDuration), systemImage: "film.stack")
                    Button(editMode.isEditing ? "تم" : "ترتيب") { withAnimation { editMode = editMode.isEditing ? .inactive : .active } }
                        .font(.subheadline)
                    Button { showAddPicker = true } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                        .accessibilityLabel("إضافة مقاطع")
                }
                if config.items.isEmpty {
                    Text("أضف مقطعين على الأقل.").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    List {
                        ForEach(viewModel.items) { entry in
                            itemRow(entry.item, asset: entry.asset)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        }
                        .onMove { viewModel.move(from: $0, to: $1) }
                        .onDelete { viewModel.remove(at: $0) }
                    }
                    .listStyle(.plain)
                    .scrollDisabled(true)
                    .frame(height: CGFloat(config.items.count) * 76)
                    .environment(\.editMode, $editMode)
                }
            }
        }
    }

    private func itemRow(_ item: MergeItem, asset: MediaAsset?) -> some View {
        HStack(spacing: 10) {
            if let asset {
                MediaThumbnailView(source: .asset(asset, env.library.url(for: asset), (item.trim?.start.seconds ?? 0) + 0.5))
                    .frame(width: 90, height: 56)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(asset?.displayName ?? "ملف مفقود").font(.subheadline.weight(.semibold)).lineLimit(1)
                if let asset {
                    if asset.kind == .image {
                        Text("صورة • " + Fmt.seconds(item.imageDuration)).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    } else {
                        let range = item.trim ?? TimeRangeValue(startSeconds: 0, endSeconds: asset.durationSeconds ?? 0)
                        Text(Fmt.duration(range.duration.seconds) + (item.trim != nil ? " (مقصوص)" : "") + " • " + asset.resolutionText)
                            .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                if let asset, env.library.isMissing(asset) {
                    StatusPill(text: "مفقود", color: Theme.Palette.danger)
                }
            }
            Spacer()
            if asset != nil {
                Button { trimming = item } label: { Image(systemName: asset?.kind == .image ? "timer" : "scissors") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("قص")
            }
        }
        .foregroundStyle(Theme.Palette.textPrimary)
    }

    private var transitionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "الانتقالات", systemImage: "rectangle.2.swap")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(TransitionKind.allCases) { kind in
                            ChipButton(title: kind.title, systemImage: kind.symbol, isSelected: config.transition == kind) {
                                viewModel.mutate { $0.transition = kind }
                            }
                        }
                    }
                }
                if config.transition != .none {
                    DecimalField(title: "مدة الانتقال", value: Binding(get: { config.transitionDuration },
                                                                     set: { v in viewModel.mutate { $0.transitionDuration = v } }),
                                 range: 0.1...3, step: 0.1, digits: 1, unit: "ث")
                }
            }
        }
    }

    private var audioCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "الصوت", systemImage: "waveform")
                Toggle("كتم الصوت الأصلي", isOn: Binding(get: { config.muteOriginalAudio }, set: { v in viewModel.mutate { $0.muteOriginalAudio = v } }))
                if !config.muteOriginalAudio {
                    sliderRow("مستوى الصوت الأصلي", value: Binding(get: { config.originalAudioVolume }, set: { v in viewModel.mutate { $0.originalAudioVolume = v } }))
                    Toggle("تلاشي صوتي بين المقاطع", isOn: Binding(get: { config.crossfadeAudio }, set: { v in viewModel.mutate { $0.crossfadeAudio = v } }))
                }
                Divider().overlay(Theme.Palette.stroke)
                if let music = config.music, let asset = viewModel.musicAsset {
                    HStack {
                        Label(asset.displayName, systemImage: "music.note").lineLimit(1)
                        Spacer()
                        Button("إزالة") { viewModel.setMusic(nil) }.font(.caption).foregroundStyle(Theme.Palette.danger)
                    }
                    sliderRow("مستوى الموسيقى", value: Binding(get: { music.volume }, set: { v in viewModel.mutate { $0.music?.volume = v } }))
                    DecimalField(title: "بداية الموسيقى", value: Binding(get: { music.startOffset }, set: { v in viewModel.mutate { $0.music?.startOffset = v } }),
                                 range: 0...3600, step: 1, digits: 1, unit: "ث")
                    DecimalField(title: "ظهور تدريجي", value: Binding(get: { music.fadeIn }, set: { v in viewModel.mutate { $0.music?.fadeIn = v } }),
                                 range: 0...10, step: 0.5, digits: 1, unit: "ث")
                    DecimalField(title: "اختفاء تدريجي", value: Binding(get: { music.fadeOut }, set: { v in viewModel.mutate { $0.music?.fadeOut = v } }),
                                 range: 0...10, step: 0.5, digits: 1, unit: "ث")
                    Toggle("تكرار الموسيقى", isOn: Binding(get: { music.loop }, set: { v in viewModel.mutate { $0.music?.loop = v } }))
                } else {
                    Button { showMusicPicker = true } label: { Label("إضافة موسيقى", systemImage: "music.note.list") }
                        .buttonStyle(.csSecondary)
                }
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(Fmt.percent(value.wrappedValue)).font(Theme.Typo.mono).foregroundStyle(Theme.Palette.textSecondary)
            }
            Slider(value: value, in: 0...1).environment(\.layoutDirection, .leftToRight)
        }
    }

    private var outputCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "المخرجات", subtitle: "توحيد المقاس ومعدل الإطارات تلقائياً", systemImage: "aspectratio")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ChipButton(title: "تلقائي", isSelected: config.aspect == nil) { viewModel.mutate { $0.aspect = nil } }
                        ForEach(AspectRatio.common) { aspect in
                            ChipButton(title: aspect.label, isSelected: config.aspect == aspect) { viewModel.mutate { $0.aspect = aspect } }
                        }
                    }
                }
                Picker("الملاءمة", selection: Binding(get: { config.fitMode }, set: { v in viewModel.mutate { $0.fitMode = v } })) {
                    ForEach(FitMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("معدل إطارات التركيب", selection: Binding(get: { config.frameRate ?? 0 },
                                                                  set: { v in viewModel.mutate { $0.frameRate = v == 0 ? nil : v } })) {
                    Text("تلقائي (الأكثر شيوعاً)").tag(0)
                    ForEach([24, 25, 30, 50, 60], id: \.self) { Text(Fmt.int($0) + " fps").tag($0) }
                }
                ColorPicker("لون الخلفية", selection: Binding(get: { config.backgroundColor.color },
                                                              set: { v in viewModel.mutate { $0.backgroundColor = RGBAColor(v) } }),
                            supportsOpacity: false)
                Button { showExportSettings = true } label: {
                    HStack {
                        Text("الترميز والجودة")
                        Spacer()
                        Text(config.exportSettings.codec.title + " • " + config.exportSettings.resolution.title)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Image(systemName: "chevron.forward").font(.caption)
                    }
                }
                .buttonStyle(.plain)
                HStack {
                    StatBadge(title: "الدقة", value: viewModel.outputSize.map { Fmt.resolution(Int($0.width), Int($0.height)) } ?? "—")
                    StatBadge(title: "الحجم التقريبي", value: Fmt.bytes(viewModel.estimatedBytes))
                }
            }
        }
    }

    private var exportBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.duration(viewModel.totalDuration)).font(.subheadline.weight(.semibold))
                Text("≈ " + Fmt.bytes(viewModel.estimatedBytes)).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
            Button {
                if viewModel.export() { Haptics.success() }
            } label: { Label("تصدير", systemImage: "square.and.arrow.up.fill") }
                .buttonStyle(.csPrimary)
                .disabled(config.items.isEmpty)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

/// Trim a video (or set an image's duration) inside the merge.
struct MergeTrimSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let viewModel: MergerViewModel
    let item: MergeItem
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var imageSeconds: Double = 3
    @State private var player = PlayerController()

    private var asset: MediaAsset? { env.library.asset(item.assetID) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Space.md) {
                    if let asset {
                        if asset.kind == .image {
                            MediaThumbnailView(source: .asset(asset, env.library.url(for: asset), 0), contentMode: .fit).frame(height: 260)
                            DecimalField(title: "مدة الظهور", value: $imageSeconds, range: 0.5...60, step: 0.5, digits: 1, unit: "ث")
                        } else {
                            VideoPreview(controller: player).frame(height: 260)
                            let total = asset.durationSeconds ?? 0
                            GlassCard {
                                VStack(spacing: 12) {
                                    DecimalField(title: "البداية", value: $start, range: 0...max(0, total - 0.5), step: 0.1, digits: 2, unit: "ث")
                                    DecimalField(title: "النهاية", value: $end, range: 0.5...max(0.5, total), step: 0.1, digits: 2, unit: "ث")
                                    HStack {
                                        Button("من موضع التشغيل كبداية") { start = player.currentTime }.buttonStyle(.csSecondary)
                                        Button("كنهاية") { end = player.currentTime }.buttonStyle(.csSecondary)
                                    }
                                    Text("المدة: " + Fmt.durationPrecise(max(0, end - start))).font(Theme.Typo.mono)
                                }
                            }
                            Button { player.playRange(start: start, end: end) } label: { Label("معاينة", systemImage: "play.fill") }
                                .buttonStyle(.csSecondary)
                        }
                    }
                }
                .padding(Theme.Space.md)
            }
            .screenBackground()
            .navigationTitle("قص المقطع")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("إلغاء") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("حفظ") {
                        if asset?.kind == .image {
                            viewModel.setImageDuration(item.id, seconds: imageSeconds)
                        } else if end - start >= 0.3 {
                            let total = asset?.durationSeconds ?? end
                            let isFull = start < 0.01 && end >= total - 0.01
                            viewModel.setTrim(item.id, range: isFull ? nil : TimeRangeValue(startSeconds: start, endSeconds: end))
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                guard let asset else { return }
                imageSeconds = item.imageDuration
                start = item.trim?.start.seconds ?? 0
                end = item.trim?.end.seconds ?? (asset.durationSeconds ?? 0)
                if asset.kind != .image {
                    player.frameRate = asset.frameRate ?? 30
                    player.load(url: env.library.url(for: asset))
                }
            }
            .onDisappear { player.pause() }
            .keyboardDoneToolbar()
        }
    }
}
