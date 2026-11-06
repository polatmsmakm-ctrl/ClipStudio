//
//  MediaLibrary.swift
//  ClipStudio — Engines/Media (MediaLibrary module)
//
//  The app-wide media library: index persistence, duplicate detection by
//  fingerprint, missing-file detection, relinking, renaming and safe deletion
//  (only ClipStudio's internal copy is ever deleted — never the user's original).
//

import Foundation

enum ImportOutcome {
    case added(MediaAsset)
    case duplicate(MediaAsset)

    var asset: MediaAsset {
        switch self {
        case .added(let a), .duplicate(let a): a
        }
    }
}

/// Immutable id → URL snapshot handed to background render work.
struct MediaURLMap: @unchecked Sendable {
    let urls: [UUID: URL]
    subscript(id: UUID) -> URL? { urls[id] }
}

@MainActor
@Observable
final class MediaLibrary {
    private(set) var assets: [MediaAsset] = []
    private(set) var missingIDs: Set<UUID> = []

    private let storage = StorageManager.shared
    /// Part 6: lets the proxy manager follow imports, deletions and relinks.
    @ObservationIgnored var onAssetAdded: ((MediaAsset) -> Void)?
    @ObservationIgnored var onAssetRemoved: ((UUID) -> Void)?
    private var indexURL: URL { storage.stateDirectory.appendingPathComponent("library.json") }

    init() {
        reload()
    }

    // MARK: Index

    func reload() {
        assets = (JSONStore.load([MediaAsset].self, from: indexURL) ?? []).sorted { $0.importedAt > $1.importedAt }
        refreshMissing()
    }

    private func persist() {
        try? JSONStore.save(assets, to: indexURL)
    }

    func refreshMissing() {
        missingIDs = Set(assets.filter { !FileManager.default.fileExists(atPath: url(for: $0).path) }.map(\.id))
    }

    // MARK: Lookup

    func url(for asset: MediaAsset) -> URL {
        storage.mediaDirectory.appendingPathComponent(asset.storedFileName)
    }

    func url(forID id: UUID) -> URL? {
        asset(id).map { url(for: $0) }
    }

    func asset(_ id: UUID) -> MediaAsset? {
        assets.first { $0.id == id }
    }

    func isMissing(_ asset: MediaAsset) -> Bool { missingIDs.contains(asset.id) }

    func existingAsset(fingerprint: String) -> MediaAsset? {
        guard !fingerprint.isEmpty else { return nil }
        return assets.first { $0.fingerprint == fingerprint && !missingIDs.contains($0.id) }
    }

    func urlMap() -> MediaURLMap {
        var map: [UUID: URL] = [:]
        for asset in assets where !missingIDs.contains(asset.id) { map[asset.id] = url(for: asset) }
        return MediaURLMap(urls: map)
    }

    var totalBytes: Int64 { assets.reduce(0) { $0 + $1.fileSize } }

    // MARK: Adopt (import)

    /// Moves a staged file into the library. If an identical file already exists,
    /// the staged copy is discarded and the existing asset is returned.
    func adopt(stagedFile: URL, originalName: String, kindHint: MediaKind?, knownFingerprint: String? = nil) async throws -> ImportOutcome {
        let fingerprint: String
        if let knownFingerprint {
            fingerprint = knownFingerprint
        } else {
            fingerprint = try await Task.detached(priority: .userInitiated) { try MediaFingerprint.compute(stagedFile) }.value
        }
        if let existing = existingAsset(fingerprint: fingerprint) {
            try? FileManager.default.removeItem(at: stagedFile)
            return .duplicate(existing)
        }

        let info = try await MediaInspector.inspect(url: stagedFile, kindHint: kindHint)
        let id = UUID()
        let ext = stagedFile.pathExtension.isEmpty ? "mov" : stagedFile.pathExtension.lowercased()
        let storedName = id.uuidString + "." + ext
        let destination = storage.mediaDirectory.appendingPathComponent(storedName)
        try FileManager.default.moveItem(at: stagedFile, to: destination)

        let baseName = (originalName as NSString).deletingPathExtension
        let asset = MediaAsset(id: id, kind: info.kind,
                               displayName: baseName.isEmpty ? info.kind.title : baseName,
                               originalFilename: originalName, storedFileName: storedName, importedAt: Date(),
                               fileSize: storage.fileSize(destination), durationSeconds: info.durationSeconds,
                               pixelWidth: info.pixelWidth, pixelHeight: info.pixelHeight, frameRate: info.frameRate,
                               videoCodec: info.videoCodec, audioCodec: info.audioCodec, hasAudio: info.hasAudio,
                               estimatedBitrate: info.estimatedBitrate, fingerprint: fingerprint)
        assets.insert(asset, at: 0)
        persist()
        onAssetAdded?(asset)
        return .added(asset)
    }

