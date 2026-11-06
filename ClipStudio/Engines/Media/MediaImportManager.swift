//
//  MediaImportManager.swift
//  ClipStudio — Engines/Media (MediaImportManager module)
//
//  Imports from the Photos library (PhotosPicker) and the Files app.
//  • Files: security-scoped access → duplicate check BEFORE copying → stream copy.
//  • Photos: the system hands a temporary file which is copied within the callback.
//  Large files are copied with FileManager (streamed / APFS clone), never read into memory.
//

import Foundation
import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers

struct ImportReport {
    var added: [MediaAsset] = []
    var duplicates: [MediaAsset] = []
    var failures: [String] = []

    var all: [MediaAsset] { added + duplicates }

    var summary: String {
        var parts: [String] = []
        if !added.isEmpty { parts.append("تمت إضافة \(added.count)") }
        if !duplicates.isEmpty { parts.append("\(duplicates.count) موجود مسبقاً") }
        if !failures.isEmpty { parts.append("فشل \(failures.count)") }
        return parts.isEmpty ? "لم يتم استيراد أي ملف" : parts.joined(separator: " • ")
    }
}

/// Transferable for movies picked from Photos.
struct TransferredMovie: Transferable {
    let url: URL
    let originalName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = StorageManager.shared.stagingURL(extension: ext)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return TransferredMovie(url: destination, originalName: received.file.lastPathComponent)
        }
    }
}

/// Transferable for images picked from Photos.
struct TransferredImage: Transferable {
    let url: URL
    let originalName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { image in
            SentTransferredFile(image.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "jpg" : received.file.pathExtension
            let destination = StorageManager.shared.stagingURL(extension: ext)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return TransferredImage(url: destination, originalName: received.file.lastPathComponent)
        }
    }
}

@MainActor
@Observable
final class MediaImportManager {
    private(set) var isImporting = false
    private(set) var completedCount = 0
    private(set) var totalCount = 0
    private(set) var currentName = ""

    private let library: MediaLibrary
    private let storage = StorageManager.shared

    static let fileTypes: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .audio, .mp3, .wav, .mpeg4Audio, .image]

    init(library: MediaLibrary) {
        self.library = library
    }

    var progress: Double { totalCount > 0 ? Double(completedCount) / Double(totalCount) : 0 }

    // MARK: Files app

    func importFiles(_ urls: [URL]) async -> ImportReport {
        begin(count: urls.count)
        defer { end() }
        var report = ImportReport()
        for url in urls {
            currentName = url.lastPathComponent
            do {
                let outcome = try await importExternal(url)
                switch outcome {
                case .added(let a): report.added.append(a)
                case .duplicate(let a): report.duplicates.append(a)
                }
            } catch {
                report.failures.append(url.lastPathComponent + ": " + error.localizedDescription)
            }
            completedCount += 1
        }
        library.refreshMissing()
        return report
    }

    private func importExternal(_ url: URL) async throws -> ImportOutcome {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let kind = MediaInspector.kind(for: url) else { throw MediaInspectorError.unsupported(url.lastPathComponent) }
        let fingerprint = try await Task.detached(priority: .userInitiated) { try MediaFingerprint.compute(url) }.value
        if let existing = library.existingAsset(fingerprint: fingerprint) {
            return .duplicate(existing)
        }
        let size = storage.fileSize(url)
        guard storage.hasSpace(for: size) else { throw ImportError.notEnoughSpace }
        let staged = storage.stagingURL(extension: url.pathExtension)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: url, to: staged)
        }.value
        return try await library.adopt(stagedFile: staged, originalName: url.lastPathComponent,
                                       kindHint: kind, knownFingerprint: fingerprint)
    }

    /// Copies a file for relinking a missing asset.
    func stageForRelink(_ url: URL) async throws -> URL {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let staged = storage.stagingURL(extension: url.pathExtension)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: url, to: staged)
        }.value
        return staged
    }

    // MARK: Photos

    func importFromPhotos(_ items: [PhotosPickerItem]) async -> ImportReport {
        begin(count: items.count)
        defer { end() }
        var report = ImportReport()
        for item in items {
            currentName = "عنصر من الصور"
            do {
                let isMovie = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
                if isMovie {
                    guard let movie = try await item.loadTransferable(type: TransferredMovie.self) else { throw ImportError.photosUnavailable }
                    let outcome = try await library.adopt(stagedFile: movie.url, originalName: movie.originalName, kindHint: .video)
                    append(outcome, to: &report)
                } else {
                    guard let image = try await item.loadTransferable(type: TransferredImage.self) else { throw ImportError.photosUnavailable }
                    let outcome = try await library.adopt(stagedFile: image.url, originalName: image.originalName, kindHint: .image)
                    append(outcome, to: &report)
                }
            } catch {
                report.failures.append(error.localizedDescription)
            }
            completedCount += 1
        }
        library.refreshMissing()
        return report
    }

    private func append(_ outcome: ImportOutcome, to report: inout ImportReport) {
        switch outcome {
        case .added(let a): report.added.append(a)
        case .duplicate(let a): report.duplicates.append(a)
        }
    }

    private func begin(count: Int) {
        isImporting = true
        totalCount = count
        completedCount = 0
    }

    private func end() {
        isImporting = false
        currentName = ""
    }
}

enum ImportError: LocalizedError {
    case notEnoughSpace
    case photosUnavailable

    var errorDescription: String? {
        switch self {
        case .notEnoughSpace: "لا توجد مساحة كافية على الجهاز لاستيراد هذا الملف."
        case .photosUnavailable: "تعذّر تحميل العنصر من مكتبة الصور (قد يكون في iCloud ولم يكتمل تنزيله)."
        }
    }
}
