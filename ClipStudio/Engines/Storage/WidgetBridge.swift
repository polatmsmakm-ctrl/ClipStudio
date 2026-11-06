//
//  WidgetBridge.swift
//  ClipStudio — Engines/Storage
//
//  Writes the widget snapshot into the App Group and reloads widget timelines
//  (throttled). Does nothing when the App Group is unavailable.
//

import Foundation
import WidgetKit

@MainActor
final class WidgetBridge {
    private var lastReload = Date.distantPast
    private var pending: Task<Void, Never>?

    func update(queue: ExportQueue, projects: ProjectManager, history: ExportHistoryStore) {
        guard AppGroup.isAvailable else { return }
        var active: WidgetSnapshot.ActiveExport?
        if let job = queue.activeJob {
            active = WidgetSnapshot.ActiveExport(title: job.title, progress: job.progress, statusText: job.status.title)
        }
        let last = history.records.first
        let snapshot = WidgetSnapshot(
            updatedAt: Date(),
            activeExport: active,
            queuedCount: queue.pendingCount,
            completedToday: history.completedToday,
            lastExportTitle: last?.title,
            lastExportDate: last?.createdAt,
            recentProjects: projects.summaries.prefix(3).map {
                WidgetSnapshot.RecentProject(id: $0.id, name: $0.name, symbol: $0.kind.symbol, modifiedAt: $0.modifiedAt)
            }
        )
        snapshot.save()
        scheduleReload()
    }

    private func scheduleReload() {
        let elapsed = Date().timeIntervalSince(lastReload)
        if elapsed > 15 {
            lastReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
            return
        }
        guard pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((15 - elapsed) * 1_000_000_000))
            guard let self else { return }
            self.lastReload = Date()
            self.pending = nil
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
