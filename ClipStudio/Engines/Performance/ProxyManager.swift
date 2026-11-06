//
//  ProxyManager.swift
//  ClipStudio — Engines/Performance (Part 6)
//
//  Proxy media: light copies (540p or 720p H.264) of heavy videos — 4K, high
//  bit-rate, high frame-rate or HEVC 10-bit footage — used ONLY for the Studio
//  preview so playback and scrubbing stay smooth. Exports, snapshots, analyses
//  and AI tools always read the original file. Proxies live in Caches (the
//  system may purge them; they are then simply rebuilt), are tied to the
//  original's fingerprint (a relinked file invalidates its proxy), and are
//  generated one at a time, paused while the device is hot.
//

import Foundation
import AVFoundation

enum ProxyResolution: String, CaseIterable, Identifiable, Codable, Hashable {
    case p540, p720

    var id: String { rawValue }

    var title: String {
        switch self {
        case .p540: "540p (أخف)"
        case .p720: "720p (أوضح)"
        }
    }

    var preset: String {
        switch self {
        case .p540: AVAssetExportPreset960x540
        case .p720: AVAssetExportPreset1280x720
        }
    }

    var shortSide: Int { self == .p540 ? 540 : 720 }
}

struct ProxyRecord: Codable, Hashable {
    var assetID: UUID
    var fingerprint: String
    var fileName: String
    var resolution: ProxyResolution
    var bytes: Int64
    var createdAt: Date
}

enum ProxyStatus: Hashable {
    case notNeeded
    case none
    case queued
    case working(Double)
    case ready
    case failed(String)
}

enum ProxyPolicy {
    /// Whether a proxy helps the preview of this asset.
    static func needsProxy(_ asset: MediaAsset) -> Bool {
        guard asset.kind == .video else { return false }
        let w = asset.pixelWidth ?? 0, h = asset.pixelHeight ?? 0
        if max(w, h) > 1920 || min(w, h) > 1080 { return true }
        if let bitrate = asset.estimatedBitrate, bitrate > 25_000_000 { return true }
        if let fps = asset.frameRate, fps > 61 { return true }
        let codec = (asset.videoCodec ?? "").lowercased()
        if codec.contains("prores") || codec.contains("apcn") || codec.contains("apch") || codec.contains("ap4h") { return true }
        return false
    }

    /// A proxy file is only valid for the exact original it was made from.
    static func isValid(_ record: ProxyRecord, for asset: MediaAsset, fileExists: Bool) -> Bool {
        fileExists && record.fingerprint == asset.fingerprint && record.assetID == asset.id
    }
}

@MainActor
@Observable
final class ProxyManager {
    private enum Keys {
        static let enabled = "proxies.enabled"
        static let auto = "proxies.auto"
        static let resolution = "proxies.resolution"
    }

    private(set) var records: [UUID: ProxyRecord] = [:]
    private(set) var queue: [UUID] = []
    private(set) var currentID: UUID?
    private(set) var currentProgress: Double = 0
    private(set) var failures: [UUID: String] = [:]
    /// Bumped whenever a proxy becomes ready or is removed (the Studio rebuilds its preview).
    private(set) var version = 0

    var isEnabled: Bool { didSet { UserDefaults.standard.set(isEnabled, forKey: Keys.enabled); version += 1 } }
    var autoCreate: Bool { didSet { UserDefaults.standard.set(autoCreate, forKey: Keys.auto) } }
    var resolution: ProxyResolution { didSet { UserDefaults.standard.set(resolution.rawValue, forKey: Keys.resolution) } }

    /// Asks before starting each item (true while the device is hot / in Low Power Mode).
    var shouldPause: () -> Bool = { false }

    private let library: MediaLibrary
    private var worker: Task<Void, Never>?
    private var activeSession: AVAssetExportSession?

    static var directory: URL { StorageManager.shared.cachesDirectory.appendingPathComponent("Proxies", isDirectory: true) }
    private static var registryURL: URL { StorageManager.shared.stateDirectory.appendingPathComponent("proxies.json") }

    init(library: MediaLibrary) {
        self.library = library
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        autoCreate = defaults.object(forKey: Keys.auto) as? Bool ?? true
        resolution = ProxyResolution(rawValue: defaults.string(forKey: Keys.resolution) ?? "") ?? .p540
        let list = JSONStore.load([ProxyRecord].self, from: Self.registryURL) ?? []
        records = Dictionary(list.map { ($0.assetID, $0) }, uniquingKeysWith: { $1 })
        prune()
    }

    // MARK: Lookup

    func url(of record: ProxyRecord) -> URL { Self.directory.appendingPathComponent(record.fileName) }

