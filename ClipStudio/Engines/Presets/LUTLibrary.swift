//
//  LUTLibrary.swift
//  ClipStudio — Engines/Presets
//
//  Observable front for LUTStore: lists imported .cube LUTs, imports several files
//  at once with a readable report (validation errors per file) and deletes LUTs
//  only after checking which projects still use them.
//

import Foundation

struct LUTImportReport {
    var imported: [LUTInfo] = []
    var failures: [String] = []

    var summary: String {
        var parts: [String] = []
        if !imported.isEmpty { parts.append("تم استيراد " + Fmt.int(imported.count) + " LUT") }
        if !failures.isEmpty { parts.append("فشل " + Fmt.int(failures.count) + ": " + failures.joined(separator: "، ")) }
        return parts.isEmpty ? "لم يتم اختيار ملفات" : parts.joined(separator: " • ")
    }
}

@MainActor
@Observable
final class LUTLibrary {
    private(set) var luts: [LUTInfo] = []

    init() {
        reload()
    }

    func reload() {
        luts = LUTStore.shared.list().sorted { $0.importedAt > $1.importedAt }
    }

    func info(_ id: UUID) -> LUTInfo? { luts.first { $0.id == id } }

    func importFiles(_ urls: [URL]) async -> LUTImportReport {
        var report = LUTImportReport()
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            do {
                let info = try await Task.detached(priority: .userInitiated) {
                    try LUTStore.shared.importLUT(from: url, name: name)
                }.value
                report.imported.append(info)
            } catch {
                report.failures.append(name + " (" + error.localizedDescription + ")")
            }
        }
        reload()
        return report
    }

    /// Projects whose clips use the LUT (checked before deleting).
    func usage(of id: UUID, projects: ProjectManager) -> [String] {
        projects.summaries.compactMap { summary -> String? in
            guard summary.kind == .pro, let project = projects.load(summary.id) else { return nil }
            let timelines = [project.timeline] + project.compounds.map(\.timeline)
            let used = timelines.contains { timeline in
                timeline.tracks.contains { $0.clips.contains { $0.lut?.lutID == id } }
            }
            return used ? summary.name : nil
        }
    }

    func delete(_ id: UUID) {
        try? LUTStore.shared.delete(id)
        reload()
    }
}
