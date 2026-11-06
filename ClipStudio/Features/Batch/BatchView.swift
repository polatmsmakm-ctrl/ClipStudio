//
//  BatchView.swift
//  ClipStudio — Features/Batch (Batch Processing)
//
//  Select many files → one operation (split / convert / resize / compress / merge)
//  → jobs are queued in the export queue with per-file and overall progress,
//  pause/resume, cancellation, retry and history (Export Center).
//

import SwiftUI

@MainActor
@Observable
final class BatchViewModel {
    enum Operation: String, CaseIterable, Identifiable {
        case split, convert, resize, compress, merge

        var id: String { rawValue }

        var title: String {
            switch self {
            case .split: "تقسيم"
            case .convert: "تحويل"
            case .resize: "تغيير المقاس"
            case .compress: "ضغط"
            case .merge: "دمج"
            }
        }

        var symbol: String {
            switch self {
            case .split: "scissors"
            case .convert: "arrow.triangle.2.circlepath"
            case .resize: "aspectratio"
            case .compress: "arrow.down.right.and.arrow.up.left"
            case .merge: "rectangle.stack.badge.plus"
            }
        }

        var explanation: String {
            switch self {
            case .split: "يقسم كل ملف حسب القاعدة إلى مقاطع منفصلة."
            case .convert: "يعيد ترميز كل ملف بالحاوية والترميز ومعدل الإطارات المختار."
            case .resize: "يحوّل كل ملف إلى مقاس جديد مع ملاءمة ذكية للإطار."
            case .compress: "يقلل الحجم بخفض معدل البت والدقة."
            case .merge: "يدمج الملفات المحددة بالترتيب في فيديو واحد."
            }
        }
    }

    let env: AppEnvironment
    var operation: Operation = .split
    var selection: [UUID] = []
    var rule = SplitRule()
    var presetKey: String?
    var splitMode: StoryExportMode = .reencode
    var aspect: AspectRatio = .portrait9x16
    var fitMode: FitMode = .fitBlur
    var compressLevel: QualityLevel = .medium
    var compressResolution: ResolutionPreset = .p720
    var settings: ExportSettings
    private(set) var lastBatchID: UUID?

    init(env: AppEnvironment) {
        self.env = env
        self.settings = env.settings.defaultExport
    }

    var assets: [MediaAsset] { selection.compactMap { env.library.asset($0) } }

    var preset: PlatformPreset? { env.presets.preset(key: presetKey) }

    func applyPreset(_ preset: PlatformPreset?) {
        presetKey = preset?.key
        guard let preset else { return }
        aspect = preset.aspect
        fitMode = preset.fitMode
        settings = preset.applying(to: settings)
        if let max = preset.maxDuration {
            rule.mode = .maxDuration
            rule.seconds = max
        }
        rule.hardMaximum = preset.maxDuration
    }

    /// Effective settings for the chosen operation.
    var effectiveSettings: ExportSettings {
        var result = settings
        switch operation {
        case .compress:
            result.quality = compressLevel
            result.resolution = compressResolution
        case .convert:
            result.resolution = .matchCanvas
        default:
            break
        }
        return result
    }

