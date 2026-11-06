//
//  WaveformService.swift
//  ClipStudio — Engines/Media (AudioEngine)
//
//  Audio waveform peaks for timeline drawing. Audio is decoded once at 8 kHz mono
//  with AVAssetReader (streamed, never loaded whole), reduced to 50 peaks per
//  second and cached in memory and on disk (Caches/ClipStudio/Analysis).
//

import Foundation
import AVFoundation

struct Waveform: Sendable {
    /// Peak amplitudes 0…1 at `samplesPerSecond` per second of source media.
    let peaks: [Float]
    let samplesPerSecond: Double

    var duration: Double { Double(peaks.count) / samplesPerSecond }
    var isEmpty: Bool { peaks.isEmpty }

    /// Highest peak within a source-time window.
    func peak(from start: Double, to end: Double) -> Float {
        guard !peaks.isEmpty, end > start else { return 0 }
        let a = max(0, Int(start * samplesPerSecond))
        let b = min(peaks.count, max(a + 1, Int((end * samplesPerSecond).rounded(.up))))
        guard a < b else { return 0 }
        var maximum: Float = 0
        for index in a..<b where peaks[index] > maximum { maximum = peaks[index] }
        return maximum
    }
}

actor WaveformService {
    static let shared = WaveformService()
    static let samplesPerSecond: Double = 50
    private static let decodeRate: Double = 8000

    private var memory: [UUID: Waveform] = [:]
    private var order: [UUID] = []
    private var inFlight: [UUID: Task<Waveform?, Never>] = [:]
    private let memoryLimit = 40

    func waveform(assetID: UUID, url: URL) async -> Waveform? {
        if let cached = memory[assetID] { return cached }
        if let running = inFlight[assetID] { return await running.value }
        let task = Task.detached(priority: .utility) { () -> Waveform? in
            if let disk = WaveformService.loadFromDisk(assetID) { return disk }
            guard let generated = try? await WaveformService.generate(url: url) else { return nil }
            WaveformService.saveToDisk(generated, assetID: assetID)
            return generated
        }
        inFlight[assetID] = task
        let result = await task.value
        inFlight[assetID] = nil
        if let result {
            memory[assetID] = result
            order.removeAll { $0 == assetID }
            order.append(assetID)
            while order.count > memoryLimit {
                let evicted = order.removeFirst()
                memory[evicted] = nil
            }
        }
        return result
    }

    func cached(_ assetID: UUID) -> Waveform? { memory[assetID] }

    func clearMemory() {
        memory.removeAll()
        order.removeAll()
    }

    // MARK: Generation

    static func generate(url: URL) async throws -> Waveform {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return Waveform(peaks: [], samplesPerSecond: samplesPerSecond)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: decodeRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return Waveform(peaks: [], samplesPerSecond: samplesPerSecond) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CancellationError() }

        let bucket = max(1, Int(decodeRate / samplesPerSecond))
        var peaks: [Float] = []
        var current: Int32 = 0
        var count = 0
        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let sampleCount = length / MemoryLayout<Int16>.size
            guard sampleCount > 0 else { continue }
            if samples.count < sampleCount { samples = [Int16](repeating: 0, count: sampleCount) }
            let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: sampleCount * 2, destination: base)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            for index in 0..<sampleCount {
                let magnitude = abs(Int32(samples[index]))
                if magnitude > current { current = magnitude }
                count += 1
                if count >= bucket {
                    peaks.append(Float(current) / 32768)
                    current = 0
                    count = 0
                }
            }
        }
        if count > 0 { peaks.append(Float(current) / 32768) }
        if reader.status == .failed { throw reader.error ?? CancellationError() }
        return Waveform(peaks: peaks, samplesPerSecond: samplesPerSecond)
    }

    // MARK: Disk cache

    private static func diskURL(_ assetID: UUID) -> URL {
        StorageManager.shared.analysisDirectory.appendingPathComponent(assetID.uuidString + "-wave-v1.bin")
    }

    static func loadFromDisk(_ assetID: UUID) -> Waveform? {
        guard let data = try? Data(contentsOf: diskURL(assetID)), data.count >= MemoryLayout<Float>.size else { return nil }
        let peaks: [Float] = data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
        return Waveform(peaks: peaks, samplesPerSecond: samplesPerSecond)
    }

    static func saveToDisk(_ waveform: Waveform, assetID: UUID) {
        guard !waveform.peaks.isEmpty else { return }
        let data = waveform.peaks.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: diskURL(assetID), options: .atomic)
    }
}