    /// Registers a rendered file (e.g. reversed clip, extracted audio) produced by the app itself.
    func registerGenerated(file: URL, displayName: String, kind: MediaKind) async throws -> MediaAsset {
        let outcome = try await adopt(stagedFile: file, originalName: displayName + "." + file.pathExtension, kindHint: kind)
        return outcome.asset
    }

    // MARK: Edit

    func rename(_ id: UUID, to name: String) {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        assets[index].displayName = trimmed
        persist()
    }

    /// Deletes ClipStudio's internal copy. Callers must confirm with the user first.
    func delete(_ id: UUID) {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return }
        let asset = assets[index]
        try? FileManager.default.removeItem(at: url(for: asset))
        assets.remove(at: index)
        missingIDs.remove(id)
        ThumbnailService.shared.removeCached(prefix: id.uuidString)
        persist()
        onAssetRemoved?(id)
    }

    /// Replaces a missing asset's file with a new one, keeping the same id so projects reconnect.
    func relink(_ id: UUID, stagedFile: URL) async throws {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return }
        let kind = assets[index].kind
        let info = try await MediaInspector.inspect(url: stagedFile, kindHint: kind)
        let fingerprint = try await Task.detached(priority: .userInitiated) { try MediaFingerprint.compute(stagedFile) }.value
        let ext = stagedFile.pathExtension.isEmpty ? "mov" : stagedFile.pathExtension.lowercased()
        let storedName = id.uuidString + "." + ext
        let destination = storage.mediaDirectory.appendingPathComponent(storedName)
        try? FileManager.default.removeItem(at: url(for: assets[index]))
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: stagedFile, to: destination)

        var updated = assets[index]
        updated.storedFileName = storedName
        updated.fileSize = storage.fileSize(destination)
        updated.durationSeconds = info.durationSeconds
        updated.pixelWidth = info.pixelWidth
        updated.pixelHeight = info.pixelHeight
        updated.frameRate = info.frameRate
        updated.videoCodec = info.videoCodec
        updated.audioCodec = info.audioCodec
        updated.hasAudio = info.hasAudio
        updated.estimatedBitrate = info.estimatedBitrate
        updated.fingerprint = fingerprint
        assets[index] = updated
        ThumbnailService.shared.removeCached(prefix: id.uuidString)
        persist()
        refreshMissing()
        onAssetRemoved?(id)
        onAssetAdded?(updated)
    }

    /// Merges asset records from a backup; returns how many were added.
    func mergeRestored(records: [MediaAsset]) -> Int {
        let known = Set(assets.map(\.id))
        let additions = records.filter { !known.contains($0.id) }
        assets.append(contentsOf: additions)
        assets.sort { $0.importedAt > $1.importedAt }
        persist()
        refreshMissing()
        return additions.count
    }

    /// Assets not referenced by any project.
    func unusedAssets(projects: ProjectManager) -> [MediaAsset] {
        let used = Set(projects.summaries.flatMap(\.assetIDs))
        return assets.filter { !used.contains($0.id) }
    }
}
