//
//  AudioTapProcessor.swift
//  ClipStudio — Engines/Audio (Audio Studio, Part 3)
//
//  Connects the per-clip AudioEffectChain to AVFoundation through an
//  MTAudioProcessingTap on each composition audio track (preview playback, export
//  and audio-only export all use it). A composition track can carry clips from
//  several timeline tracks one after another, so the tap maps the composition time
//  of every buffer to the clip that is playing and runs that clip's chain (splitting
//  buffers at clip boundaries). Parameters are read from a lock-protected store
//  that the editor updates live, so EQ/gain/noise changes are heard immediately
//  without rebuilding the player item. Output levels feed the mixer's meters.
//

import Foundation
import AVFoundation
import MediaToolbox
import os

// MARK: - Live parameters

struct AudioClipParameters: Equatable {
    var effects: AudioEffects
    var trackPan: Double
}

/// Thread-safe clip → parameters map shared by the UI (writer) and the taps (readers).
final class AudioParameterStore: @unchecked Sendable {
    private struct Entry {
        var parameters: AudioClipParameters
        var version: Int
    }

    private let lock = OSAllocatedUnfairLock(uncheckedState: [UUID: Entry]())
    private var versionCounter = 0

    func set(_ clipID: UUID, _ parameters: AudioClipParameters) {
        lock.withLockUnchecked { (entries: inout [UUID: Entry]) -> Void in
            if entries[clipID]?.parameters == parameters { return }
            versionCounter += 1
            entries[clipID] = Entry(parameters: parameters, version: versionCounter)
        }
    }

    func entry(for clipID: UUID) -> (parameters: AudioClipParameters, version: Int)? {
        lock.withLockUnchecked { (entries: inout [UUID: Entry]) -> (parameters: AudioClipParameters, version: Int)? in
            guard let entry = entries[clipID] else { return nil }
            return (parameters: entry.parameters, version: entry.version)
        }
    }

    /// Pushes the current effect settings of every clip in `timeline`.
    func update(from timeline: Timeline) {
        for track in timeline.tracks where track.carriesAudio {
            for clip in track.clips {
                set(clip.id, AudioClipParameters(effects: clip.audio.effects, trackPan: track.pan))
            }
        }
    }
}

/// Recent output levels per timeline track (for the mixer's meters).
final class AudioMeterStore: @unchecked Sendable {
    struct Reading {
        var peak: Float
        var rms: Float
        var time: CFAbsoluteTime
    }

    private let lock = OSAllocatedUnfairLock(uncheckedState: [UUID: Reading]())

    func record(trackID: UUID, peak: Float, rms: Float) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.withLockUnchecked { (readings: inout [UUID: Reading]) -> Void in
            if let existing = readings[trackID], now - existing.time < 0.03 {
                readings[trackID] = Reading(peak: max(existing.peak, peak), rms: max(existing.rms, rms), time: existing.time)
            } else {
                readings[trackID] = Reading(peak: peak, rms: rms, time: now)
            }
        }
    }

    /// Level (0…1) that decays when the track has been silent for a while.
    func level(for trackID: UUID) -> (peak: Float, rms: Float) {
        let now = CFAbsoluteTimeGetCurrent()
        return lock.withLockUnchecked { (readings: inout [UUID: Reading]) -> (peak: Float, rms: Float) in
            guard let reading = readings[trackID] else { return (0, 0) }
            let age = Float(max(0, now - reading.time))
            let decay = max(0, 1 - age / 0.35)
            return (reading.peak * decay, reading.rms * decay)
        }
    }

    func reset() {
        lock.withLockUnchecked { (readings: inout [UUID: Reading]) -> Void in readings.removeAll() }
    }
}

// MARK: - Tap context

struct AudioTapSegment {
    /// Composition seconds.
    let start: Double
    let end: Double
    let clipID: UUID
    let trackID: UUID
}

final class AudioTapContext {
    let segments: [AudioTapSegment]
    let parameters: AudioParameterStore
    let meters: AudioMeterStore?

    private var chains: [UUID: AudioEffectChain] = [:]
    private var sampleRate: Double = 44_100
    private var channelCount = 2
    private var isFloat = false
    private var isNonInterleaved = true
    private var maxFrames = 0
    private var scratch: UnsafeMutablePointer<Float>?
    private var pointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?
    private var cursor: Double = -1

    init(segments: [AudioTapSegment], parameters: AudioParameterStore, meters: AudioMeterStore?) {
        self.segments = segments.sorted { $0.start < $1.start }
        self.parameters = parameters
        self.meters = meters
    }

    deinit { releaseBuffers() }

