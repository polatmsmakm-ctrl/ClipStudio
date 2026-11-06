//
//  SplitterView.swift
//  ClipStudio — Features/Stories (Smart Stories workspace)
//
//  Simple, fast splitting UI: platform chips → rule → optional smart cuts →
//  output → export all. iPad shows preview and controls side by side.
//

import SwiftUI

struct SplitterView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.horizontalSizeClass) private var sizeClass
    let projectID: UUID

    @State private var viewModel: SplitterViewModel?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let viewModel {
                SplitterContent(viewModel: viewModel, isWide: sizeClass == .regular)
            } else if loadFailed {
                EmptyStateView(systemImage: "exclamationmark.triangle", title: "تعذّر فتح المشروع",
                               message: "قد يكون المشروع محذوفاً أو تالفاً. جرّب استعادة نسخة سابقة من سجل الإصدارات.")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .screenBackground()
        .task {
            guard viewModel == nil else { return }
            if let vm = SplitterViewModel(projectID: projectID, env: env) {
                viewModel = vm
            } else {
                loadFailed = true
            }
        }
        .onDisappear { viewModel?.close() }
    }
}

private struct SplitterContent: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var viewModel: SplitterViewModel
    let isWide: Bool

    @State private var editingSegment: StorySegment?
    @State private var showExportSettings = false
    @State private var showGallery = false
    @State private var showRename = false
    @State private var renameText = ""

    private var story: StoryConfig { viewModel.story }

    var body: some View {
        ScrollView {
            if isWide {
                HStack(alignment: .top, spacing: Theme.Space.lg) {
                    previewColumn.frame(maxWidth: .infinity)
                    controlsColumn.frame(width: 420)
                }
                .padding(Theme.Space.md)
            } else {
                VStack(spacing: Theme.Space.md) {
                    previewColumn
                    controlsColumn
                }
                .padding(Theme.Space.md)
            }
        }
        .navigationTitle(viewModel.project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { showGallery = true } label: { Label("معرض المقاطع", systemImage: "square.grid.2x2") }
                    Button {
                        renameText = viewModel.project.name
                        showRename = true
                    } label: { Label("إعادة تسمية المشروع", systemImage: "pencil") }
                    NavigationLink(value: Route.versions(viewModel.project.id)) {
                        Label("سجل الإصدارات", systemImage: "clock.arrow.circlepath")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .safeAreaInset(edge: .bottom) { exportBar }
        .navigationDestination(isPresented: $showGallery) { StoryGalleryView(viewModel: viewModel) }
        .sheet(item: $editingSegment) { segment in
            SegmentEditorSheet(viewModel: viewModel, segmentID: segment.id)
        }
        .sheet(isPresented: $showExportSettings) {
            ExportSettingsSheet(title: "إعدادات التصدير", settings: Binding(
                get: { viewModel.story.exportSettings },
                set: { viewModel.setExportSettings($0) }),
                durationSeconds: viewModel.includedSegments.reduce(0) { $0 + $1.range.duration.seconds },
                canvas: viewModel.asset.map { StoryTimelineFactory.canvas(for: $0, aspect: viewModel.story.aspect, frameRate: 30).canvasSize })
        }
        .alert("إعادة تسمية المشروع", isPresented: $showRename) {
            TextField("الاسم", text: $renameText)
            Button("حفظ") { viewModel.rename(project: renameText) }
            Button("إلغاء", role: .cancel) {}
        }
        .confirmationDialog("إعادة حساب المقاطع؟", isPresented: $viewModel.pendingReplanConfirmation, titleVisibility: .visible) {
            Button("إعادة الحساب (تُفقد التعديلات اليدوية)", role: .destructive) { viewModel.replan(force: true) }
            Button("الإبقاء على مقاطعي", role: .cancel) {}
        } message: {
            Text("عدّلت نقاط القطع يدوياً. تغيير القاعدة سيعيد تقسيم الفيديو من جديد.")
        }
        .keyboardDoneToolbar()
    }

    // MARK: Preview

    private var previewColumn: some View {
        VStack(spacing: Theme.Space.md) {
            if viewModel.isSourceMissing {
                GlassCard {
                    Label("ملف المصدر مفقود. افتح مكتبة الوسائط واختر «ربط ملف بديل».", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Palette.warning)
                }
            }
            if let asset = viewModel.asset {
                VideoPreview(controller: viewModel.player)
                    .aspectRatio(CGFloat(Double(asset.pixelWidth ?? 16) / Double(max(1, asset.pixelHeight ?? 9))), contentMode: .fit)
                    .frame(maxHeight: isWide ? 520 : 380)
            }
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionTitle(title: "المقاطع", subtitle: Fmt.int(viewModel.includedSegments.count) + " من " + Fmt.int(viewModel.segments.count) + " للتصدير")
                        Button("المعرض") { showGallery = true }.font(.subheadline)
                    }
                    SegmentStripView(duration: viewModel.duration, segments: viewModel.segments,
                                     scenes: viewModel.scenes, pauses: viewModel.pauses,
                                     playhead: viewModel.player.currentTime, selectedID: viewModel.selectedSegmentID,
                                     onSelect: { viewModel.preview($0) },
                                     onSeek: { viewModel.player.seek(to: $0, precise: false) })
                    HStack(spacing: 12) {
                        legend(color: Color.white.opacity(0.7), text: "مشهد")
                        legend(color: Theme.Palette.success, text: "وقفة")
                        Spacer()
                    }
                    if let selected = viewModel.segments.first(where: { $0.id == viewModel.selectedSegmentID }) {
                        selectedSegmentRow(selected)
                    }
                }
            }
        }
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    private func selectedSegmentRow(_ segment: StorySegment) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.displayName(for: segment)).font(.subheadline.weight(.semibold))
                Text(Fmt.durationPrecise(segment.range.start.seconds) + " → " + Fmt.durationPrecise(segment.range.end.seconds)
                     + "  (" + Fmt.durationPrecise(segment.range.duration.seconds) + ")")
                    .font(Theme.Typo.mono).foregroundStyle(Theme.Palette.textSecondary)
                    .environment(\.layoutDirection, .leftToRight)
            }
            Spacer()
            Button { viewModel.preview(segment) } label: { Image(systemName: "play.circle.fill").font(.title2) }
                .accessibilityLabel("معاينة")
            Button { editingSegment = segment } label: { Image(systemName: "slider.horizontal.below.rectangle").font(.title2) }
                .accessibilityLabel("تعديل نقاط القطع")
        }
        .foregroundStyle(Theme.Palette.textPrimary)
    }

    // MARK: Controls

    private var controlsColumn: some View {
        VStack(spacing: Theme.Space.md) {
            platformCard
            ruleCard
            smartCutsCard
            outputCard
            summaryCard
        }
    }

    private var platformCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "المنصة", subtitle: "الحدود قابلة للتعديل من الإعدادات", systemImage: "apps.iphone")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ChipButton(title: "بدون", systemImage: "slider.horizontal.3", isSelected: story.presetKey == nil) {
                            viewModel.applyPreset(nil)
                        }
                        ForEach(env.presets.platforms) { preset in
                            ChipButton(title: preset.name, systemImage: preset.symbol, isSelected: story.presetKey == preset.key) {
                                viewModel.applyPreset(preset)
                            }
                        }
                    }
                }
                if let preset = viewModel.preset {
                    Text(presetDescription(preset)).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
    }

    private func presetDescription(_ preset: PlatformPreset) -> String {
        var parts: [String] = [preset.aspect.label, preset.resolution.title]
        if let max = preset.maxDuration { parts.append("حد " + Fmt.seconds(max, digits: 0)) }
        if let size = preset.maxFileSizeMB { parts.append("حجم ≤ " + Fmt.number(size) + " MB") }
        return parts.joined(separator: " • ")
    }

    private var ruleCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "طريقة التقسيم", systemImage: "scissors")
                Picker("الطريقة", selection: Binding(get: { story.rule.mode }, set: { viewModel.setMode($0) })) {
                    ForEach(SplitModeKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(story.rule.mode.explanation).font(.caption).foregroundStyle(Theme.Palette.textSecondary)

                switch story.rule.mode {
                case .maxDuration, .fixedDuration:
                    DecimalField(title: story.rule.mode == .maxDuration ? "الحد الأقصى" : "مدة كل جزء",
                                 value: Binding(get: { story.rule.seconds }, set: { viewModel.setSeconds($0) }),
                                 range: 1...3600, step: 5, digits: 1, unit: "ث")
                case .equalParts:
                    DecimalField(title: "عدد الأجزاء", value: Binding(get: { Double(story.rule.parts) }, set: { viewModel.setParts(Int($0.rounded())) }),
                                 range: 1...500, step: 1, digits: 0)
                case .customDurations:
                    HStack {
                        TextField("15, 30, 45", text: $viewModel.customDurationsText)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numbersAndPunctuation)
                            .onSubmit { viewModel.commitCustomDurations() }
                            .environment(\.layoutDirection, .leftToRight)
                        Button("تطبيق") { viewModel.commitCustomDurations() }.buttonStyle(.bordered)
                    }
                }
                DecimalField(title: "أقل مدة للجزء الأخير", value: Binding(get: { story.rule.minimumTail }, set: { viewModel.setMinimumTail($0) }),
                             range: 0...60, step: 1, digits: 0, unit: "ث")
            }
        }
    }

    private var smartCutsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "نقاط القطع الذكية", subtitle: "تحليل محلي على الجهاز — لا يُرفع شيء", systemImage: "sparkles")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SnapTarget.allCases, id: \.self) { target in
                            ChipButton(title: target.title, systemImage: target.symbol, isSelected: story.rule.snap == target) {
                                viewModel.setSnap(target)
                            }
                        }
                    }
                }
                if let progress = viewModel.analysisProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(viewModel.analysisTitle).font(.caption)
                            Spacer()
                            Text(Fmt.percent(progress)).font(Theme.Typo.mono)
                            Button("إلغاء") { viewModel.cancelAnalysis() }.font(.caption)
                        }
                        ProgressBarView(progress: progress)
                    }
                } else if story.rule.snap != .none {
                    HStack {
                        Text(Fmt.int(viewModel.snapPoints.count) + " نقطة متاحة").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                        Spacer()
                        Button("إعادة التحليل") { viewModel.runAnalysis(story.rule.snap) }.font(.caption)
                    }
                    DecimalField(title: "أقصى إزاحة للقطع", value: Binding(get: { story.rule.snapTolerance }, set: { viewModel.setTolerance($0) }),
                                 range: 0.1...30, step: 0.5, digits: 1, unit: "ث")
                }
            }
        }
    }

    private var outputCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "المخرجات", systemImage: "square.and.arrow.up")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ChipButton(title: "مقاس المصدر", isSelected: story.aspect == nil) { viewModel.setAspect(nil) }
                        ForEach(AspectRatio.common) { aspect in
                            ChipButton(title: aspect.label, isSelected: story.aspect == aspect) { viewModel.setAspect(aspect) }
                        }
                    }
                }
                if story.aspect != nil {
                    Picker("ملاءمة الإطار", selection: Binding(get: { story.fitMode }, set: { viewModel.setFitMode($0) })) {
                        ForEach(FitMode.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                }
                Picker("وضع التصدير", selection: Binding(get: { viewModel.effectiveMode }, set: { viewModel.setExportMode($0) })) {
                    ForEach(StoryExportMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!viewModel.canFastCopy)
                Text(viewModel.canFastCopy ? viewModel.effectiveMode.explanation : "تغيير المقاس يتطلب إعادة الترميز.")
                    .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                if viewModel.effectiveMode == .fastCopy && story.rule.snap != .keyframes {
                    Label("لقطع بلا إعادة ترميز ومطابق تماماً، اختر «إطارات مفتاحية» في نقاط القطع.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(Theme.Palette.accent)
                }
                if viewModel.effectiveMode == .reencode {
                    Button { showExportSettings = true } label: {
                        HStack {
                            Text("الترميز والجودة")
                            Spacer()
                            Text(story.exportSettings.codec.title + " • " + story.exportSettings.resolution.title + " • " + story.exportSettings.quality.title)
                                .foregroundStyle(Theme.Palette.textSecondary)
                            Image(systemName: "chevron.forward").font(.caption)
                        }
                        .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                }
                Picker("الحفظ في", selection: Binding(get: { story.exportSettings.destination }, set: { value in
                    var settings = story.exportSettings
                    settings.destination = value
                    viewModel.setExportSettings(settings)
                })) {
                    ForEach(ExportDestination.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
    }

    private var summaryCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "الملخص", systemImage: "list.bullet.rectangle")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    StatBadge(title: "عدد المقاطع", value: Fmt.int(viewModel.includedSegments.count), systemImage: "number")
                    StatBadge(title: "المدة الكلية", value: Fmt.duration(viewModel.includedSegments.reduce(0) { $0 + $1.range.duration.seconds }), systemImage: "timer")
                    StatBadge(title: "الدقة", value: viewModel.outputSize.map { Fmt.resolution(Int($0.width), Int($0.height)) } ?? "—", systemImage: "aspectratio")
                    StatBadge(title: "الحجم التقريبي", value: Fmt.bytes(viewModel.totalEstimatedBytes), systemImage: "externaldrive")
                }
                let warnings = viewModel.includedSegments.filter { viewModel.exceedsDurationLimit($0) || viewModel.exceedsFileLimit($0) }.count
                if warnings > 0 {
                    Label(Fmt.int(warnings) + " مقطع يتجاوز حدود المنصة — راجعها في المعرض.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Theme.Palette.warning)
                }
                ForEach(viewModel.segments.prefix(6)) { segment in
                    HStack {
                        Text(viewModel.displayName(for: segment)).font(.caption)
                            .foregroundStyle(segment.isIncluded ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                        Spacer()
                        Text(Fmt.durationPrecise(segment.range.duration.seconds)).font(Theme.Typo.mono)
                        Text(Fmt.bytes(viewModel.estimatedBytes(for: segment))).font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                if viewModel.segments.count > 6 {
                    Button("عرض كل المقاطع (" + Fmt.int(viewModel.segments.count) + ")") { showGallery = true }.font(.caption)
                }
            }
        }
    }

    private var exportBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.int(viewModel.includedSegments.count) + " مقطع").font(.subheadline.weight(.semibold))
                Text("≈ " + Fmt.bytes(viewModel.totalEstimatedBytes)).font(.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
            Button {
                if viewModel.exportAll() > 0 { Haptics.success() }
            } label: {
                Label("تصدير الكل", systemImage: "square.and.arrow.up.on.square.fill")
            }
            .buttonStyle(.csPrimary)
            .disabled(viewModel.includedSegments.isEmpty || viewModel.isSourceMissing)
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}
