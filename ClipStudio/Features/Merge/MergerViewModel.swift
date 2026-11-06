//
//  MergerViewModel.swift
//  ClipStudio — Features/Merge (Smart Video Merger)
//
//  Ordering, trimming, transitions, music, audio continuity, resolution/frame-rate
//  matching, aspect conversion, live preview (same GPU pipeline as export) and export.
//

import Foundation
import SwiftUI
import AVFoundation

@MainActor
@Observable
final class MergerViewModel {
    let env: AppEnvironment
    private(set) var project: EditProject
    let player = PlayerController()
    private(set) var isBuildingPreview = false
    private(set) var previewError: String?
    private(set) var previewIsStale = true
    private var previewTask: Task<Void, Never>?

    init?(projectID: UUID, env: AppEnvironment) {
        guard let loaded = env.projects.load(projectID), loaded.merge != nil else { return nil }
        self.env = env
        self.project = loaded
        env.projects.beginSession(projectID)
    }

    var config: MergeConfig { project.merge ?? MergeConfig() }

    struct Entry: Identifiable {
        let item: MergeItem
        let asset: MediaAsset?
        var id: UUID { item.id }
    }

    var items: [Entry] {
        config.items.map { Entry(item: $0, asset: env.library.asset($0.assetID)) }
    }

    var musicAsset: MediaAsset? { config.music.flatMap { env.library.asset($0.assetID) } }

    var assetMap: [UUID: MediaAsset] {
        var map: [UUID: MediaAsset] = [:]
        for item in config.items { if let a = env.library.asset(item.assetID) { map[a.id] = a } }
        if let music = musicAsset { map[music.id] = music }
        return map
    }

    var missingCount: Int {
        config.items.filter { id in env.library.asset(id.assetID).map { env.library.isMissing($0) } ?? true }.count
    }

    var built: (Timeline, ProjectSettings)? {
        try? MergeTimelineFactory.make(config: config, assets: assetMap)
    }

    var totalDuration: Double { built?.0.duration.seconds ?? 0 }

    var outputSize: CGSize? {
        guard let settings = built?.1 else { return nil }
        return ExportGeometry.outputSize(canvas: settings.canvasSize, resolution: config.exportSettings.resolution)
    }

    var outputFrameRate: Int {
        config.exportSettings.frameRate.value ?? (built?.1.frameRate ?? 30)
    }

    var estimatedBytes: Int64 {
        guard let size = outputSize else { return 0 }
        let bitrate = BitrateCalculator.videoBitrate(size: size, fps: outputFrameRate, settings: config.exportSettings)
        return BitrateCalculator.estimatedBytes(durationSeconds: totalDuration, videoBitrate: bitrate,
                                                audioKbps: config.exportSettings.audioBitrateKbps)
    }

    // MARK: Mutations

    func mutate(_ change: (inout MergeConfig) -> Void) {
        guard var merge = project.merge else { return }
        change(&merge)
        project.merge = merge
        project.coverAssetID = merge.items.first?.assetID
        previewIsStale = true
        env.projects.scheduleAutosave(project)
    }

    func rename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        project.name = trimmed
        env.projects.scheduleAutosave(project)
    }

    func add(_ assets: [MediaAsset]) {
        mutate { merge in
            for asset in assets where asset.kind != .audio { merge.items.append(MergeItem(assetID: asset.id)) }
        }
    }

    func setMusic(_ asset: MediaAsset?) {
        mutate { merge in merge.music = asset.map { MusicSettings(assetID: $0.id) } }
    }

    func move(from source: IndexSet, to destination: Int) { mutate { $0.items.move(fromOffsets: source, toOffset: destination) } }
    func remove(at offsets: IndexSet) { mutate { $0.items.remove(atOffsets: offsets) } }
    func remove(_ id: UUID) { mutate { $0.items.removeAll { $0.id == id } } }

    func setTrim(_ id: UUID, range: TimeRangeValue?) {
        mutate { merge in
            guard let index = merge.items.firstIndex(where: { $0.id == id }) else { return }
            merge.items[index].trim = range
        }
    }

    func setImageDuration(_ id: UUID, seconds: Double) {
        mutate { merge in
            guard let index = merge.items.firstIndex(where: { $0.id == id }) else { return }
            merge.items[index].imageDuration = max(0.5, seconds)
        }
    }

    // MARK: Preview

    func rebuildPreview() {
        previewTask?.cancel()
        guard let pair = built else {
            previewError = MergeTimelineFactory.FactoryError.noItems.errorDescription
            return
        }
        let (timeline, settings) = pair
        isBuildingPreview = true
        previewError = nil
        let media = env.library.urlMap()
        let size = CompositionBuilder.previewSize(canvas: settings.canvasSize, maxShortSide: env.settings.previewQuality.maxShortSide)
        previewTask = Task { [weak self] in
            do {
                let result = try await CompositionBuilder(media: media).build(timeline: timeline, settings: settings,
                                                                              renderSize: size, frameRate: settings.frameRate)
                guard let self, !Task.isCancelled else { return }
                self.player.frameRate = Double(settings.frameRate)
                self.player.load(item: result.makePlayerItem())
                self.isBuildingPreview = false
                self.previewIsStale = false
                if !result.warnings.isEmpty { self.env.toasts.show(result.warnings.joined(separator: "\n"), style: .warning) }
            } catch {
                self?.isBuildingPreview = false
                self?.previewError = error.localizedDescription
            }
        }
    }

    // MARK: Export

    @discardableResult
    func export() -> Bool {
        guard let pair = built else {
            env.toasts.show(MergeTimelineFactory.FactoryError.noItems.errorDescription ?? "", style: .warning)
            return false
        }
        let (timeline, settings) = pair
        guard missingCount == 0 else {
            env.toasts.show("بعض الملفات مفقودة — اربطها من مكتبة الوسائط.", style: .error)
            return false
        }
        var job = ExportJob(title: project.name, outputBaseName: project.name,
                            payload: .render(RenderPayload(timeline: timeline, projectSettings: settings, range: nil)),
                            settings: config.exportSettings)
        job.estimatedBytes = estimatedBytes
        env.exportQueue.enqueue([job])
        env.projects.flushAutosave(project)
        env.toasts.show("أُضيف الدمج لقائمة التصدير", style: .success)
        return true
    }

    func close() {
        previewTask?.cancel()
        player.pause()
        env.projects.flushAutosave(project)
        env.projects.endSession()
    }
}