    func readyURL(for asset: MediaAsset) -> URL? {
        guard let record = records[asset.id] else { return nil }
        let url = url(of: record)
        return ProxyPolicy.isValid(record, for: asset, fileExists: FileManager.default.fileExists(atPath: url.path)) ? url : nil
    }

    func status(for asset: MediaAsset) -> ProxyStatus {
        if readyURL(for: asset) != nil { return .ready }
        if currentID == asset.id { return .working(currentProgress) }
        if queue.contains(asset.id) { return .queued }
        if let failure = failures[asset.id] { return .failed(failure) }
        return ProxyPolicy.needsProxy(asset) ? .none : .notNeeded
    }

    /// The preview's media map with ready proxies swapped in (originals elsewhere).
    func previewMap(_ map: MediaURLMap) -> MediaURLMap {
        guard isEnabled else { return map }
        var urls = map.urls
        for (id, _) in map.urls {
            if let asset = library.asset(id), let proxy = readyURL(for: asset) { urls[id] = proxy }
        }
        return MediaURLMap(urls: urls)
    }

    var totalBytes: Int64 { records.values.reduce(0) { $0 + $1.bytes } }

    var readyCount: Int { library.assets.filter { readyURL(for: $0) != nil }.count }

    /// Library videos that would benefit from a proxy but have none.
    var missingAssets: [MediaAsset] {
        library.assets.filter { ProxyPolicy.needsProxy($0) && readyURL(for: $0) == nil && !library.isMissing($0) }
    }

    // MARK: Queue

    func autoGenerateIfNeeded(_ asset: MediaAsset) {
        guard autoCreate, ProxyPolicy.needsProxy(asset) else { return }
        enqueue([asset])
    }

    func enqueue(_ assets: [MediaAsset]) {
        for asset in assets where asset.kind == .video && readyURL(for: asset) == nil {
            if !queue.contains(asset.id) && currentID != asset.id { queue.append(asset.id) }
            failures.removeValue(forKey: asset.id)
        }
        startIfNeeded()
    }

    func cancelAll() {
        queue.removeAll()
        activeSession?.cancelExport()
    }

    func startIfNeeded() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.drain()
            self?.worker = nil
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            if shouldPause() {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                continue
            }
            let id = queue.removeFirst()
            guard let asset = library.asset(id), let source = library.url(forID: id), !library.isMissing(asset) else { continue }
            currentID = id
            currentProgress = 0
            do {
                let record = try await make(asset: asset, source: source)
                records[id] = record
                persist()
                version += 1
            } catch is CancellationError {
                // Cancelled by the user.
            } catch {
                failures[id] = error.localizedDescription
            }
            currentID = nil
            currentProgress = 0
        }
    }

    private func make(asset: MediaAsset, source: URL) async throws -> ProxyRecord {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let preset = AVAssetExportSession.allExportPresets().contains(resolution.preset) ? resolution.preset : AVAssetExportPresetMediumQuality
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: preset) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let fileName = asset.id.uuidString + "-" + resolution.rawValue + ".mp4"
        let output = Self.directory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false
        activeSession = session
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                let value = Double(session.progress)
                self?.currentProgress = value
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        await session.export()
        watcher.cancel()
        activeSession = nil
        switch session.status {
        case .completed:
            let bytes = StorageManager.shared.fileSize(output)
            return ProxyRecord(assetID: asset.id, fingerprint: asset.fingerprint, fileName: fileName, resolution: resolution,
                               bytes: bytes, createdAt: Date())
        case .cancelled:
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
        default:
            try? FileManager.default.removeItem(at: output)
            throw session.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    // MARK: Removal

    func remove(_ assetID: UUID) {
        queue.removeAll { $0 == assetID }
        if currentID == assetID { activeSession?.cancelExport() }
        if let record = records.removeValue(forKey: assetID) {
            try? FileManager.default.removeItem(at: url(of: record))
            persist()
            version += 1
        }
        failures.removeValue(forKey: assetID)
    }

    func removeAll() {
        cancelAll()
        try? FileManager.default.removeItem(at: Self.directory)
        records = [:]
        failures = [:]
        persist()
        version += 1
    }

    /// Drops records whose file or original is gone.
    func prune() {
        var changed = false
        for (id, record) in records {
            let exists = FileManager.default.fileExists(atPath: url(of: record).path)
            if !exists || library.asset(id).map({ !ProxyPolicy.isValid(record, for: $0, fileExists: exists) }) ?? true {
                if exists { try? FileManager.default.removeItem(at: url(of: record)) }
                records.removeValue(forKey: id)
                changed = true
            }
        }
        if changed { persist() }
    }

    private func persist() {
        try? JSONStore.save(Array(records.values), to: Self.registryURL)
    }
}