    func makeJobs() -> [ExportJob] {
        let batchID = UUID()
        let title = operation.title + " " + Fmt.shortDate(Date())
        var jobs: [ExportJob] = []
        let settings = effectiveSettings

        func renderJob(_ name: String, timeline: Timeline, canvas: ProjectSettings, seconds: Double) -> ExportJob {
            var job = ExportJob(batchID: batchID, batchTitle: title, title: name, outputBaseName: name,
                                payload: .render(RenderPayload(timeline: timeline, projectSettings: canvas, range: nil)),
                                settings: settings)
            let size = ExportGeometry.outputSize(canvas: canvas.canvasSize, resolution: settings.resolution)
            let fps = settings.frameRate.value ?? canvas.frameRate
            job.estimatedBytes = BitrateCalculator.estimatedBytes(durationSeconds: seconds,
                                                                  videoBitrate: BitrateCalculator.videoBitrate(size: size, fps: fps, settings: settings),
                                                                  audioKbps: settings.audioBitrateKbps)
            return job
        }

        switch operation {
        case .split:
            for asset in assets {
                let duration = asset.durationSeconds ?? 0
                let ranges = SegmentPlanner.plan(duration: duration, rule: rule)
                let fps = settings.frameRate.value ?? Int((asset.frameRate ?? 30).rounded())
                for (index, range) in ranges.enumerated() {
                    let name = asset.displayName + " - " + String(format: "%02d", index + 1)
                    let value = TimeRangeValue(startSeconds: range.start, endSeconds: range.end)
                    if splitMode == .fastCopy && presetKey == nil {
                        var job = ExportJob(batchID: batchID, batchTitle: title, title: name, outputBaseName: name,
                                            payload: .passthrough(assetID: asset.id, range: value), settings: settings)
                        let rate = asset.estimatedBitrate ?? 8_000_000
                        job.estimatedBytes = Int64(rate * range.duration / 8)
                        jobs.append(job)
                    } else {
                        let targetAspect: AspectRatio? = presetKey == nil ? nil : aspect
                        let (timeline, canvas) = StoryTimelineFactory.make(source: asset, segment: value, aspect: targetAspect,
                                                                           fitMode: fitMode, frameRate: fps)
                        jobs.append(renderJob(name, timeline: timeline, canvas: canvas, seconds: range.duration))
                    }
                }
            }
        case .convert, .compress, .resize:
            for asset in assets {
                let duration = asset.durationSeconds ?? 0
                guard duration > 0 else { continue }
                let fps = settings.frameRate.value ?? Int((asset.frameRate ?? 30).rounded())
                let targetAspect: AspectRatio? = operation == .resize ? aspect : nil
                let suffix = operation == .resize ? " - " + aspect.title.replacingOccurrences(of: ":", with: "x")
                    : (operation == .compress ? " - مضغوط" : " - محوّل")
                let (timeline, canvas) = StoryTimelineFactory.make(source: asset, segment: TimeRangeValue(startSeconds: 0, endSeconds: duration),
                                                                   aspect: targetAspect, fitMode: fitMode, frameRate: fps)
                jobs.append(renderJob(asset.displayName + suffix, timeline: timeline, canvas: canvas, seconds: duration))
            }
        case .merge:
            var config = MergeConfig()
            config.items = assets.map { MergeItem(assetID: $0.id) }
            config.fitMode = fitMode
            var map: [UUID: MediaAsset] = [:]
            assets.forEach { map[$0.id] = $0 }
            if let pair = try? MergeTimelineFactory.make(config: config, assets: map) {
                let (timeline, canvas) = pair
                jobs.append(renderJob(title, timeline: timeline, canvas: canvas, seconds: timeline.duration.seconds))
            }
        }
        lastBatchID = jobs.isEmpty ? lastBatchID : batchID
        return jobs
    }
}

struct BatchView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var viewModel: BatchViewModel?

    var body: some View {
        Group {
            if let viewModel {
                BatchContent(viewModel: viewModel)
            } else {
                ProgressView()
            }
        }
        .screenBackground()
        .navigationTitle("المعالجة الدفعية")
        .task { if viewModel == nil { viewModel = BatchViewModel(env: env) } }
    }
}

