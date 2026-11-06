//
//  StorageManager.swift
//  ClipStudio — Engines/Storage (StorageManager module)
//
//  File-system layout:
//    Application Support/ClipStudio/   (private, not visible in Files)
//      Media/        imported originals (never modified)
//      Projects/     <id>/project.json, summary.json, versions/
//      Presets/      platforms.json, LUTs/
//      State/        library.json, queue.json, history.json
//    Documents/      (visible in the Files app)
//      Exports/      finished videos
//      Backups/      .csbackup files
//    Caches/ClipStudio/  Thumbnails/, Analysis/, Render/
//    tmp/            import staging and in-progress renders
//

import Foundation

final class StorageManager: @unchecked Sendable {
    static let shared = StorageManager()

    let fileManager = FileManager.default
    let appSupport: URL
    let mediaDirectory: URL
    let projectsDirectory: URL
    let presetsDirectory: URL
    let lutsDirectory: URL
    let stateDirectory: URL
    let documentsDirectory: URL
    let exportsDirectory: URL
    let backupsDirectory: URL
    let cachesDirectory: URL
    let thumbnailsDirectory: URL
    let analysisDirectory: URL
    let renderDirectory: URL
    let stagingDirectory: URL

    private init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipStudio", isDirectory: true)
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipStudio", isDirectory: true)
        appSupport = support
        mediaDirectory = support.appendingPathComponent("Media", isDirectory: true)
        projectsDirectory = support.appendingPathComponent("Projects", isDirectory: true)
        presetsDirectory = support.appendingPathComponent("Presets", isDirectory: true)
        lutsDirectory = support.appendingPathComponent("Presets/LUTs", isDirectory: true)
        stateDirectory = support.appendingPathComponent("State", isDirectory: true)
        documentsDirectory = documents
        exportsDirectory = documents.appendingPathComponent("Exports", isDirectory: true)
        backupsDirectory = documents.appendingPathComponent("Backups", isDirectory: true)
        cachesDirectory = caches
        thumbnailsDirectory = caches.appendingPathComponent("Thumbnails", isDirectory: true)
        analysisDirectory = caches.appendingPathComponent("Analysis", isDirectory: true)
        renderDirectory = caches.appendingPathComponent("Render", isDirectory: true)
        stagingDirectory = fm.temporaryDirectory.appendingPathComponent("ClipStudioStaging", isDirectory: true)
        ensureDirectories()
    }

    func ensureDirectories() {
        for url in [appSupport, mediaDirectory, projectsDirectory, presetsDirectory, lutsDirectory, stateDirectory,
                    exportsDirectory, backupsDirectory, thumbnailsDirectory, analysisDirectory, renderDirectory, stagingDirectory] {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    // MARK: Paths

    func stagingURL(extension ext: String) -> URL {
        ensureDirectories()
        let cleanExt = ext.isEmpty ? "bin" : ext.lowercased()
        return stagingDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(cleanExt)
    }

    func renderTempURL(extension ext: String) -> URL {
        ensureDirectories()
        return renderDirectory.appendingPathComponent("render-\(UUID().uuidString)").appendingPathExtension(ext)
    }

    /// Returns a URL that does not exist yet ("name.mp4", "name (2).mp4", …). Never overwrites.
    func uniqueURL(in directory: URL, baseName: String, ext: String) -> URL {
        let base = sanitizedFileName(baseName)
        var candidate = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(counter))").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    func sanitizedFileName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = name.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.hasPrefix(".") ? String(cleaned.drop(while: { $0 == "." })) : cleaned
        let result = trimmed.isEmpty ? "ClipStudio" : trimmed
        return String(result.prefix(120))
    }

    // MARK: Sizes

    func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    var freeSpace: Int64 {
        let values = try? documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    var totalCapacity: Int64 {
        let values = try? documentsDirectory.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return Int64(values?.volumeTotalCapacity ?? 0)
    }

    /// True when `bytes` (plus a 500 MB safety margin) fit on disk.
    func hasSpace(for bytes: Int64) -> Bool {
        freeSpace > bytes + 500 * 1_048_576
    }

    // MARK: Cleanup

    func clearCaches() {
        for dir in [thumbnailsDirectory, analysisDirectory, renderDirectory, stagingDirectory] {
            if let items = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for item in items where !item.lastPathComponent.hasPrefix("blank-v") {
                    try? fileManager.removeItem(at: item)
                }
            }
        }
        ensureDirectories()
    }

    func clearStaging() {
        try? fileManager.removeItem(at: stagingDirectory)
        ensureDirectories()
    }
}

// MARK: - JSON persistence

enum JSONStore {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? makeDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try makeEncoder().encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
