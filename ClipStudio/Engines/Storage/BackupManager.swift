//
//  BackupManager.swift
//  ClipStudio — Engines/Storage
//
//  Backup & restore through the Files app / share sheet.
//  Restore MERGES into existing data: nothing on the device is deleted,
//  existing files are never overwritten unless the backup's project is newer.
//  Part 2 adds LUTs, looks and the reversed registry; Part 3 adds motion presets,
//  text styles, the sound-effect registry and transcripts; Part 4 adds editing
//  styles (Editing DNA) and Studio templates; Part 5 adds Content Studio packs.
//  The Gemini key (Keychain) is never part of a backup. Part 6: assistant plan
//  history and memory are restored (merged); proxy files are never backed up.
//

import Foundation

struct RestoreSummary {
    var projectsAdded = 0
    var projectsUpdated = 0
    var mediaAdded = 0
    var presetsAdded = 0
    var exportsAdded = 0

    var text: String {
        "المشاريع: \(projectsAdded) جديد، \(projectsUpdated) محدّث • الوسائط: \(mediaAdded) • المنصات: \(presetsAdded) • الصادرات: \(exportsAdded)"
    }
}

@MainActor
@Observable
final class BackupManager {
    private(set) var isWorking = false
    private(set) var progress: Double = 0
    private(set) var statusText = ""
    private var cancelFlag = CancelFlag()

    private let storage = StorageManager.shared

