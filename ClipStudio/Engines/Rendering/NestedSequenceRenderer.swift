//
//  NestedSequenceRenderer.swift
//  ClipStudio — Engines/Rendering (EditingEngine)
//
//  Nested sequences (compound clips) are rendered once to a high-quality HEVC
//  .mov through the same GPU export pipeline, registered as a generated library
//  asset and played by ordinary media clips. Editing the nested sequence
//  re-renders it and re-points every instance (see StudioViewModel).
//

import Foundation

@MainActor
enum NestedSequenceRenderer {
    /// Mezzanine settings: canvas resolution, project frame rate, maximum quality.
    static var renderSettings: ExportSettings {
        var settings = ExportSettings()
        settings.container = .mov
        settings.codec = .hevc
        settings.resolution = .matchCanvas
        settings.frameRate = .matchSource
        settings.quality = .maximum
        settings.audioBitrateKbps = 256
        settings.destination = .files
        return settings
    }

    static func render(_ compound: CompoundClip, projectSettings: ProjectSettings, library: MediaLibrary,
                       control: RenderControl, progress: @escaping @Sendable (Double) -> Void) async throws -> MediaAsset {
        let output = StorageManager.shared.renderTempURL(extension: "mov")
        // The watermark is drawn once over the main timeline, never inside nested renders.
        var innerSettings = projectSettings
        innerSettings.watermark = nil
        let payload = RenderPayload(timeline: compound.timeline, projectSettings: innerSettings, range: nil)
        let outcome = try await ExportEngine.render(payload: payload, settings: renderSettings, media: library.urlMap(),
                                                    outputURL: output, control: control, progress: progress)
        return try await library.registerGenerated(file: outcome.url, displayName: compound.name, kind: .video)
    }
}
