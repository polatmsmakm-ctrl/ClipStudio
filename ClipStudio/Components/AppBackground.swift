//
//  AppBackground.swift
//  ClipStudio — Components
//
//  Full-screen background behind every screen.
//  • If an image named "AppBackground" exists in the asset catalog, it is used
//    with a dark overlay (drop your own space/nature photo in to replace the default).
//  • Otherwise: a calm, code-drawn animated charcoal background with soft gold glow
//    (still when Reduce Motion, Low Power Mode or heat is on).
//

import SwiftUI
import UIKit

struct AppBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppSettings.Keys.animatedBackground) private var animated = true

    private static let customImage: UIImage? = UIImage(named: "AppBackground")

    var body: some View {
        ZStack {
            if let image = Self.customImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                Color.black.opacity(0.58)
            } else {
                Theme.Palette.background
                // Part 6: the animation also stops while hot or in Low Power Mode.
                if animated && !reduceMotion && !PerformanceMonitor.shared.reducesEffects {
                    TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
                        GlowField(phase: context.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    GlowField(phase: 0)
                }
                LinearGradient(colors: [.clear, Color.black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct GlowField: View {
    let phase: Double

    var body: some View {
        Canvas { context, size in
            let blobs: [(x: Double, y: Double, radius: Double, offset: Double, opacity: Double)] = [
                (0.18, 0.12, 0.62, 0.0, 0.14),
                (0.88, 0.38, 0.48, 2.1, 0.09),
                (0.35, 0.92, 0.66, 4.2, 0.08)
            ]
            for blob in blobs {
                let t = phase * 0.045 + blob.offset
                let cx = size.width * (blob.x + 0.06 * sin(t))
                let cy = size.height * (blob.y + 0.05 * cos(t * 0.8))
                let r = max(size.width, size.height) * blob.radius
                let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect),
                             with: .radialGradient(Gradient(colors: [Theme.Palette.accent.opacity(blob.opacity), .clear]),
                                                   center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: r))
            }
        }
    }
}

extension View {
    /// Standard screen chrome: background + hidden list/form backgrounds.
    func screenBackground() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(AppBackground())
    }
}