    func prepare(maxFrames frames: Int, format: AudioStreamBasicDescription) {
        releaseBuffers()
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44_100
        channelCount = max(1, Int(format.mChannelsPerFrame))
        isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && format.mBitsPerChannel == 32
        isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        maxFrames = max(1, frames)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: channelCount * maxFrames)
        buffer.initialize(repeating: 0, count: channelCount * maxFrames)
        scratch = buffer
        let table = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: channelCount)
        for ch in 0..<channelCount { (table + ch).initialize(to: buffer + ch * maxFrames) }
        pointers = table
        var created: [UUID: AudioEffectChain] = [:]
        for segment in segments where created[segment.clipID] == nil {
            created[segment.clipID] = AudioEffectChain(sampleRate: sampleRate, channels: channelCount)
        }
        chains = created
        cursor = -1
    }

    func unprepare() {
        releaseBuffers()
        chains = [:]
    }

    private func releaseBuffers() {
        if let pointers {
            pointers.deinitialize(count: channelCount)
            pointers.deallocate()
        }
        if let scratch {
            scratch.deinitialize(count: channelCount * maxFrames)
            scratch.deallocate()
        }
        pointers = nil
        scratch = nil
    }

    private func segmentIndex(containing time: Double) -> Int? {
        var low = 0, high = segments.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let segment = segments[mid]
            if time < segment.start - 1e-6 {
                high = mid - 1
            } else if time >= segment.end - 1e-6 {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    private func nextSegmentStart(after time: Double) -> Double? {
        segments.first { $0.start > time + 1e-6 }?.start
    }

    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int, timeRange: CMTimeRange) {
        guard isFloat, frames > 0, let pointers, frames <= maxFrames else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let start: Double
        if timeRange.start.isValid && timeRange.start.isNumeric {
            start = timeRange.start.seconds
        } else {
            start = max(0, cursor)
        }
        // A jump (seek, loop) resets filter memories so no stale tail leaks in.
        if cursor >= 0 && abs(start - cursor) > 0.05 {
            for chain in chains.values { chain.reset() }
        }
        cursor = start + Double(frames) / sampleRate

        // Gather channel pointers (deinterleave when needed).
        let channels: Int
        if isNonInterleaved {
            channels = min(channelCount, buffers.count)
            for ch in 0..<channels {
                guard let data = buffers[ch].mData else { return }
                pointers[ch] = data.assumingMemoryBound(to: Float.self)
            }
        } else {
            guard let first = buffers.first, let data = first.mData, let scratch else { return }
            channels = max(1, Int(first.mNumberChannels))
            guard channels <= channelCount else { return }
            let interleaved = data.assumingMemoryBound(to: Float.self)
            for ch in 0..<channels {
                pointers[ch] = scratch + ch * maxFrames
                for i in 0..<frames { pointers[ch][i] = interleaved[i * channels + ch] }
            }
        }
        let block = ChannelBlock(pointers: pointers, channels: channels, frames: frames)

        var offset = 0
        while offset < frames {
            let time = start + Double(offset) / sampleRate
            guard let index = segmentIndex(containing: time) else {
                let next = nextSegmentStart(after: time).map { Int((($0 - time) * sampleRate).rounded(.up)) } ?? frames
                offset += max(1, min(frames - offset, next))
                continue
            }
            let segment = segments[index]
            let remaining = Int(((segment.end - time) * sampleRate).rounded(.up))
            let count = max(1, min(frames - offset, remaining))
            if let chain = chains[segment.clipID] {
                if let entry = parameters.entry(for: segment.clipID) {
                    chain.update(effects: entry.parameters.effects, trackPan: entry.parameters.trackPan, version: entry.version)
                }
                chain.process(block, offset: offset, count: count)
            }
            if let meters { measure(block, offset: offset, count: count, trackID: segment.trackID, meters: meters) }
            offset += count
        }

        if !isNonInterleaved, let first = buffers.first, let data = first.mData {
            let interleaved = data.assumingMemoryBound(to: Float.self)
            for ch in 0..<channels {
                for i in 0..<frames { interleaved[i * channels + ch] = pointers[ch][i] }
            }
        }
    }

    private func measure(_ block: ChannelBlock, offset: Int, count: Int, trackID: UUID, meters: AudioMeterStore) {
        var peak: Float = 0
        var sum: Float = 0
        for ch in 0..<block.channels {
            for i in offset..<(offset + count) {
                let v = block[ch][i]
                let a = abs(v)
                if a > peak { peak = a }
                sum += v * v
            }
        }
        let rms = sqrt(sum / Float(max(1, count * block.channels)))
        meters.record(trackID: trackID, peak: peak, rms: rms)
    }
}

// MARK: - MTAudioProcessingTap plumbing (C callbacks; no captures allowed)

private let tapInitCallback: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo
}

private let tapFinalizeCallback: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepareCallback: MTAudioProcessingTapPrepareCallback = { tap, maxFrames, format in
    let context = Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    context.prepare(maxFrames: Int(maxFrames), format: format.pointee)
}

private let tapUnprepareCallback: MTAudioProcessingTapUnprepareCallback = { tap in
    let context = Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    context.unprepare()
}

private let tapProcessCallback: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
    var timeRange = CMTimeRange.invalid
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, &timeRange, numberFramesOut)
    guard status == noErr else { return }
    let context = Unmanaged<AudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    context.process(bufferListInOut, frames: Int(numberFramesOut.pointee), timeRange: timeRange)
}

enum AudioTapFactory {
    /// Creates a tap that runs the clips' chains for one composition audio track.
    static func makeTap(context: AudioTapContext) -> MTAudioProcessingTap? {
        let clientInfo = UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque())
        var callbacks = MTAudioProcessingTapCallbacks(
            version: Int32(kMTAudioProcessingTapCallbacksVersion_0),
            clientInfo: clientInfo,
            init: tapInitCallback,
            finalize: tapFinalizeCallback,
            prepare: tapPrepareCallback,
            unprepare: tapUnprepareCallback,
            process: tapProcessCallback)
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                MTAudioProcessingTapCreationFlags(kMTAudioProcessingTapCreationFlag_PreEffects), &tap)
        guard status == noErr, let tap else {
            Unmanaged<AudioTapContext>.fromOpaque(clientInfo).release()
            return nil
        }
        return tap
    }
}

/// When composition audio tracks get a processing tap.
enum AudioTapPolicy {
    /// Only tracks with clips whose effects or balance change the sound (exports, other features).
    case whenNeeded
    /// Every audio track (Pro Studio preview: live effect edits and level meters).
    case always
}
