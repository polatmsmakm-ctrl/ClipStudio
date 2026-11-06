//
//  ExportQueue.swift
//  ClipStudio — Engines/Export (batch processing & export manager)
//
//  Persistent sequential job queue used by Smart Stories, Merge, Batch and
//  (later) Pro Studio. Features: per-job and per-batch progress, pause/resume
//  (render jobs), cancel, retry, failure recovery after app termination,
//  automatic pause in the background and on critical thermal state,
//  move to Exports/ (never overwrites), optional save to Photos, history.
//

import Foundation
import SwiftUI
import UIKit

@MainActor
@Observable
final class ExportQueue {
    private(set) var jobs: [ExportJob] = []
    private(set) var isProcessing = false
    private(set) var thermalWarning: String?

    private let library: MediaLibrary
    private let history: ExportHistoryStore
    private let storage = StorageManager.shared
    private var controls: [UUID: RenderControl] = [:]
    private var runner: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lastProgressSave = Date.distantPast
    private var thermalObserver: NSObjectProtocol?

    /// Called whenever something widget-relevant changes.
    var onStateChange: (() -> Void)?
    /// Called when a job finishes (for toasts).
    var onJobFinished: ((ExportJob) -> Void)?

    private var queueURL: URL { storage.stateDirectory.appendingPathComponent("queue.json") }

