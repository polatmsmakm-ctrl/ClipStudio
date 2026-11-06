//
//  ExportCenterView.swift
//  ClipStudio — Features/Export (Export Manager)
//
//  Queue: overall + per-batch + per-job progress (real values from the engine),
//  remaining-time estimate, pause/resume, cancel, retry, remove.
//  History: share, save to Photos, open in Files, delete (with confirmation).
//

import SwiftUI

struct ExportCenterView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var tab: CenterTab = .queue
    @State private var search = ""
    @State private var shareItem: ShareItem?
    @State private var deleteRecord: ExportRecord?

    enum CenterTab: String, CaseIterable {
        case queue, history
        var title: String { self == .queue ? "قائمة التصدير" : "السجل" }
    }

    var body: some View {
        List {
            Section {
                Picker("العرض", selection: $tab) {
                    ForEach(CenterTab.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)

            if tab == .queue { queueSections } else { historySection }
        }
        .listStyle(.insetGrouped)
        .screenBackground()
        .navigationTitle("مركز التصدير")
        .searchable(text: $search, prompt: "بحث في السجل")
        .toolbar {
            if tab == .queue {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { env.exportQueue.pauseAll() } label: { Label("إيقاف الكل مؤقتاً", systemImage: "pause") }
                        Button { env.exportQueue.resumeAll() } label: { Label("استئناف الكل", systemImage: "play") }
                        Button(role: .destructive) { env.exportQueue.cancelAll() } label: { Label("إلغاء الكل", systemImage: "xmark") }
                        Button { env.exportQueue.clearFinished() } label: { Label("مسح المنتهية", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .sheet(item: $shareItem) { item in ShareSheet(items: item.urls) }
        .confirmationDialog("حذف الملف المصدَّر؟", isPresented: Binding(get: { deleteRecord != nil }, set: { if !$0 { deleteRecord = nil } }),
                            titleVisibility: .visible) {
            Button("حذف الملف من الجهاز", role: .destructive) {
                if let record = deleteRecord { env.history.remove(record, deleteFile: true) }
                deleteRecord = nil
            }
            Button("إزالة من السجل فقط") {
                if let record = deleteRecord { env.history.remove(record, deleteFile: false) }
                deleteRecord = nil
            }
        } message: {
            Text("النسخة المحفوظة في الصور (إن وُجدت) لا تتأثر.")
        }
        .keyboardDoneToolbar()
    }

    // MARK: Queue

    @ViewBuilder
    private var queueSections: some View {
        let queue = env.exportQueue
        if let warning = queue.thermalWarning {
            Section {
                Label(warning, systemImage: "thermometer.sun.fill").foregroundStyle(Theme.Palette.warning)
            }
        }
        if queue.jobs.isEmpty {
            Section {
                EmptyStateView(systemImage: "square.and.arrow.up.on.square", title: "لا توجد مهام تصدير",
                               message: "عند تصدير قصة أو دمج أو دفعة ستظهر المهام هنا مع تقدّمها الفعلي.")
            }
            .listRowBackground(Color.clear)
        } else {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("التقدم الكلي").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(Fmt.percent(queue.overallProgress)).font(Theme.Typo.mono)
                    }
                    ProgressBarView(progress: queue.overallProgress, height: 8)
                    Text("متبقٍ: " + Fmt.int(queue.unfinishedCount) + " • في الانتظار: " + Fmt.int(queue.pendingCount))
                        .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Theme.Palette.surface.opacity(0.7))

            ForEach(groups, id: \.key) { group in
                Section {
                    ForEach(group.jobs) { job in
                        JobRow(job: job)
                            .swipeActions(edge: .trailing) {
                                if job.status.isFinished || job.status == .queued {
                                    Button(role: .destructive) { env.exportQueue.remove(job.id) } label: { Label("إزالة", systemImage: "trash") }
                                }
                            }
                    }
                } header: {
                    if let batchID = group.batchID {
                        HStack {
                            Text(group.title).textCase(nil)
                            Spacer()
                            Text(Fmt.percent(queue.batchProgress(batchID))).font(Theme.Typo.mono)
                        }
                    } else {
                        Text(group.title).textCase(nil)
                    }
                }
                .listRowBackground(Theme.Palette.surface.opacity(0.7))
            }
        }
    }

    private struct JobGroup {
        let key: String
        let batchID: UUID?
        let title: String
        let jobs: [ExportJob]
    }

    private var groups: [JobGroup] {
        var order: [String] = []
        var buckets: [String: [ExportJob]] = [:]
        for job in env.exportQueue.jobs {
            let key = job.batchID?.uuidString ?? "single"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(job)
        }
        return order.map { key in
            let jobs = buckets[key] ?? []
            return JobGroup(key: key, batchID: jobs.first?.batchID,
                            title: jobs.first?.batchTitle ?? "تصديرات فردية", jobs: jobs)
        }
    }

    // MARK: History

    @ViewBuilder
    private var historySection: some View {
        let records = env.history.records.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
        if records.isEmpty {
            Section {
                EmptyStateView(systemImage: "clock", title: "السجل فارغ", message: "الفيديوهات المصدّرة تظهر هنا، وتجدها أيضاً في تطبيق الملفات › ClipStudio › Exports.")
            }
            .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(records) { record in
                    HistoryRow(record: record, onShare: { shareItem = ShareItem(urls: [env.history.fileURL(for: record)]) },
                               onDelete: { deleteRecord = record })
                }
            } header: {
                Text(Fmt.int(records.count) + " ملف • " + Fmt.bytes(env.history.totalBytes)).textCase(nil)
            }
            .listRowBackground(Theme.Palette.surface.opacity(0.7))
        }
    }
}

private struct JobRow: View {
    @Environment(AppEnvironment.self) private var env
    let job: ExportJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(Theme.Palette.textSecondary).lineLimit(2)
                }
                Spacer()
                controls
            }
            if job.status == .running || job.status == .paused {
                ProgressBarView(progress: job.progress, tint: job.status == .paused ? Theme.Palette.textSecondary : Theme.Palette.accent)
            }
            if let error = job.errorMessage {
                Text(error).font(.caption).foregroundStyle(Theme.Palette.danger)
            }
            if let note = job.note {
                Text(note).font(.caption2).foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(.vertical, 4)
        .foregroundStyle(Theme.Palette.textPrimary)
    }

    private var icon: String {
        switch job.status {
        case .queued: "clock"
        case .running: "arrow.down.circle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private var color: Color {
        switch job.status {
        case .completed: Theme.Palette.success
        case .failed: Theme.Palette.danger
        case .cancelled: Theme.Palette.textTertiary
        default: Theme.Palette.accent
        }
    }

    private var subtitle: String {
        var parts = [job.status.title]
        switch job.payload {
        case .passthrough: parts.append("نسخ مباشر")
        case .render: parts.append(job.settings.codec.title + " • " + job.settings.resolution.title)
        }
        if job.status == .running || job.status == .paused { parts.append(Fmt.percent(job.progress)) }
        if let remaining = env.exportQueue.remainingSeconds(for: job) { parts.append("متبقٍ ≈ " + Fmt.duration(remaining)) }
        if job.status == .queued, job.estimatedBytes > 0 { parts.append("≈ " + Fmt.bytes(job.estimatedBytes)) }
        if job.status == .completed, let name = job.outputFileName { parts.append(name) }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 14) {
            switch job.status {
            case .running:
                if job.payload.supportsPause {
                    Button { env.exportQueue.pause(job.id) } label: { Image(systemName: "pause.fill") }
                        .accessibilityLabel("إيقاف مؤقت")
                }
                Button { env.exportQueue.cancel(job.id) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("إلغاء")
            case .paused:
                Button { env.exportQueue.resume(job.id) } label: { Image(systemName: "play.fill") }
                    .accessibilityLabel("استئناف")
                Button { env.exportQueue.cancel(job.id) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("إلغاء")
            case .queued:
                Button { env.exportQueue.cancel(job.id) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("إلغاء")
            case .failed, .cancelled:
                Button { env.exportQueue.retry(job.id) } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("إعادة المحاولة")
            case .completed:
                EmptyView()
            }
        }
        .buttonStyle(.borderless)
        .font(.body.weight(.semibold))
    }
}

private struct HistoryRow: View {
    @Environment(AppEnvironment.self) private var env
    let record: ExportRecord
    let onShare: () -> Void
    let onDelete: () -> Void
    @State private var preview = false

    var body: some View {
        let url = env.history.fileURL(for: record)
        let exists = env.history.fileExists(record)
        HStack(spacing: 12) {
            if exists {
                MediaThumbnailView(source: .file(url, 0.5)).frame(width: 84, height: 52)
                    .onTapGesture { preview = true }
            } else {
                ZStack {
                    Theme.Palette.surfaceRaised
                    Image(systemName: "questionmark.folder").foregroundStyle(Theme.Palette.textTertiary)
                }
                .frame(width: 84, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(Fmt.duration(record.durationSeconds) + " • " + Fmt.resolution(record.width, record.height) + " • " + Fmt.bytes(record.fileSize))
                    .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                HStack(spacing: 6) {
                    Text(Fmt.date(record.createdAt)).font(.caption2).foregroundStyle(Theme.Palette.textTertiary)
                    if record.savedToPhotos { StatusPill(text: "في الصور", color: Theme.Palette.success, systemImage: "photo") }
                    if !exists { StatusPill(text: "الملف محذوف", color: Theme.Palette.textTertiary) }
                }
            }
            Spacer()
            Menu {
                if exists {
                    Button { preview = true } label: { Label("تشغيل", systemImage: "play.fill") }
                    Button(action: onShare) { Label("مشاركة", systemImage: "square.and.arrow.up") }
                    Button { FilesAppLink.open(url) } label: { Label("فتح في الملفات", systemImage: "folder") }
                    if !record.savedToPhotos {
                        Button {
                            Task {
                                do {
                                    try await PhotosSaver.saveVideo(at: url)
                                    env.history.markSavedToPhotos(record.id)
                                    env.toasts.show("تم الحفظ في الصور", style: .success)
                                } catch {
                                    env.toasts.show(error.localizedDescription, style: .error)
                                }
                            }
                        } label: { Label("حفظ في الصور", systemImage: "photo.badge.plus") }
                    }
                }
                Button(role: .destructive, action: onDelete) { Label("حذف", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
        }
        .foregroundStyle(Theme.Palette.textPrimary)
        .sheet(isPresented: $preview) { ExportedFilePlayer(url: url, title: record.title) }
    }
}

struct ExportedFilePlayer: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let title: String
    @State private var player = PlayerController()

    var body: some View {
        NavigationStack {
            VideoPreview(controller: player)
                .padding(Theme.Space.md)
                .screenBackground()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("تم") { dismiss() } } }
                .onAppear {
                    player.load(url: url)
                    player.play()
                }
                .onDisappear { player.pause() }
        }
    }
}
