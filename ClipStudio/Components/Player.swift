//
//  Player.swift
//  ClipStudio — Components
//
//  AVPlayer wrapper with frame-accurate seeking, frame stepping, range
//  playback (for segment previews) and a compact transport bar.
//

import SwiftUI
import AVFoundation
import UIKit

@MainActor
@Observable
final class PlayerController {
    let player = AVPlayer()
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var frameRate: Double = 30
    var loopsRange = false

    private var rangeStart: Double?
    private var rangeEnd: Double?
    nonisolated(unsafe) private var timeObserver: Any?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(time)
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load(url: URL) {
        load(item: AVPlayerItem(asset: AVURLAsset(url: url)))
    }

    func load(item: AVPlayerItem?) {
        pause()
        rangeStart = nil
        rangeEnd = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player.replaceCurrentItem(with: item)
        currentTime = 0
        duration = 0
        guard let item else { return }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }
        Task { [weak self] in
            let loaded = (try? await item.asset.load(.duration))?.seconds ?? 0
            self?.duration = loaded.isFinite ? loaded : 0
        }
    }

    func play() {
        if let end = rangeEnd, currentTime >= end - 0.02, let start = rangeStart {
            seek(to: start)
        } else if duration > 0, currentTime >= duration - 0.02 {
            seek(to: rangeStart ?? 0)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to seconds: Double, precise: Bool = true) {
        let clamped = max(0, duration > 0 ? min(seconds, duration) : seconds)
        let time = CMTime(seconds: clamped, preferredTimescale: 60_000)
        let tolerance: CMTime = precise ? .zero : CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        currentTime = clamped
    }

    func step(frames: Int) {
        pause()
        seek(to: currentTime + Double(frames) / max(1, frameRate))
    }

    /// Plays only [start, end] (segment preview).
    func playRange(start: Double, end: Double, loop: Bool = false) {
        rangeStart = start
        rangeEnd = end
        loopsRange = loop
        seek(to: start)
        player.play()
        isPlaying = true
    }

    func clearRange() {
        rangeStart = nil
        rangeEnd = nil
    }

    private func tick(_ time: CMTime) {
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        currentTime = seconds
        isPlaying = player.rate != 0
        if let end = rangeEnd, seconds >= end - 0.01 {
            if loopsRange, let start = rangeStart {
                seek(to: start)
            } else {
                pause()
                currentTime = end
            }
        }
    }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect

    final class SurfaceView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateUIView(_ uiView: SurfaceView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
        uiView.playerLayer.videoGravity = gravity
    }
}

/// Player view with rounded corners and an overlaid transport bar.
struct VideoPreview: View {
    let controller: PlayerController
    var showsControls = true

    var body: some View {
        VStack(spacing: 8) {
            PlayerSurface(player: controller.player)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.Palette.stroke))
                .onTapGesture { controller.toggle() }
            if showsControls { TransportBar(controller: controller) }
        }
    }
}

struct TransportBar: View {
    let controller: PlayerController
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(
                get: { isScrubbing ? scrubValue : controller.currentTime },
                set: { newValue in
                    scrubValue = newValue
                    controller.seek(to: newValue, precise: false)
                }),
                   in: 0...max(controller.duration, 0.01),
                   onEditingChanged: { editing in
                       isScrubbing = editing
                       if !editing { controller.seek(to: scrubValue, precise: true) }
                   })
            .tint(Theme.Palette.accent)

            HStack(spacing: 18) {
                Text(Fmt.timecode(controller.currentTime, fps: controller.frameRate))
                    .font(Theme.Typo.mono)
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Button { controller.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                    .accessibilityLabel("إطار للخلف")
                Button { controller.toggle() } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                .accessibilityLabel(controller.isPlaying ? "إيقاف مؤقت" : "تشغيل")
                Button { controller.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                    .accessibilityLabel("إطار للأمام")
                Spacer()
                Text(Fmt.duration(controller.duration))
                    .font(Theme.Typo.mono)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .foregroundStyle(Theme.Palette.textPrimary)
            .buttonStyle(.plain)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}