    /// Called after a restore so stores reload from disk.
    var onRestoreFinished: (() -> Void)?

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.withLock { value } }
        func cancel() { lock.withLock { value = true } }
    }

    func cancel() { cancelFlag.cancel() }

    // MARK: Create

    func createBackup(includeMedia: Bool, includeExports: Bool) async throws -> URL {
        isWorking = true
        progress = 0
        statusText = "جارٍ تجهيز الملفات…"
        cancelFlag = CancelFlag()
        defer { isWorking = false }

        let storage = self.storage
        let flag = cancelFlag
        let stamp = Self.stampFormatter.string(from: Date())
        let destination = storage.uniqueURL(in: storage.backupsDirectory, baseName: "ClipStudio-Backup-\(stamp)", ext: "csbackup")

        statusText = "جارٍ إنشاء النسخة الاحتياطية…"
        try await Task.detached(priority: .userInitiated) { [weak self] in
            var entries: [BackupArchive.Entry] = []
            entries += Self.collect(storage.projectsDirectory, prefix: "data/Projects")
            entries += Self.collect(storage.presetsDirectory, prefix: "data/Presets")
            // Proxies are device-local caches (Part 6) and are rebuilt, never backed up.
            entries += Self.collect(storage.stateDirectory, prefix: "data/State").filter {
                !$0.relativePath.hasSuffix("queue.json") && !$0.relativePath.hasSuffix("proxies.json")
            }
            if includeMedia { entries += Self.collect(storage.mediaDirectory, prefix: "data/Media") }
            if includeExports { entries += Self.collect(storage.exportsDirectory, prefix: "exports") }
            try BackupArchive.write(entries: entries, to: destination, progress: { done, total in
                let fraction = total > 0 ? Double(done) / Double(total) : 1
                Task { @MainActor in self?.progress = fraction }
            }, isCancelled: { flag.isCancelled })
        }.value

        progress = 1
        statusText = "اكتملت النسخة الاحتياطية"
        return destination
    }

    // MARK: Restore

    func restore(from url: URL, library: MediaLibrary) async throws -> RestoreSummary {
        isWorking = true
        progress = 0
        statusText = "جارٍ قراءة النسخة الاحتياطية…"
        cancelFlag = CancelFlag()
        defer { isWorking = false }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let staging = storage.stagingDirectory.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let flag = cancelFlag
        try await Task.detached(priority: .userInitiated) { [weak self] in
            try BackupArchive.extract(from: url, into: staging, progress: { done, total in
                let fraction = total > 0 ? Double(done) / Double(total) : 1
                Task { @MainActor in self?.progress = fraction * 0.8 }
            }, isCancelled: { flag.isCancelled })
        }.value

        statusText = "جارٍ دمج البيانات…"
        let storage = self.storage
        var summary = try await Task.detached(priority: .userInitiated) {
            try Self.merge(staging: staging, storage: storage)
        }.value

        // Media library index is owned by MediaLibrary (main actor).
        let backupIndex = staging.appendingPathComponent("data/State/library.json")
        if let records = JSONStore.load([MediaAsset].self, from: backupIndex) {
            summary.mediaAdded = library.mergeRestored(records: records)
        }

        MotionPresetStore.shared.reload()
        TextStylePresetStore.shared.reload()
        SoundEffectsLibrary.shared.reload()
        EditingDNAStore.shared.reload()
        StudioTemplateLibrary.shared.reload()

        progress = 1
        statusText = "اكتملت الاستعادة"
        onRestoreFinished?()
        return summary
    }

    // MARK: Helpers (nonisolated)

    private nonisolated static func collect(_ directory: URL, prefix: String) -> [BackupArchive.Entry] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var result: [BackupArchive.Entry] = []
        let basePath = directory.standardizedFileURL.path
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let fullPath = fileURL.standardizedFileURL.path
            guard fullPath.hasPrefix(basePath) else { continue }
            var relative = String(fullPath.dropFirst(basePath.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            result.append(BackupArchive.Entry(relativePath: prefix + "/" + relative, fileURL: fileURL))
        }
        return result
    }

    private nonisolated static func merge(staging: URL, storage: StorageManager) throws -> RestoreSummary {
        let fm = FileManager.default
        var summary = RestoreSummary()

        // Media files: copy only those missing on the device.
        let stagedMedia = staging.appendingPathComponent("data/Media")
        if let files = try? fm.contentsOfDirectory(at: stagedMedia, includingPropertiesForKeys: nil) {
            for file in files {
                let target = storage.mediaDirectory.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: file, to: target) }
            }
        }

        // Projects: add missing, replace only when the backup copy is newer.
        let stagedProjects = staging.appendingPathComponent("data/Projects")
        if let dirs = try? fm.contentsOfDirectory(at: stagedProjects, includingPropertiesForKeys: nil) {
            for dir in dirs where dir.hasDirectoryPath || (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let target = storage.projectsDirectory.appendingPathComponent(dir.lastPathComponent, isDirectory: true)
                let stagedProject = JSONStore.load(EditProject.self, from: dir.appendingPathComponent("project.json"))
                if !fm.fileExists(atPath: target.path) {
                    try? fm.moveItem(at: dir, to: target)
                    summary.projectsAdded += 1
                } else if let stagedProject,
                          let existing = JSONStore.load(EditProject.self, from: target.appendingPathComponent("project.json")),
                          stagedProject.modifiedAt > existing.modifiedAt {
                    try? JSONStore.save(stagedProject, to: target.appendingPathComponent("project.json"))
                    try? JSONStore.save(ProjectSummary(project: stagedProject), to: target.appendingPathComponent("summary.json"))
                    summary.projectsUpdated += 1
                }
            }
        }

        // Platform presets: add custom presets that don't exist yet.
        let stagedPresets = staging.appendingPathComponent("data/Presets/platforms.json")
        let localPresetsURL = storage.presetsDirectory.appendingPathComponent("platforms.json")
        if let incoming = JSONStore.load([PlatformPreset].self, from: stagedPresets) {
            var local = JSONStore.load([PlatformPreset].self, from: localPresetsURL) ?? PlatformPreset.defaults
            let known = Set(local.map(\.id))
            let additions = incoming.filter { !known.contains($0.id) }
            local.append(contentsOf: additions)
            summary.presetsAdded = additions.count
            try? JSONStore.save(local, to: localPresetsURL)
        }

        // LUT files (+ merge the LUT index when one already exists locally)
        let stagedLUTs = staging.appendingPathComponent("data/Presets/LUTs")
        if let files = try? fm.contentsOfDirectory(at: stagedLUTs, includingPropertiesForKeys: nil) {
            for file in files {
                let target = storage.lutsDirectory.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: file, to: target) }
            }
        }
        let stagedLUTIndex = stagedLUTs.appendingPathComponent("luts.json")
        let localLUTIndex = storage.lutsDirectory.appendingPathComponent("luts.json")
        if fm.fileExists(atPath: stagedLUTIndex.path), let incoming = JSONStore.load([LUTInfo].self, from: stagedLUTIndex) {
            var local = JSONStore.load([LUTInfo].self, from: localLUTIndex) ?? []
            let known = Set(local.map(\.id))
            local.append(contentsOf: incoming.filter { !known.contains($0.id) })
            try? JSONStore.save(local, to: localLUTIndex)
        }

        // Saved color looks (Pro Studio)
        let stagedLooks = staging.appendingPathComponent("data/Presets/color-presets.json")
        let localLooks = storage.presetsDirectory.appendingPathComponent("color-presets.json")
        if let incoming = JSONStore.load([ColorPreset].self, from: stagedLooks) {
            var local = JSONStore.load([ColorPreset].self, from: localLooks) ?? []
            let known = Set(local.map(\.id))
            local.append(contentsOf: incoming.filter { !known.contains($0.id) })
            try? JSONStore.save(local, to: localLooks)
        }

        // Reversed-render registry (Pro Studio)
        let stagedReversed = staging.appendingPathComponent("data/State/reversed.json")
        let localReversed = storage.stateDirectory.appendingPathComponent("reversed.json")
        if let incoming = JSONStore.load([UUID: UUID].self, from: stagedReversed) {
            var local = JSONStore.load([UUID: UUID].self, from: localReversed) ?? [:]
            for (key, value) in incoming where local[key] == nil { local[key] = value }
            try? JSONStore.save(local, to: localReversed)
        }

        // Part 3: saved motion presets and text styles
        let stagedMotion = staging.appendingPathComponent("data/Presets/motion-presets.json")
        let localMotion = storage.presetsDirectory.appendingPathComponent("motion-presets.json")
        if let incoming = JSONStore.load([MotionPreset].self, from: stagedMotion) {
            var local = JSONStore.load([MotionPreset].self, from: localMotion) ?? []
            let known = Set(local.map(\.id))
            local.append(contentsOf: incoming.filter { !known.contains($0.id) })
            try? JSONStore.save(local, to: localMotion)
        }
        let stagedStyles = staging.appendingPathComponent("data/Presets/text-styles.json")
        let localStyles = storage.presetsDirectory.appendingPathComponent("text-styles.json")
        if let incoming = JSONStore.load([TextStylePreset].self, from: stagedStyles) {
            var local = JSONStore.load([TextStylePreset].self, from: localStyles) ?? []
            let known = Set(local.map(\.id))
            local.append(contentsOf: incoming.filter { !known.contains($0.id) })
            try? JSONStore.save(local, to: localStyles)
        }

        // Part 3: sound-effect registry and transcripts
        let stagedSFX = staging.appendingPathComponent("data/State/sfx.json")
        let localSFX = storage.stateDirectory.appendingPathComponent("sfx.json")
        if let incoming = JSONStore.load([String: UUID].self, from: stagedSFX) {
            var local = JSONStore.load([String: UUID].self, from: localSFX) ?? [:]
            for (key, value) in incoming where local[key] == nil { local[key] = value }
            try? JSONStore.save(local, to: localSFX)
        }
        let stagedTranscripts = staging.appendingPathComponent("data/State/Transcripts")
        let localTranscripts = storage.stateDirectory.appendingPathComponent("Transcripts", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: stagedTranscripts, includingPropertiesForKeys: nil), !files.isEmpty {
            try? fm.createDirectory(at: localTranscripts, withIntermediateDirectories: true)
            for file in files where file.pathExtension == "json" {
                let target = localTranscripts.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: file, to: target) }
            }
        }

        // Part 4: editing styles and Studio templates
        let stagedDNA = staging.appendingPathComponent("data/Presets/editing-dna.json")
        let localDNA = storage.presetsDirectory.appendingPathComponent("editing-dna.json")
        if let incoming = JSONStore.load([EditingDNA].self, from: stagedDNA) {
            var local = JSONStore.load([EditingDNA].self, from: localDNA) ?? []
            let known = Set(local.map(\.id))
            local.append(contentsOf: incoming.filter { !known.contains($0.id) })
            try? JSONStore.save(local, to: localDNA)
        }
        let stagedTemplates = staging.appendingPathComponent("data/Presets/Templates")
        let localTemplates = storage.presetsDirectory.appendingPathComponent("Templates", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: stagedTemplates, includingPropertiesForKeys: nil), !files.isEmpty {
            try? fm.createDirectory(at: localTemplates, withIntermediateDirectories: true)
            for file in files where file.pathExtension == "json" {
                let target = localTemplates.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: file, to: target) }
            }
        }

        // Part 5: Content Studio packs (copy the ones this device doesn't have)
        let stagedContent = staging.appendingPathComponent("data/State/AIContent")
        if let files = try? fm.contentsOfDirectory(at: stagedContent, includingPropertiesForKeys: nil), !files.isEmpty {
            try? fm.createDirectory(at: ContentStore.directory, withIntermediateDirectories: true)
            for file in files where file.pathExtension == "json" {
                let target = ContentStore.directory.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: file, to: target) }
            }
        }

        // Part 6: assistant plan history (missing projects' files) and assistant memory (merged).
        let stagedPlans = staging.appendingPathComponent("data/State/AIPlans")
        if let files = try? fm.contentsOfDirectory(at: stagedPlans, includingPropertiesForKeys: nil), !files.isEmpty {
            try? fm.createDirectory(at: PlanHistoryStore.directory, withIntermediateDirectories: true)
            for file in files where file.pathExtension == "json" {
                let target = PlanHistoryStore.directory.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: file, to: target) }
            }
        }
        let stagedMemory = staging.appendingPathComponent("data/State/assistant-memory.json")
        let localMemoryURL = storage.stateDirectory.appendingPathComponent("assistant-memory.json")
        if let incoming = JSONStore.load(AssistantMemoryData.self, from: stagedMemory) {
            var local = JSONStore.load(AssistantMemoryData.self, from: localMemoryURL) ?? AssistantMemoryData()
            for (key, count) in incoming.counts { local.counts[key] = max(local.counts[key] ?? 0, count) }
            if local.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { local.notes = incoming.notes }
            try? JSONStore.save(local, to: localMemoryURL)
        }

        // Export history
        let stagedHistory = staging.appendingPathComponent("data/State/history.json")
        let localHistoryURL = storage.stateDirectory.appendingPathComponent("history.json")
        if let incoming = JSONStore.load([ExportRecord].self, from: stagedHistory) {
            var local = JSONStore.load([ExportRecord].self, from: localHistoryURL) ?? []
            let known = Set(local.map(\.id))
            local.append(contentsOf: incoming.filter { !known.contains($0.id) })
            local.sort { $0.createdAt > $1.createdAt }
            try? JSONStore.save(local, to: localHistoryURL)
        }

        // Exported videos
        let stagedExports = staging.appendingPathComponent("exports")
        if let files = try? fm.contentsOfDirectory(at: stagedExports, includingPropertiesForKeys: nil) {
            for file in files {
                let target = storage.exportsDirectory.appendingPathComponent(file.lastPathComponent)
                if !fm.fileExists(atPath: target.path) {
                    try? fm.moveItem(at: file, to: target)
                    summary.exportsAdded += 1
                }
            }
        }
        return summary
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f
    }()
}
