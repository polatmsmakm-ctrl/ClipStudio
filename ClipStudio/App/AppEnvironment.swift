//
//  AppEnvironment.swift
//  ClipStudio — App (AppCore)
//
//  Composition root: creates every manager once and wires them together.
//  Injected into SwiftUI with `.environment(environment)`.
//  Part 2 adds Pro Studio preferences, saved color looks and the LUT library.
//  Part 6: proxy media for the Studio preview and the performance monitor
//  (heat / Low Power Mode / memory warnings).
//

import Foundation
import SwiftUI
import UIKit

@MainActor
@Observable
final class AppEnvironment {
    let settings = AppSettings()
    let toasts = ToastCenter()
    let router = AppRouter()
    let library: MediaLibrary
    let importer: MediaImportManager
    let projects: ProjectManager
    let presets: PresetManager
    let history: ExportHistoryStore
    let exportQueue: ExportQueue
    let backup: BackupManager
    let studioPrefs = StudioPreferences()
    let colorPresets = ColorPresetStore()
    let lutLibrary = LUTLibrary()
    let proxies: ProxyManager
    let performance = PerformanceMonitor.shared
    private let widgetBridge = WidgetBridge()

    init() {
        StorageManager.shared.ensureDirectories()
        StorageManager.shared.clearStaging()
        let library = MediaLibrary()
        let history = ExportHistoryStore()
        self.library = library
        self.importer = MediaImportManager(library: library)
        self.projects = ProjectManager()
        self.presets = PresetManager()
        self.history = history
        self.exportQueue = ExportQueue(library: library, history: history)
        self.backup = BackupManager()
        let proxies = ProxyManager(library: library)
        self.proxies = proxies
        proxies.shouldPause = { PerformanceMonitor.shared.shouldPauseBackgroundWork }
        library.onAssetAdded = { asset in proxies.autoGenerateIfNeeded(asset) }
        library.onAssetRemoved = { id in proxies.remove(id) }

        exportQueue.onStateChange = { [weak self] in self?.refreshWidget() }
        exportQueue.onJobFinished = { [weak self] job in
            guard let self else { return }
            switch job.status {
            case .completed: self.toasts.show("اكتمل تصدير: " + job.title, style: .success)
            case .failed: self.toasts.show("فشل تصدير: " + job.title, style: .error)
            default: break
            }
        }
        backup.onRestoreFinished = { [weak self] in
            guard let self else { return }
            self.library.reload()
            self.projects.reload()
            self.presets.reload()
            self.history.reload()
            self.colorPresets.reload()
            self.lutLibrary.reload()
            self.proxies.prune()
            AssistantMemory.shared.reload()
            self.refreshWidget()
        }
        // Memory warnings, heat and Low Power Mode are handled by PerformanceMonitor (Part 6).
        performance.refreshState()
        exportQueue.startIfNeeded()
        refreshWidget()
    }

    func refreshWidget() {
        widgetBridge.update(queue: exportQueue, projects: projects, history: history)
    }

    func handleScenePhase(_ phase: ScenePhase) {
        exportQueue.handleScenePhase(phase)
        if phase == .active {
            performance.refreshState()
            proxies.startIfNeeded()
        }
        if phase == .background { refreshWidget() }
    }

    func handleOpenURL(_ url: URL) {
        if url.scheme == "clipstudio" {
            switch url.host {
            case "exports": router.select(.exports)
            case "projects": router.select(.projects)
            case "stories": router.select(.stories)
            case "studio": router.select(.studio)
            default: router.select(.dashboard)
            }
        } else if url.pathExtension.lowercased() == "csbackup" {
            router.pendingBackupURL = url
            router.select(.settings)
        }
    }

    /// Default export settings with a platform preset applied.
    func exportSettings(for preset: PlatformPreset?) -> ExportSettings {
        guard let preset else { return settings.defaultExport }
        return preset.applying(to: settings.defaultExport)
    }
}