    init(library: MediaLibrary, history: ExportHistoryStore) {
        self.library = library
        self.history = history
        loadAndRecover()
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleThermalState() }
        }
    }

    // MARK: Queries

    var activeJob: ExportJob? { jobs.first { $0.status == .running || $0.status == .paused } }
    var pendingCount: Int { jobs.filter { $0.status == .queued }.count }
    var unfinishedCount: Int { jobs.filter { !$0.status.isFinished }.count }
    var hasFinished: Bool { jobs.contains { $0.status.isFinished } }

    var overallProgress: Double {
        let relevant = jobs.filter { $0.status != .cancelled }
        guard !relevant.isEmpty else { return 0 }
        return relevant.reduce(0) { $0 + ($1.status == .completed ? 1 : $1.progress) } / Double(relevant.count)
    }

    func jobs(inBatch batchID: UUID) -> [ExportJob] { jobs.filter { $0.batchID == batchID } }

    func batchProgress(_ batchID: UUID) -> Double {
        let items = jobs(inBatch: batchID).filter { $0.status != .cancelled }
        guard !items.isEmpty else { return 0 }
        return items.reduce(0) { $0 + ($1.status == .completed ? 1 : $1.progress) } / Double(items.count)
    }

    /// Remaining time for the running job, from real elapsed time and progress.
    func remainingSeconds(for job: ExportJob) -> Double? {
        guard job.status == .running, let started = job.startedAt, job.progress > 0.03 else { return nil }
        let elapsed = Date().timeIntervalSince(started)
        return elapsed / job.progress * (1 - job.progress)
    }

    // MARK: Mutations

    func enqueue(_ newJobs: [ExportJob]) {
        guard !newJobs.isEmpty else { return }
        jobs.append(contentsOf: newJobs)
        persist()
        onStateChange?()
        startIfNeeded()
    }

    func pause(_ id: UUID) {
        guard let index = index(of: id), jobs[index].status == .running, jobs[index].payload.supportsPause else { return }
        controls[id]?.setPaused(true)
        jobs[index].status = .paused
        jobs[index].autoPaused = false
        persist()
        onStateChange?()
    }

    func resume(_ id: UUID) {
        guard let index = index(of: id), jobs[index].status == .paused else { return }
        controls[id]?.setPaused(false)
        jobs[index].status = .running
        jobs[index].autoPaused = false
        persist()
        onStateChange?()
    }

    func cancel(_ id: UUID) {
        guard let index = index(of: id), !jobs[index].status.isFinished else { return }
        if let control = controls[id] {
            control.cancel()
        } else {
            jobs[index].status = .cancelled
            jobs[index].finishedAt = Date()
            persist()
            onStateChange?()
        }
    }

    func cancelAll() {
        for job in jobs where !job.status.isFinished { cancel(job.id) }
    }

    func retry(_ id: UUID) {
        guard let index = index(of: id), jobs[index].status == .failed || jobs[index].status == .cancelled else { return }
        jobs[index].status = .queued
        jobs[index].progress = 0
        jobs[index].errorMessage = nil
        jobs[index].note = nil
        jobs[index].startedAt = nil
        jobs[index].finishedAt = nil
        persist()
        startIfNeeded()
    }

    func remove(_ id: UUID) {
        guard let index = index(of: id), jobs[index].status.isFinished || jobs[index].status == .queued else { return }
        jobs.remove(at: index)
        persist()
        onStateChange?()
    }

    func clearFinished() {
        jobs.removeAll { $0.status.isFinished }
        persist()
        onStateChange?()
    }

    func pauseAll() {
        for job in jobs where job.status == .running { pause(job.id) }
    }

    func resumeAll() {
        for job in jobs where job.status == .paused { resume(job.id) }
    }

    // MARK: Scene phase / thermal

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // GPU rendering is not allowed in the background; render jobs pause and resume on return.
            for index in jobs.indices where jobs[index].status == .running && jobs[index].payload.supportsPause {
                controls[jobs[index].id]?.setPaused(true)
                jobs[index].status = .paused
                jobs[index].autoPaused = true
                jobs[index].note = "توقف تلقائياً عند الخروج من التطبيق"
            }
            persist()
            beginBackgroundTaskIfNeeded()
        case .active:
            for index in jobs.indices where jobs[index].status == .paused && jobs[index].autoPaused {
                controls[jobs[index].id]?.setPaused(false)
                jobs[index].status = .running
                jobs[index].autoPaused = false
                jobs[index].note = nil
            }
            endBackgroundTask()
            persist()
            startIfNeeded()
        default:
            break
        }
        onStateChange?()
    }

    private func handleThermalState() {
        let state = ProcessInfo.processInfo.thermalState
        switch state {
        case .critical:
            thermalWarning = "الجهاز ساخن جداً — تم إيقاف التصدير مؤقتاً حتى يبرد."
            for index in jobs.indices where jobs[index].status == .running && jobs[index].payload.supportsPause {
                controls[jobs[index].id]?.setPaused(true)
                jobs[index].status = .paused
                jobs[index].autoPaused = true
                jobs[index].note = "توقف بسبب حرارة الجهاز"
            }
        case .serious:
            thermalWarning = "حرارة الجهاز مرتفعة — قد يتباطأ التصدير."
            resumeThermalPaused()
        default:
            thermalWarning = nil
            resumeThermalPaused()
        }
        onStateChange?()
    }

    private func resumeThermalPaused() {
        guard UIApplication.shared.applicationState == .active else { return }
        for index in jobs.indices where jobs[index].status == .paused && jobs[index].autoPaused {
            controls[jobs[index].id]?.setPaused(false)
            jobs[index].status = .running
            jobs[index].autoPaused = false
            jobs[index].note = nil
        }
    }

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTask == .invalid, jobs.contains(where: { $0.status == .running }) else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ClipStudio.Export") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Out of background time: stop passthrough jobs cleanly; they restart when the app returns.
                for job in self.jobs where job.status == .running { self.controls[job.id]?.cancel() }
                self.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: Runner

    func startIfNeeded() {
        guard runner == nil, jobs.contains(where: { $0.status == .queued }) else { return }
        runner = Task { [weak self] in
            await self?.runLoop()
            self?.runner = nil
        }
    }

    private func runLoop() async {
        isProcessing = true
        defer {
            isProcessing = false
            onStateChange?()
        }
        while let id = jobs.first(where: { $0.status == .queued })?.id {
            if UIApplication.shared.applicationState == .background { break }
            await run(id)
        }
    }

    private func run(_ id: UUID) async {
        guard let index = index(of: id) else { return }
        let control = RenderControl()
        controls[id] = control
        jobs[index].status = .running
        jobs[index].progress = 0
        jobs[index].startedAt = Date()
        jobs[index].errorMessage = nil
        persist()
        onStateChange?()

        let job = jobs[index]
        let media = library.urlMap()
        let ext = job.settings.container.fileExtension
        let tempURL = storage.renderTempURL(extension: ext)
        let progressHandler: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in self?.updateProgress(id, value) }
        }

        do {
            let outcome: ExportOutcome
            switch job.payload {
            case .render(let payload):
                outcome = try await ExportEngine.render(payload: payload, settings: job.settings, media: media,
                                                        outputURL: tempURL, control: control, progress: progressHandler)
            case .passthrough(let assetID, let range):
                guard let sourceURL = media[assetID] else { throw ExportError.missingMedia }
                outcome = try await ExportEngine.passthrough(sourceURL: sourceURL, range: range, container: job.settings.container,
                                                             outputURL: tempURL, control: control, progress: progressHandler)
            }
            let finalURL = storage.uniqueURL(in: storage.exportsDirectory, baseName: job.outputBaseName,
                                             ext: outcome.url.pathExtension.isEmpty ? ext : outcome.url.pathExtension)
            try FileManager.default.moveItem(at: outcome.url, to: finalURL)

            var savedToPhotos = false
            var note: String?
            if job.settings.destination.savesToPhotos {
                do {
                    try await PhotosSaver.saveVideo(at: finalURL)
                    savedToPhotos = true
                } catch {
                    note = error.localizedDescription
                }
            }
            history.add(ExportRecord(title: job.title, fileName: finalURL.lastPathComponent, createdAt: Date(),
                                     durationSeconds: outcome.durationSeconds, fileSize: outcome.fileSize,
                                     width: outcome.width, height: outcome.height, codec: outcome.codec,
                                     savedToPhotos: savedToPhotos, batchTitle: job.batchTitle))
            finish(id, status: .completed, outputFileName: finalURL.lastPathComponent, note: note)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: tempURL)
            if let i = self.index(of: id), jobs[i].autoPaused || UIApplication.shared.applicationState == .background {
                // Interrupted by the system — requeue to restart from the beginning.
                jobs[i].status = .queued
                jobs[i].progress = 0
                jobs[i].note = "سيُعاد التصدير عند العودة للتطبيق"
                persist()
            } else {
                finish(id, status: .cancelled, outputFileName: nil, note: nil)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            finish(id, status: .failed, outputFileName: nil, note: nil, error: error.localizedDescription)
        }
        controls[id] = nil
    }

    private func updateProgress(_ id: UUID, _ value: Double) {
        guard let index = index(of: id), jobs[index].status == .running else { return }
        jobs[index].progress = value
        if Date().timeIntervalSince(lastProgressSave) > 3 {
            lastProgressSave = Date()
            onStateChange?()
        }
    }

    private func finish(_ id: UUID, status: ExportStatus, outputFileName: String?, note: String?, error: String? = nil) {
        guard let index = index(of: id) else { return }
        jobs[index].status = status
        jobs[index].finishedAt = Date()
        jobs[index].outputFileName = outputFileName
        jobs[index].note = note
        jobs[index].errorMessage = error
        if status == .completed { jobs[index].progress = 1 }
        persist()
        onStateChange?()
        onJobFinished?(jobs[index])
    }

    // MARK: Persistence

    private func index(of id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }

    private func persist() {
        try? JSONStore.save(jobs, to: queueURL)
    }

    /// Jobs that were running when the app was terminated restart from the beginning.
    private func loadAndRecover() {
        var loaded = JSONStore.load([ExportJob].self, from: queueURL) ?? []
        for index in loaded.indices where loaded[index].status == .running || loaded[index].status == .paused {
            loaded[index].status = .queued
            loaded[index].progress = 0
            loaded[index].autoPaused = false
            loaded[index].note = "استُؤنف بعد إغلاق التطبيق"
        }
        jobs = loaded
        persist()
    }
}
