//
//  ProjectManager.swift
//  ClipStudio — Engines/Project (ProjectManager module)
//
//  Project CRUD, debounced autosave, version snapshots, version restore,
//  duplication, crash recovery and media-usage queries. Part 5: deleting a
//  project also removes its Content Studio pack (Part 6: and its assistant plan history).
//

import Foundation

@MainActor
@Observable
final class ProjectManager {
    private(set) var summaries: [ProjectSummary] = []
    /// Set at launch when the previous editing session ended unexpectedly.
    private(set) var recoveredProjectID: UUID?
    /// Last save failure (e.g. disk full), shown by editors as a banner.
    private(set) var lastSaveError: String?

    private let storage = StorageManager.shared
    private var autosaveTasks: [UUID: Task<Void, Never>] = [:]
    private var lastVersionDates: [UUID: Date] = [:]

    static let versionInterval: TimeInterval = 5 * 60
    static let maxVersions = 40

    init() {
        reload()
        detectInterruptedSession()
    }

    // MARK: Paths

    func directory(for id: UUID) -> URL {
        storage.projectsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func projectURL(_ id: UUID) -> URL { directory(for: id).appendingPathComponent("project.json") }
    private func summaryURL(_ id: UUID) -> URL { directory(for: id).appendingPathComponent("summary.json") }
    private func versionsDirectory(_ id: UUID) -> URL { directory(for: id).appendingPathComponent("versions", isDirectory: true) }
    private var sessionURL: URL { storage.projectsDirectory.appendingPathComponent("session.json") }

    // MARK: Loading

    func reload() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: storage.projectsDirectory, includingPropertiesForKeys: nil) else {
            summaries = []
            return
        }
        var result: [ProjectSummary] = []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            if let summary = JSONStore.load(ProjectSummary.self, from: summaryURL(id)) {
                result.append(summary)
            } else if let project = JSONStore.load(EditProject.self, from: projectURL(id)) {
                let summary = ProjectSummary(project: project)
                try? JSONStore.save(summary, to: summaryURL(id))
                result.append(summary)
            }
        }
        summaries = result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func load(_ id: UUID) -> EditProject? {
        JSONStore.load(EditProject.self, from: projectURL(id))
    }

    func summary(_ id: UUID) -> ProjectSummary? { summaries.first { $0.id == id } }

    // MARK: Create / save

    func create(kind: ProjectKind, name: String, settings: ProjectSettings = ProjectSettings(),
                configure: (inout EditProject) -> Void = { _ in }) -> EditProject {
        var project = EditProject(name: name, kind: kind, settings: settings)
        configure(&project)
        save(project, makeVersion: true)
        return project
    }

    /// Immediate save. Writes project + summary and, when due, a version snapshot.
    func save(_ project: EditProject, makeVersion: Bool = false) {
        var stamped = project
        stamped.modifiedAt = Date()
        do {
            try JSONStore.save(stamped, to: projectURL(stamped.id))
            let summary = ProjectSummary(project: stamped)
            try JSONStore.save(summary, to: summaryURL(stamped.id))
            upsertSummary(summary)
            let last = lastVersionDates[stamped.id] ?? .distantPast
            if makeVersion || Date().timeIntervalSince(last) > Self.versionInterval {
                writeVersion(stamped)
            }
            lastSaveError = nil
        } catch {
            lastSaveError = "تعذّر حفظ المشروع: " + error.localizedDescription
        }
    }

    /// Debounced autosave (0.8 s after the last change).
    func scheduleAutosave(_ project: EditProject) {
        autosaveTasks[project.id]?.cancel()
        autosaveTasks[project.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.save(project)
        }
    }

    func flushAutosave(_ project: EditProject) {
        autosaveTasks[project.id]?.cancel()
        autosaveTasks[project.id] = nil
        save(project)
    }

    private func upsertSummary(_ summary: ProjectSummary) {
        if let index = summaries.firstIndex(where: { $0.id == summary.id }) {
            summaries[index] = summary
        } else {
            summaries.append(summary)
        }
        summaries.sort { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: Versions

    private static let versionFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    private func writeVersion(_ project: EditProject) {
        let dir = versionsDirectory(project.id)
        let url = dir.appendingPathComponent(Self.versionFormatter.string(from: Date()) + ".json")
        try? JSONStore.save(project, to: url)
        lastVersionDates[project.id] = Date()
        pruneVersions(project.id)
    }

    private func pruneVersions(_ id: UUID) {
        let all = versionFiles(id)
        guard all.count > Self.maxVersions else { return }
        for url in all.dropFirst(Self.maxVersions) { try? FileManager.default.removeItem(at: url) }
    }

    private func versionFiles(_ id: UUID) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: versionsDirectory(id), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func versions(for id: UUID) -> [ProjectVersion] {
        versionFiles(id).map { url in
            let name = url.deletingPathExtension().lastPathComponent
            let date = Self.versionFormatter.date(from: name) ?? Date.distantPast
            let summary = JSONStore.load(EditProject.self, from: url).map { ProjectSummary(project: $0) }
            return ProjectVersion(url: url, date: date, summary: summary)
        }
    }

    /// Restores a snapshot. The current state is saved as a version first, so restore is reversible.
    func restore(_ version: ProjectVersion, into id: UUID) -> EditProject? {
        guard var restored = JSONStore.load(EditProject.self, from: version.url) else { return nil }
        if let current = load(id) { writeVersion(current) }
        restored.id = id
        save(restored)
        return load(id)
    }

    // MARK: Management

    func rename(_ id: UUID, to name: String) {
        guard var project = load(id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        project.name = trimmed.isEmpty ? project.name : trimmed
        save(project)
    }

    func duplicate(_ id: UUID) -> EditProject? {
        guard var copy = load(id) else { return nil }
        copy.id = UUID()
        copy.name = copy.name + " — نسخة"
        copy.createdAt = Date()
        save(copy, makeVersion: true)
        return copy
    }

    func delete(_ id: UUID) {
        autosaveTasks[id]?.cancel()
        try? FileManager.default.removeItem(at: directory(for: id))
        ContentStore.delete(id)
        PlanHistoryStore.clear(id)
        summaries.removeAll { $0.id == id }
    }

    func projectsUsing(assetID: UUID) -> [ProjectSummary] {
        summaries.filter { $0.assetIDs.contains(assetID) }
    }

    func missingAssets(in project: EditProject, library: MediaLibrary) -> [UUID] {
        project.referencedAssetIDs.filter { id in
            guard let asset = library.asset(id) else { return true }
            return library.isMissing(asset)
        }
    }

    // MARK: Crash recovery

    private struct Session: Codable { var projectID: UUID; var startedAt: Date }

    func beginSession(_ id: UUID) {
        try? JSONStore.save(Session(projectID: id, startedAt: Date()), to: sessionURL)
    }

    func endSession() {
        try? FileManager.default.removeItem(at: sessionURL)
    }

    func clearRecovery() { recoveredProjectID = nil }

    private func detectInterruptedSession() {
        guard let session = JSONStore.load(Session.self, from: sessionURL) else { return }
        if FileManager.default.fileExists(atPath: projectURL(session.projectID).path) {
            recoveredProjectID = session.projectID
        }
        endSession()
    }
}
