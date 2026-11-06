//
//  ExportHistoryStore.swift
//  ClipStudio — Engines/Export
//
//  Export history (persisted) and saving to the Photos library.
//

import Foundation
import Photos

@MainActor
@Observable
final class ExportHistoryStore {
    private(set) var records: [ExportRecord] = []
    private let storage = StorageManager.shared
    private var url: URL { storage.stateDirectory.appendingPathComponent("history.json") }

    init() { reload() }

    func reload() {
        records = (JSONStore.load([ExportRecord].self, from: url) ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    func add(_ record: ExportRecord) {
        records.insert(record, at: 0)
        persist()
    }

    func fileURL(for record: ExportRecord) -> URL {
        storage.exportsDirectory.appendingPathComponent(record.fileName)
    }

    func fileExists(_ record: ExportRecord) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: record).path)
    }

    /// Removes the record; deletes the exported file only when `deleteFile` is true (user confirmed).
    func remove(_ record: ExportRecord, deleteFile: Bool) {
        if deleteFile { try? FileManager.default.removeItem(at: fileURL(for: record)) }
        records.removeAll { $0.id == record.id }
        persist()
    }

    func markSavedToPhotos(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].savedToPhotos = true
        persist()
    }

    var completedToday: Int {
        records.filter { Calendar.current.isDateInToday($0.createdAt) }.count
    }

    var totalBytes: Int64 { records.filter(fileExists).reduce(0) { $0 + $1.fileSize } }

    private func persist() {
        try? JSONStore.save(records, to: url)
    }
}

enum PhotosSaver {
    enum SaveError: LocalizedError {
        case denied

        var errorDescription: String? { "لم يُسمح بالحفظ في الصور. فعّل الإذن من الإعدادات › ClipStudio › الصور." }
    }

    static func saveVideo(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
