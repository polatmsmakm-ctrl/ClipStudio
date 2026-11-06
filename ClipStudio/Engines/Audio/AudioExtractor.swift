//
//  AudioExtractor.swift
//  ClipStudio — Engines/Audio (Audio Studio, Part 3)
//
//  • Extracts the audio of a clip (its used source range) to a standalone AAC
//    (.m4a) file that is added to the media library.
//  • Exports the whole mix of a timeline (all tracks, volume automation, fades and
//    Audio Studio processing) to .m4a with real progress and cancellation.
//

import Foundation
import AVFoundation

enum AudioExportError: LocalizedError {
    case noAudio
    case sessionUnavailable
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noAudio: "لا يوجد صوت للتصدير."
        case .sessionUnavailable: "تعذّر تجهيز تصدير الصوت."
        case .failed(let message): "فشل تصدير الصوت: " + message
        case .cancelled: "تم إلغاء تصدير الصوت."
        }
    }
}

enum AudioExtractor {
    /// Writes the audio of `url` within `range` (source time) to `outputURL` (.m4a).
    static func extract(from url: URL, range: CMTimeRange?, to outputURL: URL, control: RenderControl? = nil) async throws {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        guard let audio = try await asset.loadTracks(withMediaType: .audio).first,
              let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw AudioExportError.noAudio }
        let duration = try await asset.load(.duration)
        let source = range ?? CMTimeRange(start: .zero, duration: duration)
        try track.insertTimeRange(source, of: audio, at: .zero)
        try await run(asset: composition, audioMix: nil, to: outputURL, control: control, progress: nil)
    }

    /// Exports the full audio mix of a timeline (range in timeline seconds, nil = whole).
    static func exportMix(timeline: Timeline, settings: ProjectSettings, media: MediaURLMap, range: TimeSpan?,
                          to outputURL: URL, control: RenderControl, progress: @escaping @Sendable (Double) -> Void) async throws {
        let built = try await CompositionBuilder(media: media).build(timeline: timeline, settings: settings,
                                                                     renderSize: CGSize(width: 64, height: 64),
                                                                     frameRate: settings.frameRate)
        guard !built.audioTracks.isEmpty else { throw AudioExportError.noAudio }
        var timeRange: CMTimeRange? = nil
        if let range {
            timeRange = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 600),
                                    end: CMTime(seconds: range.end, preferredTimescale: 600))
        }
        try await run(asset: built.composition, audioMix: built.audioMix, timeRange: timeRange, to: outputURL,
                      control: control, progress: progress)
    }

    private static func run(asset: AVAsset, audioMix: AVAudioMix?, timeRange: CMTimeRange? = nil, to outputURL: URL,
                            control: RenderControl?, progress: (@Sendable (Double) -> Void)?) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioExportError.sessionUnavailable
        }
        session.outputURL = outputURL
        session.outputFileType = .m4a
        session.audioMix = audioMix
        if let timeRange { session.timeRange = timeRange }
        let box = ExportSessionBox(session)
        control?.onCancel { box.session.cancelExport() }

        let poller = Task.detached {
            while !Task.isCancelled {
                progress?(Double(box.session.progress))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        defer { poller.cancel() }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            box.session.exportAsynchronously { continuation.resume() }
        }
        switch box.session.status {
        case .completed:
            progress?(1)
        case .cancelled:
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioExportError.cancelled
        default:
            try? FileManager.default.removeItem(at: outputURL)
            if control?.isCancelled == true { throw AudioExportError.cancelled }
            throw AudioExportError.failed(box.session.error?.localizedDescription ?? "—")
        }
    }
}

/// Lets the non-Sendable export session cross into callbacks.
final class ExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
