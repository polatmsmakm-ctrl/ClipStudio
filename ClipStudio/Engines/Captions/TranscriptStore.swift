//
//  TranscriptStore.swift
//  ClipStudio — Engines/Captions (Part 3)
//
//  Per-media, per-language word transcripts in State/Transcripts/<asset>-<lang>.json
//  (included in backups). Only parts of a file that were never transcribed are
//  sent to the recognizer again.
//

import Foundation

enum TranscriptStore {
    static var directory: URL {
        StorageManager.shared.stateDirectory.appendingPathComponent("Transcripts", isDirectory: true)
    }

    static func url(assetID: UUID, localeID: String) -> URL {
        let safeLocale = localeID.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(assetID.uuidString + "-" + safeLocale + ".json")
    }

    static func load(assetID: UUID, localeID: String) -> AssetTranscript? {
        JSONStore.load(AssetTranscript.self, from: url(assetID: assetID, localeID: localeID))
    }

    static func save(_ transcript: AssetTranscript) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONStore.save(transcript, to: url(assetID: transcript.assetID, localeID: transcript.localeID))
    }

    /// Every transcript of a media file (any language).
    static func transcripts(for assetID: UUID) -> [AssetTranscript] {
        let prefix = assetID.uuidString + "-"
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .compactMap { JSONStore.load(AssetTranscript.self, from: $0) }
    }

    static func delete(assetID: UUID) {
        let prefix = assetID.uuidString + "-"
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