private struct BatchContent: View {
    @Environment(AppEnvironment.self) private var env
    @Bindable var viewModel: BatchViewModel
    @State private var showPicker = false
    @State private var showSettings = false
    @State private var preview: [ExportJob] = []

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.md) {
                filesCard
                operationCard
                settingsCard
                if let batchID = viewModel.lastBatchID, !env.exportQueue.jobs(inBatch: batchID).isEmpty {
                    batchProgressCard(batchID)
                }
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) { actionBar }
        .sheet(isPresented: $showPicker) {
            MediaPickerSheet(title: "اختر الملفات", kinds: [.video], allowsMultiple: true, confirmTitle: "إضافة") { assets in
                for asset in assets where !viewModel.selection.contains(asset.id) { viewModel.selection.append(asset.id) }
            }
        }
        .sheet(isPresented: $showSettings) {
            ExportSettingsSheet(title: "إعدادات الدفعة", settings: $viewModel.settings,
                                durationSeconds: viewModel.assets.reduce(0) { $0 + ($1.durationSeconds ?? 0) }, canvas: nil)
        }
        .keyboardDoneToolbar()
    }

    private var filesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(title: "1. الملفات", subtitle: Fmt.int(viewModel.selection.count) + " ملف محدد", systemImage: "film.stack")
                    Button { showPicker = true } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                        .accessibilityLabel("إضافة ملفات")
                }
                if viewModel.assets.isEmpty {
                    Button { showPicker = true } label: { Label("اختيار الملفات", systemImage: "plus") }
                        .buttonStyle(.csSecondary)
                } else {
                    ForEach(viewModel.assets) { asset in
                        HStack(spacing: 10) {
                            MediaThumbnailView(source: .asset(asset, env.library.url(for: asset), 1)).frame(width: 72, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(asset.displayName).font(.subheadline).lineLimit(1)
                                Text(asset.durationText + " • " + asset.resolutionText + " • " + Fmt.bytes(asset.fileSize))
                                    .font(.caption2).foregroundStyle(Theme.Palette.textSecondary)
                            }
                            Spacer()
                            Button { viewModel.selection.removeAll { $0 == asset.id } } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(Theme.Palette.danger)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("إزالة " + asset.displayName)
                        }
                    }
                }
            }
        }
    }

    private var operationCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "2. العملية", systemImage: "gearshape.2")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(BatchViewModel.Operation.allCases) { op in
                            ChipButton(title: op.title, systemImage: op.symbol, isSelected: viewModel.operation == op) { viewModel.operation = op }
                        }
                    }
                }
                Text(viewModel.operation.explanation).font(.caption).foregroundStyle(Theme.Palette.textSecondary)

                switch viewModel.operation {
                case .split:
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ChipButton(title: "بدون منصة", isSelected: viewModel.presetKey == nil) { viewModel.applyPreset(nil) }
                            ForEach(env.presets.platforms) { preset in
                                ChipButton(title: preset.name, systemImage: preset.symbol, isSelected: viewModel.presetKey == preset.key) {
                                    viewModel.applyPreset(preset)
                                }
                            }
                        }
                    }
                    Picker("الطريقة", selection: $viewModel.rule.mode) {
                        ForEach(SplitModeKind.allCases.filter { $0 != .customDurations }, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if viewModel.rule.mode == .equalParts {
                        DecimalField(title: "عدد الأجزاء", value: Binding(get: { Double(viewModel.rule.parts) }, set: { viewModel.rule.parts = max(1, Int($0.rounded())) }),
                                     range: 1...200, step: 1, digits: 0)
                    } else {
                        DecimalField(title: "المدة", value: $viewModel.rule.seconds, range: 1...3600, step: 5, digits: 0, unit: "ث")
                    }
                    Picker("الوضع", selection: $viewModel.splitMode) {
                        ForEach(StoryExportMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(viewModel.presetKey != nil)
                    if viewModel.presetKey != nil {
                        Text("المنصة تغيّر المقاس، لذلك يُستخدم الوضع الدقيق.").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                    }
                case .resize:
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(AspectRatio.common) { aspect in
                                ChipButton(title: aspect.label, isSelected: viewModel.aspect == aspect) { viewModel.aspect = aspect }
                            }
                        }
                    }
                    Picker("الملاءمة", selection: $viewModel.fitMode) {
                        ForEach(FitMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                case .compress:
                    Picker("الجودة", selection: $viewModel.compressLevel) {
                        ForEach([QualityLevel.low, .medium, .high], id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("الدقة", selection: $viewModel.compressResolution) {
                        ForEach([ResolutionPreset.p720, .p1080, .matchCanvas], id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                case .convert:
                    Text("اختر الحاوية والترميز ومعدل الإطارات من الإعدادات أدناه.").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                case .merge:
                    Picker("الملاءمة", selection: $viewModel.fitMode) {
                        ForEach(FitMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("الترتيب حسب ترتيب الاختيار. للانتقالات والموسيقى استخدم «الدمج الذكي».")
                        .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
    }

    private var settingsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "3. الإعدادات", systemImage: "slider.horizontal.3")
                let settings = viewModel.effectiveSettings
                Button { showSettings = true } label: {
                    HStack {
                        Text("الترميز والجودة")
                        Spacer()
                        Text(settings.container.title + " • " + settings.codec.title + " • " + settings.resolution.title + " • " + settings.quality.title)
                            .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                        Image(systemName: "chevron.forward").font(.caption)
                    }
                }
                .buttonStyle(.plain)
                Picker("الحفظ في", selection: $viewModel.settings.destination) {
                    ForEach(ExportDestination.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
    }

    private func batchProgressCard(_ batchID: UUID) -> some View {
        let jobs = env.exportQueue.jobs(inBatch: batchID)
        let done = jobs.filter { $0.status == .completed }.count
        return Button { env.router.select(.exports) } label: {
            GlassCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("آخر دفعة").font(.headline)
                        Spacer()
                        Text(Fmt.int(done) + " / " + Fmt.int(jobs.count)).font(Theme.Typo.mono)
                    }
                    ProgressBarView(progress: env.exportQueue.batchProgress(batchID))
                    Text("اضغط لفتح مركز التصدير").font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.Palette.textPrimary)
    }

    private var actionBar: some View {
        Button {
            let jobs = viewModel.makeJobs()
            guard !jobs.isEmpty else {
                env.toasts.show("اختر ملفات صالحة أولاً.", style: .warning)
                return
            }
            env.exportQueue.enqueue(jobs)
            env.toasts.show("أُضيف " + Fmt.int(jobs.count) + " مهمة لقائمة التصدير", style: .success)
        } label: {
            Label("إضافة إلى قائمة التصدير", systemImage: "tray.and.arrow.down.fill")
        }
        .buttonStyle(.csPrimary)
        .disabled(viewModel.selection.isEmpty || (viewModel.operation == .merge && viewModel.selection.count < 2))
        .padding(Theme.Space.md)
        .background(.ultraThinMaterial)
    }
}
